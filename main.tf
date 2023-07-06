terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.63.0"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}
}

locals {
  location             = "switzerlandnorth"
  vnet_address_space   = "192.168.0.0/24"
  vm_address_space     = "192.168.0.0/25"
  netapp_address_space = "192.168.0.128/25"
}

resource "azurerm_resource_group" "rg" {
  name     = "netapp-avg-test"
  location = local.location
}

resource "azurerm_virtual_network" "vnet" {
  name = "netapp-avg-test"

  resource_group_name = azurerm_resource_group.rg.name
  location            = local.location
  address_space       = [local.vnet_address_space]
}

resource "azurerm_subnet" "vms" {
  name                 = "netapp-avg-test-vms"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [local.vm_address_space]
}


resource "azurerm_subnet" "netapp" {
  name                 = "netapp-avg-test-netapp"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [local.netapp_address_space]

  delegation {
    name = "Netapp"

    service_delegation {
      name    = "Microsoft.Netapp/volumes"
      actions = [
        "Microsoft.Network/networkinterfaces/*",
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

resource "azurerm_proximity_placement_group" "db" {
  name                = "netapp-avg-test"
  location            = local.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_availability_set" "db" {
  name                        = "netapp-avg-test"
  location                    = local.location
  resource_group_name         = azurerm_resource_group.rg.name
  platform_fault_domain_count = 2 # we don't need more than two domains, and switzerland north doesn't offer more

  proximity_placement_group_id = azurerm_proximity_placement_group.db.id
}

resource "azurerm_network_interface" "main" {
  name                = "netapp-avg-test"
  location            = local.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "testconfiguration1"
    subnet_id                     = azurerm_subnet.vms.id
    private_ip_address_allocation = "Dynamic"
  }
}

// create a VM so that the AVSet has an anchor
resource "azurerm_virtual_machine" "main" {
  name                         = "netapp-avg-test"
  location                     = local.location
  resource_group_name          = azurerm_resource_group.rg.name
  network_interface_ids        = [azurerm_network_interface.main.id]
  vm_size                      = "Standard_B1s"
  availability_set_id          = azurerm_availability_set.db.id
  proximity_placement_group_id = azurerm_proximity_placement_group.db.id

  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    offer     = "0001-com-ubuntu-server-focal"
    publisher = "Canonical"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
  storage_os_disk {
    name              = "myosdisk1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "hostname"
    admin_username = "testadmin"
    admin_password = "Password1234!"
  }
  os_profile_linux_config {
    disable_password_authentication = false
  }
}

resource "azurerm_netapp_account" "account" {
  name                = "netapp-avg-test"
  location            = local.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_netapp_pool" "pool" {
  name                = "netapp-avg-test"
  location            = local.location
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_netapp_account.account.name
  service_level       = "Standard"
  size_in_tb          = 4
  qos_type            = "Manual"
}

resource "azurerm_netapp_volume_group_sap_hana" "avg" {
  name                   = "netapp-avg-test"
  location               = local.location
  resource_group_name    = azurerm_resource_group.rg.name
  account_name           = azurerm_resource_group.rg.name
  application_identifier = "X01"
  group_description      = "avg"

  volume {
    name                         = "netapp-avg-test-data"
    volume_path                  = "netapp-avg-test-data"
    service_level                = azurerm_netapp_pool.pool.service_level
    capacity_pool_id             = azurerm_netapp_pool.pool.id
    subnet_id                    = azurerm_subnet.netapp.id
    proximity_placement_group_id = azurerm_proximity_placement_group.db.id
    volume_spec_name             = "data"
    storage_quota_in_gb          = 128
    throughput_in_mibps          = 10
    protocols                    = ["NFSv4.1"]
    security_style               = "Unix"
    snapshot_directory_visible   = true

    export_policy_rule {
      rule_index          = 1
      allowed_clients     = "0.0.0.0/0"
      nfsv3_enabled       = false
      nfsv41_enabled      = true
      unix_read_only      = false
      unix_read_write     = true
      root_access_enabled = true
    }
  }

  volume {
    name                         = "netapp-avg-test-log"
    volume_path                  = "netapp-avg-test-log"
    service_level                = azurerm_netapp_pool.pool.service_level
    capacity_pool_id             = azurerm_netapp_pool.pool.id
    subnet_id                    = azurerm_subnet.netapp.id
    proximity_placement_group_id = azurerm_proximity_placement_group.db.id
    volume_spec_name             = "log"
    storage_quota_in_gb          = 128
    throughput_in_mibps          = 10
    protocols                    = ["NFSv4.1"]
    security_style               = "Unix"
    snapshot_directory_visible   = true

    export_policy_rule {
      rule_index          = 1
      allowed_clients     = "0.0.0.0/0"
      nfsv3_enabled       = false
      nfsv41_enabled      = true
      unix_read_only      = false
      unix_read_write     = true
      root_access_enabled = true
    }
  }

  volume {
    name                         = "netapp-avg-test-shared"
    volume_path                  = "netapp-avg-test-shared"
    service_level                = azurerm_netapp_pool.pool.service_level
    capacity_pool_id             = azurerm_netapp_pool.pool.id
    subnet_id                    = azurerm_subnet.netapp.id
    proximity_placement_group_id = azurerm_proximity_placement_group.db.id
    volume_spec_name             = "shared"
    storage_quota_in_gb          = 128
    throughput_in_mibps          = 10
    protocols                    = ["NFSv4.1"]
    security_style               = "Unix"
    snapshot_directory_visible   = true

    export_policy_rule {
      rule_index          = 1
      allowed_clients     = "0.0.0.0/0"
      nfsv3_enabled       = false
      nfsv41_enabled      = true
      unix_read_only      = false
      unix_read_write     = true
      root_access_enabled = true
    }
  }


  # wait for the vm so that the avset has an anchor
  depends_on = [azurerm_virtual_machine.main]
}


