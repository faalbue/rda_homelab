# Proxmox VM Setup with Terraform and Ansible

## Overview

This project uses a split-responsibility model:

- **Ansible** creates Debian and Ubuntu Server cloud image templates on Proxmox
- **Ansible** downloads ISOs for pfSense and Windows 10 to Proxmox
- **Terraform** provisions VMs by cloning templates or booting from ISOs
- **Ansible** configures the provisioned VMs
- **Make** orchestrates the full pipeline

## Prerequisites

- Proxmox VE host with API access
- Terraform installed locally
- Ansible installed locally
- SSH key pair for cloud-init access
- Windows 10 ISO (download from Microsoft, must be transferred manually)

## Directory Structure

```
proxmox-infra/
├── ansible/
│   ├── inventory.ini              # Proxmox host inventory
│   ├── create-template.yml        # Debian template creation playbook
│   ├── create-ubuntu-template.yml # Ubuntu Server 24.04 template playbook
│   ├── download-pfsense.yml       # pfSense ISO download playbook (Option A)
│   ├── upload-pfsense.yml         # pfSense ISO upload from local (Option B)
│   ├── setup-windows-iso.yml      # VirtIO drivers + Windows ISO reminder (Option A)
│   ├── upload-windows-iso.yml     # Upload local Windows ISO + VirtIO (Option B)
│   ├── create-win10-template.yml            # Windows 10 template (interactive)
│   ├── build-autounattend-iso.yml           # Build Autounattend.xml ISO
│   ├── create-win10-template-unattended.yml # Windows 10 template (unattended)
│   └── configure-vms.yml                    # VM configuration playbook
├── terraform/
│   ├── providers.tf               # Proxmox provider config
│   ├── variables.tf               # Input variables
│   ├── main.tf                    # Debian VM resource definitions
│   ├── ubuntu.tf                  # Ubuntu Server VM resource definitions
│   ├── pfsense.tf                 # pfSense VM resource definition
│   ├── windows.tf                 # Windows 10 VM resource definitions
│   ├── outputs.tf                 # Outputs and inventory generation
│   ├── inventory.tftpl            # Ansible inventory template
│   └── terraform.tfvars           # Variable values (gitignored)
├── resources/
│   ├── pfSense-CE-2.7.2-RELEASE-amd64.iso  # Local ISO (gitignored, for Option B)
│   ├── Win10_22H2_English_x64v1.iso       # Local ISO (gitignored, for Option B)
│   └── Autounattend.xml                   # Windows unattended answer file
└── Makefile
```

## Proxmox API Token Setup

Run these commands on the Proxmox host to create a dedicated API token for Terraform:

```bash
pveum role add TerraformRole -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.Monitor VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit"

pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role TerraformRole

# Save the output — this is your API token secret
pveum user token add terraform@pve terraform-token --privsep=0
```

## pfSense VM

pfSense is a FreeBSD-based firewall appliance. Unlike Debian VMs, it cannot use cloud-init and requires an interactive install from an ISO. The workflow is: download the ISO to Proxmox via Ansible, create the VM via Terraform, then complete the install through the Proxmox console.

### Option A: Download pfSense ISO from URL — `ansible/download-pfsense.yml`

If you have a direct download URL (e.g., from a Netgate account), this playbook downloads and extracts the gzipped ISO on the Proxmox host.

```yaml
---
- name: Download pfSense ISO to Proxmox
  hosts: proxmox
  become: true
  vars:
    pfsense_iso_url: "https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz"
    pfsense_iso_gz: "/tmp/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz"
    pfsense_iso_dest: "/var/lib/vz/template/iso/pfSense-CE-2.7.2-RELEASE-amd64.iso"

  tasks:
    - name: Check if ISO already exists
      stat:
        path: "{{ pfsense_iso_dest }}"
      register: iso_file

    - name: Download and extract pfSense ISO
      when: not iso_file.stat.exists
      block:
        - name: Download pfSense ISO (gzipped)
          get_url:
            url: "{{ pfsense_iso_url }}"
            dest: "{{ pfsense_iso_gz }}"
            mode: "0644"

        - name: Extract ISO
          command: gunzip -k {{ pfsense_iso_gz }}
          args:
            creates: "{{ pfsense_iso_dest }}"

        - name: Move ISO to storage
          command: mv /tmp/pfSense-CE-2.7.2-RELEASE-amd64.iso {{ pfsense_iso_dest }}
          args:
            creates: "{{ pfsense_iso_dest }}"

        - name: Clean up gzipped file
          file:
            path: "{{ pfsense_iso_gz }}"
            state: absent
```

### Option B: Upload local ISO — `ansible/upload-pfsense.yml`

pfSense CE requires registration to download, even for the community edition. If you've already downloaded the ISO locally, place it in `./resources/` and use this playbook to upload it to Proxmox.

```yaml
---
- name: Upload pfSense ISO to Proxmox
  hosts: proxmox
  become: true
  vars:
    pfsense_iso_local: "{{ playbook_dir }}/../resources/pfSense-CE-2.7.2-RELEASE-amd64.iso"
    pfsense_iso_dest: "/var/lib/vz/template/iso/pfSense-CE-2.7.2-RELEASE-amd64.iso"

  tasks:
    - name: Check if ISO already exists on Proxmox
      stat:
        path: "{{ pfsense_iso_dest }}"
      register: iso_file

    - name: Upload pfSense ISO to Proxmox
      when: not iso_file.stat.exists
      copy:
        src: "{{ pfsense_iso_local }}"
        dest: "{{ pfsense_iso_dest }}"
        mode: "0644"
```

Run with:

```bash
make pfsense-iso-upload
```

### pfSense VM Resource — `terraform/pfsense.tf`

pfSense needs at least two network interfaces (WAN + LAN) and does not use cloud-init.

```hcl
resource "proxmox_vm_qemu" "pfsense" {
  name        = "pfsense"
  target_node = var.target_node
  vmid        = 100
  iso         = "local:iso/pfSense-CE-2.7.2-RELEASE-amd64.iso"

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
```

### Completing the pfSense Install

After `terraform apply` creates the VM, you must complete the interactive installer:

**Option 1 — Proxmox Web Console:**

1. Browse to `https://proxmox:8006`
2. Select the `pfsense` VM → Console
3. Walk through the pfSense installer (accept defaults for most options)
4. VM reboots after install and drops the ISO

**Option 2 — VNC over SSH tunnel (fully headless):**

```bash
# Get the VNC port
ssh root@proxmox "qm monitor 100 -cmd 'info vnc'"

# SSH tunnel to access VNC locally
ssh -L 5900:localhost:<vnc_port> root@proxmox

# Connect with any VNC client to localhost:5900
```

### Accessing pfSense Post-Install

The WebConfigurator is available on the LAN interface at `https://192.168.1.1` by default (admin/pfsense).

To reach it remotely through Proxmox:

```bash
ssh -L 8443:192.168.1.1:443 root@proxmox
# Then browse to https://localhost:8443
```

For ongoing pfSense config automation, consider:
- [pfsensible.core](https://github.com/pfsensible/core) Ansible collection
- pfSense XML config restore — pre-build a `config.xml` and inject it into the VM disk after install

## Windows 10 VM

Windows 10 on Proxmox requires a different approach from Linux VMs. You need both the Windows ISO and the VirtIO drivers ISO (so Windows can see the virtual disk and network during install). After an interactive install, the VM is converted to a template for cloning.

### Option A: Download VirtIO Drivers Only — `ansible/setup-windows-iso.yml`

Microsoft doesn't provide a direct download URL for the Windows 10 ISO — you must download it manually. This playbook downloads the VirtIO drivers ISO and reminds you to transfer the Windows ISO separately.

```yaml
---
- name: Setup Windows 10 ISOs on Proxmox
  hosts: proxmox
  become: true
  vars:
    virtio_iso_url: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    virtio_iso_dest: "/var/lib/vz/template/iso/virtio-win.iso"
    win10_iso_dest: "/var/lib/vz/template/iso/Win10_22H2_English_x64v1.iso"

  tasks:
    - name: Download VirtIO drivers ISO
      get_url:
        url: "{{ virtio_iso_url }}"
        dest: "{{ virtio_iso_dest }}"
        mode: "0644"

    - name: Check if Windows 10 ISO exists
      stat:
        path: "{{ win10_iso_dest }}"
      register: win10_iso

    - name: Remind to upload Windows ISO
      debug:
        msg: >
          Windows 10 ISO not found at {{ win10_iso_dest }}.
          Download from https://www.microsoft.com/en-us/software-download/windows10ISO
          and transfer with: scp Win10_22H2_English_x64v1.iso root@proxmox:/var/lib/vz/template/iso/
      when: not win10_iso.stat.exists
```

### Option B: Upload local Windows ISO + download VirtIO — `ansible/upload-windows-iso.yml`

If you've already downloaded the Windows 10 ISO locally, place it in `./resources/` and use this playbook to upload it to Proxmox alongside the VirtIO drivers.

```yaml
---
- name: Upload Windows 10 ISO and download VirtIO drivers to Proxmox
  hosts: proxmox
  become: true
  vars:
    win10_iso_local: "{{ playbook_dir }}/../resources/Win10_22H2_English_x64v1.iso"
    win10_iso_dest: "/var/lib/vz/template/iso/Win10_22H2_English_x64v1.iso"
    virtio_iso_url: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    virtio_iso_dest: "/var/lib/vz/template/iso/virtio-win.iso"

  tasks:
    - name: Download VirtIO drivers ISO
      get_url:
        url: "{{ virtio_iso_url }}"
        dest: "{{ virtio_iso_dest }}"
        mode: "0644"

    - name: Check if Windows 10 ISO already exists on Proxmox
      stat:
        path: "{{ win10_iso_dest }}"
      register: win10_iso

    - name: Upload Windows 10 ISO to Proxmox
      when: not win10_iso.stat.exists
      copy:
        src: "{{ win10_iso_local }}"
        dest: "{{ win10_iso_dest }}"
        mode: "0644"
```

Run with:

```bash
make win10-iso-upload
```

### Create Windows 10 Template (Interactive) — `ansible/create-win10-template.yml`

Creates a VM from the Windows ISO, configured with VirtIO drivers mounted as a second CD-ROM. After you complete the interactive Windows install, run this playbook again — it will detect the installed VM and convert it to a template.

```yaml
---
- name: Create Windows 10 template VM on Proxmox
  hosts: proxmox
  become: true
  vars:
    template_vmid: 9001
    template_name: "win10-template"
    storage: "local-lvm"
    win10_iso: "local:iso/Win10_22H2_English_x64v1.iso"
    virtio_iso: "local:iso/virtio-win.iso"

  tasks:
    - name: Check if VM already exists
      command: qm status {{ template_vmid }}
      register: vm_exists
      failed_when: false
      changed_when: false

    - name: Check if VM is already a template
      command: qm config {{ template_vmid }}
      register: vm_config
      failed_when: false
      changed_when: false
      when: vm_exists.rc == 0

    - name: Create Windows 10 installer VM
      when: vm_exists.rc != 0
      block:
        - name: Create base VM
          command: >
            qm create {{ template_vmid }}
            --name {{ template_name }}
            --memory 4096
            --cores 2
            --sockets 1
            --cpu host
            --net0 virtio,bridge=vmbr0
            --scsihw virtio-scsi-pci
            --agent enabled=1
            --ostype win10
            --bios ovmf
            --machine pc-q35-8.1
            --tpmstate0 {{ storage }}:1,version=v2.0
            --efidisk0 {{ storage }}:1

        - name: Create disk
          command: >
            qm set {{ template_vmid }}
            --scsi0 {{ storage }}:64

        - name: Attach Windows ISO
          command: >
            qm set {{ template_vmid }}
            --ide0 {{ win10_iso }},media=cdrom

        - name: Attach VirtIO drivers ISO
          command: >
            qm set {{ template_vmid }}
            --ide2 {{ virtio_iso }},media=cdrom

        - name: Set boot order (CD first, then disk)
          command: >
            qm set {{ template_vmid }}
            --boot order=ide0;scsi0

        - name: Start VM for installation
          command: qm start {{ template_vmid }}

        - name: Display install instructions
          debug:
            msg: >
              Windows 10 installer VM is running (VMID {{ template_vmid }}).
              Complete the install via Proxmox console.
              During disk selection, click "Load driver" and browse the VirtIO CD
              (D:\vioscsi\w10\amd64 for storage, D:\NetKVM\w10\amd64 for network).
              After install, install the QEMU guest agent from D:\guest-agent\qemu-ga-x86_64.msi.
              Then run this playbook again to convert to template.

    - name: Convert to template if VM exists and is not already a template
      when:
        - vm_exists.rc == 0
        - vm_config.stdout is defined
        - "'template: 1' not in vm_config.stdout"
      block:
        - name: Stop VM if running
          command: qm shutdown {{ template_vmid }} --timeout 120
          failed_when: false

        - name: Wait for VM to stop
          command: qm wait {{ template_vmid }} --timeout 120
          failed_when: false

        - name: Remove ISO media
          command: >
            qm set {{ template_vmid }}
            --ide0 none,media=cdrom
            --ide2 none,media=cdrom

        - name: Set boot to disk only
          command: >
            qm set {{ template_vmid }}
            --boot order=scsi0

        - name: Convert to template
          command: qm template {{ template_vmid }}

        - name: Template created
          debug:
            msg: "Windows 10 template created (VMID {{ template_vmid }}). Ready for cloning via Terraform."
```

### Interactive Install Walkthrough

After the installer VM starts:

1. Open the Proxmox console at `https://proxmox:8006` → select VM `9001` → Console
2. Boot from the Windows ISO — press any key when prompted
3. At disk selection, Windows won't see the VirtIO disk. Click **Load driver**:
   - Browse to the VirtIO CD drive
   - Load **`vioscsi\w10\amd64`** (storage controller)
   - Load **`NetKVM\w10\amd64`** (network adapter)
   - The disk will now appear — select it and continue
4. Complete the Windows installation normally
5. After Windows boots, install additional VirtIO drivers:
   - Open the VirtIO CD in Explorer
   - Run **`virtio-win-gt-x64.msi`** to install all drivers
   - Run **`guest-agent\qemu-ga-x86_64.msi`** to install the QEMU guest agent
6. Run Windows Update, install any needed software for your base image
7. Run `sysprep` to generalize the image (optional but recommended for cloning):
   ```
   C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
   ```
8. After the VM shuts down, run the playbook again to convert to template:
   ```bash
   make win10-template
   ```

### Unattended Install — `Autounattend.xml`

Windows Setup looks for an `Autounattend.xml` file on removable media at boot. By packing this file into a small ISO and mounting it as a third CD-ROM, the entire installation runs hands-off — including VirtIO driver loading, account creation, and sysprep.

#### Answer File — `resources/Autounattend.xml`

This answer file handles: language/locale, license acceptance, VirtIO driver injection, disk partitioning (GPT/UEFI), local admin account creation, skipping OOBE, and post-install commands (VirtIO drivers MSI, QEMU guest agent, sysprep).

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <!-- Pass 1: Windows PE — runs during the installer before Windows is on disk -->
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               language="neutral" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               language="neutral" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

      <!-- Load VirtIO storage + network drivers so the installer can see the disk and NIC -->
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1">
          <Path>E:\vioscsi\w10\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2">
          <Path>E:\NetKVM\w10\amd64</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3">
          <Path>E:\viostor\w10\amd64</Path>
        </PathAndCredentials>
      </DriverPaths>

      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <!-- EFI System Partition -->
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Size>260</Size>
              <Type>EFI</Type>
            </CreatePartition>
            <!-- Microsoft Reserved Partition -->
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Size>16</Size>
              <Type>MSR</Type>
            </CreatePartition>
            <!-- Windows partition — uses remaining space -->
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Extend>true</Extend>
              <Type>Primary</Type>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>System</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>

      <UserData>
        <ProductKey>
          <!-- Generic Windows 10 Pro KMS key — activates against KMS or skips activation -->
          <Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>

  <!-- Pass 4: Specialize — runs after image is applied, before first boot -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               language="neutral">
      <ComputerName>WIN10-TEMPLATE</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>

  <!-- Pass 7: OOBE — runs on first user-facing boot -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               language="neutral" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>

      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>admin</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>changeme</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>admin</Username>
        <Password>
          <Value>changeme</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>

      <!-- Run once after first login — install drivers, guest agent, then sysprep + shutdown -->
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c msiexec /i E:\virtio-win-gt-x64.msi /qn /norestart</CommandLine>
          <Description>Install VirtIO drivers</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>cmd /c msiexec /i E:\guest-agent\qemu-ga-x86_64.msi /qn /norestart</CommandLine>
          <Description>Install QEMU guest agent</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <CommandLine>cmd /c C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet</CommandLine>
          <Description>Sysprep and shutdown for template conversion</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
```

**Important notes on the answer file:**

- **Drive letter for VirtIO ISO**: The XML uses `E:\` for the VirtIO paths. With three CD-ROMs (Windows ISO on ide0, autounattend ISO on ide1, VirtIO on ide2), Windows PE typically assigns the VirtIO disc to `E:\`. If driver loading fails, check the assigned letter via the installer's Shift+F10 command prompt and adjust the paths.
- **Product key**: The generic KMS key (`W269N-WFGWX-YVC9B-4J6C9-T83GX`) is for Windows 10 Pro — it satisfies the installer but doesn't activate Windows. Replace with your volume license key if applicable.
- **Password**: The `admin` account is created with password `changeme`. Change this in the XML or after cloning.
- **Sysprep runs automatically**: After the first login, VirtIO drivers and guest agent are installed silently, then sysprep generalizes and shuts down the VM — ready for template conversion with no manual steps.

#### Build the Autounattend ISO — `ansible/build-autounattend-iso.yml`

Packs the `Autounattend.xml` into a small ISO on the Proxmox host so it can be mounted as a CD-ROM.

```yaml
---
- name: Build Autounattend ISO on Proxmox
  hosts: proxmox
  become: true
  vars:
    autounattend_local: "{{ playbook_dir }}/../resources/Autounattend.xml"
    iso_staging_dir: "/tmp/autounattend"
    autounattend_iso_dest: "/var/lib/vz/template/iso/autounattend.iso"

  tasks:
    - name: Check if ISO already exists
      stat:
        path: "{{ autounattend_iso_dest }}"
      register: iso_file

    - name: Build Autounattend ISO
      when: not iso_file.stat.exists
      block:
        - name: Install genisoimage
          apt:
            name: genisoimage
            state: present

        - name: Create staging directory
          file:
            path: "{{ iso_staging_dir }}"
            state: directory
            mode: "0755"

        - name: Copy Autounattend.xml to staging
          copy:
            src: "{{ autounattend_local }}"
            dest: "{{ iso_staging_dir }}/Autounattend.xml"
            mode: "0644"

        - name: Generate ISO
          command: >
            genisoimage -o {{ autounattend_iso_dest }}
            -J -r -V "AUTOUNATTEND"
            {{ iso_staging_dir }}

        - name: Clean up staging directory
          file:
            path: "{{ iso_staging_dir }}"
            state: absent
```

#### Unattended Template Creation — `ansible/create-win10-template-unattended.yml`

Same as the interactive playbook but mounts the autounattend ISO as a third CD-ROM. The VM installs, configures, syspreps, and shuts down on its own — then the playbook converts it to a template.

```yaml
---
- name: Create Windows 10 template VM (unattended) on Proxmox
  hosts: proxmox
  become: true
  vars:
    template_vmid: 9001
    template_name: "win10-template"
    storage: "local-lvm"
    win10_iso: "local:iso/Win10_22H2_English_x64v1.iso"
    virtio_iso: "local:iso/virtio-win.iso"
    autounattend_iso: "local:iso/autounattend.iso"
    # Total wait: up to 30 minutes for install + sysprep + shutdown
    install_timeout: 1800

  tasks:
    - name: Check if VM already exists
      command: qm status {{ template_vmid }}
      register: vm_exists
      failed_when: false
      changed_when: false

    - name: Check if VM is already a template
      command: qm config {{ template_vmid }}
      register: vm_config
      failed_when: false
      changed_when: false
      when: vm_exists.rc == 0

    - name: Create and install Windows 10 VM (unattended)
      when: vm_exists.rc != 0
      block:
        - name: Create base VM
          command: >
            qm create {{ template_vmid }}
            --name {{ template_name }}
            --memory 4096
            --cores 2
            --sockets 1
            --cpu host
            --net0 virtio,bridge=vmbr0
            --scsihw virtio-scsi-pci
            --agent enabled=1
            --ostype win10
            --bios ovmf
            --machine pc-q35-8.1
            --tpmstate0 {{ storage }}:1,version=v2.0
            --efidisk0 {{ storage }}:1

        - name: Create disk
          command: >
            qm set {{ template_vmid }}
            --scsi0 {{ storage }}:64

        - name: Attach Windows ISO
          command: >
            qm set {{ template_vmid }}
            --ide0 {{ win10_iso }},media=cdrom

        - name: Attach Autounattend ISO
          command: >
            qm set {{ template_vmid }}
            --ide1 {{ autounattend_iso }},media=cdrom

        - name: Attach VirtIO drivers ISO
          command: >
            qm set {{ template_vmid }}
            --ide2 {{ virtio_iso }},media=cdrom

        - name: Set boot order (CD first, then disk)
          command: >
            qm set {{ template_vmid }}
            --boot order=ide0;scsi0

        - name: Start VM for unattended installation
          command: qm start {{ template_vmid }}

        - name: Wait for VM to install, sysprep, and shut down
          command: qm wait {{ template_vmid }} --timeout {{ install_timeout }}
          register: wait_result

        - name: Remove ISO media
          command: >
            qm set {{ template_vmid }}
            --ide0 none,media=cdrom
            --ide1 none,media=cdrom
            --ide2 none,media=cdrom

        - name: Set boot to disk only
          command: >
            qm set {{ template_vmid }}
            --boot order=scsi0

        - name: Convert to template
          command: qm template {{ template_vmid }}

        - name: Template created
          debug:
            msg: "Windows 10 template created (VMID {{ template_vmid }}). Ready for cloning via Terraform."

    - name: Convert to template if VM exists but is not a template
      when:
        - vm_exists.rc == 0
        - vm_config.stdout is defined
        - "'template: 1' not in vm_config.stdout"
      block:
        - name: Stop VM if running
          command: qm shutdown {{ template_vmid }} --timeout 120
          failed_when: false

        - name: Wait for VM to stop
          command: qm wait {{ template_vmid }} --timeout 120
          failed_when: false

        - name: Remove ISO media
          command: >
            qm set {{ template_vmid }}
            --ide0 none,media=cdrom
            --ide1 none,media=cdrom
            --ide2 none,media=cdrom

        - name: Set boot to disk only
          command: >
            qm set {{ template_vmid }}
            --boot order=scsi0

        - name: Convert to template
          command: qm template {{ template_vmid }}

        - name: Template created
          debug:
            msg: "Windows 10 template created (VMID {{ template_vmid }}). Ready for cloning via Terraform."
```

Run with:

```bash
make win10-template-auto
```

This is fully hands-off — the playbook starts the VM, waits up to 30 minutes for Windows to install + sysprep + shut down, then strips the ISOs and converts to a template.

### Windows 10 VM Resource — `terraform/windows.tf`

Clone VMs from the Windows template. No cloud-init — Windows uses sysprep + unattended XML if you need automated setup.

```hcl
variable "windows_vms" {
  description = "Map of Windows VMs to create"
  type = map(object({
    vmid   = number
    cores  = number
    memory = number
    disk   = string
  }))
  default = {
    "win-desktop-01" = {
      vmid   = 201
      cores  = 4
      memory = 8192
      disk   = "128G"
    }
  }
}

resource "proxmox_vm_qemu" "windows_vm" {
  for_each    = var.windows_vms
  name        = each.key
  target_node = var.target_node
  clone       = "win10-template"
  full_clone  = true
  vmid        = each.value.vmid

  cores   = each.value.cores
  memory  = each.value.memory
  sockets = 1
  cpu     = "host"
  agent   = 1
  onboot  = false

  scsihw  = "virtio-scsi-pci"
  os_type = "other"
  bios    = "ovmf"
  machine = "pc-q35-8.1"

  disks {
    scsi {
      scsi0 {
        disk {
          size    = each.value.disk
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  lifecycle {
    ignore_changes = [network, disks]
  }
}
```

### Accessing Windows VMs Remotely

After the VM boots from a cloned template:

**Option 1 — Proxmox Console:**

Browse to `https://proxmox:8006` → select the VM → Console

**Option 2 — RDP over SSH tunnel:**

```bash
# Tunnel RDP through Proxmox
ssh -L 3389:<vm-ip>:3389 root@proxmox

# Connect with any RDP client to localhost:3389
```

**Option 3 — Enable RDP via Proxmox console first, then connect directly** if the VM is on a reachable network.

## Ubuntu Server 24.04 Template

Follows the same cloud-init pattern as the Debian template — download a cloud image, import it, and convert to a template.

### Template Creation — `ansible/create-ubuntu-template.yml`

Downloads the Ubuntu Server 24.04 (Noble Numbat) cloud image and registers it as a Proxmox VM template. Idempotent — skips creation if the template already exists.

```yaml
---
- name: Create Ubuntu Server 24.04 cloud image template in Proxmox
  hosts: proxmox
  become: true
  vars:
    image_url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    image_path: "/tmp/noble-server-cloudimg-amd64.img"
    template_vmid: 9002
    template_name: "ubuntu-2404-template"
    storage: "local-lvm"

  tasks:
    - name: Download Ubuntu Server 24.04 cloud image
      get_url:
        url: "{{ image_url }}"
        dest: "{{ image_path }}"
        mode: "0644"

    - name: Check if template already exists
      command: qm status {{ template_vmid }}
      register: template_exists
      failed_when: false
      changed_when: false

    - name: Create template VM
      when: template_exists.rc != 0
      block:
        - name: Create base VM
          command: >
            qm create {{ template_vmid }}
            --name {{ template_name }}
            --memory 2048
            --cores 2
            --net0 virtio,bridge=vmbr0
            --scsihw virtio-scsi-pci
            --serial0 socket
            --vga serial0
            --agent enabled=1
            --ostype l26

        - name: Import disk image
          command: >
            qm importdisk {{ template_vmid }}
            {{ image_path }}
            {{ storage }}

        - name: Attach imported disk
          command: >
            qm set {{ template_vmid }}
            --scsi0 {{ storage }}:vm-{{ template_vmid }}-disk-0

        - name: Set boot disk
          command: >
            qm set {{ template_vmid }}
            --boot order=scsi0

        - name: Add cloud-init drive
          command: >
            qm set {{ template_vmid }}
            --ide2 {{ storage }}:cloudinit

        - name: Set cloud-init defaults
          command: >
            qm set {{ template_vmid }}
            --ciuser ubuntu
            --ipconfig0 ip=dhcp

        - name: Convert to template
          command: qm template {{ template_vmid }}

    - name: Clean up downloaded image
      file:
        path: "{{ image_path }}"
        state: absent
```

Key differences from the Debian template:
- **Image source**: `cloud-images.ubuntu.com` — the `.img` file is a qcow2 image despite the extension
- **VMID**: `9002` (Debian is `9000`, Windows is `9001`)
- **Default cloud-init user**: `ubuntu` instead of `debian`

### Ubuntu Server VM Resource — `terraform/ubuntu.tf`

Clones VMs from the Ubuntu template. Uses cloud-init for user/SSH/network configuration, identical workflow to Debian.

```hcl
variable "ubuntu_vms" {
  description = "Map of Ubuntu Server VMs to create"
  type = map(object({
    vmid   = number
    cores  = number
    memory = number
    disk   = string
    ip     = string
  }))
  default = {
    "docker-01" = {
      vmid   = 111
      cores  = 4
      memory = 8192
      disk   = "64G"
      ip     = "192.168.1.211/24"
    }
    "k8s-node-01" = {
      vmid   = 112
      cores  = 4
      memory = 8192
      disk   = "64G"
      ip     = "192.168.1.212/24"
    }
  }
}

resource "proxmox_vm_qemu" "ubuntu_vm" {
  for_each    = var.ubuntu_vms
  name        = each.key
  target_node = var.target_node
  clone       = "ubuntu-2404-template"
  full_clone  = true
  vmid        = each.value.vmid

  cores   = each.value.cores
  memory  = each.value.memory
  sockets = 1
  cpu     = "host"
  agent   = 1

  scsihw = "virtio-scsi-pci"

  disks {
    scsi {
      scsi0 {
        disk {
          size    = each.value.disk
          storage = "local-lvm"
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  os_type   = "cloud-init"
  ciuser    = "ubuntu"
  sshkeys   = var.ssh_public_key
  ipconfig0 = "ip=${each.value.ip},gw=192.168.1.1"

  lifecycle {
    ignore_changes = [network]
  }
}
```

### Ansible Configuration for Ubuntu VMs

The existing `configure-vms.yml` works for Ubuntu VMs as well — both are Debian-based and use `apt`. Update the inventory template to include Ubuntu VMs alongside Debian VMs.

#### Updated Inventory Template — `terraform/inventory.tftpl`

```ini
[debian_vms]
%{ for name, vm in vms ~}
${name} ansible_host=${split("/", vm.ip)[0]} ansible_user=debian
%{ endfor ~}

[ubuntu_vms]
%{ for name, vm in ubuntu_vms ~}
${name} ansible_host=${split("/", vm.ip)[0]} ansible_user=ubuntu
%{ endfor ~}

[linux_vms:children]
debian_vms
ubuntu_vms

[linux_vms:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
```

#### Updated Outputs — `terraform/outputs.tf`

```hcl
output "vm_info" {
  description = "VM names and IPs"
  value = merge(
    {
      for name, vm in proxmox_vm_qemu.vm :
      name => { vmid = vm.vmid }
    },
    {
      for name, vm in proxmox_vm_qemu.ubuntu_vm :
      name => { vmid = vm.vmid }
    }
  )
}

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.tftpl", {
    vms        = var.vms
    ubuntu_vms = var.ubuntu_vms
  })
  filename = "${path.module}/../ansible/inventory-vms.ini"
}
```

#### Updated VM Configuration — `ansible/configure-vms.yml`

Change the `hosts` target to include both Debian and Ubuntu VMs:

```yaml
---
- name: Configure Linux VMs
  hosts: linux_vms
  become: true
  gather_facts: true

  tasks:
    - name: Wait for cloud-init to finish
      command: cloud-init status --wait
      changed_when: false

    - name: Update apt cache
      apt:
        update_cache: true
        cache_valid_time: 3600

    - name: Install base packages
      apt:
        name:
          - vim
          - curl
          - wget
          - htop
          - qemu-guest-agent
        state: present

    - name: Enable and start qemu-guest-agent
      systemd:
        name: qemu-guest-agent
        enabled: true
        state: started

    - name: Set timezone
      timezone:
        name: UTC
```

### Debian vs Ubuntu Templates

| | Debian 12 | Ubuntu Server 24.04 |
|---|---|---|
| VMID | 9000 | 9002 |
| Cloud image source | cloud.debian.org | cloud-images.ubuntu.com |
| Image format | `.qcow2` | `.img` (qcow2) |
| Default user | `debian` | `ubuntu` |
| Package manager | apt | apt |
| Init system | systemd | systemd |
| Kernel | 6.1 LTS | 6.8 HWE |
| Support cycle | ~5 years | 5 years (10 with ESM) |

## Ansible — Debian Template & VM Configuration

### Proxmox Host Inventory — `ansible/inventory.ini`

```ini
[proxmox]
proxmox01 ansible_host=192.168.1.100 ansible_user=root
```

### Template Creation — `ansible/create-template.yml`

Downloads the Debian 12 cloud image and registers it as a Proxmox VM template. Idempotent — skips creation if the template already exists.

```yaml
---
- name: Create Debian cloud image template in Proxmox
  hosts: proxmox
  become: true
  vars:
    image_url: "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
    image_path: "/tmp/debian-12-generic-amd64.qcow2"
    template_vmid: 9000
    template_name: "debian-12-template"
    storage: "local-lvm"

  tasks:
    - name: Download Debian cloud image
      get_url:
        url: "{{ image_url }}"
        dest: "{{ image_path }}"
        mode: "0644"

    - name: Check if template already exists
      command: qm status {{ template_vmid }}
      register: template_exists
      failed_when: false
      changed_when: false

    - name: Create template VM
      when: template_exists.rc != 0
      block:
        - name: Create base VM
          command: >
            qm create {{ template_vmid }}
            --name {{ template_name }}
            --memory 2048
            --cores 2
            --net0 virtio,bridge=vmbr0
            --scsihw virtio-scsi-pci
            --serial0 socket
            --vga serial0
            --agent enabled=1
            --ostype l26

        - name: Import disk image
          command: >
            qm importdisk {{ template_vmid }}
            {{ image_path }}
            {{ storage }}

        - name: Attach imported disk
          command: >
            qm set {{ template_vmid }}
            --scsi0 {{ storage }}:vm-{{ template_vmid }}-disk-0

        - name: Set boot disk
          command: >
            qm set {{ template_vmid }}
            --boot order=scsi0

        - name: Add cloud-init drive
          command: >
            qm set {{ template_vmid }}
            --ide2 {{ storage }}:cloudinit

        - name: Set cloud-init defaults
          command: >
            qm set {{ template_vmid }}
            --ciuser debian
            --ipconfig0 ip=dhcp

        - name: Convert to template
          command: qm template {{ template_vmid }}

    - name: Clean up downloaded image
      file:
        path: "{{ image_path }}"
        state: absent
```

### VM Configuration — `ansible/configure-vms.yml`

Runs against VMs after Terraform provisions them. Uses the inventory file generated by Terraform.

```yaml
---
- name: Configure Debian VMs
  hosts: debian_vms
  become: true
  gather_facts: true

  tasks:
    - name: Wait for cloud-init to finish
      command: cloud-init status --wait
      changed_when: false

    - name: Update apt cache
      apt:
        update_cache: true
        cache_valid_time: 3600

    - name: Install base packages
      apt:
        name:
          - vim
          - curl
          - wget
          - htop
          - qemu-guest-agent
        state: present

    - name: Enable and start qemu-guest-agent
      systemd:
        name: qemu-guest-agent
        enabled: true
        state: started

    - name: Set timezone
      timezone:
        name: UTC
```

### All VM Types Compared

| | Debian 12 | Ubuntu 24.04 | pfSense | Windows 10 |
|---|---|---|---|---|
| Provisioning | Clone template | Clone template | Boot from ISO | Clone template |
| Template creation | Cloud image import | Cloud image import | N/A (no template) | ISO install + sysprep |
| Initial config | Cloud-init | Cloud-init | Interactive | Sysprep OOBE / unattend.xml |
| Default user | `debian` | `ubuntu` | admin | Administrator |
| Guest agent | qemu-guest-agent | qemu-guest-agent | No | qemu-ga-x86_64.msi |
| Extra drivers | None | None | None | VirtIO drivers required |
| Network | Single NIC | Single NIC | WAN + LAN | Single NIC |
| BIOS | SeaBIOS | SeaBIOS | OVMF / SeaBIOS | OVMF (UEFI) + TPM 2.0 |
| Typical RAM | 2 GB | 2 GB | 4 GB | 8 GB |
| Typical disk | 32 GB | 32 GB | 32 GB | 128 GB |

## Terraform

### Provider Configuration — `terraform/providers.tf`

```hcl
terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "~> 3.0"
    }
  }
}

provider "proxmox" {
  pm_api_url          = var.proxmox_api_url
  pm_api_token_id     = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token_secret
  pm_tls_insecure     = true
}
```

### Variables — `terraform/variables.tf`

```hcl
variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
  default     = "https://192.168.1.100:8006/api2/json"
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID"
  type        = string
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for cloud-init"
  type        = string
}

variable "target_node" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "vms" {
  description = "Map of VMs to create"
  type = map(object({
    vmid   = number
    cores  = number
    memory = number
    disk   = string
    ip     = string
  }))
  default = {
    "web-01" = {
      vmid   = 101
      cores  = 2
      memory = 2048
      disk   = "32G"
      ip     = "192.168.1.201/24"
    }
    "web-02" = {
      vmid   = 102
      cores  = 2
      memory = 2048
      disk   = "32G"
      ip     = "192.168.1.202/24"
    }
    "db-01" = {
      vmid   = 103
      cores  = 4
      memory = 4096
      disk   = "64G"
      ip     = "192.168.1.203/24"
    }
  }
}
```

### VM Resources — `terraform/main.tf`

Clones the Debian template for each entry in the `vms` variable map.

```hcl
resource "proxmox_vm_qemu" "vm" {
  for_each    = var.vms
  name        = each.key
  target_node = var.target_node
  clone       = "debian-12-template"
  full_clone  = true
  vmid        = each.value.vmid

  cores   = each.value.cores
  memory  = each.value.memory
  sockets = 1
  cpu     = "host"
  agent   = 1

  scsihw = "virtio-scsi-pci"

  disks {
    scsi {
      scsi0 {
        disk {
          size    = each.value.disk
          storage = "local-lvm"
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }

  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  os_type   = "cloud-init"
  ciuser    = "debian"
  sshkeys   = var.ssh_public_key
  ipconfig0 = "ip=${each.value.ip},gw=192.168.1.1"

  lifecycle {
    ignore_changes = [network]
  }
}
```

### Outputs and Inventory Generation — `terraform/outputs.tf`

Generates an Ansible inventory file on `terraform apply`. Includes both Debian and Ubuntu VMs.

```hcl
output "vm_info" {
  description = "VM names and IPs"
  value = merge(
    {
      for name, vm in proxmox_vm_qemu.vm :
      name => { vmid = vm.vmid }
    },
    {
      for name, vm in proxmox_vm_qemu.ubuntu_vm :
      name => { vmid = vm.vmid }
    }
  )
}

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.tftpl", {
    vms        = var.vms
    ubuntu_vms = var.ubuntu_vms
  })
  filename = "${path.module}/../ansible/inventory-vms.ini"
}
```

### Inventory Template — `terraform/inventory.tftpl`

Groups Debian and Ubuntu VMs separately (different default users), then combines them under `linux_vms` for shared Ansible configuration.

```ini
[debian_vms]
%{ for name, vm in vms ~}
${name} ansible_host=${split("/", vm.ip)[0]} ansible_user=debian
%{ endfor ~}

[ubuntu_vms]
%{ for name, vm in ubuntu_vms ~}
${name} ansible_host=${split("/", vm.ip)[0]} ansible_user=ubuntu
%{ endfor ~}

[linux_vms:children]
debian_vms
ubuntu_vms

[linux_vms:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
```

### Secret Values — `terraform/terraform.tfvars`

**Add this file to `.gitignore`.**

```hcl
proxmox_api_token_id     = "terraform@pve!terraform-token"
proxmox_api_token_secret = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ssh_public_key           = "ssh-ed25519 AAAA... you@host"
target_node              = "pve"
```

## Makefile

```makefile
.PHONY: template ubuntu-template pfsense-iso pfsense-iso-upload win10-iso win10-iso-upload win10-template win10-autounattend win10-template-auto init plan apply configure destroy all

# Step 1a: Create the Debian template on Proxmox
template:
	ansible-playbook -i ansible/inventory.ini ansible/create-template.yml

# Step 1b: Create the Ubuntu Server 24.04 template on Proxmox
ubuntu-template:
	ansible-playbook -i ansible/inventory.ini ansible/create-ubuntu-template.yml

# Step 1c: Download pfSense ISO to Proxmox (Option A — direct download)
pfsense-iso:
	ansible-playbook -i ansible/inventory.ini ansible/download-pfsense.yml

# Step 1c alt: Upload local pfSense ISO to Proxmox (Option B — local ISO in ./resources/)
pfsense-iso-upload:
	ansible-playbook -i ansible/inventory.ini ansible/upload-pfsense.yml

# Step 1d: Download VirtIO drivers and check for Windows ISO (Option A)
win10-iso:
	ansible-playbook -i ansible/inventory.ini ansible/setup-windows-iso.yml

# Step 1d alt: Upload local Windows ISO + download VirtIO (Option B — local ISO in ./resources/)
win10-iso-upload:
	ansible-playbook -i ansible/inventory.ini ansible/upload-windows-iso.yml

# Step 1e: Create Windows 10 template — interactive (run twice: first creates VM, second converts to template)
win10-template:
	ansible-playbook -i ansible/inventory.ini ansible/create-win10-template.yml

# Step 1e alt: Build Autounattend ISO + create Windows 10 template — fully unattended
win10-autounattend:
	ansible-playbook -i ansible/inventory.ini ansible/build-autounattend-iso.yml

win10-template-auto: win10-autounattend
	ansible-playbook -i ansible/inventory.ini ansible/create-win10-template-unattended.yml

# Step 2: Init Terraform
init:
	cd terraform && terraform init

# Step 3: Plan infrastructure
plan:
	cd terraform && terraform plan

# Step 4: Provision VMs (also generates ansible/inventory-vms.ini)
apply:
	cd terraform && terraform apply

# Step 5: Configure Linux VMs with Ansible
configure:
	ansible-playbook -i ansible/inventory-vms.ini ansible/configure-vms.yml

# Tear down VMs
destroy:
	cd terraform && terraform destroy

# Full pipeline (excluding Windows — requires interactive install steps)
all: template ubuntu-template pfsense-iso init apply configure
```

## Usage

### Full Pipeline

```bash
make all
```

### Step by Step

```bash
make template          # Ansible: create Debian template on Proxmox
make ubuntu-template   # Ansible: create Ubuntu Server 24.04 template on Proxmox
make pfsense-iso       # Ansible: download pfSense ISO to Proxmox (Option A)
make pfsense-iso-upload # Ansible: upload local ISO from ./resources/ (Option B)
make win10-iso         # Ansible: download VirtIO drivers, check for Windows ISO (Option A)
make win10-iso-upload  # Ansible: upload local ISO from ./resources/ + VirtIO (Option B)
make win10-template    # Ansible: create Windows installer VM (interactive)
                       # ... complete Windows install via Proxmox console ...
                       # ... run sysprep, let VM shut down ...
make win10-template    # Ansible: convert installed VM to template (run again)
                       # --- OR use unattended (no manual steps) ---
make win10-template-auto # Ansible: build answer ISO, install, sysprep, template — fully hands-off
make init              # Terraform: initialize providers
make plan              # Terraform: review what will be created
make apply             # Terraform: provision VMs, generate Ansible inventory
                       # NOTE: after apply, complete pfSense install via Proxmox console
make configure         # Ansible: configure the Linux VMs (Debian + Ubuntu)
```

### Tear Down

```bash
make destroy     # Terraform: destroy all VMs (template remains)
```

### Adding or Removing VMs

Edit the `vms` map in `terraform/terraform.tfvars` or `terraform/variables.tf`, then:

```bash
make apply && make configure
```

## Responsibility Split

| Concern | Tool | Files |
|---------|------|-------|
| Debian template | Ansible | `create-template.yml` |
| Ubuntu template | Ansible | `create-ubuntu-template.yml` |
| pfSense ISO | Ansible | `download-pfsense.yml` |
| Windows 10 ISOs (Option A) | Ansible + manual | `setup-windows-iso.yml` + scp |
| Windows 10 ISOs (Option B) | Ansible | `upload-windows-iso.yml` |
| Windows 10 template (interactive) | Ansible + manual | `create-win10-template.yml` + Proxmox console |
| Windows 10 template (unattended) | Ansible | `build-autounattend-iso.yml` + `create-win10-template-unattended.yml` |
| Debian VM provisioning | Terraform | `main.tf`, `variables.tf` |
| Ubuntu VM provisioning | Terraform | `ubuntu.tf` |
| pfSense VM provisioning | Terraform | `pfsense.tf` |
| Windows VM provisioning | Terraform | `windows.tf` |
| VM inventory bridge | Terraform | `outputs.tf`, `inventory.tftpl` |
| Linux VM configuration | Ansible | `configure-vms.yml` |
| pfSense configuration | Manual | Proxmox console + WebConfigurator |
| Windows configuration | Manual | RDP + Proxmox console |
| Orchestration | Make | `Makefile` |
