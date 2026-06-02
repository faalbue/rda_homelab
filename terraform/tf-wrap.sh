#!/usr/bin/env bash
# tf-wrap.sh
export ANSIBLE_VAULT_PASSWORD_FILE=~/Summer26/Homelab/Homelab/ansible/.vault_password
eval "$(ansible-vault view ../ansible/inventory/group_vars/proxmox/vault.yml | yq -r 'to_entries | .[] | "export TF_VAR_" + .key + "=" + (.value | @sh)')"

export TF_VAR_proxmox_api_url="${TF_VAR_proxmox_api_url:-https://10.0.0.175:8006}"
export TF_VAR_target_node="${TF_VAR_target_node:-pve}"

terraform "$@"
