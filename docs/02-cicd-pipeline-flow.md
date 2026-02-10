# CI/CD Pipeline Flow

## End-to-End Flow

```
Developer ──push──▶ GitHub ──trigger──▶ GitHub Actions (CI)
                                           │
                                    ┌──────┴──────┐
                                    │ Build image  │
                                    │ Push to :5000│
                                    └──────┬──────┘
                                           │
                                    POST /launch/
                                           │
                                           ▼
                                    AWX Workflow (CD)
                                    ┌──────────────┐
                                    │  1. Deploy    │
                                    │  sample-app   │
                                    └──────┬───────┘
                                           │ on success
                                    ┌──────▼───────┐
                                    │ 2. ZAP Scan  │
                                    │ baseline+full│
                                    └──────┬───────┘
                                           │ on success
                                    ┌──────▼───────┐
                                    │ 3. Evaluate  │
                                    │ quality gate │
                                    └──────────────┘
```

## Phase 1: CI (GitHub Actions)

**Trigger**: Push to `main` branch

1. **Checkout** code
2. **Build** container image with Podman: `localhost:5000/sample-app:<sha>`
3. **Push** to in-cluster registry at `localhost:5000`
4. **Trigger AWX** workflow via REST API POST to `/api/v2/workflow_job_templates/{id}/launch/`

The self-hosted runner uses **Podman** (not Docker Desktop) because Podman runs natively in WSL2 and shares the network namespace with k3s — Docker Desktop runs in a separate VM and cannot reach k3s NodePort services. The runner has network access to both the registry (NodePort :5000) and AWX API (NodePort :8043).

## Phase 2: CD (AWX Workflow)

AWX executes three Job Templates in sequence:

### Step 1: Deploy (`deploy.yml`)

- Ensures `apps` namespace exists
- Applies k8s Deployment with `image: localhost:5000/sample-app:{{ image_tag }}`
- Applies ClusterIP Service
- Waits for `readyReplicas >= 1`
- Uses `kubernetes.core.k8s` and `kubernetes.core.k8s_info`

### Step 2: ZAP Scan (`zap-scan.yml`)

- Ensures PVC and ConfigMap exist
- Cleans up old ZAP Jobs
- Creates baseline scan Job → waits for completion
- Creates full scan Job → waits for completion
- Spawns helper pod to `kubectl cp` reports from PVC to local filesystem
- Cleans up helper pod

### Step 3: Evaluate (`evaluate-report.yml`)

- Reads ZAP JSON report
- Filters alerts where `riskcode >= 3` (High/Critical)
- Displays findings summary
- **Fails pipeline** if any high-risk findings exist

## CI → CD Handoff

The handoff happens via AWX REST API:

```bash
curl -X POST \
  -H "Authorization: Bearer $AWX_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"extra_vars": {"image_tag": "<sha>"}}' \
  "http://localhost:8043/api/v2/workflow_job_templates/{id}/launch/"
```

The `image_tag` variable flows through the workflow to the Deploy Job Template.

## Bootstrap Sequence (Local Development)

For local development without GitHub Actions:

```bash
# 1. Install k3s
sudo ./scripts/setup-k3s.sh

# 2. Quick start (registry + build + deploy)
./scripts/start.sh

# 3. Full pipeline
./scripts/run-pipeline.sh

# 4. (Optional) Deploy AWX for workflow orchestration
./scripts/deploy-awx.sh
./scripts/awx-setup.sh
```

## Variable Flow

| Variable | Source | Used In |
|----------|--------|---------|
| `image_tag` | CI (git SHA) or manual (`latest`) | `deploy.yml` — sets container image tag |
| `app_namespace` | Default `apps` | All playbooks — target namespace |
| `target_url` | Default `http://sample-app.apps.svc.cluster.local:8080` | `zap-scan.yml` — ZAP target |
| `reports_dir` | Default `/reports` (PVC mount in AWX EE pods) | `zap-scan.yml`, `evaluate-report.yml` |
| `risk_threshold` | Default `3` (High) | `evaluate-report.yml` — quality gate threshold |
