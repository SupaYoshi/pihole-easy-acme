"""Offline regressions: real OpenSSL validation; fake ACME and service commands.

Only selected production functions are loaded: no top-level logging, root
requirements, bootstrap, network calls, or production paths are executed.
"""
import datetime as dt
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'pihole-easy-acme.sh').read_text()


def function(name, source=SOURCE):
    return re.search(r'^' + name + r'\(\) \{.*?^\}', source, re.M | re.S)[0]


class RenewalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / 'program home'
        self.state = self.base / 'account state'
        self.certs = self.base / 'cert state'
        self.legacy = self.base / 'legacy'
        self.target = self.base / 'pihole'
        for p in (self.home, self.state, self.certs, self.target):
            p.mkdir()
        self.config = self.base / 'config'
        self.config.write_text(f'acme_home={self.home}\nacme_config_home={self.state}\nacme_cert_home={self.certs}\n')
        self.domain = self.certs / 'example.test_ecc'
        self.domain.mkdir()
        self.cert = self.domain / 'fullchain.cer'
        self.key = self.domain / 'example.test.key'
        self.pem = self.target / 'tls.pem'
        self.calls = self.base / 'calls'
        self.args = self.base / 'args'
        mock = self.home / 'acme.sh'
        mock.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARGS"\necho MOCK_PRIVATE_PROVIDER_OUTPUT\nexit "${ACME_RC:-0}"\n')
        mock.chmod(0o700)
        self.fixture()

    def fixture(self, names=('example.test',), days=90, start=-1, san=True):
        key = ec.generate_private_key(ec.SECP256R1())
        now = dt.datetime.now(dt.timezone.utc)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'example.test')])
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now + dt.timedelta(days=start))
                .not_valid_after(now + dt.timedelta(days=days)))
        if san:
            cert = cert.add_extension(x509.SubjectAlternativeName([x509.DNSName(n) for n in names]), critical=False)
        self.cert.write_bytes(cert.sign(key, hashes.SHA256()).public_bytes(serialization.Encoding.PEM))
        self.key.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))

    def run_shell(self, command, rc=0, extra=''):
        names = ('cfg_get', 'resolve_acme_paths', 'acme_command', 'validate_cert_material',
                 'do_issue', 'cert_material_unchanged', 'install_cert_bare',
                 'install_cert_docker', 'prune_cert_backups', 'cert_expires_within',
                 'cert_expiry', 'do_certificate', 'disable_acme_cron')
        code = '\n'.join(function(n) for n in names)
        # Remap fixed production locations in the loaded test functions only.
        code = code.replace('/etc/pihole', str(self.target)).replace('/.acme.sh', str(self.legacy))
        prelude = '''set -Eeuo pipefail
warn(){ echo "$*"; }; ok(){ echo "$*"; }; info(){ echo "$*"; }
die(){ echo "$*"; exit 1; }
systemctl(){ echo "systemctl $*" >> "$CALLS"; [[ "${FAIL_RESTART:-0}" != 1 ]]; }
docker(){ echo "docker $*" >> "$CALLS"; [[ "${FAIL_RESTART:-0}" != 1 ]]; }
pihole-FTL(){ echo "FTL $*" >> "$CALLS"; }
chown(){ :; }
read_token(){ :; }; report_wan_ip(){ :; }
install_acme(){ echo INSTALL_ACME >> "$CALLS"; }
'''
        env = dict(os.environ, CONF_FILE=str(self.config), CF_TOKEN='', ARGS=str(self.args),
                   CALLS=str(self.calls), ACME_RC=str(rc), MAX_CERT_BACKUPS='5',
                   DEFAULT_RENEW_DAYS='30', CA_PROD='letsencrypt', CA_STAGING='letsencrypt_test')
        result = subprocess.run(['bash'], input=prelude + code + '\n' + extra + '\n' + command,
                                text=True, capture_output=True, env=env)
        self.assertNotIn('MOCK_PRIVATE_PROVIDER_OUTPUT', result.stdout + result.stderr)
        return result

    def issue(self, rc=0, expected=True):
        result = self.run_shell('do_issue false letsencrypt example.test', rc)
        self.assertEqual(result.returncode == 0, expected, result.stdout + result.stderr)
        return result

    def test_issue_and_skip_explicit_paths(self):
        for rc in (0, 2):
            with self.subTest(rc=rc):
                self.issue(rc)
                args = self.args.read_text().splitlines()
                for flag, path in (('--home', self.home), ('--config-home', self.state), ('--cert-home', self.certs)):
                    self.assertEqual(args[args.index(flag) + 1], str(path))
                self.assertNotIn('--force', args)

    def test_real_errors_not_masked(self):
        for rc in (1, 3, 127):
            with self.subTest(rc=rc):
                self.assertEqual(self.issue(rc, False).returncode, rc)

    def test_bad_material_rejected_for_success_and_skip(self):
        for rc in (0, 2):
            for bad in ('missing_cert', 'missing_key', 'bad_cert', 'bad_key', 'wrong_key',
                        'wrong_san', 'no_san', 'expired', 'near_expiry', 'future'):
                with self.subTest(rc=rc, bad=bad):
                    self.fixture()
                    if bad == 'missing_cert': self.cert.unlink()
                    elif bad == 'missing_key': self.key.unlink()
                    elif bad == 'bad_cert': self.cert.write_text('invalid')
                    elif bad == 'bad_key': self.key.write_text('invalid')
                    elif bad == 'wrong_key':
                        old = self.cert.read_bytes(); self.fixture(); self.cert.write_bytes(old)
                    elif bad == 'wrong_san': self.fixture(names=('other.test',))
                    elif bad == 'no_san': self.fixture(san=False)
                    elif bad == 'expired': self.fixture(days=-1, start=-90)
                    elif bad == 'near_expiry': self.fixture(days=1)
                    elif bad == 'future': self.fixture(start=1)
                    self.issue(rc, False)

    def test_wildcard_names(self):
        self.fixture(names=('example.test', '*.example.test'))
        result = self.run_shell("do_issue false letsencrypt example.test '*.example.test'")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.fixture()
        result = self.run_shell("do_issue false letsencrypt example.test '*.example.test'")
        self.assertNotEqual(result.returncode, 0)

    def test_identical_install_no_restart_bare_and_docker(self):
        self.pem.write_bytes(self.cert.read_bytes() + self.key.read_bytes())
        before = self.pem.stat().st_mtime_ns
        for command in ('install_cert_bare example.test example.test',
                        f'install_cert_docker fake example.test example.test {shlex.quote(str(self.target))}'):
            result = self.run_shell(command)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(self.calls.exists())
            self.assertEqual(self.pem.stat().st_mtime_ns, before)
            self.assertEqual(list(self.target.glob('*.bak.*')), [])

    def test_changed_install_and_rollback(self):
        for docker in (False, True):
            for fail in (False, True):
                with self.subTest(docker=docker, fail=fail):
                    self.pem.write_text('old certificate')
                    self.calls.write_text('')
                    command = (f'install_cert_docker fake example.test example.test {shlex.quote(str(self.target))}'
                               if docker else 'install_cert_bare example.test example.test')
                    result = self.run_shell(command, extra=f'FAIL_RESTART={int(fail)}')
                    self.assertEqual(result.returncode == 0, not fail, result.stdout + result.stderr)
                    self.assertEqual(self.pem.read_bytes(), b'old certificate' if fail else self.cert.read_bytes() + self.key.read_bytes())
                    self.assertEqual(self.calls.read_text().count('restart '), 2 if fail else 1)

    def test_healthy_scheduled_check_does_not_issue_or_restart(self):
        self.pem.write_bytes(self.cert.read_bytes() + self.key.read_bytes())
        with self.config.open('a') as f:
            f.write('domain=example.test\nprimary=example.test\nzone_id=test\n')
        result = self.run_shell('do_certificate false')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('No renewal or Pi-hole restart required.', result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertNotIn('--issue', self.args.read_text())

    def test_legacy_state_requires_explicit_configuration(self):
        self.legacy.mkdir()
        self.config.write_text(f'acme_home={self.home}\n')
        self.issue(0, False)
        self.assertFalse(self.args.exists())
        with self.config.open('a') as f:
            f.write(f'acme_config_home={self.state}\nacme_cert_home={self.certs}\n')
        self.issue(2)

    def test_legacy_default_and_invalid_relative_path(self):
        self.config.write_text(f'acme_home={self.home}\n')
        result = self.run_shell('resolve_acme_paths; printf "%s\\n" "$ACME_HOME" "$ACME_CONFIG_HOME" "$ACME_CERT_HOME"')
        self.assertEqual(result.stdout.splitlines(), [str(self.home)] * 3)
        self.config.write_text('acme_home=relative\n')
        self.issue(0, False)

    def test_skip_installs_new_material_then_next_check_is_noop(self):
        self.fixture(days=20)
        self.pem.write_bytes(self.cert.read_bytes() + self.key.read_bytes())
        self.fixture(days=90)
        with self.config.open('a') as f:
            f.write('domain=example.test\nprimary=example.test\nzone_id=test\n')
        result = self.run_shell('do_certificate false', rc=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.pem.read_bytes(), self.cert.read_bytes() + self.key.read_bytes())
        self.assertEqual(self.calls.read_text().count('restart '), 1)
        before = self.calls.read_text()
        result = self.run_shell('do_certificate false', rc=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls.read_text(), before)

    def test_invalid_skip_cannot_reach_installer_in_guarded_context(self):
        self.key.write_text('invalid')
        result = self.run_shell('do_issue false letsencrypt example.test || exit 42; echo INSTALL_REACHED', rc=2)
        self.assertEqual(result.returncode, 42)
        self.assertNotIn('INSTALL_REACHED', result.stdout)

    def test_monitor_accepts_noop_success(self):
        helper = (ROOT / 'monitoring/zabbix/openclaw-zbx-pihole-easy-acme').read_text()
        code = 'set -Eeuo pipefail\npct_exec(){ echo "2026-09-07T10:00:00+0000 host No renewal or Pi-hole restart required."; }\n'
        result = subprocess.run(['bash'], input=code + function('last_success_age', helper) + '\nlast_success_age',
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(result.stdout.strip(), '-1')
        int(result.stdout)


if __name__ == '__main__':
    unittest.main()
