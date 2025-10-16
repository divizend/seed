talosctl gen config --with-docs=false --with-examples=false --with-kubespan=true seed-talos-cluster https://k8s.divizend.ai:6443



talosctl --nodes api.divizend.ai apply-config --file controlplane.yaml --insecure --talosconfig ./talosconfig

grpcurl -vv -insecure api.divizend.ai:50000 list



Continue: https://docs.siderolabs.com/talos/v1.11/getting-started/getting-started
