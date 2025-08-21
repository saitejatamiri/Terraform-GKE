terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0.0"
    }
  }
}

provider "google" {
  # --- ⚠️ REQUIRED ---
  # Replace "your-gcp-project-id" with your actual Google Cloud Project ID.
  project = "new-project-462710"

  # --- Optional ---
  # You can change the region to your preferred location.
  region = "us-central1"
}

resource "google_container_cluster" "primary" {
  # --- ⚠️ REQUIRED ---
  # Provide a unique name for your GKE cluster.
  name = "my-gke-cluster"

  # --- FIX FOR QUOTA ERROR ---
  # Change the location from a region ("us-central1") to a specific zone
  # ("us-central1-a") to create a ZONAL cluster instead of a REGIONAL one.
  # This creates nodes in only one zone, significantly reducing resource usage.
  location = "us-central1-a"
  deletion_protection = false

  # The number of nodes to create in this cluster's default node pool.
  initial_node_count = 2

  # Configuration for the nodes in the default node pool.
  node_config {
    # The machine type to use for the nodes. "e2-medium" is a cost-effective choice.
    machine_type = "e2-medium"

    # Using "pd-standard" uses standard hard drives, avoiding SSD quota issues.
    disk_type = "pd-standard"

    # Explicitly set a smaller disk size to further reduce resource consumption.
    disk_size_gb = 30
    service_account = "new-service@new-project-462710.iam.gserviceaccount.com"
    # Standard OAuth scopes required for GKE nodes to function correctly.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
