# Repository Guide for Codex

Use this file as the first stop before scanning the repo. This is a Flux-managed K3s homelab repository. Most work is Kubernetes YAML under `clusters/building-blocks`.

## Architecture

- `README.md` explains the homelab and the deployed services.
- `clusters/homelab-k3s/kustomization.yaml` loads `cluster.yaml`.
- `clusters/homelab-k3s/cluster.yaml` defines the top-level Flux `Kustomization` graph:
  - `namespaces`
  - `repos`
  - `base-apps`
  - `edge`
  - `persistency`
  - `security`
  - `monitoring`
  - `media`
  - `other`
  - `backup`
- App implementations live under:
  - `clusters/building-blocks/base/apps`
  - `clusters/building-blocks/edge/apps`
  - `clusters/building-blocks/persistency/apps`
  - `clusters/building-blocks/security/apps`
  - `clusters/building-blocks/monitoring/apps`
  - `clusters/building-blocks/media/apps`
  - `clusters/building-blocks/other/apps`
  - `clusters/building-blocks/backup/apps`
- Each category has an `apps/kustomization.yaml` that opts apps into deployment by listing `./<app>/ks.yaml`.
- Each app normally has:
  - `<app>/ks.yaml`: Flux `Kustomization` object in namespace `flux-system`.
  - `<app>/app/kustomization.yaml`: Kustomize resources for the app.
  - `<app>/app/*.yaml`: Kubernetes resources or Flux `HelmRelease` resources.

## Fast Orientation

When adding or changing an app, do not rescan everything. Start with:

```sh
rg --files clusters/building-blocks/<category>/apps
sed -n '1,220p' clusters/building-blocks/<category>/apps/kustomization.yaml
sed -n '1,220p' clusters/building-blocks/<category>/apps/<similar-app>/ks.yaml
sed -n '1,220p' clusters/building-blocks/<category>/apps/<similar-app>/app/kustomization.yaml
```

Pick a similar app in the same category and copy its conventions.

Good plain-manifest examples:

- `clusters/building-blocks/other/apps/better-bahn`
- `clusters/building-blocks/media/apps/radarr`
- `clusters/building-blocks/security/apps/vaultwarden`

Good HelmRelease examples:

- `clusters/building-blocks/other/apps/homepage`
- `clusters/building-blocks/other/apps/meilisearch`
- `clusters/building-blocks/media/apps/immich`
- `clusters/building-blocks/edge/apps/traefik`

## Adding a New Deployment

1. Choose the category by runtime purpose:
   - `base`: cluster foundations like CNI, DNS, Flux, storage provisioners, repos.
   - `edge`: ingress, certificates, tunnels, external DNS or gateway-facing pieces.
   - `persistency`: database and storage services.
   - `security`: auth, password management, security tooling.
   - `monitoring`: observability services.
   - `media`: media stack and media automation.
   - `other`: general apps in the `default` namespace.
   - `backup`: backup CronJobs and related secrets/config.
2. Create `clusters/building-blocks/<category>/apps/<app>/ks.yaml`.
3. Create `clusters/building-blocks/<category>/apps/<app>/app/kustomization.yaml`.
4. Add the app resources in the `app/` directory.
5. Register the app by adding `- ./<app>/ks.yaml` to `clusters/building-blocks/<category>/apps/kustomization.yaml`.
6. If the app uses a Helm chart from a new repository, add a `HelmRepository` in `clusters/building-blocks/base/repos/<repo>.yaml` and list it in `clusters/building-blocks/base/repos/kustomization.yaml`.
7. Validate locally with `task cluster:validate` or `./scripts/validate.sh`.

## Flux Kustomization Pattern

Use this shape for most app-level `ks.yaml` files:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/kustomization-kustomize-v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app app-name
  namespace: flux-system
spec:
  targetNamespace: default
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./clusters/building-blocks/<category>/apps/app-name/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: false
  interval: 30m
  timeout: 5m
```

Use the real namespace for `targetNamespace` and resource `metadata.namespace`. Existing namespaces are declared in `clusters/building-blocks/base/namespaces`.

Some infrastructure apps define multiple Flux `Kustomization` objects in one `ks.yaml` and use `dependsOn`; follow those local examples when adding staged config such as app, config, certs, or issuers.

## Plain Manifest App Pattern

For non-Helm apps, use explicit manifests:

- `deployment.yaml` or `<app>-deploy.yaml`
- `service.yaml` or `<app>-svc.yaml`
- `ingressroute.yaml` or `<app>-ingressroute.yaml` when exposed
- `<app>-pvc.yaml` when local persistent state is needed
- `<app>-secret.yaml` only for templated/SOPS-managed secrets
- optional ConfigMaps or CronJobs as needed

Kustomize should list every file explicitly:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingressroute.yaml
```

## HelmRelease App Pattern

For Helm apps, existing convention is:

- `helmrelease.yaml` or `<app>.yaml`
- `helm-values.yaml`
- `kustomizeconfig.yaml`
- `app/kustomization.yaml` with `configMapGenerator`

Example `app/kustomization.yaml` shape:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
configMapGenerator:
  - name: app-name-helm-values
    namespace: default
    files:
      - values.yaml=./helm-values.yaml
configurations:
  - kustomizeconfig.yaml
```

Use `kustomizeconfig.yaml` to make Kustomize rewrite `spec/valuesFrom/name` on `HelmRelease` objects:

```yaml
---
nameReference:
  - kind: ConfigMap
    version: v1
    fieldSpecs:
      - path: spec/valuesFrom/name
        kind: HelmRelease
```

HelmRelease values usually come from the generated ConfigMap:

```yaml
valuesFrom:
  - kind: ConfigMap
    name: app-name-helm-values
```

## Ingress Conventions

- Ingress uses Traefik `IngressRoute` resources from `traefik.io/v1alpha1`.
- Typical entry points are both `websecure` and `web`.
- Internal hostnames commonly use ``Host(`<name>.home.${DOMAIN_NAME}`)``.
- Public hostnames omit `.home`, for example ``Host(`photos.${DOMAIN_NAME}`)``.
- Common middlewares live in `clusters/building-blocks/edge/apps/traefik/config`:
  - `local-ipallowlist`
  - `gateway-only-ipallowlist`
  - `pocket-id-oidc`
  - `websocket`
  - `ssl-header`
- Reference middleware with `namespace: edge` unless following a specific existing exception.

## Secrets and Substitution

- Top-level category Flux `Kustomization` objects apply SOPS decryption and `postBuild.substituteFrom` using the `cluster-secrets` Secret.
- Secrets in this repo are YAML with `${VARIABLE}` placeholders, often quoted via `${quote}`.
- `.sops.yaml` encrypts `data` and `stringData` fields for YAML files and encrypts files matching `*values.yaml`.
- Do not commit plaintext secret values. Add placeholders and rely on the secrets repo / `cluster-secrets`.
- Secret helper tasks:
  - `task fetch-secrets-vault`
  - `task push-secrets-vault`

## Storage Conventions

- App-local state normally uses `storageClassName: local-path` and `ReadWriteOnce`.
- Shared media/document data uses static NFS PV/PVCs in `clusters/building-blocks/media/apps/shared`.
- Reuse existing shared PVCs such as `pvc-nfs-media`, `pvc-nfs-photos`, `pvc-nfs-books`, or `pvc-nfs-documents` when appropriate.
- Stateful single-replica apps commonly use `strategy.type: Recreate`.

## Pod Defaults

Prefer the existing hardening defaults when the image supports them:

- `runAsNonRoot: true`
- app user/group usually `1000`
- `allowPrivilegeEscalation: false`
- drop all Linux capabilities
- `seccompProfile.type: RuntimeDefault`
- add readiness/liveness/startup probes for HTTP apps
- set `TZ` to `Europe/Berlin`
- keep CPU/memory requests modest and set practical limits

Some media apps use `fsGroup: 3004` for shared media permissions. Match the closest existing app before choosing IDs.

## Formatting and Validation

- YAML files start with `---` and usually include `yaml-language-server` schema comments.
- Formatting is controlled by `.yamlfmt.yaml`; pre-commit runs `yamlfmt` on staged YAML.
- Validate with:

```sh
task cluster:validate
```

or:

```sh
./scripts/validate.sh
```

The validation script requires `yq`, `kustomize`, and `kubeconform`; it downloads Flux CRD schemas into `/tmp/flux-crd-schemas` and skips Kubernetes Secrets during kubeconform validation.

## Operational Tasks

- `task` lists available tasks.
- `task k3s:install` installs single-node K3s using `config.yaml` and bootstrapping files.
- `task cluster:bootstrap` creates Flux/SOPS secrets, runs `bootstrap/helmfile.yaml`, and applies the initial Flux resources.
- `task cluster:flux-reconcile` forces Flux to reconcile the secrets and main repo sources.

Do not run cluster-modifying tasks unless explicitly requested.
