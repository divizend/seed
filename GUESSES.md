seed/
├─ talos/
│  ├─ cluster/
│  │  ├─ talconfig.yaml                 # ClusterConfig (Basis für talosctl gen config)
│  │  ├─ controlplane.yaml              # MachineConfig (CP)
│  │  ├─ worker.yaml                    # MachineConfig (Worker)
│  │  ├─ kubespan.md                    # kurze Notizen/Peer Discovery/Ports
│  ├─ boot/
│  │  ├─ README.md
│  │  ├─ kernel-cmdline.txt             # enthält talos.config.early=... (eine Zeile)
│  │  └─ make-inline.sh                 # Skript: YAML -> zstd -> base64 -> kernel param
│  └─ talosctl/
│     └─ genconfig.sh                   # Beispielaufrufe für gen config --with-kubespan
│
├─ sst/
│  ├─ sst.config.ts                     # SST Projektkonfiguration + Provider (Terraform Helm)
│  ├─ lib/
│  │  └─ librechat.ts                   # Deklaration des Helm Releases
│  ├─ providers/
│  │  └─ helm.tf.json                   # (optional) Provider wiring als JSON aus TS generiert
│  └─ values/
│     └─ librechat.values.yaml          # Chart-Values (Ingress, Secrets, Storage, ...)
│
├─ k8s/
│  ├─ namespaces/librechat.yaml         # Namespace-Manifest
│  └─ ingress/                          # falls eigener IngressController/Cert-Setup
│
└─ README.md
