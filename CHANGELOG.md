# Changelog

## Unreleased

- Add optional Zabbix Agent 2 monitoring helper for `pihole-easy-acme`.
- Add Zabbix UserParameter and sudoers examples for Proxmox-hosted Pi-hole
  containers.
- Document monitoring checks for timer state, service failure, certificate
  expiry, SAN mismatch, served-vs-installed fingerprint mismatch, journal
  errors, and last successful run age.
- Complete the README requirements/install section and link monitoring docs.

## v2.0 - 2026-07-29

- Make certificate renewal safe and idempotent.
- Use a single renewal scheduler: `pihole-easy-acme.timer`.
- Remove native `acme.sh` cron scheduling when the timer is configured and on
  each scheduled check.
- Skip writes and Pi-hole restarts when the served certificate remains valid
  beyond the renewal window.
- Validate certificate, key, and SAN before atomic installation.
- Restart Pi-hole FTL once after installation and roll back the previous
  certificate if restart fails.
- Retain only the five newest certificate backups.
- Keep `dns_sync` as a compatibility key, but limit it to read-only WAN IP
  reporting.

## v1.9

- Add initial guided setup and renewal automation.
