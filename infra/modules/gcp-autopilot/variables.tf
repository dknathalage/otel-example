variable "project" {
  type        = string
  description = "GCP project id"
}

variable "region" {
  type        = string
  description = "GCP region for the Autopilot cluster"
  default     = "us-central1"
}

variable "name" {
  type        = string
  description = "Base name; the cluster name derives from this unless cluster_name is set."
  default     = "otel-poc"
}

variable "cluster_name" {
  type        = string
  description = "GKE cluster name. Empty => derive from var.name."
  default     = ""
}
