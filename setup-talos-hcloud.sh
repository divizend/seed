#!/bin/bash

#================================================================================#
#         Fully Automated Talos Kubernetes Cluster on Hetzner Cloud          #
#================================================================================#
#  This script automates the entire lifecycle of a Talos cluster on Hetzner:   #
#  1. Provisions all infrastructure (network, firewall, servers) using `hcloud`.#
#     -> It's idempotent: if resources exist, they are adopted.                #
#  2. Deploys a secure Talos cluster with KubeSpan (WireGuard) using `talosctl`. #
#  3. Provides a single command to destroy all created resources.              #
#================================================================================#

# --- 📝 PRE-REQUISITES: Your Local Machine ---
#
# 1.  **Hetzner Cloud CLI**: Install `hcloud`.
#     - `brew install hcloud` or download from GitHub.
#     - Run `hcloud context create <my-project>` and provide your API token.
#
# 2.  **Other Tools**: Ensure `kubectl`, `talosctl`, `jq`, `dig`, and `nc` (netcat) are installed.
#
# 3.  **DNS Provider Access**: You will need to manually create one 'A' record
#     when the script prompts you to do so.
#
#================================================================================#

# Stop script on any error and treat unset variables as an error.
set -euo pipefail

# --- ⚙️ Cluster Configuration (CHANGE THESE VALUES) ---

# A unique name for your cluster. Used for naming and labeling all resources.
readonly CLUSTER_NAME="divizend-ai-prod"

# The DNS name you will point to the cluster's Floating IP.
readonly CLUSTER_ENDPOINT_DNS="k8s-api.divizend.ai"

# Hetzner Cloud settings
readonly HCLOUD_LOCATION="fsn1"     # Falkenstein
readonly HCLOUD_CP_TYPE="cpx21"     # Control Plane server type (e.g., 3 vCPU, 4GB RAM)
readonly HCLOUD_WORKER_TYPE="cpx21" # Worker server type
readonly HCLOUD_WORKER_COUNT=2      # Number of worker nodes to create
readonly HCLOUD_TALOS_ISO="122630"  # Specific Talos ISO ID provided by Hetzner

# --- 🎨 Logging and Helper Functions ---
info() { printf '\n\e[34m[INFO]\e[0m %s\n' "$1"; }
success() { printf '\e[32m[SUCCESS]\e[0m %s\n' "$1"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$1"; }
error() { printf '\n\e[31m[ERROR]\e[0m %s\n' "$1" >&2; exit 1; }
command_exists() { command -v "$1" &>/dev/null; }

# --- 🧹 Deprovisioning Function ---
deprovision() {
    info "Deprovisioning all resources for cluster '${CLUSTER_NAME}'..."
    readonly CLUSTER_LABEL="cluster=${CLUSTER_NAME}"
    
    warn "This will permanently delete all servers, floating IPs, firewalls, and networks with the label ${CLUSTER_LABEL}."
    read -p "Are you sure you want to continue? (y/N) " -n 1 -r; echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Aborting deprovisioning."
        exit 1
    fi

    info "Deleting servers..."
    SERVER_NAMES=$(hcloud server list -l "${CLUSTER_LABEL}" -o columns=name -o noheader)
    if [[ -n "$SERVER_NAMES" ]]; then
        echo "$SERVER_NAMES" | xargs hcloud server delete
    else
        success "No servers found to delete."
    fi
    
    info "Deleting floating IPs..."
    FLOATING_IP_NAMES=$(hcloud floating-ip list -l "${CLUSTER_LABEL}" -o columns=name -o noheader)
    if [[ -n "$FLOATING_IP_NAMES" ]]; then
        echo "$FLOATING_IP_NAMES" | xargs hcloud floating-ip delete
    else
        success "No floating IPs found to delete."
    fi
    
    info "Deleting firewalls..."
    FIREWALL_NAMES=$(hcloud firewall list -l "${CLUSTER_LABEL}" -o columns=name -o noheader)
    if [[ -n "$FIREWALL_NAMES" ]]; then
        echo "$FIREWALL_NAMES" | xargs hcloud firewall delete
    else
        success "No firewalls found to delete."
    fi

    info "Deleting networks..."
    NETWORK_NAMES=$(hcloud network list -l "${CLUSTER_LABEL}" -o columns=name -o noheader)
    if [[ -n "$NETWORK_NAMES" ]]; then
        echo "$NETWORK_NAMES" | xargs hcloud network delete
    else
        success "No networks found to delete."
    fi
    
    info "Cleaning up local configuration files..."
    rm -rf "./clusterconfig_${CLUSTER_NAME}"
    rm -f "./${CLUSTER_NAME}.kubeconfig"

    success "All resources for cluster '${CLUSTER_NAME}' have been deprovisioned."
}


# --- 🚀 Script Execution ---

if [[ "${1:-}" == "--wipe" || "${1:-}" == "wipe" ]]; then
    deprovision
    exit 0
fi

clear
info "Starting Fully Automated Talos Cluster Setup: ${CLUSTER_NAME}"
echo "----------------------------------------------------------------"

# --- Phase 1: Prerequisite & Configuration Checks ---
info "Checking for required tools..."
for cmd in hcloud kubectl talosctl jq dig nc; do
  if ! command_exists ${cmd}; then
    error "'${cmd}' is not installed. Please install it before running."
  fi
done
if ! hcloud context active &>/dev/null; then
  error "No active Hetzner Cloud context. Please run 'hcloud context create <name>'."
fi
success "All required tools are present."

info "Configuration:"
echo "  - Cluster Name: ${CLUSTER_NAME}"
echo "  - k8s Endpoint: https://${CLUSTER_ENDPOINT_DNS}:6443"
echo "  - Hetzner Location: ${HCLOUD_LOCATION}"
read -p "Press [Enter] to provision this infrastructure, or [Ctrl+C] to abort..."

# --- Phase 2: Provision Hetzner Cloud Infrastructure ---

readonly CLUSTER_LABEL="cluster=${CLUSTER_NAME}"
readonly CONFIG_DIR="./clusterconfig_${CLUSTER_NAME}"
readonly FIREWALL_NAME="${CLUSTER_NAME}-fw"
readonly NETWORK_NAME="${CLUSTER_NAME}-net"

info "Fetching latest Kubernetes version..."
KUBERNETES_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
success "Found latest stable Kubernetes release: ${KUBERNETES_VERSION}"

info "Provisioning Hetzner infrastructure for '${CLUSTER_NAME}'..."

if ! hcloud network describe "${NETWORK_NAME}" >/dev/null 2>&1; then
  hcloud network create --name "${NETWORK_NAME}" --ip-range 10.0.0.0/16 --label "${CLUSTER_LABEL}" >/dev/null
  hcloud network add-subnet "${NETWORK_NAME}" --network-zone eu-central --type cloud --ip-range 10.0.0.0/16 >/dev/null
  success "Private Network '${NETWORK_NAME}' created."
else
  success "Private Network '${NETWORK_NAME}' already exists, adopting."
fi

if ! hcloud firewall describe "${FIREWALL_NAME}" >/dev/null 2>&1; then
  hcloud firewall create --name "${FIREWALL_NAME}" --label "${CLUSTER_LABEL}" >/dev/null
  hcloud firewall add-rule "${FIREWALL_NAME}" --direction in --protocol tcp --port 6443 --source-ips "0.0.0.0/0,::/0" >/dev/null
  hcloud firewall add-rule "${FIREWALL_NAME}" --direction in --protocol tcp --port 50000 --source-ips "0.0.0.0/0,::/0" >/dev/null
  hcloud firewall add-rule "${FIREWALL_NAME}" --direction in --protocol udp --port 50001 --source-ips "10.0.0.0/16" >/dev/null
  success "Firewall '${FIREWALL_NAME}' created."
else
  success "Firewall '${FIREWALL_NAME}' already exists, adopting."
fi

CP_NAME="${CLUSTER_NAME}-cp-1"
if ! hcloud server describe "${CP_NAME}" >/dev/null 2>&1; then
  info "Creating control plane server '${CP_NAME}'..."
  hcloud server create --name "${CP_NAME}" --type "${HCLOUD_CP_TYPE}" --location "${HCLOUD_LOCATION}" \
    --image "ubuntu-22.04" --network "${NETWORK_NAME}" --firewall "${FIREWALL_NAME}" \
    --label "${CLUSTER_LABEL}" >/dev/null
  success "Control plane server '${CP_NAME}' created."
else
  success "Control plane server '${CP_NAME}' already exists, adopting."
fi
info "Ensuring Talos ISO is attached to ${CP_NAME} and rebooting..."
hcloud server attach-iso "${CP_NAME}" "${HCLOUD_TALOS_ISO}" >/dev/null
hcloud server reset "${CP_NAME}" >/dev/null

WORKER_NAMES=()
for i in $(seq 1 ${HCLOUD_WORKER_COUNT}); do
  WORKER_NAME="${CLUSTER_NAME}-worker-${i}"
  WORKER_NAMES+=("${WORKER_NAME}")
  if ! hcloud server describe "${WORKER_NAME}" >/dev/null 2>&1; then
    info "Creating worker server '${WORKER_NAME}'..."
    hcloud server create --name "${WORKER_NAME}" --type "${HCLOUD_WORKER_TYPE}" --location "${HCLOUD_LOCATION}" \
      --image "ubuntu-22.04" --network "${NETWORK_NAME}" --firewall "${FIREWALL_NAME}" \
      --label "${CLUSTER_LABEL}" >/dev/null
    success "Worker server '${WORKER_NAME}' created."
  else
    success "Worker server '${WORKER_NAME}' already exists, adopting."
  fi
  info "Ensuring Talos ISO is attached to ${WORKER_NAME} and rebooting..."
  hcloud server attach-iso "${WORKER_NAME}" "${HCLOUD_TALOS_ISO}" >/dev/null
  hcloud server reset "${WORKER_NAME}" >/dev/null
done

VIP=$(hcloud floating-ip describe "${CLUSTER_NAME}-vip" -o json 2>/dev/null | jq -r .ip || true)
if [[ -z "$VIP" ]]; then
  VIP=$(hcloud floating-ip create --type ipv4 --name "${CLUSTER_NAME}-vip" --home-location "${HCLOUD_LOCATION}" --label "${CLUSTER_LABEL}" -o json | jq -r .floating_ip.ip)
  hcloud floating-ip assign "${CLUSTER_NAME}-vip" "${CP_NAME}" >/dev/null
  success "Floating IP ${VIP} created and assigned to control plane ${CP_NAME}."
else
  hcloud floating-ip assign "${CLUSTER_NAME}-vip" "${CP_NAME}" >/dev/null
  success "Floating IP ${VIP} already exists, adopting and ensuring assignment to ${CP_NAME}."
fi

info "ACTION REQUIRED: Please create a DNS 'A' record if it doesn't exist:"
echo "  - Hostname: ${CLUSTER_ENDPOINT_DNS}"
echo "  - Value:    ${VIP}"
info "Waiting for DNS to propagate..."
until dig +short "${CLUSTER_ENDPOINT_DNS}" | grep -q "^${VIP}$"; do
    printf '.'
    sleep 5
done
success "DNS record for ${CLUSTER_ENDPOINT_DNS} is correctly pointing to ${VIP}."

# --- Phase 3: Deploy Talos Cluster ---

CONTROL_PLANE_PUBLIC_IP=$(hcloud server describe "${CP_NAME}" -o json | jq -r '.public_net.ipv4.ip')
WORKER_PUBLIC_IPS=()
for WORKER_NAME in "${WORKER_NAMES[@]}"; do
  IP=$(hcloud server describe "${WORKER_NAME}" -o json | jq -r '.public_net.ipv4.ip')
  WORKER_PUBLIC_IPS+=("${IP}")
done

info "Waiting for Talos API on control plane (${CONTROL_PLANE_PUBLIC_IP}:50000) to become available..."
until nc -z -w 5 "${CONTROL_PLANE_PUBLIC_IP}" 50000; do
  printf '.'
  sleep 5
done
success "Control plane (${CONTROL_PLANE_PUBLIC_IP}) is ready for configuration."

mkdir -p "${CONFIG_DIR}"
info "Generating Talos configuration files in '${CONFIG_DIR}'..."

PATCH_FILE="${CONFIG_DIR}/controlplane-patch.yaml"
# FIX: Reverted to the `bind-address` and `aliases` patch, which is the correct combination for this scenario.
cat > "${PATCH_FILE}" <<EOF
- op: add
  path: /machine/network/extraHostEntries
  value:
    - ip: 127.0.0.1
      aliases:
        - ${CLUSTER_ENDPOINT_DNS}
- op: add
  path: /cluster/apiServer/extraArgs
  value:
    bind-address: 0.0.0.0
EOF
success "Created control plane patch for network reflection and public API binding."

talosctl gen config "${CLUSTER_NAME}" "https://${CLUSTER_ENDPOINT_DNS}:6443" \
  --output-dir "${CONFIG_DIR}" \
  --kubernetes-version "${KUBERNETES_VERSION}" \
  --with-kubespan=true \
  --config-patch-control-plane "@${PATCH_FILE}"

rm -f "${PATCH_FILE}"
success "Configuration files generated and patch file cleaned up."

info "Applying configuration to all nodes..."
talosctl apply-config --insecure --file "${CONFIG_DIR}/controlplane.yaml" --nodes "${CONTROL_PLANE_PUBLIC_IP}"
success "Configuration applied to control plane ${CONTROL_PLANE_PUBLIC_IP}."

for IP in "${WORKER_PUBLIC_IPS[@]}"; do
  info "Waiting for Talos API on worker (${IP}:50000) to become available..."
  until nc -z -w 5 "${IP}" 50000; do
    printf '.'
    sleep 5
  done
  success "Worker (${IP}) is ready for configuration."
  info "Applying configuration to worker ${IP}..."
  talosctl apply-config --insecure --file "${CONFIG_DIR}/worker.yaml" --nodes "${IP}"
  success "Configuration applied to worker ${IP}."
done
success "All nodes have received their configuration and will reboot."

info "Waiting for SECURE Talos API on control plane (${CONTROL_PLANE_PUBLIC_IP}) to return after reboot..."
until talosctl --talosconfig "${CONFIG_DIR}/talosconfig" --nodes "${CONTROL_PLANE_PUBLIC_IP}" --endpoints "${CONTROL_PLANE_PUBLIC_IP}" version >/dev/null 2>&1; do
  printf '.'
  sleep 5
done
success "Secure API on control plane (${CONTROL_PLANE_PUBLIC_IP}) is responsive."

info "Bootstrapping the cluster on ${CONTROL_PLANE_PUBLIC_IP}..."
talosctl bootstrap --talosconfig "${CONFIG_DIR}/talosconfig" --nodes "${CONTROL_PLANE_PUBLIC_IP}" --endpoints "${CONTROL_PLANE_PUBLIC_IP}"
success "Bootstrap command sent successfully."

info "Waiting for Kubernetes API server (${CONTROL_PLANE_PUBLIC_IP}:6443) to become available..."
until nc -z -w 5 "${CONTROL_PLANE_PUBLIC_IP}" 6443; do
  printf '.'
  sleep 5
done
success "Kubernetes API server is ready."

# --- Phase 4: Cluster Verification & Finalization ---
KUBECONFIG_PATH="$(pwd)/${CLUSTER_NAME}.kubeconfig"
info "Retrieving kubeconfig from ${CONTROL_PLANE_PUBLIC_IP}..."
talosctl kubeconfig --talosconfig "${CONFIG_DIR}/talosconfig" --nodes "${CONTROL_PLANE_PUBLIC_IP}" --endpoints "${CONTROL_PLANE_PUBLIC_IP}" "${KUBECONFIG_PATH}"
chmod 600 "${KUBECONFIG_PATH}"
export KUBECONFIG="${KUBECONFIG_PATH}"
success "Kubeconfig saved to ${KUBECONFIG_PATH} with secure permissions."

info "Waiting for all Kubernetes nodes to become 'Ready'..."
TOTAL_NODES=$((HCLOUD_WORKER_COUNT + 1))
while true; do
  READY_NODES=$(kubectl get nodes -o json 2>/dev/null | jq '[.items[] | select(.spec.providerID != "" and (.status.conditions[] | select(.type == "Ready" and .status == "True"))) ] | length' 2>/dev/null || echo 0)
  if [[ "${READY_NODES}" -eq "${TOTAL_NODES}" ]]; then
    echo "" && success "All ${TOTAL_NODES} nodes are now Ready!"
    break
  fi
  printf "\r\e[34m[INFO]\e[0m  Waiting for all nodes to become Ready... [${READY_NODES}/${TOTAL_NODES}]"
  sleep 10
done

info "Performing final cluster health check on ${CONTROL_PLANE_PUBLIC_IP}..."
talosctl --talosconfig "${CONFIG_DIR}/talosconfig" --nodes "${CONTROL_PLANE_PUBLIC_IP}" --endpoints "${CONTROL_PLANE_PUBLIC_IP}" health
success "Cluster health checks passed."

# --- ✅ Finalization ---
echo ""
echo "----------------------------------------------------------------"
success "🚀 Your Talos Kubernetes cluster '${CLUSTER_NAME}' is ready! 🚀"
echo "----------------------------------------------------------------"
echo ""
info "Verifying cluster access by listing all nodes:"
kubectl get nodes -o wide
echo ""
info "To manage your cluster, use the generated kubeconfig:"
echo "export KUBECONFIG='${KUBECONFIG_PATH}'"
echo ""
warn "The directory '${CONFIG_DIR}' contains sensitive cluster PKI keys. Keep it safe."
echo ""
warn "To DESTROY ALL cloud resources for this cluster, run: $0 --wipe"
echo ""
