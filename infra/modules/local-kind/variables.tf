variable "cluster_name" {
  description = "Name of the local kind cluster."
  type        = string
  default     = "otel-poc"
}

variable "node_image" {
  description = "kindest/node image to use for the cluster nodes. Empty string lets the provider pick its default."
  type        = string
  default     = ""
}

variable "wait_for_ready" {
  description = "Block until the control-plane is ready before returning."
  type        = bool
  default     = true
}

variable "ingress_http_host_port" {
  description = "Host port mapped to the ingress controller's HTTP (container port 80) on the control-plane node."
  type        = number
  default     = 80
}

variable "ingress_https_host_port" {
  description = "Host port mapped to the ingress controller's HTTPS (container port 443) on the control-plane node."
  type        = number
  default     = 443
}
