variable "vms" {
  description = "Map of VMs to create. The map key is used as the hostname."
  type = map(object({
    vmid            = number
    proxmox_node    = string
    ip_address      = string
    gateway         = string
    clone_template  = optional(string)
    iso_file        = optional(string)
    memory          = optional(number, 2048)
    cores           = optional(number, 2)
    storage         = optional(string, "local-lvm")
    disk_size       = optional(number, 10)
    network_bridge  = optional(string, "vmbr0")
    agent_enabled   = optional(bool, true)
    ssh_public_keys = optional(list(string), [])
    tags            = optional(list(string), [])
    started         = optional(bool, true)
    ansible_groups  = optional(list(string), [])
  }))
  default = {}
}

variable "lxcs" {
  description = "Map of LXC containers to create. The map key is used as the hostname."
  type = map(object({
    vmid            = number
    proxmox_node    = string
    ostemplate      = string
    ip_address      = string
    gateway         = string
    memory          = optional(number, 512)
    disk_size       = optional(number, 8)
    ssh_public_keys = optional(list(string), [])
    nesting         = optional(bool, false)
    keyctl          = optional(bool, false)
    tags            = optional(list(string), [])
    mountpoints     = optional(list(object({ volume = string, path = string, size = string })), [])
    network_bridge  = optional(string, "vmbr0")
    ansible_groups  = optional(list(string), [])
  }))
  default = {}
}
