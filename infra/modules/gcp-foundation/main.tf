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
    "sqladmin.googleapis.com",
    "redis.googleapis.com",
    "servicenetworking.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

# Name knob: every resource name derives from var.name unless the per-field
# override var is set. Keeps the WIF binding (ksa_namespace_prefix/ksa_name) and
# the Helm chart's serviceAccountName/namespace aligned by construction.
locals {
  ksa_namespace_prefix = coalesce(var.ksa_namespace_prefix, var.name)
  ksa_name             = coalesce(var.ksa_name, var.name)
}

# --- Artifact Registry (Docker images) ---
resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = var.name
  format        = "DOCKER"
  description   = "OTel POC app images"
  depends_on    = [google_project_service.apis]
}

# --- Workload identity GCP service account for all workloads + the collector ---
resource "google_service_account" "app" {
  account_id   = var.name
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
    "roles/cloudsql.client",
  ]
}

resource "google_project_iam_member" "gsa" {
  for_each = toset(local.gsa_roles)
  project  = var.project
  role     = each.value
  member   = "serviceAccount:${google_service_account.app.email}"
}

# --- WIF: bind each release's KSA (<prefix>-<release>/<ksa>) to the GSA ---
resource "google_service_account_iam_member" "wif" {
  for_each           = toset(var.releases)
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[${local.ksa_namespace_prefix}-${each.value}/${local.ksa_name}]"
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

# Secret versions (the actual credentials). count-skipped when the var is empty so the
# apply succeeds before a token is on hand. The collector reads these at runtime via the
# googlesecretmanager confmap provider under Workload Identity.
resource "google_secret_manager_secret_version" "dash0_token" {
  count       = var.dash0_token == "" ? 0 : 1
  secret      = google_secret_manager_secret.dash0_token.id
  secret_data = var.dash0_token
}

resource "google_secret_manager_secret_version" "coralogix_key" {
  count       = var.coralogix_key == "" ? 0 : 1
  secret      = google_secret_manager_secret.coralogix_key.id
  secret_data = var.coralogix_key
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

# --- Cloud SQL Postgres (cheapest: db-f1-micro shared-core / ENTERPRISE / zonal / HDD / no backups) ---
resource "google_sql_database_instance" "orders" {
  name                = var.name
  database_version    = "POSTGRES_16"
  region              = var.region
  deletion_protection = false

  settings {
    tier              = "db-f1-micro"
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"
    disk_type         = "PD_HDD"
    disk_size         = 10
    disk_autoresize   = false

    backup_configuration {
      enabled = false
    }
  }

  depends_on = [google_project_service.apis]
}

# DB user the apps connect as (via the Cloud SQL Auth Proxy).
resource "google_sql_user" "app" {
  name     = "otel"
  instance = google_sql_database_instance.orders.name
  password = var.cloudsql_password
}

# Per-release logical database: orders_<release>.
resource "google_sql_database" "orders" {
  for_each = toset(var.releases)
  name     = "orders_${each.value}"
  instance = google_sql_database_instance.orders.name
}

# --- Memorystore Redis (cheapest: BASIC tier, 1 GB, direct peering on the default VPC) ---
resource "google_redis_instance" "cache" {
  name               = var.name
  display_name       = var.name
  tier               = "BASIC"
  memory_size_gb     = 1
  region             = var.region
  redis_version      = "REDIS_7_2"
  connect_mode       = "DIRECT_PEERING"
  authorized_network = "default"

  depends_on = [google_project_service.apis]
}
