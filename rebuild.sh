#!/bin/bash

# Exit immediately if a command fails
set -e

echo "=== 1. Navigating to working directory ==="
cd ~/rebuild_kind_cluster/code

echo "=== 2. Cleaning up existing kind clusters ==="
kind delete clusters --all

echo "=== 3. Creating kind cluster ==="
kind create cluster --name edu --config edu-cluster.yaml

echo -e "\n=== 4. Getting nodes ==="
kubectl get nodes

echo "=== 5. Waiting for 10 seconds before proceeding... ==="
sleep 10

echo -e "\n=== 6. Applying Calico Operator manifest ==="
CALICO_OPERATOR_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml"
kubectl apply -f "${CALICO_OPERATOR_MANIFEST}" --server-side --force-conflicts

echo -e "\n=== 7. Waiting for Calico CRDs to be established ==="
kubectl wait --for=condition=established --timeout=60s crd/installations.operator.tigera.io
sleep 5

echo -e "\n=== 8. Applying custom Calico configuration ==="
kubectl apply -f calico-custom-config.yaml --server-side --field-manager=calico-config

echo -e "\n=== 9. Watching pods (Initial 10 seconds) ==="
timeout 10s kubectl get pods --all-namespaces --watch | grep --line-buffered -E "NAMESPACE|calico-system|kube-system|tigera-operator" || true

echo -e "\n=== 10. Checking & Installing Helm ==="
if command -v helm &> /dev/null; then
    echo "=== 10a. Helm is already installed ==="
    helm version
else
    echo "=== 10a. Helm not found. Installing Helm... ==="
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 755 get_helm.sh
    ./get_helm.sh
    rm -f get_helm.sh
    echo "=== 10b. Helm successfully installed ==="
    helm version
fi

echo -e "\n=== 11. Waiting for 10 seconds before proceeding... ==="
sleep 10

echo -e "\n=== 12. Adding Metrics Server Helm repository ==="
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

echo -e "\n=== 13. Installing/Upgrading Metrics Server via Helm ==="
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' \
  --wait

echo -e "\n=== 14. Watching pods (Remaining 70 seconds) ==="
timeout 70s kubectl get pods --all-namespaces --watch | grep --line-buffered -E "NAMESPACE|calico-system|kube-system|tigera-operator" || true

echo -e "\n=== 15. Getting nodes ==="
kubectl get nodes

echo -e "\n=== 16. Getting pods in kube-system ==="
kubectl get pods -n kube-system

echo -e "\n=== 17. Getting pods in calico-system ==="
kubectl get pods -n calico-system

echo -e "\n=== 18. Re-cloning repository ==="
cd ~/src
rm -rf ADMIN-238_Admin_K8s
git clone https://github.com/wmdailey/ADMIN-238_Admin_K8s.git
cd ADMIN-238_Admin_K8s
ls

# Spawns an interactive shell to preserve the target directory in your current terminal session
exec $SHELL
