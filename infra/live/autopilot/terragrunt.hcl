include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "../../modules/gcp-autopilot"
}

inputs = {
  project = "focal-fossa-dev"
  region  = "us-central1"

  cluster_name = "otel-poc"
}
