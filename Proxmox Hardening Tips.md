# Proxmox Hardening Tips



### SSH:

hackers will brute force your ssh with passwords

Best Practice:

Disable root access altogether, make normal user with sudo priveleges, switch from password to ssh key only



etc/ssh/sshd\_config file

permit root login no

password authentication no

un-comment public key authentication

make it yes

restart ssh with restart ssh command



### Built-in Proxmox Firewall:

command pve-firewall status

Datacenter/Firewall/Options



### Trusted SSL Certificates

Datacenter/ACME

certificate



Run reverse proxy like engine



### Let's Encrypt in Proxmox

In Datacenter, go to ACME, choose cloudfare, Cloudfare Managed DNS



then, go to pve host, in system, certificates, create domain. choose the domain that has the encrypt certificate





### Use 2FA Authentication

Turn UB keys on for you root ad pam account, and then create daily admin accounts with 2FA enabled



Reduces Risk, even if your stuff gets leaked



Datacenter, Permissions, Two Factor

Add a TOTP login factor.





### Keep Proxmox Server Updated

one of the most effective security



patch regularly

use nested virtualization for updates to test and make sure they wouldn't break your proxmox server



pve, updates, repositories; shows subscriptions







### Use Role Based Access Control

Datacenter, Permissions, Roles,

make use of built-in roles or create new roles



##### 

##### Secure Storage

##### Secure Backup 

### Protect Management Interfaces

put them on a dedicated Vlan





##### Disable Unused Hardware

##### use a UPS



## AI Summary
 1. SSH Security
  Disable root login and password authentication in /etc/ssh/sshd_config. Use SSH key-based auth only. Optionally change
   the default port and install fail2ban to block brute force attempts.

  2. Proxmox Firewall
  Enable the built-in firewall at both the datacenter and node levels. Default to deny-all, then whitelist only what you
   need (port 8006 for the web UI, Corosync, NFS/iSCSI, SSH). Warning: enabling it without rules first will lock you
  out.

  3. Trusted SSL Certificates
  The web UI ships with a self-signed cert. Replace it with a trusted one using Proxmox's built-in Let's Encrypt / ACME
  support. For air-gapped setups, use DNS challenge (e.g. Cloudflare). Alternatively, put a reverse proxy (Nginx,
  Traefik) in front.

  4. Two-Factor Authentication (2FA) (needs to be manual due to having to take picture on phone)
  Enable TOTP (Google Authenticator, Authy) or WebAuthn (YubiKey) for all admin accounts, especially root. Built
  directly into Proxmox under Datacenter > Permissions > Two Factor.

  5. Keep Proxmox Updated
  Regularly patch using either the enterprise repo (subscription) or no-subscription repo (home lab). Also update
  container templates, guest tools, and the kernel. Pro tip: test updates on a nested Proxmox VM first.

  6. Role-Based Access Control (RBAC)
  Stop using root for daily tasks. Use Proxmox's built-in roles (Administrator, Auditor, Datastore Admin, etc.) or
  create custom roles with only the privileges needed. Limits blast radius if an account is compromised.

  7. Secure Storage and Backups
  Lock down NFS/iSCSI so only Proxmox nodes can connect. On Proxmox Backup Server, enable client-side encryption and
  immutable backups to protect against ransomware and accidental deletion.

  8. Monitoring and Logging
  Forward syslog to a central server. Watch for repeated failed login attempts. Configure Proxmox email notifications
  for failed jobs or abnormal logins. Also disable unused hardware (e.g. onboard audio) and enable Secure Boot.

  9. Protect Management Interfaces
  Put IDRAC, IPMI, and iLO on a dedicated VLAN, isolated from VM/LXC traffic. Use strong, unique passwords for those
  interfaces. Use a UPS to prevent power disruptions from destabilizing the environment.