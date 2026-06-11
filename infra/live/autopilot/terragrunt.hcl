include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "../../modules/gcp-autopilot"
}

inputs = {
  project = get_env("GCP_PROJECT")
  region  = get_env("GCP_REGION", "us-central1")
}
