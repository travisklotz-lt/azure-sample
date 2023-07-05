terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.63.0"
    }
    azuread = {
      source = "hashicorp/azuread"
      version = "=2.39.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "Bootstrap"
    storage_account_name = "tkcore"
    container_name       = "tfstate"
    key                  = "sample-app.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  storage_use_azuread = true
}

provider "azuread" {

}

resource "azurerm_resource_group" "rg" {
  name                                   = "sample-app"
  location                               = "East US"
}

data "azurerm_client_config" "current" {}

data "azuread_user" "tklotz" {
  user_principal_name = "tklotz@travisklotzgmail.onmicrosoft.com"
}

data "azurerm_dns_zone" "zone" {
  name = "azure.kalak451.net"
}

data "azurerm_virtual_network" "core" {
  name = "CoreNetwork"
  resource_group_name = "CoreNetwork"
}

data "azurerm_subnet" "private" {
  resource_group_name  = data.azurerm_virtual_network.core.resource_group_name
  virtual_network_name = data.azurerm_virtual_network.core.name
  name                 = "private"
}

resource "azurerm_subnet" "sample" {
  address_prefixes     = [
    "10.0.3.0/24"
  ]
  name                 = "sample-app"
  resource_group_name  = data.azurerm_virtual_network.core.resource_group_name
  virtual_network_name = data.azurerm_virtual_network.core.name
  delegation {
    name = "apps"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action"
      ]
    }
  }
}

resource "azurerm_private_dns_zone" "sample" {
  name                = "sample.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "core" {
  name                  = "core-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.sample.name
  virtual_network_id    = data.azurerm_virtual_network.core.id
}

resource "azurerm_postgresql_flexible_server" "sample" {
  name                   = "sample-db"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  version                = "14"
  delegated_subnet_id    = data.azurerm_subnet.private.id
  private_dns_zone_id    = azurerm_private_dns_zone.sample.id
  storage_mb = 32768
  sku_name   = "B_Standard_B1ms"
  zone = "2"

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled = false
    tenant_id = data.azurerm_client_config.current.tenant_id
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.core
  ]
}

resource "azurerm_postgresql_flexible_server_database" "sample" {
  name      = "sample"
  server_id = azurerm_postgresql_flexible_server.sample.id


}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "sample_tklotz" {
  server_name         = azurerm_postgresql_flexible_server.sample.name
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = data.azuread_user.tklotz.object_id
  principal_name      = data.azuread_user.tklotz.user_principal_name
  principal_type      = "User"
}

resource "azurerm_service_plan" "sample" {
  name                = "sample"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "S1"
}

resource "azurerm_linux_web_app" "sample" {
  name                = "tk-sample-app"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_service_plan.sample.location
  service_plan_id     = azurerm_service_plan.sample.id
  https_only = true
  virtual_network_subnet_id = azurerm_subnet.sample.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      java_server = "JAVA"
      java_server_version = "17"
      java_version = "17"
    }
    vnet_route_all_enabled = true
  }

  app_settings = {
    SPRING_PROFILES_ACTIVE = "azure"
  }
}

//This doesn't actually grant access to the 'sample' database, just the postgres db.
//I still need to log into the database to grant the app access.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "app_user" {
  server_name         = azurerm_postgresql_flexible_server.sample.name
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = azurerm_linux_web_app.sample.identity[0].principal_id
  principal_name      = "sample_app"
  principal_type      = "ServicePrincipal"
}

resource "azurerm_app_service_custom_hostname_binding" "sample" {
  hostname            = "sample.azure.kalak451.net"
  app_service_name    = azurerm_linux_web_app.sample.name
  resource_group_name = azurerm_linux_web_app.sample.resource_group_name

  depends_on = [
    azurerm_dns_txt_record.sample
  ]
}

resource "azurerm_dns_txt_record" "sample" {
  name                = "asuid.sample"
  zone_name           = data.azurerm_dns_zone.zone.name
  resource_group_name = data.azurerm_dns_zone.zone.resource_group_name
  ttl                 = 60

  record {
    value = azurerm_linux_web_app.sample.custom_domain_verification_id
  }
}

resource "azurerm_dns_cname_record" "sample" {
  name                = "sample"
  ttl                 = 60
  zone_name           = data.azurerm_dns_zone.zone.name
  resource_group_name = data.azurerm_dns_zone.zone.resource_group_name

  record = azurerm_linux_web_app.sample.default_hostname
}

resource "azurerm_app_service_managed_certificate" "sample" {
  custom_hostname_binding_id = azurerm_app_service_custom_hostname_binding.sample.id
}

resource "azurerm_app_service_certificate_binding" "sample" {
  hostname_binding_id = azurerm_app_service_custom_hostname_binding.sample.id
  certificate_id      = azurerm_app_service_managed_certificate.sample.id
  ssl_state           = "SniEnabled"
}