# Pi-hole Easy Encrypt

Automated HTTPS setup for your Pi-hole dashboard using Let's Encrypt and Cloudflare DNS validation.

This script runs a guided setup wizard and then keeps everything maintained automatically:
- certificate issuance
- renewal checks
- optional DNS sync
- optional gravity updates

Currently supported DNS provider:
✔ Cloudflare only

---

## Features

- One-command HTTPS setup
- Fully automated certificate lifecycle
- Works on bare metal and Docker installs
- Automatic DNS A/AAAA record sync (optional)
- Detects WAN IP automatically
- systemd timers for maintenance
- Safe cert backup before replacement
- Rollback if restart fails
- Interactive maintenance menu

---

## Requirements

- Pi-hole installed
- Domain managed in Cloudflare
- Cloudflare API token with permissions:
  - Zone → DNS → Edit
  - Zone → Zone → Read

Required binaries:

