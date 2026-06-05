resource "proxmox_virtual_environment_vm" "pfsense" {
  name      = "pfsense"
  node_name = var.node_name
  vm_id     = 100

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"

  operating_system {
    type = "other"
  }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  # Boot disk
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 32
    file_format  = "raw"
    iothread     = true
    discard      = "on"
  }

  # pfSense ISO
  cdrom {
    file_id = "local:iso/netgate-installer-v1.1.1-RELEASE-amd64.iso"
  }

  # WAN interface
  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # LAN interface
  network_device {
    bridge = "vmbr1"
    model  = "virtio"
  }

  # Boot from CD first for installation, then disk
  boot_order = ["scsi0", "ide3"]

  on_boot = false

  lifecycle {
    ignore_changes = [cdrom]
  }
}
