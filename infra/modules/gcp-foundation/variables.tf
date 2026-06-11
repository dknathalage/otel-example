variable "project" {
  type        = string
  description = "GCP project id"
}

variable "region" {
  type        = string
  description = "GCP region for the Autopilot cluster, Artifact Registry, and data resources"
  default     = "us-central1"
}

variable "name" {
  type        = string
  description = "Base name for all resources (Artifact Registry repo, GSA, Cloud SQL, Redis, and the default cluster/KSA names). Override individual names below if needed."
  default     = "otel-poc"
}

variable "cluster_name" {
  type        = string
  description = "GKE cluster name. Empty => derive from var.name."
  default     = ""
}

variable "releases" {
  type        = list(string)
  description = "Per-provider release names; each gets its own Pub/Sub topic+subscription and a WIF binding"
  default     = ["google", "dash0", "coralogix"]
}

variable "ksa_namespace_prefix" {
  type        = string
  description = "Namespace prefix each release deploys into (<prefix>-<release>). Empty => derive from var.name."
  default     = ""
}

variable "ksa_name" {
  type        = string
  description = "Kubernetes ServiceAccount name the workloads run as (created by Helm). Empty => derive from var.name."
  default     = ""
}

variable "create_firestore" {
  type        = bool
  description = "Create the (default) Firestore database. Set false if the project already has one."
  default     = true
}

# The Cloud SQL app-user password is generated (random_password.cloudsql) — never
# a hardcoded default. Read it from the `cloudsql_password` output (sensitive).

# Backend credentials written into GSM. Supply via TF_VAR_dash0_token / TF_VAR_coralogix_key
# (or a gitignored/sops tfvars). Empty default => the secret version is skipped, so the
# apply stays clean before a token is available.
variable "dash0_token" {
  type        = string
  description = "Dash0 ingest auth token (Bearer). Stored in the dash0-token GSM secret."
  sensitive   = true
  default     = ""
}

variable "coralogix_key" {
  type        = string
  description = "Coralogix Send-Your-Data API key. Stored in the coralogix-key GSM secret."
  sensitive   = true
  default     = ""
}
