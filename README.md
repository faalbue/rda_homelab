# Homelab

## Domain

My Domain is [robaalbue.com](http://robaalbue.com)

which is registered through 1and1.com

## Git

This repository uses Git for version control of all homelab configuration, infrastructure code, and automation scripts.

## Proxmox

free open-source server virtualization management platform

[https://www.youtube.com/watch?v=uMZIHDztsUY](https://www.youtube.com/watch?v=uMZIHDztsUY)  hardening proxmox  
[https://www.youtube.com/watch?v=VAJWUZ3sTSI](https://www.youtube.com/watch?v=VAJWUZ3sTSI)  things after proxmox install

## Terraform

Terraform is used to provision and manage infrastructure as code. Configuration files define the desired state of infrastructure resources, allowing repeatable and auditable deployments.

## Ansible

Ansible is used for configuration management and automation. Playbooks handle provisioning, configuration, and maintenance tasks across homelab hosts.

[https://computingforgeeks.com/ansible-proxmox-tutorial/](https://computingforgeeks.com/ansible-proxmox-tutorial/)  
[https://computingforgeeks.com/terraform-ansible-tutorial/](https://computingforgeeks.com/terraform-ansible-tutorial/)  
[https://initez.nl/bootstrapping-your-homelab-with-proxmox-terraform-ansible/](https://initez.nl/bootstrapping-your-homelab-with-proxmox-terraform-ansible/)

## Recipe Buildout

ssh-keygen -t ed25519 -f ~/.ssh/ansible_proxmox -C "ansible@proxmox" (First time only)

### Copy to proxmox host

ssh-keygen -f "/root/.ssh/known_hosts" -R "10.0.0.175" (on re-install only) (clears key from known host file)

ssh-copy-id -i ~/.ssh/ansible_proxmox.pub [root@10.0.0.175](mailto:root@10.0.0.175)

## Bootstrap Playbook

## 00_Bootstrap

I ran the Bootstrap Playbook from the ansible.md directory.  
ansible-playbook playbooks/00_bootstrap.yml

```markdown

First Time (from the ansible directory):
   echo 'your-vault-password-here' > .vault_password
   chmod 600 .vault_password
   ansible-vault create inventory/group_vars/proxmox/vault.yml 

ansible-vault edit inventory/group_vars/proxmox/vault.yml (Second time and on)

## Force Creation
if you want to force the creation of your tokens
backup the vault.yml file located in the inventory/group_vars/proxmox
mv inventory/group_vars/proxmox inventory/group_vars/proxmox vault.yml.back

Validate that the ansible user is root
through inventory/hosts.yml
all:
  children:
    proxmox:
      hosts:
        pve01:
          ansible_host: 192.168.1.x
          ansible_user: root     <---------------
          ansible_python_interpreter: /usr/bin/python3
```

ansible-playbook playbooks/site.yml

## 01_Harden_proxmox.yml

ansible-playbook playbooks/01_harden_proxmox.yml

**After running**, update `inventory/hosts.yml` to use `administrator` instead of `root`  
and enable `become` so Ansible can still run privileged tasks:

```yaml
all:
  children:
    proxmox:
      hosts:
        pve01:
          ansible_host: 192.168.1.x
          ansible_user: administrator        # changed from root
          ansible_python_interpreter: /usr/bin/python3
```

And update `ansible.cfg` to enable become by default:

```ini
[privilege_escalation]
become = True
become_method = sudo
become_user = root

ssh -i ~/.ssh/ansible_proxmox administrator@10.0.0.175


If that works, add a host entry to ~/.ssh/config so you don't have to specify it every time:
Host pve01
      HostName 10.0.0.175
      User administrator
      IdentityFile ~/.ssh/ansible_proxmox

Test:
ssh pve-hagrid

Test:
ansible-playbook playbooks/site.yml
```

## IONOS API key

(? .back) ls -la  
ansible-vault edit inventory/group_vars/proxmox/vault.yml  
add the following at the bottom:  
vault_acme_dns_credentials: "IONOS_PREFIX=\nIONOS_SECRET=="

## 02_update_proxmox

To run the update_proxmox.yml  
do ansible-playbook playbooks/02_update_proxmox.yml

the code will produce these results: adds a ssl certificate, uploads the pfsense iso and windows iso to proxmox
