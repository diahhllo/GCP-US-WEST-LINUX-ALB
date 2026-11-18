terraform {
  required_version = ">= 1.5.7, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

variable "project_id" {
  description = "Google Cloud project with billing and Compute Engine enabled"
  type        = string
}

provider "google" {
  project = var.project_id
  region  = "us-west1"
}

locals {
  servers = {
    linux1 = {
      zone    = "us-west1-a"
      message = "Welcome to Linux1 in US West"
    }
    linux2 = {
      zone    = "us-west1-b"
      message = "Welcome to Linux2 in US West"
    }
  }
}

resource "google_compute_network" "web" {
  name                    = "linux-web-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "web" {
  name          = "linux-web-subnet"
  ip_cidr_range = "10.50.0.0/24"
  region        = "us-west1"
  network       = google_compute_network.web.id
}

# Allow HTTP only from Google's load balancer and health check ranges.
resource "google_compute_firewall" "web" {
  name    = "linux-web-allow-lb"
  network = google_compute_network.web.name

  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["linux-web"]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

resource "google_compute_instance" "web" {
  for_each = local.servers

  name         = each.key
  zone         = each.value.zone
  machine_type = "e2-micro"
  tags         = ["linux-web"]

  deletion_protection = false

  boot_disk {
    auto_delete = true

    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.web.id

    # Outbound internet access for installing Apache.
    access_config {
      network_tier = "PREMIUM"
    }
  }

  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Retries=5 update
    apt-get -o Acquire::Retries=5 install -y apache2
    printf '%s\n' '${each.value.message}' > /var/www/html/index.html
    systemctl enable --now apache2
  SCRIPT

  labels = {
    project    = "us-west-linux-alb"
    managed_by = "terraform"
  }
}

# One unmanaged instance group per zone.
# These keep stopped VMs stopped during the failover test.
resource "google_compute_instance_group" "web" {
  for_each = local.servers

  name      = "${each.key}-group"
  zone      = each.value.zone
  instances = [google_compute_instance.web[each.key].self_link]

  named_port {
    name = "http"
    port = 80
  }
}

resource "google_compute_health_check" "web" {
  name                = "linux-web-health"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    port         = 80
    request_path = "/"
  }
}

resource "google_compute_backend_service" "web" {
  name                  = "linux-web-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.web.id]
  session_affinity      = "NONE"

  dynamic "backend" {
    for_each = google_compute_instance_group.web

    content {
      group                 = backend.value.self_link
      balancing_mode        = "RATE"
      max_rate_per_instance = 100
      capacity_scaler       = 1.0
    }
  }
}

resource "google_compute_url_map" "web" {
  name            = "linux-web-url-map"
  default_service = google_compute_backend_service.web.id
}

resource "google_compute_target_http_proxy" "web" {
  name    = "linux-web-http-proxy"
  url_map = google_compute_url_map.web.id
}

resource "google_compute_global_address" "web" {
  name         = "linux-web-public-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

resource "google_compute_global_forwarding_rule" "web" {
  name                  = "linux-web-http-rule"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.web.address
  ip_protocol           = "TCP"
  port_range            = "80"
  target                = google_compute_target_http_proxy.web.id
  network_tier          = "PREMIUM"
}

output "website_url" {
  value = "http://${google_compute_global_address.web.address}"
}

output "load_balancer_ip" {
  value = google_compute_global_address.web.address
}

output "backend_service_name" {
  value = google_compute_backend_service.web.name
}

output "project_id" {
  value = var.project_id
}

output "servers" {
  value = {
    for name, server in google_compute_instance.web :
    name => {
      name = server.name
      zone = server.zone
    }
  }
}
