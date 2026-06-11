# Local environment: a single-node kind cluster named "otel-poc".
#
# APPLY PREREQUISITE (podman runtime): export the variables from the repo
# `env.sh` first, e.g.
#
#   source env.sh
#   # which sets:
#   #   export KIND_EXPERIMENTAL_PROVIDER=podman
#   #   export DOCKER_HOST="unix://<podman socket>"
#
# Cluster creation (`terragrunt apply`) is Phase 8, not Phase 7.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "../../modules/local-kind"
}

inputs = {
  cluster_name            = "otel-poc"
  wait_for_ready          = true
  ingress_http_host_port  = 80
  ingress_https_host_port = 443
}
