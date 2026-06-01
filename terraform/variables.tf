variable "proxmox_api_url" {
    description = "Proxmox API URL, e.g. https://10.0.0.175:8006/api2/json"
    type        = string
  }

  variable "proxmox_user" {
    description = "Proxmox API user, e.g. root@pam"
    type        = string
    default     = "administrator@pam"
  }

  variable "proxmox_password" {
    description = "Proxmox API password"
    type        = string
    sensitive   = true
  }

  variable "target_node" {
    description = "Proxmox node name to deploy VMs on"
    type        = string
  }
