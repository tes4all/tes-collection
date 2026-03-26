output "vm_ids" {
  description = "Map of VM hostname to VMID"
  value       = { for k, v in proxmox_virtual_environment_vm.this : k => v.vm_id }
}

output "lxc_ids" {
  description = "Map of LXC hostname to VMID"
  value       = { for k, v in proxmox_virtual_environment_container.this : k => v.vm_id }
}

output "ansible_inventory_data" {
  description = "Aggregated inventory data for all VMs and LXCs"
  value = concat(
    [for k, v in proxmox_virtual_environment_vm.this : {
      name   = v.name
      ip     = var.vms[k].ip_address
      groups = var.vms[k].ansible_groups
    }],
    [for k, v in proxmox_virtual_environment_container.this : {
      name   = v.initialization[0].hostname
      ip     = var.lxcs[k].ip_address
      groups = var.lxcs[k].ansible_groups
    }]
  )
}
