terraform {
  required_version = ">= 1.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable required APIs
resource "google_project_service" "gke_apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com"
  ])
  
  project = var.project_id
  service = each.value
  disable_on_destroy = false
}

# Use existing service account data source
data "google_service_account" "existing_sa" {
  account_id = "rk-service-account"
  project    = var.project_id
}

# Create VPC
resource "google_compute_network" "gke_vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [google_project_service.gke_apis]
}

# Create Subnet
resource "google_compute_subnetwork" "gke_subnet" {
  name          = "${var.cluster_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.gke_vpc.id
  
  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = var.pods_cidr
  }
  
  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = var.services_cidr
  }
  
  depends_on = [google_compute_network.gke_vpc]
}

# Create Router and NAT for outbound internet access
resource "google_compute_router" "router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.gke_vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Create Firewall rules for SSH
resource "google_compute_firewall" "ssh" {
  name          = "${var.cluster_name}-ssh"
  network       = google_compute_network.gke_vpc.name
  direction     = "INGRESS"
  
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  
  source_ranges = var.ssh_source_ranges
  target_tags   = ["ssh-enabled"]
}

# Create Firewall rules for internal communication
resource "google_compute_firewall" "internal" {
  name          = "${var.cluster_name}-internal"
  network       = google_compute_network.gke_vpc.name
  direction     = "INGRESS"
  
  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  
  allow {
    protocol = "icmp"
  }
  
  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr, var.master_cidr]
  target_tags   = ["gke-node"]
}

# Create GKE Cluster using existing service account
resource "google_container_cluster" "primary" {
  name                     = var.cluster_name
  location                 = var.region
  network                  = google_compute_network.gke_vpc.name
  subnetwork               = google_compute_subnetwork.gke_subnet.name
  remove_default_node_pool = true
  initial_node_count       = 1
  
  # Use existing service account with minimal scopes
  node_config {
    service_account = data.google_service_account.existing_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append"
    ]
    tags = ["ssh-enabled", "gke-node"]
  }
  
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }
  
  # Use public cluster for simplicity
  private_cluster_config {
    enable_private_nodes    = false
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }
  
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "public-access"
    }
  }

  # Add timeouts to prevent hanging
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  depends_on = [
    google_compute_subnetwork.gke_subnet,
    google_project_service.gke_apis
  ]
}

# Create Node Pool with 3 nodes using existing service account
resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = 3
  
  node_config {
    preemptible     = false
    machine_type    = var.machine_type
    disk_size_gb    = var.disk_size
    service_account = data.google_service_account.existing_sa.email
    
    # Use minimal scopes
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append"
    ]
    
    tags = ["ssh-enabled", "gke-node"]
  }
  
  management {
    auto_repair  = true
    auto_upgrade = true
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
