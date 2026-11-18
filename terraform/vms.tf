resource "google_service_account" "vm_sa" {
  account_id   = "${var.course_name}-vm"
  display_name = "Course VM SA"
  depends_on   = [google_project_service.apis]
}

# IAM roles przypisane ręcznie (gcloud) ze względu na ograniczenia uprawień
# resource "google_project_iam_member" "vm_sa_roles" {
#   for_each = toset([
#     "roles/storage.objectAdmin",
#     "roles/logging.logWriter",
#     "roles/monitoring.metricWriter",
#   ])
#   project = var.project_id
#   role    = each.key
#   member  = "serviceAccount:${google_service_account.vm_sa.email}"
# }

locals {
  ssh_pub_key = file(pathexpand(var.ssh_pub_key_path))
  common_metadata = {
    ssh-keys               = "ubuntu:${local.ssh_pub_key}"
    block-project-ssh-keys = "true"
  }
}

# ── Control plane ─────────────────────────────────────────────────────────────
resource "google_compute_instance" "master" {
  name         = "${var.course_name}-master"
  machine_type = var.master_machine_type
  zone         = var.zone
  tags         = ["course-node"]

  scheduling {
    on_host_maintenance = "MIGRATE"
    automatic_restart   = true
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 50
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {} # publiczne IP do SSH od instruktora
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = merge(local.common_metadata, {
    startup-script                 = file("${path.module}/../scripts/master-init.sh")
    tf_project_id                  = var.project_id
    tf_join_bucket                 = local.join_bucket
    tf_dag_bucket                  = local.dag_bucket
    tf_analitycy                   = jsonencode(var.analitycy)
    tf_airflow_admin_password      = var.airflow_admin_password
    tf_airflow_analyst_password    = var.airflow_analyst_password
    tf_jupyterhub_admin_password   = var.jupyterhub_admin_password
    tf_jupyterhub_analyst_password = var.jupyterhub_analyst_password
    tf_grafana_admin_password      = var.grafana_admin_password
  })

  depends_on = [
    google_storage_bucket.bootstrap,
    google_storage_bucket.dags,
  ]
}

# ── Worker nodes (Spark + Airflow workery) ────────────────────────────────────
locals {
  worker_config = {
    "1" = { region = "europe-west4", zone = "europe-west4-a" }
    "2" = { region = "europe-central2", zone = "europe-central2-a" }
  }
}

resource "google_compute_instance" "worker" {
  for_each     = local.worker_config
  name         = "${var.course_name}-worker-${each.key}"
  machine_type = var.worker_machine_type
  zone         = each.value.zone
  tags         = ["course-node"]

  scheduling {
    on_host_maintenance = "MIGRATE"
    automatic_restart   = true
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 100
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.worker_subnet[each.value.region].id
    # bez publicznego IP — dostęp przez NAT
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = merge(local.common_metadata, {
    startup-script = file("${path.module}/../scripts/worker-join.sh")
    tf_join_bucket = local.join_bucket
    tf_worker_id   = each.key
  })

  depends_on = [
    google_compute_instance.master,
    google_compute_router_nat.worker_nat,
  ]
}
