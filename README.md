# e2e-kargo-argo

## Description

This repository contains a complete multi-cluster GitOps setup with ArgoCD and Kargo. It provides scripts for deploying 7 local Kubernetes clusters using k3d, with ArgoCD (HA mode) managing each cluster independently and Kargo orchestrating progressive delivery across environments.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CLUSTERS                                        │
├─────────────┬─────────────┬─────────────┬─────────────────────────────────────┤
│   test      │    dev      │   staging   │   prod-us / prod-eu / prod-au      │
│  (ArgoCD)   │  (ArgoCD)   │  (ArgoCD)   │         (ArgoCD each)               │
│  (Kargo     │  (Kargo     │  (Kargo     │         (Kargo Agent)               │
│   Agent)    │   Agent)    │   Agent)    │                                     │
└──────┬──────┴──────┬──────┴──────┬──────┴─────────────┬───────────────────────┘
       │             │             │                    │
       └─────────────┴──────┬──────┴────────────────────┘
                            │
                    ┌───────▼───────┐
                    │    infra      │
                    │   (ArgoCD)    │
                    │   (Kargo      │
                    │  Controller)  │
                    └───────────────┘

Promotion Flow: test → dev → staging → (prod-us, prod-eu, prod-au) parallel
```

## Features

- 🚀 7 local k3d clusters with shared Docker network for cross-cluster communication
- 🔄 ArgoCD HA mode in each cluster (independent, self-managing)
- 📦 Kargo controller in `infra` cluster, agents in all other clusters
- 🤖 ApplicationSets for automatic app deployment
- 🌐 Nginx reverse proxy for local domain access (`*.local`)
- 🧹 Cleanup and reset scripts for fresh starts

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [k3d](https://k3d.io/) (v5.x+)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/) (v3.x+)

## Quick Start

### 1. Create the Clusters

```bash
# Create all 7 k3d clusters with nginx proxy
./setup-scripts/setup-local-k8s-clusters.sh
```

### 2. Update /etc/hosts

Add the following to your `/etc/hosts` file (the script will show the exact entries):

```
127.0.0.1  argocd.test.local argocd.dev.local argocd.staging.local \
           argocd.prod-us.local argocd.prod-eu.local argocd.prod-au.local \
           argocd.infra.local kargo.infra.local \
           simple-echo-server.test.local simple-echo-server.dev.local ...
```

### 3. Set Up Credentials (for private repos)

```bash
# Copy the template and edit with your Git credentials
cp values-credentials.yaml.template values-credentials.yaml
# Edit values-credentials.yaml with your Git URL and PAT
```

### 4. Bootstrap ArgoCD

```bash
# Bootstrap ArgoCD in all clusters (uses values-credentials.yaml if present)
./setup-scripts/bootstrap.sh

# Or specify repo URL directly
./setup-scripts/bootstrap.sh --repo-url https://github.com/YOUR_ORG/e2e-kargo-argo.git
```

### 4. Access ArgoCD

- URL: `http://argocd.<cluster>.local` (e.g., `http://argocd.infra.local`)
- Username: `admin`
- Password: Run `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`

## Directory Structure

```
e2e-kargo-argo/
├── setup-scripts/
│   ├── setup-local-k8s-clusters.sh  # Creates k3d clusters + nginx proxy + registry
|   ├── registries.yaml               # Registry configuration for k3d clusters
│   ├── cleanup-clusters.sh           # Deletes clusters and cleans up
│   ├── cleanup-registry.sh           # Deletes local registry (separate from clusters)
│   └── bootstrap.sh                  # Installs ArgoCD in all clusters
├── values-credentials.yaml.template  # Template for Git credentials
├── apps/
│   ├── infra/
│   │   ├── argocd/                   # ArgoCD wrapper chart + ApplicationSets
│   │   │   ├── Chart.yaml
│   │   │   ├── values.yaml           # Common HA config
│   │   │   ├── values-<cluster>.yaml # Per-cluster config
│   │   │   └── templates/
│   │   │       ├── infra-appset.yaml      # Auto-discovers apps/infra/*
│   │   │       └── workload-appset.yaml   # Auto-discovers apps/workloads/*
│   │   └── kargo/                    # Kargo wrapper chart
│   │       ├── Chart.yaml
│   │       ├── values.yaml
│   │       └── values-<cluster>.yaml # Per-cluster (controller/agent)
│   └── workloads/
│       └── simple-echo-server/       # Example app
```

## Scripts

All scripts are in the `setup-scripts/` directory.

### setup-local-k8s-clusters.sh

Creates 7 k3d clusters with:
- Shared Docker network (`k3d-multi-cluster`) for cross-cluster communication
- Port mappings for ingress (8080-8086)
- Nginx reverse proxy on port 80 for `*.local` domain routing
- Local image registry (`k3d-registry.localhost:5000`) for faster image pulls and caching

### cleanup-clusters.sh

```bash
# Delete all clusters and clean up
./setup-scripts/cleanup-clusters.sh

# Delete and recreate fresh
./setup-scripts/cleanup-clusters.sh --reset
```

**Note:** The local registry is NOT removed by this script to preserve cached images for faster cluster resets. Use `cleanup-registry.sh` to remove the registry separately.

### cleanup-registry.sh

```bash
# Delete the local registry (removes all cached images)
./setup-scripts/cleanup-registry.sh

# Delete registry and config file
./setup-scripts/cleanup-registry.sh --remove-config
```

**Warning:** This will delete all cached images in the registry!

### bootstrap.sh

```bash
# Bootstrap all clusters (uses values-credentials.yaml if present)
./setup-scripts/bootstrap.sh

# Or with explicit repo URL
./setup-scripts/bootstrap.sh --repo-url <git-repo-url>

# Bootstrap single cluster
./setup-scripts/bootstrap.sh --cluster infra

# Skip dependency update (faster)
./setup-scripts/bootstrap.sh --skip-deps
```

## How It Works

### Bootstrap Flow

1. `bootstrap.sh` runs `helm install argocd` in each cluster
2. ArgoCD deploys with embedded ApplicationSets
3. ApplicationSets automatically create Applications for:
   - **ArgoCD** (self-management)
   - **Kargo** (controller in infra, agent in others)
   - **Workloads** (from `apps/workloads/`)

### Adding New Applications

1. Create a Helm chart in `apps/workloads/<app-name>/`
2. Push to Git
3. ArgoCD's `workload-appset` will automatically discover and deploy it

### Kargo Promotion Flow

```
test → dev → staging → prod-us
                    ↘ prod-eu
                    ↘ prod-au
```

The Kargo controller in the `infra` cluster orchestrates promotions across all environments.

## Clusters

| Cluster   | Port | Purpose |
|-----------|------|---------|
| test      | 8080 | Initial testing |
| dev       | 8081 | Development |
| staging   | 8082 | Pre-production |
| prod-us   | 8083 | US production |
| prod-eu   | 8084 | EU production |
| prod-au   | 8085 | AU production |
| infra     | 8086 | Kargo controller, shared infra |

## Configuration

### ArgoCD

Edit `apps/infra/argocd/values.yaml` for common settings, or `values-<cluster>.yaml` for cluster-specific overrides.

### Kargo

- Controller config: `apps/infra/kargo/values-infra.yaml` (full Kargo install)
- Agent config: `apps/infra/kargo/values-<cluster>.yaml` (agent mode)

### Git Repository & Credentials

Set your Git repo URL and credentials via the local credentials file (recommended):

```bash
cp values-credentials.yaml.template values-credentials.yaml
# Edit values-credentials.yaml
```

Or via command line:
- `./setup-scripts/bootstrap.sh --repo-url <url>`
- `GIT_REPO_URL=<url> ./setup-scripts/bootstrap.sh`

## Troubleshooting

### Clusters not starting
```bash
# Check Docker is running
docker info

# Check k3d clusters
k3d cluster list

# Check cluster logs
docker logs k3d-<cluster>-server-0
```

### ArgoCD not syncing
```bash
# Check ArgoCD pods
kubectl -n argocd get pods

# Check ApplicationSet controller
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-applicationset-controller
```

### Cross-cluster communication issues
```bash
# Verify shared network
docker network inspect k3d-multi-cluster

# Test connectivity from one cluster to another
kubectl run test --rm -it --image=curlimages/curl -- curl http://kargo.infra.local
```

### Using the Local Registry

The setup includes a local image registry at `k3d-registry.localhost:5000` that all clusters use. This speeds up deployments by caching images locally.

**Push images to the registry:**
```bash
# Tag your image
docker tag myapp:latest k3d-registry.localhost:5000/myapp:latest

# Push to registry (from your local machine, use localhost:5000)
docker tag myapp:latest localhost:5000/myapp:latest
docker push localhost:5000/myapp:latest

# Use in your deployments
# Image: k3d-registry.localhost:5000/myapp:latest
```

**Check registry contents:**
```bash
# List repositories
curl http://localhost:5000/v2/_catalog

# List tags for a repository
curl http://localhost:5000/v2/myapp/tags/list
```

**Note:** When pushing from your local machine, use `localhost:5000` (the host port). When referencing in Kubernetes manifests, use `k3d-registry.localhost:5000` (the container name).
