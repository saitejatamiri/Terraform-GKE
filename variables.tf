variable "project_id" {
  description = "The GCP project ID"
  type        = string
  default     = "new-project-462710"
}

variable "cluster_name" {
  description = "The name of the GKE cluster"
  type        = string
  default     = "my-gke-cluster"
}

variable "region" {
  description = "The GCP region"
  type        = string
  default     = "us-central1"
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
  default     = "10.0.0.0/20"
}

variable "pods_cidr" {
  description = "CIDR range for pods"
  type        = string
  default     = "10.1.0.0/16"
}

variable "services_cidr" {
  description = "CIDR range for services"
  type        = string
  default     = "10.2.0.0/20"
}

variable "master_cidr" {
  description = "CIDR range for the master"
  type        = string
  default     = "172.16.0.0/28"
}

variable "machine_type" {
  description = "Machine type for nodes"
  type        = string
  default     = "e2-medium"
}

variable "disk_size" {
  description = "Disk size for nodes in GB"
  type        = number
  default     = 100
}

variable "ssh_source_ranges" {
  description = "Source IP ranges for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict this in production
}
