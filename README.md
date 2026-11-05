# Deployment Repo

GitOps-managed Kubernetes stack for stackcraft. Git is the source of truth;
**Flux CD** watches this repo and reconciles the cluster to match it.

## How it works

1. `flux bootstrap` installs Flux's controllers into the cluster and points
   them at this repo (a specific branch + path under `clusters/`).
2. Flux's own `flux-system` Kustomization watches `clusters/<env>/`, which
   contains a set of Flux `Kustomization` objects — one per component.
3. Each `Kustomization` object points at a folder under `deployments/`,
   applies it into a target namespace, and can declare `dependsOn` so
   components come up in the right order.
4. `postBuild.substitute` lets the same manifest set under `deployments/`
   be reused across environments with different values injected per cluster
   (e.g. Infisical identity/project IDs, environment name).

### Reconciliation order (staging)

```text
namespaces
├── infra-postgres ─────┐
├── infra-redis ────────┼──> apps-infisical ───> apps-vaultwarden
├── tailscale-operator ─┼──> apps-immich
├── infra-cert-manager
├── infra-kubescape
├── infra-kyverno
├── infra-prometheus ────> infra-headlamp
└── infra-headlamp <─────┘
```

Postgres, Redis, and the Tailscale operator come up first. Infisical depends
on all three (it needs the DB and needs Tailscale ingress for its own
hostname). Vaultwarden depends on Infisical, since it fetches its admin token
from Infisical at startup. Immich depends on Postgres, Redis, and Tailscale.
Headlamp depends on Infisical, Prometheus, and Tailscale. cert-manager,
Kubescape, and Kyverno are independent cluster infrastructure services.
Kubescape enables continuous configuration and image-vulnerability scans,
but leaves node and runtime scanning disabled by default. Kyverno is installed
without any policy resources, so it will not block workloads; audit reports
require adding policies explicitly configured with `failureAction: Audit`.
Prometheus supplies seven days of local metric history to the Headlamp
Prometheus plugin; Grafana and Alertmanager are not installed.

## Folder layout

```text
.
├── .gitlab-ci.yml
├── .gitignore
├── .yamllint.yml
├── .trivyignore.yaml
├── Makefile
├── kind-config.yaml
├── README.md
├── clusters/
│   ├── staging/
│   │   ├── namespaces.yaml
│   │   ├── infra-postgres.yaml
│   │   ├── infra-redis.yaml
│   │   ├── infra-headlamp.yaml
│   │   ├── tailscale.yaml
│   │   ├── apps-infisical.yaml
│   │   ├── apps-vaultwarden.yaml
│   │   └── flux-system/
│   │       ├── gotk-components.yaml
│   │       ├── gotk-sync.yaml
│   │       └── kustomization.yaml
│   └── production/
│       └── (mirrors staging/, generated via `make bootstrap-flux`)
├── deployments/
│   ├── applications/ [namespace]
│   │   ├── infisical/
│   │   │   ├── bootstrap.yaml
│   │   │   ├── deployment.yaml
│   │   │   ├── ingress.yaml
│   │   │   ├── kustomization.yaml
│   │   │   ├── rbac.yaml
│   │   │   ├── script.hostname-discovery.yaml
│   │   │   ├── service.yaml
│   │   │   └── serviceaccount.yaml
│   │   └── vaultwarden/
│   │   └── immich/
│   │       ├── db-init.yaml
│   │       ├── deployment.yaml
│   │       ├── ingress.yaml
│   │       ├── kustomization.yaml
│   │       ├── machine-learning-deployment.yaml
│   │       ├── pvc.yaml
│   │       └── service.yaml
│   ├── infrastructure/ [namespace]
│   │   ├── cert-manager/ — certificate lifecycle controller and CRDs
│   │   ├── kubescape/ — continuous Kubernetes configuration and image scanning
│   │   ├── kyverno/ — Kubernetes policy engine; no policies installed by default
│   │   └── prometheus/ — single Prometheus server, kube-state-metrics, and node-exporter
│   └── tailscale/ [namespace]
│       ├── helmrelease.yaml
│       ├── helmrepository.yaml
│       └── kustomization.yaml
├── namespaces/
│   ├── applications.yaml
│   ├── infrastructure.yaml
│   └── tailscale.yaml
└── scripts/
    └── validate-flux-deps.py
```

## Main services

### Infrastructure (`infrastructure` namespace)

- **Postgres** — shared database for apps that need one.
- **Redis** — shared cache.
- **Headlamp** — Kubernetes dashboard, installed via HelmRelease, exposed
  through Tailscale ingress with a scoped exec/node-shell RBAC role. Includes
  the Flux and Prometheus plugins.
- **Prometheus** — one server per cluster, with persistent 4 GiB storage,
  seven-day retention, kube-state-metrics, and node-exporter. It also scrapes
  kubelet/cAdvisor metrics for pod CPU, memory, network, and filesystem charts.
  Grafana, Alertmanager, and Pushgateway are disabled. The Headlamp Prometheus
  plugin auto-discovers the service; after deployment, enable metrics under
  Headlamp Settings → Plugins → Prometheus for the selected cluster.
- **cert-manager** — certificate lifecycle controller, installed via its
  official OCI Helm chart. Issuers and certificate policies are configured
  separately for each cluster. This installs the controller in Kubernetes;
  it does not add packages to the NixOS host.
- **Kubescape** — continuous Kubernetes configuration and image-vulnerability
  scanning, surfaced through the Headlamp plugin. Persistent storage requires
  a default StorageClass and at least 5 GiB of available capacity. Node and
  runtime detections are disabled in the initial configuration (image SBOM
  generation remains enabled for vulnerability reporting); this installs the
  operator in Kubernetes, not on the NixOS host.
- **Kyverno** — Kubernetes policy engine with its Headlamp plugin for viewing
  policies, reports, and violations. The initial install includes no policy
  resources, so it cannot block workloads; add policies explicitly in audit
  mode before considering enforcement.
- **Tailscale operator** — provides the `tailscale` IngressClass used by
  every app/infra ingress in this repo instead of a public load balancer.

### Applications (`applications` namespace)

- **Infisical** — self-hosted secrets manager. Ships with a `bootstrap.yaml`
  Job that idempotently creates its Postgres role/database on first run.
- **Vaultwarden** — self-hosted password manager (Bitwarden-compatible).
  Fetches its own admin token from Infisical at pod startup via a
  Kubernetes-auth login (no static secret ever stored in the cluster for
  this token) — see `script.vaultwarden-bootstrap.yaml`.
- **Immich** — self-hosted photo and video management. Uses the shared
  PostgreSQL and Redis services, stores its media library on a persistent
  volume (5 GiB in staging, 60 GiB in production), and is exposed over
  Tailscale.

All applications are reachable only over Tailscale, never the public internet.

## Local production-network simulation

`kind-config.yaml` keeps the three-node production-shaped topology and reserves
the following addresses for an optional VIP simulation:

- `192.168.1.230` — kube-vip control-plane VIP
- `192.168.1.231-192.168.1.240` — MetalLB `LoadBalancer` Services

Install MetalLB and apply its pool with:

```sh
make setup-kind-lb
```

These addresses must be reachable on the Docker/Kind network. A normal Kind
Docker bridge does not advertise arbitrary `192.168.1.x` addresses onto the
physical LAN, so use a LAN-attached Docker network (or change the pool to an
unused subnet on the Docker bridge) before expecting clients outside Docker to
reach a `LoadBalancer` Service. The API continues to bootstrap through
`127.0.0.1:6443`; kube-vip can be layered on afterward when the Kind nodes share
the VIP-capable L2 network.

## Environments

- **staging** — tracks the `staging` branch, path `clusters/staging`.
- **production** — bootstrapped separately (`FLUX_PATH=clusters/production`,
  its own branch). Deployed in the same dependency order as staging, with
  Vaultwarden intentionally deployed last/after Infisical is confirmed
  healthy, since it depends on Infisical being reachable.

Per-environment values (Infisical identity ID, project ID, environment
name, etc.) are **not** hardcoded into `deployments/`. They're injected per
cluster via `postBuild.substitute` in each environment's
`clusters/<env>/apps-vaultwarden.yaml` / `apps-infisical.yaml`.

## Secrets

The manifests reference Kubernetes Secrets such as:

- `clustercreds-postgres`
- `clustercreds-infisical`
- `headlamp-admin-token`

These are expected to already exist in-cluster (created out-of-band, e.g.
via Reflector or manually) — they are never committed to this repo.

## Makefile targets

Run `make help` for the full list. Highlights:

| Target | Description |
|:---|:---|
| `bootstrap-flux` | Bootstraps Flux against this repo (`GITLAB_TOKEN` required; override `FLUX_PATH`/`GIT_BRANCH` per environment) |
| `setup-prerequisites` | Adds Helm repos, installs the Reflector controller |
| `reconcile-<tier>` | Forces Flux to reconcile a specific Kustomization now, e.g. `make reconcile-apps-infisical` |
| `status-flux` | Shows all Kustomizations, HelmReleases, and sources |
| `status-headlamp` / `creds-headlamp` | Inspect Headlamp / fetch its admin token |
| `test` | Runs all local CI checks: yamllint, kubeconform (K8s + Flux CRD schemas), `kubectl kustomize` build validation, Flux `dependsOn` graph validation, Trivy scan |
| `clean` | Full teardown: uninstalls Flux, deletes managed namespaces, strips lingering finalizers |

## CI (GitLab)

Mirrors the local `make test` checks: YAML lint, Kubernetes/Flux CRD schema
validation via kubeconform, Helm chart template validation for
Helm-installed apps, and a Trivy security scan (with accepted-risk
exceptions documented in `.trivyignore.yaml`).

## Bottom line

- Git is the source of truth.
- Flux is the controller that watches it.
- Each environment (`staging`, `production`) is its own branch/path
  combination bootstrapped independently.
- Dependency ordering (`dependsOn`) guarantees infra → Infisical →
  Vaultwarden, so secrets exist before the apps that need them start.
- Environment-specific values are injected at reconcile time via
  `postBuild.substitute`, not hardcoded into shared manifests.