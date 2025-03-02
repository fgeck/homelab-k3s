# Homelab-K3S

## Setup & Explanation

This repository is the deployment entity for a homelab Kubernetes setup. It mainly relies und [FluxCD](https://fluxcd.io/flux/) to deploy the Helmreleases, Kubernetes Manifests and Kustomizations located in [clusters/building-blocks](./clusters/building-blocks). For templating secret values a dedicated secrets repository is used where the sops-age encoded secrets are stored. Flux syncs the resources defined in [bootstrap/flux-ks.yaml](./bootstrap/flux-ks.yaml) from this git repository defined in [bootstrap/flux-gitrepository.yaml](./bootstrap/flux-gitrepository.yaml) with the cluster in which flux is deployed.

The resources to be deployed in this repository expect an empty cluster. CNI will be deployed via Cilium and DNS via CoreDNS. Once flux takes over local-path-provisioner is used to provide dynamic storage handling for local volumes.
To initially bootstrap the cluster a helmfile is used. Once flux is running all resources will be synced by flux and flux will take over the lifecycle management.

To automate reoccurring tasks some [taskfiles](https://taskfile.dev/) were created. To see all available commands just enter `task`.

## Deployed

- [x] [Webhook from github to flux](https://fluxcd.io/flux/guides/webhook-receivers/)
- [x] [Cilium](https://docs.cilium.io/)
- [x] [CoreDNS](https://coredns.io/)
- [x] [FluxCD](https://fluxcd.io/flux/)
- [x] [Reloader](https://github.com/stakater/Reloader)
- [x] [Local-Path-Provisioner](https://github.com/rancher/local-path-provisioner)
- [x] [Cert-Manager](https://cert-manager.io/)
- [x] [Fritzbox-Cloudflare-DynDNS](https://github.com/cromefire/fritzbox-cloudflare-dyndns) *Currently inactive - external Services are exposed via Cloudflared*
- [x] [Cloudflared-Tunnel](https://developers.cloudflare.com/cloudflare-one/tutorials/many-cfd-one-tunnel/)
- [x] [Traefik](https://doc.traefik.io/)
- [x] [Redis](https://github.com/bitnami/charts/tree/main/bitnami/redis)
- [x] [Security-Postgres](https://github.com/bitnami/charts/tree/main/bitnami/postgresql) for all security related deployments to use
- [x] [Default-Postgres](https://github.com/bitnami/charts/tree/main/bitnami/postgresql) for all other deployments to use
- [x] [Authentik](https://github.com/goauthentik/helm)
- [x] [Crowdsec](https://github.com/crowdsecurity/helm-charts) *Currently inactive - Machine is not exposed to the internert, external Services are exposed via Cloudflared*
- [x] [Vaultwarden](https://github.com/guerzon/vaultwarden)
- [x] [Portainer](https://portainer.github.io/k8s/charts/portainer/)
- [x] [Uptime-Kuma](https://github.com/dirsigler/uptime-kuma-helm)
- [x] [Calibre-Web-Automated](https://github.com/crocodilestick/Calibre-Web-Automated)
- [x] [Jellyfin](https://jellyfin.org/)
- [x] [Jellyseerr](https://docs.jellyseerr.dev/)
- [x] [Radarr](https://radarr.video/)
- [x] [Readarr](https://readarr.com/)
- [x] [Sabnzbd](https://sabnzbd.org/)
- [x] [Sonarr](https://sonarr.tv/)
- [x] [Hoarder](https://docs.hoarder.app/)
- [x] [Homepage](https://gethomepage.dev/)
- [x] [Paperless-NGX](https://docs.paperless-ngx.com/)
- [x] [Samba](https://github.com/ServerContainers/samba)
- [x] [Spoolman](https://github.com/Donkie/Spoolman)
- [x] [ICloud Photo Downloader](https://github.com/boredazfcuk/docker-icloudpd) as a CronJob -- **Still untested**
- [x] [Obsidian](https://github.com/vrtmrz/obsidian-livesync)
- [x] Backups are done via CronJobs and can be found in a dedicated [building-block](https://github.com/fgeck/homelab-k3s/blob/main/clusters/building-blocks/backup/apps). All PVCs are backed up to Proxmox Backup Server using a single CronJob. Postgresql Databases are backed up to Proxmox Backup Server as well but the CronJob dumps the database first to a temp. directory and uploads this directory to PBS.

Renovate is taking care of updating the deployed releases.

## Todo

- [ ] Switch to docker image + scripts for PVC and Postgres backups to PBS
- [ ] Test and activate [ICloud Photo Downloader](https://github.com/fgeck/homelab-k3s/blob/main/clusters/building-blocks/media/apps/kustomization.yaml)
- [ ] [Configarr](https://github.com/raydak-labs/configarr)
- [ ] [Immich](https://github.com/immich-app/immich-charts)
- [ ] monitoring: signoz / Grafana LGTM Stack
- [ ] [Crowdsec traefik bouncer](https://www.crowdsec.net/blog/how-to-mitigate-security-threats-with-crowdsec-and-traefik)
- [ ] Traefik use IP of VM instead of Cilium's L2 Announcement
