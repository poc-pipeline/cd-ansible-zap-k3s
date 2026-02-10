# cd-ansible-zap-k3s

Decoupled CI/CD pipeline with OWASP ZAP security scanning on **k3s + AWX Operator**. This PoC simulates AAP running on on-prem OpenShift — k3s is a certified Kubernetes distribution, so the patterns transfer directly.

## Architecture

```
┌─────────────────┐     ┌────────────────────────────────────────────────────┐
│  GitHub Actions  │────▶│                  k3s Cluster                       │
│  (CI: Build +    │     │  ┌────────────┐  ┌──────────────────────────────┐ │
│   Push Image)    │     │  │  awx (ns)  │  │         apps (ns)            │ │
│                  │     │  │  ┌────────┐│  │  ┌──────────┐ ┌──────────┐  │ │
│  POST /launch/   │────▶│  │  │  AWX   ││──│──│sample-app│ │ registry │  │ │
│                  │     │  │  │Operator ││  │  └──────────┘ └──────────┘  │ │
└─────────────────┘     │  │  └────────┘│  │  ┌──────────┐ ┌──────────┐  │ │
                        │  └────────────┘  │  │ ZAP Job  │ │ PVC:     │  │ │
                        │                  │  │(baseline)│ │ reports  │  │ │
                        │                  │  └──────────┘ └──────────┘  │ │
                        │                  │  ┌──────────┐               │ │
                        │                  │  │ ZAP Job  │               │ │
                        │                  │  │ (full)   │               │ │
                        │                  │  └──────────┘               │ │
                        │                  └──────────────────────────────┘ │
                        └────────────────────────────────────────────────────┘
```

## Prerequisites

- **WSL2** (Ubuntu 22.04+) or Linux host
- **k3s** (installed via `scripts/setup-k3s.sh`)
- **Podman** (for building images — Docker Desktop cannot reach k3s NodePort on WSL2)
- **Ansible** 2.16+ with `kubernetes.core` collection
- **Python** `kubernetes` package (`pip install kubernetes`)

```bash
# Install Ansible collection and Python dependency
ansible-galaxy collection install kubernetes.core
pip install kubernetes
```

## Quick Start

### 1. Install k3s

```bash
sudo ./scripts/setup-k3s.sh
```

### 2. Deploy registry + app

```bash
./scripts/start.sh
```

### 3. Run the full pipeline

```bash
./scripts/run-pipeline.sh
```

### 4. (Optional) Deploy AWX

```bash
# Build and push custom Execution Environment
podman build -t localhost:5000/awx-ee-k3s:latest -f awx/Dockerfile.ee .
podman push localhost:5000/awx-ee-k3s:latest

# Install AWX Operator + instance
./scripts/deploy-awx.sh

# Configure AWX resources
./scripts/awx-setup.sh
```

## Run Order (Manual)

```bash
# 1. Setup k3s cluster
sudo ./scripts/setup-k3s.sh

# 2. Apply namespaces and RBAC
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/rbac/

# 3. Deploy registry
kubectl apply -f k8s/registry/

# 4. Build and push image
podman build -t localhost:5000/sample-app:latest ./sample-app
podman push localhost:5000/sample-app:latest

# 5. Deploy app via Ansible
ansible-playbook -i ansible/inventory/local.yml \
  ansible/playbooks/deploy.yml -e "image_tag=latest"

# 6. Run ZAP scans
ansible-playbook -i ansible/inventory/local.yml \
  ansible/playbooks/zap-scan.yml

# 7. Evaluate results
ansible-playbook -i ansible/inventory/local.yml \
  ansible/playbooks/evaluate-report.yml
```

## Key Differences from Podman Edition

| Component | Podman Edition | k3s Edition |
|-----------|---------------|-------------|
| Runtime | Podman (rootless) | k3s (containerd) |
| Orchestration | podman-compose | Kubernetes |
| AWX | docker-compose | AWX Operator (kustomize) |
| App deployment | `containers.podman` | `kubernetes.core.k8s` |
| Networking | Podman bridge | k8s Service DNS |
| ZAP execution | Podman containers | k8s Jobs |
| Report storage | Host bind mounts | PVC + kubectl cp |
| EE auth | Podman socket mount | ServiceAccount + RBAC |
| OpenShift fidelity | Low | High |

## Project Structure

```
cd-ansible-zap-k3s/
├── .github/workflows/ci.yml       # CI: build → push → trigger AWX
├── sample-app/                     # Spring Boot sample application
├── ansible/
│   ├── inventory/local.yml
│   └── playbooks/
│       ├── deploy.yml              # k8s Deployment via kubernetes.core
│       ├── zap-scan.yml            # ZAP as k8s Jobs
│       └── evaluate-report.yml     # Security quality gate
├── awx/
│   ├── Dockerfile.ee               # EE with kubectl + kubernetes.core
│   └── kustomize/                  # AWX Operator install
├── k8s/
│   ├── namespaces.yaml
│   ├── registry/                   # Registry Deployment + NodePort
│   ├── sample-app/                 # App Deployment + Service
│   ├── scanning/                   # PVC, ConfigMap, Job templates
│   └── rbac/                       # ServiceAccount, Role, RoleBinding, ClusterRole
├── scripts/
│   ├── setup-k3s.sh                # Install k3s
│   ├── deploy-awx.sh               # Install AWX Operator
│   ├── awx-setup.sh                # Provision AWX resources
│   ├── start.sh                    # Quick start
│   └── run-pipeline.sh             # Full pipeline
├── zap/rules.tsv                   # ZAP scan rules
├── reports/                        # Generated scan reports
└── docs/                           # Architecture documentation
```

## Troubleshooting

### WSL2 + Docker Desktop: k3s fails to start

If k3s crashes with:

```
"Failed to start ContainerManager" err="system validation failed - wrong number of fields (expected 6, got 7)"
```

**Cause**: Docker Desktop mounts `C:\Program Files\Docker\Docker\resources` at `/Docker/host` via 9p. The space in "Program Files" produces 7 fields in `/proc/mounts` instead of 6, crashing kubelet's mount parser.

**Fix**: `scripts/setup-k3s.sh` handles this automatically by unmounting `/Docker/host` before starting k3s. If running manually:

```bash
sudo umount /Docker/host 2>/dev/null
sudo systemctl restart k3s
```

This does not affect Docker Desktop functionality — `docker` commands continue to work normally. The mount will reappear after a WSL2 reboot, so the unmount must be repeated (the setup script handles this).

See [k3s-io/k3s#4483](https://github.com/k3s-io/k3s/issues/4483) for details.

### CI: Docker Desktop cannot push to k3s registry

Docker Desktop on WSL2 runs in a separate network namespace and cannot reach k3s NodePort services (`localhost:5000`). Use **Podman** for image builds — it runs natively in WSL2 and shares the network namespace with k3s.

### AWX: PVC stuck in Pending state

If `awx-projects-claim` PVC stays Pending, the access mode is likely `ReadWriteMany`. The k3s `local-path` provisioner only supports `ReadWriteOnce`. The AWX instance spec includes `projects_storage_access_mode: ReadWriteOnce` to handle this.

### AWX: CRD race condition during install

Applying the AWX Operator and instance simultaneously fails because the AWX CRD doesn't exist yet when the instance manifest is processed. `scripts/deploy-awx.sh` handles this by deploying the operator first, waiting for the CRD, then deploying the instance.

### AWX: EE pod cannot find kubernetes Python module

The AWX EE base image has Python 3.9 as default but `pip3` is symlinked to Python 3.11. `awx/Dockerfile.ee` bootstraps pip for Python 3.9 directly to ensure the `kubernetes` package is installed for the correct interpreter.

### WSL2: Accessing k3s services from Windows

k3s NodePort services (AWX UI, registry) listen on `localhost` inside WSL2, which is not reachable from the Windows host. Use the WSL2 IP instead:

```bash
# Get WSL2 IP
hostname -I | awk '{print $1}'
```

| Service | WSL2 URL | Purpose |
|---------|----------|---------|
| AWX UI | `http://<WSL2_IP>:8043` | AWX Web interface (admin/admin) |
| Registry | `http://<WSL2_IP>:5000` | Container image registry |
| Sample App | Cluster-internal only | `sample-app.apps.svc.cluster.local:8080` |

**Podman Desktop**: To view k3s pods from Podman Desktop on Windows, copy the kubeconfig with the WSL2 IP:

```bash
WSL_IP=$(hostname -I | awk '{print $1}')
sed "s|https://127.0.0.1:6443|https://${WSL_IP}:6443|" ~/.kube/config > /mnt/c/Users/$USER/.kube/config
sed -i 's|certificate-authority-data:.*|insecure-skip-tls-verify: true|' /mnt/c/Users/$USER/.kube/config
```

**Note**: The WSL2 IP changes on reboot — re-run the commands above after restarting WSL2.

## Documentation

- [System Architecture](docs/01-system-architecture.md)
- [CI/CD Pipeline Flow](docs/02-cicd-pipeline-flow.md)
- [AWX Infrastructure](docs/03-awx-infrastructure.md)
- [Security Scanning](docs/04-security-scanning.md)
