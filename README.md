# Fully Automated Talos Cluster on Hetzner Cloud

This script completely automates the creation and destruction of a production-ready, secure Kubernetes cluster using Talos on Hetzner Cloud.

It is fully idempotent, meaning it can be run multiple times without causing errors. If resources already exist, it will adopt them; if they don't, it will create them. The script handles everything from provisioning servers and networking to configuring the Kubernetes control plane with all necessary patches for a cloud environment.

## To Do

- [ ] Fix that the script stays stuck at `Waiting for all nodes to become Ready... [0/3]`. Potential solution: Because the kube API server is only listening on the local network, we need to add a load balancer in front of it. `bind-address: 0.0.0.0` doesn't seem to work.
- [ ] Add the best, most universally accepted control panel(s) (kube-prometheus-stack? ArgoCD? others? -> research)
- [ ] Add k8s MCP server, deploy LibreChat and connect the two.

## Features

- **Fully Automated**: From zero to a running Kubernetes cluster with a single command.
- **Idempotent**: Safe to re-run. The script intelligently creates or adopts existing infrastructure.
- **Production-Ready**:
    - **High-Availability Ready**: Uses a floating IP for a stable control plane endpoint.
    - **Secure by Default**: Deploys Talos with a minimal attack surface and an encrypted network backend (KubeSpan via WireGuard).
    - **Correctly Patched**: Automatically applies the necessary patches for NAT reflection (hairpinning) and public API access.
- **Easy Cleanup**: A simple `--wipe` command de-provisions all created cloud resources.

---

##  Prerequisites

Before you begin, make sure you have the following tools installed on your local machine:

1.  **Hetzner Cloud CLI**: `hcloud`
    - You must have a context created and active: `hcloud context create my-project`
2.  **Kubernetes CLI**: `kubectl`
3.  **Talos CLI**: `talosctl`
4.  **Helper Tools**: `jq`, `dig`, and `nc` (netcat)

---

## Configuration

All user-configurable variables are located at the top of the `setup-talos-hcloud.sh` script. You **must** edit these before running the script for the first time.

```bash
# --- ⚙️ Cluster Configuration (CHANGE THESE VALUES) ---

# A unique name for your cluster. Used for naming and labeling all resources.
readonly CLUSTER_NAME="divizend-ai-prod"

# The DNS name you will point to the cluster's Floating IP.
readonly CLUSTER_ENDPOINT_DNS="k8s-api.divizend.ai"

# Hetzner Cloud settings
readonly HCLOUD_LOCATION="fsn1"     # Falkenstein
readonly HCLOUD_CP_TYPE="cpx21"     # Control Plane server type
readonly HCLOUD_WORKER_TYPE="cpx21" # Worker server type
readonly HCLOUD_WORKER_COUNT=2      # Number of worker nodes
readonly HCLOUD_TALOS_ISO="122630"  # Specific Talos ISO ID
```

## Usage

Make the script executable first:

```bash
chmod +x setup-talos-hcloud.sh
```

### To Create the Cluster

Simply run the script. It will guide you through the process.

```bash
./setup-talos-hcloud.sh
```

The script will provision all resources and, upon completion, generate two important files in your current directory:

- `divizend-ai-prod.kubeconfig`: Your `kubeconfig` file for accessing the cluster with `kubectl`.
- `clusterconfig_divizend-ai-prod/`: A directory containing the sensitive Talos PKI infrastructure. **Keep this directory safe!**

### To Destroy the Cluster

To completely remove all cloud infrastructure created by this script, use the `--wipe` flag.

```bash
./setup-talos-hcloud.sh --wipe
```

This command will find all resources associated with your `CLUSTER_NAME` label and permanently delete them.
