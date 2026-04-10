# iCloud to Immich

## icloudpd — Re-Authenticate

```bash
kubectl run icloudpd-auth -it --rm -n media \
  --image=icloudpd/icloudpd:latest \
  --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "icloudpd-auth",
        "image": "icloudpd/icloudpd:latest",
        "stdin": true,
        "tty": true,
        "args": ["icloudpd", "--username", "MY_USER", "--cookie-directory", "/config", "--auth-only"],
        "volumeMounts": [{"name": "config", "mountPath": "/config"}]
      }],
      "volumes": [{"name": "config", "persistentVolumeClaim": {"claimName": "icloudpd-config-pvc"}}]
    }
  }'
```

https://github.com/icloud-photos-downloader/icloud_photos_downloader/issues/1322

---

## kei — Initial Login / Re-Authenticate

kei stores its session in the `kei-config-pvc` volume (`/config`). On first run or after session expiry, authenticate interactively:

```bash
kubectl run kei-auth -it --rm -n media \
  --image=ghcr.io/rhoopr/kei:latest \
  --restart=Never \
  --overrides='{
    "spec": {
      "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
      "containers": [{
        "name": "kei-auth",
        "image": "ghcr.io/rhoopr/kei:latest",
        "stdin": true,
        "tty": true,
        "args": ["login", "--username", "MY_USER@icloud.com", "--data-dir", "/config"],
        "volumeMounts": [{"name": "config", "mountPath": "/config"}]
      }],
      "volumes": [{"name": "config", "persistentVolumeClaim": {"claimName": "kei-config-pvc"}}]
    }
  }'
```

After `kei login` completes (password + 2FA approved on a trusted device), the session is persisted to the PVC and the CronJob will authenticate automatically on subsequent runs.

### Headless 2FA (if session expires while kei is running)

kei fires a Telegram notification on the `2fa_required` event. To submit a code non-interactively:

```bash
kubectl run kei-2fa -it --rm -n media \
  --image=ghcr.io/rhoopr/kei:latest \
  --restart=Never \
  --overrides='{
    "spec": {
      "securityContext": {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000},
      "containers": [{
        "name": "kei-2fa",
        "image": "ghcr.io/rhoopr/kei:latest",
        "stdin": true,
        "tty": true,
        "args": ["login", "submit-code", "123456", "--username", "MY_USER@icloud.com", "--data-dir", "/config"],
        "volumeMounts": [{"name": "config", "mountPath": "/config"}]
      }],
      "volumes": [{"name": "config", "persistentVolumeClaim": {"claimName": "kei-config-pvc"}}]
    }
  }'
```

Replace `123456` with the code from your trusted device.

### Switching from icloudpd to kei

1. Enable kei resources in `kustomization.yaml` (uncomment the three kei lines)
2. Run `kei login` as above to initialize the session
3. Verify the next CronJob run succeeds
4. Disable icloudpd resources in `kustomization.yaml` (comment out the three icloudpd lines)
5. Delete the `icloudpd-download` CronJob from the cluster: `kubectl delete cronjob icloudpd-download -n media`
