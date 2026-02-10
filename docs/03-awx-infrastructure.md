# AWX Infrastructure

## AWX Operator on k3s

AWX is deployed using the **AWX Operator** via Kustomize — the official installation method. This replaces the docker-compose approach from the Podman edition.

### Installation

```bash
# 1. Create namespace and admin secret
kubectl create namespace awx
kubectl create secret generic awx-admin-password \
  --from-literal=password=admin -n awx

# 2. Apply kustomization
kubectl apply -k awx/kustomize/

# 3. Wait for operator and instance
kubectl -n awx wait --for=condition=Available \
  deployment/awx-operator-controller-manager --timeout=300s
```

### AWX Instance (CR)

```yaml
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: awx
spec:
  service_type: nodeport
  nodeport_port: 8043
  postgres_storage_class: local-path
  projects_persistence: true
  admin_password_secret: awx-admin-password
```

The AWX instance creates:
- **awx-web**: Web UI and API server
- **awx-task**: Task runner (processes Jobs)
- **awx-postgres**: PostgreSQL database

## Container Group

Instead of `DEFAULT_CONTAINER_RUN_OPTIONS` (Podman-specific), the k3s edition uses a **Container Group** (Instance Group with `is_container_group: true`). This tells AWX to run EE pods in the cluster.

### Pod Spec Override

```yaml
apiVersion: v1
kind: Pod
metadata:
  namespace: apps
spec:
  serviceAccountName: awx-ee-sa
  automountServiceAccountToken: true
  containers:
    - name: worker
      image: localhost:5000/awx-ee-k3s:latest
      args:
        - ansible-runner
        - worker
        - --private-data-dir=/runner
      volumeMounts:
        - name: zap-reports
          mountPath: /reports
  volumes:
    - name: zap-reports
      persistentVolumeClaim:
        claimName: zap-reports
```

Key points:
- EE pods run in `apps` namespace (not `awx`)
- `awx-ee-sa` ServiceAccount provides k8s API access
- `zap-reports` PVC is mounted at `/reports`
- No Podman socket mount needed — EE uses in-cluster `kubernetes.core`

## Execution Environment (EE)

The custom EE (`awx/Dockerfile.ee`) extends the base AWX EE with:

```dockerfile
FROM quay.io/ansible/awx-ee:latest
# Install kubectl + kubernetes Python client + kubernetes.core collection
```

This replaces the Podman edition's EE which had `podman-remote` + `containers.podman`.

## RBAC Chain

```
AWX Task Pod
  └── Creates EE Pod in apps namespace
        └── Uses ServiceAccount: awx-ee-sa
              └── Bound to Role: awx-ee-role
                    └── Permissions:
                          - pods, pods/exec, pods/log (CRUD)
                          - services (CRUD)
                          - deployments (CRUD)
                          - jobs (CRUD)
                          - persistentvolumeclaims (CRUD)
                          - configmaps (CRUD)
```

The EE pod's ServiceAccount token is automatically injected by Kubernetes. The `kubernetes.core` collection auto-detects the in-cluster config — no kubeconfig file needed.

## AWX Resource Provisioning

`scripts/awx-setup.sh` creates via REST API:

| Step | Resource | Key Config |
|------|----------|------------|
| 1 | Wait for API | `/api/v2/ping/` |
| 2 | Get Organization | Default org |
| 3 | Container Group | Pod spec with `awx-ee-sa`, PVC mount |
| 4 | Inventory | localhost, local connection |
| 5 | Project (Git SCM) | Clones from GitHub repo |
| 6 | Execution Environment | `localhost:5000/awx-ee-k3s:latest` |
| 7 | Job Templates | Deploy, ZAP Scan, Evaluate |
| 8 | Workflow Template | Deploy → Scan → Evaluate chain |
| 9 | API Token | For GitHub Actions CI trigger |

### Git SCM Project

Unlike the Podman edition (manual/local project), the k3s edition uses **Git SCM** — AWX clones playbooks directly from the GitHub repo. This is more realistic for OpenShift/AAP production workflows where projects always come from SCM.

## Comparison: Podman vs k3s EE Auth

| Aspect | Podman Edition | k3s Edition |
|--------|---------------|-------------|
| EE access method | Podman socket mount | In-cluster ServiceAccount |
| Auth mechanism | Unix socket permissions | RBAC (Role + RoleBinding) |
| Config | `DEFAULT_CONTAINER_RUN_OPTIONS` | Container Group pod spec |
| Collection | `containers.podman` | `kubernetes.core` |
| Scope | Host-level (podman commands) | Namespace-level (k8s API) |
