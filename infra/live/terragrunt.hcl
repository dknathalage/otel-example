# Root Terragrunt configuration for the OTel multi-backend POC.
#
# State is kept locally under each unit's .terragrunt-cache (relative path),
# which is fine for a POC. Child units `include` this file to inherit the
# backend and the shared inputs below.

remote_state {
  backend = "local"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    path = "${path_relative_to_include()}/terraform.tfstate"
  }
}

# Shared inputs available to every environment.
inputs = {
  cluster_name = "otel-poc"
}
