#!/bin/bash

#================================================================================#
#                  Kubernetes GitOps Bootstrap Script                          #
#================================================================================#
#  This script bootstraps a fresh Kubernetes cluster for GitOps management.      #
#  It installs and configures:                                                   #
#  1. An Ingress Controller (NGINX) to handle external traffic.                #
#  2. Cert-Manager to automate TLS certificates via Let's Encrypt.             #
#  3. ArgoCD as the GitOps continuous delivery tool.                           #
#  4. An ArgoCD "App of Apps" to manage the cluster from a Git repository.       #
#================================================================================#

# --- 📝 PRE-REQUISITES: Your Local Machine ---
#
# 1.  **A Running Kubernetes Cluster**: This script assumes your cluster is up.
# 2.  **A Valid Kubeconfig**: Your KUBECONFIG environment variable must be set,
#     or the config must be at the default location (`~/.kube/config`).
# 3.  **Required Tools**: `kubectl`, `helm`.
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

# --- 🎨 Logging and Helper Functions ---
info() { printf '\n\e[34m[INFO]\e[0m %s\n' "$1"; }
success() { printf '\e[32m[SUCCESS]\e[0m %s\n' "$1"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$1"; }
error() { printf '\n\e[31m[ERROR]\e[0m %s\n' "$1" >&2; exit 1; }
command_exists() { command -v "$1" &>/dev/null; }

# --- 🧹 Deprovisioning Function ---
deprovision() {
    info "Wiping all bootstrapped GitOps components from the cluster..."
    warn "This will delete ArgoCD, Cert-Manager, Ingress-NGINX, and all related resources."
    read -p "Are you sure you want to continue? (y/N) " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Aborting wipe."
        exit 1
    fi

    info "Deleting the root ArgoCD application..."
    kubectl delete application root-cluster-config -n argocd --ignore-not-found=true

    info "Uninstalling Helm charts..."
    helm uninstall argocd -n argocd 2>/dev/null || true
    helm uninstall cert-manager -n cert-manager 2>/dev/null || true
    helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
    
    info "Deleting namespaces..."
    kubectl delete namespace argocd --ignore-not-found=true
    kubectl delete namespace cert-manager --ignore-not-found=true
    kubectl delete namespace ingress-nginx --ignore-not-found=true

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
for cmd in kubectl helm; do
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

info "Step 1: Installing Ingress Controller (NGINX)..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1
helm repo update >/dev/null 2>&1
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait
success "Ingress controller installed. Waiting for public IP..."

INGRESS_IP=""
until [[ -n "$INGRESS_IP" ]]; do
    INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$INGRESS_IP" ]]; then
        success "Ingress controller is ready and exposed at public IP: ${INGRESS_IP}"
    else
        printf '.'
        sleep 5
    fi
done

info "Step 2: Installing Certificate Manager (cert-manager)..."
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1
helm repo update >/dev/null 2>&1
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.13.2 --set installCRDs=true --wait
info "Waiting for cert-manager webhook to become available..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s
success "Cert-Manager is installed and ready."

info "Step 3: Installing GitOps Operator (ArgoCD)..."
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1
helm repo update >/dev/null 2>&1
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace --wait
info "Waiting for ArgoCD server to become available..."
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
success "ArgoCD is installed and ready."

# --- Phase 3: GitOps Integration (App of Apps) ---

info "Step 4: Configuring ArgoCD to manage the cluster from Git..."
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
