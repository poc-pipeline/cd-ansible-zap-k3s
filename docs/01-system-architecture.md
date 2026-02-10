# System Architecture

## Overview

This PoC implements a decoupled CI/CD pipeline with OWASP ZAP security scanning running on a **k3s single-node cluster**. It simulates the target architecture of **AAP (Ansible Automation Platform) on OpenShift**, since k3s is a certified Kubernetes distribution and the patterns transfer directly.

## System Context

```
┌──────────────┐          ┌─────────────────────────────────────────────┐
│   Developer  │──push──▶ │              GitHub                        │
└──────────────┘          │  ┌─────────────────────────────────────┐   │
                          │  │  GitHub Actions (self-hosted runner) │   │
                          │  │  - Build image                      │   │
                          │  │  - Push to localhost:5000            │   │
                          │  │  - POST /api/v2/.../launch/          │   │
                          │  └──────────────┬──────────────────────┘   │
                          └─────────────────┼──────────────────────────┘
                                            │
                                            ▼
┌───────────────────────────────────────────────────────────────────────┐
│                         k3s Cluster (rootful)                        │
│                                                                       │
│  ┌─────────────────────┐    ┌──────────────────────────────────────┐ │
│  │    awx namespace     │    │          apps namespace              │ │
│  │                      │    │                                      │ │
│  │  ┌────────────────┐  │    │  ┌──────────┐  ┌────────────────┐  │ │
│  │  │ AWX Operator   │  │    │  │ registry │  │  sample-app    │  │ │
│  │  │  └─ AWX Web    │──┼────┼─▶│ :5000    │  │  Deployment    │  │ │
│  │  │  └─ AWX Task   │  │    │  └──────────┘  │  + Service     │  │ │
│  │  │  └─ Postgres   │  │    │                 │  :8080         │  │ │
│  │  └────────────────┘  │    │  ┌──────────┐  └────────────────┘  │ │
│  │                      │    │  │ ZAP Jobs │                      │ │
│  │  ┌────────────────┐  │    │  │ baseline │                      │ │
│  │  │ EE Pod         │──┼────┼─▶│ full     │  ┌──────────────┐   │ │
│  │  │ (awx-ee-sa)    │  │    │  └──────────┘  │ PVC: reports │   │ │
│  │  └────────────────┘  │    │                 └──────────────┘   │ │
│  └─────────────────────┘    └──────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

## Namespaces

| Namespace | Purpose |
|-----------|---------|
| `awx` | AWX Operator, AWX Web/Task/Postgres pods |
| `apps` | Registry, sample-app, ZAP Jobs, RBAC resources |

This mirrors OpenShift's project-based isolation.

## Kubernetes Network Topology

- **Registry** (`apps/registry`): NodePort :5000 — accessible from host for `podman push` and from cluster nodes for image pulls
- **sample-app** (`apps/sample-app`): ClusterIP :8080 — accessible within cluster via `sample-app.apps.svc.cluster.local:8080`
- **AWX** (`awx/awx-service`): NodePort :8043 — accessible from host for Web UI and API calls
- **ZAP Jobs**: Access sample-app via k8s Service DNS (no special networking needed)

## Technology Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| k3s mode | Rootful | Reliable on WSL2; simulates OpenShift where cluster runs as root |
| Registry | k8s Deployment + NodePort | k3s mirror is read-only; we need push support |
| AWX install | Kustomize (AWX Operator) | Official method; no extra tooling |
| ZAP → app access | Service DNS | Standard k8s networking, same as OpenShift |
| Report flow | PVC + helper pod | ZAP Job pods are ephemeral; PVC persists reports |
| EE auth to k8s | In-cluster ServiceAccount + RBAC | No kubeconfig mounting; automatic token injection |
| Ansible collection | `kubernetes.core` | Replaces `containers.podman` for k8s-native management |

## WSL2 Compatibility

When running on WSL2 with Docker Desktop installed, k3s may fail to start due to a mount parsing issue. Docker Desktop mounts its program files at `/Docker/host` using a 9p filesystem with a path containing spaces (`C:\Program Files\Docker\...`). This causes `/proc/mounts` to have 7 fields instead of 6, which kubelet's mount parser cannot handle.

`scripts/setup-k3s.sh` automatically detects and unmounts `/Docker/host` before configuring k3s. This unmount is safe — Docker Desktop communicates via the Docker socket, not through this mount. The mount reappears on WSL2 reboot and must be cleared again before starting k3s.

Reference: [k3s-io/k3s#4483](https://github.com/k3s-io/k3s/issues/4483)

## Image Build Responsibility

In the real flow, the **GitHub Actions self-hosted runner** (CI phase) builds and pushes images — it has Docker/Podman CLI access. Podman on the host is only used by convenience scripts (`scripts/start.sh`) for local development. This mirrors production where CI (Jenkins/GitHub Actions) builds images and CD (AAP/OpenShift) only orchestrates k8s resources.
