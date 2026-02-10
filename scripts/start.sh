#!/usr/bin/env bash
# start.sh — Quick start: apply namespaces, deploy registry, build/push/deploy app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "================================================================"
echo " Quick Start — Registry + Sample App on k3s"
echo "================================================================"
echo ""

# ── 1. Apply namespaces ──────────────────────────────────────────────────────

echo "--- [1/5] Creating namespaces..."
kubectl apply -f "${PROJECT_ROOT}/k8s/namespaces.yaml"
echo "  Namespaces created."

# ── 2. Deploy registry ───────────────────────────────────────────────────────

echo "--- [2/5] Deploying container registry..."
kubectl apply -f "${PROJECT_ROOT}/k8s/registry/pvc.yaml"
kubectl apply -f "${PROJECT_ROOT}/k8s/registry/deployment.yaml"
kubectl apply -f "${PROJECT_ROOT}/k8s/registry/service.yaml"

echo "  Waiting for registry to be ready..."
kubectl -n apps wait --for=condition=Available deployment/registry --timeout=120s
echo "  Registry available at localhost:5000."

# ── 3. Build and push sample-app ─────────────────────────────────────────────

echo "--- [3/5] Building sample-app image..."
if command -v podman &>/dev/null; then
  BUILD_CMD="podman"
elif command -v docker &>/dev/null; then
  BUILD_CMD="docker"
else
  echo "ERROR: Neither podman nor docker found. Install one to build images."
  exit 1
fi

$BUILD_CMD build -t localhost:5000/sample-app:latest "${PROJECT_ROOT}/sample-app"
echo "  Image built."

echo "--- [4/5] Pushing image to registry..."
$BUILD_CMD push localhost:5000/sample-app:latest
echo "  Image pushed to localhost:5000/sample-app:latest."

# ── 4. Deploy sample-app ─────────────────────────────────────────────────────

echo "--- [5/5] Deploying sample-app to k3s..."
kubectl apply -f "${PROJECT_ROOT}/k8s/sample-app/deployment.yaml"
kubectl apply -f "${PROJECT_ROOT}/k8s/sample-app/service.yaml"

echo "  Waiting for sample-app to be ready..."
kubectl -n apps wait --for=condition=Available deployment/sample-app --timeout=120s
echo "  sample-app is running."

echo ""
echo "================================================================"
echo " Quick Start Complete!"
echo "================================================================"
echo ""
echo " Verify with:"
echo "   kubectl -n apps port-forward svc/sample-app 8080:8080"
echo "   curl http://localhost:8080/health"
echo ""
