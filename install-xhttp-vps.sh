#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 yazmann
set -Eeuo pipefail

# Universal unattended 3x-ui VPN server / remote-node installer for a fresh Ubuntu VPS.
# The script is interactive only during the initial questionnaire.
# Independent automation project; not affiliated with or endorsed by 3x-ui,
# XTLS/Xray or Cloudflare. Third-party names remain their owners' property.
# See THIRD_PARTY_NOTICES.md in the project repository.

green='\033[1;32m'; yellow='\033[1;33m'; red='\033[1;31m'; cyan='\033[1;36m'; blue='\033[1;34m'; plain='\033[0m'
CURRENT_STEP='startup'
INSTALLATION_STARTED=0
RECOVERY_SCRIPT='/root/finish-xhttp-vps.sh'
log() { CURRENT_STEP="$*"; printf '\n%b[%s]%b %b%s%b\n' "$blue" "$(date +'%H:%M:%S')" "$plain" "$cyan" "$*" "$plain"; }
warn() { printf '\n%bWARNING%b %s\n' "$yellow" "$plain" "$*" >&2; }
recovery_hint() {
  local solution="${1:-}"
  if [[ -n "$solution" ]]; then
    printf '%bSuggested solution:%b %s\n' "$yellow" "$plain" "$solution" >&2
  elif [[ "$INSTALLATION_STARTED" == 1 ]]; then
    printf '%bSuggested solution:%b Fix the reason above, then run: %s\n' "$yellow" "$plain" "$RECOVERY_SCRIPT" >&2
  else
    printf '%bSuggested solution:%b Fix the reason above, then start this installer again. No existing service was changed automatically.\n' "$yellow" "$plain" >&2
  fi
}
die() {
  local reason="$1" solution="${2:-}"
  printf '\n%b================================================================%b\n' "$red" "$plain" >&2
  printf '%bINSTALLATION STOPPED%b\n' "$red" "$plain" >&2
  printf '%bReason:%b %s\n' "$red" "$plain" "$reason" >&2
  printf '%bCurrent step:%b %s\n' "$yellow" "$plain" "$CURRENT_STEP" >&2
  recovery_hint "$solution"
  printf '%b================================================================%b\n' "$red" "$plain" >&2
  exit 1
}
unexpected_error() {
  local exit_code="$1" line="$2"
  printf '\n%b================================================================%b\n' "$red" "$plain" >&2
  printf '%bUNEXPECTED INSTALLATION ERROR%b\n' "$red" "$plain" >&2
  printf '%bStep:%b %s\n' "$yellow" "$plain" "$CURRENT_STEP" >&2
  printf '%bTechnical detail:%b command failed near line %s (exit code %s).\n' "$yellow" "$plain" "$line" "$exit_code" >&2
  recovery_hint
  printf '%b================================================================%b\n' "$red" "$plain" >&2
}
trap 'unexpected_error "$?" "$LINENO"' ERR

[[ ${EUID} -eq 0 ]] || die "Run as root."
MEMORY_SCRIPT="$(dirname "$(readlink -f "$0")")/optimize-xhttp-memory.sh"
[[ -r "$MEMORY_SCRIPT" ]] || die "Place optimize-xhttp-memory.sh alongside this installer."
# shellcheck source=optimize-xhttp-memory.sh
source "$MEMORY_SCRIPT"
COMMON_SCRIPT="$(dirname "$(readlink -f "$0")")/xhttp-vps-common.sh"
[[ -r "$COMMON_SCRIPT" ]] || die "Place xhttp-vps-common.sh alongside this installer."
# shellcheck source=xhttp-vps-common.sh
source "$COMMON_SCRIPT"
UDP_SCRIPT="$(dirname "$COMMON_SCRIPT")/xhttp-vps-udp.sh"
if [[ -r "$UDP_SCRIPT" ]]; then
  # shellcheck source=xhttp-vps-udp.sh
  source "$UDP_SCRIPT"
fi
MIGRATION_SCRIPT="$(dirname "$COMMON_SCRIPT")/xhttp-vps-migrate.sh"
if [[ -r "$MIGRATION_SCRIPT" ]]; then
  # shellcheck source=xhttp-vps-migrate.sh
  source "$MIGRATION_SCRIPT"
fi
xhttp_lock || die "Another setup or repair is already running."

remove_installation() {
  local script_path answer expected
  script_path="$(readlink -f "$0")"
  mapfile -t states < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
  [[ ${#states[@]} -eq 1 ]] || die "Expected one 3x-ui installer state file in /root; found ${#states[@]}."
  # shellcheck disable=SC1090
  source "${states[0]}"
  printf '%bThis permanently deletes the managed VPN installation for %s. No archive will be created.%b\n' "$yellow" "$DOMAIN" "$plain"
  expected="DELETE ${DOMAIN}"
  if ! read -r -p "Type '${expected}' to continue: " answer; then
    die "Removal cancelled: no confirmation was received."
  fi
  answer="${answer//$'\r'/}"
  [[ "$answer" == "$expected" ]] || die "Removal cancelled: confirmation did not match."
  xhttp_validate_state && [[ -f "$MANAGED_BACKUP/ready" ]] \
    || die "This installation has no valid ownership journal. Automatic removal is disabled; preserve the state and remove legacy components manually."
  xhttp_validate_ownership_journal || die "Ownership journal contains an invalid managed path or index."
  local service
  service="$(xhttp_service_name)"
  if systemctl is-active --quiet "$service"; then systemctl stop "$service"; fi
  systemctl disable "$service" 2>/dev/null || true
  systemctl disable --now xhttp-vps-cert-renew.timer 2>/dev/null || true
  if systemctl is-active --quiet xhttp-vps-cert-renew.service; then
    systemctl stop xhttp-vps-cert-renew.service
  fi
  systemctl disable --now xhttp-vps-maintenance.timer 2>/dev/null || true
  systemctl disable --now xhttp-vps-reboot.timer 2>/dev/null || true
  rm -f -- /run/xhttp-vps-maintenance.ok
  if [[ "${TRANSPORT:-}" == amneziawg && -x /usr/local/sbin/xhttp-vps-awg-firewall ]]; then
    /usr/local/sbin/xhttp-vps-awg-firewall down
  fi
  if xhttp_uses_panel && command -v fail2ban-client >/dev/null; then fail2ban-client stop xhttp-vps-panel >/dev/null 2>&1 || true; fi
  # Shared services, ACME accounts, SSH access, packages and swap are retained.
  # Delete only rules carrying this installation's unique marker.
  if command -v ufw >/dev/null; then
    xhttp_delete_firewall_rules "xhttp-vps:${SAFE_INSTANCE}"
  fi
  if [[ "${ACME_CLIENT:-}" != certbot && -x /root/.acme.sh/acme.sh ]]; then
    /root/.acme.sh/acme.sh --remove -d "$DOMAIN" || true
    /root/.acme.sh/acme.sh --remove -d "$DOMAIN" --ecc || true
  fi
  xhttp_restore_owned_files
  systemctl daemon-reload
  if command -v nginx >/dev/null && nginx -t; then systemctl reload nginx || true; fi
  if command -v fail2ban-client >/dev/null; then fail2ban-client reload >/dev/null 2>&1 || true; fi
  # Restore recorded runtime values only while they still match our settings.
  [[ "$(sysctl -n net.core.default_qdisc)" != fq ]] || sysctl -w "net.core.default_qdisc=${PREV_QDISC:-fq_codel}" >/dev/null
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" != bbr ]] || sysctl -w "net.ipv4.tcp_congestion_control=${PREV_CC:-cubic}" >/dev/null
  [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" != 1 ]] || sysctl -w "net.ipv6.conf.all.disable_ipv6=${PREV_IPV6_ALL:-0}" >/dev/null
  [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6)" != 1 ]] || sysctl -w "net.ipv6.conf.default.disable_ipv6=${PREV_IPV6_DEFAULT:-0}" >/dev/null
  [[ "$(sysctl -n net.ipv6.conf.lo.disable_ipv6)" != 1 ]] || sysctl -w "net.ipv6.conf.lo.disable_ipv6=${PREV_IPV6_LO:-0}" >/dev/null
  if [[ "${DISABLE_PING:-0}" == 1 && "$(sysctl -n net.ipv4.icmp_echo_ignore_all)" == 1 ]]; then
    sysctl -w "net.ipv4.icmp_echo_ignore_all=${PREV_IPV4_ECHO_IGNORE:-0}" >/dev/null
  fi
  if [[ "${TRANSPORT:-}" == amneziawg && "$(sysctl -n net.ipv4.ip_forward)" == 1 ]]; then
    sysctl -w "net.ipv4.ip_forward=${PREV_IPV4_FORWARD:-0}" >/dev/null
  fi
  sysctl --system >/dev/null || true
  rm -f -- "${states[0]}" /root/finish-xhttp-vps.sh /root/xhttp-vps-common.sh /root/optimize-xhttp-memory.sh \
    /root/xhttp-vps-udp.sh /root/xhttp-vps-migrate.sh
  printf '%s\n' 'Removal completed without an archive. Packages, swap, the current SSH policy, the SSH firewall rule and the shared ACME client were retained.'
  [[ "$script_path" != /root/install-xhttp-vps.sh ]] || rm -f -- "$script_path"
}

show_current_settings() {
  local state_file
  mapfile -t states < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
  [[ ${#states[@]} -eq 1 ]] || die "No completed installation managed by this script was found."
  state_file="${states[0]}"
  # shellcheck disable=SC1090
  source "$state_file"
  [[ -n "${RESULT_FILE:-}" && -r "$RESULT_FILE" ]] \
    || die "The saved result file is not available. Re-run the installer only if you need to create a new installation."
  clear || true
  printf '%b================================================================%b\n' "$green" "$plain"
  printf '%b                    CURRENT SERVER SETTINGS%b\n' "$green" "$plain"
  printf '%b================================================================%b\n\n' "$green" "$plain"
  cat -- "$RESULT_FILE"
  printf '\n%b================================================================%b\n' "$green" "$plain"
  printf '%bThe settings are stored in:%b %s\n' "$cyan" "$plain" "$RESULT_FILE"
  printf '%b================================================================%b\n' "$green" "$plain"
  exit 0
}

RESUMING=0
REPAIRING_UDP=0
if [[ "${1:-}" == --resume ]]; then
  RESUMING=1
  mapfile -t RESUME_STATES < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
  [[ ${#RESUME_STATES[@]} == 1 ]] || die "Expected one state file for resume."
  # shellcheck disable=SC1090
  source "${RESUME_STATES[0]}"
  STATE_FILE="${RESUME_STATES[0]}"
  # Older interrupted states predate selectable panel exposure and previously
  # expected a public listener. Preserve that behavior rather than guessing a
  # trusted source address during unattended resume.
  : "${PANEL_ACCESS_MODE:=public}"
  : "${PANEL_ALLOWED_IP:=}"
  : "${TRANSPORT:=xhttp}"
  if xhttp_uses_panel; then : "${INBOUND_TAG:=$(xhttp_inbound_tag_for "$TRANSPORT")}"; fi
  : "${UDP_PORT:=}" "${HY_PASSWORD:=}"
  : "${ACME_CLIENT:=acme.sh}"
  : "${TLS_MODE:=production}"
  : "${MIGRATION_DB:=}" "${MIGRATION_INBOUND:=}"
  : "${SUB_ENCRYPT_LINKS:=}"
  : "${MAINTENANCE_TIMEZONE:=Europe/Moscow}"
  : "${MAINTENANCE_MODE:=weekly}"
  : "${TWO_FACTOR_GUIDE:=0}"
  : "${SSH_HARDENING:=0}"
  if [[ -z "${SSH_ACCESS_MODE:-}" ]]; then
    if [[ "$SSH_HARDENING" == 1 ]]; then SSH_ACCESS_MODE='admin'; else SSH_ACCESS_MODE='existing'; fi
  fi
  : "${ADMIN_USER:=root}"
  : "${ADMIN_KEYS_B64:=}"
  : "${ADMIN_KEY_FINGERPRINTS:=}"
  : "${NODE_API_TOKEN:=}"
  xhttp_validate_state && [[ -f "$MANAGED_BACKUP/ready" ]] || die "Resume requires the ownership journal from this installer version."
  CERT_DIR="/root/cert/$DOMAIN"
  if [[ "${INSTALL_PHASE:-bootstrap}" != bootstrap ]]; then
    if xhttp_uses_panel; then exec "$RECOVERY_SCRIPT"; fi
    if [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" && -s /var/www/3xui-cover/index.html ]]; then
      REPAIRING_UDP=1
    fi
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  UBUNTU_VERSION="$VERSION_ID"
else
HAS_CURRENT_SETTINGS=0
mapfile -t MENU_STATE_FILES < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
if [[ ${#MENU_STATE_FILES[@]} -eq 1 ]]; then
  # shellcheck disable=SC1090
  source "${MENU_STATE_FILES[0]}"
  if [[ "${INSTALL_PHASE:-}" == complete && -n "${RESULT_FILE:-}" && -r "$RESULT_FILE" ]]; then
    HAS_CURRENT_SETTINGS=1
  fi
fi

printf '\nVPN VPS Setup\n\n'
if [[ ${#MENU_STATE_FILES[@]} -eq 1 ]]; then
  if [[ "$HAS_CURRENT_SETTINGS" -eq 1 ]]; then
    printf 'Existing installation:\n1) Show current settings (default)\n2) Verify and repair\n3) Permanently remove VPN (no archive)\n4) Refresh automatic maintenance\n5) Export an encrypted recovery backup\n0) Exit\n'
    read -rp "Select [1]: " ACTION
    ACTION="${ACTION:-1}"
    case "$ACTION" in
      1) show_current_settings ;;
      2) [[ -x "$RECOVERY_SCRIPT" ]] || die "Recovery script is missing: ${RECOVERY_SCRIPT}"; exec "$RECOVERY_SCRIPT" ;;
      3) remove_installation; exit 0 ;;
      4)
        : "${TRANSPORT:=xhttp}" "${MAINTENANCE_MODE:=weekly}" "${MAINTENANCE_TIMEZONE:=Europe/Moscow}"
        log 'Refreshing the saved automatic-update policy'
        xhttp_configure_automatic_updates && xhttp_verify_automatic_updates || die 'Could not refresh automatic maintenance.'
        if [[ "$COMMON_SCRIPT" != /root/xhttp-vps-common.sh ]]; then
          install -m 700 "$COMMON_SCRIPT" /root/xhttp-vps-common.sh
        fi
        printf 'Automatic maintenance: %s\n' "$(xhttp_maintenance_label "$MAINTENANCE_MODE")"
        exit 0
        ;;
      5)
        xhttp_validate_state || die 'Could not validate the installation state.'
        xhttp_export_recovery_backup "${MENU_STATE_FILES[0]}" || die 'Encrypted backup was not created.'
        exit 0
        ;;
      0) exit 0 ;;
      *) die "Unknown menu item: $ACTION" ;;
    esac
  else
    printf 'Interrupted installation:\n1) Continue and repair (default)\n2) Permanently remove VPN (no archive)\n0) Exit\n'
    read -rp "Select [1]: " ACTION
    ACTION="${ACTION:-1}"
    case "$ACTION" in
      1) exec "$(readlink -f "$0")" --resume ;;
      2) remove_installation; exit 0 ;;
      0) exit 0 ;;
      *) die "Unknown menu item: $ACTION" ;;
    esac
  fi
elif [[ ${#MENU_STATE_FILES[@]} -gt 1 ]]; then
  die "Multiple installer state files were found in /root. Resolve them manually before continuing."
else
  printf 'New VPS:\n1) Install standalone VPN (default)\n2) Install remote node\n3) Install standalone VPN and import VLESS users from a 3x-ui SQLite backup\n0) Exit\n'
  read -rp "Select [1]: " ACTION
  ACTION="${ACTION:-1}"
  MIGRATION_DB=''
  MIGRATION_INBOUND=''
  case "$ACTION" in
    1) INSTALL_MODE="standalone" ;;
    2) INSTALL_MODE="node" ;;
    3)
      INSTALL_MODE=standalone
      [[ -r "$MIGRATION_SCRIPT" ]] || die "Place xhttp-vps-migrate.sh alongside this installer."
      read -rp "Path to the source 3x-ui SQLite backup: " MIGRATION_DB
      MIGRATION_DB="$(realpath -e -- "$MIGRATION_DB")" || die "SQLite backup does not exist."
      [[ -f "$MIGRATION_DB" && -r "$MIGRATION_DB" ]] || die "SQLite backup is not a readable file."
      ;;
    0) exit 0 ;;
    *) die "Unknown menu item: $ACTION" ;;
  esac
fi

TLS_MODE="production"
if [[ "${1:-}" == --staging ]]; then TLS_MODE=staging; fi
ACME_CLIENT=certbot
printf '%bTLS:%b %s (required).\n' "$cyan" "$plain" "$(xhttp_tls_label)"

[[ -r /etc/os-release ]] || die "Cannot identify the operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "A fresh Ubuntu VPS is required. Found: ${ID:-unknown}."
UBUNTU_VERSION="${VERSION_ID:-unknown}"
case "$UBUNTU_VERSION" in
  22.04*|24.04*|26.04*) ;;
  *)
    if [[ "$UBUNTU_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] && dpkg --compare-versions "$UBUNTU_VERSION" ge 22.04; then
      warn "Ubuntu ${UBUNTU_VERSION} is newer or non-LTS and has not been explicitly tested; package availability will be checked."
    else
      die "Supported Ubuntu releases start at 22.04. Found: ${UBUNTU_VERSION}"
    fi
    ;;
esac
command -v systemctl >/dev/null || die "systemd is required."
case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64|armv7l|s390x) ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac
mapfile -t EXISTING_STATES < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
if ((${#EXISTING_STATES[@]} > 0)); then
  if ((${#EXISTING_STATES[@]} == 1)); then
    # shellcheck disable=SC1090
    source "${EXISTING_STATES[0]}"
    if [[ "${INSTALL_PHASE:-}" == "bootstrap" ]]; then
      exec "$(readlink -f "$0")" --resume
    fi
  fi
  die "This VPS already has an installation managed by this script. Select menu item 3 to remove it, or run /root/finish-xhttp-vps.sh to repair an interrupted installation."
fi
[[ ! -e /etc/x-ui/x-ui.db && ! -x /usr/local/x-ui/x-ui ]] \
  || die "3x-ui is already installed. To protect the existing panel, this installer will not overwrite it. Use a fresh VPS or remove the existing panel first."
[[ ! -e /root/.acme.sh ]] \
  || die "An existing /root/.acme.sh installation was found. Use a fresh VPS; this installer will not execute or overwrite an unverified ACME client."
[[ ! -e /etc/ssh/sshd_config.d/00-xhttp-vps-hardening.conf && ! -e /etc/sudoers.d/90-xhttp-vps-admin ]] \
  || die "Existing xhttp-vps SSH hardening files were found. Review them manually before using this fresh-server installer."
if command -v nginx >/dev/null || \
  dpkg-query -W -f='${db:Status-Status}\n' nginx 2>/dev/null | grep -qx 'installed' || \
  [[ -x /usr/local/nginx/sbin/nginx ]]; then
  die "Nginx is already installed. To protect the existing website configuration, use a fresh VPS for this installer."
fi
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  die "UFW is already active. To avoid changing an existing firewall policy, use a fresh VPS or disable and document the current rules before installation."
fi
if command -v ufw >/dev/null && ufw show added | grep -q '^ufw '; then
  die "UFW has pre-existing rules, even though it is inactive. Use a VPS without a configured firewall policy."
fi

read -rp "Domain already pointed to this VPS (example: vpn.example.com): " DOMAIN
# SSH/terminal paste can add a UTF-8 BOM, spaces or a carriage return. They are
# not part of a domain, so remove only these accidental boundary characters.
DOMAIN="${DOMAIN//$'\r'/}"
DOMAIN="${DOMAIN#$'\ufeff'}"
DOMAIN="${DOMAIN#"${DOMAIN%%[![:space:]]*}"}"
DOMAIN="${DOMAIN%"${DOMAIN##*[![:space:]]}"}"
DOMAIN="${DOMAIN,,}"
if ! [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
  printf -v SHOWN_DOMAIN '%q' "$DOMAIN"
  die "Invalid domain input: ${SHOWN_DOMAIN}. Enter a domain such as vpn.example.com (Latin letters, digits, hyphens and dots only)."
fi
[[ ${#DOMAIN} -le 253 ]] || die "Domain is longer than the DNS limit (253 characters)."
IFS='.' read -r -a DOMAIN_LABELS <<<"$DOMAIN"
for DOMAIN_LABEL in "${DOMAIN_LABELS[@]}"; do
  [[ ${#DOMAIN_LABEL} -le 63 ]] || die "A DNS label in the domain is longer than 63 characters."
done

DEFAULT_INSTANCE="$(hostname -s | tr -cd 'A-Za-z0-9_-')"
INSTANCE_NAME="${DEFAULT_INSTANCE:-$([[ "$INSTALL_MODE" == "standalone" ]] && echo VPN1 || echo NODE1)}"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  DEFAULT_VPN_NAME="${DOMAIN%%.*} VPN"
  NAME_LABEL="VPN name"
  read -rp "VPN name shown in subscriptions [${DEFAULT_VPN_NAME}]: " VPN_NAME
else
  DEFAULT_VPN_NAME="${DOMAIN%%.*} Node"
  NAME_LABEL="Node name"
  read -rp "Node name shown in the local 3x-ui panel [${DEFAULT_VPN_NAME}]: " VPN_NAME
fi
VPN_NAME="${VPN_NAME:-$DEFAULT_VPN_NAME}"
[[ ${#VPN_NAME} -ge 1 && ${#VPN_NAME} -le 64 ]] || die "${NAME_LABEL} must contain 1-64 characters."
if LC_ALL=C grep -q '[[:cntrl:]]' <<<"$VPN_NAME"; then die "${NAME_LABEL} contains control characters."; fi

printf '%s\n' 'VPN transport:' '  1) Vision (default), TCP/443' '  2) XHTTP, TCP/443'
if [[ "$INSTALL_MODE" == standalone && -z "$MIGRATION_DB" ]]; then
  printf '%s\n' '  3) AmneziaWG, UDP' '  4) Hysteria 2, UDP/443'
fi
read -rp "Select transport [1]: " TRANSPORT_CHOICE
case "${TRANSPORT_CHOICE:-1}" in
  1) TRANSPORT=vision ;;
  2) TRANSPORT=xhttp ;;
  3) TRANSPORT=amneziawg ;;
  4) TRANSPORT=hysteria2 ;;
  *) die "Unknown transport choice: ${TRANSPORT_CHOICE}" ;;
esac
if ! xhttp_uses_panel; then
  [[ "$INSTALL_MODE" != node ]] || die "Remote nodes require Vision or XHTTP."
  [[ -z "$MIGRATION_DB" ]] || die "3x-ui client import requires Vision or XHTTP."
fi
UDP_PORT=''
HY_PASSWORD=''
INBOUND_TAG=''
PANEL_ACCESS_MODE=''
PANEL_ALLOWED_IP=''
TWO_FACTOR_GUIDE=0
PANEL_2FA_ENROLL=0
ENABLE_WARP=0
SUB_ENCRYPT_LINKS=''
SUB_PROFILE_MODE=''
SUB_PRIVACY_HEADERS=''
if xhttp_uses_panel; then
INBOUND_TAG="$(xhttp_inbound_tag_for "$TRANSPORT")"
cat <<'EOF'
Panel access:
  1) Public Internet
     Open the panel from any device.
  2) Trusted IPv4 only
     For a fixed administrator or main-panel IP.
  3) Localhost only (default)
     Connect through an SSH tunnel or Tailscale.
EOF
read -rp "Select panel access [3]: " PANEL_ACCESS_CHOICE
PANEL_ACCESS_CHOICE="${PANEL_ACCESS_CHOICE:-3}"
PANEL_ALLOWED_IP=""
case "$PANEL_ACCESS_CHOICE" in
  1)
    PANEL_ACCESS_MODE="public"
    warn "Public access selected. Keep the full panel URL private; 2FA is recommended for public access."
    ;;
  2)
    PANEL_ACCESS_MODE="allowlist"
    read -rp "Trusted public IPv4 allowed to reach the panel: " PANEL_ALLOWED_IP
    xhttp_valid_ipv4 "$PANEL_ALLOWED_IP" || die "Invalid trusted IPv4: ${PANEL_ALLOWED_IP}."
    ;;
  3) PANEL_ACCESS_MODE="private" ;;
  *) die "Unknown panel access choice: ${PANEL_ACCESS_CHOICE}" ;;
esac

read -rp 'Enable 3x-ui two-factor authentication during setup (requires an authenticator app)? [y/N]: ' TWO_FACTOR_CHOICE
case "${TWO_FACTOR_CHOICE,,}" in
  ''|n|no) PANEL_2FA_ENROLL=0 ;;
  y|yes) PANEL_2FA_ENROLL=1 ;;
  *) die 'Enter yes or no for 3x-ui two-factor authentication.' ;;
esac

if [[ "$INSTALL_MODE" == standalone ]]; then
  read -rp "Generate encrypted HAPP and INCY subscription links? [Y/n]: " ENCRYPT_LINKS_CHOICE
  case "${ENCRYPT_LINKS_CHOICE,,}" in
    ''|y|yes) SUB_ENCRYPT_LINKS=true ;;
    n|no) SUB_ENCRYPT_LINKS=false ;;
    *) die "Enter yes or no for encrypted subscription links." ;;
  esac
fi

printf '%s\n' 'The built-in profile page can expose subscription URLs and server settings to its visitors.'
read -rp 'Advertise the built-in subscription profile page? [y/N]: ' PROFILE_PAGE_CHOICE
case "${PROFILE_PAGE_CHOICE,,}" in
  ''|n|no) SUB_PROFILE_MODE=none ;;
  y|yes) SUB_PROFILE_MODE=builtin ;;
  *) die 'Enter yes or no for the subscription profile page.' ;;
esac
read -rp 'Disable caching and referrer sharing for subscription responses? [Y/n]: ' SUB_PRIVACY_CHOICE
case "${SUB_PRIVACY_CHOICE,,}" in
  ''|y|yes) SUB_PRIVACY_HEADERS=true ;;
  n|no) SUB_PRIVACY_HEADERS=false ;;
  *) die 'Enter yes or no for subscription privacy headers.' ;;
esac

read -rp "Use Cloudflare WARP as an extra exit for Russian resources (domains and IPs)? [Y/n]: " WARP_ANSWER
WARP_ANSWER="${WARP_ANSWER//$'\r'/}"
WARP_ANSWER="${WARP_ANSWER#$'\ufeff'}"
# Keep only an ASCII yes/no answer. This makes paste artefacts harmless.
WARP_ANSWER="$(LC_ALL=C tr -cd '[:alpha:]' <<<"$WARP_ANSWER")"
WARP_ANSWER="${WARP_ANSWER,,}"
case "${WARP_ANSWER:-y}" in
  y|yes) ENABLE_WARP=1 ;;
  n|no) ENABLE_WARP=0 ;;
  *)
    printf -v SHOWN_WARP_ANSWER '%q' "$WARP_ANSWER"
    die "Expected yes/y or no/n for Cloudflare WARP routing; received ${SHOWN_WARP_ANSWER}. Press Enter for yes."
    ;;
esac
else
  [[ -r "$UDP_SCRIPT" ]] || die "Place xhttp-vps-udp.sh alongside this installer."
  case "$TRANSPORT" in
    amneziawg)
      [[ ! -e /etc/amnezia/amneziawg/awg-vps.conf && ! -e /etc/xhttp-vps-awg ]] || die "An unmanaged AmneziaWG configuration already exists."
      UDP_PORT="$(xhttp_udp_random_port)" || die "Could not select a free UDP port."
      ;;
    hysteria2)
      [[ ! -e /etc/xhttp-vps-hysteria.yaml && ! -e /etc/systemd/system/xhttp-vps-hysteria.service && ! -e /usr/local/bin/xhttp-vps-hysteria ]] || die "An unmanaged Hysteria configuration already exists."
      UDP_PORT=443
      HY_PASSWORD="$(random_hex 32)"
      ;;
  esac
  xhttp_udp_port_busy "$UDP_PORT" && die "UDP/${UDP_PORT} is already occupied."
fi

cat <<'EOF'
Cover-site design:
  1) Automatic (stable selection based on domain)
  2) Engineering consultancy
  3) Digital infrastructure
  4) Logistics and operations
  5) Architecture studio
  6) Industrial service
EOF
read -rp "Select cover design [1]: " COVER_CHOICE
COVER_CHOICE="${COVER_CHOICE:-1}"
if [[ "$COVER_CHOICE" == 1 ]]; then
  COVER_STYLE=$(( $(printf '%s' "$DOMAIN" | cksum | awk '{print $1}') % 5 + 2 ))
else
  COVER_STYLE="$COVER_CHOICE"
fi
[[ "$COVER_STYLE" =~ ^[2-6]$ ]] || die "Unknown cover design: ${COVER_CHOICE}"
case "$COVER_STYLE" in
  2) COVER_LABEL="Engineering consultancy" ;;
  3) COVER_LABEL="Digital infrastructure" ;;
  4) COVER_LABEL="Logistics and operations" ;;
  5) COVER_LABEL="Architecture studio" ;;
  6) COVER_LABEL="Industrial service" ;;
esac

PACKAGES_INSTALLED_BY_SCRIPT=""
if ! command -v curl >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  xhttp_apt_get -o APT::Update::Error-Mode=any update
  for package in ca-certificates curl; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' \
      || PACKAGES_INSTALLED_BY_SCRIPT+=" ${package}"
  done
  xhttp_apt_apply install -y --no-install-recommends ca-certificates curl
fi
PUBLIC_IP="$(curl -q -4fsS --retry 2 --retry-all-errors --connect-timeout 5 --max-time 10 https://api4.ipify.org || true)"
xhttp_valid_ipv4 "$PUBLIC_IP" || die "Could not detect a valid public IPv4."
SSH_PORT="$(awk '{print $4}' <<<"${SSH_CONNECTION:-}" 2>/dev/null || true)"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}' || true)"
fi
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22
SSH_TARGET_PORT=''
read -rp "Move SSH from port $SSH_PORT to a high port? [y/N]: " SSH_PORT_CHOICE
case "${SSH_PORT_CHOICE,,}" in
  ''|n|no) ;;
  y|yes)
    SSH_PORT_SUGGESTION="$(random_port)" || die 'Could not find a free high SSH port.'
    read -rp "High SSH port (10000–65535) [$SSH_PORT_SUGGESTION]: " SSH_TARGET_PORT
    SSH_TARGET_PORT="${SSH_TARGET_PORT:-$SSH_PORT_SUGGESTION}"
    [[ "$SSH_TARGET_PORT" =~ ^[1-9][0-9]{4}$ ]] && (( SSH_TARGET_PORT <= 65535 )) &&
      [[ "$SSH_TARGET_PORT" != "$SSH_PORT" ]] && ! port_busy "$SSH_TARGET_PORT" || die 'Choose a free high SSH port different from the current port.'
    printf 'Allow TCP/%s at your VPS provider before switching. Keep TCP/%s open until the new login is verified.\n' "$SSH_TARGET_PORT" "$SSH_PORT"
    ;;
  *) die 'Enter yes or no for the SSH port change.' ;;
esac

cat <<'EOF'
SSH access:
  1) Keep current access
     Existing root and login settings stay unchanged.
  2) Root with SSH key only
     Password login is disabled.
  3) New sudo user with SSH key
     Root and password login are disabled.
  4) New sudo user with an SSH certificate (default)
     A certificate login is tested before root and password login are disabled.
  5) Root with password
     Set a root password if necessary.
EOF
read -rp "Select SSH policy [4]: " SSH_ACCESS_CHOICE
SSH_ACCESS_CHOICE="${SSH_ACCESS_CHOICE:-4}"
case "$SSH_ACCESS_CHOICE" in
  1)
    SSH_ACCESS_MODE=existing
    SSH_HARDENING=0
    ADMIN_USER="${SUDO_USER:-root}"
    [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die 'Could not determine the current SSH administrator.'
    warn "The installer will preserve the current root and SSH authentication policy. Fail2ban reduces brute-force attempts but does not make weak credentials safe."
    ;;
  2)
    SSH_ACCESS_MODE='root-key'
    SSH_HARDENING=1
    ADMIN_USER=root
    warn "Root will remain reachable by its SSH key. Password login is disabled, but this is less safe than a separate administrator."
    ;;
  3|4)
    SSH_ACCESS_MODE='admin'
    if [[ "$SSH_ACCESS_CHOICE" == 4 ]]; then SSH_ACCESS_MODE=admin-cert; fi
    SSH_HARDENING=1
    read -rp "New administrative SSH user [vpnadmin]: " ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-vpnadmin}"
    [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] \
      || die "Administrative user must be a non-root Linux name up to 31 characters."
    getent passwd "$ADMIN_USER" >/dev/null && die "User ${ADMIN_USER} already exists; use a fresh name."
    ;;
  5)
    SSH_ACCESS_MODE='root-password'
    SSH_HARDENING=1
    ADMIN_USER=root
    warn 'Root password login selected. Use a strong unique password and restrict the source IPv4 when possible.'
    ;;
  *) die "Unknown SSH policy choice: ${SSH_ACCESS_CHOICE}" ;;
esac
ADMIN_KEYS_B64=""
ADMIN_KEY_FINGERPRINTS=""
if [[ "$SSH_ACCESS_MODE" == admin-cert ]]; then
  printf '\nOn your computer, use an existing SSH user key or create one with ssh-keygen -t ed25519.\n'
  printf '%s\n' 'Create an Ed25519 CA separately and keep its private key offline:'
  printf '%s\n' '  ssh-keygen -t ed25519 -f ~/.ssh/vps_ssh_ca'
  printf '  ssh-keygen -s ~/.ssh/vps_ssh_ca -I %s -n %s -V +30d ~/.ssh/id_ed25519.pub\n' "$ADMIN_USER" "$ADMIN_USER"
  read -rp 'Paste the CA public key (vps_ssh_ca.pub): ' SSH_CA_KEY
  [[ "$SSH_CA_KEY" != *$'\r'* && "$SSH_CA_KEY" != *$'\n'* ]] || die 'The CA public key must be one line.'
  ADMIN_KEYS_B64="$(printf '%s' "$SSH_CA_KEY" | base64 -w0)"
  xhttp_validate_ssh_ca_b64 "$ADMIN_KEYS_B64" || die 'An Ed25519 CA public key is required.'
  ADMIN_KEY_FINGERPRINTS="$(xhttp_authorized_key_fingerprints "$ADMIN_KEYS_B64")"
elif [[ "$SSH_ACCESS_MODE" == admin || "$SSH_ACCESS_MODE" == root-key ]]; then
  if [[ -s /root/.ssh/authorized_keys ]]; then
    read -rp "Reuse the current root authorized_keys for ${ADMIN_USER}? [Y/n]: " REUSE_KEYS
    REUSE_KEYS="${REUSE_KEYS//$'\r'/}"
    REUSE_KEYS="${REUSE_KEYS,,}"
    case "${REUSE_KEYS:-y}" in
      y|yes) ADMIN_KEYS_B64="$(base64 -w0 /root/.ssh/authorized_keys)" ;;
      n|no) ;;
      *) die "Expected yes/y or no/n when selecting the SSH key source." ;;
    esac
  fi
  if [[ -z "$ADMIN_KEYS_B64" ]]; then
    read -rp "Paste one SSH public key for ${ADMIN_USER}: " ADMIN_PUBLIC_KEY
    [[ "$ADMIN_PUBLIC_KEY" != *$'\r'* && "$ADMIN_PUBLIC_KEY" != *$'\n'* ]] \
      || die "SSH public key must be one line without control characters."
    ADMIN_KEYS_B64="$(printf '%s\n' "$ADMIN_PUBLIC_KEY" | base64 -w0)"
  fi
  xhttp_validate_authorized_keys_b64 "$ADMIN_KEYS_B64" \
    || die "The selected authorized_keys data does not contain a valid SSH public key."
  ADMIN_KEY_FINGERPRINTS="$(xhttp_authorized_key_fingerprints "$ADMIN_KEYS_B64")"
fi

read -rp 'Restrict SSH to this trusted IPv4 (leave blank for unrestricted source IPs): ' SSH_ALLOWED_IP
if [[ -n "$SSH_ALLOWED_IP" ]]; then
  xhttp_valid_ipv4 "$SSH_ALLOWED_IP" || die 'Enter one valid IPv4 address or leave the field blank.'
  if [[ -n "${SSH_CONNECTION:-}" && "${SSH_CONNECTION%% *}" != "$SSH_ALLOWED_IP" ]]; then
    die "The current SSH connection is from ${SSH_CONNECTION%% *}. Use the provider console or reconnect from $SSH_ALLOWED_IP before selecting this restriction."
  fi
fi

read -rp 'Disable IPv4 ping replies (keep other ICMP messages)? [y/N]: ' PING_CHOICE
case "${PING_CHOICE,,}" in
  ''|n|no) DISABLE_PING=0 ;;
  y|yes) DISABLE_PING=1 ;;
  *) die 'Enter yes or no for ping replies.' ;;
esac

cat <<'EOF'
Automatic maintenance:
  1) Scheduled updates and conditional reboot (default)
     Security updates every day at 05:30. Full updates and cleanup on Sundays at 05:30.
     Reboot after maintenance if required.
  2) Security updates only
     Installed daily at 05:30 without automatic reboot.
  3) No automatic updates
     Updates and reboot are performed manually.
EOF
read -rp "Select maintenance [1]: " MAINTENANCE_CHOICE
MAINTENANCE_CHOICE="${MAINTENANCE_CHOICE:-1}"
MAINTENANCE_TIMEZONE=Europe/Moscow
case "$MAINTENANCE_CHOICE" in
  1) MAINTENANCE_MODE=weekly ;;
  2) MAINTENANCE_MODE=security ;;
  3) MAINTENANCE_MODE=none ;;
  *) die "Unknown maintenance choice: ${MAINTENANCE_CHOICE}" ;;
esac
if [[ "$MAINTENANCE_MODE" != none ]]; then
  read -rp "Timezone for scheduled maintenance at 05:30 [Europe/Moscow]: " MAINTENANCE_TIMEZONE
  MAINTENANCE_TIMEZONE="${MAINTENANCE_TIMEZONE:-Europe/Moscow}"
  [[ "$MAINTENANCE_TIMEZONE" =~ ^([A-Za-z0-9_+-]+/)*[A-Za-z0-9_+-]+$ && -f "/usr/share/zoneinfo/$MAINTENANCE_TIMEZONE" ]] \
    || die "Unknown IANA timezone: ${MAINTENANCE_TIMEZONE}. Example: Europe/Moscow or Etc/UTC."
fi
read -rp 'Export an encrypted recovery backup after setup? [y/N]: ' BACKUP_CHOICE
case "${BACKUP_CHOICE,,}" in
  ''|n|no) CREATE_RECOVERY_BACKUP=0 ;;
  y|yes) CREATE_RECOVERY_BACKUP=1 ;;
  *) die 'Enter yes or no for the encrypted recovery backup.' ;;
esac


PANEL_PORT=''
SUB_PORT=''
FALLBACK_PORT=''
PANEL_PATH=''
SUB_PATH=''
PANEL_USERNAME=''
PANEL_PASSWORD=''
PANEL_API_TOKEN=''
NODE_API_TOKEN=''
CLIENT_UUID=''
CLIENT_SUB_ID=''
CLIENT_EMAIL=''
SUB_JSON_PATH=''
SUB_CLASH_PATH=''
MIHOMO_ROUTING_PATH=''
if xhttp_uses_panel; then
while :; do PANEL_PORT="$(random_port)"; [[ "$PANEL_PORT" != "$SSH_TARGET_PORT" ]] && break; done
while :; do SUB_PORT="$(random_port)"; [[ "$SUB_PORT" != "$PANEL_PORT" && "$SUB_PORT" != "$SSH_TARGET_PORT" ]] && break; done
while :; do FALLBACK_PORT="$(random_port)"; [[ "$FALLBACK_PORT" != "$PANEL_PORT" && "$FALLBACK_PORT" != "$SUB_PORT" && "$FALLBACK_PORT" != "$SSH_TARGET_PORT" ]] && break; done
PANEL_PATH="panel-$(random_hex 16)"
SUB_PATH="feed-$(random_hex 10)"
SUB_JSON_PATH=""
SUB_CLASH_PATH=""
MIHOMO_ROUTING_PATH=""
if [[ "$INSTALL_MODE" == "standalone" ]]; then PANEL_USERNAME="vpn$(random_hex 4)"; else PANEL_USERNAME="node$(random_hex 4)"; fi
PANEL_PASSWORD="$(random_hex 18)"
PANEL_API_TOKEN=""
NODE_API_TOKEN=""
CLIENT_UUID=""
CLIENT_SUB_ID=""
CLIENT_EMAIL=""
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  CLIENT_UUID="$(cat /proc/sys/kernel/random/uuid)"
  CLIENT_SUB_ID="$(random_hex 8)"
  CLIENT_EMAIL="${INSTANCE_NAME}-primary"
  if [[ -n "$MIGRATION_DB" ]]; then CLIENT_EMAIL="probe-$(random_hex 8)-primary"; fi
  SUB_JSON_PATH="json-$(random_hex 10)"
  SUB_CLASH_PATH="mihomo-$(random_hex 10)"
  MIHOMO_ROUTING_PATH="mihomo-routing-$(random_hex 10).yaml"
fi
fi
SAFE_INSTANCE="$(printf '%s' "$INSTANCE_NAME" | tr -cs 'A-Za-z0-9_-' '_')"
if [[ "$INSTALL_MODE" == "node" ]]; then
  STATE_FILE="/root/3xui-node-${SAFE_INSTANCE}.env"
else
  STATE_FILE="/root/3xui-vps-${SAFE_INSTANCE}.env"
fi
RESULT_FILE="/root/xhttp-vps-result-${SAFE_INSTANCE}.txt"
CERT_DIR="/root/cert/${DOMAIN}"
PREV_QDISC="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo fq_codel)"
PREV_CC="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo cubic)"
PREV_IPV6_ALL="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
PREV_IPV6_DEFAULT="$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null || echo 0)"
PREV_IPV6_LO="$(cat /proc/sys/net/ipv6/conf/lo/disable_ipv6 2>/dev/null || echo 0)"
PREV_IPV4_ECHO_IGNORE="$(sysctl -n net.ipv4.icmp_echo_ignore_all)"
PREV_IPV4_FORWARD="$(sysctl -n net.ipv4.ip_forward)"
UFW_WAS_ACTIVE=0
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  UFW_WAS_ACTIVE=1
fi
UFW_SSH_RULE_EXISTED=0
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])(${SSH_PORT}/tcp|OpenSSH)([[:space:]]|$)"; then
  UFW_SSH_RULE_EXISTED=1
fi
UFW_HTTP_RULE_EXISTED=0
UFW_HTTPS_RULE_EXISTED=0
UFW_PANEL_RULE_EXISTED=0
SWAP_CREATED_BY_SCRIPT=0
if command -v ufw >/dev/null; then
  ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])80/tcp([[:space:]]|$)" && UFW_HTTP_RULE_EXISTED=1
  ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])443/tcp([[:space:]]|$)" && UFW_HTTPS_RULE_EXISTED=1
  if [[ -n "$PANEL_PORT" ]] && ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${PANEL_PORT}/tcp([[:space:]]|$)"; then UFW_PANEL_RULE_EXISTED=1; fi
fi

fi

install_recovery_script() {
  local temporary_file source_file
  if [[ "$COMMON_SCRIPT" != /root/xhttp-vps-common.sh ]]; then
    install -m 700 "$COMMON_SCRIPT" /root/xhttp-vps-common.sh
  fi
  if [[ "$UDP_SCRIPT" != /root/xhttp-vps-udp.sh && -r "$UDP_SCRIPT" ]]; then
    install -m 700 "$UDP_SCRIPT" /root/xhttp-vps-udp.sh
  fi
  if [[ "$MIGRATION_SCRIPT" != /root/xhttp-vps-migrate.sh && -r "$MIGRATION_SCRIPT" ]]; then
    install -m 700 "$MIGRATION_SCRIPT" /root/xhttp-vps-migrate.sh
  fi
  local installer
  installer="$(readlink -f "$0")"
  if [[ "$installer" != /root/install-xhttp-vps.sh ]]; then
    install -m 700 "$installer" /root/install-xhttp-vps.sh
  fi
  temporary_file="${RECOVERY_SCRIPT}.new"
  source_file="$(dirname "$(readlink -f "$0")")/finish-xhttp-vps.sh"
  if [[ -r "$source_file" ]]; then
    if [[ "$MEMORY_SCRIPT" != /root/optimize-xhttp-memory.sh ]]; then
      install -m 700 "$MEMORY_SCRIPT" /root/optimize-xhttp-memory.sh
    fi
    install -m 700 "$source_file" "$temporary_file"
    mv -f "$temporary_file" "$RECOVERY_SCRIPT"
  else
    rm -f "$temporary_file"
    warn "Recovery script was not installed: upload finish-xhttp-vps.sh alongside this installer before starting."
  fi
}

configure_warp_swap() {
  local memory_kib free_kib
  memory_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
  if ! [[ "$memory_kib" =~ ^[0-9]+$ ]] || (( memory_kib > 1100000 )); then
    return 0
  fi
  if swapon --noheadings --show 2>/dev/null | grep -q .; then
    log "Keeping existing swap for low-memory WARP VPS"
    return 0
  fi
  if [[ -e /swapfile ]]; then
    warn "Low-memory WARP VPS has /swapfile, but it is not active. The installer will not modify an existing file."
    return 0
  fi
  free_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
  if ! [[ "$free_kib" =~ ^[0-9]+$ ]] || (( free_kib < 1310720 )); then
    warn "Low-memory WARP VPS has insufficient free disk space for the required 1 GiB swap."
    return 0
  fi
  log "Adding 1 GiB swap for low-memory WARP VPS"
  if ! fallocate -l 1G /swapfile; then
    warn "Could not allocate /swapfile; continuing without managed swap."
    return 0
  fi
  chmod 600 /swapfile
  if ! mkswap /swapfile >/dev/null; then
    rm -f /swapfile
    warn "Could not format /swapfile; continuing without managed swap."
    return 0
  fi
  if ! swapon /swapfile; then
    rm -f /swapfile
    warn "Could not enable /swapfile; continuing without managed swap."
    return 0
  fi
  if ! printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab; then
    swapoff /swapfile || die "Cannot persist or disable /swapfile. The active file has been preserved; repair /etc/fstab manually."
    rm -f /swapfile
    warn "Could not persist /swapfile in /etc/fstab; continuing without managed swap."
    return 0
  fi
  SWAP_CREATED_BY_SCRIPT=1
}

write_state() {
  local temporary_file
  temporary_file="${STATE_FILE}.new"
  umask 077
  cat > "$temporary_file" <<EOF
INSTANCE_NAME=${INSTANCE_NAME}
VPN_NAME=$(printf '%q' "$VPN_NAME")
INSTALL_MODE=${INSTALL_MODE}
TLS_MODE=${TLS_MODE}
INSTALL_PHASE=${INSTALL_PHASE:-bootstrap}
MANAGED_BACKUP=${MANAGED_BACKUP:-}
SAFE_INSTANCE=${SAFE_INSTANCE}
COVER_LABEL=$(printf '%q' "${COVER_LABEL:-Cover site}")
ACME_CLIENT=${ACME_CLIENT}
DOMAIN=${DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
PANEL_PORT=${PANEL_PORT}
PANEL_PATH=${PANEL_PATH}
PANEL_ACCESS_MODE=${PANEL_ACCESS_MODE}
PANEL_ALLOWED_IP=${PANEL_ALLOWED_IP}
TWO_FACTOR_GUIDE=${TWO_FACTOR_GUIDE}
PANEL_2FA_ENROLL=${PANEL_2FA_ENROLL:-0}
DISABLE_PING=${DISABLE_PING:-0}
TRANSPORT=${TRANSPORT}
UDP_PORT=${UDP_PORT}
HY_PASSWORD=${HY_PASSWORD}
MIGRATION_DB=$(printf '%q' "$MIGRATION_DB")
MIGRATION_INBOUND=${MIGRATION_INBOUND}
INBOUND_TAG=${INBOUND_TAG:-}
ADMIN_USER=${ADMIN_USER}
ADMIN_KEYS_B64=${ADMIN_KEYS_B64}
ADMIN_KEY_FINGERPRINTS=${ADMIN_KEY_FINGERPRINTS}
SSH_HARDENING=${SSH_HARDENING}
SSH_ACCESS_MODE=${SSH_ACCESS_MODE}
MAINTENANCE_TIMEZONE=$(printf '%q' "$MAINTENANCE_TIMEZONE")
MAINTENANCE_MODE=${MAINTENANCE_MODE}
SUB_PORT=${SUB_PORT}
SUB_PATH=${SUB_PATH}
SUB_JSON_PATH=${SUB_JSON_PATH}
SUB_CLASH_PATH=${SUB_CLASH_PATH}
SUB_ENCRYPT_LINKS=${SUB_ENCRYPT_LINKS}
SUB_PROFILE_MODE=${SUB_PROFILE_MODE:-}
SUB_PRIVACY_HEADERS=${SUB_PRIVACY_HEADERS:-}
CREATE_RECOVERY_BACKUP=${CREATE_RECOVERY_BACKUP:-0}
MIHOMO_ROUTING_PATH=${MIHOMO_ROUTING_PATH}
FALLBACK_PORT=${FALLBACK_PORT}
PANEL_USERNAME=${PANEL_USERNAME}
PANEL_PASSWORD=${PANEL_PASSWORD}
PANEL_API_TOKEN=$(printf '%q' "$PANEL_API_TOKEN")
NODE_API_TOKEN=$(printf '%q' "${NODE_API_TOKEN:-}")
CLIENT_UUID=${CLIENT_UUID}
CLIENT_SUB_ID=${CLIENT_SUB_ID}
CLIENT_EMAIL=${CLIENT_EMAIL}
REALITY_PUBLIC=${REALITY_PUBLIC:-}
SHORT_ID=${SHORT_ID:-}
ENABLE_WARP=${ENABLE_WARP}
COVER_STYLE=${COVER_STYLE}
RESULT_FILE=${RESULT_FILE}
PREV_QDISC=${PREV_QDISC}
PREV_CC=${PREV_CC}
PREV_IPV6_ALL=${PREV_IPV6_ALL}
PREV_IPV6_DEFAULT=${PREV_IPV6_DEFAULT}
PREV_IPV6_LO=${PREV_IPV6_LO}
PREV_IPV4_ECHO_IGNORE=${PREV_IPV4_ECHO_IGNORE:-0}
PREV_IPV4_FORWARD=${PREV_IPV4_FORWARD:-0}
UFW_WAS_ACTIVE=${UFW_WAS_ACTIVE}
SSH_PORT=${SSH_PORT}
SSH_TARGET_PORT=${SSH_TARGET_PORT:-}
SSH_ALLOWED_IP=${SSH_ALLOWED_IP:-}
UFW_SSH_RULE_EXISTED=${UFW_SSH_RULE_EXISTED}
UFW_HTTP_RULE_EXISTED=${UFW_HTTP_RULE_EXISTED}
UFW_HTTPS_RULE_EXISTED=${UFW_HTTPS_RULE_EXISTED}
UFW_PANEL_RULE_EXISTED=${UFW_PANEL_RULE_EXISTED}
PACKAGES_INSTALLED_BY_SCRIPT="${PACKAGES_INSTALLED_BY_SCRIPT# }"
SWAP_CREATED_BY_SCRIPT=${SWAP_CREATED_BY_SCRIPT:-0}
EOF
  chmod 600 "$temporary_file"
  mv -f "$temporary_file" "$STATE_FILE"
  INSTALLATION_STARTED=1
  install_recovery_script
  umask 022
}

if [[ "$RESUMING" == 0 ]]; then
cat <<EOF

Configuration summary
  Mode:          $([[ "$INSTALL_MODE" == "standalone" ]] && echo "standalone VPN server" || echo "node for an existing panel")
  $([[ "$INSTALL_MODE" == "standalone" ]] && echo "VPN name" || echo "Node name"):      ${VPN_NAME}
  Host name:     ${INSTANCE_NAME}
  Ubuntu:        ${UBUNTU_VERSION} ($(uname -m))
  Domain/IP:     ${DOMAIN} / ${PUBLIC_IP}
  SSH port:      ${SSH_PORT} (current Termius session preserved)
  SSH login:     ${ADMIN_USER}${ADMIN_KEY_FINGERPRINTS:+ (${ADMIN_KEY_FINGERPRINTS})}
  SSH policy:    $(xhttp_ssh_access_label "$SSH_ACCESS_MODE")
  Transport:     $(xhttp_transport_label "$TRANSPORT")
EOF
if xhttp_uses_panel; then
cat <<EOF
  Panel port:    ${PANEL_PORT}
  Panel access:  ${PANEL_ACCESS_MODE}$([[ -n "$PANEL_ALLOWED_IP" ]] && printf ' (%s only)' "$PANEL_ALLOWED_IP")
  Subscription:  ${SUB_PORT} (local only)
  Self-steal:    127.0.0.1:${FALLBACK_PORT}
  WARP for RU:   $([[ "$ENABLE_WARP" -eq 1 ]] && echo yes || echo no)
EOF
else
  printf '  VPN port:      %s/UDP\n' "$UDP_PORT"
fi
cat <<EOF
  Cover site:    ${COVER_LABEL}
  Maintenance:   $(xhttp_maintenance_label "$MAINTENANCE_MODE")
EOF
if [[ -n "${SSH_ALLOWED_IP:-}" ]]; then printf '  SSH source:    %s (UFW)\n' "$SSH_ALLOWED_IP"; fi
if [[ -n "${SSH_TARGET_PORT:-}" ]]; then printf '  New SSH port:  %s (after tested login)\n' "$SSH_TARGET_PORT"; fi
if [[ "${DISABLE_PING:-0}" == 1 ]]; then printf '  Ping replies:  disabled (IPv4 echo only)\n'; fi
if xhttp_uses_panel; then
  printf '  Profile page:  %s\n  Subscription privacy headers: %s\n' "$SUB_PROFILE_MODE" "$SUB_PRIVACY_HEADERS"
  if [[ "${PANEL_2FA_ENROLL:-0}" == 1 ]]; then printf '  Panel 2FA:     enroll during setup\n'; fi
fi
if [[ "${CREATE_RECOVERY_BACKUP:-0}" == 1 ]]; then printf '  Encrypted recovery backup: yes\n'; fi
if [[ -n "$MIGRATION_DB" ]]; then printf '  User backup:   %s\n' "$MIGRATION_DB"; fi
if [[ -n "$SUB_ENCRYPT_LINKS" ]]; then printf '  Encrypted links: %s\n' "$SUB_ENCRYPT_LINKS"; fi
read -rp "Start installation? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Cancelled."
MANAGED_BACKUP="$(mktemp -d /root/xhttp-managed.XXXXXXXX)"
[[ ! -e "/root/.acme.sh/$DOMAIN" && ! -e "/root/.acme.sh/${DOMAIN}_ecc" ]] \
  || die "An ACME certificate already exists for this domain. Use a dedicated domain."
xhttp_record_ownership
INSTALL_PHASE=bootstrap
write_state
fi
if [[ "$ACME_CLIENT" == acme.sh && ! -x /root/.acme.sh/acme.sh ]]; then
  ACME_CLIENT=certbot
  write_state
fi
xhttp_record_ownership || die "Could not validate or extend the managed-file ownership journal."

if [[ "$REPAIRING_UDP" == 1 ]]; then
  [[ -r "$UDP_SCRIPT" ]] || die "UDP transport helpers are missing."
  log "Repairing $(xhttp_transport_label "$TRANSPORT")"
  xhttp_install_nginx
  systemctl enable --now nginx
  systemctl reload nginx
  xhttp_configure_automatic_updates
  xhttp_verify_automatic_updates
  xhttp_install_cert_renewal
  xhttp_apply_ping_policy
  if [[ -n "${SSH_ALLOWED_IP:-}" ]]; then xhttp_configure_ssh_source; fi
  if [[ "$SSH_HARDENING" == 1 ]]; then xhttp_harden_sshd; fi
  xhttp_finalize_ssh_port || die 'SSH port migration did not complete. Keep this session open.'
  write_state
  xhttp_install_fail2ban_sshd
  xhttp_udp_finish
  PREVIOUS_INSTALL_PHASE="${INSTALL_PHASE:-}"
  INSTALL_PHASE=complete
  write_state
  if [[ "$PREVIOUS_INSTALL_PHASE" != complete && "${CREATE_RECOVERY_BACKUP:-0}" == 1 ]]; then
    xhttp_export_recovery_backup "$STATE_FILE" || warn 'Backup skipped. You can retry using menu item 5.'
  fi
  exit 0
fi

log "Repairing package state and fully upgrading the fresh Ubuntu system"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
xhttp_apt_get -o APT::Update::Error-Mode=any update
xhttp_repair_apt || die "Could not repair Ubuntu package dependencies. Review the APT errors above."
xhttp_apt_apply -y -o Dpkg::Options::="--force-confold" dist-upgrade
xhttp_apt_get check
[[ -z "$(dpkg --audit)" ]] || die "Ubuntu package database is not clean after the full upgrade. Review 'dpkg --audit' before retrying."
UBUNTU_UPGRADE_OK=1

log "Checking availability and installing required packages"

REQUIRED_PACKAGES=(ca-certificates cron curl fail2ban iproute2 jq nginx openssh-server openssl procps sudo tar ufw unattended-upgrades util-linux)
if xhttp_uses_panel; then REQUIRED_PACKAGES+=(socat sqlite3 unzip wget wireguard-tools); fi
if [[ "$SUB_ENCRYPT_LINKS" == true ]]; then REQUIRED_PACKAGES+=(nodejs); fi
if [[ "$ACME_CLIENT" == certbot ]]; then REQUIRED_PACKAGES+=(certbot); fi
if [[ "$TRANSPORT" == amneziawg ]]; then REQUIRED_PACKAGES+=(gnupg iptables); fi
OPTIONAL_PACKAGES=(htop lsof)
INSTALL_PACKAGES=()
MISSING_PACKAGES=()
for package in "${REQUIRED_PACKAGES[@]}"; do
  if apt-cache show "$package" >/dev/null 2>&1; then
    INSTALL_PACKAGES+=("$package")
  else
    MISSING_PACKAGES+=("$package")
  fi
done

DNS_PACKAGE=""
for candidate in dnsutils bind9-dnsutils; do
  if apt-cache show "$candidate" >/dev/null 2>&1; then
    DNS_PACKAGE="$candidate"
    INSTALL_PACKAGES+=("$candidate")
    break
  fi
done
[[ -n "$DNS_PACKAGE" ]] || MISSING_PACKAGES+=("dnsutils-or-bind9-dnsutils")

if ((${#MISSING_PACKAGES[@]} > 0)); then
  die "Required packages are unavailable on Ubuntu ${UBUNTU_VERSION}: ${MISSING_PACKAGES[*]}. Check that main, universe and security repositories are enabled."
fi
for package in "${OPTIONAL_PACKAGES[@]}"; do
  if apt-cache show "$package" >/dev/null 2>&1; then
    INSTALL_PACKAGES+=("$package")
  else
    warn "Optional package '${package}' is unavailable on Ubuntu ${UBUNTU_VERSION}; continuing without it."
  fi
done
for package in "${INSTALL_PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' \
    || PACKAGES_INSTALLED_BY_SCRIPT+=" ${package}"
done
write_state
xhttp_apt_apply install -y --no-install-recommends "${INSTALL_PACKAGES[@]}"
write_state
if [[ -n "$MIGRATION_DB" && ! -s "$MANAGED_BACKUP/migration.json" ]]; then
  log "Reading the SQLite client backup"
  [[ -r "$MIGRATION_SCRIPT" ]] || die "SQLite migration helpers are missing."
  while :; do
    if xhttp_migration_snapshot "$MIGRATION_DB" "$MIGRATION_INBOUND" "$(xhttp_transport_flow "$TRANSPORT")" "$MANAGED_BACKUP/migration.json"; then
      break
    else
      [[ "$?" == 2 && -t 0 ]] || die "Could not read clients from the SQLite backup."
    fi
    read -rp "Source VLESS inbound ID: " MIGRATION_INBOUND
    [[ "$MIGRATION_INBOUND" =~ ^[1-9][0-9]{0,9}$ ]] || die "Invalid source inbound ID."
    write_state
  done
fi

for command in curl dig fail2ban-client flock ip jq nginx openssl sshd ssh-keygen ss sudo sysctl systemctl ufw visudo; do
  command -v "$command" >/dev/null || die "Package installation completed, but required command '${command}' is missing."
done
if [[ "$SSH_ACCESS_MODE" == admin || "$SSH_ACCESS_MODE" == admin-cert ]]; then
  log "Creating administrative SSH user ${ADMIN_USER}"
elif [[ "$SSH_ACCESS_MODE" == root-key ]]; then
  log "Installing the selected key for root-only SSH access"
elif [[ "$SSH_ACCESS_MODE" == existing ]]; then
  warn "Keeping the current SSH authentication policy by explicit user choice."
fi
xhttp_install_ssh_access || die "Could not prepare the selected SSH access policy. The current root SSH access has not been disabled."
log "Configuring automatic Ubuntu maintenance"
xhttp_configure_automatic_updates || die "Could not apply the selected automatic-update policy."
xhttp_verify_automatic_updates || die "The active automatic-update policy does not match the selected mode."
log "Enabling BBR and disabling IPv6"
cat > /etc/modules-load.d/bbr.conf <<'EOF'
tcp_bbr
EOF
modprobe tcp_bbr 2>/dev/null || true
grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control \
  || die "The VPS kernel does not provide BBR. Available algorithms: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
cat > /etc/sysctl.d/99-xhttp-vps-network.conf <<'EOF'
# Managed by VLESS VPS Setup
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
sysctl --system >/dev/null
xhttp_apply_ping_policy || die 'Could not apply the selected IPv4 ping policy.'
[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] || die "BBR could not be activated."
[[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] || die "fq queue discipline could not be activated."
[[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == "1" ]] || die "IPv6 could not be disabled."
log "Network tuning active: BBR + fq, IPv6 disabled"

log "Checking DNS"
DNS_A_OUTPUT="$(dig +short A "$DOMAIN")"
xhttp_validate_single_dns_ipv4 "$PUBLIC_IP" <<<"$DNS_A_OUTPUT" \
  || die "${DOMAIN} must have exactly one A record, ${PUBLIC_IP}. Remove stale/proxy addresses; Cloudflare must be DNS only (grey cloud)."
if dig +short AAAA "$DOMAIN" | grep -q .; then
  die "Remove the AAAA record for ${DOMAIN}, then run the script again."
fi

log "Configuring UFW"
if [[ -L /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
  if systemctl is-active --quiet nginx; then systemctl reload nginx; fi
fi
ufw default deny incoming
ufw default allow outgoing
xhttp_configure_ssh_source || die 'Could not apply the selected SSH source policy.'
if [[ "$TLS_MODE" == production || "$TLS_MODE" == staging ]]; then
  ufw allow 80/tcp comment "xhttp-vps:${SAFE_INSTANCE} ACME"
fi
ufw allow 443/tcp comment "xhttp-vps:${SAFE_INSTANCE} VPN"
ufw --force enable

if xhttp_uses_panel && [[ ! -x /usr/local/x-ui/x-ui || ( -z "$PANEL_API_TOKEN" && ! -s /etc/x-ui/install-result.env ) ]]; then
  log "Installing 3x-ui from its latest stable release"
  for p in "$PANEL_PORT" "$SUB_PORT" 443 "$FALLBACK_PORT"; do port_busy "$p" && die "TCP/${p} is occupied."; done
  if [[ ! -x /usr/local/x-ui/x-ui ]]; then xhttp_install_panel; fi
  /usr/local/x-ui/x-ui setting -username "$PANEL_USERNAME" -password "$PANEL_PASSWORD" \
    -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" -listenIP 127.0.0.1 >/dev/null
  PANEL_API_TOKEN="$(/usr/local/x-ui/x-ui setting -getApiToken 2>/dev/null \
    | awk -F': ' '/^apiToken:/{gsub(/[[:space:]]/, "", $2); print $2}')"
  [[ -n "$PANEL_API_TOKEN" ]] || die "Could not create the panel API token."
  write_state
fi
if [[ ! -s "$CERT_DIR/fullchain.pem" || ! -s "$CERT_DIR/privkey.pem" ]]; then
  [[ "$TLS_MODE" == production || "$TLS_MODE" == staging ]] || die "Missing legacy test certificate."
  log "Issuing the TLS certificate through the persistent Nginx webroot"
  install -d -m 700 "$CERT_DIR"
  install -d -m 755 /var/www/3xui-cover/.well-known/acme-challenge
  rm -f /etc/nginx/sites-enabled/default
  xhttp_install_acme_nginx || die "Could not install the temporary ACME webroot virtual host."
  systemctl enable --now nginx
  systemctl reload nginx
  ACME_PROBE="$(random_hex 12)"
  printf '%s\n' "$ACME_PROBE" > "/var/www/3xui-cover/.well-known/acme-challenge/${ACME_PROBE}"
  [[ "$(curl -q -fsS --retry 3 --retry-connrefused --max-time 5 -H "Host: ${DOMAIN}" "http://127.0.0.1/.well-known/acme-challenge/${ACME_PROBE}")" == "$ACME_PROBE" ]] \
    || die "The local Nginx ACME webroot probe failed."
  rm -f "/var/www/3xui-cover/.well-known/acme-challenge/${ACME_PROBE}"
  if [[ "$ACME_CLIENT" == certbot ]]; then
    xhttp_issue_certbot_certificate /etc/xhttp-vps-acme /var/lib/xhttp-vps-acme \
      /var/log/xhttp-vps-acme /var/www/3xui-cover
    ln -sfn "/etc/xhttp-vps-acme/live/$DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
    ln -sfn "/etc/xhttp-vps-acme/live/$DOMAIN/privkey.pem" "$CERT_DIR/privkey.pem"
  else
    if [[ ! -s "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer" ]]; then
      /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --webroot /var/www/3xui-cover \
        --server letsencrypt --keylength ec-256
    fi
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
      --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" \
      --reloadcmd "systemctl reload nginx"
  fi
fi

if xhttp_uses_panel; then
[[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] || die "TLS certificate deployment failed."
xhttp_prepare_staging_ca || die "Could not verify the Let's Encrypt staging certificate."
/usr/local/x-ui/x-ui cert -webCert "$CERT_DIR/fullchain.pem" -webCertKey "$CERT_DIR/privkey.pem" >/dev/null
# The installer's result file is authoritative. Reading it also protects us
# from future installer-side normalization of the port or web base path.
if [[ -r /etc/x-ui/install-result.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/install-result.env
  PANEL_USERNAME="${XUI_USERNAME:-$PANEL_USERNAME}"
  PANEL_PASSWORD="${XUI_PASSWORD:-$PANEL_PASSWORD}"
  PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
  PANEL_PATH="${XUI_WEB_BASE_PATH:-$PANEL_PATH}"
  PANEL_API_TOKEN="${XUI_API_TOKEN:-$PANEL_API_TOKEN}"
  PANEL_PATH="${PANEL_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}"
  write_state
fi
# Current 3x-ui writes the one-time plaintext token to install-result.env.
# Use the CLI only when the installer omitted a token: on recent 3x-ui releases
# that command mints a new fallback token and must never be called routinely.
if [[ -z "$PANEL_API_TOKEN" ]]; then
  PANEL_API_TOKEN="$(/usr/local/x-ui/x-ui setting -getApiToken true 2>/dev/null \
    | awk -F': ' '/apiToken:/{gsub(/[[:space:]]/, "", $2); print $2; exit}')"
fi
# Keep the panel private while it is being configured. Never reset an existing
# two-factor setting: enrollment and recovery codes belong to the administrator.
/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 >/dev/null
[[ -n "$PANEL_API_TOKEN" ]] || die "The official 3x-ui installer did not provide an API token in /etc/x-ui/install-result.env."
fi

log "Creating the public HTTPS site"
install -d -m 755 /var/www/3xui-cover
DOMAIN_ROOT="${DOMAIN%%.*}"
DOMAIN_ROOT="$(printf '%s' "$DOMAIN_ROOT" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)} print}')"
case "$COVER_STYLE" in
  2)
    BRAND="${DOMAIN_ROOT} Engineering"; KICKER="Independent engineering consultancy"
    HEADLINE="Technical clarity for complex building systems."
    INTRO="We help project teams move from early technical studies to coordinated delivery with clear documentation, practical analysis and disciplined project controls."
    S1="Technical studies"; D1="Feasibility reviews, system assessments and clearly structured recommendations."
    S2="Design coordination"; D2="Cross-discipline technical alignment from concept through construction information."
    S3="Delivery support"; D3="Documentation reviews, commissioning planning and structured handover support."
    ACCENT="#e56b3f"; ACCENT2="#f2b84b"; SURFACE="#f5f1eb"; INK="#17202a"; MODE="warm"
    PHOTO_ID="xYeGSXRhV80"; PHOTO_ASSET="engineering.jpg"; PHOTO_CREDIT="Dave Meckler" ;;
  3)
    BRAND="${DOMAIN_ROOT} Infrastructure"; KICKER="Digital systems & operations"
    HEADLINE="Infrastructure designed to stay dependable."
    INTRO="Architecture, automation and operational guidance for teams that need secure, observable and maintainable digital systems without unnecessary complexity."
    S1="Platform architecture"; D1="Practical system design shaped around reliability, scale and operating constraints."
    S2="Operational readiness"; D2="Monitoring, runbooks and recovery workflows prepared before services go live."
    S3="Lifecycle improvement"; D3="Measured modernization of existing environments with controlled implementation risk."
    ACCENT="#3b82f6"; ACCENT2="#22c1a3"; SURFACE="#09111f"; INK="#eef5ff"; MODE="dark"
    PHOTO_ID="k27hkqXuveo"; PHOTO_ASSET="infrastructure.jpg"; PHOTO_CREDIT="Eric Stoynov" ;;
  4)
    BRAND="${DOMAIN_ROOT} Operations"; KICKER="Logistics planning & coordination"
    HEADLINE="A clearer route from planning to delivery."
    INTRO="We support complex operational flows with structured planning, supplier coordination and useful reporting that keeps decisions close to real-world conditions."
    S1="Network planning"; D1="Flow analysis and practical operating models for evolving distribution requirements."
    S2="Delivery coordination"; D2="Milestone control, supplier alignment and concise exception reporting."
    S3="Process improvement"; D3="Focused reviews that remove friction without disrupting day-to-day operations."
    ACCENT="#bbf451"; ACCENT2="#57d6c7"; SURFACE="#13251f"; INK="#f4f8ef"; MODE="green"
    PHOTO_ID="F2C_mSrb6iM"; PHOTO_ASSET="logistics.jpg"; PHOTO_CREDIT="Bernd Dittrich" ;;
  5)
    BRAND="${DOMAIN_ROOT} Studio"; KICKER="Architecture & spatial strategy"
    HEADLINE="Thoughtful spaces, resolved with precision."
    INTRO="An independent studio working across early design, technical coordination and project delivery to create places that are calm, useful and built to last."
    S1="Spatial strategy"; D1="Brief development, site response and clear options for informed early decisions."
    S2="Design development"; D2="Material, detail and system coordination carried through with consistency."
    S3="Project continuity"; D3="Design intent protected through documentation, review and on-site collaboration."
    ACCENT="#9d7d62"; ACCENT2="#d8c6b4"; SURFACE="#eeeae4"; INK="#24211f"; MODE="stone"
    PHOTO_ID="A9HNu8LiHQc"; PHOTO_ASSET="architecture.jpg"; PHOTO_CREDIT="Grigorii Shcheglov" ;;
  6)
    BRAND="${DOMAIN_ROOT} Service Group"; KICKER="Industrial maintenance & support"
    HEADLINE="Keeping essential equipment working well."
    INTRO="Planned maintenance, technical documentation and service coordination for commercial and industrial equipment throughout its operating life."
    S1="Maintenance planning"; D1="Asset-led schedules, service scopes and practical maintenance documentation."
    S2="Technical support"; D2="Structured fault review, supplier coordination and clear action tracking."
    S3="Lifecycle services"; D3="Condition reviews and replacement planning grounded in operational priorities."
    ACCENT="#ffb000"; ACCENT2="#f05d3e"; SURFACE="#101418"; INK="#f4f6f8"; MODE="industrial"
    PHOTO_ID="VFrbWve7eAs"; PHOTO_ASSET="industrial-service.jpg"; PHOTO_CREDIT="TECNIC Bioprocess Solutions" ;;
esac
PHOTO_PAGE="https://unsplash.com/photos/${PHOTO_ID}"
PHOTO_FILE="/var/www/3xui-cover/hero.jpg"
REPO_ASSET_BASE="${REPO_ASSET_BASE:-https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/main/assets}"
PHOTO_MARKUP=''
PHOTO_TEMP="$(mktemp /var/www/3xui-cover/.photo.XXXXXXXX)"
if curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 15 \
    "${REPO_ASSET_BASE}/${PHOTO_ASSET}" -o "$PHOTO_TEMP" 2>/dev/null ||
   curl -q -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 15 \
    "https://unsplash.com/photos/${PHOTO_ID}/download?force=true&w=1800&fm=jpg" -o "$PHOTO_TEMP" 2>/dev/null; then
  if [[ "$(od -An -N 3 -tx1 "$PHOTO_TEMP" | tr -d ' \n')" == ffd8ff ]]; then
    chmod 644 "$PHOTO_TEMP"
    mv -T "$PHOTO_TEMP" "$PHOTO_FILE"
  fi
fi
rm -f -- "$PHOTO_TEMP"
if [[ -s "$PHOTO_FILE" ]]; then
  PHOTO_MARKUP="<img src=\"/hero.jpg\" alt=\"\" fetchpriority=\"high\"><a class=\"credit\" href=\"${PHOTO_PAGE}\" rel=\"noreferrer\">Photo: ${PHOTO_CREDIT} / Unsplash</a>"
fi
cat > /var/www/3xui-cover/index.html <<HTML
<!doctype html>
<html lang="en" data-theme="${MODE}">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="${KICKER}. ${INTRO}"><title>${BRAND} — ${KICKER}</title>
  <style>
    :root{--accent:${ACCENT};--accent2:${ACCENT2};--surface:${SURFACE};--ink:${INK};--muted:color-mix(in srgb,var(--ink) 62%,transparent);--line:color-mix(in srgb,var(--ink) 14%,transparent);--panel:color-mix(in srgb,var(--surface) 91%,var(--ink) 9%);--max:1180px}
    *{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--surface);color:var(--ink);font-family:Inter,ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:16px;line-height:1.55;-webkit-font-smoothing:antialiased}a{color:inherit;text-decoration:none}.shell{width:min(calc(100% - 40px),var(--max));margin:auto}
    header{height:82px;display:flex;align-items:center;border-bottom:1px solid var(--line)}nav{display:flex;align-items:center;justify-content:space-between;width:100%}.brand{display:flex;gap:12px;align-items:center;font-weight:680;letter-spacing:-.02em}.mark{width:34px;height:34px;border:1px solid var(--line);border-radius:10px;display:grid;place-items:center;background:linear-gradient(145deg,color-mix(in srgb,var(--accent) 22%,transparent),transparent)}.mark svg{width:18px}.links{display:flex;align-items:center;gap:30px;color:var(--muted);font-size:14px}.links a:hover{color:var(--ink)}
    .hero{min-height:720px;padding:96px 0 84px;display:grid;grid-template-columns:minmax(0,1.08fr) minmax(340px,.92fr);gap:72px;align-items:center}.eyebrow{text-transform:uppercase;letter-spacing:.16em;font-size:12px;font-weight:700;color:var(--accent);margin-bottom:26px}.hero h1{font-size:clamp(48px,6.3vw,82px);line-height:.98;letter-spacing:-.055em;max-width:850px;margin:0}.intro{font-size:19px;line-height:1.65;color:var(--muted);max-width:580px;margin:36px 0}.action{display:inline-flex;align-items:center;gap:12px;border-bottom:1px solid var(--ink);padding:8px 0;font-weight:650}.action span{transition:transform .2s}.action:hover span{transform:translateX(5px)}.visual{position:relative;margin:0;min-height:540px;border-radius:4px 42px 4px 4px;overflow:hidden;background:var(--panel);box-shadow:0 26px 70px color-mix(in srgb,var(--ink) 16%,transparent)}.visual:after{content:"";position:absolute;inset:0;background:linear-gradient(180deg,transparent 48%,rgba(5,10,15,.76))}.visual img{position:absolute;width:100%;height:100%;object-fit:cover;filter:saturate(.88) contrast(1.04)}.visual-note{position:absolute;z-index:1;left:28px;right:28px;bottom:26px;color:#fff;font-size:14px}.visual-note strong{display:block;font-size:17px;margin-bottom:7px}.credit{position:absolute;z-index:2;right:14px;top:14px;padding:6px 9px;border-radius:20px;background:rgba(0,0,0,.42);backdrop-filter:blur(8px);color:rgba(255,255,255,.82);font-size:10px}
    .band{border-top:1px solid var(--line);border-bottom:1px solid var(--line);padding:25px 0}.band-row{display:flex;justify-content:space-between;gap:30px;color:var(--muted);font-size:13px;text-transform:uppercase;letter-spacing:.1em}.dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--accent);margin-right:10px}
    section{padding:110px 0}.section-head{display:grid;grid-template-columns:1fr 2fr;gap:60px;margin-bottom:64px}.section-head p{margin:0;color:var(--muted);max-width:700px;font-size:18px}.label{font-size:12px;text-transform:uppercase;letter-spacing:.15em;font-weight:700;color:var(--accent)}.services{display:grid;grid-template-columns:repeat(3,1fr);border-top:1px solid var(--line)}.service{padding:34px 34px 42px 0;border-bottom:1px solid var(--line)}.service+.service{border-left:1px solid var(--line);padding-left:34px}.num{font-variant-numeric:tabular-nums;color:var(--accent);font-size:12px}.service h2{font-size:24px;letter-spacing:-.025em;margin:50px 0 15px}.service p{color:var(--muted);margin:0;max-width:330px}
    .approach{background:var(--panel);border-radius:28px;padding:70px;display:grid;grid-template-columns:1fr 1fr;gap:80px}.approach h2{font-size:clamp(36px,4vw,58px);line-height:1.05;letter-spacing:-.045em;margin:0}.steps{counter-reset:step}.step{counter-increment:step;display:grid;grid-template-columns:38px 1fr;gap:15px;padding:20px 0;border-bottom:1px solid var(--line)}.step:before{content:"0" counter(step);color:var(--accent);font-size:12px}.step strong{display:block;margin-bottom:5px}.step span{color:var(--muted);font-size:14px}
    footer{padding:44px 0;border-top:1px solid var(--line);color:var(--muted);font-size:13px}.footer-row{display:flex;justify-content:space-between;gap:30px}.domain{color:var(--ink)}
    @media(max-width:800px){.links a:not(:last-child){display:none}.hero{grid-template-columns:1fr;min-height:auto;padding:72px 0 64px;gap:50px}.visual{min-height:430px;border-radius:4px 30px 4px 4px}.band-row{flex-wrap:wrap}.section-head,.approach{grid-template-columns:1fr}.services{grid-template-columns:1fr}.service+.service{border-left:0;padding-left:0}.approach{padding:38px;gap:45px}.footer-row{flex-direction:column}.hero h1{font-size:clamp(44px,14vw,70px)}}
    @media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}.action span{transition:none}}
  </style>
</head>
<body>
  <header><div class="shell"><nav><a class="brand" href="#"><span class="mark"><svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M4 17.5 12 4l8 13.5M7 14h10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span>${BRAND}</a><div class="links"><a href="#capabilities">Capabilities</a><a href="#approach">Approach</a><a href="#about">About</a></div></nav></div></header>
  <main>
    <div class="shell hero"><div><div class="eyebrow">${KICKER}</div><h1>${HEADLINE}</h1><p class="intro">${INTRO}</p><a class="action" href="#capabilities">Explore our capabilities <span>→</span></a></div><figure class="visual">${PHOTO_MARKUP}<figcaption class="visual-note"><strong>Measured, collaborative, accountable.</strong>Clear technical thinking and decisions grounded in the realities of delivery.</figcaption></figure></div>
    <div class="band"><div class="shell band-row"><span><i class="dot"></i>Independent practice</span><span>Planning & coordination</span><span>Documentation & delivery</span></div></div>
    <section id="capabilities"><div class="shell"><div class="section-head"><div class="label">What we do</div><p>Focused support at the points where good information and careful coordination have the greatest impact on project outcomes.</p></div><div class="services"><article class="service"><div class="num">01</div><h2>${S1}</h2><p>${D1}</p></article><article class="service"><div class="num">02</div><h2>${S2}</h2><p>${D2}</p></article><article class="service"><div class="num">03</div><h2>${S3}</h2><p>${D3}</p></article></div></div></section>
    <section id="approach"><div class="shell approach"><div><div class="label">How we work</div><h2>Useful detail.<br>Decisive progress.</h2></div><div class="steps"><div class="step"><div><strong>Understand the context</strong><span>Define the real constraints, responsibilities and measures of success.</span></div></div><div class="step"><div><strong>Make the work visible</strong><span>Turn complex information into an organised, reviewable plan.</span></div></div><div class="step"><div><strong>Follow through</strong><span>Keep decisions, documentation and delivery aligned as the work develops.</span></div></div></div></div></section>
  </main>
  <footer id="about"><div class="shell footer-row"><span class="domain">${DOMAIN}</span><span>${BRAND} · Professional services</span><span>© $(date +%Y)</span></div></footer>
</body>
</html>
HTML
xhttp_install_nginx
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/3xui-self-steal.conf /etc/nginx/sites-enabled/3xui-self-steal.conf
nginx -t
systemctl enable --now nginx
systemctl reload nginx
if [[ "$ACME_CLIENT" == certbot ]]; then xhttp_install_cert_renewal; fi
if ! xhttp_uses_panel; then
  [[ -r "$UDP_SCRIPT" ]] || die "UDP transport helpers are missing."
  log "Starting $(xhttp_transport_label "$TRANSPORT")"
  if [[ "$SSH_HARDENING" == 1 ]]; then xhttp_harden_sshd; fi
  xhttp_finalize_ssh_port || die 'SSH port migration did not complete. Keep this session open.'
  write_state
  xhttp_install_fail2ban_sshd || die "Fail2ban could not load the sshd jail."
  xhttp_udp_finish
  INSTALL_PHASE=complete
  write_state
  if [[ "${CREATE_RECOVERY_BACKUP:-0}" == 1 ]]; then
    xhttp_export_recovery_backup "$STATE_FILE" || warn 'Backup skipped. You can retry using menu item 5.'
  fi
  exit 0
fi
systemctl enable x-ui
xhttp_restart_vpn_service x-ui
if [[ "$TLS_MODE" == "production" && "$ACME_CLIENT" != certbot ]]; then
  /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --key-file "$CERT_DIR/privkey.pem" \
    --fullchain-file "$CERT_DIR/fullchain.pem" --reloadcmd "systemctl reload nginx && systemctl restart x-ui"
fi

INSTALL_PHASE='service-ready'
write_state
if [[ "$RESUMING" == 1 ]]; then exec "$RECOVERY_SCRIPT"; fi

API_BASE="https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}"
API_HEADER_FILE="$(xhttp_create_api_header_file "$PANEL_API_TOKEN")" \
  || die "The panel API token is empty or contains invalid control characters."
API_AUTH=(--cacert "$(xhttp_tls_ca_file)" --noproxy '*' --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" -H "@${API_HEADER_FILE}")
trap 'rm -f "${API_HEADER_FILE:-}"' EXIT

build_warp_outbound() {
  local data_json="$1" config_json="$2" private_key client_id peer_key endpoint addresses reserved
  WARP_OUT=""
  private_key="$(jq -r '.private_key // empty' <<<"$data_json")"
  client_id="$(jq -r '.client_id // empty' <<<"$data_json")"
  peer_key="$(jq -r '.config.peers[0].public_key // empty' <<<"$config_json")"
  endpoint="$(jq -r '.config.peers[0].endpoint.host // empty' <<<"$config_json")"
  addresses="$(jq -nc --arg v4 "$(jq -r '.config.interface.addresses.v4 // empty' <<<"$config_json")" \
    --arg v6 "$(jq -r '.config.interface.addresses.v6 // empty' <<<"$config_json")" \
    '[$v4, $v6 | select(length > 0) | if contains(":") then . + "/128" else . + "/32" end]')"
  [[ -n "$private_key" && -n "$client_id" && -n "$peer_key" && -n "$endpoint" && "$addresses" != "[]" ]] || return 1
  reserved="$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1 | awk 'BEGIN { printf "[" } { for (i=1; i<=NF; i++) { if (n++) printf ","; printf $i } } END { print "]" }')" || return 1
  [[ "$reserved" != "[]" ]] || return 1
  WARP_OUT="$(jq -nc --arg private "$private_key" --arg public "$peer_key" --arg endpoint "$endpoint" \
    --argjson addresses "$addresses" --argjson reserved "$reserved" \
    '{tag:"warp",protocol:"wireguard",settings:{mtu:1420,secretKey:$private,address:$addresses,reserved:$reserved,domainStrategy:"ForceIPv4v6",peers:[{publicKey:$public,endpoint:$endpoint}],noKernelTun:true}}')" || return 1
}

log "Waiting for the private IPv4 panel API and verifying its bearer token"
API_READY=0; RESPONSE=""; API_HTTP_CODE="000"
for _ in $(seq 1 15); do
  API_PROBE="$(curl -ksS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 \
    -w $'\n%{http_code}' "$API_BASE/panel/api/server/status" 2>&1 || true)"
  API_HTTP_CODE="${API_PROBE##*$'\n'}"
  RESPONSE="${API_PROBE%$'\n'*}"
  if [[ "$API_HTTP_CODE" == "200" ]] && jq -e '.success == true' <<<"$RESPONSE" >/dev/null 2>&1; then
    API_READY=1
    break
  fi
  sleep 1
done
if [[ "$API_READY" -ne 1 ]]; then
  systemctl status x-ui --no-pager || true
  /usr/local/x-ui/x-ui setting -show true 2>/dev/null || true
  ss -ltnp | grep -E ":${PANEL_PORT}([[:space:]]|$)" || true
  die "Private bearer API did not become ready after 15 attempts. HTTP ${API_HTTP_CODE}; response: ${RESPONSE:-<empty>}"
fi

log "Enabling and configuring subscriptions"
RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/setting/all")"
SETTINGS="$(jq -c '.obj | if type == "string" then fromjson else . end' <<<"$RESPONSE")"
SETTINGS="$(jq -c --arg d "$DOMAIN" --arg title "$VPN_NAME" --argjson p "$SUB_PORT" --arg path "/${SUB_PATH}/" --arg cert "$CERT_DIR/fullchain.pem" --arg key "$CERT_DIR/privkey.pem" '
  .subEnable=true | .subEncrypt=true | .subListen="127.0.0.1" | .subDomain=$d | .subPort=$p | .subPath=$path
  | .subCertFile=$cert | .subKeyFile=$key | .subURI=("https://"+$d+$path) | .subTitle=$title
' <<<"$SETTINGS")"
SETTINGS="$(xhttp_subscription_profile_settings <<<"$SETTINGS")"
CLIENT_ROUTING_CONFIGURED=0; MIHOMO_CONFIGURED=0
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if [[ -n "$SUB_ENCRYPT_LINKS" ]]; then
    SETTINGS="$(jq -c --argjson enabled "$SUB_ENCRYPT_LINKS" '.happLinkEnable=$enabled' <<<"$SETTINGS")"
  fi
  ROUTING_REVISION="$(xhttp_routing_revision || true)"
  HAPP_ROUTING="$(xhttp_fetch_routing "$ROUTING_REVISION" HAPP/DEFAULT.DEEPLINK 2>/dev/null || true)"
  INCY_ROUTING="$(xhttp_fetch_routing "$ROUTING_REVISION" INCY/DEFAULT.DEEPLINK 2>/dev/null || true)"
  if [[ "$HAPP_ROUTING" == happ://routing/onadd/* && "$INCY_ROUTING" == incy://routing/onadd/* ]]; then
    SETTINGS="$(jq -c --arg happ "$HAPP_ROUTING" --arg incy "$INCY_ROUTING" \
      --arg jsonPath "/${SUB_JSON_PATH}/" --arg clashPath "/${SUB_CLASH_PATH}/" \
      --arg jsonURI "https://${DOMAIN}/${SUB_JSON_PATH}/" --arg clashURI "https://${DOMAIN}/${SUB_CLASH_PATH}/" '
      .subEnableRouting=true | .subRoutingRules=$happ
      | .subIncyEnableRouting=true | .subIncyRoutingRules=$incy
      | .subJsonEnable=true | .subJsonPath=$jsonPath | .subJsonURI=$jsonURI
      | .subClashEnable=true | .subClashPath=$clashPath | .subClashURI=$clashURI
      | .subClashEnableRouting=false
    ' <<<"$SETTINGS")"
    CLIENT_ROUTING_CONFIGURED=1
    MIHOMO_CONFIGURED=1
  else
    warn "RoscomVPN routing profiles could not be downloaded; HAPP/INCY routing and Mihomo endpoint are left disabled."
  fi
fi
RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -H 'Content-Type: application/json' -X POST "$API_BASE/panel/api/setting/update" --data-binary "$SETTINGS")"
jq -e '.success == true' <<<"$RESPONSE" >/dev/null || die "Subscription configuration failed: ${RESPONSE}"
SUBSCRIPTION_CONFIGURED=1

if [[ "$INSTALL_MODE" == "standalone" ]]; then
  log "Creating Mihomo subscription with RoscomVPN routing"
  MIHOMO_PROVIDER_URL="https://${DOMAIN}/${SUB_CLASH_PATH}/${CLIENT_SUB_ID}"
  MIHOMO_ROUTING_URL="https://${DOMAIN}/${MIHOMO_ROUTING_PATH}"
  MIHOMO_TEMPLATE="$(xhttp_fetch_routing "$ROUTING_REVISION" MIHOMO/default.yaml 2>/dev/null || true)"
  if grep -Fq '<ВВЕДИТЕ URL ПОДПИСКИ>' <<<"$MIHOMO_TEMPLATE"; then
    printf '%s\n' "$MIHOMO_TEMPLATE" | sed "s|<ВВЕДИТЕ URL ПОДПИСКИ>|${MIHOMO_PROVIDER_URL}|g" > "/var/www/3xui-cover/${MIHOMO_ROUTING_PATH}"
    chmod 644 "/var/www/3xui-cover/${MIHOMO_ROUTING_PATH}"
    MIHOMO_CONFIGURED=1
    write_state
  else
    MIHOMO_CONFIGURED=0
    warn "RoscomVPN Mihomo template could not be downloaded; the Mihomo routing subscription is unavailable."
  fi
fi

log "Creating $(xhttp_transport_label "$TRANSPORT") inbound on TCP/443"
RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" "$API_BASE/panel/api/server/getNewX25519Cert")"
jq -e '.success == true' <<<"$RESPONSE" >/dev/null || die "Reality key generation failed: ${RESPONSE}"
REALITY_PRIVATE="$(jq -r '.obj.privateKey // .obj.private // empty' <<<"$RESPONSE")"
REALITY_PUBLIC="$(jq -r '.obj.publicKey // .obj.public // empty' <<<"$RESPONSE")"
[[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || die "3x-ui returned incomplete Reality keys: ${RESPONSE}"
SHORT_ID="$(random_hex 8)"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  CLIENT_FLOW="$(xhttp_transport_flow "$TRANSPORT")"
  INBOUND_SETTINGS="$(jq -nc --arg id "$CLIENT_UUID" --arg email "$CLIENT_EMAIL" --arg sub "$CLIENT_SUB_ID" \
    --arg flow "$CLIENT_FLOW" '{clients:[{id:$id,flow:$flow,email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,reset:0}],decryption:"none",encryption:"none",fallbacks:[]}')"
else
  INBOUND_SETTINGS="$(jq -nc '{clients:[],decryption:"none",encryption:"none",fallbacks:[]}')"
fi
STREAM_SETTINGS="$(xhttp_build_stream_settings "$TRANSPORT" "$DOMAIN" "127.0.0.1:${FALLBACK_PORT}" \
  "$REALITY_PRIVATE" "$REALITY_PUBLIC" "$SHORT_ID")" \
  || die "Could not build ${TRANSPORT} stream settings."
SNIFFING="$(jq -nc '{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}')"
INBOUND="$(jq -nc --arg remark "${VPN_NAME}" --arg settings "$INBOUND_SETTINGS" \
  --arg stream "$STREAM_SETTINGS" --arg sniff "$SNIFFING" --arg tag "$INBOUND_TAG" '
  {up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,trafficReset:"never",listen:"",port:443,
   protocol:"vless",settings:$settings,streamSettings:$stream,tag:$tag,sniffing:$sniff}
')"
RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -H 'Content-Type: application/json' \
  -X POST "$API_BASE/panel/api/inbounds/add" --data-binary "$INBOUND")"
jq -e '.success == true' <<<"$RESPONSE" >/dev/null || die "Inbound creation failed: ${RESPONSE}"
RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/server/restartXrayService")"
jq -e '.success == true' <<<"$RESPONSE" >/dev/null || die "Xray restart after inbound creation failed: ${RESPONSE}"
INBOUND_CONFIGURED=1
write_state

log "Applying the low-memory Xray profile"
xhttp_memory_apply "$INBOUND_TAG" "$TRANSPORT"
if [[ -n "$MIGRATION_DB" ]]; then
  log "Importing VLESS users and usage"
  xhttp_import_migrated_clients
fi

if [[ "$ENABLE_WARP" -eq 1 ]]; then
  log "Creating built-in WARP and RU routing"
  RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/data")"
  if ! jq -e '.success == true and .obj != null and .obj != ""' <<<"$RESPONSE" >/dev/null; then
    PRIVATE_KEY="$(wg genkey)"; PUBLIC_KEY="$(printf '%s' "$PRIVATE_KEY" | wg pubkey)"
    RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/reg" --data-urlencode "privateKey=$PRIVATE_KEY" --data-urlencode "publicKey=$PUBLIC_KEY")"
    if ! jq -e '.success == true' <<<"$RESPONSE" >/dev/null; then
      die "WARP registration failed. WARP was requested, so installation cannot continue. Panel response: ${RESPONSE}"
    fi
  fi
  if [[ "$ENABLE_WARP" -eq 1 ]]; then
    WARP_DATA_RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/data")"
    WARP_CONFIG_RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/config")"
    WARP_DATA="$(jq -c '.obj | if type=="string" then fromjson else . end' <<<"$WARP_DATA_RESPONSE")"
    WARP_CONFIG="$(jq -c '.obj | if type=="string" then fromjson else . end' <<<"$WARP_CONFIG_RESPONSE")"
    if ! build_warp_outbound "$WARP_DATA" "$WARP_CONFIG"; then
      die "WARP account data is incomplete. WARP was requested, so installation cannot continue."
    else
      RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/")"
      jq -e '.success == true and .obj != null' <<<"$RESPONSE" >/dev/null || die "Could not read Xray configuration: $RESPONSE"
      XRAY="$(jq -c '.obj | if type=="string" then fromjson else . end | .xraySetting | if type=="string" then fromjson else . end' <<<"$RESPONSE")"
      jq -e 'type=="object" and (.outbounds|type=="array")' <<<"$XRAY" >/dev/null || die "Xray configuration has an unexpected format."
      WARP_BACKUP="$(mktemp -d /root/xhttp-warp-backup.XXXXXXXX)"
      sqlite3 /etc/x-ui/x-ui.db ".timeout 5000" ".backup '$WARP_BACKUP/x-ui.db'"
      XRAY="$(xhttp_warp_config "$WARP_OUT" <<<"$XRAY")"
      xhttp_validate_warp_routes <<<"$XRAY" || die "Required Russian routing datasets are unavailable."
      RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/update" --data-urlencode "xraySetting=$XRAY" --data-urlencode 'outboundTestUrl=https://www.cloudflare.com/cdn-cgi/trace')"
      if jq -e '.success == true' <<<"$RESPONSE" >/dev/null; then
        VERIFY_WARP_RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/")"
        VERIFY_WARP="$(jq -c '.obj | if type=="string" then fromjson else . end | .xraySetting | if type=="string" then fromjson else . end' <<<"$VERIFY_WARP_RESPONSE")"
        jq -e 'type=="object" and any(.outbounds[]?; .tag=="warp") and any(.routing.rules[]?; .ruleTag=="xhttp-vps-warp-ru-domain" and .domain==["domain:ru","domain:su","domain:xn--p1ai","geosite:category-ru"] and .outboundTag=="warp") and any(.routing.rules[]?; .ruleTag=="xhttp-vps-warp-ru-ip" and .ip==["geoip:ru"] and .outboundTag=="warp") and .routing.domainStrategy=="IPOnDemand"' <<<"$VERIFY_WARP" >/dev/null || die "WARP configuration could not be verified after saving."
        WARP_CONFIGURED=1
        configure_warp_swap
      else
        die "WARP routing could not be saved. WARP was requested, so installation cannot continue. Panel response: ${RESPONSE}"
      fi
    fi
  fi
fi
write_state

xhttp_restart_vpn_service x-ui
sleep 1
API_READY=0; RESPONSE=""
for _ in $(seq 1 15); do
  RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 "$API_BASE/panel/api/server/status" 2>&1 || true)"
  if jq -e '.success == true' <<<"$RESPONSE" >/dev/null 2>&1; then API_READY=1; break; fi
  sleep 1
done
[[ "$API_READY" -eq 1 ]] || die "Private bearer API did not return after restart. Last response: ${RESPONSE:-<empty>}"

if [[ "$INSTALL_MODE" == "node" && -z "${NODE_API_TOKEN:-}" ]]; then
  log "Creating a least-privilege node-sync API token"
  NODE_API_TOKEN="$(xhttp_rotate_node_sync_token xhttp-node-sync)" \
    || die "Could not create the restricted node-sync API token. The local administrator token was not exported."
  write_state
fi

# Verify the saved configuration through the panel API, not only the TCP port.
INBOUND_VERIFIED=0; CLIENT_VERIFIED=0; SUBSCRIPTION_VERIFIED=0; SUB_PROTECTION_VERIFIED=0; PUBLIC_SELF_STEAL_VERIFIED=0
CLIENT_ROUTING_VERIFIED=0; MIHOMO_VERIFIED=0; PANEL_SETTINGS_VERIFIED=0
SETTING_VERIFY_RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/setting/all" || true)"
if jq -e '.success == true and ((.obj | if type=="string" then fromjson else . end) | type=="object")' \
  <<<"$SETTING_VERIFY_RESPONSE" >/dev/null 2>&1; then PANEL_SETTINGS_VERIFIED=1; fi
VERIFY_RESPONSE="$(curl -q -fsS "${API_AUTH[@]}" "$API_BASE/panel/api/inbounds/list" || true)"
if jq -e --arg d "$DOMAIN" --arg dest "127.0.0.1:${FALLBACK_PORT}" --arg transport "$TRANSPORT" --arg tag "$INBOUND_TAG" '
  .success == true and
  ((.obj | if type=="string" then fromjson else . end) | any(
    .port==443 and .protocol=="vless" and .enable==true and .tag==$tag and
    ((.streamSettings | if type=="string" then fromjson else . end) as $s |
      $s.security=="reality" and
      (($s.realitySettings.target // $s.realitySettings.dest) == $dest) and
      (($s.realitySettings.serverNames // []) | index($d)) != null and
      (if $transport=="vision" then
         ($s.network=="tcp" or $s.network=="raw") and (($s.tcpSettings.header.type//"none")=="none")
       else
         $s.network=="xhttp" and $s.xhttpSettings.host==$d and $s.xhttpSettings.path=="/"
       end))
  ))' <<<"$VERIFY_RESPONSE" >/dev/null 2>&1; then
  INBOUND_VERIFIED=1
fi
for _ in $(seq 1 20); do
  if xhttp_probe_cover_website 2>/dev/null; then PUBLIC_SELF_STEAL_VERIFIED=1; break; fi
  sleep 1
done
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if jq -e --arg id "$CLIENT_UUID" --arg sub "$CLIENT_SUB_ID" --arg flow "$(xhttp_transport_flow "$TRANSPORT")" '
    .success == true and
    ((.obj | if type=="string" then fromjson else . end) | any(
      .port==443 and .protocol=="vless" and
      ((.settings | if type=="string" then fromjson else . end).clients |
        any(.id==$id and .subId==$sub and .enable==true and (.flow//"")==$flow))
    ))' <<<"$VERIFY_RESPONSE" >/dev/null 2>&1; then
    CLIENT_VERIFIED=1
  fi
  for _ in $(seq 1 20); do
    SUB_RESPONSE="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 \
      "https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}" 2>/dev/null || true)"
    [[ -n "$SUB_RESPONSE" ]] && { SUBSCRIPTION_VERIFIED=1; break; }
    sleep 1
  done
  if [[ "$SUBSCRIPTION_VERIFIED" -eq 1 ]]; then
    SUB_HEADERS="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 -D - -o /dev/null \
      "https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}" 2>/dev/null || true)"
    if [[ -n "$SUB_HEADERS" ]] && xhttp_verify_subscription_protection "$SUB_HEADERS"; then SUB_PROTECTION_VERIFIED=1; fi
  fi
  if [[ "$CLIENT_ROUTING_CONFIGURED" -eq 1 && "$SUBSCRIPTION_VERIFIED" -eq 1 ]] \
    && xhttp_verify_subscription_routing "$DOMAIN" "${SUB_PATH}/${CLIENT_SUB_ID}"; then
    CLIENT_ROUTING_VERIFIED=1
  fi
  if [[ "$MIHOMO_CONFIGURED" -eq 1 ]]; then
    MIHOMO_RESPONSE="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 10 \
      "$MIHOMO_ROUTING_URL" 2>/dev/null || true)"
    if grep -q '^rule-providers:' <<<"$MIHOMO_RESPONSE" && grep -Fq "$MIHOMO_PROVIDER_URL" <<<"$MIHOMO_RESPONSE"; then MIHOMO_VERIFIED=1; fi
  fi
fi

while IFS= read -r rule_number; do
  ufw --force delete "$rule_number"
done < <(ufw status numbered | awk -v marker="# xhttp-vps:${SAFE_INSTANCE} panel" '
  index($0,marker) {sub(/^\[[[:space:]]*/, ""); sub(/\].*$/, ""); print}
' | sort -rn)
case "$PANEL_ACCESS_MODE" in
  private) ;;
  allowlist) ufw allow from "$PANEL_ALLOWED_IP" to any port "$PANEL_PORT" proto tcp comment "xhttp-vps:${SAFE_INSTANCE} panel" ;;
  public) ufw allow "$PANEL_PORT"/tcp comment "xhttp-vps:${SAFE_INSTANCE} panel" ;;
  *) die "Invalid panel access mode in state: ${PANEL_ACCESS_MODE}" ;;
esac

if [[ "$PANEL_ACCESS_MODE" == "private" ]]; then
  log "Keeping the panel on private localhost access"
  /usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 >/dev/null
else
  log "Enabling restricted panel IPv4 access after private configuration"
  /usr/local/x-ui/x-ui setting -listenIP 0.0.0.0 >/dev/null
fi
xhttp_restart_vpn_service x-ui
PANEL_HTTPS_VERIFIED=0
PANEL_LOCAL_URL="https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}/"
for _ in $(seq 1 20); do
  if curl -kfsS --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" --connect-timeout 2 --max-time 5 \
    -o /dev/null "$PANEL_LOCAL_URL" 2>/dev/null; then PANEL_HTTPS_VERIFIED=1; break; fi
  sleep 1
done
PANEL_BIND_VERIFIED=0
PANEL_LISTEN_ADDRESSES="$(ss -H -ltn "sport = :$PANEL_PORT" | awk '{print $4}')"
if [[ "$PANEL_ACCESS_MODE" == "private" ]]; then
  if [[ -n "$PANEL_LISTEN_ADDRESSES" ]] && ! grep -Evq '^127\.0\.0\.1:' <<<"$PANEL_LISTEN_ADDRESSES"; then
    PANEL_BIND_VERIFIED=1
  fi
else
  if grep -Eq '^(0\.0\.0\.0|\*):' <<<"$PANEL_LISTEN_ADDRESSES"; then PANEL_BIND_VERIFIED=1; fi
fi
PANEL_FIREWALL_VERIFIED=0
if [[ "$PANEL_ACCESS_MODE" == "private" ]]; then
  if ! ufw status numbered | grep -Fq "# xhttp-vps:${SAFE_INSTANCE} panel"; then PANEL_FIREWALL_VERIFIED=1; fi
else
  if ufw status numbered | grep -Fq "# xhttp-vps:${SAFE_INSTANCE} panel"; then PANEL_FIREWALL_VERIFIED=1; fi
fi

if [[ "$SSH_HARDENING" == 1 ]]; then
  log "Applying the selected SSH policy"
  xhttp_harden_sshd \
    || die "OpenSSH hardening did not pass validation. The current SSH session remains open; repair sshd before disconnecting."
else
  warn "SSH hardening was skipped by explicit user choice."
fi
xhttp_finalize_ssh_port || die 'SSH port migration did not complete. Keep this session open.'
write_state
log "Configuring Fail2ban"
xhttp_install_fail2ban_sshd || die "Fail2ban could not enable and load the sshd jail."
xhttp_configure_panel_fail2ban || die "Fail2ban could not apply the selected panel-access policy."
xhttp_enroll_panel_2fa || die '3x-ui has not confirmed two-factor authentication. Resume setup to finish enrollment.'

log "Final checks"
CHECK_FAILURES=0
status_line() {
  local label="$1" result="$2" detail="${3:-}"
  if [[ "$result" == "OK" ]]; then
    printf '  %-32s %bOK%b%s\n' "$label" "$green" "$plain" "${detail:+ — $detail}"
  elif [[ "$result" == "SKIP" ]]; then
    printf '  %-32s %bSKIP%b%s\n' "$label" "$yellow" "$plain" "${detail:+ — $detail}"
  else
    printf '  %-32s %bERROR%b%s\n' "$label" "$red" "$plain" "${detail:+ — $detail}"
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
  fi
}

printf '\n==================== INSTALLATION AUDIT ====================\n'
if [[ "$INSTALL_MODE" == standalone ]]; then
  if xhttp_verify_traffic; then status_line "VLESS / WARP traffic probe" OK; else status_line "VLESS / WARP traffic probe" ERROR; fi
else
  status_line "VLESS traffic (no client yet)" SKIP
  if [[ "${ENABLE_WARP:-0}" == 1 ]]; then
    if xhttp_verify_traffic warp; then status_line "WARP tunnel traffic" OK; else status_line "WARP tunnel traffic" ERROR; fi
  fi
fi
if [[ "${UBUNTU_UPGRADE_OK:-0}" -eq 1 ]] && apt-get check >/dev/null 2>&1 && [[ -z "$(dpkg --audit)" ]]; then status_line "Ubuntu package upgrade" OK "Ubuntu $UBUNTU_VERSION"; else status_line "Ubuntu package upgrade" ERROR; fi
if apt-get check >/dev/null 2>&1 && [[ -z "$(dpkg --audit)" ]]; then status_line "Required packages" OK; else status_line "Required packages" ERROR; fi
if xhttp_verify_automatic_updates; then
  status_line "Automatic maintenance" OK "$(xhttp_maintenance_label "$MAINTENANCE_MODE")"
else
  status_line "Automatic maintenance" ERROR
fi
if [[ "$SSH_HARDENING" == 1 ]] && xhttp_verify_ssh_access; then
  status_line "SSH access policy" OK "$(xhttp_ssh_access_label "$SSH_ACCESS_MODE")"
elif [[ "$SSH_HARDENING" == 0 && "$SSH_ACCESS_MODE" == existing ]]; then
  status_line "SSH access policy" SKIP "current policy retained by explicit choice"
else
  status_line "SSH access policy" ERROR
fi
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr && "$(sysctl -n net.core.default_qdisc)" == fq ]]; then status_line "BBR + fq" OK; else status_line "BBR + fq" ERROR; fi
if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == 1 ]]; then status_line "IPv6 disabled" OK; else status_line "IPv6 disabled" ERROR; fi
if xhttp_validate_single_dns_ipv4 "$PUBLIC_IP" <<<"$(dig +short A "$DOMAIN")" && ! dig +short AAAA "$DOMAIN" | grep -q .; then status_line "DNS A / AAAA" OK "$DOMAIN → $PUBLIC_IP"; else status_line "DNS A / AAAA" ERROR; fi
if ufw status | grep -q '^Status: active'; then status_line "UFW firewall" OK; else status_line "UFW firewall" ERROR; fi
if openssl x509 -in "$CERT_DIR/fullchain.pem" -checkend 86400 -noout >/dev/null 2>&1; then
  status_line "TLS certificate" OK "$(xhttp_tls_label)"
else
  status_line "TLS certificate" ERROR
fi
if systemctl is-enabled --quiet x-ui && systemctl is-active --quiet x-ui && [[ "$PANEL_HTTPS_VERIFIED" -eq 1 ]]; then status_line "3x-ui panel HTTPS" OK "$DOMAIN:$PANEL_PORT"; else status_line "3x-ui panel HTTPS" ERROR; fi
if [[ "$PANEL_SETTINGS_VERIFIED" -eq 1 ]]; then status_line "Panel settings API" OK "2FA state preserved"; else status_line "Panel settings API" ERROR; fi
if [[ "$PANEL_BIND_VERIFIED" -eq 1 && "$PANEL_FIREWALL_VERIFIED" -eq 1 ]]; then
  case "$PANEL_ACCESS_MODE" in
    private) status_line "Panel network exposure" OK "localhost only" ;;
    allowlist) status_line "Panel network exposure" OK "UFW allowlist: $PANEL_ALLOWED_IP" ;;
    public) status_line "Panel network exposure" OK "public by explicit choice" ;;
  esac
else
  status_line "Panel network exposure" ERROR
fi
if nginx -t >/dev/null 2>&1 && systemctl is-enabled --quiet nginx && systemctl is-active --quiet nginx && port_busy "$FALLBACK_PORT"; then status_line "nginx self-steal" OK "127.0.0.1:$FALLBACK_PORT"; else status_line "nginx self-steal" ERROR; fi
if [[ "$PANEL_HTTPS_VERIFIED" -eq 1 ]]; then status_line "Panel web interface" OK "domain TLS and base path"; else status_line "Panel web interface" ERROR; fi
if curl -kfsSI --resolve "$DOMAIN:$FALLBACK_PORT:127.0.0.1" "https://$DOMAIN:$FALLBACK_PORT/" >/dev/null; then status_line "Cover website" OK; else status_line "Cover website" ERROR; fi
if [[ "$PUBLIC_SELF_STEAL_VERIFIED" -eq 1 ]]; then status_line "Public self-steal website" OK "normal TLS through TCP 443"; else status_line "Public self-steal website" ERROR; fi
if xhttp_probe_foreign_sni; then status_line "Foreign SNI behavior" OK "site certificate withheld"; else status_line "Foreign SNI behavior" ERROR; fi
if xhttp_probe_no_sni; then status_line "Missing SNI behavior" OK "site certificate withheld"; else status_line "Missing SNI behavior" ERROR; fi
if xhttp_probe_h2_alpn; then status_line "Fallback ALPN" OK "HTTP/2 negotiated"; else status_line "Fallback ALPN" ERROR; fi
HTTP_REDIRECT_HEADERS="$(curl -fsSI --resolve "${DOMAIN}:80:127.0.0.1" "http://${DOMAIN}/" 2>/dev/null || true)"
if grep -Eiq "^location:[[:space:]]*https://${DOMAIN}/" <<<"$HTTP_REDIRECT_HEADERS"; then status_line "HTTP / ACME webroot" OK "port 80 redirects; challenge path retained"; else status_line "HTTP / ACME webroot" ERROR; fi
if [[ -n "$PHOTO_MARKUP" ]]; then status_line "Licensed cover photo" OK "$PHOTO_CREDIT / Unsplash"; else status_line "Licensed cover photo" SKIP "site available without image"; fi
if [[ "${INBOUND_CONFIGURED:-0}" -eq 1 && "$INBOUND_VERIFIED" -eq 1 ]] && port_busy 443; then status_line "VPN Reality self-steal" OK "$(xhttp_transport_label "$TRANSPORT"); TCP 443 → 127.0.0.1:$FALLBACK_PORT"; else status_line "VPN Reality self-steal" ERROR; fi
if [[ "${SUBSCRIPTION_CONFIGURED:-0}" -eq 1 ]] && xhttp_verify_loopback_listener "$SUB_PORT"; then
  status_line "Subscription service" OK "127.0.0.1:$SUB_PORT only"
else
  status_line "Subscription service" ERROR "expected a listener only on 127.0.0.1:$SUB_PORT"
fi
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if [[ "$CLIENT_VERIFIED" -eq 1 ]]; then status_line "First VLESS client" OK "$CLIENT_EMAIL"; else status_line "First VLESS client" ERROR; fi
  if [[ "$SUBSCRIPTION_VERIFIED" -eq 1 ]]; then status_line "Client subscription URL" OK "verified through TCP 443"; else status_line "Client subscription URL" ERROR; fi
  if [[ "$SUB_PROTECTION_VERIFIED" -eq 1 ]]; then status_line "Subscription privacy policy" OK; else status_line "Subscription privacy policy" ERROR; fi
  if [[ "$CLIENT_ROUTING_VERIFIED" -eq 1 ]]; then status_line "HAPP + INCY routing" OK "RoscomVPN profiles injected"; else status_line "HAPP + INCY routing" ERROR; fi
  if [[ "$MIHOMO_VERIFIED" -eq 1 ]]; then status_line "Mihomo subscription" OK "YAML endpoint verified"; else status_line "Mihomo subscription" ERROR; fi
else
  if [[ -n "${NODE_API_TOKEN:-}" ]]; then status_line "Node-sync API token" OK "restricted scope"; else status_line "Node-sync API token" ERROR; fi
  status_line "First VLESS client" SKIP "managed by the main panel"
  status_line "Client subscription URL" SKIP "managed by the main panel"
  status_line "HAPP + INCY routing" SKIP "managed by the main panel"
  status_line "Mihomo subscription" SKIP "managed by the main panel"
fi
if systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then status_line "Fail2ban sshd jail" OK; else status_line "Fail2ban sshd jail" ERROR; fi
if [[ "$PANEL_ACCESS_MODE" == public ]]; then
  if fail2ban-client status xhttp-vps-panel >/dev/null 2>&1; then status_line "Fail2ban panel jail" OK; else status_line "Fail2ban panel jail" ERROR; fi
else
  status_line "Fail2ban panel jail" SKIP "panel is not public"
fi
if [[ "$ENABLE_WARP" -eq 1 ]]; then
  if [[ "${WARP_CONFIGURED:-0}" -eq 1 ]]; then status_line "WARP RU routing" OK; else status_line "WARP RU routing" ERROR; fi
else
  status_line "WARP RU routing" SKIP "disabled by user"
fi
MEMORY_KIB_FINAL="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
if [[ "$ENABLE_WARP" -eq 1 && "$MEMORY_KIB_FINAL" =~ ^[0-9]+$ ]] && (( MEMORY_KIB_FINAL <= 1100000 )); then
  if swapon --noheadings --show 2>/dev/null | grep -q .; then
    status_line "Swap for low-memory WARP" OK
  else
    status_line "Swap for low-memory WARP" ERROR "1 GiB swap is required"
  fi
else
  status_line "Swap for low-memory WARP" SKIP "not required"
fi
printf '============================================================\n'

if [[ "$CHECK_FAILURES" -eq 0 ]]; then
  STANDALONE_STATUS_MESSAGE='The standalone VPN server is ready. Add the matching subscription URL to the client.'
  NODE_STATUS_MESSAGE='The remote node setup is ready. Add it to the main panel with the Panel URL and credentials/API token.'
else
  STANDALONE_STATUS_MESSAGE='Installation finished with failed checks. Do not use the subscription until the ERROR items are fixed.'
  NODE_STATUS_MESSAGE='Node installation finished with failed checks. Do not attach it to the main panel until the ERROR items are fixed.'
fi

if [[ "$INSTALL_MODE" == "standalone" ]]; then
  SUBSCRIPTION_URL="https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}"
  MIHOMO_SUBSCRIPTION_URL="$MIHOMO_ROUTING_URL"
  SUBSCRIPTION_DISPLAY="$(xhttp_subscription_links "$SUBSCRIPTION_URL" "$CLIENT_EMAIL")" \
    || die "Could not generate the selected HAPP and INCY subscription links."
  printf -v MODE_DETAILS 'FIRST CLIENT: %s\n%s\nMIHOMO SUBSCRIPTION: %s\n\n%s' \
    "$CLIENT_EMAIL" "$SUBSCRIPTION_DISPLAY" "$MIHOMO_SUBSCRIPTION_URL" "$STANDALONE_STATUS_MESSAGE"
else
  printf -v MODE_DETAILS 'NODE TOKEN:  %s\n\n%s\nThe local inbound is already created; do not deploy a duplicate on port 443.' "${NODE_API_TOKEN:-not created}" "$NODE_STATUS_MESSAGE"
fi

case "$PANEL_ACCESS_MODE" in
  private)
    PANEL_DISPLAY_URL="https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}/"
    PANEL_ACCESS_DETAILS="localhost only; use an SSH tunnel or private Tailscale Serve"
    ;;
  allowlist)
    PANEL_DISPLAY_URL="https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}/"
    PANEL_ACCESS_DETAILS="only ${PANEL_ALLOWED_IP} is allowed by UFW"
    ;;
  public)
    PANEL_DISPLAY_URL="https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}/"
    PANEL_ACCESS_DETAILS="public Internet; 2FA is recommended as additional protection"
    ;;
esac

umask 077
{
  printf 'MODE: %s\n' "$INSTALL_MODE"
  printf 'TLS MODE: %s\n' "$TLS_MODE"
  printf '%s: %s\n' "$([[ "$INSTALL_MODE" == "standalone" ]] && echo "VPN NAME" || echo "NODE NAME")" "$VPN_NAME"
  printf 'PANEL URL: %s\n' "$PANEL_DISPLAY_URL"
  printf 'PANEL ACCESS: %s\n' "$PANEL_ACCESS_DETAILS"
  printf 'LOGIN: %s\nPASSWORD: %s\n' "$PANEL_USERNAME" "$PANEL_PASSWORD"
  printf 'VPN TRANSPORT: %s\n' "$(xhttp_transport_label "$TRANSPORT")"
  xhttp_print_ssh_connection
  printf 'MAINTENANCE: %s\n' "$(xhttp_maintenance_label "$MAINTENANCE_MODE")"
  if [[ "${PANEL_2FA_ENROLL:-0}" == 1 ]]; then printf 'PANEL 2FA: Verified\n'; fi
  if [[ "${DISABLE_PING:-0}" == 1 ]]; then printf 'IPV4 PING REPLIES: Disabled\n'; fi
  printf '%s\n' "$MODE_DETAILS"
  if [[ "$INSTALL_MODE" == "standalone" ]]; then
    printf '\nMAIN SERVER — COPY OR SAVE\n'
    printf '%s\n' '---------------------------------------------------------------'
    printf 'Panel URL: %s\n' "$PANEL_DISPLAY_URL"
    printf 'Panel login: %s\n' "$PANEL_USERNAME"
    printf 'Panel password: %s\n' "$PANEL_PASSWORD"
    printf '%s\n' "$SUBSCRIPTION_DISPLAY"
    if [[ -s "$MANAGED_BACKUP/migration.done" ]]; then printf 'Imported VLESS clients: %s\n' "$(cat "$MANAGED_BACKUP/migration.done")"; fi
    printf 'Mihomo subscription: %s\n' "$MIHOMO_SUBSCRIPTION_URL"
    printf '%s\n' '---------------------------------------------------------------'
  else
    printf '\nNODE CONNECTION — COPY TO THE MAIN 3X-UI PANEL\n'
    printf '%s\n' '---------------------------------------------------------------'
    printf 'Name: %s\n' "$VPN_NAME"
    printf 'Remark: \n'
    printf 'Scheme: https\n'
    printf 'Address: %s\n' "$DOMAIN"
    printf 'Port: %s\n' "$PANEL_PORT"
    printf 'Base Path: /%s/\n' "$PANEL_PATH"
    printf 'Enabled: yes\n'
    printf 'Allow private address: no\n'
    printf 'TLS verification: Verify (default CA)\n'
    printf 'API Token: %s\n' "$NODE_API_TOKEN"
    printf '%s\n' '---------------------------------------------------------------'
  fi
} > "$RESULT_FILE"
chmod 600 "$RESULT_FILE"
umask 022

if [[ "$CHECK_FAILURES" -ne 0 ]]; then
  printf '\n%b================================================================%b\n' "$red" "$plain"
  printf '%bRESULT: %s CHECK(S) FAILED%b\n' "$red" "$CHECK_FAILURES" "$plain"
  printf '%bFix every line marked ERROR above before using the VPN or subscriptions.%b\n' "$yellow" "$plain"
  printf '%bSaved configuration:%b %s\n%bSaved result:%b        %s\n' "$yellow" "$plain" "$STATE_FILE" "$yellow" "$plain" "$RESULT_FILE"
  printf '%bSuggested solution:%b Review the failed checks, then run: %s\n' "$yellow" "$plain" "$RECOVERY_SCRIPT"
  printf '%bDiagnostics:%b systemctl status x-ui nginx --no-pager; nginx -t; journalctl -u x-ui -n 100 --no-pager\n' "$yellow" "$plain"
  printf '%b================================================================%b\n' "$red" "$plain"
  exit 1
fi

INSTALL_PHASE=complete
write_state

# On success, remove the noisy installation transcript from the visible terminal.
# Credentials and subscription URLs are retained in the protected result file above.
clear || true
printf '%b================================================================%b\n' "$green" "$plain"
printf '%b                 VPN INSTALLATION COMPLETED SUCCESSFULLY%b\n' "$green" "$plain"
printf '%b                     ALL APPLICABLE CHECKS PASSED%b\n' "$green" "$plain"
printf '%b================================================================%b\n\n' "$green" "$plain"
printf '%b%s:%b          %s\n' "$blue" "$([[ "$INSTALL_MODE" == "standalone" ]] && echo "VPN" || echo "NODE")" "$plain" "$VPN_NAME"
printf '%bTLS:%b          %s\n\n' "$blue" "$plain" "$(xhttp_tls_label)"
printf '%bPANEL%b\n' "$cyan" "$plain"
printf '  %bURL:%b      %s\n' "$yellow" "$plain" "$PANEL_DISPLAY_URL"
printf '  %bAccess:%b   %s\n' "$yellow" "$plain" "$PANEL_ACCESS_DETAILS"
printf '  %bLogin:%b    %s\n' "$yellow" "$plain" "$PANEL_USERNAME"
printf '  %bPassword:%b %s\n\n' "$yellow" "$plain" "$PANEL_PASSWORD"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  printf '%bMAIN SERVER — COPY OR SAVE%b\n' "$cyan" "$plain"
  printf '%b---------------------------------------------------------------%b\n' "$yellow" "$plain"
  printf 'Panel URL: %s\n' "$PANEL_DISPLAY_URL"
  printf 'Panel login: %s\n' "$PANEL_USERNAME"
  printf 'Panel password: %s\n' "$PANEL_PASSWORD"
  printf '%s\n' "$SUBSCRIPTION_DISPLAY"
  printf 'Mihomo subscription: %s\n' "$MIHOMO_SUBSCRIPTION_URL"
  printf '%b---------------------------------------------------------------%b\n' "$yellow" "$plain"
  printf '%bRouting:%b HAPP and INCY RoscomVPN routing profiles are included.\n\n' "$cyan" "$plain"
else
  printf '%bNODE CONNECTION — COPY TO THE MAIN 3X-UI PANEL%b\n' "$cyan" "$plain"
  printf '%b---------------------------------------------------------------%b\n' "$yellow" "$plain"
  printf 'Name: %s\n' "$VPN_NAME"
  printf 'Remark: \n'
  printf 'Scheme: https\n'
  printf 'Address: %s\n' "$DOMAIN"
  printf 'Port: %s\n' "$PANEL_PORT"
  printf 'Base Path: /%s/\n' "$PANEL_PATH"
  printf 'Enabled: yes\n'
  printf 'Allow private address: no\n'
  printf 'TLS verification: Verify (default CA)\n'
  printf 'API Token: %s\n' "$NODE_API_TOKEN"
  printf '%b---------------------------------------------------------------%b\n' "$yellow" "$plain"
  printf '%bIn the main panel:%b Nodes → Add node. Fill in the fields above; leave Remark empty.\n\n' "$cyan" "$plain"
fi
if [[ "$PANEL_ACCESS_MODE" == "private" ]]; then
  printf '%bSSH tunnel:%b ssh -p %s -L %s:127.0.0.1:%s %s@%s\n' "$cyan" "$plain" "$SSH_PORT" "$PANEL_PORT" "$PANEL_PORT" "$ADMIN_USER" "$DOMAIN"
  printf '%bMobile:%b create the same local-port forwarding in Termius, or expose localhost privately with Tailscale Serve.\n\n' "$cyan" "$plain"
fi
printf '%bVPN inbound:%b %s on TCP/443\n' "$blue" "$plain" "$(xhttp_transport_label "$TRANSPORT")"
xhttp_print_ssh_connection
printf '%bMaintenance:%b %s\n' "$blue" "$plain" "$(xhttp_maintenance_label "$MAINTENANCE_MODE")"
printf '%bWARP routing:%b %s\n' "$blue" "$plain" "$([[ "$ENABLE_WARP" -eq 1 ]] && echo ENABLED || echo DISABLED)"
printf '%bSaved result:%b %s\n' "$blue" "$plain" "$RESULT_FILE"
printf '%bSaved state:%b  %s\n' "$blue" "$plain" "$STATE_FILE"
if [[ -f /var/run/reboot-required ]]; then
  printf '\n%bREBOOT RECOMMENDED:%b Ubuntu updates require a reboot.\n' "$yellow" "$plain"
fi
printf '\n%bKeep the panel password and subscription URLs private.%b\n' "$yellow" "$plain"
if [[ "$SSH_HARDENING" == 1 ]]; then
  printf '%bBefore closing this session, test a new login using the SSH connection block above.%b\n' "$yellow" "$plain"
else
  printf '%bWARNING: the current SSH policy was retained and may still permit password/root login.%b\n' "$red" "$plain"
fi
if [[ "$PANEL_ACCESS_MODE" == public ]]; then
  printf '%bPublic panel selected: 2FA is recommended as additional protection; store its recovery codes offline.%b\n' "$yellow" "$plain"
fi
if [[ "$TWO_FACTOR_GUIDE" == 1 ]]; then
  printf '%b2FA setup:%b open Panel Settings, enable 2FA, scan the QR code and store recovery codes offline.\n' "$cyan" "$plain"
fi
printf '%s\n' 'From another network, open the website, refresh subscriptions in your VPN apps, and test that the panel follows the chosen access policy.'
if [[ "${CREATE_RECOVERY_BACKUP:-0}" == 1 ]]; then
  xhttp_export_recovery_backup "$STATE_FILE" || warn 'Backup skipped. You can retry using menu item 5.'
fi
if [[ "$INSTALL_MODE" == node ]]; then
  printf 'Node traffic is not verified until a client is provisioned by the main panel.\n'
fi
printf '%b================================================================%b\n' "$green" "$plain"
