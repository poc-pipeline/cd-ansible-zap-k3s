# Security Scanning

## ZAP as Kubernetes Jobs

OWASP ZAP scans run as **Kubernetes Jobs** (ephemeral pods) instead of Podman containers. This is the k8s-native equivalent and mirrors how security scanning would work on OpenShift.

### Scan Types

| Scan | Job Name | Duration | Purpose |
|------|----------|----------|---------|
| Baseline | `zap-baseline` | ~2-5 min | Passive scan, no active attacks |
| Full | `zap-full` | ~10-20 min | Active scan with `-m 10` minute limit |

### Job Flow

```
ansible-playbook zap-scan.yml
  │
  ├── Ensure PVC + ConfigMap exist
  ├── Delete old Jobs (cleanup)
  │
  ├── Create zap-baseline Job
  │     └── Pod: ghcr.io/zaproxy/zaproxy:stable
  │           ├── Mounts: PVC (reports) + ConfigMap (rules.tsv)
  │           ├── Target: http://sample-app.apps.svc.cluster.local:8080
  │           └── Output: /zap/wrk/zap-baseline-report.json
  ├── Wait for completion
  │
  ├── Create zap-full Job
  │     └── Pod: ghcr.io/zaproxy/zaproxy:stable
  │           ├── Same mounts
  │           └── Output: /zap/wrk/zap-full-report.json
  ├── Wait for completion
  │
  ├── Create helper pod (busybox)
  │     └── kubectl cp reports from PVC to local filesystem
  └── Delete helper pod
```

### ZAP → App Communication

ZAP pods access the sample-app via Kubernetes Service DNS:

```
http://sample-app.apps.svc.cluster.local:8080
```

This is standard k8s networking — no special bridge network or container linking needed. On OpenShift, the same Service DNS pattern applies.

## PVC Report Flow

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  ZAP Job Pod │────▶│  PVC:        │────▶│  AWX EE Pod  │
│  writes JSON │     │  zap-reports │     │  reads from   │
│  to /zap/wrk │     │  (1Gi)       │     │  /reports     │
└──────────────┘     └──────────────┘     └──────────────┘
```

In the AWX context, the same PVC (`zap-reports`) is mounted in both ZAP Job pods (`/zap/wrk`) and AWX EE pods (`/reports`). Reports written by ZAP are directly accessible to the evaluate playbook — no file copy needed. The helper pod + `kubectl cp` step in the playbook is a fallback for non-AWX execution.

Why PVC instead of bind mounts:
- k8s Jobs are ephemeral — pod filesystem is lost when Job completes
- PVC persists across pod restarts and Job recreation
- Same PVC is shared between ZAP jobs and AWX EE pods via the Container Group pod spec
- Same pattern works on OpenShift (PersistentVolumeClaim)
- No host path dependencies

## Rules Configuration

ZAP rules are stored as a ConfigMap (`zap-rules`) created from `zap/rules.tsv`:

```tsv
10003    WARN    Vulnerable JS Library
10010    IGNORE  Cookie No HttpOnly Flag
...
```

The ConfigMap is mounted into ZAP pods at `/zap/wrk/rules.tsv` via `subPath`.

### Updating Rules

1. Edit `zap/rules.tsv`
2. Update the ConfigMap: `kubectl apply -f k8s/scanning/configmap-rules.yaml`
3. Or let the playbook handle it — `zap-scan.yml` applies the ConfigMap manifest on each run

## Quality Gate

`evaluate-report.yml` implements the security quality gate:

```yaml
risk_threshold: 3  # 0=Info, 1=Low, 2=Medium, 3=High, 4=Critical
```

### Logic

1. Read `zap-full-report.json` from `/reports` (PVC mount)
2. Parse JSON and extract alerts from all scanned sites
3. Filter alerts where `riskcode >= risk_threshold`
4. If any high-risk alerts found → **fail the pipeline**

### Alert Risk Levels

| Code | Level | Gate Action |
|------|-------|-------------|
| 0 | Informational | Pass |
| 1 | Low | Pass |
| 2 | Medium | Pass |
| 3 | High | **FAIL** |
| 4 | Critical | **FAIL** |

The threshold is configurable. Set `risk_threshold: 2` to also fail on Medium findings.

## Comparison: Podman vs k8s Scanning

| Aspect | Podman Edition | k3s Edition |
|--------|---------------|-------------|
| ZAP execution | `podman_container` | k8s Job |
| Networking | `poc-network` bridge | Service DNS |
| Report storage | Host bind mount | PVC (local-path) |
| Report extraction | `podman cp` | `kubectl cp` via helper pod |
| Rules injection | Volume mount | ConfigMap + subPath |
| Cleanup | `podman rm` | Job `ttlSecondsAfterFinished` |
