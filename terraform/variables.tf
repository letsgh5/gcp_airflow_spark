variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "europe-west1-b"
}

variable "course_name" {
  type    = string
  default = "airflow-spark-course"
}

variable "analitycy" {
  description = "Lista loginów analityków — tworzone jako konta Airflow"
  type        = list(string)
  default = [
    "analityk01", "analityk02", "analityk03", "analityk04",
    "analityk05", "analityk06", "analityk07", "analityk08",
    "analityk09", "analityk10", "analityk11", "analityk12",
    "analityk13", "analityk14", "analityk15", "analityk16"
  ]
}

# control-plane: potrzebuje tylko zarządzać klastrem, nie uruchamia podów
variable "master_machine_type" {
  type    = string
  default = "e2-standard-2" # 2 vCPU, 8 GB
}

# workerzy: Airflow workery + Spark executory
variable "worker_machine_type" {
  type    = string
  default = "e2-standard-4" # 4 vCPU, 16 GB × 2 nody = 8 vCPU / 32 GB łącznie
}

variable "allowed_cidr" {
  description = "CIDR skąd dostęp do UI (np. IP sali/instruktora). 0.0.0.0/0 = wszyscy."
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_public_key" {
  description = "Treść publicznego klucza SSH (w CI: vars.SSH_PUBLIC_KEY). Gdy pusta, używany jest plik z ssh_pub_key_path."
  type        = string
  default     = ""
}

variable "ssh_pub_key_path" {
  description = "Ścieżka do publicznego klucza SSH (fallback dla pracy lokalnej, gdy ssh_public_key jest pusta)"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "airflow_admin_password" {
  description = "Hasło admina Airflow"
  type        = string
  sensitive   = true
}

variable "airflow_analyst_password" {
  description = "Hasło dla analityków w Airflow"
  type        = string
  sensitive   = true
}

variable "jupyterhub_admin_password" {
  description = "Hasło admina JupyterHub"
  type        = string
  sensitive   = true
}

variable "jupyterhub_analyst_password" {
  description = "Hasło dla analityków w JupyterHub"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Hasło admina Grafana"
  type        = string
  sensitive   = true
}
