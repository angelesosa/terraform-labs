###############################################################################
# Azure - Container Apps
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# ------------------ Variables (sin defaults → se piden en terminal) ------------------

variable "subscription_id" {
  description = "ID de la suscripción de Azure"
  type        = string
}

variable "location" {
  description = "Región de Azure (ej: eastus, westeurope, brazilsouth)"
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
  description = "Imagen del contenedor (ej: mcr.microsoft.com/k8se/quickstart:latest)"
  type        = string
}

variable "container_port" {
  description = "Puerto expuesto por el contenedor (ej: 80, 8080, 3000)"
  type        = number
}

variable "cpu" {
  description = "CPU asignada al contenedor en cores (ej: 0.25, 0.5, 1, 2)"
  type        = number
}

variable "memory" {
  description = "Memoria asignada al contenedor (ej: 0.5Gi, 1Gi, 2Gi)"
  type        = string
}

# ------------------ Resource Group ------------------

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ------------------ Log Analytics ------------------

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ------------------ Container Apps Environment ------------------

resource "azurerm_container_app_environment" "main" {
  name                       = "cae-${var.project_name}-${var.environment}"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ------------------ Container App ------------------

resource "azurerm_container_app" "main" {
  name                         = "ca-${var.project_name}-${var.environment}"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  template {
    min_replicas = 0
    max_replicas = 5

    container {
      name   = "${var.project_name}-app"
      image  = var.container_image
      cpu    = var.cpu
      memory = var.memory

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = var.container_port
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ------------------ Outputs ------------------

output "container_app_fqdn" {
  description = "FQDN de la Container App"
  value       = azurerm_container_app.main.latest_revision_fqdn
}

output "container_app_url" {
  description = "URL completa de la Container App"
  value       = "https://${azurerm_container_app.main.latest_revision_fqdn}"
}

output "resource_group_name" {
  description = "Nombre del resource group"
  value       = azurerm_resource_group.main.name
}

output "environment_name" {
  description = "Nombre del Container Apps Environment"
  value       = azurerm_container_app_environment.main.name
}
