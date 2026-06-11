# --- API required for the Autopilot cluster ---
resource "google_project_service" "container" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

locals {
  cluster_name = coalesce(var.cluster_name, var.name)
}

# --- GKE Autopilot cluster (cheap: pay-per-pod, Workload Identity built in) ---
resource "google_container_cluster" "this" {
  name                = local.cluster_name
  location            = var.region
  enable_autopilot    = true
  deletion_protection = false
  depends_on          = [google_project_service.container]
}
