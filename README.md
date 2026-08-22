# Deployment Repo

This repo is a small Kubernetes stack managed with GitOps.
The simple version: Git says what should exist, and Argo CD makes the cluster match it.

## What is in this repo

This repo is not app code. It is deployment code.

It sets up:

- Argo CD itself
- Kubernetes namespaces
- shared infrastructure
- self-hosted apps
- Tailscale-based access

## Folder layout

```text
.
├── .gitlab-ci.yml
├── .gitignore
├── .yamllint.yml
├── Makefile
├── kind-config.yaml
├── README.md
├── bootstrap/
│   └── argocd/
│       ├── production/
│       │   └── argocd.yaml
│       ├── staging/
│       │   └── argocd.yaml
│       └── values.yaml
├── deployments/
│   ├── applications/
│   │   ├── infisical/
│   │   │   ├── bootstrap.yaml
│   │   │   ├── deployment.yaml
│   │   │   ├── ingress.yaml
│   │   │   ├── kustomization.yaml
│   │   │   └── service.yaml
│   │   └── vaultwarden/
│   │       ├── deployment.yaml
│   │       ├── ingress.yaml
│   │       ├── kustomization.yaml
│   │       ├── pvc.yaml
│   │       └── service.yaml
│   ├── infrastructure/
│   │   ├── headlamp/
│   │   │   ├── application.yaml
│   │   │   ├── ingress.yaml
│   │   │   ├── kustomization.yaml
│   │   │   ├── rbac.yaml
│   │   │   └── values.yaml
│   │   ├── postgres/
│   │   │   ├── deployment.yaml
│   │   │   ├── pvc.yaml
│   │   │   └── service.yaml
│   │   └── redis/
│   │       ├── deployment.yaml
│   │       ├── pvc.yaml
│   │       └── service.yaml
│   └── tailscale/
│       └── deployment.yaml
├── namespaces/
│   ├── applications.yaml
│   ├── argocd.yaml
│   ├── infrastructure.yaml
│   └── tailscale.yaml
└── testcreds/               # ignored for secrets, not part of real deployment docs
```

This is the actual repo shape. The important deployment folders are `bootstrap/`, `namespaces/`, and `deployments/`.

## How it works

1. `Makefile` is the main control file.
   - creates namespaces
   - installs prerequisites
   - installs Argo CD
   - deploys infrastructure
   - checks status

2. Argo CD is installed first.
   - It watches the Git repo.
   - It sees folders under `deployments/`.
   - It creates app resources automatically from those folders.

3. The repo uses ApplicationSet.
   - It scans paths like `deployments/*/*`.
   - It maps each folder to a namespace.
   - Example:
     - `deployments/applications/infisical` -> `applications`
     - `deployments/infrastructure/postgres` -> `infrastructure`

4. Sync waves control startup order.
   - Wave 0: Tailscale + Postgres + Redis
   - Wave 1: Infisical + DB bootstrap
   - Wave 2: Headlamp + Vaultwarden

This is important because Infisical needs the database already created before it starts.

## Main services

### Infrastructure
- Postgres: shared database in `infrastructure`
- Redis: shared cache in `infrastructure`
- Headlamp: Kubernetes dashboard in `infrastructure`
- Tailscale operator: exposes services through Tailscale ingress

### Applications
- Infisical: self-hosted secrets app
- Vaultwarden: self-hosted password manager

Both are exposed through Tailscale-hosted ingress, not normal public internet load balancers.

## Secrets

The manifests reference Kubernetes secrets such as:

- `clustercreds-postgres`
- `clustercreds-infisical`
- `headlamp-admin-token`

Those secrets are expected to exist outside the repo. The repo does not contain the real secret values.

## CI

The project has GitLab CI checks for:

- YAML lint
- Kubernetes schema validation
- Trivy security scan

## Bottom line

This repo is basically:

- install the platform tools
- create the namespaces
- let Argo CD watch Git
- deploy database + cache + dashboard + apps
- keep secrets out of Git

Git is the source of truth, Argo CD is the robot, Kubernetes is the target, and this repo is the recipe for the whole stack.
