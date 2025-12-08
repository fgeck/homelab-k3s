# CloudNativePG Migration Guide

## Overview

This guide documents the migration from Bitnami PostgreSQL to CloudNativePG for your homelab cluster.

**Migration Approach:** In-place migration with downtime
**Estimated Downtime per Database:** 30-60 minutes
**Total Migration Time:** 2-3 hours

## What is CloudNativePG?

CloudNativePG is a Kubernetes operator that manages PostgreSQL clusters natively. Benefits over Bitnami:

- **Cloud-native design:** Purpose-built for Kubernetes
- **Built-in backup/restore:** Integrated Barman support
- **Better monitoring:** Native Prometheus integration
- **Declarative management:** Full GitOps support
- **Simpler upgrades:** Automated rolling updates
- **Connection pooling:** Built-in PgBouncer support

## Architecture

### Current Setup (Bitnami)
- 2x single-instance PostgreSQL clusters
- Bitnami Helm charts with OCIRepository
- Custom backup cronjobs to Proxmox Backup Server
- Application init containers create databases/users

### New Setup (CloudNativePG)
- 2x single-instance PostgreSQL clusters (CloudNativePG)
- CloudNativePG operator + cluster Helm charts
- Custom backup cronjobs continue to work
- **Application init containers work unchanged!**

### How Init Containers Work with CloudNativePG

**Good news!** Your existing init container pattern will work seamlessly with CloudNativePG:

1. **Superuser Access:** CloudNativePG exposes the postgres superuser credentials via a secret: `<cluster-name>-superuser`
2. **Connection:** Init containers connect to `<cluster-name>-rw` service (read-write endpoint)
3. **Database Creation:** Init containers can create databases and users exactly as before
4. **No Changes Required:** Your init container scripts in authentik, paperless, etc. work as-is

**Example connection update:**
```yaml
# OLD (Bitnami)
PGHOST: default-postgres

# NEW (CloudNativePG)
PGHOST: default-postgres-cnpg-rw
```

That's it! The init container logic remains identical.

## Pre-Migration Checklist

- [ ] Backup current databases using existing PBS cronjobs
- [ ] Verify all applications are healthy
- [ ] Note current database sizes: `kubectl exec -n <namespace> <pod> -- psql -U postgres -c "\l+"`
- [ ] Review application init container configurations
- [ ] Plan maintenance window (suggest weekend evening)
- [ ] Test recovery from PBS backups

## Migration Steps

### Phase 1: Install CloudNativePG Operator (15 minutes)

1. **Commit and push operator configuration:**
   ```bash
   git add clusters/building-blocks/base/repos/cloudnative-pg.yaml
   git add clusters/building-blocks/persistency/cnpg-system/
   git commit -m "feat: add CloudNativePG operator"
   git push
   ```

2. **Wait for Flux to reconcile:**
   ```bash
   flux reconcile source git flux-system
   flux reconcile ks cnpg-operator --with-source
   ```

3. **Verify operator is running:**
   ```bash
   kubectl get pods -n cnpg-system
   # Expected: cloudnative-pg-xxx Running
   ```

4. **Check operator logs:**
   ```bash
   kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg
   ```

### Phase 2: Deploy CloudNativePG Clusters (30 minutes)

**Do NOT enable the clusters in kustomization yet!** We'll deploy them manually first.

1. **Deploy default-postgres-cnpg:**
   ```bash
   # Apply the cluster configuration
   kubectl apply -k clusters/building-blocks/persistency/apps/default-postgres-cnpg/app

   # Watch cluster creation
   kubectl get cluster -n default default-postgres-cnpg -w

   # Wait for cluster to be ready
   kubectl wait --for=condition=Ready cluster/default-postgres-cnpg -n default --timeout=10m
   ```

2. **Verify default-postgres-cnpg is healthy:**
   ```bash
   # Check pods
   kubectl get pods -n default -l cnpg.io/cluster=default-postgres-cnpg

   # Check cluster status
   kubectl describe cluster -n default default-postgres-cnpg

   # Test connection
   kubectl exec -n default default-postgres-cnpg-1 -- psql -U postgres -c "SELECT version();"
   ```

3. **Deploy security-postgres-cnpg:**
   ```bash
   # Apply the cluster configuration
   kubectl apply -k clusters/building-blocks/persistency/apps/security-postgres-cnpg/app

   # Watch cluster creation
   kubectl get cluster -n security security-postgres-cnpg -w

   # Wait for cluster to be ready
   kubectl wait --for=condition=Ready cluster/security-postgres-cnpg -n security --timeout=10m
   ```

4. **Verify security-postgres-cnpg is healthy:**
   ```bash
   # Check pods
   kubectl get pods -n security -l cnpg.io/cluster=security-postgres-cnpg

   # Check cluster status
   kubectl describe cluster -n security security-postgres-cnpg

   # Test connection
   kubectl exec -n security security-postgres-cnpg-1 -- psql -U postgres -c "SELECT version();"
   ```

### Phase 3: Migrate default-postgres (60 minutes)

**Applications using default-postgres:**
- paperless-ngx
- radarr
- sonarr

1. **Scale down applications:**
   ```bash
   kubectl scale deployment -n default paperless --replicas=0
   kubectl scale deployment -n media radarr --replicas=0
   kubectl scale deployment -n media sonarr --replicas=0
   ```

2. **Create final backup from Bitnami PostgreSQL:**
   ```bash
   # Get old pod name
   OLD_POD=$(kubectl get pod -n default -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=default-postgres -o jsonpath='{.items[0].metadata.name}')

   # Create backup directory
   mkdir -p /tmp/postgres-migration

   # Backup all databases
   kubectl exec -n default $OLD_POD -- bash -c "PGPASSWORD=\${POSTGRES_PASSWORD} pg_dumpall -U defaultuser" > /tmp/postgres-migration/default-postgres-$(date +%Y%m%d_%H%M%S).sql

   # Verify backup
   ls -lh /tmp/postgres-migration/
   grep -c "PostgreSQL database dump complete" /tmp/postgres-migration/default-postgres-*.sql
   ```

3. **Restore to CloudNativePG:**
   ```bash
   # Get new pod name
   NEW_POD=$(kubectl get pod -n default -l cnpg.io/cluster=default-postgres-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

   # Get postgres superuser password
   POSTGRES_PASSWORD=$(kubectl get secret -n default default-postgres-cnpg-superuser -o jsonpath='{.data.password}' | base64 -d)

   # Restore backup
   cat /tmp/postgres-migration/default-postgres-*.sql | kubectl exec -i -n default $NEW_POD -- \
       bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -U postgres"
   ```

4. **Verify restored data:**
   ```bash
   # List databases
   kubectl exec -n default $NEW_POD -- psql -U postgres -c "\l"

   # Check for application databases (should see paperless, radarr, sonarr)
   kubectl exec -n default $NEW_POD -- psql -U postgres -c "SELECT datname FROM pg_database WHERE datistemplate = false;"
   ```

5. **Update application configurations:**

   Update each application to use the new database host. The **init containers will work automatically**!

   **Paperless-ngx:** `clusters/building-blocks/other/apps/paperless-ngx/app/paperless-deploy.yaml:40`
   ```yaml
   # OLD
   - name: PAPERLESS_DBHOST
     value: ${quote}${DEFAULT_POSTGRES_HOST}${quote}

   # NEW
   - name: PAPERLESS_DBHOST
     value: default-postgres-cnpg-rw
   ```

   **Paperless init secret:** `clusters/building-blocks/other/apps/paperless-ngx/app/paperless-init-db-secret.yaml`
   ```yaml
   # Update PGHOST
   PGHOST: default-postgres-cnpg-rw
   ```

   **Radarr:** `clusters/building-blocks/media/apps/radarr/app/radarr-env.yaml`
   ```yaml
   # Find and update Postgres connection
   ```

   **Sonarr:** `clusters/building-blocks/media/apps/sonarr/app/sonarr-env.yaml`
   ```yaml
   # Find and update Postgres connection
   ```

   **Important:** Also update your `cluster-secrets` if `DEFAULT_POSTGRES_HOST` is defined there:
   ```bash
   # Edit the cluster-secrets Secret
   # Change DEFAULT_POSTGRES_HOST from "default-postgres" to "default-postgres-cnpg-rw"
   ```

6. **Scale up applications:**
   ```bash
   kubectl scale deployment -n default paperless --replicas=1
   kubectl scale deployment -n default radarr --replicas=1
   kubectl scale deployment -n default sonarr --replicas=1
   ```

7. **Watch init containers create databases:**
   ```bash
   # Watch paperless init container
   kubectl logs -n default -l app.kubernetes.io/name=paperless -c init-postgres -f

   # It should connect to default-postgres-cnpg-rw and create databases/users!
   ```

8. **Verify applications are healthy:**
   ```bash
   kubectl get pods -n default
   kubectl logs -n default -l app.kubernetes.io/name=paperless

   # Test applications via browser
   ```

### Phase 4: Migrate security-postgres (60 minutes)

**Applications using security-postgres:**
- authentik
- vaultwarden
- crowdsec

1. **Scale down applications:**
   ```bash
   kubectl scale deployment -n security authentik-server --replicas=0
   kubectl scale deployment -n security authentik-worker --replicas=0
   kubectl scale deployment -n security vaultwarden --replicas=0
   kubectl scale deployment -n security crowdsec --replicas=0
   ```

2. **Create final backup:**
   ```bash
   OLD_POD=$(kubectl get pod -n security -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=security-postgres -o jsonpath='{.items[0].metadata.name}')

   kubectl exec -n security $OLD_POD -- bash -c "PGPASSWORD=\${POSTGRES_PASSWORD} pg_dumpall -U securityuser" > /tmp/postgres-migration/security-postgres-$(date +%Y%m%d_%H%M%S).sql

   # Verify backup
   grep -c "PostgreSQL database dump complete" /tmp/postgres-migration/security-postgres-*.sql
   ```

3. **Restore to CloudNativePG:**
   ```bash
   NEW_POD=$(kubectl get pod -n security -l cnpg.io/cluster=security-postgres-cnpg,role=primary -o jsonpath='{.items[0].metadata.name}')

   POSTGRES_PASSWORD=$(kubectl get secret -n security security-postgres-cnpg-superuser -o jsonpath='{.data.password}' | base64 -d)

   cat /tmp/postgres-migration/security-postgres-*.sql | kubectl exec -i -n security $NEW_POD -- \
       bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -U postgres"
   ```

4. **Verify restored data:**
   ```bash
   kubectl exec -n security $NEW_POD -- psql -U postgres -c "\l"
   ```

5. **Update application configurations:**

   **Authentik:** `clusters/building-blocks/security/apps/authentik/app/helm-values.yaml:16`
   ```yaml
   # Update SECURITY_POSTGRES_HOST in init secret or helm values
   host: security-postgres-cnpg-rw
   ```

   **Authentik init secret:** `clusters/building-blocks/security/apps/authentik/app/authentik-init-secret-env.yaml`
   ```yaml
   PGHOST: security-postgres-cnpg-rw
   ```

   **Vaultwarden** and **CrowdSec:** Update similarly

   **Important:** Update your `cluster-secrets` if `SECURITY_POSTGRES_HOST` is defined there:
   ```bash
   # Change SECURITY_POSTGRES_HOST from "security-postgres" to "security-postgres-cnpg-rw"
   ```

6. **Scale up applications:**
   ```bash
   kubectl scale deployment -n security authentik-server --replicas=1
   kubectl scale deployment -n security authentik-worker --replicas=1
   kubectl scale deployment -n security vaultwarden --replicas=1
   kubectl scale deployment -n security crowdsec --replicas=1
   ```

7. **Watch init containers:**
   ```bash
   kubectl logs -n security -l app.kubernetes.io/name=authentik -c init-postgres -f
   ```

8. **Verify applications:**
   - Test Authentik login
   - Test Vaultwarden access
   - Check CrowdSec logs

### Phase 5: Update Backup Cronjobs (30 minutes)

Your PBS backup cronjobs need to point to the new clusters:

1. **Update default-postgres-backup cronjob:**
   `clusters/building-blocks/backup/apps/default-postgres-backup/app/default-postgres-backup-secret.yaml`
   ```yaml
   # Change connection details to point to new cluster
   POSTGRES_HOST: default-postgres-cnpg-rw
   ```

2. **Update security-postgres-backup cronjob:**
   `clusters/building-blocks/backup/apps/security-postgres-backup/app/security-postgres-backup-secret.yaml`
   ```yaml
   # Change connection details
   POSTGRES_HOST: security-postgres-cnpg-rw
   ```

3. **Test backups manually:**
   ```bash
   # Trigger backup job manually
   kubectl create job -n default --from=cronjob/default-postgres-backup test-backup-$(date +%s)

   # Watch logs
   kubectl logs -n default -l job-name=test-backup-xxxxx -f
   ```

### Phase 6: Cleanup Old Bitnami Clusters (Wait 7 days)

**DO NOT rush this step!** Keep old clusters for at least a week.

After verifying everything works for 7 days:

1. **Remove from kustomization:**
   Edit `clusters/building-blocks/persistency/apps/kustomization.yaml`:
   ```yaml
   # Comment out or remove:
   # - ./default-postgres/ks.yaml
   # - ./security-postgres/ks.yaml
   ```

2. **Delete HelmReleases:**
   ```bash
   kubectl delete helmrelease -n default default-postgres
   kubectl delete helmrelease -n security security-postgres
   ```

3. **Delete PVCs (after final PBS backup!):**
   ```bash
   # Create final PBS backup first!
   kubectl delete pvc -n default default-postgres-pvc
   kubectl delete pvc -n security security-postgres-pvc
   ```

4. **Remove Bitnami repository (optional):**
   ```bash
   # Remove clusters/building-blocks/base/repos/bitnami-postgressql.yaml if not used elsewhere
   ```

## Rollback Procedure

If issues occur during migration:

### Before Application Updates
If problems occur before updating applications:
1. Applications still point to old Bitnami clusters - just abort migration
2. Old data is intact in Bitnami PostgreSQL
3. Delete new CloudNativePG clusters: `kubectl delete cluster <name>`

### After Application Updates
If applications are updated but not working:
1. Scale down applications
2. Revert application configurations to old hostnames
3. Scale up applications
4. Investigate issues with CloudNativePG
5. Retry migration when ready

### Data Corruption
1. Stop all applications
2. Delete CloudNativePG clusters
3. Restore from PBS backups to Bitnami PostgreSQL
4. Verify data integrity
5. Start applications

## Post-Migration Tasks

- [ ] Monitor CloudNativePG clusters for 7 days
- [ ] Verify PBS backups are working
- [ ] Test application functionality thoroughly
- [ ] Document any issues encountered
- [ ] Enable CloudNativePG native backups (optional)
- [ ] Consider enabling monitoring/PodMonitor
- [ ] Update runbooks with new procedures
- [ ] Clean up old Bitnami resources (after 7 days)

## CloudNativePG Services

Each cluster creates several services:

### Read-Write Service (Primary)
- Name: `<cluster-name>-rw`
- Use for: Application connections, init containers
- Points to: Primary PostgreSQL instance

### Read-Only Service (Replicas)
- Name: `<cluster-name>-ro`
- Use for: Read-only queries (only if you scale to multiple instances)
- Points to: Replica instances

### Read Service (Any)
- Name: `<cluster-name>-r`
- Use for: Read queries from any instance
- Points to: All instances

**For single-instance homelab:** Only use `-rw` service.

## Monitoring

### Check Cluster Status
```bash
# List clusters
kubectl get clusters -A

# Describe cluster
kubectl describe cluster -n default default-postgres-cnpg

# Check pods
kubectl get pods -n default -l cnpg.io/cluster=default-postgres-cnpg
```

### Check Logs
```bash
# Operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg

# Cluster logs
kubectl logs -n default default-postgres-cnpg-1
```

### Database Commands
```bash
# Connect to database
kubectl exec -it -n default default-postgres-cnpg-1 -- psql -U postgres

# List databases
kubectl exec -n default default-postgres-cnpg-1 -- psql -U postgres -c "\l"

# List users
kubectl exec -n default default-postgres-cnpg-1 -- psql -U postgres -c "\du"
```

## Troubleshooting

### Cluster Won't Start
```bash
# Check operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --tail=100

# Check cluster events
kubectl describe cluster -n default default-postgres-cnpg

# Check pod events
kubectl describe pod -n default default-postgres-cnpg-1
```

### Init Container Fails
```bash
# Check init container logs
kubectl logs -n default <pod-name> -c init-postgres

# Common issues:
# - Wrong hostname (should be <cluster-name>-rw)
# - Missing superuser secret
# - Network policy blocking connection
```

### Connection Refused
```bash
# Verify service exists
kubectl get svc -n default default-postgres-cnpg-rw

# Test connection from another pod
kubectl run -it --rm debug --image=postgres:16 --restart=Never -- \
    psql -h default-postgres-cnpg-rw.default.svc.cluster.local -U postgres
```

### Restore Fails
```bash
# Check disk space
kubectl exec -n default default-postgres-cnpg-1 -- df -h

# Check PostgreSQL logs
kubectl logs -n default default-postgres-cnpg-1 --tail=100

# Try restore in smaller chunks
# Split SQL file and restore incrementally
```

## Important Notes

1. **Init Containers Work Unchanged:** Your existing pattern of using init containers to create databases and users works perfectly with CloudNativePG. No changes to init container logic needed!

2. **Superuser Access:** CloudNativePG manages the postgres superuser password automatically. Access it via: `kubectl get secret <cluster-name>-superuser`

3. **Application Users:** Init containers create application-specific users (paperless, authentik, etc.) - CloudNativePG manages these transparently.

4. **Single Instance:** For homelab use, single instance is fine. CloudNativePG still provides better management than Bitnami.

5. **Backups:** Your PBS cronjobs will continue to work - just update the hostname to `<cluster-name>-rw`.

6. **No Downtime Needed Later:** Once migrated, CloudNativePG supports rolling updates with zero downtime (even for single instance).

## Support

- CloudNativePG Docs: https://cloudnative-pg.io/documentation/
- Slack: #cloudnativepg on Kubernetes Slack
- GitHub: https://github.com/cloudnative-pg/cloudnative-pg

## Migration Completion

Once migration is complete and verified:
- Update this document with any lessons learned
- Document actual migration time
- Note any issues encountered
- Update disaster recovery procedures
