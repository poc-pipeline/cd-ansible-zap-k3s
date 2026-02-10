#!/usr/bin/env bash
# deploy-awx.sh — Install AWX Operator and AWX instance on k3s
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AWX_NAMESPACE="awx"
AWX_ADMIN_PASS="${AWX_ADMIN_PASS:-admin}"

echo "================================================================"
echo " AWX Deployment — Operator + Instance on k3s"
echo "================================================================"
echo ""

# ── 1. Create namespace and admin secret ──────────────────────────────────────

echo "--- [1/5] Creating namespace and admin secret..."
kubectl create namespace "$AWX_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic awx-admin-password \
  --from-literal=password="$AWX_ADMIN_PASS" \
  -n "$AWX_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  Namespace '${AWX_NAMESPACE}' and admin secret ready."

# ── 2. Deploy AWX Operator via Kustomize ──────────────────────────────────────

echo "--- [2/5] Deploying AWX Operator..."
# Apply operator first (skip AWX instance — CRD won't exist yet)
kubectl apply -k "github.com/ansible/awx-operator/config/default?ref=2.19.1" -n "$AWX_NAMESPACE"
echo "  AWX Operator resources applied."

# ── 3. Wait for Operator + CRD ──────────────────────────────────────────────

echo "--- [3/5] Waiting for AWX Operator to be ready..."
kubectl -n "$AWX_NAMESPACE" wait --for=condition=Available \
  deployment/awx-operator-controller-manager --timeout=300s
echo "  AWX Operator is running."

echo "  Waiting for AWX CRD to be registered..."
kubectl wait --for=condition=Established \
  crd/awxs.awx.ansible.com --timeout=60s
echo "  CRD ready."

echo "  Applying AWX instance..."
kubectl apply -f "${PROJECT_ROOT}/awx/kustomize/awx-instance.yaml"
echo "  AWX instance created."

# ── 4. Wait for AWX pods ─────────────────────────────────────────────────────

echo "--- [4/5] Waiting for AWX instance pods..."
echo "  This may take several minutes on first install..."
MAX_WAIT=600
ELAPSED=0
while true; do
  READY=$(kubectl -n "$AWX_NAMESPACE" get pods -l app.kubernetes.io/name=awx-web \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  if [ "$READY" = "True" ]; then
    break
  fi
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "ERROR: AWX pods not ready after ${MAX_WAIT}s"
    kubectl -n "$AWX_NAMESPACE" get pods
    exit 1
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  echo "  Waiting... (${ELAPSED}s)"
done
echo "  AWX pods are running."

# ── 5. Verify API readiness ──────────────────────────────────────────────────

echo "--- [5/5] Verifying AWX API..."
AWX_PORT=$(kubectl -n "$AWX_NAMESPACE" get svc awx-service \
  -o jsonpath='{.spec.ports[0].nodePort}')
MAX_WAIT=120
ELAPSED=0
until curl --fail --silent --show-error "http://localhost:${AWX_PORT}/api/v2/ping/" -o /dev/null 2>/dev/null; do
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "ERROR: AWX API not responding after ${MAX_WAIT}s"
    exit 1
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  echo "  Waiting for API... (${ELAPSED}s)"
done
echo "  AWX API is ready on port ${AWX_PORT}."

echo ""
echo "================================================================"
echo " AWX Deployment Complete!"
echo "================================================================"
echo ""
echo " AWX Web UI: http://localhost:${AWX_PORT}"
echo " Credentials: admin / ${AWX_ADMIN_PASS}"
echo ""
echo " Next step: ./scripts/awx-setup.sh"
echo ""
