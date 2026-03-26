# Local test — smoke test for the tes-infra module against a real PVE node

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.60.0"
    }
  }
}

variable "pm_api_url" {
  type        = string
  description = "The Proxmox API URL"
}

variable "pm_api_token" {
  type        = string
  description = "The Proxmox API token ID and Secret formatted as ID=SECRET"
  sensitive   = true
}

variable "pve_node" {
  type        = string
  description = "The name of your Proxmox node"
  default     = "pve"
}

provider "proxmox" {
  endpoint  = var.pm_api_url
  api_token = var.pm_api_token
  insecure  = true
}

module "infra" {
  source = "../modules/tes-infra"

  vms = {
    "test-terraform-vm" = {
      vmid           = 1000
      proxmox_node   = var.pve_node
      ip_address     = "192.168.122.210/24"
      gateway        = "192.168.122.1"
      iso_file       = "local:iso/ubuntu-24.04.4-live-server-amd64.iso"
      memory         = 2048
      cores          = 2
      disk_size      = 20
      agent_enabled  = false
      ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAabc123testkey..."]
    }
  }
}

output "vm_ids" {
  value = module.infra.vm_ids
}

output "ansible_inventory_data" {
  value = module.infra.ansible_inventory_data
}
