# Re-Authenticate

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
