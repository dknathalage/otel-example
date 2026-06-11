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
