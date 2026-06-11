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
# APP_NAME is the single base-name knob; foundation and autopilot derive every
# resource/cluster/KSA name from it. Defaults to "otel-poc" when unset.
inputs = {
  name = get_env("APP_NAME", "otel-poc")
}
