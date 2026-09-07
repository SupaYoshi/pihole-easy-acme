# ACME state and renewal recovery (v2.1)

The executable and its account/certificate data need not live together.
Do not use the systemd service's implicit `HOME` to locate either. The wrapper
passes all three paths on each ACME invocation, including cron removal, and
uses the same certificate directory for validation and installation.

## Configuration

Add plain `key=value` entries to `/etc/pihole-easy-acme/config` (root-only,
mode 0600; values are literal paths, not shell expressions):

```text
acme_home=/root/.acme.sh
acme_config_home=/root/.acme.sh
acme_cert_home=/root/.acme.sh
```

- `acme_home`: program directory containing executable `acme.sh`.
- `acme_config_home`: account configuration directory; defaults to `acme_home`.
- `acme_cert_home`: certificate directory; defaults to `acme_config_home`.

Existing standard installations need no config changes. Paths must be absolute
non-root directories. Spaces are supported. Nonstandard program directories
must already contain an installed acme.sh; the bootstrap is only used for the
standard layout. ECC material is read from `<acme_cert_home>/<first-domain>_ecc/`.

## Existing split state

Some historical systemd runs wrote state into `/.acme.sh` while the wrapper
installed material from `/root/.acme.sh`. If `/.acme.sh` exists without explicit
state configuration, the new wrapper stops with an actionable warning before
calling ACME. It does not choose the newest certificate, merge account files,
move private keys, or create a replacement account automatically.

1. Preserve a root-only backup of the wrapper, configuration and both existing
   state trees. Never upload the state trees to a repository or support chat.
2. Locally identify the existing account directory and the intended domain's
   certificate directory. Inspect certificate dates and SANs without displaying
   account files, tokens or private keys. The executable location alone is not
   evidence of the correct state directory.
3. Set both state paths explicitly to the verified existing locations. For a
   **confirmed** split-state installation only, this could be:

   ```text
   acme_home=/root/.acme.sh
   acme_config_home=/.acme.sh
   acme_cert_home=/.acme.sh
   ```

   This is a recovery example, **not** a new default. If the root-level state is
   unrelated, explicitly pin both paths to the verified standard directory.
4. Deploy the wrapper and run the regular `--renew` check in your maintenance
   window. Do not force issuance to test migration. A normal check may request
   issuance if due; it is not a dry run. Verify service result, served TLS and
   DNS after any certificate installation.

No production deployment is performed by the repository test suite.

## Outcome handling

- ACME exit 0 (issued) or 2 (renewal skipped) is accepted only after checking
  readable/parseable cert and key, matching public keys, DNS SAN/hostname,
  not-before, and **more than 24 hours** of remaining validity. Every requested
  name is checked, including wildcard names.
- Other ACME exit codes remain failures, even when old valid material exists.
- Raw provider output is not echoed to the wrapper log. Failures report their
  exit code; provider diagnostics should be examined locally with secrets kept
  private.
- Identical fullchain-plus-key material is not rewritten and causes no backup
  or restart on either bare-metal or Docker installations. A changed chain is
  installed even if the leaf certificate is unchanged.
- The normal renewal-window fast path also validates the installed cert/key
  and hostname. A successfully skipped daily run counts for Zabbix's
  `last_success_age`; historical error events are not cleared or suppressed.
- The checks validate local material, not CA trust-chain/revocation or actual
  service reachability. Continue the independent served-TLS monitoring checks.

The path flags and skip semantics are defined by
[upstream acme.sh](https://github.com/acmesh-official/acme.sh/blob/master/acme.sh).

## Offline tests

```bash
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
bash -n pihole-easy-acme.sh
.venv/bin/python -m unittest discover -s tests -v
```

Tests generate disposable synthetic certificates, invoke the production Bash
functions with temporary paths, and stub ACME/systemctl/Docker. They cover
issued/skipped/error outcomes, invalid/missing/mismatched/expired/future
material, wildcard SANs, split state, exact no-op behavior, changed installs,
rollback, sequential recovery checks, and monitoring. No real certificates,
provider credentials, DNS changes, production services or network ACME calls
are involved. The same checks run in GitHub Actions.
