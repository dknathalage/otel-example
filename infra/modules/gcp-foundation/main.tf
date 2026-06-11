# --- APIs (most already enabled on the project; declared for idempotency) ---
locals {
  apis = [
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "pubsub.googleapis.com",
    "firestore.googleapis.com",
    "cloudtrace.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "telemetry.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

# --- Artifact Registry (Docker images) ---
resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = "otel-poc"
  format        = "DOCKER"
  description   = "OTel POC app images"
  depends_on    = [google_project_service.apis]
}

# --- Workload identity GCP service account for all workloads + the collector ---
resource "google_service_account" "app" {
  account_id   = "otel-poc"
  display_name = "OTel POC workloads"
}

# Roles the collector + apps need.
# Cloud Trace / Monitoring / Logging cover what telemetry.googleapis.com routes to;
# pubsub.editor = publish+subscribe; datastore.user = Firestore; secretAccessor = GSM.
locals {
  gsa_roles = [
    "roles/cloudtrace.agent",
    "roles/monitoring.metricWriter",
    "roles/logging.logWriter",
    "roles/telemetry.tracesWriter",
    "roles/telemetry.metricsWriter",
    "roles/telemetry.logsWriter",
    "roles/secretmanager.secretAccessor",
    "roles/pubsub.editor",
    "roles/datastore.user",
  ]
}

resource "google_project_iam_member" "gsa" {
  for_each = toset(local.gsa_roles)
  project  = var.project
  role     = each.value
  member   = "serviceAccount:${google_service_account.app.email}"
}

# --- WIF: bind each release's KSA (otel-poc-<release>/otel-poc) to the GSA ---
resource "google_service_account_iam_member" "wif" {
  for_each           = toset(var.releases)
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[${var.ksa_namespace_prefix}-${each.value}/${var.ksa_name}]"
}

# --- GSM secret containers (versions added out-of-band when tokens are available) ---
resource "google_secret_manager_secret" "dash0_token" {
  secret_id = "dash0-token"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret" "coralogix_key" {
  secret_id = "coralogix-key"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

# --- Per-release Pub/Sub topic + subscription ---
resource "google_pubsub_topic" "orders" {
  for_each   = toset(var.releases)
  name       = "orders-${each.value}"
  depends_on = [google_project_service.apis]
}

resource "google_pubsub_subscription" "orders" {
  for_each = toset(var.releases)
  name     = "orders-${each.value}-sub"
  topic    = google_pubsub_topic.orders[each.value].name

  ack_deadline_seconds       = 30
  message_retention_duration = "600s"
}

# --- Firestore (Native). One default DB per project; releases isolate via collection prefix. ---
resource "google_firestore_database" "default" {
  count       = var.create_firestore ? 1 : 0
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"
  depends_on  = [google_project_service.apis]
}
