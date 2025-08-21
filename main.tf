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
    "monitoring.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "artifactregistry.googleapis.com"
  ])
  
  project = var.project_id
  service = each.value
  disable_on_destroy = false
}

# Create new service account for GKE
resource "google_service_account" "gke_service_account" {
  account_id   = "${var.cluster_name}-gke-sa"
  display_name = "GKE Service Account for ${var.cluster_name}"
  description  = "Service account for GKE cluster ${var.cluster_name} with all required permissions"
  
  depends_on = [google_project_service.gke_apis]
}

# Create service account key (optional - for external access)
resource "google_service_account_key" "gke_sa_key" {
  service_account_id = google_service_account.gke_service_account.name
  public_key_type    = "TYPE_X509_PEM_FILE"
  
  depends_on = [google_service_account.gke_service_account]
}

# Assign comprehensive IAM roles to the service account
resource "google_project_iam_member" "gke_sa_roles" {
  for_each = toset([
    "roles/container.admin",
    "roles/compute.admin",
    "roles/iam.serviceAccountUser",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/storage.admin",
    "roles/artifactregistry.reader",
    "roles/networkadmin",
    "roles/cloudsql.client",
    "roles/secretmanager.secretAccessor",
    "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  ])
  
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_service_account.email}"
  
  depends_on = [
    google_service_account.gke_service_account,
    google_project_service.gke_apis
  ]
}

# Create custom IAM role for GKE with specific permissions
resource "google_project_iam_custom_role" "gke_custom_role" {
  role_id     = "gkeCustomRole"
  title       = "GKE Custom Role"
  description = "Custom role with specific permissions for GKE operations"
  project     = var.project_id
  permissions = [
    "compute.networks.get",
    "compute.networks.create",
    "compute.networks.delete",
    "compute.subnetworks.get",
    "compute.subnetworks.create",
    "compute.subnetworks.delete",
    "compute.routers.get",
    "compute.routers.create",
    "compute.routers.delete",
    "compute.firewalls.get",
    "compute.firewalls.create",
    "compute.firewalls.delete",
    "container.clusters.get",
    "container.clusters.create",
    "container.clusters.delete",
    "container.clusters.update",
    "container.nodePools.get",
    "container.nodePools.create",
    "container.nodePools.delete",
    "container.nodePools.update"
  ]
  
  depends_on = [google_project_service.gke_apis]
}

# Assign custom role to service account
resource "google_project_iam_member" "gke_custom_role" {
  project = var.project_id
  role    = "projects/${var.project_id}/roles/${google_project_iam_custom_role.gke_custom_role.role_id}"
  member  = "serviceAccount:${google_service_account.gke_service_account.email}"
  
  depends_on = [google_project_iam_custom_role.gke_custom_role]
}

# Create VPC
resource "google_compute_network" "gke_vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "VPC for GKE cluster ${var.cluster_name}"
  
  depends_on = [google_project_service.gke_apis]
}

# Create Subnet
resource "google_compute_subnetwork" "gke_subnet" {
  name                     = "${var.cluster_name}-subnet"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.gke_vpc.id
  private_ip_google_access = true
  
  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = var.pods_cidr
  }
  
  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = var.services_cidr
  }
  
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
  
  depends_on = [google_compute_network.gke_vpc]
}

# Create Router for NAT
resource "google_compute_router" "router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.gke_vpc.id
  
  bgp {
    asn = 64514
  }
}

# Create NAT for outbound internet access
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
  
  depends_on = [google_compute_router.router]
}

# Create Firewall rules for SSH
resource "google_compute_firewall" "ssh" {
  name        = "${var.cluster_name}-ssh"
  network     = google_compute_network.gke_vpc.name
  description = "Allow SSH access to GKE nodes"
  direction   = "INGRESS"
  
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  
  source_ranges = var.ssh_source_ranges
  target_tags   = ["ssh-enabled"]
  
  depends_on = [google_compute_network.gke_vpc]
}

# Create Firewall rules for internal cluster communication
resource "google_compute_firewall" "internal_cluster" {
  name        = "${var.cluster_name}-internal-cluster"
  network     = google_compute_network.gke_vpc.name
  description = "Allow internal cluster communication"
  direction   = "INGRESS"
  
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

# Create Firewall rules for health checks
resource "google_compute_firewall" "health_checks" {
  name        = "${var.cluster_name}-health-checks"
  network     = google_compute_network.gke_vpc.name
  description = "Allow health checks from Google Cloud"
  direction   = "INGRESS"
  
  allow {
    protocol = "tcp"
    ports    = ["30000-32767"] # NodePort range
  }
  
  allow {
    protocol = "tcp"
    ports    = ["10250"] # Kubelet API
  }
  
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "209.85.152.0/22", "209.85.204.0/22"]
  target_tags   = ["gke-node"]
}

# Create GKE Cluster with new service account
resource "google_container_cluster" "primary" {
  name                     = var.cluster_name
  location                 = var.region
  network                  = google_compute_network.gke_vpc.name
  subnetwork               = google_compute_subnetwork.gke_subnet.name
  remove_default_node_pool = true
  initial_node_count       = 1
  
  # Use the new service account with full permissions
  node_config {
    service_account = google_service_account.gke_service_account.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform" # Full access
    ]
    tags = ["ssh-enabled", "gke-node"]
    
    # Enable Shielded VM features
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
  
  # Enable IP aliasing and specify ranges
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }
  
  # Network policy
  network_policy {
    enabled = true
    provider = "CALICO"
  }
  
  # Cluster autoscaling
  cluster_autoscaling {
    enabled = true
    resource_limits {
      resource_type = "cpu"
      minimum       = 1
      maximum       = 8
    }
    resource_limits {
      resource_type = "memory"
      minimum       = 4
      maximum       = 32
    }
  }
  
  # Vertical Pod Autoscaling
  vertical_pod_autoscaling {
    enabled = true
  }
  
  # Release channel
  release_channel {
    channel = "REGULAR"
  }
  
  # Maintenance window
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }
  
  # Private cluster configuration
  private_cluster_config {
    enable_private_nodes    = false
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }
  
  # Master authorized networks
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "public-access"
    }
  }
  
  # Enable workload identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
  
  # Addons config
  addons_config {
    horizontal_pod_autoscaling {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
    network_policy_config {
      disabled = false
    }
  }
  
  # Database encryption
  database_encryption {
    state = "DECRYPTED"
  }
  
  # Timeouts
  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }

  depends_on = [
    google_project_iam_member.gke_sa_roles,
    google_project_iam_member.gke_custom_role,
    google_compute_subnetwork.gke_subnet,
    google_compute_router_nat.nat,
    google_project_service.gke_apis
  ]
}

# Create Node Pool with 3 nodes
resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = 3
  
  # Autoscaling configuration
  autoscaling {
    min_node_count = 3
    max_node_count = 6
  }
  
  # Node configuration
  node_config {
    preemptible     = false
    machine_type    = var.machine_type
    disk_size_gb    = var.disk_size
    disk_type       = "pd-ssd"
    service_account = google_service_account.gke_service_account.email
    
    # Full cloud platform access
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    
    tags = ["ssh-enabled", "gke-node"]
    
    # Shielded VM
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    
    # Labels and metadata
    labels = {
      environment = "production"
      workload    = "general"
    }
    
    metadata = {
      disable-legacy-endpoints = "true"
    }
    
    # Resource limits
    resources {
      requests = {
        cpu    = "500m"
        memory = "1Gi"
      }
      limits = {
        cpu    = "2000m"
        memory = "4Gi"
      }
    }
  }
  
  # Management settings
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  
  # Upgrade settings
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
  
  # Timeouts
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
  
  depends_on = [google_container_cluster.primary]
}

# Output the service account key (base64 encoded)
resource "local_file" "service_account_key" {
  content  = base64decode(google_service_account_key.gke_sa_key.private_key)
  filename = "${path.module}/gke-service-account-key.json"
  
  depends_on = [google_service_account_key.gke_sa_key]
}
