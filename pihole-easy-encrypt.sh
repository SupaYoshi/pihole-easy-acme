#!/usr/bin/env bash
# =============================================================================
#  Pi-hole Easy Encrypt  v3.1
#  Wizard: beantwoord 10 vragen → automatisch HTTPS + Let's Encrypt
# =============================================================================
set -Eeuo pipefail

APP="pihole-easy-encrypt"
VERSION="3.1"
CONF_DIR="/etc/${APP}"
CONF_FILE="${CONF_DIR}/config"
TOKEN_FILE="${CONF_DIR}/cloudflare.token"
LOG="/var/log/${APP}.log"
LOG_MAX_LINES=5000          # log roteren boven dit aantal regels
GRAVITY_LOG="/var/log/pihole-gravity.log"
LOCK_FILE="/run/${APP}.lock"
DEFAULT_RENEW_DAYS=30
CA_PROD="letsencrypt"
CA_STAGING="letsencrypt_test"
MAX_TOKEN_ATTEMPTS=3
ACME_SH="/root/.acme.sh/acme.sh"

# ── kleuren (alleen als terminal) ─────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'
  DIM=$'\033[2m'; NC=$'\033[0m'
else
  RED="" GREEN="" YELLOW="" CYAN="" BLUE="" BOLD="" DIM="" NC=""
fi

# ── logging  (GEEN secrets in logbestand) ─────────────────────────────────────
_LOG_ACTIVE=false
_setup_logging() {
  mkdir -p "$(dirname "$LOG")"
  touch "$LOG"; chmod 600 "$LOG"
  # Roteer log als het te groot wordt
  if [[ -f "$LOG" ]]; then
    local lines; lines="$(wc -l < "$LOG" 2>/dev/null || echo 0)"
    if (( lines > LOG_MAX_LINES )); then
      local bak="${LOG}.$(date +%Y%m%d-%H%M%S).old"
      mv "$LOG" "$bak"
      touch "$LOG"; chmod 600 "$LOG"
      echo "[$(date -Is)] Log geroteerd — oud log: $bak" >> "$LOG"
    fi
  fi
  exec > >(tee -a "$LOG") 2>&1
  _LOG_ACTIVE=true
}

_ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()   { echo "[$(_ts)] $*" >> "$LOG" 2>/dev/null || true; }
die()   {
  echo >/dev/tty
  echo "${RED}${BOLD}  ✗ FOUT:${NC}${BOLD} $*${NC}" >/dev/tty
  echo
  log "FOUT: $*"
  exit 1
}
warn()  { echo "${YELLOW}  ⚠  $*${NC}"; log "WARN: $*"; }
ok()    { echo "${GREEN}  ✓ $*${NC}"; log "OK:   $*"; }
info()  { echo "${CYAN}  → $*${NC}"; log "INFO: $*"; }
step()  {
  echo >/dev/tty
  echo "${BOLD}${CYAN}  [$1/10] $2${NC}" >/dev/tty
  printf '%s' "${DIM}  " >/dev/tty; printf '─%.0s' {1..48} >/dev/tty; printf '%s\n' "${NC}" >/dev/tty
  log "STAP $1: $2"
}

# ── CTRL+C / cleanup ─────────────────────────────────────────────────────────
_CLEANUP_FILES=()
_interrupted=false

_cleanup() {
  local sig="${1:-EXIT}"
  # Verwijder tijdelijke bestanden
  for f in "${_CLEANUP_FILES[@]+"${_CLEANUP_FILES[@]}"}"; do
    [[ -f "$f" ]] && rm -f "$f" 2>/dev/null || true
  done
  # Verwijder onvolledige config.tmp als die nog bestaat
  [[ -f "${CONF_FILE}.tmp" ]] && rm -f "${CONF_FILE}.tmp" 2>/dev/null || true
  if [[ "$sig" == "INT" || "$sig" == "TERM" ]]; then
    echo >/dev/tty
    echo >/dev/tty
    echo "${YELLOW}${BOLD}  ⚠  Onderbroken door gebruiker.${NC}" >/dev/tty
    echo "${DIM}  Voortgang is opgeslagen tot het laatste voltooide stap.${NC}" >/dev/tty
    echo >/dev/tty
    log "Script onderbroken door gebruiker (SIG${sig})"
    exit 130
  fi
}

trap '_cleanup INT'  INT
trap '_cleanup TERM' TERM
trap '_cleanup EXIT' EXIT

# ── locking ──────────────────────────────────────────────────────────────────
_LOCKED=false
lock() {
  command -v flock >/dev/null 2>&1 || die "flock ontbreekt (installeer util-linux)."
  exec 9>"$LOCK_FILE"
  flock -n 9 2>/dev/null || die "Er draait al een instantie van ${APP}."
  _LOCKED=true
}

# ── rechten + mappen ─────────────────────────────────────────────────────────
as_root()    { [[ $EUID -eq 0 ]] || die "Draai dit script als root:\n  sudo ${APP}"; }
need_cmd()   { command -v "$1" >/dev/null 2>&1 || die "Vereist programma ontbreekt: $1\n  Installeer het met: apt install $1"; }

ensure_dirs() {
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  [[ -f "$CONF_FILE" ]] || touch "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

# ── configuratie r/w ─────────────────────────────────────────────────────────
cfg_set() {
  local k="${1:?}" v="${2:-}"
  ensure_dirs
  local tmp; tmp="${CONF_FILE}.tmp.$$"
  _CLEANUP_FILES+=("$tmp")
  grep -v "^${k}=" "$CONF_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
}

cfg_get() {
  local k="${1:?}" def="${2:-}"
  [[ -f "$CONF_FILE" ]] || { echo "$def"; return; }
  local val
  val="$(grep "^${k}=" "$CONF_FILE" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)"
  echo "${val:-$def}"
}

# ── invoer helpers ────────────────────────────────────────────────────────────
ask() {
  local prompt="$1" default="${2:-}" var="${3:-_ASK_RESULT}"
  local val=""
  [[ -n "$default" ]] \
    && printf '\n  %s [%s]: ' "$prompt" "$default" >/dev/tty \
    || printf '\n  %s: ' "$prompt" >/dev/tty
  IFS= read -r val </dev/tty 2>/dev/null || { val=""; }
  val="${val:-$default}"
  # Verwijder leading/trailing whitespace
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf -v "$var" '%s' "$val"
}

ask_secret() {
  local prompt="$1" var="${2:-_SECRET_RESULT}"
  local val=""
  printf '\n  %s: ' "$prompt" >/dev/tty
  IFS= read -rs val </dev/tty 2>/dev/null || { val=""; }
  printf '\n' >/dev/tty
  printf -v "$var" '%s' "$val"
}

ask_yesno() {
  local prompt="$1" default="${2:-j}" var="${3:-_YN_RESULT}"
  local val="" J N
  [[ "$default" == "j" ]] && J="J" N="n" || { J="j"; N="N"; }
  while :; do
    printf '\n  %s [%s/%s]: ' "$prompt" "$J" "$N" >/dev/tty
    IFS= read -r val </dev/tty 2>/dev/null || { val="$default"; }
    val="${val:-$default}"
    val="${val,,}"
    case "$val" in
      j|ja|y|yes) printf -v "$var" 'true';  return 0 ;;
      n|nee|no)   printf -v "$var" 'false'; return 0 ;;
      *)
        printf '  %s\n' "${YELLOW}Voer j of n in.${NC}" >/dev/tty
        ;;
    esac
  done
}

# Keuze uit numeriek menu: ask_menu "1" var 3   (3 = max keuze)
ask_menu() {
  local default="$1" var="$2" max="$3"
  local val=""
  while :; do
    ask "Keuze" "$default" val
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= max )); then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    printf '  %s\n' "${YELLOW}Voer een getal in tussen 1 en ${max}.${NC}" >/dev/tty
  done
}

pause() {
  printf '\n  %s' "${DIM}Druk op Enter om door te gaan...${NC}" >/dev/tty
  IFS= read -r _ </dev/tty 2>/dev/null || true
}

# ── validatie helpers ─────────────────────────────────────────────────────────
is_valid_domain() {
  local d="${1,,}"
  # Eenvoudige FQDN check: minimaal één punt, alleen geldige tekens, max 253 chars
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^([a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || return 1
}

is_valid_email() {
  [[ "${1:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

# ── spinner voor lange acties ─────────────────────────────────────────────────
_SPINNER_PID=""
spinner_start() {
  [[ -t 1 ]] || return 0
  local msg="${1:-Bezig...}"
  ( local i=0; local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    while :; do
      printf '\r  %s %s  ' "${CYAN}${frames[$i]}${NC}" "$msg" >/dev/tty
      i=$(( (i+1) % ${#frames[@]} ))
      sleep 0.1
    done
  ) &
  _SPINNER_PID=$!
  disown "$_SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
  [[ -n "$_SPINNER_PID" ]] || return 0
  kill "$_SPINNER_PID" 2>/dev/null || true
  wait "$_SPINNER_PID" 2>/dev/null || true
  _SPINNER_PID=""
  printf '\r%s\r' "$(printf ' %.0s' {1..60})" >/dev/tty
}

# ── header ────────────────────────────────────────────────────────────────────
header() {
  clear 2>/dev/null || true
  printf '\n'
  printf '%s\n' "${CYAN}${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
  printf '%s\n' "${CYAN}${BOLD}  ║         Pi-hole Easy Encrypt  v${VERSION}                ║${NC}"
  printf '%s\n' "${CYAN}${BOLD}  ║    Automatisch HTTPS voor je Pi-hole dashboard       ║${NC}"
  printf '%s\n' "${CYAN}${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
  printf '\n'
}

# =============================================================================
#  Cloudflare API helpers
# =============================================================================

read_token() {
  [[ -f "$TOKEN_FILE" ]] || die "Geen token gevonden.\n  Draai: sudo ${APP}  en kies 'Setup opnieuw uitvoeren'."
  CF_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  [[ -n "${CF_TOKEN:-}" ]] || die "Token-bestand is leeg. Verwijder ${TOKEN_FILE} en draai setup opnieuw."
}

_cf_curl() {
  local method="$1" endpoint="$2" data="${3:-}"
  local args=(-fsSL --connect-timeout 10 --max-time 30
    -H "Authorization: Bearer ${CF_TOKEN}"
    -H "Content-Type: application/json"
    -X "$method")
  [[ -n "$data" ]] && args+=(--data "$data")
  curl "${args[@]}" "https://api.cloudflare.com/client/v4${endpoint}" 2>/dev/null || true
}

cf_api()      { _cf_curl GET    "$1"; }
cf_api_post() { _cf_curl POST   "$1" "$2"; }
cf_api_put()  { _cf_curl PUT    "$1" "$2"; }
cf_api_del()  { _cf_curl DELETE "$1"; }

cf_verify_token() {
  local out; out="$(cf_api "/user/tokens/verify" 2>/dev/null || true)"
  python3 - "$out" <<'PY'
import json, sys
try:
    j = json.loads(sys.argv[1])
    ok = bool(j.get("success"))
    status = ((j.get("result") or {}).get("status") or "").lower()
    sys.exit(0 if ok and status == "active" else 1)
except Exception:
    sys.exit(1)
PY
}

cf_get_zones() {
  local page=1 all='[]'
  while :; do
    local out; out="$(cf_api "/zones?status=active&per_page=50&page=${page}")"
    [[ -n "$out" ]] || break
    all="$(python3 - <<PY
import json, sys
try:
    a = json.loads($(printf '%q' "$all"))
    b = json.loads($(printf '%q' "$out")).get("result") or []
    print(json.dumps(a + b))
except Exception as e:
    sys.stderr.write(str(e)+"\n")
    print($(printf '%q' "$all"))
PY
)"
    local pages; pages="$(python3 - <<PY
import json, sys
try:
    j = json.loads($(printf '%q' "$out"))
    print((j.get("result_info") or {}).get("total_pages") or 1)
except Exception:
    print(1)
PY
)"
    (( page++ )); [[ "$page" -le "$pages" ]] || break
  done
  echo "$all"
}

cf_find_zone() {
  python3 - "$1" "$2" <<'PY'
import json, sys
domain = sys.argv[1].lower().rstrip(".")
try:
    zones = json.loads(sys.argv[2])
except Exception:
    sys.exit(0)
best = None
for z in zones:
    name = (z.get("name") or "").lower().rstrip(".")
    if not name:
        continue
    if domain == name or domain.endswith("." + name):
        if best is None or len(name) > len(best[1]):
            best = (z["id"], name)
if best:
    print(best[0] + "\t" + best[1])
PY
}

cf_dns_get_id() {
  local out; out="$(cf_api "/zones/${1}/dns_records?type=${2}&name=${3}")"
  python3 - "$out" <<'PY'
import json, sys
try:
    res = json.loads(sys.argv[1] or "{}").get("result") or []
    print(res[0].get("id", "") if res else "")
except Exception:
    print("")
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
  local result
  if [[ -n "$id" ]]; then
    result="$(cf_api_put "/zones/${zone_id}/dns_records/${id}" "$payload")"
    ok "Cloudflare ${type} bijgewerkt: ${name} → ${content}"
  else
    result="$(cf_api_post "/zones/${zone_id}/dns_records" "$payload")"
    ok "Cloudflare ${type} aangemaakt: ${name} → ${content}"
  fi
  # Controleer success veld
  python3 - "$result" <<'PY' || warn "Cloudflare API meldt geen succes — controleer de response in het log."
import json, sys
try:
    j = json.loads(sys.argv[1] or "{}")
    sys.exit(0 if j.get("success") else 1)
except Exception:
    sys.exit(1)
PY
}

cf_dns_delete() {
  local zone_id="$1" type="$2" name="$3"
  local id; id="$(cf_dns_get_id "$zone_id" "$type" "$name")"
  [[ -n "$id" ]] || return 0
  cf_api_del "/zones/${zone_id}/dns_records/${id}" >/dev/null
  info "Cloudflare ${type} verwijderd: ${name}"
}

# =============================================================================
#  WAN IP detectie
# =============================================================================

get_wan_ipv4() {
  local ip="" url
  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.co/ip"; do
    ip="$(curl -fsSL --max-time 6 --ipv4 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  done
  return 1
}

get_wan_ipv6() {
  local ip="" url
  for url in "https://api64.ipify.org" "https://ipv6.icanhazip.com"; do
    ip="$(curl -fsSL --max-time 6 --ipv6 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$ip" =~ : ]] && [[ ! "$ip" =~ ^(fc|fd|fe80|::1) ]] && { echo "$ip"; return 0; }
  done
  return 1
}

# =============================================================================
#  Pi-hole helpers
# =============================================================================

detect_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  local name
  name="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i '^pihole$' | head -1 || true)"
  [[ -n "$name" ]] && { echo "$name"; return 0; }
  # Zoek op image naam
  name="$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
    | awk 'tolower($2)~/pihole/{print $1;exit}' || true)"
  [[ -n "$name" ]] && { echo "$name"; return 0; }
  return 1
}

docker_etc_pihole() {
  local container="$1"
  local path
  path="$(docker inspect "$container" \
    --format '{{range .Mounts}}{{if eq .Destination "/etc/pihole"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null || true)"
  if [[ -z "$path" ]]; then
    warn "Geen /etc/pihole bind-mount gevonden in container '$container'."
    warn "Zorg dat je Docker Compose een volume heeft: /etc/pihole:/etc/pihole"
    return 1
  fi
  echo "$path"
}

pihole_domain_from_toml() {
  local toml="/etc/pihole/pihole.toml"
  [[ -f "$toml" ]] || { echo ""; return; }
  if python3 -c "import tomllib" >/dev/null 2>&1; then
    python3 - "$toml" <<'PY' 2>/dev/null || true
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
print((data.get("webserver", {}).get("domain", "")).strip())
PY
  else
    grep -E '^\s*domain\s*=' "$toml" 2>/dev/null | head -1 \
      | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true
  fi
}

cert_expiry() {
  [[ -f "$1" ]] || { echo "ontbreekt"; return; }
  openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "onbekend"
}

cert_days_left() {
  [[ -f "$1" ]] || { echo "-1"; return; }
  local end_epoch now_epoch
  end_epoch="$(openssl x509 -in "$1" -noout -enddate 2>/dev/null \
    | sed 's/notAfter=//' | python3 -c "
import sys, datetime, time
from email.utils import parsedate_to_datetime
try:
    d = parsedate_to_datetime(sys.stdin.read().strip())
    print(int(d.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo "0")"
  now_epoch="$(date +%s)"
  echo $(( (end_epoch - now_epoch) / 86400 ))
}

cert_expires_within() {
  [[ -f "$1" ]] || return 0
  openssl x509 -in "$1" -noout -checkend "$(( $2 * 86400 ))" >/dev/null 2>&1 && return 1 || return 0
}

# =============================================================================
#  acme.sh installatie + certificaat
# =============================================================================

install_acme() {
  [[ -x "$ACME_SH" ]] && return 0
  info "acme.sh installeren..."
  local email; email="$(cfg_get email "admin@$(cfg_get zone)")"
  spinner_start "acme.sh downloaden..."
  if ! curl -fsSL https://get.acme.sh | sh -s email="$email" >/dev/null 2>&1; then
    spinner_stop
    die "acme.sh installatie mislukt. Controleer je internet verbinding."
  fi
  spinner_stop
  [[ -x "$ACME_SH" ]] || die "acme.sh niet gevonden na installatie: ${ACME_SH}"
  ok "acme.sh geïnstalleerd."
}

do_issue() {
  local ca="$1" force="${2:-false}"; shift 2
  local domains=("$@")
  export CF_Token="${CF_TOKEN}"
  local args=(--issue --dns dns_cf --keylength ec-256 --server "$ca" --log "$LOG")
  [[ "$force" == "true" ]] && args+=(--force)
  for d in "${domains[@]}"; do args+=(-d "$d"); done

  # Stel renew-hook in zodat acme.sh het cert ook installeert bij eigen auto-renew
  local primary="${domains[-1]}"
  local hook="/usr/local/sbin/${APP} --install-cert --domain ${primary}"
  args+=(--renew-hook "$hook")

  "$ACME_SH" "${args[@]}" || {
    die "acme.sh kon geen certificaat aanvragen.\n  Controleer:\n  • Cloudflare token rechten (Zone:DNS:Edit + Zone:Zone:Read)\n  • DNS propagatie (wacht 2-5 minuten en probeer opnieuw)\n  • Let's Encrypt rate limits (max 5 per domein per week)\n  Log: ${LOG}"
  }
}

_install_cert_to_pem() {
  local dir="$1" main="$2" pem="$3"
  [[ -f "${dir}/fullchain.cer" ]] || die "Fullchain niet gevonden: ${dir}/fullchain.cer"
  [[ -f "${dir}/${main}.key" ]]  || die "Private key niet gevonden: ${dir}/${main}.key"

  local bak=""
  if [[ -f "$pem" ]]; then
    bak="${pem}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$pem" "$bak"; chmod 600 "$bak"
    ok "Backup gemaakt: $bak"
  fi

  cat "${dir}/fullchain.cer" "${dir}/${main}.key" > "$pem"
  chmod 600 "$pem"
  ok "Certificaat gecombineerd: $pem"
  echo "$bak"   # geef backup pad terug (leeg als geen backup)
}

install_cert_bare() {
  local primary="$1" main="$2"
  local dir="${ACME_SH%/*}/${main}_ecc"
  local bak; bak="$(_install_cert_to_pem "$dir" "$main" "/etc/pihole/tls.pem")"
  chown pihole:pihole /etc/pihole/tls.pem 2>/dev/null || true

  command -v pihole-FTL >/dev/null 2>&1 && {
    pihole-FTL --config webserver.domain        "$primary"            >/dev/null 2>&1 || true
    pihole-FTL --config webserver.tls.cert      "/etc/pihole/tls.pem" >/dev/null 2>&1 || true
  }

  if systemctl restart pihole-FTL >/dev/null 2>&1; then
    ok "pihole-FTL herstart."
  else
    warn "Herstart mislukt — rollback..."
    if [[ -n "$bak" && -f "$bak" ]]; then
      cp "$bak" /etc/pihole/tls.pem 2>/dev/null || true
    fi
    systemctl restart pihole-FTL >/dev/null 2>&1 || true
    die "Pi-hole kon niet herstarten na certificaatinstallatie.\n  Controleer: journalctl -u pihole-FTL --no-pager -n 30"
  fi
}

install_cert_docker() {
  local container="$1" primary="$2" main="$3"
  local host_etc; host_etc="$(docker_etc_pihole "$container")" || die "Docker bind-mount niet gevonden."
  local dir="${ACME_SH%/*}/${main}_ecc"
  local pem="${host_etc}/tls.pem"
  mkdir -p "$host_etc"; chmod 700 "$host_etc"

  _install_cert_to_pem "$dir" "$main" "$pem" >/dev/null

  docker exec "$container" pihole-FTL --config webserver.domain        "$primary"            >/dev/null 2>&1 || true
  docker exec "$container" pihole-FTL --config webserver.tls.cert      "/etc/pihole/tls.pem" >/dev/null 2>&1 || true

  if docker restart "$container" >/dev/null 2>&1; then
    ok "Container herstart: $container"
  else
    die "Docker container kon niet herstarten: $container\n  Controleer: docker logs $container"
  fi
}

# =============================================================================
#  Cloudflare DNS sync
# =============================================================================

sync_dns() {
  [[ "$(cfg_get dns_sync false)" == "true" ]] || return 0
  local zone_id; zone_id="$(cfg_get zone_id)"
  local primary;  primary="$(cfg_get primary)"
  [[ -n "$zone_id" && -n "$primary" ]] || { warn "DNS sync: zone of domein ontbreekt in config."; return 0; }

  info "Cloudflare DNS bijwerken voor: $primary"
  spinner_start "WAN IP ophalen..."
  local wan4="" wan6=""
  wan4="$(get_wan_ipv4 || true)"
  wan6="$(get_wan_ipv6 || true)"
  spinner_stop

  if [[ -n "$wan4" ]]; then
    cf_dns_upsert "$zone_id" "A" "$primary" "$wan4" "false" "120"
  else
    warn "Geen publiek IPv4 gevonden — A-record ongewijzigd."
  fi

  if [[ -n "$wan6" ]]; then
    cf_dns_upsert "$zone_id" "AAAA" "$primary" "$wan6" "false" "120"
  else
    warn "Geen publiek IPv6 — AAAA-record wordt verwijderd."
    warn "Dit voorkomt dat Windows IPv6 prefereert boven jouw lokale IPv4."
    cf_dns_delete "$zone_id" "AAAA" "$primary"
  fi
}

# =============================================================================
#  Schedulers (systemd timers)
# =============================================================================

install_timer() {
  local name="$1" desc="$2" cmd="$3" calendar="$4"
  cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=${desc}
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=${cmd}
StandardOutput=journal
StandardError=journal
EOF
  cat > "/etc/systemd/system/${name}.timer" <<EOF
[Unit]
Description=${desc} (timer)

[Timer]
OnCalendar=${calendar}
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now "${name}.timer" >/dev/null 2>&1
  ok "Timer actief: ${name}.timer  (${calendar})"
}

setup_schedulers() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemd niet beschikbaar — geen timers ingesteld."
    return 0
  fi

  if [[ "$(cfg_get auto_renew false)" == "true" ]]; then
    install_timer "${APP}" \
      "Pi-hole Easy Encrypt certificaatvernieuwing" \
      "/usr/local/sbin/${APP} --renew" \
      "*-*-* 03:11:00"
  fi

  if [[ "$(cfg_get auto_gravity false)" == "true" ]]; then
    local calendar="*-*-* 03:17:00"
    [[ "$(cfg_get gravity_schedule daily)" == "weekly" ]] && calendar="Sun *-*-* 03:17:00"
    install_timer "pihole-gravity-easy" \
      "Pi-hole adlist update (gravity)" \
      "/usr/local/sbin/${APP} --gravity" \
      "$calendar"
  fi
}

# =============================================================================
#  Certificaat aanvragen — complete flow
# =============================================================================

do_certificate() {
  local force="${1:-false}"
  read_token

  local domain;     domain="$(cfg_get domain)"
  local primary;    primary="$(cfg_get primary "$domain")"
  local zone;       zone="$(cfg_get zone)"
  local zone_id;    zone_id="$(cfg_get zone_id)"
  local mode;       mode="$(cfg_get mode bare)"
  local container;  container="$(cfg_get container)"
  local wildcard;   wildcard="$(cfg_get wildcard false)"
  local staging;    staging="$(cfg_get staging false)"
  local renew_days; renew_days="$(cfg_get renew_days "$DEFAULT_RENEW_DAYS")"

  [[ -n "$domain"  ]] || die "Geen domein geconfigureerd. Draai setup opnieuw."
  [[ -n "$zone_id" ]] || die "Geen Cloudflare zone ID. Draai setup opnieuw."

  # Bepaal PEM locatie
  local pem="/etc/pihole/tls.pem"
  if [[ "$mode" == "docker" ]]; then
    local host_etc; host_etc="$(docker_etc_pihole "$container")" || die "Docker bind-mount niet gevonden."
    pem="${host_etc}/tls.pem"
  fi

  # Vervaldatum controle
  if [[ "$force" != "true" ]]; then
    local days_left; days_left="$(cert_days_left "$pem")"
    if (( days_left > renew_days )); then
      ok "Certificaat verloopt over ${days_left} dagen — geen actie nodig."
      ok "Vervaldatum: $(cert_expiry "$pem")"
      return 0
    fi
    if (( days_left > 0 )); then
      info "Certificaat verloopt over ${days_left} dagen — vernieuwen..."
    fi
  fi

  # Stel domeinen samen
  local -a domains=()
  if [[ "$wildcard" == "true" ]]; then
    domains=("$zone" "*.${zone}")
    [[ "$domain" != "$zone" ]] && domains+=("$domain")
  else
    domains=("$domain")
  fi

  local ca="$CA_PROD"
  [[ "$staging" == "true" ]] && ca="$CA_STAGING" && warn "Staging modus — geen echt certificaat!"

  install_acme
  echo
  info "Certificaat aanvragen voor: ${domains[*]}"
  do_issue "$ca" "$force" "${domains[@]}"

  local main="${domains[0]}"
  if [[ "$mode" == "docker" ]]; then
    local host_etc; host_etc="$(docker_etc_pihole "$container")"
    install_cert_docker "$container" "$primary" "$main"
  else
    install_cert_bare "$primary" "$main"
  fi

  sync_dns
  "$ACME_SH" --install-cronjob >/dev/null 2>&1 || true

  local days_left; days_left="$(cert_days_left "$pem")"
  echo
  ok "Certificaat geldig voor ${days_left} dagen."
  ok "Vervalt op: $(cert_expiry "$pem")"
  ok "Dashboard: https://${primary}/admin"
}

# =============================================================================
#  --install-cert modus (acme.sh renew-hook)
# =============================================================================

cmd_install_cert() {
  # Opgeroepen door acme.sh renew-hook: --install-cert --domain <domain>
  local domain=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) domain="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$domain" ]] || die "--install-cert vereist --domain <domein>"

  log "acme.sh renew-hook: certificaat installeren voor $domain"
  ensure_dirs

  local mode;      mode="$(cfg_get mode bare)"
  local container; container="$(cfg_get container)"
  local primary;   primary="$(cfg_get primary "$domain")"
  local main;      main="$domain"

  if [[ "$mode" == "docker" ]]; then
    install_cert_docker "$container" "$primary" "$main"
  else
    install_cert_bare "$primary" "$main"
  fi

  sync_dns
  log "Certificaat geïnstalleerd via renew-hook voor $domain"
}

# =============================================================================
#  SETUP WIZARD — 10 stappen
# =============================================================================

run_setup() {
  header
  echo "  Dit script configureert automatisch HTTPS voor je Pi-hole"
  echo "  via Let's Encrypt en Cloudflare DNS-validatie."
  echo
  echo "  Wat je nodig hebt:"
  echo "    • Je domeinnaam staat in Cloudflare DNS"
  echo "    • Een Cloudflare API-token:"
  echo "      https://dash.cloudflare.com/profile/api-tokens"
  echo "      Rechten: Zone → DNS → Edit  +  Zone → Zone → Read"
  echo

  ask_yesno "Beginnen met de setup?" "j" _START
  [[ "$_START" == "true" ]] || { echo; info "Setup geannuleerd."; exit 0; }

  # Backup bestaande config
  if [[ -f "$CONF_FILE" ]]; then
    local cfg_bak="${CONF_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$CONF_FILE" "$cfg_bak" 2>/dev/null || true
    log "Config backup: $cfg_bak"
  fi

  # ── Stap 1: Cloudflare token ──────────────────────────────────────────────
  step 1 "Cloudflare API-token"
  echo
  echo "  Kies invoermodus:"
  echo "    1) Zichtbaar  (makkelijker plakken)"
  echo "    2) Verborgen  (veiliger)"
  echo
  local _TMODE; ask_menu "1" _TMODE 2

  local tok="" attempt=0
  while (( attempt < MAX_TOKEN_ATTEMPTS )); do
    (( attempt++ ))
    tok=""
    if [[ "$_TMODE" == "2" ]]; then
      ask_secret "Plak je Cloudflare API-token" tok
    else
      ask "Plak je Cloudflare API-token" "" tok
    fi

    if [[ -z "$tok" ]]; then
      warn "Geen token ingevoerd. Probeer opnieuw. (${attempt}/${MAX_TOKEN_ATTEMPTS})"
      continue
    fi

    # Sla op (NIET in de log)
    ensure_dirs
    umask 077
    printf '%s' "$tok" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    CF_TOKEN="$tok"

    echo
    spinner_start "Token valideren bij Cloudflare..."
    if cf_verify_token; then
      spinner_stop
      ok "Token is actief en geldig."
      break
    else
      spinner_stop
      warn "Token is ongeldig of heeft onvoldoende rechten. (${attempt}/${MAX_TOKEN_ATTEMPTS})"
      warn "Vereiste scopes: Zone → DNS → Edit  +  Zone → Zone → Read"
      (( attempt < MAX_TOKEN_ATTEMPTS )) && continue
      die "Token validatie mislukt na ${MAX_TOKEN_ATTEMPTS} pogingen."
    fi
  done

  # ── Stap 2: Domeinnaam ────────────────────────────────────────────────────
  step 2 "Domeinnaam voor Pi-hole dashboard"
  local detected; detected="$(pihole_domain_from_toml || true)"
  local domain_default=""
  if [[ -n "$detected" && "$detected" != "pi.hole" ]]; then
    domain_default="$detected"
    info "Gedetecteerd vanuit Pi-hole config: $detected"
  fi

  local DOMAIN=""
  while :; do
    ask "Domeinnaam (bijv. pihole.jouwdomein.nl)" "$domain_default" DOMAIN
    [[ -n "$DOMAIN" ]] || { warn "Vul een domeinnaam in."; continue; }
    DOMAIN="${DOMAIN,,}"
    is_valid_domain "$DOMAIN" && break
    warn "'${DOMAIN}' is geen geldig domeinnaam. Gebruik alleen letters, cijfers en koppeltekens."
  done

  # ── Stap 3: Zone detecteren ───────────────────────────────────────────────
  step 3 "Cloudflare zone detecteren"
  spinner_start "Zones ophalen uit Cloudflare..."
  local zones; zones="$(cf_get_zones)"
  spinner_stop
  local zone_line; zone_line="$(cf_find_zone "$DOMAIN" "$zones" || true)"
  if [[ -z "$zone_line" ]]; then
    die "Geen Cloudflare zone gevonden voor: ${DOMAIN}\n  Controleer:\n  • Staat het domein in jouw Cloudflare account?\n  • Heeft het token Zone:Read rechten?"
  fi
  local ZONE_ID ZONE_NAME
  ZONE_ID="$(cut -f1 <<< "$zone_line")"
  ZONE_NAME="$(cut -f2 <<< "$zone_line")"
  ok "Zone gevonden: ${BOLD}${ZONE_NAME}${NC}  ${DIM}(${ZONE_ID})${NC}"

  # ── Stap 4: Docker of bare metal ─────────────────────────────────────────
  step 4 "Pi-hole installatiemodus"
  local CONTAINER="" MODE="bare"
  local docker_found; docker_found="$(detect_docker 2>/dev/null || true)"
  if [[ -n "$docker_found" ]]; then
    info "Docker Pi-hole container gedetecteerd: ${BOLD}${docker_found}${NC}"
    ask_yesno "Pi-hole draait in Docker?" "j" _IS_DOCKER
    if [[ "$_IS_DOCKER" == "true" ]]; then
      MODE="docker"
      CONTAINER="$docker_found"
      # Controleer bind-mount direct
      if ! docker_etc_pihole "$CONTAINER" >/dev/null 2>&1; then
        warn "Geen /etc/pihole bind-mount gevonden."
        warn "Voeg toe aan docker-compose.yml:  - /etc/pihole:/etc/pihole"
        ask_yesno "Toch doorgaan in Docker-modus?" "n" _CONT_DOCKER
        [[ "$_CONT_DOCKER" == "true" ]] || { MODE="bare"; CONTAINER=""; }
      fi
      ok "Modus: ${BOLD}Docker${NC}  (container: ${CONTAINER})"
    else
      ok "Modus: ${BOLD}bare metal${NC}"
    fi
  else
    ok "Modus: ${BOLD}bare metal${NC}  (geen Docker Pi-hole gevonden)"
  fi

  # ── Stap 5: Wildcard certificaat ─────────────────────────────────────────
  step 5 "Wildcard certificaat"
  echo
  echo "  Een wildcard (*.${ZONE_NAME}) geldt voor alle subdomeinen."
  echo "  Voor alleen Pi-hole is dit niet nodig."
  echo
  ask_yesno "Wildcard certificaat aanvragen?" "n" WILDCARD

  # ── Stap 6: E-mailadres ───────────────────────────────────────────────────
  step 6 "E-mailadres (voor Let's Encrypt vervalmeldingen)"
  echo
  local EMAIL=""
  while :; do
    ask "E-mailadres (Enter = admin@${ZONE_NAME})" "" EMAIL
    if [[ -z "$EMAIL" ]]; then
      EMAIL="admin@${ZONE_NAME}"; break
    fi
    is_valid_email "$EMAIL" && break
    warn "'${EMAIL}' is geen geldig e-mailadres."
  done
  info "E-mail: $EMAIL"

  # ── Stap 7: Cloudflare DNS sync ───────────────────────────────────────────
  step 7 "Cloudflare DNS automatisch bijwerken"
  echo
  echo "  Het script stelt A/AAAA-records automatisch in op jouw WAN-IP."
  echo "  Verwijdert AAAA als je geen publiek IPv6 hebt — dit voorkomt"
  echo "  dat Windows IPv6 prefereert boven je lokale Pi-hole IP."
  echo
  ask_yesno "Cloudflare DNS automatisch bijwerken?" "j" DNS_SYNC

  # ── Stap 8: Staging modus ────────────────────────────────────────────────
  step 8 "Let's Encrypt modus"
  echo
  echo "  Staging = testmodus. Geen echt certificaat, geen rate limits."
  echo "  Aanbevolen voor je EERSTE test. Kies 'n' voor een echt certificaat."
  echo
  ask_yesno "Staging/testmodus gebruiken?" "n" STAGING

  # ── Stap 9: Automatische vernieuwing ─────────────────────────────────────
  step 9 "Automatische certificaatvernieuwing"
  echo
  echo "  Certificaten zijn 90 dagen geldig. Een dagelijkse controle"
  echo "  vernieuwt automatisch ${DEFAULT_RENEW_DAYS} dagen vóór vervaldatum."
  echo
  ask_yesno "Automatische vernieuwing instellen?" "j" AUTO_RENEW

  # ── Stap 10: Gravity updates ──────────────────────────────────────────────
  step 10 "Automatische adlist updates (gravity)"
  echo
  echo "  Houdt Pi-hole bloklijsten automatisch up-to-date."
  echo
  ask_yesno "Automatische adlist updates instellen?" "j" AUTO_GRAVITY
  local GRAVITY_SCHEDULE="daily"
  if [[ "$AUTO_GRAVITY" == "true" ]]; then
    echo
    echo "  Hoe vaak bijwerken?"
    echo "    1) Dagelijks  (aanbevolen)"
    echo "    2) Wekelijks"
    echo
    local _GS; ask_menu "1" _GS 2
    [[ "$_GS" == "2" ]] && GRAVITY_SCHEDULE="weekly"
    info "Gravity schema: $GRAVITY_SCHEDULE"
  fi

  # ── Bevestiging ───────────────────────────────────────────────────────────
  echo
  local _w="54"
  printf "%s\n" "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════════╗${NC}"
  printf "%s\n" "${BOLD}${CYAN}  ║               Jouw configuratie                     ║${NC}"
  printf "%s\n" "${BOLD}${CYAN}  ╠══════════════════════════════════════════════════════╣${NC}"
  _summary_row() { printf "  ${CYAN}║${NC}  ${BOLD}%-18s${NC} %-32s${CYAN}║${NC}\n" "$1" "$2"; }
  _summary_row "Domein:"       "$DOMAIN"
  _summary_row "Zone:"         "$ZONE_NAME"
  _summary_row "Modus:"        "$MODE${CONTAINER:+ ($CONTAINER)}"
  _summary_row "Wildcard:"     "$([[ "$WILDCARD" == "true" ]] && echo "Ja (*.${ZONE_NAME})" || echo "Nee")"
  _summary_row "Staging:"      "$([[ "$STAGING"  == "true" ]] && echo "${YELLOW}Ja (testmodus)${NC}" || echo "Nee (echt cert)")"
  _summary_row "DNS sync:"     "$([[ "$DNS_SYNC" == "true" ]] && echo "Ja" || echo "Nee")"
  _summary_row "Auto-renew:"   "$([[ "$AUTO_RENEW" == "true" ]] && echo "Ja (dagelijks)" || echo "Nee")"
  _summary_row "Gravity:"      "$([[ "$AUTO_GRAVITY" == "true" ]] && echo "Ja ($GRAVITY_SCHEDULE)" || echo "Nee")"
  printf "%s\n" "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════════╝${NC}"
  echo

  ask_yesno "Alles klopt — starten met installatie?" "j" _CONFIRM
  [[ "$_CONFIRM" == "true" ]] || { echo; info "Installatie geannuleerd."; exit 0; }

  # ── Config opslaan ────────────────────────────────────────────────────────
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
  cfg_set setup_done       "true"

  # ── Installatie ───────────────────────────────────────────────────────────
  echo
  printf '%s\n' "${BOLD}  ═══ Installatie gestart ═══${NC}"
  echo
  do_certificate "true"
  setup_schedulers

  # ── Klaar ─────────────────────────────────────────────────────────────────
  echo
  printf '%s\n' "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
  printf '%s\n' "${GREEN}${BOLD}  ║            ✓  Setup voltooid!                       ║${NC}"
  printf '%s\n' "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
  echo
  printf '  Dashboard:     %s\n' "${BOLD}https://${DOMAIN}/admin${NC}"
  printf '  Vervalt op:    %s\n' "$(cert_expiry /etc/pihole/tls.pem)"
  printf '  Log:           %s\n' "$LOG"
  [[ "$AUTO_RENEW"   == "true" ]] && printf '  Renew timer:   dagelijks 03:11\n'
  [[ "$AUTO_GRAVITY" == "true" ]] && printf '  Gravity timer: %s 03:17\n' "$GRAVITY_SCHEDULE"
  echo
  log "Setup voltooid voor $DOMAIN"
  pause
}

# =============================================================================
#  Onderhoudsmenu
# =============================================================================

maintenance_menu() {
  while :; do
    header

    # Status balk
    local domain; domain="$(cfg_get domain '(niet ingesteld)')"
    local mode;   mode="$(cfg_get mode bare)"
    local pem="/etc/pihole/tls.pem"
    [[ "$mode" == "docker" ]] && {
      local cont; cont="$(cfg_get container)"
      local he; he="$(docker_etc_pihole "$cont" 2>/dev/null || true)"
      [[ -n "$he" ]] && pem="${he}/tls.pem"
    }
    local days_left; days_left="$(cert_days_left "$pem" 2>/dev/null || echo "-1")"
    local expiry_str; expiry_str="$(cert_expiry "$pem")"
    local cert_color="$GREEN"
    (( days_left < 14 )) && cert_color="$RED"
    (( days_left >= 14 && days_left < 30 )) && cert_color="$YELLOW"

    printf '  Domein:  %s\n'  "${BOLD}${domain}${NC}"
    if (( days_left >= 0 )); then
      printf '  Cert:    %s  %s\n' "${cert_color}${expiry_str}${NC}" "${DIM}(${days_left} dagen)${NC}"
    else
      printf '  Cert:    %s\n' "${RED}${expiry_str}${NC}"
    fi
    printf '  Modus:   %s\n' "$mode"
    echo

    echo "  1) Certificaat vernieuwen   (alleen als bijna verlopen)"
    echo "  2) Certificaat forceren     (nu opnieuw aanvragen)"
    echo "  3) Cloudflare DNS bijwerken"
    echo "  4) Pi-hole bijwerken        (pihole -up)"
    echo "  5) Gravity uitvoeren        (adlists nu vernieuwen)"
    echo "  6) Status / diagnose"
    echo "  7) Setup opnieuw uitvoeren"
    echo
    echo "  0) Afsluiten"
    echo

    local c; ask "Keuze" "" c
    echo

    case "$c" in
      1)
        read_token
        do_certificate "false" || true
        ;;
      2)
        read_token
        do_certificate "true" || true
        ;;
      3)
        read_token
        sync_dns || true
        ;;
      4)
        warn "Pi-hole updates kunnen FTL of de config breken."
        warn "Maak eerst een Teleporter-backup via https://${domain}/admin"
        echo
        ask_yesno "Toch doorgaan?" "n" _UPD
        [[ "$_UPD" == "true" ]] || { info "Geannuleerd."; pause; continue; }
        if [[ "$mode" == "docker" ]]; then
          local _cont; _cont="$(cfg_get container)"
          local _img; _img="$(docker inspect "$_cont" --format '{{.Config.Image}}' 2>/dev/null || true)"
          [[ -n "$_img" ]] || die "Kan image niet bepalen voor container: $_cont"
          info "Docker image pullen: $_img"
          docker pull "$_img"
          docker restart "$_cont" >/dev/null 2>&1
          ok "Container bijgewerkt en herstart."
        else
          pihole -up
        fi
        ;;
      5)
        info "Gravity uitvoeren..."
        if [[ "$mode" == "docker" ]]; then
          docker exec "$(cfg_get container)" pihole -g 2>&1 | tee -a "$GRAVITY_LOG"
        else
          pihole -g 2>&1 | tee -a "$GRAVITY_LOG"
        fi
        ok "Gravity voltooid."
        ;;
      6)
        echo
        printf '  %-22s %s\n' "Domein:"       "$(cfg_get domain '(leeg)')"
        printf '  %-22s %s\n' "Zone:"         "$(cfg_get zone  '(leeg)')"
        printf '  %-22s %s\n' "Modus:"        "$(cfg_get mode  'bare')"
        [[ "$(cfg_get mode)" == "docker" ]] && \
          printf '  %-22s %s\n' "Container:" "$(cfg_get container)"
        printf '  %-22s %s\n' "Wildcard:"     "$(cfg_get wildcard false)"
        printf '  %-22s %s\n' "DNS sync:"     "$(cfg_get dns_sync false)"
        printf '  %-22s %s\n' "Auto-renew:"   "$(cfg_get auto_renew false)"
        printf '  %-22s %s\n' "Gravity:"      "$(cfg_get auto_gravity false) / $(cfg_get gravity_schedule daily)"
        printf '  %-22s %s  %s\n' "Cert vervalt:" "$expiry_str" "(${days_left} dagen)"
        printf '  %-22s %s\n' "Config:"       "$CONF_FILE"
        printf '  %-22s %s\n' "Log:"          "$LOG"
        echo
        if command -v systemctl >/dev/null 2>&1; then
          echo "  Actieve timers:"
          systemctl list-timers --no-pager 2>/dev/null \
            | grep -E "pihole|${APP}" | sed 's/^/    /' \
            || echo "    (geen)"
        fi
        echo
        echo "  Certificaat details:"
        if [[ -f "$pem" ]]; then
          openssl x509 -in "$pem" -noout -subject -issuer -dates 2>/dev/null \
            | sed 's/^/    /' || true
        else
          echo "    (certificaat niet gevonden op $pem)"
        fi
        ;;
      7)
        ask_yesno "Setup opnieuw uitvoeren? (huidige config wordt gebackupt)" "j" _RESET
        [[ "$_RESET" == "true" ]] || { pause; continue; }
        cfg_set setup_done "false"
        run_setup
        return 0
        ;;
      0)
        info "Tot ziens."
        exit 0
        ;;
      "")
        continue
        ;;
      *)
        warn "Ongeldige keuze: '${c}'. Voer 0–7 in."
        ;;
    esac
    pause
  done
}

# =============================================================================
#  Non-interactieve modi (systemd timers)
# =============================================================================

cmd_auto_renew() {
  _setup_logging
  log "Auto-renew gestart"
  ensure_dirs
  if ! do_certificate "false"; then
    log "Auto-renew mislukt"
    exit 1
  fi
  log "Auto-renew klaar"
}

cmd_auto_gravity() {
  _setup_logging
  log "Gravity gestart"
  ensure_dirs
  local mode; mode="$(cfg_get mode bare)"
  local cont; cont="$(cfg_get container)"
  if [[ "$mode" == "docker" && -n "$cont" ]]; then
    docker exec "$cont" pihole -g >> "$GRAVITY_LOG" 2>&1 || { log "Gravity mislukt (docker)"; exit 1; }
  else
    pihole -g >> "$GRAVITY_LOG" 2>&1 || { log "Gravity mislukt"; exit 1; }
  fi
  log "Gravity klaar"
}

# =============================================================================
#  Help
# =============================================================================

show_help() {
  echo
  echo "${BOLD}Pi-hole Easy Encrypt v${VERSION}${NC}"
  echo
  echo "  Gebruik: sudo ${APP} [optie]"
  echo
  echo "  Zonder optie:  setup-wizard (eerste keer) of onderhoudsmenu"
  echo
  echo "  Opties:"
  echo "    --renew              Vernieuw certificaat indien nodig (voor systemd)"
  echo "    --gravity            Voer gravity uit (voor systemd)"
  echo "    --install-cert       Installeer cert na acme.sh auto-renew"
  echo "      --domain <fqdn>    Domein voor --install-cert"
  echo "    --version            Toon versie"
  echo "    --help               Toon deze hulp"
  echo
  echo "  Bestanden:"
  echo "    Config:  ${CONF_FILE}"
  echo "    Token:   ${TOKEN_FILE}"
  echo "    Log:     ${LOG}"
  echo
}

# =============================================================================
#  Hoofdprogramma
# =============================================================================

main() {
  case "${1:-}" in
    --help|-h)
      show_help; exit 0 ;;
    --version|-v)
      echo "${APP} v${VERSION}"; exit 0 ;;
    --renew)
      as_root; lock; _setup_logging; need_cmd curl; need_cmd python3; need_cmd openssl
      cmd_auto_renew; exit 0 ;;
    --gravity)
      as_root; lock; _setup_logging
      cmd_auto_gravity; exit 0 ;;
    --install-cert)
      shift
      as_root; lock; _setup_logging; ensure_dirs
      cmd_install_cert "$@"; exit 0 ;;
  esac

  as_root
  lock
  _setup_logging
  ensure_dirs
  need_cmd curl
  need_cmd python3
  need_cmd openssl

  log "Script gestart (v${VERSION}) door $(id -un 2>/dev/null || echo root)"

  if [[ "$(cfg_get setup_done false)" != "true" ]]; then
    run_setup
  else
    maintenance_menu
  fi
}

main "$@"
