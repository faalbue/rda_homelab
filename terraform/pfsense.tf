resource "proxmox_vm_qemu" "pfsense" {
  name        = "pfsense"
  target_node = var.target_node
  vmid        = 100
  iso         = "local:iso/netgate-installer-v1.2-RELEASE-amd64.iso"

  cores   = 2
  memory  = 4096
  sockets = 1
  cpu     = "host"
  agent   = 0  # no qemu-guest-agent in pfSense by default
  onboot  = true

  scsihw  = "virtio-scsi-pci"
  os_type = "other"
  bios    = "ovmf"  # UEFI — use "seabios" if you prefer legacy

  # WAN interface
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # LAN interface
  network {
    model  = "virtio"
    bridge = "vmbr1"
  }

  disks {
    scsi {
      scsi0 {
        disk {
          size    = "32G"
          storage = "local-lvm"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [network, disks]
  }
}