#!/bin/bash
#================================================================================#
#                  Kubernetes GitOps Bootstrap Script                          #
#================================================================================#
#  This script bootstraps a fresh Kubernetes cluster for GitOps management.      #
#  It installs and configures, in the correct order:                             #
#  1. Hetzner Cloud Controller Manager (CCM) to enable cloud integrations.     #
#  2. An Ingress Controller (NGINX) to handle external traffic.                #
#  3. Cert-Manager to automate TLS certificates via Let's Encrypt.             #
#  4. ArgoCD as the GitOps continuous delivery tool.                           #
#  5. An ArgoCD "App of Apps" to manage the cluster from a Git repository.       #
#================================================================================#
# --- 📝 PRE-REQUISITES: Your Local Machine ---
#
# 1.  **A Running Kubernetes Cluster**: This script assumes your cluster is up.
# 2.  **A Valid Kubeconfig**: Your KUBECONFIG environment variable must be set.
# 3.  **Required Tools**: `kubectl`, `helm`, `hcloud`.
#
#================================================================================#
# Stop script on any error and treat unset variables as an error.
set -euo pipefail
# --- ⚙️ GitOps Configuration (CHANGE THESE VALUES) ---
# The Git repository that will define your cluster's desired state.
readonly GIT_REPO_URL="https://github.com/divizend/seed"
# The path within the repository where your cluster manifests are located.
readonly GIT_REPO_PATH="cluster-manifests"
# The branch to track.
readonly GIT_REPO_BRANCH="main"
# The label used to identify your cluster's resources in Hetzner.
# This MUST match the CLUSTER_NAME from your `setup-talos-hcloud.sh` script.
readonly CLUSTER_LABEL_NAME="divizend-ai-prod"
# Hetzner Cloud location (must match your cluster setup)
readonly HCLOUD_LOCATION="fsn1"
# --- 🎨 Logging and Helper Functions ---
info() { printf '\n\e[34m[INFO]\e[0m %s\n' "$1"; }
success() { printf '\e[32m[SUCCESS]\e[0m %s\n' "$1"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$1"; }
error() { printf '\n\e[31m[ERROR]\e[0m %s\n' "$1" >&2; exit 1; }
command_exists() { command -v "$1" &>/dev/null; }
# --- 🧹 Deprovisioning Function ---
deprovision() {
    info "Wiping all bootstrapped GitOps components from the cluster..."
    warn "This will delete ArgoCD, Cert-Manager, Ingress-NGINX, the Hetzner CCM, and all related resources."
    read -p "Are you sure you want to continue? (y/N) " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Aborting wipe."
        exit 1
    fi
    info "Deleting the root ArgoCD application..."
    if kubectl api-resources | grep -q "applications.argoproj.io"; then
        kubectl delete application root-cluster-config -n argocd --ignore-not-found=true
    else
        success "ArgoCD Application CRD not found, skipping deletion."
    fi
    info "Uninstalling Helm charts gracefully..."
    helm uninstall ingress-nginx -n ingress-nginx --wait 2>/dev/null || true
    helm uninstall cert-manager -n cert-manager --wait 2>/dev/null || true
    helm uninstall argocd -n argocd --wait 2>/dev/null || true
    
    info "Deleting Hetzner Cloud Controller Manager..."
    kubectl delete -f https://raw.githubusercontent.com/hetznercloud/hcloud-cloud-controller-manager/main/deploy/ccm-networks.yaml --ignore-not-found=true
    kubectl delete secret hcloud -n kube-system --ignore-not-found=true
    info "Deleting namespaces..."
    kubectl delete namespace ingress-nginx --ignore-not-found=true
    kubectl delete namespace cert-manager --ignore-not-found=true
    kubectl delete namespace argocd --ignore-not-found=true
    success "GitOps components have been wiped from the cluster."
}
# --- 🚀 Script Execution ---
if [[ "${1:-}" == "--wipe" || "${1:-}" == "wipe" ]]; then
    deprovision
    exit 0
fi
clear
info "Starting Kubernetes GitOps Bootstrap..."
echo "----------------------------------------------------------------"
# --- Phase 1: Prerequisite Checks ---
info "Checking for required tools..."
for cmd in kubectl helm hcloud; do
  if ! command_exists ${cmd}; then error "'${cmd}' is not installed. Please install it."; exit 1; fi
done
info "Verifying Kubernetes cluster connectivity..."
if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Could not connect to a Kubernetes cluster. Is your KUBECONFIG set correctly?"
    exit 1
fi
success "All prerequisites met. Connected to cluster."
read -p "Press [Enter] to bootstrap the cluster, or [Ctrl+C] to abort..."
# --- Phase 2: Core Infrastructure Installation ---
info "Step 1: Installing Hetzner Cloud Controller Manager (CCM)..."
warn "The CCM allows Kubernetes to create Load Balancers in your Hetzner project."
info "Extracting Hetzner API token and Network Name from active hcloud context..."
HCLOUD_TOKEN=$(hcloud config get token --allow-sensitive)
if [[ -z "$HCLOUD_TOKEN" ]]; then
    error "Could not extract API token from your active hcloud context."
fi
success "Hetzner token extracted."
HCLOUD_NETWORK_NAME=$(hcloud network list -l "cluster=${CLUSTER_LABEL_NAME}" -o columns=name -o noheader)
if [[ -z "$HCLOUD_NETWORK_NAME" ]]; then
    error "Could not find a Hetzner network with the label 'cluster=${CLUSTER_LABEL_NAME}'."
fi
success "Found Hetzner network: ${HCLOUD_NETWORK_NAME}"
info "Creating the hcloud secret in the 'kube-system' namespace..."
kubectl create secret generic hcloud -n kube-system \
  --from-literal=token="$HCLOUD_TOKEN" \
  --from-literal=network="$HCLOUD_NETWORK_NAME" \
  --dry-run=client -o yaml | kubectl apply -f -
success "Secret 'hcloud' with token and network created/updated in 'kube-system'."
info "Setting Provider IDs on all nodes..."
# FIX: The CCM needs nodes to have spec.providerID set to link them to Hetzner servers
ALL_NODE_NAMES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
for NODE_NAME in $ALL_NODE_NAMES; do
    # Get the Hetzner server ID for this node
    SERVER_ID=$(hcloud server describe "${NODE_NAME}" -o json | jq -r '.id')
    if [[ -n "$SERVER_ID" && "$SERVER_ID" != "null" ]]; then
        info "Setting providerID for node ${NODE_NAME} (Hetzner ID: ${SERVER_ID})..."
        kubectl patch node "${NODE_NAME}" -p "{\"spec\":{\"providerID\":\"hcloud://${SERVER_ID}\"}}"
    else
        warn "Could not find Hetzner server ID for node ${NODE_NAME}, skipping..."
    fi
done
success "Provider IDs set on all nodes."

info "Applying the Hetzner CCM manifest..."
kubectl apply -f https://raw.githubusercontent.com/hetznercloud/hcloud-cloud-controller-manager/main/deploy/ccm-networks.yaml
info "Waiting for Hetzner CCM deployment to become available..."
kubectl wait --for=condition=Available deployment/hcloud-cloud-controller-manager -n kube-system --timeout=300s
success "Hetzner Cloud Controller Manager deployment is ready."
info "Waiting for CCM to fully initialize its LoadBalancer controller (30 seconds)..."
sleep 30
success "Hetzner Cloud Controller Manager is fully initialized and ready."
info "Step 2: Installing Ingress Controller (NGINX)..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
info "Installing/upgrading the ingress-nginx chart..."
# FIX: Add network annotation so CCM knows which Hetzner network to use for the LoadBalancer
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.annotations."load-balancer\.hetzner\.cloud/use-private-ip"="true" \
  --set controller.service.annotations."load-balancer\.hetzner\.cloud/location"="${HCLOUD_LOCATION}" \
  --set controller.service.annotations."load-balancer\.hetzner\.cloud/type"="lb11" \
  --timeout 15m
success "Ingress controller Helm installation initiated."
info "Waiting for ingress-nginx controller deployment to be available..."
kubectl wait --for=condition=Available deployment/ingress-nginx-controller -n ingress-nginx --timeout=600s
success "Ingress controller deployment is ready."
info "Waiting for the Ingress Load Balancer to get a public IP (this may take 2-3 minutes)..."
INGRESS_IP=""
TIMEOUT=300
ELAPSED=0
until [[ -n "$INGRESS_IP" ]]; do
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
        error "Timeout waiting for LoadBalancer IP. Check 'kubectl get svc -n ingress-nginx' for status."
    fi
    printf '.'
    INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
echo ""
success "Ingress controller is ready and exposed at public IP: ${INGRESS_IP}"
info "Step 3: Installing Certificate Manager (cert-manager)..."
helm repo add jetstack https://charts.jetstack.io
helm repo update
info "Installing/upgrading the cert-manager chart..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.13.2 --set installCRDs=true --wait --timeout 10m
info "Waiting for cert-manager webhook to become available..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s
success "Cert-Manager is installed and ready."
info "Step 4: Installing GitOps Operator (ArgoCD)..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
info "Installing/upgrading the argo-cd chart..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace --wait --timeout 10m
info "Waiting for ArgoCD server to become available..."
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
success "ArgoCD is installed and ready."
# --- Phase 3: GitOps Integration (App of Apps) ---
info "Step 5: Configuring ArgoCD to manage the cluster from Git..."
warn "This will create a root Application in ArgoCD pointing to ${GIT_REPO_URL}."
read -p "Press [Enter] to apply the root application manifest..."
kubectl apply -n argocd -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-cluster-config
spec:
  project: default
  source:
    repoURL: '${GIT_REPO_URL}'
    path: '${GIT_REPO_PATH}'
    targetRevision: '${GIT_REPO_BRANCH}'
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
success "Root 'App of Apps' created. ArgoCD will now synchronize the cluster state with your Git repository."
# --- ✅ Finalization ---
echo ""
echo "----------------------------------------------------------------"
success "🚀 Your cluster is now bootstrapped for GitOps management! 🚀"
echo "----------------------------------------------------------------"
echo ""
info "Next Steps:"
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
warn "Your ArgoCD admin password is: ${ARGOCD_PASSWORD}"
echo ""
info "To access the ArgoCD UI, run the following command in a new terminal:"
echo "kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Then open your browser to: https://localhost:8080"
echo "(Login with username 'admin' and the password above)"
echo ""
info "IMPORTANT: Now, you must define your cluster infrastructure (ingress, cert-manager, etc.) as ArgoCD Application manifests inside the '${GIT_REPO_PATH}' directory of your Git repository."
echo ""
