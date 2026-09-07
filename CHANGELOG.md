# Changelog

## v2.1 - 2026-09-07

- Separate ACME program, account configuration and certificate directories with
  explicit `acme_home`, `acme_config_home` and `acme_cert_home` configuration.
- Fail safely on ambiguous legacy root-level state; document in-place recovery
  without moving account files, keys or credentials.
- Accept ACME renewal-skip exit 2 only with validated existing material; preserve
  genuine errors and suppress raw provider output in wrapper logs.
- Require valid dates, more than 24 hours remaining, DNS SAN coverage and
  matching certificate/key material for issuance and installation.
- Require an explicit positive OpenSSL hostname result; older versions return
  exit 0 even when the hostname does not match.
- Avoid writes, backups and restarts for identical installed material on both
  bare-metal and Docker paths; validate the renewal-window fast path too.
- Count successful no-renewal checks in Zabbix last-success monitoring.
- Add offline certificate/recovery/rollback regressions and GitHub Actions CI.


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
