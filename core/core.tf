terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.63.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "Bootstrap"
    storage_account_name = "tkcore"
    container_name       = "tfstate"
    key                  = "core.tfstate"
    use_azuread_auth     = true
  }
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  storage_use_azuread = true
}

data "azurerm_ssh_public_key" "laptop" {
  name                = "TK-Laptop"
  resource_group_name = "Bootstrap"
}

resource "azurerm_resource_group" "rg" {
  name     = "CoreNetwork"
  location = "East US"
}

resource "azurerm_virtual_network" "core" {
  name                = "CoreNetwork"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "public" {
  name                 = "public"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.core.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "private" {
  name                 = "private"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.core.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
      name = "Postgresql"
      service_delegation {
          name = "Microsoft.DBforPostgreSQL/flexibleServers"
          actions = [
              "Microsoft.Network/virtualNetworks/subnets/join/action"
          ]
      }
  }
}

resource "azurerm_dns_zone" "azure" {
  name                = "azure.kalak451.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone" "internal" {
  name                = "internal.azure.kalak451.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "core" {
  name                  = "core-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.internal.name
  virtual_network_id    = azurerm_virtual_network.core.id
  registration_enabled  = true
}

resource "azurerm_public_ip" "bastion" {
  name                = "bastion"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
}

resource "azurerm_dns_a_record" "bastion_dns" {
  name                = "bastion"
  zone_name           = azurerm_dns_zone.azure.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 60
  records             = [
      azurerm_public_ip.bastion.ip_address
  ]
}

resource "azurerm_network_interface" "bastion_nic" {
  name                = "bastion-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  internal_dns_name_label = "bastion"

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion.id
    primary                       = true
  }
}

resource "azurerm_linux_virtual_machine" "bastion" {
  name                = "bastion"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B1s"
  admin_username      = "azureuser"

  network_interface_ids = [
    azurerm_network_interface.bastion_nic.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = data.azurerm_ssh_public_key.laptop.public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}
