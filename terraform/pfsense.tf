resource "proxmox_virtual_environment_vm" "pfsense" {
  name      = "pfsense"
  node_name = var.target_node
  vm_id     = 100
  on_boot   = true

  bios = "ovmf"

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = 4096
  }

  agent {
    enabled = false
  }

  cdrom {
    file_id   = "local:iso/netgate-installer-v1.2-RELEASE-amd64.iso"
    interface = "ide2"
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 32
    file_format  = "raw"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  scsi_hardware = "virtio-scsi-pci"

  operating_system {
    type = "other"
  }

  lifecycle {
    ignore_changes = [network_device, disk]
  }
}

