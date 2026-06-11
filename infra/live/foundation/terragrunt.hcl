include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "../../modules/gcp-foundation"
}

inputs = {
  project = "focal-fossa-dev"
  region  = "us-central1"

  cluster_name = "otel-poc"
  releases     = ["google", "dash0", "coralogix"]

  # Set false if the project already has a (default) Firestore database.
  create_firestore = true
}
