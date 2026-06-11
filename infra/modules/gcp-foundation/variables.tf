variable "project" {
  type        = string
  description = "GCP project id"
}

variable "region" {
  type        = string
  description = "GCP region for the Autopilot cluster, Artifact Registry, and data resources"
  default     = "us-central1"
}

variable "cluster_name" {
  type    = string
  default = "otel-poc"
}

variable "releases" {
  type        = list(string)
  description = "Per-provider release names; each gets its own Pub/Sub topic+subscription and a WIF binding"
  default     = ["google", "dash0", "coralogix"]
}

variable "ksa_namespace_prefix" {
  type        = string
  description = "Namespace prefix each release deploys into (otel-poc-<release>)"
  default     = "otel-poc"
}

variable "ksa_name" {
  type        = string
  description = "Kubernetes ServiceAccount name the workloads run as (created by Helm)"
  default     = "otel-poc"
}

variable "create_firestore" {
  type        = bool
  description = "Create the (default) Firestore database. Set false if the project already has one."
  default     = true
}

variable "cloudsql_password" {
  type        = string
  description = "Password for the Cloud SQL 'otel' app user (POC default; override for anything real)."
  sensitive   = true
  default     = "otelpoc-dev-pw"
}
