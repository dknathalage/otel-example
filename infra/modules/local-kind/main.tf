# Local kind cluster for the OTel multi-backend POC.
#
# RUNTIME NOTE (podman): this repo uses podman as the container runtime, so the
# kind provider must talk to the podman socket. Before running `tofu/terragrunt
# apply` you MUST export (see repo `env.sh`):
#
#   export KIND_EXPERIMENTAL_PROVIDER=podman
#   export DOCKER_HOST="unix://<podman socket>"   # e.g. the podman-machine api.sock
#
# `source env.sh` from the repo root sets both. Apply happens in Phase 8, not here.

resource "kind_cluster" "otel_poc" {
  name           = var.cluster_name
  node_image     = var.node_image != "" ? var.node_image : null
  wait_for_ready = var.wait_for_ready

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # Label the control-plane so an ingress controller (e.g. ingress-nginx)
      # schedules here, matching the extra_port_mappings below.
      kubeadm_config_patches = [
        <<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        EOT
      ]

      # Expose the ingress controller to the host so the web app and the
      # browser OTLP endpoint are reachable from outside the cluster.
      extra_port_mappings {
        container_port = 80
        host_port      = var.ingress_http_host_port
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = var.ingress_https_host_port
        protocol       = "TCP"
      }
    }
  }
}
