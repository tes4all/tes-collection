# --- Template Lookups (one per unique clone_template) ---

locals {
  # Collect all unique (proxmox_node, clone_template) pairs that need a lookup
  vm_clone_nodes = distinct([
    for k, v in var.vms : v.proxmox_node if v.clone_template != null
  ])

  # Build a map of template name -> vm_id per VM that needs cloning
  template_vm_ids = {
    for k, v in var.vms : k => (
      v.clone_template != null
      ? [for vm in data.proxmox_virtual_environment_vms.templates[v.proxmox_node].vms : vm.vm_id if vm.name == v.clone_template][0]
      : null
    )
  }
}

data "proxmox_virtual_environment_vms" "templates" {
  for_each  = toset(local.vm_clone_nodes)
  node_name = each.value
  tags      = ["template"]
}

# --- Virtual Machines ---

resource "proxmox_virtual_environment_vm" "this" {
  for_each  = var.vms

  node_name = each.value.proxmox_node
  vm_id     = each.value.vmid
  name      = each.key
  started   = each.value.started
  tags      = each.value.tags

  dynamic "clone" {
    for_each = each.value.clone_template != null ? [1] : []
    content {
      vm_id = local.template_vm_ids[each.key]
      full  = true
    }
  }

  dynamic "cdrom" {
    for_each = each.value.iso_file != null ? [1] : []
    content {
      file_id = each.value.iso_file
    }
  }

  cpu {
    cores = each.value.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory
  }

  dynamic "initialization" {
    for_each = each.value.clone_template != null ? [1] : []
    content {
      ip_config {
        ipv4 {
          address = each.value.ip_address
          gateway = each.value.gateway
        }
      }
      user_account {
        username = "ubuntu"
        keys     = each.value.ssh_public_keys
      }
    }
  }

  network_device {
    bridge = each.value.network_bridge
  }

  disk {
    datastore_id = each.value.storage
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
  }

  agent {
    enabled = each.value.agent_enabled
  }
}

# --- LXC Containers ---

resource "proxmox_virtual_environment_container" "this" {
  for_each  = var.lxcs

  node_name = each.value.proxmox_node
  vm_id     = each.value.vmid

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = each.value.ip_address
        gateway = each.value.gateway
      }
    }

    user_account {
      keys = each.value.ssh_public_keys
    }
  }

  disk {
    datastore_id = "local-lvm"
    size         = each.value.disk_size
  }

  memory {
    dedicated = each.value.memory
  }

  operating_system {
    template_file_id = each.value.ostemplate
    type             = "debian"
  }

  network_interface {
    name   = "eth0"
    bridge = each.value.network_bridge
  }

  features {
    nesting = each.value.nesting
    keyctl  = each.value.keyctl
  }

  tags = each.value.tags

  dynamic "mount_point" {
    for_each = each.value.mountpoints
    content {
      volume = mount_point.value.volume
      path   = mount_point.value.path
      size   = mount_point.value.size
    }
  }
}
