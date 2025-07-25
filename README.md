# Homelab-K3S

## Setup & Explanation

This repository serves as the deployment entity for a homelab Kubernetes setup, utilizing [FluxCD](https://fluxcd.io/flux/) to manage the Helm releases, Kubernetes Manifests, and Kustomizations located in [clusters/building-blocks](./clusters/building-blocks). For templating secret values, a dedicated secrets repository is employed where sops-age encoded secrets are stored. Flux synchronizes the resources specified in [bootstrap/flux-ks.yaml](./bootstrap/flux-ks.yaml) from this Git repository, as defined in [bootstrap/flux-gitrepository.yaml](./bootstrap/flux-gitrepository.yaml), with the cluster where Flux is deployed.

The resources intended for deployment in this repository expect an empty cluster. CNI will be deployed using Cilium, and DNS will be managed by CoreDNS. Once Flux takes control, the local-path-provisioner will be deployed to offer dynamic storage management for local volumes. For initial cluster bootstrapping, a helmfile is utilized. Once Flux is operational, it will synchronize all resources and assume lifecycle management responsibilities.

To facilitate the automation of recurring tasks, several [taskfiles](https://taskfile.dev/) have been created. To view all available commands, simply enter `task`.

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
- [x] Traefik use IP of VM instead of Cilium's L2 Announcement ([Cilium Node IPAM LB](https://docs.cilium.io/en/latest/network/node-ipam/#node-ipam-lb))
- [x] [Crowdsec traefik bouncer](https://www.crowdsec.net/blog/how-to-mitigate-security-threats-with-crowdsec-and-traefik)
- [x] [Crowdsec IP Tables Bouncer](https://docs.crowdsec.net/u/bouncers/firewall/#iptables) as I prefer Firewall based blocking over blocking in Reverse Proxy
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
- [x] [Sonarr](https://sonarr.tv/)
- [x] [Configarr](https://github.com/raydak-labs/configarr)
- [x] [Sabnzbd](https://sabnzbd.org/)
- [x] [karakeep](https://docs.karakeep.app/)
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
- [ ] [Immich](https://github.com/immich-app/immich-charts)
- [x] Monitoring - currently not deployed
  - [x] [InfluxDB2](https://github.com/influxdata/helm-charts/blob/master/charts/influxdb2/values.yaml) incl. user setup scripts
  - [x] [Telegraf](https://github.com/influxdata/helm-charts/blob/master/charts/telegraf/values.yaml)
  - [x] [Grafana](https://github.com/grafana/helm-charts) for visualization
  - [x] [Grafana-Alloy](https://github.com/grafana/alloy/blob/main/operations/helm/charts/alloy/values.yaml)
  - [x][Prometheus](https://github.com/prometheus-community/helm-charts/blob/main/charts/prometheus/values.yaml)