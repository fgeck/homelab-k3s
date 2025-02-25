# Homelab-K3S

## Setup & Explanation

This repository is the deployment entity for a homelab Kubernetes setup. It mainly relies und [FluxCD](https://fluxcd.io/flux/) to deploy the Helmreleases, Kubernetes Manifests and Kustomizations located in [clusters/building-blocks](./clusters/building-blocks). For templating secret values a dedicated secrets repository is used where the sops-age encoded secrets are stored. Flux syncs the resources defined in [bootstrap/flux-ks.yaml](./bootstrap/flux-ks.yaml) from this git repository defined in [bootstrap/flux-gitrepository.yaml](./bootstrap/flux-gitrepository.yaml) with the cluster in which flux is deployed.

The resources to be deployed in this repository expect an empty cluster. CNI will be deployed via Cilium and DNS via CoreDNS. Once flux takes over local-path-provisioner is used to provide dynamic storage handling for local volumes.
To initially bootstrap the cluster a helmfile is used.Once flux is running all resources will be synced by flux and flux will take over the lifecycle management.

To automate reoccurring tasks some [taskfiles](https://taskfile.dev/) were created. To see all available commands just enter `task`.

## Deployed

- [x] [Webhook from github to flux](https://fluxcd.io/flux/guides/webhook-receivers/)
- [x] [Cilium](https://docs.cilium.io/)
- [x] [CoreDNS](https://coredns.io/)
- [x] [FluxCD](https://fluxcd.io/flux/)
- [x] [Local-Path-Provisioner](https://github.com/rancher/local-path-provisioner)
- [x] [Cert-Manager](https://cert-manager.io/)
- [x] [Fritzbox-Cloudflare-DynDNS](https://github.com/cromefire/fritzbox-cloudflare-dyndns)
- [x] [Cloudflare-Tunnel](https://developers.cloudflare.com/cloudflare-one/tutorials/many-cfd-one-tunnel/)
- [x] [Traefik](https://doc.traefik.io/)
- [x] [Redis](https://github.com/bitnami/charts/tree/main/bitnami/redis)
- [x] [Security-Postgres](https://github.com/bitnami/charts/tree/main/bitnami/postgresql) for all security related deployments to use
- [x] [Default-Postgres](https://github.com/bitnami/charts/tree/main/bitnami/postgresql) for all other deployments to use
- [x] [Authentik](https://github.com/goauthentik/helm)
- [x] [Crowdsec](https://github.com/crowdsecurity/helm-charts)
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

Renovate is taking care of updating the deployed releases.

## Todo

- [ ] Traefik use IP of VM instead of Cilium's L2 Announcement 
- [ ] [Reloader](https://github.com/stakater/Reloader)
- [ ]Cloudflare to route all traffic to Traefik
- [ ] [configarr](https://github.com/raydak-labs/configarr)
- [ ] [ICloud Photo Dump](https://github.com/boredazfcuk/docker-icloudpd) as a cronJob
- [ ] [crowdsec traefik bouncer](https://www.crowdsec.net/blog/how-to-mitigate-security-threats-with-crowdsec-and-traefik)
- [ ] monitoring: signoz / Grafana LGTM Stack
- [ ] [Immich](https://github.com/immich-app/immich-charts)

