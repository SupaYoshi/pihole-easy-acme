# Pi-hole Easy ACME

Automated HTTPS setup for your Pi-hole dashboard using Let's Encrypt and Cloudflare DNS validation.

This script runs a guided setup wizard and then keeps everything maintained automatically:
- certificate issuance
- renewal checks
- optional WAN IP reporting (read-only; no DNS record changes)
- optional gravity updates

Currently supported DNS provider:
✔ Cloudflare only

---

## Features

- One-command HTTPS setup
- Fully automated certificate lifecycle
- Works on bare metal and Docker installs
- Read-only WAN IPv4/IPv6 reporting (optional)
- Explicitly supports internal-only split DNS
- systemd timers for maintenance
- Safe cert backup before replacement
- Rollback if restart fails
- Atomic certificate installation with certificate/key/SAN validation
- Retains only the five newest certificate backups
- Interactive maintenance menu

## Renewal safety

Version 2.0 uses one renewal scheduler: `pihole-easy-acme.timer`. The native
`acme.sh` cron entry is removed when the timer is configured and on each
scheduled check.

A daily check exits without writing files or restarting Pi-hole when the
certificate remains valid beyond the configured renewal window. When renewal
is required, the new certificate, private key and hostname are validated
before an atomic install. Pi-hole FTL is restarted once and the current
certificate is restored if the restart fails.

The `dns_sync` configuration key is retained for compatibility with v1.9, but
it only enables a read-only WAN IP report. It does not create or modify
Cloudflare A/AAAA records.

---

## Requirements

- Pi-hole installed
- Domain managed in Cloudflare
- Cloudflare API token with permissions:
  - Zone → DNS → Edit
  - Zone → Zone → Read

Required binaries:
- `bash`
- `curl`
- `openssl`
- `systemctl`
- `python3`
- `acme.sh`
- `pihole` / Pi-hole FTL tooling

---

## Install

```bash
sudo install -m 0755 pihole-easy-acme.sh /usr/local/sbin/pihole-easy-acme
sudo pihole-easy-acme
```

The setup wizard writes its configuration under `/etc/pihole-easy-acme/` and
creates `pihole-easy-acme.service` plus `pihole-easy-acme.timer`.

---

## Zabbix Monitoring

Optional Zabbix Agent 2 UserParameter monitoring is included under
`monitoring/zabbix/`.

It can monitor:
- `pihole-easy-acme.timer` active/enabled state.
- `pihole-easy-acme.service` failed state.
- served TLS certificate days remaining.
- served certificate SAN match for the expected hostname.
- served-vs-installed `/etc/pihole/tls.pem` SHA256 fingerprint match.
- repeated ACME-related journal errors.
- age of the last successful renewal/check.

See `docs/zabbix-monitoring.md` for deployment details and example item keys.

---

## Changelog

See `CHANGELOG.md`.
