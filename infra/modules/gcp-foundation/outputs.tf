output "gsa_email" {
  value = google_service_account.app.email
}

output "artifact_registry" {
  description = "Docker image path prefix"
  value       = "${var.region}-docker.pkg.dev/${var.project}/${google_artifact_registry_repository.docker.repository_id}"
}

output "pubsub_topics" {
  value = { for k, t in google_pubsub_topic.orders : k => t.name }
}

output "cloudsql_connection_name" {
  description = "Cloud SQL instance connection name (project:region:instance) for the Auth Proxy."
  value       = google_sql_database_instance.orders.connection_name
}

output "cloudsql_user" {
  value = "otel"
}

output "redis_host" {
  value = google_redis_instance.cache.host
}

output "redis_port" {
  value = google_redis_instance.cache.port
}
