# Zabbix Monitoring

This repository includes optional Zabbix Agent 2 UserParameter monitoring for
`pihole-easy-acme`.

The helper is designed for Pi-hole containers hosted on Proxmox. It runs on the
Proxmox host and reads container state through `pct exec`. It performs read-only
checks and does not renew certificates, edit DNS, restart Pi-hole, or write
Pi-hole configuration.

## Files

- `monitoring/zabbix/openclaw-zbx-pihole-easy-acme`
- `monitoring/zabbix/pihole-easy-acme.conf`
- `monitoring/zabbix/zabbix-pihole-easy-acme.sudoers`

## Install On A Proxmox Host

```bash
sudo install -m 0755 monitoring/zabbix/openclaw-zbx-pihole-easy-acme \
  /usr/local/sbin/openclaw-zbx-pihole-easy-acme

sudo install -m 0644 monitoring/zabbix/pihole-easy-acme.conf \
  /etc/zabbix/zabbix_agent2.d/pihole-easy-acme.conf

sudo install -m 0440 monitoring/zabbix/zabbix-pihole-easy-acme.sudoers \
  /etc/sudoers.d/zabbix-pihole-easy-acme

sudo visudo -cf /etc/sudoers
sudo systemctl restart zabbix-agent2
```

Ensure the main Agent 2 config includes local UserParameter snippets:

```text
Include=/etc/zabbix/zabbix_agent2.d/*.conf
```

## Item Key Format

```text
pihole.easy_acme[<ctid>,<check>,<hostname>,<connect_host>,<cert_file>]
```

Example:

```text
pihole.easy_acme[110,served_days_left,pihole1.example.net,10.22.1.5,/etc/pihole/tls.pem]
```

## Checks

| Check | Meaning | Healthy |
| --- | --- | --- |
| `timer_active` | `pihole-easy-acme.timer` is active | `1` |
| `timer_enabled` | timer is enabled for boot | `1` |
| `service_failed` | `pihole-easy-acme.service` is failed | `0` |
| `served_days_left` | days until served TLS certificate expiry | `>=21` |
| `served_san_match` | served certificate SAN contains expected hostname | `1` |
| `served_installed_fingerprint_match` | served cert matches `/etc/pihole/tls.pem` | `1` |
| `journal_errors_24h` | ACME-related error lines in last 24h | `0` |
| `last_success_age` | seconds since last successful run marker | `<172800` |

## Suggested Triggers

- Timer inactive for 10 minutes: Average.
- Timer disabled: Average.
- Service failed for 10 minutes: High.
- Served TLS certificate expires within 21 days: High.
- Served certificate SAN mismatch: High.
- Served certificate does not match installed `/etc/pihole/tls.pem`: High.
- More than two ACME-related journal errors over two hours: Average.
- No successful run marker in 48 hours: Average.

## Notes

Monitor `/etc/pihole/tls.pem`, not `/etc/pihole/tls.crt`, for the installed
certificate comparison. `pihole-easy-acme` installs the served Let's Encrypt
certificate into `tls.pem`; `tls.crt` may be a local Pi-hole fallback
certificate.
