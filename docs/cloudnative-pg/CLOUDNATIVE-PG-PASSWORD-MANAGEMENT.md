# CloudNativePG Password Management Options

## Summary

CloudNativePG creates roles **WITHOUT passwords** by default. You have two options for password management:

## Option 1: Init Containers (Recommended - Current Approach)

**Keep your existing pattern** - this is best practice!

### How It Works

```
CloudNativePG (creates role)
    ↓
Role exists WITHOUT password
    ↓
Init container runs
    ↓
Sets password from your existing secret
    ↓
Application connects with credentials
```

### Your Current Setup

**Secrets already exist:**
```yaml
# For paperless
DEFAULT_POSTGRES_PAPERLESS_USER: paperless
DEFAULT_POSTGRES_PAPERLESS_USER_PASSWORD: <password>

# For radarr
DEFAULT_POSTGRES_RADARR_USER: radarr
DEFAULT_POSTGRES_RADARR_USER_PASSWORD: <password>

# Similar for sonarr, authentik, vaultwarden, crowdsec
```

**Init containers already set passwords:**
```bash
# Init container runs and sets password
psql -c "ALTER USER paperless WITH PASSWORD '$PAPERLESS_PASSWORD';"
```

**Applications already use credentials:**
```yaml
# Paperless connects
DATABASE_URL: postgresql://paperless:${PASSWORD}@default-postgres-cnpg-rw/paperless
```

### Why This Is Best

✅ **Flexible**: Works with any secret management (SOPS, Vault, sealed-secrets)
✅ **Secure**: Passwords stored in Kubernetes secrets, not manifests
✅ **No changes**: Your existing setup already does this
✅ **Simple**: CloudNativePG just creates structure, you handle credentials

### Recommendation

**Keep this approach!** Just update the `PGHOST` in your secrets to point to CloudNativePG:
- `DEFAULT_POSTGRES_HOST: default-postgres-cnpg-rw`
- `SECURITY_POSTGRES_HOST: security-postgres-cnpg-rw`

Everything else works as-is.

---

## Option 2: CloudNativePG Password Secrets

CloudNativePG can manage passwords via `passwordSecret` references.

### How It Works

```
You create kubernetes.io/basic-auth secret
    ↓
CloudNativePG creates role
    ↓
CloudNativePG sets password from secret
    ↓
Application connects with credentials
```

### Implementation

#### Step 1: Create Password Secrets

For each application user, create a `kubernetes.io/basic-auth` secret:

**Paperless:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: default-postgres-cnpg-paperless-password
  namespace: default
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: paperless
  password: ${DEFAULT_POSTGRES_PAPERLESS_USER_PASSWORD}
```

**Radarr:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: default-postgres-cnpg-radarr-password
  namespace: default
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: radarr
  password: ${DEFAULT_POSTGRES_RADARR_USER_PASSWORD}
```

Repeat for sonarr, authentik, vaultwarden, crowdsec...

#### Step 2: Update Helm Values

**default-postgres-cnpg/app/helm-values.yaml:**
```yaml
cluster:
  roles:
    - name: paperless
      ensure: present
      login: true
      comment: "Paperless-ngx application user"
      passwordSecret:
        name: default-postgres-cnpg-paperless-password

    - name: radarr
      ensure: present
      login: true
      comment: "Radarr application user"
      passwordSecret:
        name: default-postgres-cnpg-radarr-password

    - name: sonarr
      ensure: present
      login: true
      comment: "Sonarr application user"
      passwordSecret:
        name: default-postgres-cnpg-sonarr-password
```

#### Step 3: Remove Init Containers

Since CloudNativePG manages passwords, you can remove the database init logic:

**Before (with init container):**
```yaml
initContainers:
  - name: init-postgres
    image: bitnami/postgresql:17.6.0
    envFrom:
      - secretRef:
          name: paperless-init-db
    command: ["/bin/sh", "-c"]
    args:
      - |
        # Complex bash script...
```

**After (no init container needed):**
```yaml
# No init container needed!
# CloudNativePG already created everything
```

#### Step 4: Applications Reference Same Secrets

Your applications still use the same credentials:

**Paperless:**
```yaml
env:
  - name: PAPERLESS_DBUSER
    valueFrom:
      secretKeyRef:
        name: default-postgres-cnpg-paperless-password
        key: username
  - name: PAPERLESS_DBPASS
    valueFrom:
      secretKeyRef:
        name: default-postgres-cnpg-paperless-password
        key: password
  - name: PAPERLESS_DBHOST
    value: default-postgres-cnpg-rw
```

### Why You Might Want This

✅ **No init containers**: CloudNativePG handles everything
✅ **Kubernetes-native**: Uses standard `basic-auth` secrets
✅ **Automatic reconciliation**: Password changes propagate automatically
✅ **Cleaner**: Pure declarative approach

### Why You Might NOT Want This

❌ **More secrets to create**: 8 new secrets (3 for default, 3 for security, plus extras)
❌ **Duplicated passwords**: Same password in two secrets (cluster-secrets + passwordSecret)
❌ **More complexity**: Additional secret management
❌ **Application changes**: Need to update all apps to reference new secrets

---

## Comparison

| Aspect | Option 1: Init Containers | Option 2: CloudNativePG Secrets |
|--------|---------------------------|----------------------------------|
| **Complexity** | Simple - existing setup | More complex - new secrets |
| **Secret Count** | Current count | +8 new secrets |
| **Init Containers** | Keep existing | Can remove |
| **App Changes** | None | Update all apps |
| **Password Source** | cluster-secrets | Per-user secrets |
| **Migration Effort** | Zero | High |
| **Recommended** | ✅ Yes | Only if starting fresh |

---

## Recommendation: Stick with Option 1

### Why

1. **Zero changes needed**: Your current setup already works
2. **Less secrets**: Don't need to duplicate passwords
3. **Flexible**: Works with any secret backend
4. **Simple**: Init containers are well-understood
5. **Migration friendly**: No refactoring during migration

### What You Need to Do

**Just update these values in `cluster-secrets`:**

```yaml
# Old
DEFAULT_POSTGRES_HOST: default-postgres
SECURITY_POSTGRES_HOST: security-postgres

# New
DEFAULT_POSTGRES_HOST: default-postgres-cnpg-rw
SECURITY_POSTGRES_HOST: security-postgres-cnpg-rw
```

That's it! Everything else works unchanged:
- ✅ CloudNativePG creates roles and databases declaratively
- ✅ Init containers set passwords from existing secrets
- ✅ Applications connect using existing credentials
- ✅ No application changes needed

---

## If You Want to Switch to Option 2 Later

You can always migrate from init containers to CloudNativePG password secrets later:

1. Create the `passwordSecret` secrets
2. Add `passwordSecret` references to helm-values
3. Remove init container logic
4. Update applications to use new secret references

But there's **no rush** - init containers work perfectly with CloudNativePG!

---

## The Hybrid Approach (What You're Using)

Your setup uses the best of both worlds:

```
┌─────────────────────────────────────────────────────────┐
│ CloudNativePG (Declarative)                             │
├─────────────────────────────────────────────────────────┤
│ • Creates roles (paperless, radarr, sonarr, etc.)       │
│ • Creates databases with correct owners                 │
│ • Manages structure in GitOps                           │
│ • Continuously reconciles existence                     │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ Init Containers (Imperative)                            │
├─────────────────────────────────────────────────────────┤
│ • Wait for PostgreSQL availability                      │
│ • Set passwords from cluster-secrets                    │
│ • Grant fine-grained permissions                        │
│ • One-time setup per pod                                │
└─────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────┐
│ Applications                                            │
├─────────────────────────────────────────────────────────┤
│ • Connect with credentials from cluster-secrets         │
│ • Use databases created by CloudNativePG                │
│ • Work exactly as before                                │
└─────────────────────────────────────────────────────────┘
```

**This is professional, maintainable, and requires zero changes!** ✅
