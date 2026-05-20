# PVE01

TASK [Show token (save this to vault)] *********************************************************************************

ok: [pve01] => {

"msg": "┌──────────────┬──────────────────────────────────────┐\n│ key          │ value                                │\n╞══════════════╪══════════════════════════════════════╡\n│ full-tokenid │ ansible@pam!ansible-token            │\n├──────────────┼──────────────────────────────────────┤\n│ info         │ {privsep:1}                        │\n├──────────────┼──────────────────────────────────────┤\n│ value        │ 99765641-41db-4ca0-87a5-e26618167cb4 │\n└──────────────┴──────────────────────────────────────┘"

## Security Practices Summary

- **SSH keys** over passwords -- no `ansible_password` anywhere in persistent config
- **Ansible Vault** for all secrets -- nothing plaintext in git
- **API tokens** over root credentials for Proxmox API calls
- **Vault indirection pattern** -- encrypted `vault.yml` + unencrypted reference vars
- `.vault_password`** excluded from git** -- store separately or use `--ask-vault-pass` in CI
- **Bootstrap uses **`vars_prompt` -- root password is interactive only, never written to disk
