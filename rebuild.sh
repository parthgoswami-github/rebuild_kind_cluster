#!/bin/bash

# Exit immediately if a command fails
set -e

# Parse command line flags
HEADLAMP_ONLY=false
for arg in "$@"; do
  if [ "$arg" == "--headlamp" ]; then
    HEADLAMP_ONLY=true
  fi
done

# If --headlamp flag is provided, skip the cluster rebuild steps and run ONLY the Headlamp setup
if [ "$HEADLAMP_ONLY" = true ]; then
  echo "=== '--headlamp' flag detected: Skipping cluster rebuild and installing Headlamp on existing cluster ==="

  # Ensure we are in the repo directory at the end regardless
  cd ~/src/ADMIN-238_Admin_K8s 2>/dev/null || cd ~/src

  echo -e "\n=== Installing and Configuring Headlamp ==="
  
  echo "--> Adding Headlamp Helm repository..."
  helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
  helm repo update

  echo -e "\n--> Installing Headlamp via Helm..."
  helm install headlamp headlamp/headlamp \
    --namespace headlamp --create-namespace \
    --set service.type=LoadBalancer

  echo -e "\n=== Configuring Headlamp Service Accounts & Permissions ==="
  
  echo "--> Checking current resources in 'headlamp' namespace..."
  kubectl -n headlamp get all
  
  echo "--> Checking Headlamp service details..."
  kubectl -n headlamp get svc headlamp
  
  echo "--> Creating 'headlamp-admin' ServiceAccount..."
  kubectl -n headlamp create serviceaccount headlamp-admin
  
  echo "--> Creating 'headlamp-read-only' ServiceAccount..."
  kubectl -n headlamp create serviceaccount headlamp-read-only
  
  echo "--> Binding 'headlamp-admin' ServiceAccount to 'cluster-admin' ClusterRole..."
  kubectl create clusterrolebinding headlamp-admin-binding --clusterrole=cluster-admin --serviceaccount=headlamp:headlamp-admin
  
  echo "--> Binding 'headlamp-read-only' ServiceAccount to 'view' ClusterRole..."
  kubectl create clusterrolebinding headlamp-read-only-binding --clusterrole=view --serviceaccount=headlamp:headlamp-read-only
  
  echo "--> Generating 24-hour admin access token..."
  ADMIN_TOKEN=$(kubectl -n headlamp create token headlamp-admin --duration 86400s)
  
  echo "--> Generating read-only access token..."
  kubectl -n headlamp create token headlamp-read-only > /dev/null
  
  echo "--> Checking status of services in 'headlamp' namespace..."
  kubectl -n headlamp get svc

  echo -e "\n--> Waiting for MetalLB to assign an External IP to the Headlamp service..."
  until [ -n "$(kubectl -n headlamp get svc headlamp -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)" ]; do
    sleep 2
  done
  
  HEADLAMP_IP=$(kubectl -n headlamp get svc headlamp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  echo "--> Headlamp External IP assigned: ${HEADLAMP_IP}"

  echo "--> Updating /etc/hosts entry for 'headlamp.local'..."
  if grep -q "headlamp.local" /etc/hosts; then
    sudo sed -i "s/.*headlamp.local/${HEADLAMP_IP} headlamp.local/" /etc/hosts
  else
    echo "${HEADLAMP_IP} headlamp.local" | sudo tee -a /etc/hosts > /dev/null
  fi

  echo -e "\n================================================================="
  echo -e "                 HEADLAMP ACCESS INSTRUCTIONS                    "
  echo -e "================================================================="
  echo -e "1. Copy and paste the URL into your browser:"
  echo -e "   http://headlamp.local\n"
  echo -e "2. Accept the risk and proceed to the website.\n"
  echo -e "3. Paste the following Admin Token when prompted:\n"
  echo -e "${ADMIN_TOKEN}\n"
  echo -e "=================================================================\n"

  # Preserve working directory and spawn shell
  cd ~/src/ADMIN-238_Admin_K8s
  exec $SHELL
fi

# ==============================================================================
# FULL REBUILD WORKFLOW (Runs when NO --headlamp flag is passed)
# ==============================================================================

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

echo -e "\n=== 12. Adding Helm repositories (Metrics Server & MetalLB) ==="
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add metallb https://metallb.github.io/metallb
helm repo update

echo -e "\n=== 13. Installing/Upgrading Metrics Server via Helm ==="
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' \
  --wait

echo -e "\n=== 14. Verifying Metrics Server Deployment and Resources ==="
kubectl -n kube-system get deployment metrics-server
echo ""
kubectl -n kube-system get all -l app.kubernetes.io/name=metrics-server
echo -e "\nWaiting 5 seconds for visual verification..."
sleep 5

echo -e "\n=== 15. Dynamically waiting for pods to become Ready (Up to 60s max) ==="
kubectl wait --namespace kube-system --for=condition=ready pod --all --timeout=60s || true
kubectl wait --namespace calico-system --for=condition=ready pod --all --timeout=60s || true
kubectl wait --namespace tigera-operator --for=condition=ready pod --all --timeout=60s || true

echo -e "\n=== 16. Getting nodes ==="
kubectl get nodes

echo -e "\n=== 17. Checking node resource usage (kubectl top node) ==="
kubectl top node || true
echo -e "\nWaiting 5 seconds for visual verification..."
sleep 5

echo -e "\n=== 18. Getting pods in kube-system ==="
kubectl get pods -n kube-system

echo -e "\n=== 19. Getting pods in calico-system ==="
kubectl get pods -n calico-system
echo -e "\nWaiting 5 seconds before installing MetalLB..."
sleep 5

echo -e "\n=== 20. Installing MetalLB via Helm ==="
helm install metallb metallb/metallb --namespace metallb-system --create-namespace

echo -e "\n=== 21. Waiting for MetalLB Controller and Webhook to be Ready (Up to 45s max) ==="
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=45s

echo -e "\n=== 22. Applying MetalLB Custom Configuration ==="
kubectl apply -f metallb-conf.yaml

echo -e "\n=== 23. Watching MetalLB pods (10 seconds) ==="
timeout 10s kubectl get pods -n metallb-system -w || true

echo -e "\n=== 24. Re-cloning repository ==="
cd ~/src
rm -rf ADMIN-238_Admin_K8s
git clone https://github.com/wmdailey/ADMIN-238_Admin_K8s.git
cd ADMIN-238_Admin_K8s
ls

echo -e "\n================================================================="
echo -e "[INFO] Headlamp setup was skipped."
echo -e "If you wish to install and configure Headlamp, run:"
echo -e "  ./rebuild.sh --headlamp"
echo -e "=================================================================\n"

# Spawns an interactive shell to preserve the target directory in your current terminal session
exec $SHELL
