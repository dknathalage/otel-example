variable "project" {
  type        = string
  description = "GCP project id"
}

variable "region" {
  type        = string
  description = "GCP region for the Autopilot cluster"
  default     = "us-central1"
}

variable "cluster_name" {
  type    = string
  default = "otel-poc"
}
