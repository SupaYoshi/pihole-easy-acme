#!/usr/bin/env bash
# ==============================================================================
#  pihole-easy-acme  v2.1
#  Automated TLS certificate management for Pi-hole via ACME DNS-01 challenge
#
#  Copyright (c) 2026 Walter Verkerk (SupaYoshi)
#  Repository : https://github.com/SupaYoshi/pihole-easy-acme
#  License    : MIT
# ==============================================================================
set -Eeuo pipefail

# ============================================================
#  pihole-easy-acme v2.1
#  Simple setup wizard: answer 10 questions, everything works.
# ============================================================

APP="pihole-easy-acme"
VERSION="2.1"
CONF_DIR="/etc/${APP}"
CONF_FILE="${CONF_DIR}/config"
TOKEN_FILE="${CONF_DIR}/cloudflare.token"
ENV_FILE="${CONF_DIR}/.env"
LOG="/var/log/${APP}.log"
GRAVITY_LOG="/var/log/pihole-gravity.log"
LOCK_FILE="/run/${APP}.lock"
DEFAULT_RENEW_DAYS=30
MAX_CERT_BACKUPS=5
CA_PROD="letsencrypt"
CA_STAGING="letsencrypt_test"

# -------- colors --------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; NC=""
fi

# -------- logging --------
mkdir -p "$(dirname "$LOG")"
touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

die()  { echo; echo "${RED}✗ ERROR:${NC} $*"; echo; exit 1; }
warn() { echo "${RED}WARNING: $*${NC}"; }
ok()   { echo "${GREEN}$*${NC}"; }
info() { echo "${CYAN}$*${NC}"; }
step() { echo; echo "${BOLD}${CYAN}[Step $1]${NC} ${BOLD}$2${NC}"; echo "${DIM}────────────────────────────────────────${NC}"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required program missing: $1"; }
as_root()  { [[ $EUID -eq 0 ]] || die "Run this script as root:  sudo $APP"; }

lock() {
  need_cmd flock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "An instance of ${APP} is already running."
}

ensure_dirs() {
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  [[ -f "$CONF_FILE" ]] || touch "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

cfg_set() { local k="$1" v="$2"
  ensure_dirs
  grep -v "^${k}=" "$CONF_FILE" > "${CONF_FILE}.tmp" 2>/dev/null || true
  echo "${k}=${v}" >> "${CONF_FILE}.tmp"
  mv "${CONF_FILE}.tmp" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

cfg_get() { local k="$1" def="${2:-}"
  [[ -f "$CONF_FILE" ]] || { echo "$def"; return; }
  local val; val="$(grep "^${k}=" "$CONF_FILE" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
  echo "${val:-$def}"
}

ask() {
  local prompt="$1" default="${2:-}" var="${3:-_ASK_RESULT}"
  local val=""
  if [[ -n "$prompt" ]]; then
    if [[ -n "$default" ]]; then
      printf "  %s [%s]: " "$prompt" "$default" >/dev/tty
    else
      printf "  %s: " "$prompt" >/dev/tty
    fi
  fi
  IFS= read -r val </dev/tty || true
  val="${val:-$default}"
  printf -v "$var" '%s' "$val"
}

ask_secret() {
  local prompt="$1" var="${2:-_ASK_RESULT}"
  local val=""
  printf "  %s: " "$prompt" >/dev/tty
  IFS= read -rs val </dev/tty || true
  echo >/dev/tty
  printf -v "$var" '%s' "$val"
}

ask_yesno() {
  local prompt="$1" default="${2:-y}" var="${3:-_YN_RESULT}"
  local val=""
  printf "  %s [%s/%s]: " "$prompt" \
    "$([[ $default == y ]] && echo 'Y' || echo 'y')" \
    "$([[ $default == n ]] && echo 'N' || echo 'n')" >/dev/tty
  IFS= read -r val </dev/tty || true
  val="${val:-$default}"
  val="${val,,}"
  if [[ "$val" =~ ^(y|yes)$ ]]; then
    printf -v "$var" 'true'
  else
    printf -v "$var" 'false'
  fi
}

pause() { printf "\n  Press Enter to continue..." >/dev/tty; IFS= read -r _ </dev/tty || true; }

header() {
  clear 2>/dev/null || true
  echo
  echo "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo "${CYAN}${BOLD}║          Pi-hole Easy ACME  v${VERSION}               ║${NC}"
  echo "${CYAN}${BOLD}║       Automatic HTTPS for your Pi-hole dashboard     ║${NC}"
  echo "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo
}

# ============================================================
#  Cloudflare helpers
# ============================================================

read_token() {
  [[ -f "$TOKEN_FILE" ]] || die "No token found. Run setup again."
  CF_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
  [[ -n "${CF_TOKEN:-}" ]] || die "Token file is empty."
}

cf_api()     { curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4${1}" 2>&1; }
cf_api_post(){ curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
    -X POST --data "$2" "https://api.cloudflare.com/client/v4${1}" 2>&1; }
cf_api_put() { curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
    -X PUT --data "$2" "https://api.cloudflare.com/client/v4${1}" 2>&1; }
cf_api_del() { curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -X DELETE "https://api.cloudflare.com/client/v4${1}" 2>&1; }

cf_api_with_retry() {
  local endpoint="$1" max_attempts="${2:-3}" attempt=1
  while (( attempt <= max_attempts )); do
    local out
    out="$(cf_api "$endpoint" 2>&1)"
    local status=$?

    if (( status == 0 )); then
      echo "$out"
      return 0
    fi

    if (( attempt < max_attempts )); then
      local wait_time=$((2 ** (attempt - 1)))
      warn "Cloudflare API request failed. Retrying in ${wait_time}s... (attempt $attempt/$max_attempts)"
      sleep "$wait_time"
    fi
    (( attempt++ ))
  done

  die "Failed to reach Cloudflare API after $max_attempts attempts."
}

cf_verify_token() {
  local out
  out="$(cf_api "/user/tokens/verify" 2>&1)" || {
    warn "Failed to verify token: API call failed"
    return 1
  }

  # Check API success and token status (JSON validation included)
  local result
  result="$(python3 - <<'PY' "$out"
import json, sys
try:
    j = json.loads(sys.argv[1])
    success = bool(j.get("success"))
    status = ((j.get("result") or {}).get("status") or "").lower()
    errors = j.get("errors") or []

    if not success:
        if errors:
            msg = errors[0].get("message", "Unknown error")
        else:
            msg = "API returned success=false"
        print(f"fail:{msg}")
        sys.exit(1)

    if status != "active":
        print(f"fail:Token status is '{status}', expected 'active'")
        sys.exit(1)

    print("ok")
    sys.exit(0)
except Exception as e:
    print(f"fail:Error parsing response: {str(e)}")
    sys.exit(1)
PY
)"

  if [[ "$result" == "ok" ]]; then
    return 0
  else
    warn "Token validation failed: ${result#fail:}"
    return 1
  fi
}

cf_get_zones() {
  local out
  out="$(cf_api "/zones?status=active&per_page=50&page=1" 2>&1)"
  [[ -z "$out" ]] && { echo ""; return 1; }

  # Pass JSON as argv[1] — safe, no string injection in Python source
  local all
  all="$(python3 - "$out" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
    if data.get("success"):
        result = data.get("result", [])
        print(json.dumps(result if isinstance(result, list) else []))
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
PY
  )" || { echo ""; return 1; }

  echo "$all"
}

cf_find_zone() {
  python3 - "$1" "$2" <<'PY'
import json, sys
domain = sys.argv[1].lower().rstrip(".")
zones  = json.loads(sys.argv[2])
best   = None
for z in zones:
    name = (z.get("name") or "").lower().rstrip(".")
    if not name: continue
    if domain == name or domain.endswith("." + name):
        if best is None or len(name) > len(best[1]):
            best = (z["id"], name)
if best:
    print(best[0] + "\t" + best[1])
PY
}

cf_dns_get_id() {
  local out; out="$(cf_api "/zones/${1}/dns_records?type=${2}&name=${3}" || true)"
  python3 - "$out" <<'PY'
import json, sys
res = (json.loads(sys.argv[1] or "{}").get("result") or [])
print(res[0].get("id", "") if res else "")
PY
}

cf_dns_upsert() {
  local zone_id="$1" type="$2" name="$3" content="$4" proxied="${5:-false}" ttl="${6:-120}"
  local payload; payload="$(python3 - "$type" "$name" "$content" "$ttl" "$proxied" <<'PY'
import json, sys
print(json.dumps({"type":sys.argv[1],"name":sys.argv[2],"content":sys.argv[3],
    "ttl":int(sys.argv[4]),"proxied":sys.argv[5]=="true"}))
PY
)"
  local id; id="$(cf_dns_get_id "$zone_id" "$type" "$name")"
  if [[ -n "$id" ]]; then
    cf_api_put "/zones/${zone_id}/dns_records/${id}" "$payload" >/dev/null
    ok "Cloudflare ${type} updated: ${name} -> ${content}"
  else
    cf_api_post "/zones/${zone_id}/dns_records" "$payload" >/dev/null
    ok "Cloudflare ${type} created: ${name} -> ${content}"
  fi
}

cf_dns_delete() {
  local zone_id="$1" type="$2" name="$3"
  local id; id="$(cf_dns_get_id "$zone_id" "$type" "$name")"
  [[ -n "$id" ]] || return 0
  cf_api_del "/zones/${zone_id}/dns_records/${id}" >/dev/null
  info "Cloudflare ${type} deleted: ${name}"
}

# ============================================================
#  WAN IP detection
# ============================================================

get_wan_ipv4() {
  local ip=""
  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.co/ip"; do
    ip="$(curl -fsSL --max-time 6 --ipv4 "$url" 2>/dev/null | tr -d '\r\n' || true)"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  done
  return 1
}

get_wan_ipv6() {
  local ip=""
  for url in "https://api64.ipify.org" "https://ipv6.icanhazip.com"; do
    ip="$(curl -fsSL --max-time 6 --ipv6 "$url" 2>/dev/null | tr -d '\r\n' || true)"
    [[ "$ip" =~ : ]] && [[ ! "$ip" =~ ^(fc|fd|fe80|::1) ]] && { echo "$ip"; return 0; }
  done
  return 1
}

get_local_ipv6() {
  # Get first global unicast IPv6 address (not link-local, not loopback)
  ip -6 addr show 2>/dev/null | grep -oP '(?<=inet6\s)([a-f0-9:]+)(?=/(?!128\s))' | grep -v '^fe80' | head -1
}


# ============================================================
#  Service + sync constants
# ============================================================

PIHOLE_USER="pihole"
PIHOLE_SSH_DIR=""
PIHOLE_SYNC_KEY=""

resolve_sync_key() {
  local home; home="$(getent passwd "$PIHOLE_USER" | cut -d: -f6 2>/dev/null)"
  [[ -z "$home" || "$home" == "/" || "$home" == "/nonexistent" ]] && home="/var/lib/pihole"
  PIHOLE_SSH_DIR="${home}/.ssh"
  PIHOLE_SYNC_KEY="${PIHOLE_SSH_DIR}/id_ed25519_sync"
}

cleanup_old_timers() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local old_app="pihole-easy-encrypt"
  for timer in "${old_app}.timer" "${old_app}-renew.timer"; do
    if systemctl is-active --quiet "$timer" 2>/dev/null || systemctl is-enabled --quiet "$timer" 2>/dev/null; then
      systemctl disable --now "$timer" 2>/dev/null || true
      info "Stopped legacy timer: ${timer}"
    fi
  done
  rm -f /etc/systemd/system/${old_app}* 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
}

# ============================================================
#  Peer SSH helpers
# ============================================================

setup_pihole_ssh_home() {
  local home; home="$(getent passwd "$PIHOLE_USER" | cut -d: -f6 2>/dev/null)"
  if [[ -z "$home" || "$home" == "/" || "$home" == "/nonexistent" ]]; then
    usermod -d /var/lib/pihole "$PIHOLE_USER" 2>/dev/null || true
    home="/var/lib/pihole"
  fi
  mkdir -p "${home}/.ssh"
  chown "${PIHOLE_USER}:${PIHOLE_USER}" "${home}" "${home}/.ssh" 2>/dev/null || true
  chmod 700 "${home}/.ssh"
  PIHOLE_SSH_DIR="${home}/.ssh"
  PIHOLE_SYNC_KEY="${PIHOLE_SSH_DIR}/id_ed25519_sync"
  ok "SSH home for '${PIHOLE_USER}': ${home}/.ssh"
}

_peer_remote_setup_script() {
  cat << 'END_REMOTE'
PHOME="$(getent passwd pihole | cut -d: -f6 2>/dev/null || echo /var/lib/pihole)"
case "$PHOME" in "/"|""|"/nonexistent") usermod -d /var/lib/pihole pihole 2>/dev/null || true; PHOME="/var/lib/pihole" ;; esac
mkdir -p "${PHOME}/.ssh"
chown pihole:pihole "${PHOME}" "${PHOME}/.ssh" 2>/dev/null || true
chmod 700 "${PHOME}/.ssh"
touch "${PHOME}/.ssh/authorized_keys"
chmod 600 "${PHOME}/.ssh/authorized_keys"
chown pihole:pihole "${PHOME}/.ssh/authorized_keys"
CURRENT_SHELL="$(getent passwd pihole | cut -d: -f7 2>/dev/null)"
case "$CURRENT_SHELL" in */nologin|*/false) usermod -s /bin/bash pihole 2>/dev/null && echo "SHELL_FIXED" ;; esac
SSHD_CONF=/etc/ssh/sshd_config
if ! grep -q "^Match User pihole" "$SSHD_CONF" 2>/dev/null; then
  printf '\nMatch User pihole\n    AuthorizedKeysFile %s/.ssh/authorized_keys\n    PasswordAuthentication no\n    AllowTcpForwarding no\n    X11Forwarding no\n' "$PHOME" >> "$SSHD_CONF"
  sshd -t >/dev/null 2>&1 && systemctl reload ssh 2>/dev/null && echo "SSHD_UPDATED"
else
  echo "SSHD_ALREADY_OK"
fi
touch /etc/pihole/custom.list 2>/dev/null || true
chmod 640 /etc/pihole/custom.list
chown root:pihole /etc/pihole/custom.list
echo "PEER_SETUP_OK:${PHOME}"
END_REMOTE
}

_verify_peer_permissions() {
  local peer_host="$1"
  local SSH_BATCH="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
  resolve_sync_key
  ssh -i "$PIHOLE_SYNC_KEY" $SSH_BATCH "${PIHOLE_USER}@${peer_host}" \
    "test -r /etc/pihole/custom.list && echo OK || echo NOPERM" 2>/dev/null \
    | grep -q "^OK$" \
    && ok "Peer custom.list readable ✓" \
    || warn "Run on peer: chown root:pihole /etc/pihole/custom.list && chmod 640 /etc/pihole/custom.list"
}

setup_sync_user_on_peer() {
  local peer_host="$1"
  local SSH_BATCH="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
  local SSH_PASS="-o StrictHostKeyChecking=no  -o ConnectTimeout=15 -o BatchMode=no"

  echo; echo "${BOLD}${CYAN}  Setting up sync on peer: ${peer_host}${NC}"
  echo "${DIM}────────────────────────────────────────${NC}"

  resolve_sync_key; setup_pihole_ssh_home

  if [[ ! -f "$PIHOLE_SYNC_KEY" ]]; then
    info "Generating sync SSH key..."
    ssh-keygen -t ed25519 -f "$PIHOLE_SYNC_KEY" -N "" \
      -C "${PIHOLE_USER}@$(hostname -s 2>/dev/null || echo local)-sync" >/dev/null 2>&1
    chown "${PIHOLE_USER}:${PIHOLE_USER}" "${PIHOLE_SYNC_KEY}" "${PIHOLE_SYNC_KEY}.pub" 2>/dev/null || true
    chmod 600 "$PIHOLE_SYNC_KEY"; chmod 644 "${PIHOLE_SYNC_KEY}.pub"
    ok "Sync key generated: ${PIHOLE_SYNC_KEY}"
  else
    info "Sync key already exists: ${PIHOLE_SYNC_KEY}"
  fi

  local pubkey; pubkey="$(cat "${PIHOLE_SYNC_KEY}.pub" 2>/dev/null)"
  [[ -z "$pubkey" ]] && { warn "Could not read public key."; return 1; }

  info "Testing existing key-based access to ${PIHOLE_USER}@${peer_host}..."
  if ssh -i "$PIHOLE_SYNC_KEY" $SSH_BATCH "${PIHOLE_USER}@${peer_host}" "echo ok" >/dev/null 2>&1; then
    ok "Sync SSH already works: ${PIHOLE_USER}@${peer_host} ✓"
    _verify_peer_permissions "$peer_host"; return 0
  fi

  echo; echo "  Enter ${BOLD}root@${peer_host}${NC} password when prompted (one time only):"; echo

  local attempts=0
  while (( attempts < 3 )); do
    (( attempts++ )) || true
    info "Attempt ${attempts}/3..."

    local setup_out
    setup_out="$(_peer_remote_setup_script | ssh $SSH_PASS "root@${peer_host}" 'bash -s' 2>&1)" || {
      warn "Remote setup failed (attempt ${attempts}/3)."; continue
    }
    [[ "$setup_out" != *"PEER_SETUP_OK"* ]] && { warn "Unexpected output: ${setup_out}"; continue; }

    while IFS= read -r ln; do
      case "$ln" in
        SHELL_FIXED)     ok "Shell set to /bin/bash on peer." ;;
        SSHD_UPDATED)    ok "sshd Match User block added and reloaded." ;;
        SSHD_ALREADY_OK) info "sshd Match User block already present." ;;
      esac
    done <<< "$setup_out"

    local phome_peer; phome_peer="$(echo "$setup_out" | grep PEER_SETUP_OK | cut -d: -f2)"
    [[ -z "$phome_peer" ]] && phome_peer="/var/lib/pihole"

    local key_result
    key_result="$(echo "$pubkey" | ssh $SSH_PASS "root@${peer_host}" "
      cat >> '${phome_peer}/.ssh/authorized_keys' &&
      sort -u '${phome_peer}/.ssh/authorized_keys' -o '${phome_peer}/.ssh/authorized_keys' &&
      chown pihole:pihole '${phome_peer}/.ssh/authorized_keys' &&
      chmod 600 '${phome_peer}/.ssh/authorized_keys' &&
      echo KEY_INSTALLED
    " 2>&1)" || { warn "Key install failed."; continue; }
    [[ "$key_result" != *"KEY_INSTALLED"* ]] && { warn "Unexpected key output."; continue; }
    ok "SSH key installed on peer."

    sleep 1
    if ssh -i "$PIHOLE_SYNC_KEY" $SSH_BATCH "${PIHOLE_USER}@${peer_host}" "echo ok" >/dev/null 2>&1; then
      ok "Passwordless sync confirmed: ${PIHOLE_USER}@${peer_host} ✓"
      _verify_peer_permissions "$peer_host"; return 0
    else
      warn "SSH test still failing after key install."
    fi
  done

  warn "Could not set up sync after ${attempts} attempts."
  echo "  Manual fix on ${peer_host}: sudo usermod -s /bin/bash pihole"
  return 1
}

run_ssh_setup() {
  as_root; ensure_dirs; resolve_sync_key
  local peer_host; peer_host="$(cfg_get peer_host '')"
  [[ -z "$peer_host" ]] && ask "Peer hostname or IP" "" peer_host
  [[ -n "$peer_host" ]] || { warn "No peer host."; return 1; }
  setup_sync_user_on_peer "$peer_host"
  cfg_set peer_host "$peer_host"
}

reset_sync_key() {
  as_root; resolve_sync_key
  local peer_host; peer_host="$(cfg_get peer_host '')"
  echo; echo "${BOLD}${CYAN}  Reset SSH Sync Key${NC}"
  echo "${DIM}────────────────────────────────────────${NC}"
  if [[ -f "$PIHOLE_SYNC_KEY" ]]; then
    echo "  Current key: ${PIHOLE_SYNC_KEY}"
    local fp; fp="$(ssh-keygen -lf "${PIHOLE_SYNC_KEY}.pub" 2>/dev/null | awk '{print $2}' || echo '(unreadable)')"
    echo "  Fingerprint: ${fp}"
    echo
    local _R; ask_yesno "Delete and regenerate?" "n" _R
    [[ "$_R" == "true" ]] || { info "Cancelled."; return 0; }
    rm -f "$PIHOLE_SYNC_KEY" "${PIHOLE_SYNC_KEY}.pub"; ok "Key deleted."
  else
    info "No existing key found — will generate new one."
  fi
  if [[ -n "$peer_host" ]]; then
    echo; warn "Old key may still be in peer authorized_keys. Run option 12 after setup to remove it."; echo
    setup_pihole_ssh_home
    setup_sync_user_on_peer "$peer_host"
  else
    setup_pihole_ssh_home
    ssh-keygen -t ed25519 -f "$PIHOLE_SYNC_KEY" -N "" \
      -C "${PIHOLE_USER}@$(hostname -s 2>/dev/null || echo local)-sync" >/dev/null 2>&1
    chown "${PIHOLE_USER}:${PIHOLE_USER}" "${PIHOLE_SYNC_KEY}" "${PIHOLE_SYNC_KEY}.pub" 2>/dev/null || true
    chmod 600 "$PIHOLE_SYNC_KEY"; chmod 644 "${PIHOLE_SYNC_KEY}.pub"
    ok "New key: ${PIHOLE_SYNC_KEY}"
    echo "  Public key (install on peer):"
    echo "    ${GREEN}$(cat "${PIHOLE_SYNC_KEY}.pub")${NC}"
  fi
}

audit_ssh_keys() {
  resolve_sync_key
  local peer_host; peer_host="$(cfg_get peer_host '')"
  echo; echo "${BOLD}${CYAN}  SSH Key Audit${NC}"
  echo "${DIM}────────────────────────────────────────${NC}"
  local phome; phome="$(getent passwd "$PIHOLE_USER" | cut -d: -f6 2>/dev/null || echo /var/lib/pihole)"
  for loc in "/root/.ssh/authorized_keys" "${phome}/.ssh/authorized_keys"; do
    [[ -f "$loc" ]] || { echo "  ${loc}: ${DIM}(not found)${NC}"; continue; }
    local cnt; cnt="$(grep -c 'ssh-' "$loc" 2>/dev/null || echo 0)"
    echo "  ${BOLD}${loc}${NC} (${cnt} key(s)):"
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      local kc; kc="$(echo "$line" | awk '{print $3}')"
      [[ "$kc" == *"-sync"* ]] && echo "    ... ${kc} ${GREEN}<-- sync${NC}" || echo "    ... ${kc}"
    done < "$loc"
  done
  echo; echo "  ${BOLD}Sync key (local):${NC}"
  if [[ -f "${PIHOLE_SYNC_KEY}.pub" ]]; then
    echo "    ${GREEN}$(ssh-keygen -lf "${PIHOLE_SYNC_KEY}.pub" 2>/dev/null | awk '{print $2, $4}')${NC}"
  else
    echo "    ${DIM}(not found — run: pihole-easy-acme --ssh-setup)${NC}"
  fi
  if [[ -n "$peer_host" ]]; then
    echo; echo "${BOLD}${CYAN}  Peer: ${peer_host}${NC}"
    echo "${DIM}────────────────────────────────────────${NC}"
    local SSH_BATCH="-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes"
    local peer_phome
    peer_phome="$(ssh -i "$PIHOLE_SYNC_KEY" $SSH_BATCH "${PIHOLE_USER}@${peer_host}" \
      "getent passwd pihole | cut -d: -f6" 2>/dev/null || echo /var/lib/pihole)"
    ssh -i "$PIHOLE_SYNC_KEY" $SSH_BATCH "${PIHOLE_USER}@${peer_host}" \
      "cat '${peer_phome}/.ssh/authorized_keys' 2>/dev/null || echo '(empty)'" 2>/dev/null \
      | while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          kc="$(echo "$line" | awk '{print $3}')"
          [[ "$kc" == *"-sync"* ]] && echo "    ... ${kc} ${GREEN}<-- sync${NC}" || echo "    ... ${kc}"
        done || echo "    ${YELLOW}Cannot connect — run: pihole-easy-acme --ssh-setup${NC}"
  fi
  echo
}

cleanup_peer_ssh_keys() {
  resolve_sync_key
  local peer_host; peer_host="$(cfg_get peer_host '')"
  [[ -n "$peer_host" ]] || ask "Peer hostname or IP" "" peer_host
  [[ -n "$peer_host" ]] || { warn "No peer host."; return 1; }
  local SSH_BATCH="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
  local SSH_PASS="-o StrictHostKeyChecking=no  -o ConnectTimeout=15 -o BatchMode=no"
  [[ -f "${PIHOLE_SYNC_KEY}.pub" ]] || { warn "No sync key — run --ssh-setup first."; return 1; }
  local current_pub; current_pub="$(cat "${PIHOLE_SYNC_KEY}.pub")"
  local peer_phome
  peer_phome="$(ssh -i "$PIHOLE_SYNC_KEY" $SSH_BATCH "${PIHOLE_USER}@${peer_host}" \
    "getent passwd pihole | cut -d: -f6" 2>/dev/null || echo /var/lib/pihole)"
  local peer_keys
  peer_keys="$(ssh -i "$PIHOLE_SYNC_KEY" $SSH_BATCH "${PIHOLE_USER}@${peer_host}" \
    "cat '${peer_phome}/.ssh/authorized_keys' 2>/dev/null" 2>/dev/null)" \
    || { warn "Cannot read authorized_keys on peer."; return 1; }
  local to_remove=0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    [[ "$line" != "$current_pub" ]] && (( to_remove++ )) || true
  done <<< "$peer_keys"
  (( to_remove == 0 )) && { ok "Peer authorized_keys already clean."; return 0; }
  local _DO; ask_yesno "Remove ${to_remove} stale key(s) from ${peer_host}?" "y" _DO
  [[ "$_DO" == "true" ]] || { info "Cancelled."; return 0; }
  local result
  result="$(echo "$current_pub" | ssh $SSH_PASS "root@${peer_host}" "
    cat > '${peer_phome}/.ssh/authorized_keys'
    chmod 600 '${peer_phome}/.ssh/authorized_keys'
    chown pihole:pihole '${peer_phome}/.ssh/authorized_keys'
    echo CLEANUP_DONE
  " 2>&1)"
  [[ "$result" == *"CLEANUP_DONE"* ]] \
    && ok "Removed ${to_remove} stale key(s) from ${peer_host}." \
    || warn "Cleanup failed: ${result}"
}

cleanup_local_root_keys() {
  local root_ak="/root/.ssh/authorized_keys"
  [[ -f "$root_ak" ]] || { info "No root authorized_keys."; return 0; }
  local stale; stale="$(grep -cE 'pihole-encrypt|-sync' "$root_ak" 2>/dev/null || echo 0)"
  (( stale == 0 )) && { ok "No stale keys in root authorized_keys."; return 0; }
  echo "  Found ${stale} stale key(s) in ${root_ak}."
  local _DO; ask_yesno "Remove them?" "y" _DO
  [[ "$_DO" == "true" ]] || { info "Cancelled."; return 0; }
  cp "$root_ak" "${root_ak}.bak.$(date +%Y%m%d%H%M%S)"
  sed -i -E '/pihole-encrypt|-sync/d' "$root_ak"
  ok "Removed ${stale} stale key(s)."
}

sync_peers() {
  [[ "$(cfg_get peer_enabled false)" == "true" ]] || return 0
  resolve_sync_key
  local peer_host; peer_host="$(cfg_get peer_host '')"
  local peer_key="$PIHOLE_SYNC_KEY"
  local local_domain; local_domain="$(cfg_get domain '')"
  [[ -n "$peer_host" ]] || { warn "No peer host configured."; return 1; }
  [[ -f "$peer_key"  ]] || { warn "Sync key not found: ${peer_key} — run: pihole-easy-acme --ssh-setup"; return 1; }
  info "Syncing DNS records from ${PIHOLE_USER}@${peer_host}..."
  local peer_records
  peer_records="$(ssh -i "$peer_key" \
    -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
    "${PIHOLE_USER}@${peer_host}" "cat /etc/pihole/custom.list 2>/dev/null || true" 2>&1)" \
    || { warn "Could not reach peer: ${peer_host}"; return 1; }
  [[ -z "$peer_records" ]] && { info "Peer custom.list is empty."; return 0; }
  local custom_list="/etc/pihole/custom.list"
  touch "$custom_list"; chmod 640 "$custom_list"; chown root:pihole "$custom_list" 2>/dev/null || true
  local added=0 skipped=0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    [[ -n "$local_domain" && "$line" == *"$local_domain"* ]] && { (( skipped++ )) || true; continue; }
    grep -qF "$line" "$custom_list" 2>/dev/null || { echo "$line" >> "$custom_list"; (( added++ )) || true; }
  done <<< "$peer_records"
  if (( added > 0 )); then
    ok "Synced ${added} record(s) from ${peer_host} (${skipped} local record(s) skipped)."
    pihole reloaddns 2>/dev/null || true
  else
    info "No new records (${skipped} local record(s) skipped — already up to date)."
  fi
}

show_peer_records() {
  resolve_sync_key
  local peer_host; peer_host="$(cfg_get peer_host '')"
  [[ -n "$peer_host" ]] || { warn "No peer configured — run option 10 first."; return 1; }
  echo; echo "${BOLD}  Local custom.list:${NC}"
  cat /etc/pihole/custom.list 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
  echo; echo "${BOLD}  Peer (${peer_host}) custom.list:${NC}"
  ssh -i "$PIHOLE_SYNC_KEY" \
    -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes \
    "${PIHOLE_USER}@${peer_host}" \
    "cat /etc/pihole/custom.list 2>/dev/null || echo '(empty)'" 2>/dev/null \
    | sed 's/^/    /' || echo "    (could not connect — run option 10)"
}

auto_sync_peers() {
  as_root; lock; ensure_dirs; resolve_sync_key
  sync_peers || warn "Peer sync failed."
}

add_local_dns_ipv4_only() {
  local domain="$1"
  local ipv4; ipv4="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -z "$ipv4" ]] && { warn "Could not detect local IPv4 address."; return 1; }
  local custom_list="/etc/pihole/custom.list"
  touch "$custom_list"
  # Remove any existing entry for this domain, then add fresh
  sed -i "/[[:space:]]${domain}$/d" "$custom_list" 2>/dev/null || true
  echo "${ipv4}  ${domain}" >> "$custom_list"
  chmod 640 "$custom_list"; chown root:pihole "$custom_list" 2>/dev/null || true
  ok "DNS A record: ${ipv4} -> ${domain} (IPv4 only)"
  pihole reloaddns 2>/dev/null || true
}

test_https_enforcement() {
  local domain="$1"
  local ipv4; ipv4="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo; echo "${BOLD}  Testing HTTPS on ${domain} (${ipv4})...${NC}"; echo
  local cert_cn
  cert_cn="$(openssl s_client -connect "${ipv4}:443" -servername "$domain" \
    -verify_quiet </dev/null 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN *= *//')"
  if [[ "$cert_cn" == "$domain" ]]; then
    ok "TLS 443: cert CN = ${cert_cn} ✓"
  elif [[ -n "$cert_cn" ]]; then
    warn "TLS 443: CN = ${cert_cn} (expected ${domain})"
  else
    warn "TLS 443: no response on port 443"
  fi
  local http_resp http_code http_loc
  http_resp="$(curl -s -o /dev/null -w "%{http_code}:%{redirect_url}" \
    --max-time 5 "http://${ipv4}/" 2>/dev/null || echo "000:")"
  http_code="${http_resp%%:*}"; http_loc="${http_resp#*:}"
  case "$http_code" in
    301|302|307|308) [[ "$http_loc" == https://* ]] \
      && ok "HTTP 80: ${http_code} redirect to HTTPS ✓" \
      || warn "HTTP 80: redirect to non-HTTPS: ${http_loc}" ;;
    200) warn "HTTP 80: serving plain HTTP (no redirect configured)" ;;
    000) warn "HTTP 80: no response" ;;
    *)   warn "HTTP 80: unexpected status ${http_code}" ;;
  esac
  local https_code
  https_code="$(curl -sk -o /dev/null -w "%{http_code}" \
    --max-time 10 "https://${ipv4}/admin/" 2>/dev/null || echo "000")"
  case "$https_code" in
    200|301|302|308) ok "HTTPS /admin/: HTTP ${https_code} ✓" ;;
    000) warn "HTTPS /admin/: no response" ;;
    *) warn "HTTPS /admin/: unexpected HTTP ${https_code}" ;;
  esac
}

# ============================================================
#  Pi-hole helpers
# ============================================================

detect_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  local result
  result="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -qi '^pihole$' && echo "pihole")" && [[ -n "$result" ]] && { echo "$result"; return 0; }
  result="$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk 'tolower($2)~/pihole/{print $1;exit}' || true)"
  [[ -n "$result" ]] && echo "$result" && return 0
  return 1
}

docker_etc_pihole() {
  docker inspect "$1" --format \
    '{{range .Mounts}}{{if eq .Destination "/etc/pihole"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null || true
}

pihole_domain_from_toml() {
  local toml="/etc/pihole/pihole.toml"
  [[ -f "$toml" ]] || { echo ""; return; }
  if python3 -c "import tomllib" >/dev/null 2>&1; then
    python3 - "$toml" <<'PY' 2>/dev/null || true
import sys, tomllib
with open(sys.argv[1], 'rb') as f: data = tomllib.load(f)
print((data.get("webserver", {}).get("domain", "")).strip())
PY
  else
    grep -E '^\s*domain\s*=' "$toml" | head -1 \
      | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true
  fi
}

cert_expiry() {
  [[ -f "$1" ]] || { echo "missing"; return; }
  openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "unknown"
}

cert_expires_within() {
  [[ -f "$1" ]] || return 0
  openssl x509 -in "$1" -noout -checkend "$(( $2 * 86400 ))" >/dev/null 2>&1 && return 1 || return 0
}

validate_cert_material() {
  local cert="$1" key="$2" hostname="$3"
  [[ -s "$cert" ]] || { warn "Certificate is missing or empty: $cert"; return 1; }
  [[ -s "$key" ]]  || { warn "Private key is missing or empty: $key"; return 1; }

  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || {
    warn "Certificate cannot be parsed: $cert"
    return 1
  }
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || {
    warn "Private key cannot be parsed: $key"
    return 1
  }
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 || {
    warn "Certificate expires within 24 hours."
    return 1
  }
  local start now
  start="$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null)" || return 1
  start="$(date -u -d "${start#notBefore=}" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  (( start <= now )) || { warn "Certificate is not yet valid."; return 1; }
  openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:' || {
    warn "Certificate has no DNS subjectAltName."
    return 1
  }
  # Older OpenSSL versions return exit 0 even for a hostname mismatch.
  # Require the positive match text as well as a successful command.
  local host_check
  host_check="$(LC_ALL=C openssl x509 -in "$cert" -noout -checkhost "$hostname" 2>/dev/null)" || return 1
  [[ "$host_check" == "Hostname ${hostname} does match certificate" ]] || {
    warn "Certificate does not cover hostname: $hostname"
    return 1
  }

  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}')"
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}')"
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || {
    warn "Certificate and private key do not match."
    return 1
  }
}

prune_cert_backups() {
  local pem="$1" keep="${2:-$MAX_CERT_BACKUPS}"
  local -a backups=()
  mapfile -t backups < <(find "$(dirname "$pem")" -maxdepth 1 -type f \
    -name "$(basename "$pem").bak.*" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | awk '{print $2}')

  local i
  for ((i=keep; i<${#backups[@]}; i++)); do
    rm -f -- "${backups[$i]}"
  done
  (( ${#backups[@]} > keep )) && \
    ok "Old certificate backups pruned; newest ${keep} retained."
  return 0
}

add_local_dns_records() {
  local domain="$1"
  local custom_list="/etc/pihole/custom.list"

  # Get local addresses
  local ipv4; ipv4="$(hostname -I | awk '{print $1}')"
  local ipv6; ipv6="$(get_local_ipv6)"

  # Ensure custom.list exists
  touch "$custom_list"; chmod 640 "$custom_list"
  chown root:pihole "$custom_list" 2>/dev/null || true

  # Remove old entries for this domain (if any) - leaves all other entries untouched
  sed -i "/[[:space:]]${domain}$/d" "$custom_list"

  # Add IPv4 record
  if [[ -n "$ipv4" ]]; then
    echo "$ipv4  $domain" >> "$custom_list"
  fi

  # Add IPv6 record
  if [[ -n "$ipv6" ]]; then
    echo "$ipv6  $domain" >> "$custom_list"
  fi

  # Reload DNS to apply custom records
  if command -v pihole >/dev/null 2>&1; then
    pihole reloaddns
  fi
}

# ============================================================
#  acme.sh + certificaat installatie
# ============================================================

# Never infer account/certificate state from the invoking shell's HOME.
# Legacy split state is detected, not silently moved or selected.
resolve_acme_paths() {
  ACME_HOME="$(cfg_get acme_home /root/.acme.sh)"
  ACME_CONFIG_HOME="$(cfg_get acme_config_home "$ACME_HOME")"
  ACME_CERT_HOME="$(cfg_get acme_cert_home "$ACME_CONFIG_HOME")"
  local path
  for path in "$ACME_HOME" "$ACME_CONFIG_HOME" "$ACME_CERT_HOME"; do
    [[ "$path" == /* && "$path" != / && "$path" != *$'\n'* ]] || {
      warn "ACME paths must be absolute non-root directories."
      return 1
    }
  done
  if [[ -z "$(cfg_get acme_config_home)" && -z "$(cfg_get acme_cert_home)" \
        && "$ACME_HOME" != /.acme.sh && -d /.acme.sh ]]; then
    warn "Legacy /.acme.sh state detected. Set acme_config_home and acme_cert_home explicitly before renewal; no state has been moved."
    return 1
  fi
}

acme_command() {
  "$ACME_HOME/acme.sh" --home "$ACME_HOME" \
    --config-home "$ACME_CONFIG_HOME" --cert-home "$ACME_CERT_HOME" "$@"
}

install_acme() {
  resolve_acme_paths || return 1
  [[ -x "$ACME_HOME/acme.sh" ]] && return 0
  # Preserve the existing bootstrap for standard installations only.
  [[ "$ACME_HOME" == /root/.acme.sh && "$ACME_CONFIG_HOME" == "$ACME_HOME" \
      && "$ACME_CERT_HOME" == "$ACME_HOME" ]] || {
    warn "Install acme.sh in the configured home before continuing."
    return 1
  }
  info "Installing acme.sh..."
  local email; email="$(cfg_get email "admin@$(cfg_get zone)")"
  curl -fsSL https://get.acme.sh | sh -s email="$email" >/dev/null 2>&1 || return 1
  [[ -x "$ACME_HOME/acme.sh" ]] || return 1
  ok "acme.sh installed."
}

do_issue() {
  local force="$1"; shift
  local ca="$1"; shift; local domains=("$@")
  [[ ${#domains[@]} -gt 0 ]] || { warn "No domains specified"; return 1; }
  resolve_acme_paths || return 1
  local args=(--issue --dns dns_cf --keylength ec-256 --server "$ca")
  [[ "$force" == "true" ]] && args+=(--force)
  local d
  for d in "${domains[@]}"; do
    [[ -n "$d" && "$d" != */* && "$d" != -* ]] || return 1
    args+=(-d "$d")
  done

  # Capture status explicitly: callers may enable errexit or invoke us in ||.
  # Do not echo raw provider output, which can contain sensitive account data.
  local exit_code=0
  CF_Token="${CF_TOKEN}" acme_command "${args[@]}" >/dev/null 2>&1 || exit_code=$?
  case "$exit_code" in
    0|2) ;;
    *) warn "acme.sh failed (exit ${exit_code}); certificate not installed."; return "$exit_code" ;;
  esac
  local main="${domains[0]}" dir="${ACME_CERT_HOME}/${domains[0]}_ecc"
  for d in "${domains[@]}"; do
    validate_cert_material "${dir}/fullchain.cer" "${dir}/${main}.key" "$d" || return 1
  done
  if (( exit_code == 2 )); then
    ok "ACME renewal skipped; existing certificate material validated."
  fi
  ok "Certificate ready: ${main}"
}

cert_material_unchanged() {
  local cert="$1" key="$2" pem="$3"
  [[ -s "$pem" ]] && cmp -s "$pem" <(cat "$cert" "$key")
}

install_cert_bare() {
  local primary="$1" main="$2"
  resolve_acme_paths || die "Cannot resolve ACME state."
  local dir="${ACME_CERT_HOME}/${main}_ecc"
  [[ -f "${dir}/fullchain.cer" ]] || die "Fullchain not found: ${dir}/fullchain.cer"
  [[ -f "${dir}/${main}.key" ]]  || die "Key not found: ${dir}/${main}.key"
  validate_cert_material "${dir}/fullchain.cer" "${dir}/${main}.key" "$primary" \
    || die "New certificate material failed validation."

  if cert_material_unchanged "${dir}/fullchain.cer" "${dir}/${main}.key" /etc/pihole/tls.pem; then
    ok "No renewal or Pi-hole restart required."
    return 0
  fi

  local bak="" tmp=""
  if [[ -f /etc/pihole/tls.pem ]]; then
    bak="/etc/pihole/tls.pem.bak.$(date +%F-%H%M%S)"
    cp /etc/pihole/tls.pem "$bak" || die "Backup creation failed"
    chmod 600 "$bak"
    ok "Backup created: $bak"
  fi

  tmp="$(mktemp /etc/pihole/.tls.pem.new.XXXXXX)" || die "Cannot create temporary certificate file"
  if ! cat "${dir}/fullchain.cer" "${dir}/${main}.key" > "$tmp"; then
    rm -f -- "$tmp"
    die "Certificate write failed"
  fi
  chown pihole:pihole "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f -- "$tmp" /etc/pihole/tls.pem || die "Atomic certificate install failed"
  ok "Certificate installed: /etc/pihole/tls.pem"

  command -v pihole-FTL >/dev/null 2>&1 && {
    pihole-FTL --config webserver.domain        "$primary"           >/dev/null 2>&1 || true
    pihole-FTL --config webserver.tls.cert      "/etc/pihole/tls.pem" >/dev/null 2>&1 || true
  }

  if systemctl restart pihole-FTL >/dev/null 2>&1 \
      && systemctl is-active --quiet pihole-FTL; then
    ok "pihole-FTL restarted."
    prune_cert_backups /etc/pihole/tls.pem
  else
    warn "Restart failed — rolling back..."
    if [[ -n "$bak" ]] && [[ -f "$bak" ]]; then
      cp "$bak" /etc/pihole/tls.pem || warn "Rollback failed"
      systemctl restart pihole-FTL >/dev/null 2>&1 || true
    fi
    die "Pi-hole failed to restart after certificate installation."
  fi
}

install_cert_docker() {
  local container="$1" primary="$2" main="$3" host_etc="$4"
  resolve_acme_paths || die "Cannot resolve ACME state."
  local dir="${ACME_CERT_HOME}/${main}_ecc"
  local pem="${host_etc}/tls.pem"

  [[ -f "${dir}/fullchain.cer" ]] || die "Fullchain not found."
  [[ -f "${dir}/${main}.key" ]]  || die "Key not found."
  [[ -n "$host_etc" ]] || die "Host etc path is empty"
  [[ -n "$container" ]] || die "Container name is empty"
  validate_cert_material "${dir}/fullchain.cer" "${dir}/${main}.key" "$primary" \
    || die "New certificate material failed validation."

  if cert_material_unchanged "${dir}/fullchain.cer" "${dir}/${main}.key" "$pem"; then
    ok "No renewal or Pi-hole restart required."
    return 0
  fi

  mkdir -p "$host_etc" || die "Cannot create directory: $host_etc"
  chmod 700 "$host_etc"

  local bak="" tmp=""
  if [[ -f "$pem" ]]; then
    bak="${pem}.bak.$(date +%F-%H%M%S)"
    cp "$pem" "$bak" || die "Backup creation failed"
    ok "Backup created: $bak"
  fi

  tmp="$(mktemp "${host_etc}/.tls.pem.new.XXXXXX")" || die "Cannot create temporary certificate file"
  if ! cat "${dir}/fullchain.cer" "${dir}/${main}.key" > "$tmp"; then
    rm -f -- "$tmp"
    die "Certificate write failed"
  fi
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$pem" || die "Atomic certificate install failed"
  ok "Certificate installed: $pem"

  docker exec "$container" pihole-FTL --config webserver.domain        "$primary"            >/dev/null 2>&1 || true
  docker exec "$container" pihole-FTL --config webserver.tls.cert      "/etc/pihole/tls.pem" >/dev/null 2>&1 || true

  if docker restart "$container" >/dev/null 2>&1; then
    ok "Container restarted: $container"
    prune_cert_backups "$pem"
  else
    warn "Container restart failed — rolling back..."
    if [[ -n "$bak" ]] && [[ -f "$bak" ]]; then
      cp "$bak" "$pem" || warn "Rollback failed"
      docker restart "$container" >/dev/null 2>&1 || true
    fi
    die "Docker container failed to restart."
  fi
}

# ============================================================
#  WAN IP reporting
# ============================================================

report_wan_ip() {
  [[ "$(cfg_get dns_sync false)" == "true" ]] || return 0
  local zone_id primary
  zone_id="$(cfg_get zone_id)"
  primary="$(cfg_get primary)"
  [[ -n "$zone_id" ]] && [[ -n "$primary" ]] || { warn "WAN IP report: configuration missing."; return 0; }

  info "Reporting WAN addresses for: $primary"
  local wan4 wan6
  wan4="$(get_wan_ipv4 || true)"
  wan6="$(get_wan_ipv6 || true)"

  if [[ -n "$wan4" ]]; then
    info "Current IPv4: $wan4"
  else
    warn "No public IPv4 detected."
  fi

  if [[ -n "$wan6" ]]; then
    info "Current IPv6: $wan6"
  else
    info "No public IPv6 detected."
  fi

  ok "WAN IP report completed; no DNS records were changed."
}

# Backwards-compatible internal name for v1.9 configurations and menu paths.
sync_dns() { report_wan_ip; }

# ============================================================
#  Schedulers
# ============================================================

disable_acme_cron() {
  resolve_acme_paths || return 1
  [[ -x "$ACME_HOME/acme.sh" ]] || return 0
  acme_command --uninstall-cronjob >/dev/null 2>&1 || true
}

install_timer() {
  local name="$1" desc="$2" cmd="$3" time="$4"
  cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${desc}
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=${cmd}
EOF
  cat > "/etc/systemd/system/${name}.timer" <<EOF
[Unit]
Description=${desc} (timer)
[Timer]
OnCalendar=${time}
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${name}.timer" >/dev/null 2>&1
  ok "Timer active: ${name}.timer  (${time})"
}

install_self() {
  local target="/usr/local/sbin/${APP}"
  local src; src="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "$0" 2>/dev/null || true)"
  [[ -z "$src" || ! -f "$src" ]] && { warn "Cannot resolve script path — skipping install to ${target}."; return 0; }
  [[ "$src" == "$target" ]] && { ok "Script already at ${target}."; return 0; }
  cp "$src" "$target" && chmod 700 "$target" && ok "Script installed: ${target}" || warn "Could not install to ${target} — timers may fail."
}

setup_schedulers() {
  command -v systemctl >/dev/null 2>&1 || { warn "systemd not available."; return 0; }

  if [[ "$(cfg_get auto_renew false)" == "true" ]]; then
    install_timer "${APP}" "Pi-hole Easy ACME renewal" \
      "/usr/local/sbin/${APP} --renew" "*-*-* 03:11:00"
    disable_acme_cron
    ok "Native acme.sh cron disabled; systemd owns certificate renewal."
  fi

  if [[ "$(cfg_get auto_gravity false)" == "true" ]]; then
    local when="*-*-* 03:17:00"
    [[ "$(cfg_get gravity_schedule daily)" == "weekly" ]] && when="Sun *-*-* 03:17:00"
    install_timer "pihole-gravity-easy" "Pi-hole adlist update" \
      "/usr/local/sbin/${APP} --gravity" "$when"
  fi
}

# ============================================================
#  Request certificate (complete flow)
# ============================================================

do_certificate() {
  local force="${1:-false}"
  read_token

  local domain primary zone zone_id mode container wildcard staging renew_days
  domain="$(cfg_get domain)"
  primary="$(cfg_get primary)"
  zone="$(cfg_get zone)"
  zone_id="$(cfg_get zone_id)"
  mode="$(cfg_get mode bare)"
  container="$(cfg_get container)"
  wildcard="$(cfg_get wildcard false)"
  staging="$(cfg_get staging false)"
  renew_days="$(cfg_get renew_days "$DEFAULT_RENEW_DAYS")"

  [[ -n "$domain"  ]] || die "No domain. Run setup again."
  [[ -n "$zone_id" ]] || die "No zone ID. Run setup again."

  local pem="/etc/pihole/tls.pem"
  if [[ "$mode" == "docker" ]]; then
    local host_etc; host_etc="$(docker_etc_pihole "$container" || true)"
    [[ -n "$host_etc" ]] || die "Cannot determine Docker mount path for container: $container"
    pem="${host_etc}/tls.pem"
  fi

  # Determine if we need to request a new certificate
  local need_cert="false"
  if [[ "$force" == "true" ]] || cert_expires_within "$pem" "$renew_days" \
      || ! validate_cert_material "$pem" "$pem" "$primary"; then
    need_cert="true"
  else
    ok "Certificate expires in more than ${renew_days} days (expires: $(cert_expiry "$pem"))."
    disable_acme_cron
    ok "No renewal or Pi-hole restart required."
    return 0
  fi

  # Request new certificate if needed
  local main_domain="$domain"
  if [[ "$need_cert" == "true" ]]; then
    local -a domains=()
    if [[ "$wildcard" == "true" ]]; then
      domains=("$zone" "*.${zone}")
      [[ "$domain" != "$zone" ]] && domains+=("$domain")
      main_domain="$zone"
    else
      domains=("$domain")
      main_domain="$domain"
    fi

    local ca="$CA_PROD"
    [[ "$staging" == "true" ]] && ca="$CA_STAGING"

    install_acme || die "ACME installation/state configuration failed."
    echo
    info "Requesting certificate for: ${domains[*]}"
    do_issue "$force" "$ca" "${domains[@]}" || die "acme.sh certificate request failed"
    disable_acme_cron
  fi

  # Apply Pi-hole configuration only after a newly issued certificate.
  if [[ "$mode" == "docker" ]]; then
    local host_etc; host_etc="$(docker_etc_pihole "$container" || true)"
    [[ -n "$host_etc" ]] || die "Cannot determine Docker mount path"
    install_cert_docker "$container" "$primary" "$main_domain" "$host_etc"
  else
    install_cert_bare "$primary" "$main_domain"
  fi

  report_wan_ip
  echo
  ok "Certificate valid until: $(cert_expiry "$pem")"
  ok "HTTPS reachable at: https://${primary}/admin"
}

# ============================================================
#  SETUP WIZARD — 10 steps
# ============================================================

run_setup() {
  header
  echo "  This script automatically sets up HTTPS for your Pi-hole"
  echo "  via Let's Encrypt with Cloudflare DNS validation."
  echo
  echo "  What you need:"
  echo "    • Your domain name is in Cloudflare DNS"
  echo "    • A Cloudflare API token (Zone:DNS:Edit + Zone:Zone:Read)"
  echo
  ask_yesno "Start the setup?" "y" _START
  [[ "$_START" == "true" ]] || { echo "  Cancelled."; exit 0; }

  # ─── Step 1: Cloudflare token ───────────────────────────────
  step 1 "Cloudflare API token"
  echo
  echo "  ${BOLD}Open this link in your browser:${NC}"
  echo "  ${CYAN}https://dash.cloudflare.com/profile/api-tokens${NC}"
  echo
  echo "  Required permissions:"
  echo "    • Zone -> DNS -> Edit"
  echo "    • Zone -> Zone -> Read"
  echo
  if command -v xdg-open >/dev/null 2>&1; then
    echo "  ${YELLOW}Tip: To open the link automatically, enter '?' at the token prompt.${NC}"
  fi
  echo
  echo "  Choose input mode:"
  echo "    1) Visible  (easier to paste)"
  echo "    2) Hidden   (more secure)"
  ask "Input mode" "1" _TMODE

  local tok=""

  # Check for token in secure .env file
  if [[ -f "$ENV_FILE" ]]; then
    local env_token
    env_token="$(grep -E "^CF_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d ' \t\r\n' || true)"
    if [[ -n "$env_token" ]]; then
      echo
      echo "  Found Cloudflare token in secure storage"
      ask_yesno "Reuse saved token?" "y" _USE_ENV_TOKEN
      if [[ "$_USE_ENV_TOKEN" == "true" ]]; then
        tok="$env_token"
      fi
    fi
  fi

  while [[ -z "$tok" ]]; do
    echo
    if [[ "${_TMODE:-1}" == "2" ]]; then
      ask_secret "API Key" tok
    else
      ask "API Key" "" tok
    fi

    if [[ "$tok" == "?" ]] && command -v xdg-open >/dev/null 2>&1; then
      xdg-open "https://dash.cloudflare.com/profile/api-tokens" 2>/dev/null || true
      tok=""
      info "Opening browser... Please paste your token below."
      continue
    fi

    [[ -n "$tok" ]] && break
    warn "Token cannot be empty. Please try again."
  done

  ensure_dirs
  umask 077; printf "%s" "$tok" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"

  # Save token to secure .env file for next run
  umask 077
  printf "CF_TOKEN=%s\n" "$tok" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  CF_TOKEN="$tok"
  echo
  info "Validating token..."
  cf_verify_token && ok "Token is active and valid." \
    || die "Token is invalid or missing required permissions.\nRequired scopes: Zone -> DNS -> Edit + Zone -> Zone -> Read"

  echo
  info "Configuration saved to: ${CONF_DIR}"
  echo "  • Token:       ${TOKEN_FILE}"
  echo "  • Config:      ${CONF_FILE}"
  echo "  • Secure env:  ${ENV_FILE}"

  # ─── Step 2: Cloudflare zone detection ──────────────────────
  step 2 "Cloudflare zone detection"

  local zones zone_line ZONE_ID ZONE_NAME
  while :; do
    zones="$(cf_get_zones 2>/dev/null)" || zones=""

    if [[ -z "$zones" ]] || [[ "$zones" == "[]" ]]; then
      warn "Failed to fetch zones from Cloudflare"
      echo
      echo "  Possible causes:"
      echo "    • Internet connection issue"
      echo "    • Token is invalid or expired"
      echo "    • Cloudflare API is temporarily unavailable"
      echo
      ask_yesno "Retry fetching zones?" "y" _RETRY
      if [[ "$_RETRY" == "true" ]]; then
        continue
      else
        die "Cannot continue without zones from Cloudflare."
      fi
    fi

    # Show available zones
    echo
    echo "  Available zones in your Cloudflare account:"
    python3 - "$zones" <<'PY' 2>/dev/null || echo "  (unable to list zones)"
import json, sys
try:
    zones_data = json.loads(sys.argv[1])
    if isinstance(zones_data, list) and len(zones_data) > 0:
        for i, z in enumerate(zones_data, 1):
            name = z.get('name', 'unknown')
            print(f"    {i}) {name}")
    elif isinstance(zones_data, list):
        print("    (no zones in account)")
    else:
        print(f"    (unexpected response format)")
except Exception as e:
    print(f"    (error parsing zones: {str(e)[:50]})")
PY
    echo

    # Ask user to select or search
    ask "Enter zone name or number" "" _ZONE_INPUT

    # If input is empty, show menu again
    if [[ -z "$_ZONE_INPUT" ]]; then
      continue
    fi

    # If input is a number, select by index
    if [[ "$_ZONE_INPUT" =~ ^[0-9]+$ ]]; then
      zone_line="$(python3 - "$zones" "$_ZONE_INPUT" <<'PY'
import json, sys
try:
    zones_data = json.loads(sys.argv[1])
    idx = int(sys.argv[2]) - 1
    if 0 <= idx < len(zones_data):
        z = zones_data[idx]
        zone_id = z.get('id', '')
        name = z.get('name', '')
        print(f"{zone_id}\t{name}")
except Exception as e:
    pass
PY
)"
    else
      # Try to find matching zone by name/domain
      zone_line="$(cf_find_zone "$_ZONE_INPUT" "$zones" 2>/dev/null || true)"
    fi

    if [[ -z "$zone_line" ]]; then
      warn "Zone '$_ZONE_INPUT' not found"
      echo
      ask_yesno "Try again?" "y" _RETRY
      if [[ "$_RETRY" != "true" ]]; then
        die "Cannot continue without selecting a zone."
      fi
      continue
    fi

    ZONE_ID="$(echo "$zone_line" | cut -f1)"
    ZONE_NAME="$(echo "$zone_line" | cut -f2)"
    ok "Zone selected: ${ZONE_NAME}  (${ZONE_ID})"
    break
  done

  # ─── Step 3: Domain name for Pi-hole dashboard ──────────────
  step 3 "Domain name for Pi-hole dashboard"
  local DOMAIN=""
  while [[ -z "$DOMAIN" ]]; do
    ask "Domain name (default: pihole.${ZONE_NAME})" "pihole.${ZONE_NAME}" DOMAIN
    [[ -n "$DOMAIN" ]] && break
    warn "Domain name cannot be empty. Please try again."
    echo
  done
  DOMAIN="${DOMAIN,,}"
  DOMAIN="${DOMAIN#\*.}"  # remove leading *. from wildcard
  DOMAIN="${DOMAIN%.}"   # remove trailing dot

  # ─── Step 4: Docker or bare metal ───────────────────────────
  step 4 "Pi-hole installation mode"
  local CONTAINER="" MODE="bare"
  local docker_found; docker_found="$(detect_docker || true)"
  if [[ -n "$docker_found" ]]; then
    info "Docker Pi-hole container detected: $docker_found"
    ask_yesno "Is Pi-hole running in Docker?" "y" _IS_DOCKER
    if [[ "$_IS_DOCKER" == "true" ]]; then
      MODE="docker"; CONTAINER="$docker_found"
      ok "Mode: Docker  (container: $CONTAINER)"
    else
      ok "Mode: bare metal"
    fi
  else
    ok "Mode: bare metal  (no Docker Pi-hole found)"
  fi

  # ─── Step 5: Wildcard ───────────────────────────────────────
  step 5 "Wildcard certificate"
  echo "  A wildcard (*.${ZONE_NAME}) covers all subdomains."
  echo "  For Pi-hole only, this is not necessary."
  echo
  ask_yesno "Request wildcard certificate?" "n" WILDCARD

  # ─── Step 6: Email ─────────────────────────────────────────
  step 6 "Email address (for Let's Encrypt expiration notices)"
  local EMAIL=""
  ask "Email address (leave empty to skip)" "" EMAIL
  [[ -n "$EMAIL" ]] || EMAIL="admin@${ZONE_NAME}"

  # ─── Step 7: Cloudflare DNS sync ────────────────────────────
  step 7 "WAN IP reporting"
  echo "  The script can report your current WAN IP address."
  echo "  (This does not create or modify DNS records)"
  echo
  ask_yesno "Enable WAN IP reporting?" "y" DNS_SYNC

  # ─── Step 8: Staging ────────────────────────────────────────
  step 8 "Let's Encrypt mode"
  echo "  Staging = test mode (no real cert, no rate limits)."
  echo "  Choose 'n' for a real certificate."
  echo
  ask_yesno "Use staging/test mode?" "n" STAGING

  # ─── Step 9: Auto-renew ─────────────────────────────────────
  step 9 "Automatic certificate renewal"
  echo "  Certificates are valid for 90 days. A daily"
  echo "  check automatically renews within ${DEFAULT_RENEW_DAYS} days before expiration."
  echo
  ask_yesno "Enable automatic renewal?" "y" AUTO_RENEW

  # ─── Step 10: Gravity ───────────────────────────────────────
  step 10 "Automatic adlist updates (gravity)"
  echo "  Keeps Pi-hole blocklists automatically up-to-date."
  echo
  ask_yesno "Enable automatic adlist updates?" "y" AUTO_GRAVITY
  local GRAVITY_SCHEDULE="daily"
  if [[ "$AUTO_GRAVITY" == "true" ]]; then
    echo
    echo "  How often?"
    echo "    1) Daily  (recommended)"
    echo "    2) Weekly"
    echo
    ask "Choice" "1" _GS
    [[ "${_GS:-1}" == "2" ]] && GRAVITY_SCHEDULE="weekly"
    ok "Gravity schedule: ${GRAVITY_SCHEDULE}"
  fi


  # ─── Step 11: Peer Pi-hole sync ─────────────────────────────
  step 11 "Peer Pi-hole DNS sync"
  echo "  Sync custom.list DNS records with a second Pi-hole over SSH."
  echo "  Uses the 'pihole' OS user — root password of peer needed once."
  echo
  local PEER_ENABLED="false" PEER_HOST="" PEER_SYNC_INTERVAL="*:0/15"
  local _HAS_PEER
  ask_yesno "Do you have a second Pi-hole to sync with?" "n" _HAS_PEER
  if [[ "$_HAS_PEER" == "true" ]]; then
    PEER_ENABLED="true"
    ask "Peer hostname or IP" "" PEER_HOST
    echo
    echo "  Sync interval:"
    echo "    1) Every 15 minutes  (default)"
    echo "    2) Every 5 minutes"
    echo "    3) Hourly"
    echo
    local _SI; ask "Choice" "1" _SI
    case "${_SI:-1}" in
      2) PEER_SYNC_INTERVAL="*:0/5"  ;;
      3) PEER_SYNC_INTERVAL="hourly" ;;
      *) PEER_SYNC_INTERVAL="*:0/15" ;;
    esac
    if [[ -n "$PEER_HOST" ]]; then
      setup_pihole_ssh_home
      setup_sync_user_on_peer "$PEER_HOST" || \
        warn "SSH setup incomplete — finish later with: pihole-easy-acme --ssh-setup"
    fi
  fi

  # ─── Confirmation ────────────────────────────────────────────
  echo
  echo "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════════╗${NC}"
  echo "${BOLD}${CYAN}  ║                  Your configuration                 ║${NC}"
  echo "${BOLD}${CYAN}  ╠══════════════════════════════════════════════════════╣${NC}"
  printf "  ${CYAN}║${NC}  %-22s %-28s ${CYAN}║${NC}\n" "Domain:"       "$DOMAIN"
  printf "  ${CYAN}║${NC}  %-22s %-28s ${CYAN}║${NC}\n" "Zone:"         "$ZONE_NAME"
  printf "  ${CYAN}║${NC}  %-22s %-28s ${CYAN}║${NC}\n" "Mode:"         "$MODE${CONTAINER:+ ($CONTAINER)}"
  printf "  ${CYAN}║${NC}  %-22s %-28s ${CYAN}║${NC}\n" "Wildcard:"     "$WILDCARD"
  printf "  ${CYAN}║${NC}  %-22s %-28s ${CYAN}║${NC}\n" "Staging:"      "$STAGING"
  printf "  ${CYAN}║${NC}  %-22s %-28s ${CYAN}║${NC}\n" "DNS verify:"   "$DNS_SYNC"
  printf "  ${CYAN}║${NC}  %-22s %-28s ${CYAN}║${NC}\n" "Auto-renew:"   "$AUTO_RENEW"
  printf "  ${CYAN}║${NC}  %-22s %-28s ${CYAN}║${NC}\n" "Gravity:"      "${AUTO_GRAVITY} (${GRAVITY_SCHEDULE})"
  printf "  ${CYAN}║${NC}  %-22s %-28s ${CYAN}║${NC}\n" "Peer sync:"    "${PEER_ENABLED}${PEER_HOST:+ -> $PEER_HOST}"
  echo "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════════╝${NC}"
  echo
  ask_yesno "Everything is correct — start installation?" "y" _CONFIRM
  [[ "$_CONFIRM" == "true" ]] || { echo "  Cancelled."; exit 0; }

  # ─── Save config ─────────────────────────────────────────
  cfg_set domain           "$DOMAIN"
  cfg_set primary          "$DOMAIN"
  cfg_set zone             "$ZONE_NAME"
  cfg_set zone_id          "$ZONE_ID"
  cfg_set mode             "$MODE"
  cfg_set container        "$CONTAINER"
  cfg_set wildcard         "$WILDCARD"
  cfg_set staging          "$STAGING"
  cfg_set dns_sync         "$DNS_SYNC"
  cfg_set auto_renew       "$AUTO_RENEW"
  cfg_set auto_gravity     "$AUTO_GRAVITY"
  cfg_set gravity_schedule "$GRAVITY_SCHEDULE"
  cfg_set renew_days       "$DEFAULT_RENEW_DAYS"
  cfg_set email            "$EMAIL"
  # ─── Running installation ───────────────────────────────────
  echo
  echo "${BOLD}  ═══ Starting installation ═══${NC}"
  echo
  cleanup_old_timers
  install_self
  do_certificate "false"
  setup_schedulers
  add_local_dns_ipv4_only "$DOMAIN"
  if [[ "$PEER_ENABLED" == "true" && -n "$PEER_HOST" ]]; then
    install_timer "pihole-peer-sync" "Pi-hole peer DNS sync" \
      "/usr/local/sbin/${APP} --sync-peers" "$PEER_SYNC_INTERVAL"
    info "Running initial peer DNS sync..."
    sync_peers || warn "Initial sync failed — will retry via timer."
  fi

  cfg_set peer_enabled       "$PEER_ENABLED"
  cfg_set peer_host          "$PEER_HOST"
  cfg_set peer_sync_interval "$PEER_SYNC_INTERVAL"

  # Mark setup complete only AFTER full successful installation
  cfg_set setup_done "true"

  # ─── Complete ──────────────────────────────────────────────────
  echo
  echo "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
  echo "${GREEN}${BOLD}  ║               ✓  Setup completed!                   ║${NC}"
  echo "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
  echo
  echo "  Dashboard:     ${BOLD}https://${DOMAIN}/admin${NC}"
  echo "  Expires on:    $(cert_expiry /etc/pihole/tls.pem)"
  echo "  Log:           $LOG"
  [[ "$AUTO_RENEW"   == "true" ]] && echo "  Renew timer:   daily 03:11:00"
  [[ "$AUTO_GRAVITY"  == "true" ]] && echo "  Gravity timer: ${GRAVITY_SCHEDULE} 03:17"
  [[ "$PEER_ENABLED"  == "true" && -n "$PEER_HOST" ]] && echo "  Peer sync:     ${PEER_HOST} every ${PEER_SYNC_INTERVAL}"
  echo
  echo "${BOLD}[*] Secure Storage:${NC}"
  echo "  Configuration stored in: ${BOLD}${CONF_DIR}${NC}"
  echo "    • Token:       cloudflare.token (600)"
  echo "    • Config:      config            (600)"
  echo "    • Env vars:    .env              (600)"
  echo
  echo "${BOLD}Next Steps:${NC}"
  echo
  echo "  Local DNS records automatically added:"
  echo
  local ipv4; ipv4="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ipv4" ]] && echo "     A record:   ${GREEN}${BOLD}$DOMAIN${NC}${GREEN} -> $ipv4${NC}"
  echo
  echo "     IPv4 only (dynamic IPv6 excluded to prevent AAAA resolution issues)."
  echo "     The dashboard is only reachable locally"
  echo "     and not resolved over the internet."
  echo
  echo "  1. Optional: configure your devices to use Pi-hole as DNS server"
  echo
  pause
}

# ============================================================
#  Maintenance menu (after initial setup)
# ============================================================

maintenance_menu() {
  while :; do
    header
    local domain; domain="$(cfg_get domain '(not configured)')"
    echo "  Domain:   ${BOLD}${domain}${NC}"
    echo "  Cert:     $(cert_expiry /etc/pihole/tls.pem)"
    echo
    echo "  1) Renew certificate       (only if expiring soon)"
    echo "  2) Force renew certificate (request new now)"
    echo "  3) Report WAN IP addresses"
    echo "  4) Update Pi-hole          (pihole -up)"
    echo "  5) Run gravity now         (refresh adlists)"
    echo "  6) Show status"
    echo "  7) Re-run setup"
    echo
    echo "  0) Exit"
    echo

    local c; ask "Choice" "" c
    echo

    case "$c" in
      1) read_token; do_certificate "false" ;;
      2) read_token; do_certificate "true" ;;
      3) read_token; sync_dns ;;
      4)
        warn "Pi-hole updates may break things. Create a Teleporter backup first."
        ask_yesno "Continue anyway?" "n" _UPD
        [[ "$_UPD" == "true" ]] || { info "Cancelled."; pause; continue; }
        if [[ "$(cfg_get mode bare)" == "docker" ]]; then
          local _cont; _cont="$(cfg_get container)"
          local _img; _img="$(docker inspect "$_cont" --format '{{.Config.Image}}' 2>/dev/null || true)"
          info "Pulling: $_img"; docker pull "$_img"
          docker restart "$_cont" >/dev/null; ok "Container updated."
        else
          pihole -up
        fi
        ;;
      5)
        if [[ "$(cfg_get mode bare)" == "docker" ]]; then
          docker exec "$(cfg_get container)" pihole -g 2>&1 | tee -a "$GRAVITY_LOG"
        else
          pihole -g 2>&1 | tee -a "$GRAVITY_LOG"
        fi
        ok "Gravity completed."
        ;;
      6)
        echo; echo "  ${BOLD}Configuration:${NC}"
        echo "  Domain:        $(cfg_get domain)"
        echo "  Zone:          $(cfg_get zone)"
        echo "  Mode:          $(cfg_get mode)"
        [[ "$(cfg_get mode)" == "docker" ]] && echo "  Container:     $(cfg_get container)"
        echo "  Wildcard:      $(cfg_get wildcard)"
        echo "  DNS verify:    $(cfg_get dns_sync)"
        echo "  Auto-renew:    $(cfg_get auto_renew)"
        echo "  Gravity:       $(cfg_get auto_gravity) / $(cfg_get gravity_schedule)"
        echo "  Cert expires:  $(cert_expiry /etc/pihole/tls.pem)"
        echo
        local _ps _ph _pi
        _ps="$(cfg_get peer_enabled false)"
        _ph="$(cfg_get peer_host '')"
        _pi="$(cfg_get peer_sync_interval '')"
        if [[ "$_ps" == "true" && -n "$_ph" ]]; then
          resolve_sync_key
          local _fp="(no key)"
          [[ -f "${PIHOLE_SYNC_KEY}.pub" ]] && \
            _fp="$(ssh-keygen -lf "${PIHOLE_SYNC_KEY}.pub" 2>/dev/null | awk '{print $2}' || echo unreadable)"
          local _ss="${RED}not connected${NC}"
          ssh -i "$PIHOLE_SYNC_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=no "${PIHOLE_USER}@${_ph}" "echo ok" \
            >/dev/null 2>&1 && _ss="${GREEN}connected ✓${NC}"
          local _last
          _last="$(systemctl show pihole-peer-sync.service \
            --property=ExecMainExitTimestamp 2>/dev/null | cut -d= -f2 || echo '')"
          echo "  ${BOLD}Peer sync:${NC}"
          echo "  Peer host:     ${GREEN}${_ph}${NC}"
          echo "  Interval:      ${_pi:-unknown}"
          echo -e "  SSH status:    ${_ss}"
          echo "  Sync key:      ${_fp}"
          echo "  Last sync:     ${_last:-(not yet run)}"
        else
          echo "  Peer sync:     ${DIM}disabled${NC}"
        fi
        echo
        command -v systemctl >/dev/null 2>&1 && \
          systemctl list-timers --no-pager 2>/dev/null \
            | grep -E "pihole|${APP}" | sed 's/^/  /' \
          || echo "  (no timers)"
        ;;
      7)  cfg_set setup_done "false"; run_setup; return 0 ;;
      8)  read_token; sync_peers ;;
      9)  show_peer_records ;;
      10) run_ssh_setup ;;
      11) reset_sync_key ;;
      12) cleanup_peer_ssh_keys; cleanup_local_root_keys ;;
      13) add_local_dns_ipv4_only "$(cfg_get domain)" ;;
      14) test_https_enforcement "$(cfg_get domain)" ;;
      15) audit_ssh_keys ;;
      16) cleanup_old_timers ;;
      0)  exit 0 ;;
      "")  continue ;;
      *)  warn "Invalid choice." ;;
    esac
    pause
  done
}

# ============================================================
#  Non-interactive mode (systemd timers)
# ============================================================

auto_renew() {
  as_root; lock; ensure_dirs; read_token
  need_cmd openssl; need_cmd python3; need_cmd curl
  disable_acme_cron
  do_certificate "false"
}

auto_gravity() {
  as_root; lock; ensure_dirs
  echo "[$(date -Is)] gravity start" >> "$GRAVITY_LOG"
  if [[ "$(cfg_get mode bare)" == "docker" ]]; then
    docker exec "$(cfg_get container)" pihole -g >> "$GRAVITY_LOG" 2>&1 || true
  else
    pihole -g >> "$GRAVITY_LOG" 2>&1 || true
  fi
  echo "[$(date -Is)] gravity end" >> "$GRAVITY_LOG"
}

uninstall() {
  echo
  echo "${BOLD}${RED}WARNING: This will remove all ${APP} data${NC}"
  echo
  echo "  The following will be deleted:"
  echo "    • Configuration: ${CONF_DIR}"
  echo "    • Logs:         ${LOG}"
  echo "    • DNS records:  local records for the domain"
  echo "    • Certificate:  /etc/pihole/tls.pem"
  echo "    • Timers:       systemd timers for renewal & gravity"
  echo "    • Pi-hole domain: reset to pi.hole"
  echo
  ask_yesno "Continue with uninstall?" "n" _CONFIRM
  if [[ "$_CONFIRM" != "true" ]]; then
    echo "  Cancelled."
    exit 0
  fi

  # Remove DNS records
  if [[ -f /etc/pihole/custom.list ]]; then
    local domain; domain="$(cfg_get domain '' 2>/dev/null || true)"
    if [[ -n "$domain" ]]; then
      sed -i "/[[:space:]]${domain}$/d" /etc/pihole/custom.list
      ok "Removed DNS records for $domain"
    fi
  fi

  # Reset Pi-hole domain back to pi.hole
  local pihole_toml="/etc/pihole/pihole.toml"
  if [[ -f "$pihole_toml" ]]; then
    # Use sed to safely replace only the domain line in [webserver] section
    sed -i 's/^\s*domain\s*=.*/  domain = "pi.hole"/' "$pihole_toml" 2>/dev/null || true
    ok "Reset Pi-hole domain to pi.hole"
  fi

  # Disable and remove timers
  if command -v systemctl >/dev/null 2>&1; then
    for timer in "${APP}.timer" "${APP}-renew.timer" "pihole-gravity-easy.timer" \
                 "pihole-peer-sync.timer" "pihole-easy-encrypt.timer" \
                 "pihole-easy-encrypt-renew.timer"; do
      systemctl disable --now "$timer" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/${APP}*
    rm -f /etc/systemd/system/pihole-gravity-easy*
    rm -f /etc/systemd/system/pihole-peer-sync*
    rm -f /etc/systemd/system/pihole-easy-encrypt*
    systemctl daemon-reload 2>/dev/null || true
    ok "Removed systemd timers"
  fi

  rm -f "/usr/local/sbin/${APP}" 2>/dev/null || true

  # Remove certificate
  rm -f /etc/pihole/tls.pem

  # Remove logs
  rm -f "$LOG"

  # Remove configuration
  rm -rf "$CONF_DIR"

  echo
  echo "${GREEN}${BOLD}Uninstall complete${NC}"
  echo
  info "To reload Pi-hole DNS:"
  echo "  pihole reloaddns"
  echo
}

print_help() {
  cat << 'HELP'

  pihole-easy-acme - Simple Let's Encrypt automation for Pi-hole

  USAGE:
    sudo pihole-easy-acme [option]

  OPTIONS:
    (no option)      Run setup wizard and maintenance menu
    --renew          Check and renew certificate if needed (used by timer)
    --gravity          Update Pi-hole gravity database (used by timer)
    --sync-peers       Sync DNS records from peer Pi-hole (used by timer)
    --ssh-setup        Set up / repair SSH sync key on peer
    --reset-key        Regenerate SSH sync key
    --fix-dns          Re-create local DNS A record (IPv4 only)
    --https-test       Test TLS + HTTP redirect enforcement
    --audit-keys       Show SSH authorized_keys (local + peer)
    --clean-keys       Remove stale SSH keys from peer
    --clean-old        Remove legacy pihole-easy-encrypt timers
    --uninstall      Remove all data and uninstall the script
    --help, -h       Show this help message

HELP
}

# ============================================================
#  Main program
# ============================================================

main() {
  case "${1:-}" in
    --help|-h)    print_help; exit 0 ;;
    --renew)      as_root; lock; ensure_dirs; auto_renew;   exit 0 ;;
    --gravity)       as_root; lock; ensure_dirs; auto_gravity;        exit 0 ;;
    --sync-peers)    as_root; lock; ensure_dirs; auto_sync_peers;     exit 0 ;;
    --ssh-setup)     as_root; ensure_dirs; run_ssh_setup;             exit 0 ;;
    --reset-key)     as_root; ensure_dirs; reset_sync_key;            exit 0 ;;
    --fix-dns)       as_root; add_local_dns_ipv4_only "$(cfg_get domain)"; exit 0 ;;
    --https-test)    test_https_enforcement "$(cfg_get domain)";      exit 0 ;;
    --audit-keys)    audit_ssh_keys;                                  exit 0 ;;
    --clean-keys)    as_root; cleanup_peer_ssh_keys; cleanup_local_root_keys; exit 0 ;;
    --clean-old)     as_root; cleanup_old_timers;                     exit 0 ;;
    --uninstall)  as_root; uninstall; exit 0 ;;
    *)            if [[ -n "${1:-}" ]]; then echo "Unknown option: $1"; echo; print_help; exit 1; fi ;;
  esac

  as_root; lock; ensure_dirs
  need_cmd curl; need_cmd python3; need_cmd openssl; need_cmd flock

  # Show uninstall option if previous install detected
  if [[ -f "$CONF_FILE" && -s "$CONF_FILE" ]]; then
    header
    echo "  Previous installation detected."
    echo ""
    echo "  1) Start/continue Pi-hole Easy ACME"
    echo "  2) Uninstall Pi-hole Easy ACME"
    echo "  3) Exit"
    echo
    while :; do
      printf "  Select an option [1]: " >/dev/tty
      IFS= read -r menu_choice </dev/tty || true
      menu_choice="${menu_choice:-1}"
      case "$menu_choice" in
        1) break ;;
        2) uninstall; exit 0 ;;
        3) echo "  Exiting."; exit 0 ;;
        *) echo "  Invalid option." ;;
      esac
    done
  fi

  if [[ "$(cfg_get setup_done false)" != "true" ]]; then
    run_setup
  fi

  maintenance_menu
}

main "$@"
