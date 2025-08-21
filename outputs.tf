output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.primary.name
}


