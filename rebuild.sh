#!/bin/bash

# Exit immediately if a command fails
set -e

echo "=== 0. Updating repository and navigating to working directory ==="
cd
cd src/ADMIN-238_Admin_K8s/
git pull --rebase
cd 03_Installing/03-04-02_CNI/

echo "=== Cleaning up existing kind clusters ==="
kind delete clusters --all

echo "=== 1. Creating kind cluster ==="
kind create cluster --name edu --config edu-cluster.yaml

echo -e "\n=== 2. Getting nodes ==="
kubectl get nodes

echo "Waiting for 10 seconds before proceeding..."
sleep 10

echo -e "\n=== 3 & 4. Applying Calico Operator manifest ==="
CALICO_OPERATOR_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml"
kubectl apply -f "${CALICO_OPERATOR_MANIFEST}" --server-side --force-conflicts

echo -e "\n=== Waiting for Calico CRDs to be established ==="
kubectl wait --for=condition=established --timeout=60s crd/installations.operator.tigera.io
sleep 5

echo -e "\n=== 5. Applying custom Calico configuration ==="
kubectl apply -f calico-custom-config.yaml --server-side --field-manager=calico-config

echo -e "\n=== 6a. Watching pods (Initial 10 seconds) ==="
timeout 10s kubectl get pods --all-namespaces --watch | grep --line-buffered -E "NAMESPACE|calico-system|kube-system|tigera-operator" || true

echo -e "\n=== Checking & Installing Helm ==="
if command -v helm &> /dev/null; then
    echo "Helm is already installed:"
    helm version
else
    echo "Helm not found. Installing Helm..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 755 get_helm.sh
    ./get_helm.sh
    rm -f get_helm.sh
    echo "Helm successfully installed:"
    helm version
fi

echo -e "\nWaiting for 10 seconds before starting the main watch..."
sleep 10

echo -e "\n=== 6b. Watching pods (Remaining 90 seconds) ==="
timeout 90s kubectl get pods --all-namespaces --watch | grep --line-buffered -E "NAMESPACE|calico-system|kube-system|tigera-operator" || true

echo -e "\n=== 7. Getting nodes ==="
kubectl get nodes

echo -e "\n=== 8. Getting pods in kube-system ==="
kubectl get pods -n kube-system

echo -e "\n=== 9. Getting pods in calico-system ==="
kubectl get pods -n calico-system

echo -e "\n=== 10. Returning to root repository directory ==="
cd ../../
ls

# Spawns an interactive shell to preserve the target directory in your current terminal session
exec $SHELL
