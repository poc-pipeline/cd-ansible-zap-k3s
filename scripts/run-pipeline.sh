#!/usr/bin/env bash
# run-pipeline.sh — Full local pipeline: registry → build → deploy → ZAP scan → evaluate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "================================================================"
echo " Full Pipeline — Build → Deploy → Scan → Evaluate"
echo "================================================================"
echo ""

# ── 1. Quick Start (registry + app) ──────────────────────────────────────────

echo "=== Phase 1: Infrastructure + Application ==="
"${SCRIPT_DIR}/start.sh"
echo ""

# ── 2. Apply RBAC ────────────────────────────────────────────────────────────

echo "=== Phase 2: RBAC Setup ==="
echo "--- Applying RBAC resources..."
kubectl apply -f "${PROJECT_ROOT}/k8s/rbac/serviceaccount.yaml"
kubectl apply -f "${PROJECT_ROOT}/k8s/rbac/role.yaml"
kubectl apply -f "${PROJECT_ROOT}/k8s/rbac/rolebinding.yaml"
echo "  RBAC applied."
echo ""

# ── 3. Deploy via Ansible ────────────────────────────────────────────────────

echo "=== Phase 3: Ansible Deploy ==="
ansible-playbook \
  -i "${PROJECT_ROOT}/ansible/inventory/local.yml" \
  "${PROJECT_ROOT}/ansible/playbooks/deploy.yml" \
  -e "image_tag=latest"
echo ""

# ── 4. ZAP Scan via Ansible ──────────────────────────────────────────────────

echo "=== Phase 4: ZAP Security Scan ==="
ansible-playbook \
  -i "${PROJECT_ROOT}/ansible/inventory/local.yml" \
  "${PROJECT_ROOT}/ansible/playbooks/zap-scan.yml"
echo ""

# ── 5. Evaluate Report via Ansible ───────────────────────────────────────────

echo "=== Phase 5: Security Gate Evaluation ==="
ansible-playbook \
  -i "${PROJECT_ROOT}/ansible/inventory/local.yml" \
  "${PROJECT_ROOT}/ansible/playbooks/evaluate-report.yml"
echo ""

echo "================================================================"
echo " Pipeline Complete!"
echo "================================================================"
