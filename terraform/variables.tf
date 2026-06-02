variable "proxmox_api_url" {
  description = "Proxmox API endpoint, e.g. https://192.168.1.10:8006"  
  type        = string
  }

  variable "proxmox_user" {
    variable "proxmox_api_token_id" { 
      description = "Proxmox API token ID, e.g. terraform@pve!mytoken"
      type        = string
      default     = "administrator@pam"
  }

  variable "proxmox_password" {
    variable "proxmox_api_token_secret" {
      description = "Proxmox API token secret UUID"
      type        = string
      sensitive   = true
  }

  variable "target_node" {
    description = "Proxmox node name to deploy VMs on"
    type        = string
  }
