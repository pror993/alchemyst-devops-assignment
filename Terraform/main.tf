terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "project-923f66c6-2be4-4024-841"
  region  = "asia-south1"
  zone    = "asia-south1-a"
}

# VPC network
resource "google_compute_network" "iii_network" {
  name                    = "iii-network"
  auto_create_subnetworks = false
}

# Private subnet
resource "google_compute_subnetwork" "iii_subnet" {
  name          = "iii-subnet"
  network       = google_compute_network.iii_network.id
  region        = "asia-south1"
  ip_cidr_range = "10.0.0.0/24"
}

# Allow internal traffic between VMs
resource "google_compute_firewall" "allow_internal" {
  name    = "iii-allow-internal"
  network = google_compute_network.iii_network.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/24"]
}

# Allow SSH from anywhere
resource "google_compute_firewall" "allow_ssh" {
  name    = "iii-allow-ssh"
  network = google_compute_network.iii_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

# Allow HTTP API on port 3111 — only for tagged VMs
resource "google_compute_firewall" "allow_http_api" {
  name    = "iii-allow-http-api"
  network = google_compute_network.iii_network.name

  allow {
    protocol = "tcp"
    ports    = ["3111"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["api-gateway"]
}

# Cloud router for NAT
resource "google_compute_router" "iii_router" {
  name    = "iii-router"
  network = google_compute_network.iii_network.name
  region  = "asia-south1"
}

# NAT so private VMs can reach the internet
resource "google_compute_router_nat" "iii_nat" {
  name                               = "iii-nat"
  router                             = google_compute_router.iii_router.name
  region                             = "asia-south1"
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Engine VM — public IP, runs iii engine
resource "google_compute_instance" "engine_vm" {
  name         = "engine-vm"
  machine_type = "e2-micro"
  zone         = "asia-south1-a"
  tags         = ["api-gateway"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_subnet.id
    access_config {}  # gives it a public IP
  }
}

# Caller VM — no public IP, runs TypeScript worker
resource "google_compute_instance" "caller_vm" {
  name         = "caller-vm"
  machine_type = "e2-micro"
  zone         = "asia-south1-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_subnet.id
    # no access_config = no public IP
  }
}

# Inference VM — no public IP, runs Python worker + ollama
resource "google_compute_instance" "inference_vm" {
  name         = "inference-vm"
  machine_type = "e2-medium"
  zone         = "asia-south1-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 15
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_subnet.id
    # no access_config = no public IP
  }
}

# Outputs — useful after apply
output "engine_public_ip" {
  value       = google_compute_instance.engine_vm.network_interface[0].access_config[0].nat_ip
  description = "Public IP of engine-vm — hit this with curl"
}