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

echo -e "\n=== 6. Watching pods across calico-system, kube-system, and tigera-operator namespaces for 2 minutes ==="
timeout 100s kubectl get pods --all-namespaces --watch | grep --line-buffered -E "NAMESPACE|calico-system|kube-system|tigera-operator" || true

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
