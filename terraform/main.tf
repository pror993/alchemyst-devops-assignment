terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  backend "gcs" {
    bucket = "alchemyst-tf-state-alchemyst-devops-v2"   # your bucket name
    prefix = "terraform/state"
  }
}

provider "google" {
  project = var.project_id   # we'll use a variable now
  region  = "asia-south1"
  zone    = "asia-south1-a"
}

variable "project_id" {}     # passed in by GitHub Actions

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

  metadata_startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_DIR="/opt/alchemyst-devops-assignment"
    export PATH="$PATH:/root/.local/bin"

    apt-get update
    apt-get install -y curl git

    if [[ ! -d "$REPO_DIR" ]]; then
      git clone https://github.com/pror993/alchemyst-devops-assignment.git "$REPO_DIR"
    else
      git -C "$REPO_DIR" pull --ff-only || true
    fi

    if ! command -v iii >/dev/null 2>&1; then
      export HOME=/root
      curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
    fi

    if ! pgrep -f "iii --config" >/dev/null 2>&1; then
      nohup iii --config "$REPO_DIR/config.yaml" > /var/log/iii-engine.log 2>&1 &
    fi
  EOT

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_subnet.id
    network_ip = "10.0.0.2"
    access_config {}  # gives it a public IP
  }
}

# Caller VM — no public IP, runs TypeScript worker
resource "google_compute_instance" "caller_vm" {
  name         = "caller-vm"
  machine_type = "e2-micro"
  zone         = "asia-south1-a"

  metadata_startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    REPO_DIR="/opt/alchemyst-devops-assignment"

    apt-get update
    apt-get install -y curl git ca-certificates

    if ! command -v node >/dev/null 2>&1; then
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs
    fi

    if [[ ! -d "$REPO_DIR" ]]; then
      git clone https://github.com/pror993/alchemyst-devops-assignment.git "$REPO_DIR"
    else
      git -C "$REPO_DIR" pull --ff-only || true
    fi

    cd "$REPO_DIR/workers/caller-worker"
    if [[ ! -d node_modules ]]; then
      npm install
    fi

    if ! pgrep -f "tsx src/worker.ts" >/dev/null 2>&1; then
      nohup env III_URL=ws://10.0.0.2:49134 ./node_modules/.bin/tsx src/worker.ts > /var/log/caller-worker.log 2>&1 &
    fi
  EOT

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_subnet.id
    network_ip = "10.0.0.3"
    # no access_config = no public IP
  }
}

# Inference VM — no public IP, runs Python worker + ollama
resource "google_compute_instance" "inference_vm" {
  name         = "inference-vm"
  machine_type = "e2-medium"
  zone         = "asia-south1-a"

  metadata_startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    export HOME=/root

    REPO_DIR="/opt/alchemyst-devops-assignment"

    apt-get update
    apt-get install -y curl git python3 python3-pip

    if ! command -v ollama >/dev/null 2>&1; then
      curl -fsSL https://ollama.com/install.sh | sh
    fi

    if command -v systemctl >/dev/null 2>&1; then
      cat >/usr/local/bin/ollama-pull.sh <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail

    OLLAMA_READY_URL="http://127.0.0.1:11434/api/tags"
    OLLAMA_WAIT_SECONDS=300
    OLLAMA_WAIT_INTERVAL=2
    elapsed=0

    until curl -sf "$OLLAMA_READY_URL" >/dev/null; do
      if [[ $elapsed -ge $OLLAMA_WAIT_SECONDS ]]; then
        echo "Ollama did not become ready in $${OLLAMA_WAIT_SECONDS}s" >&2
        exit 1
      fi
      sleep "$OLLAMA_WAIT_INTERVAL"
      elapsed=$((elapsed + OLLAMA_WAIT_INTERVAL))
    done

    ollama pull gemma3:1b
EOF

      chmod 0755 /usr/local/bin/ollama-pull.sh

      cat >/etc/systemd/system/ollama-pull.service <<'EOF'
    [Unit]
    Description=Pull Ollama model after service is ready
    After=network-online.target ollama.service
    Wants=network-online.target
    Requires=ollama.service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/ollama-pull.sh
    TimeoutStartSec=360

    [Install]
    WantedBy=multi-user.target
EOF

      systemctl daemon-reload
      systemctl enable --now ollama || true
      systemctl enable --now ollama-pull.service || true
    else
      if ! pgrep -f "ollama serve" >/dev/null 2>&1; then
        nohup ollama serve > /var/log/ollama.log 2>&1 &
      fi

      OLLAMA_READY_URL="http://127.0.0.1:11434/api/tags"
      OLLAMA_WAIT_SECONDS=120
      OLLAMA_WAIT_INTERVAL=2
      elapsed=0
      until curl -sf "$OLLAMA_READY_URL" >/dev/null; do
        if [[ $elapsed -ge $OLLAMA_WAIT_SECONDS ]]; then
          echo "Ollama did not become ready in $${OLLAMA_WAIT_SECONDS}s" >&2
          break
        fi
        sleep "$OLLAMA_WAIT_INTERVAL"
        elapsed=$((elapsed + OLLAMA_WAIT_INTERVAL))
      done

      if curl -sf "$OLLAMA_READY_URL" >/dev/null; then
        ollama pull gemma3:1b
      else
        echo "Skipping ollama pull; API not ready" >&2
      fi
    fi

    if [[ ! -d "$REPO_DIR" ]]; then
      git clone https://github.com/pror993/alchemyst-devops-assignment.git "$REPO_DIR"
    else
      git -C "$REPO_DIR" pull --ff-only || true
    fi

    cd "$REPO_DIR/workers/inference-worker"
    pip3 install -r requirements.txt

    if ! pgrep -f "inference_worker.py" >/dev/null 2>&1; then
      nohup env III_URL=ws://10.0.0.2:49134 python3 inference_worker.py > /var/log/inference-worker.log 2>&1 &
    fi
  EOT

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 15
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iii_subnet.id
    network_ip = "10.0.0.4"
    # no access_config = no public IP
  }
}

# Outputs — useful after apply
output "engine_public_ip" {
  value       = google_compute_instance.engine_vm.network_interface[0].access_config[0].nat_ip
  description = "Public IP of engine-vm — hit this with curl"
}