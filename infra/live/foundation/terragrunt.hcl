include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "../../modules/gcp-foundation"
}

inputs = {
  project = get_env("GCP_PROJECT")
  region  = get_env("GCP_REGION", "us-central1")

  releases = ["google", "dash0", "coralogix"]

  # Set false if the project already has a (default) Firestore database.
  create_firestore = true
}
