locals {
  # region → CIDR + zones dla workerów
  worker_regions = {
    "europe-central2" = { cidr = "10.0.2.0/24", zone = "europe-central2-a" }
  }
}

resource "google_compute_network" "vpc" {
  name                    = "${var.course_name}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

# ── Subnety ────────────────────────────────────────────────────────────────────

# master — europe-west1 (Belgia)
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.course_name}-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

# worker-2 — europe-central2 (Warszawa); limit CPUS_ALL_REGIONS = 8 vCPU (master 2 + worker 4)
resource "google_compute_subnetwork" "worker_subnet" {
  for_each      = local.worker_regions
  name          = "${var.course_name}-subnet-${each.key}"
  ip_cidr_range = each.value.cidr
  region        = each.key
  network       = google_compute_network.vpc.id
}

# ── Cloud Router + NAT per region ─────────────────────────────────────────────

resource "google_compute_router" "router" {
  name    = "${var.course_name}-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.course_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_router" "worker_router" {
  for_each = local.worker_regions
  name     = "${var.course_name}-router-${each.key}"
  network  = google_compute_network.vpc.id
  region   = each.key
}

resource "google_compute_router_nat" "worker_nat" {
  for_each                           = local.worker_regions
  name                               = "${var.course_name}-nat-${each.key}"
  router                             = google_compute_router.worker_router[each.key].name
  region                             = each.key
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ── Firewall ───────────────────────────────────────────────────────────────────

resource "google_compute_firewall" "allow_ui" {
  name    = "${var.course_name}-allow-ui"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22", "8080", "8181", "7077", "4040", "6443", "15002", "30080", "30088", "30090", "30300", "30451", "31527"]
  }

  source_ranges = [var.allowed_cidr]
  target_tags   = ["course-node"]
}

# K8s wymaga ESP (protokół 50) dla Calico między węzłami + pełny TCP/UDP/ICMP
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.course_name}-allow-internal"
  network = google_compute_network.vpc.name

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
  allow { protocol = "esp" }
  allow { protocol = "ipip" } # Calico IPIP tunnel

  source_tags = ["course-node"]
  target_tags = ["course-node"]
}
