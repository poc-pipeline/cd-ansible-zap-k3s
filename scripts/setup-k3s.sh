#!/usr/bin/env bash
# setup-k3s.sh — Install and configure k3s single-node cluster
set -euo pipefail

echo "================================================================"
echo " k3s Setup — Single Node Cluster"
echo "================================================================"
echo ""

# ── 1. Install k3s ────────────────────────────────────────────────────────────

echo "--- [1/4] Installing k3s..."
if command -v k3s &>/dev/null; then
  echo "  k3s already installed: $(k3s --version)"
else
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --disable servicelb \
    --kube-apiserver-arg=service-node-port-range=5000-32767" sh -
  echo "  k3s installed successfully."
fi

# ── 1b. Fix WSL2 mounts with spaces (breaks kubelet mount parser) ─────────────

echo "--- [1b/4] Fixing WSL2 mounts with spaces..."
# Docker Desktop mounts can have spaces in options, causing kubelet to crash
# with "system validation failed - wrong number of fields (expected 6, got 7)"
if mountpoint -q /Docker/host 2>/dev/null; then
  sudo umount /Docker/host 2>/dev/null || true
  echo "  Unmounted /Docker/host (had spaces in mount options)."
else
  echo "  No problematic mounts found."
fi

# ── 2. Configure insecure registry ────────────────────────────────────────────

echo "--- [2/4] Configuring insecure registry (localhost:5000)..."
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<'EOF'
mirrors:
  "localhost:5000":
    endpoint:
      - "http://localhost:5000"
EOF

# Restart k3s to pick up registry config
sudo systemctl restart k3s
echo "  Registry configuration applied."

# ── 3. Setup kubeconfig ───────────────────────────────────────────────────────

echo "--- [3/4] Setting up kubeconfig..."
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=~/.kube/config
echo "  Kubeconfig ready at ~/.kube/config"

# ── 4. Verify cluster ─────────────────────────────────────────────────────────

echo "--- [4/4] Verifying cluster..."
echo "  Waiting for node to be Ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s
echo ""
kubectl get nodes
echo ""

echo "================================================================"
echo " k3s Setup Complete!"
echo "================================================================"
echo ""
echo " Next steps:"
echo "   kubectl apply -f k8s/namespaces.yaml"
echo "   ./scripts/start.sh"
echo ""
