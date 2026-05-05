###############################################################################
# Google Cloud - Cloud Run + Secret Manager
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# ------------------ Variables (sin defaults → se piden en terminal) ------------------

variable "gcp_project_id" {
  description = "ID del proyecto en GCP (ej: my-project-123456)"
  type        = string
}

variable "gcp_region" {
  description = "Región de GCP (ej: us-central1, southamerica-east1)"
  type        = string
}

variable "project_name" {
  description = "Nombre del proyecto (se usa como prefijo en los recursos)"
  type        = string
}

variable "environment" {
  description = "Entorno de despliegue (ej: dev, staging, prod)"
  type        = string
}

variable "container_image" {
  description = "Imagen del contenedor (ej: us-docker.pkg.dev/cloudrun/container/hello)"
  type        = string
}

variable "container_port" {
  description = "Puerto expuesto por el contenedor (ej: 8080, 3000)"
  type        = number
}

variable "secret_db_password" {
  description = "Valor del secreto para la contraseña de base de datos"
  type        = string
  sensitive   = true
}

variable "secret_api_key" {
  description = "Valor del secreto para la API key"
  type        = string
  sensitive   = true
}

# ------------------ APIs habilitadas ------------------

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# ------------------ Locals para los secretos ------------------

locals {
  secrets = {
    "db-password" = var.secret_db_password
    "api-key"     = var.secret_api_key
  }
}

# ------------------ Secret Manager ------------------

resource "google_secret_manager_secret" "secrets" {
  for_each  = local.secrets
  secret_id = "${var.project_name}-${var.environment}-${each.key}"

  replication {
    auto {}
  }

  labels = {
    project     = var.project_name
    environment = var.environment
  }

  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "secrets" {
  for_each    = local.secrets
  secret      = google_secret_manager_secret.secrets[each.key].id
  secret_data = each.value
}

# ------------------ Service Account para Cloud Run ------------------

resource "google_service_account" "cloud_run_sa" {
  account_id   = "${var.project_name}-${var.environment}-run"
  display_name = "Cloud Run SA - ${var.project_name} ${var.environment}"
}

resource "google_secret_manager_secret_iam_member" "run_secret_access" {
  for_each  = local.secrets
  secret_id = google_secret_manager_secret.secrets[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# ------------------ Cloud Run Service ------------------

resource "google_cloud_run_v2_service" "main" {
  name     = "${var.project_name}-${var.environment}-service"
  location = var.gcp_region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.cloud_run_sa.email

    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }

    containers {
      image = var.container_image

      ports {
        container_port = var.container_port
      }

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }

      dynamic "env" {
        for_each = local.secrets
        content {
          name = upper(replace(env.key, "-", "_"))
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.secrets[env.key].secret_id
              version = "latest"
            }
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }

  labels = {
    project     = var.project_name
    environment = var.environment
  }

  depends_on = [
    google_project_service.run,
    google_secret_manager_secret_version.secrets,
    google_secret_manager_secret_iam_member.run_secret_access
  ]
}

resource "google_cloud_run_v2_service_iam_member" "public_access" {
  name     = google_cloud_run_v2_service.main.name
  location = google_cloud_run_v2_service.main.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ------------------ Outputs ------------------

output "cloud_run_url" {
  description = "URL del servicio Cloud Run"
  value       = google_cloud_run_v2_service.main.uri
}

output "service_account_email" {
  description = "Email del Service Account de Cloud Run"
  value       = google_service_account.cloud_run_sa.email
}

output "secret_ids" {
  description = "IDs de los secretos creados"
  value       = { for k, v in google_secret_manager_secret.secrets : k => v.secret_id }
}
