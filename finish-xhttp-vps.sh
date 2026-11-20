#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 yazmann
set -Eeuo pipefail

green='\033[1;32m'; yellow='\033[1;33m'; red='\033[1;31m'; cyan='\033[1;36m'; blue='\033[1;34m'; plain='\033[0m'
CURRENT_STEP='repair startup'
die() {
  local reason="$1" solution="${2:-Fix the reason above, then run: /root/finish-xhttp-vps.sh}"
  printf '\n%b================================================================%b\n' "$red" "$plain" >&2
  printf '%bREPAIR STOPPED%b\n' "$red" "$plain" >&2
  printf '%bReason:%b %s\n%bCurrent step:%b %s\n' "$red" "$plain" "$reason" "$yellow" "$plain" "$CURRENT_STEP" >&2
  printf '%bSuggested solution:%b %s\n' "$yellow" "$plain" "$solution" >&2
  printf '%b================================================================%b\n' "$red" "$plain" >&2
  exit 1
}
unexpected_error() {
  local exit_code="$1" line="$2"
  printf '\n%bUNEXPECTED REPAIR ERROR:%b step "%s", line %s, exit code %s.\n' "$red" "$plain" "$CURRENT_STEP" "$line" "$exit_code" >&2
  printf '%bSuggested solution:%b Fix the cause, then run: /root/finish-xhttp-vps.sh\n' "$yellow" "$plain" >&2
}
trap 'unexpected_error "$?" "$LINENO"' ERR
[[ ${EUID} -eq 0 ]] || die "Run as root."
COMMON_SCRIPT="$(dirname "$(readlink -f "$0")")/xhttp-vps-common.sh"
[[ -r "$COMMON_SCRIPT" ]] || die "Place xhttp-vps-common.sh alongside this repair script."
# shellcheck source=xhttp-vps-common.sh
source "$COMMON_SCRIPT"
MIGRATION_SCRIPT="$(dirname "$COMMON_SCRIPT")/xhttp-vps-migrate.sh"
if [[ -r "$MIGRATION_SCRIPT" ]]; then
  # shellcheck source=xhttp-vps-migrate.sh
  source "$MIGRATION_SCRIPT"
fi
xhttp_lock || die "Another setup or repair is already running."
mapfile -t STATE_FILES < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
[[ ${#STATE_FILES[@]} -eq 1 ]] || die "Expected exactly one 3x-ui installer state file in /root; found ${#STATE_FILES[@]}."
# shellcheck disable=SC1090
source "${STATE_FILES[0]}"
INITIAL_INSTALL_PHASE="${INSTALL_PHASE:-}"
if [[ "${INSTALL_PHASE:-}" == bootstrap ]] || ! xhttp_uses_panel; then
  exec "$(dirname "$(readlink -f "$0")")/install-xhttp-vps.sh" --resume
fi
if [[ ! -x /usr/local/x-ui/x-ui || ! -s "/root/cert/${DOMAIN}/fullchain.pem" || ! -s /etc/nginx/sites-available/3xui-self-steal.conf ]]; then
  xhttp_validate_state && [[ -f "$MANAGED_BACKUP/ready" ]] \
    || die "Incomplete legacy installation has no ownership journal; restore its prerequisites manually."
  printf 'INSTALL_PHASE=bootstrap\n' >> "${STATE_FILES[0]}"
  exec "$(dirname "$(readlink -f "$0")")/install-xhttp-vps.sh" --resume
fi
: "${SUB_PATH:?State file does not contain SUB_PATH}"
: "${INSTALL_MODE:=node}"
: "${TLS_MODE:=production}"
: "${INSTANCE_NAME:=${NODE_NAME:-VPN}}"
: "${VPN_NAME:=$INSTANCE_NAME}"
# Legacy state files predate private panel modes and historically published the
# panel. Preserve that behavior during repair instead of silently locking out
# their administrators.
: "${PANEL_ACCESS_MODE:=public}"
: "${PANEL_ALLOWED_IP:=}"
: "${TRANSPORT:=xhttp}"
: "${INBOUND_TAG:=$(xhttp_inbound_tag_for "$TRANSPORT")}"
: "${MAINTENANCE_TIMEZONE:=Europe/Moscow}"
: "${MAINTENANCE_MODE:=weekly}"
: "${TWO_FACTOR_GUIDE:=0}"
: "${SUB_ENCRYPT_LINKS:=}"
: "${SSH_HARDENING:=0}"
if [[ -z "${SSH_ACCESS_MODE:-}" ]]; then
  if [[ "$SSH_HARDENING" == 1 ]]; then SSH_ACCESS_MODE='admin'; else SSH_ACCESS_MODE='existing'; fi
fi
: "${ADMIN_USER:=root}"
: "${ADMIN_KEYS_B64:=}"
: "${ADMIN_KEY_FINGERPRINTS:=}"
: "${NODE_API_TOKEN:=}"
case "$TRANSPORT" in vision|xhttp) ;; *) die "State contains an invalid transport: ${TRANSPORT}" ;; esac
case "$PANEL_ACCESS_MODE" in
  private|public) ;;
  allowlist) xhttp_valid_ipv4 "$PANEL_ALLOWED_IP" || die "State contains an invalid panel allowlist IPv4." ;;
  *) die "State contains an invalid panel access mode: ${PANEL_ACCESS_MODE}" ;;
esac
STATE_PANEL_API_TOKEN="${PANEL_API_TOKEN:-}"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  : "${SUB_JSON_PATH:=json-$(od -An -N 10 -tx1 /dev/urandom|tr -d ' \n')}"
  : "${SUB_CLASH_PATH:=mihomo-$(od -An -N 10 -tx1 /dev/urandom|tr -d ' \n')}"
  : "${MIHOMO_ROUTING_PATH:=mihomo-routing-$(od -An -N 10 -tx1 /dev/urandom|tr -d ' \n').yaml}"
fi
if [[ -r /etc/x-ui/install-result.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/install-result.env
  PANEL_USERNAME="${XUI_USERNAME:-$PANEL_USERNAME}"
  PANEL_PASSWORD="${XUI_PASSWORD:-$PANEL_PASSWORD}"
  PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
  PANEL_PATH="${XUI_WEB_BASE_PATH:-$PANEL_PATH}"
  PANEL_API_TOKEN="${STATE_PANEL_API_TOKEN:-${XUI_API_TOKEN:-${PANEL_API_TOKEN:-}}}"
  PANEL_PATH="${PANEL_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}"
fi
for cmd in curl jq sqlite3; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
if [[ "$SSH_HARDENING" == 1 ]]; then
  : "${ADMIN_USER:?State file does not contain ADMIN_USER}"
  : "${ADMIN_KEYS_B64:?State file does not contain ADMIN_KEYS_B64}"
  : "${ADMIN_KEY_FINGERPRINTS:=$(xhttp_authorized_key_fingerprints "$ADMIN_KEYS_B64")}"
fi
[[ -n "${PANEL_API_TOKEN:-}" ]] || die "State/install-result does not contain the 3x-ui API token."
xhttp_validate_state && xhttp_record_ownership \
  || die "State or managed-file ownership journal is invalid; repair stopped before changing files."
REPAIR_BACKUP="$(mktemp -d /root/xhttp-repair-backup.XXXXXXXX)"
chmod 700 "$REPAIR_BACKUP"
sqlite3 /etc/x-ui/x-ui.db ".timeout 5000" ".backup '$REPAIR_BACKUP/x-ui.db'"
chmod 600 "$REPAIR_BACKUP/x-ui.db"
printf 'Database backup before repair: %s\n' "$REPAIR_BACKUP"
CERT_DIR="/root/cert/$DOMAIN"
[[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] || die "Certificate files are missing. Resume bootstrap before configuring the panel."
{
  printf 'SUB_JSON_PATH=%q\n' "${SUB_JSON_PATH:-}"
  printf 'SUB_CLASH_PATH=%q\n' "${SUB_CLASH_PATH:-}"
  printf 'MIHOMO_ROUTING_PATH=%q\n' "${MIHOMO_ROUTING_PATH:-}"
} >> "${STATE_FILES[0]}"
# Keep proxy locations in sync with recovered subscription paths.
NGINX_CONFIG=/etc/nginx/sites-available/3xui-self-steal.conf
if [[ -e "$NGINX_CONFIG" ]]; then cp -a "$NGINX_CONFIG" "$REPAIR_BACKUP/nginx.conf"; fi
xhttp_install_nginx
systemctl enable --now nginx
systemctl reload nginx
if [[ "${ACME_CLIENT:-}" == certbot ]]; then xhttp_install_cert_renewal; fi

API_BASE="https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}"
API_HEADER_FILE="$(xhttp_create_api_header_file "$PANEL_API_TOKEN")" \
  || die "The panel API token is empty or contains invalid control characters."
API_AUTH=(--cacert "$(xhttp_tls_ca_file)" --noproxy '*' --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" -H "@${API_HEADER_FILE}")
trap 'rm -f "${API_HEADER_FILE:-}"' EXIT

configure_warp_swap() {
  local memory_kib free_kib
  memory_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
  if ! [[ "$memory_kib" =~ ^[0-9]+$ ]] || (( memory_kib > 1100000 )); then
    return 0
  fi
  if swapon --noheadings --show 2>/dev/null | grep -q .; then
    printf '%b[STEP]%b Keeping existing swap for low-memory WARP VPS\n' "$cyan" "$plain"
    return 0
  fi
  if [[ -e /swapfile ]]; then
    printf '%bWARNING:%b Low-memory WARP VPS has /swapfile, but it is not active. The repair script will not modify an existing file.\n' "$yellow" "$plain" >&2
    return 0
  fi
  free_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
  if ! [[ "$free_kib" =~ ^[0-9]+$ ]] || (( free_kib < 1310720 )); then
    printf '%bWARNING:%b Low-memory WARP VPS has insufficient free disk space for the required 1 GiB swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  printf '%b[STEP]%b Adding 1 GiB swap for low-memory WARP VPS\n' "$cyan" "$plain"
  if ! fallocate -l 1G /swapfile; then
    printf '%bWARNING:%b Could not allocate /swapfile; continuing without managed swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  chmod 600 /swapfile
  if ! mkswap /swapfile >/dev/null; then
    rm -f /swapfile
    printf '%bWARNING:%b Could not format /swapfile; continuing without managed swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  if ! swapon /swapfile; then
    rm -f /swapfile
    printf '%bWARNING:%b Could not enable /swapfile; continuing without managed swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  if ! printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab; then
    swapoff /swapfile || die "Cannot persist or disable /swapfile. The active file has been preserved; repair /etc/fstab manually."
    rm -f /swapfile
    printf '%bWARNING:%b Could not persist /swapfile in /etc/fstab; continuing without managed swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  printf '\nSWAP_CREATED_BY_SCRIPT=1\n' >> "${STATE_FILES[0]}"
}

xhttp_restart_vpn_service x-ui
READY=0; R=""
for _ in $(seq 1 15); do
  R="$(curl -q -fsS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 "$API_BASE/panel/api/server/status" 2>&1 || true)"
  if jq -e '.success==true' <<<"$R" >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
if [[ "$READY" -eq 0 && "$R" == *'error: 401'* ]]; then
  printf '%bAPI token required:%b the saved token was rejected by the panel. In the panel open Settings → API Tokens, create a token named xhttp-recovery, then paste it below.\n' "$yellow" "$plain" >&2
  read -r -s -p "New API token (input is hidden): " PANEL_API_TOKEN
  printf '\n' >&2
  if [[ -n "$PANEL_API_TOKEN" ]]; then
    rm -f "$API_HEADER_FILE"
    API_HEADER_FILE="$(xhttp_create_api_header_file "$PANEL_API_TOKEN")" \
      || die "The replacement API token contains invalid control characters."
    API_AUTH=(--cacert "$(xhttp_tls_ca_file)" --noproxy '*' --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" -H "@${API_HEADER_FILE}")
    printf '\nPANEL_API_TOKEN=%q\n' "$PANEL_API_TOKEN" >> "${STATE_FILES[0]}"
    READY=0
    for _ in $(seq 1 15); do
      R="$(curl -q -fsS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 "$API_BASE/panel/api/server/status" 2>&1 || true)"
      if jq -e '.success==true' <<<"$R" >/dev/null 2>&1; then READY=1; break; fi
      sleep 1
    done
  fi
fi
[[ "$READY" -eq 1 ]] || { systemctl status x-ui --no-pager || true; /usr/local/x-ui/x-ui setting -show true 2>/dev/null || true; die "Private bearer API failed after 15 attempts. Last response: ${R:-<empty>}"; }

CURRENT_STEP='configuring subscription service'
printf '\n%b[STEP]%b %s\n' "$cyan" "$plain" "$CURRENT_STEP"
R="$(curl -q -fsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/setting/all")"
jq -e '.success==true and .obj!=null' <<<"$R" >/dev/null || die "Could not read panel settings: $R"
S="$(jq -c '.obj|if type=="string" then fromjson else . end' <<<"$R")"
jq -e 'type=="object"' <<<"$S" >/dev/null || die "Panel settings have an unexpected format."
S="$(jq -c --arg d "$DOMAIN" --arg title "$VPN_NAME" --argjson p "$SUB_PORT" --arg path "/${SUB_PATH}/" \
  --arg cert "/root/cert/${DOMAIN}/fullchain.pem" --arg key "/root/cert/${DOMAIN}/privkey.pem" '
  .subEnable=true|.subEncrypt=true|.subListen="127.0.0.1"|.subDomain=$d|.subPort=$p|.subPath=$path
  |.subCertFile=$cert|.subKeyFile=$key|.subURI=("https://"+$d+$path)|.subTitle=$title' <<<"$S")"
S="$(xhttp_subscription_profile_settings <<<"$S")"
ROUTING_CONFIGURED=0; MIHOMO_CONFIGURED=0
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if [[ -n "$SUB_ENCRYPT_LINKS" ]]; then
    S="$(jq -c --argjson enabled "$SUB_ENCRYPT_LINKS" '.happLinkEnable=$enabled' <<<"$S")"
  fi
  ROUTING_REVISION="$(xhttp_routing_revision || true)"
  HAPP_ROUTING="$(xhttp_fetch_routing "$ROUTING_REVISION" HAPP/DEFAULT.DEEPLINK 2>/dev/null || true)"
  INCY_ROUTING="$(xhttp_fetch_routing "$ROUTING_REVISION" INCY/DEFAULT.DEEPLINK 2>/dev/null || true)"
  if [[ "$HAPP_ROUTING" == happ://routing/onadd/* && "$INCY_ROUTING" == incy://routing/onadd/* ]]; then
    S="$(jq -c --arg happ "$HAPP_ROUTING" --arg incy "$INCY_ROUTING" --arg jp "/${SUB_JSON_PATH}/" --arg cp "/${SUB_CLASH_PATH}/" --arg ju "https://${DOMAIN}/${SUB_JSON_PATH}/" --arg cu "https://${DOMAIN}/${SUB_CLASH_PATH}/" '.subEnableRouting=true|.subRoutingRules=$happ|.subIncyEnableRouting=true|.subIncyRoutingRules=$incy|.subJsonEnable=true|.subJsonPath=$jp|.subJsonURI=$ju|.subClashEnable=true|.subClashPath=$cp|.subClashURI=$cu|.subClashEnableRouting=false' <<<"$S")"
    ROUTING_CONFIGURED=1; MIHOMO_CONFIGURED=1
  fi
fi
R="$(curl -q -fsS "${API_AUTH[@]}" -H 'Content-Type: application/json' \
  -X POST "$API_BASE/panel/api/setting/update" --data-binary "$S")"
jq -e '.success==true' <<<"$R" >/dev/null || die "Subscription setup failed: $R"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  CURRENT_STEP='creating Mihomo subscription with RoscomVPN routing'
  printf '\n%b[STEP]%b %s\n' "$cyan" "$plain" "$CURRENT_STEP"
  MIHOMO_PROVIDER_URL="https://${DOMAIN}/${SUB_CLASH_PATH}/${CLIENT_SUB_ID}"
  MIHOMO_ROUTING_URL="https://${DOMAIN}/${MIHOMO_ROUTING_PATH}"
  MIHOMO_TEMPLATE="$(xhttp_fetch_routing "$ROUTING_REVISION" MIHOMO/default.yaml 2>/dev/null || true)"
  if grep -Fq '<ВВЕДИТЕ URL ПОДПИСКИ>' <<<"$MIHOMO_TEMPLATE"; then
    printf '%s\n' "$MIHOMO_TEMPLATE" | sed "s|<ВВЕДИТЕ URL ПОДПИСКИ>|${MIHOMO_PROVIDER_URL}|g" > "/var/www/3xui-cover/${MIHOMO_ROUTING_PATH}"
    chmod 644 "/var/www/3xui-cover/${MIHOMO_ROUTING_PATH}"
    MIHOMO_CONFIGURED=1
    printf 'MIHOMO_ROUTING_PATH=%s\n' "$MIHOMO_ROUTING_PATH" >> "${STATE_FILES[0]}"
  else
    MIHOMO_CONFIGURED=0
    printf '%bWARNING:%b RoscomVPN Mihomo template could not be downloaded; the Mihomo routing subscription is unavailable.\n' "$yellow" "$plain" >&2
  fi
fi

CURRENT_STEP='restoring Xray policy defaults if the old memory profile is present'
xhttp_restore_policy_defaults || die "Could not restore Xray policy defaults."

WARP_CONFIGURED=0
if [[ "${ENABLE_WARP:-0}" -eq 1 ]]; then
  CURRENT_STEP='configuring Cloudflare WARP over MASQUE for Russian traffic'
  printf '\n%b[STEP]%b %s\n' "$cyan" "$plain" "$CURRENT_STEP"
  xhttp_configure_warp_masque || die "Could not configure a verified MASQUE exit for Russian traffic."
  WARP_CONFIGURED=1
  configure_warp_swap
fi

CURRENT_STEP="creating or repairing $(xhttp_transport_label "$TRANSPORT") inbound"
printf '\n%b[STEP]%b %s\n' "$cyan" "$plain" "$CURRENT_STEP"
R="$(curl -q -fsS "${API_AUTH[@]}" "$API_BASE/panel/api/inbounds/list")"
jq -e '.success==true and .obj!=null' <<<"$R" >/dev/null || die "Could not read inbounds: $R"
INBOUNDS="$(jq -c '.obj|if type=="string" then fromjson else . end' <<<"$R")"
jq -e 'type=="array"' <<<"$INBOUNDS" >/dev/null || die "Inbound list has an unexpected format."
EXISTING_INBOUND="$(jq -c --arg tag "$INBOUND_TAG" 'map(select(.tag==$tag))|first // empty' <<<"$INBOUNDS")"
if [[ -z "$EXISTING_INBOUND" ]] && jq -e 'any(.port==443)' <<<"$INBOUNDS" >/dev/null; then
  die "TCP/443 is occupied by an unmanaged inbound; recovery will not overwrite it."
fi
if [[ -n "$EXISTING_INBOUND" ]]; then
  # Rebuild only installer-owned transport fields. Quotas, clients, enable state,
  # counters, REALITY identities and every short ID remain untouched.
  IB="$(xhttp_rebuild_managed_inbound "$TRANSPORT" "$DOMAIN" "127.0.0.1:${FALLBACK_PORT}" "$INBOUND_TAG" <<<"$EXISTING_INBOUND")" \
    || die "Existing inbound has invalid settings or incomplete REALITY identities. Recovery will not rotate client credentials."
  INBOUND_ID="$(jq -r '.id' <<<"$IB")"
  EXISTING_STREAM="$(jq -c '.streamSettings|fromjson' <<<"$IB")"
  PUB_R="$(jq -r '.realitySettings.settings.publicKey' <<<"$EXISTING_STREAM")"
  SID="$(jq -r '.realitySettings.shortIds[0]' <<<"$EXISTING_STREAM")"
  R="$(curl -q -fsS "${API_AUTH[@]}" -H 'Content-Type: application/json' -X POST "$API_BASE/panel/api/inbounds/update/${INBOUND_ID}" --data-binary "$IB")"
  jq -e '.success==true' <<<"$R" >/dev/null || die "Inbound repair failed: $R"
  REALITY_PUBLIC="$PUB_R"; SHORT_ID="$SID"
else
  R="$(curl -q -fsS "${API_AUTH[@]}" "$API_BASE/panel/api/server/getNewX25519Cert")"
  PRIV_R="$(jq -r '.obj.privateKey//.obj.private//empty' <<<"$R")"; PUB_R="$(jq -r '.obj.publicKey//.obj.public//empty' <<<"$R")"
  [[ -n "$PRIV_R" && -n "$PUB_R" ]] || die "Reality key generation failed: $R"
  SID="$(od -An -N 8 -tx1 /dev/urandom|tr -d ' \n')"
  if [[ "$INSTALL_MODE" == "standalone" ]]; then
    : "${CLIENT_UUID:=$(cat /proc/sys/kernel/random/uuid)}"
    : "${CLIENT_SUB_ID:=$(od -An -N 8 -tx1 /dev/urandom|tr -d ' \n')}"
    : "${CLIENT_EMAIL:=${INSTANCE_NAME}-primary}"
    IS="$(jq -nc --arg id "$CLIENT_UUID" --arg email "$CLIENT_EMAIL" --arg sub "$CLIENT_SUB_ID" --arg flow "$(xhttp_transport_flow "$TRANSPORT")" '{clients:[{id:$id,flow:$flow,email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,reset:0}],decryption:"none",encryption:"none",fallbacks:[]}')"
  else
    IS="$(jq -nc '{clients:[],decryption:"none",encryption:"none",fallbacks:[]}')"
  fi
  ST="$(xhttp_build_stream_settings "$TRANSPORT" "$DOMAIN" "127.0.0.1:${FALLBACK_PORT}" "$PRIV_R" "$PUB_R" "$SID")" \
    || die "Could not build ${TRANSPORT} stream settings."
  SN="$(jq -nc '{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}')"
  IB="$(jq -nc --arg r "${VPN_NAME}" --arg s "$IS" --arg t "$ST" --arg n "$SN" --arg tag "$INBOUND_TAG" '{up:0,down:0,total:0,remark:$r,enable:true,expiryTime:0,trafficReset:"never",listen:"",port:443,protocol:"vless",settings:$s,streamSettings:$t,tag:$tag,sniffing:$n}')"
  R="$(curl -q -fsS "${API_AUTH[@]}" -H 'Content-Type: application/json' -X POST "$API_BASE/panel/api/inbounds/add" --data-binary "$IB")"
  jq -e '.success==true' <<<"$R" >/dev/null || die "Inbound creation failed: $R"
  REALITY_PUBLIC="$PUB_R"; SHORT_ID="$SID"
  {
    printf 'CLIENT_UUID=%s\nCLIENT_SUB_ID=%s\nCLIENT_EMAIL=%s\n' "${CLIENT_UUID:-}" "${CLIENT_SUB_ID:-}" "${CLIENT_EMAIL:-}"
    printf 'REALITY_PUBLIC=%s\nSHORT_ID=%s\n' "$REALITY_PUBLIC" "$SHORT_ID"
  } >> "${STATE_FILES[0]}"
fi

if [[ -n "${MIGRATION_DB:-}" ]]; then
  CURRENT_STEP='importing VLESS users and usage'
  [[ -r "$MIGRATION_SCRIPT" ]] || die "SQLite migration helpers are missing."
  xhttp_import_migrated_clients
fi


xhttp_restart_vpn_service x-ui
sleep 2
READY=0; R=""
for _ in $(seq 1 40); do
  R="$(curl -q -fsS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 "$API_BASE/panel/api/server/status" 2>&1 || true)"
  if jq -e '.success==true' <<<"$R" >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
[[ "$READY" -eq 1 ]] || die "Private bearer API failed after the final restart. Last response: ${R:-<empty>}"
if [[ "$INSTALL_MODE" == "node" && -z "${NODE_API_TOKEN:-}" ]]; then
  CURRENT_STEP='creating a least-privilege node-sync API token'
  NODE_API_TOKEN="$(xhttp_rotate_node_sync_token xhttp-node-sync)" \
    || die "Could not create the restricted node-sync API token. The local administrator token was not exported."
  printf '\nNODE_API_TOKEN=%q\n' "$NODE_API_TOKEN" >> "${STATE_FILES[0]}"
fi
INBOUND_OK=0; CLIENT_OK=0; SUB_OK=0; SUB_PROTECTION_OK=0; SELF_STEAL_OK=0; ROUTING_OK=0; MIHOMO_OK=0
R="$(curl -q -fsS "${API_AUTH[@]}" "$API_BASE/panel/api/inbounds/list" || true)"
if jq -e --arg d "$DOMAIN" --arg t "127.0.0.1:${FALLBACK_PORT}" --arg transport "$TRANSPORT" --arg tag "$INBOUND_TAG" '
  .success==true and ((.obj|if type=="string" then fromjson else . end)|any(
    .port==443 and .protocol=="vless" and .enable==true and .tag==$tag and
    ((.streamSettings|if type=="string" then fromjson else . end) as $s |
      $s.security=="reality" and (($s.realitySettings.target//$s.realitySettings.dest)==$t) and
      (($s.realitySettings.serverNames//[])|index($d))!=null and
      (if $transport=="vision" then
         ($s.network=="tcp" or $s.network=="raw") and (($s.tcpSettings.header.type//"none")=="none")
       else $s.network=="xhttp" and $s.xhttpSettings.host==$d and $s.xhttpSettings.path=="/" end))))
' <<<"$R" >/dev/null 2>&1; then INBOUND_OK=1; fi
for _ in $(seq 1 20); do
  if xhttp_probe_cover_website 2>/dev/null; then SELF_STEAL_OK=1; break; fi
  sleep 1
done
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if jq -e --arg id "${CLIENT_UUID:-}" --arg sub "${CLIENT_SUB_ID:-}" --arg flow "$(xhttp_transport_flow "$TRANSPORT")" '.success==true and ((.obj|if type=="string" then fromjson else . end)|any(.port==443 and .protocol=="vless" and ((.settings|if type=="string" then fromjson else . end).clients|any(.id==$id and .subId==$sub and .enable==true and (.flow//"")==$flow))))' <<<"$R" >/dev/null 2>&1; then CLIENT_OK=1; fi
  for _ in $(seq 1 20); do
    SUB_DATA="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 "https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}" 2>/dev/null || true)"
    [[ -n "$SUB_DATA" ]] && { SUB_OK=1; break; }
    sleep 1
  done
  if [[ "$SUB_OK" -eq 1 ]]; then
    SUB_HEADERS="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 -D - -o /dev/null "https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}" 2>/dev/null || true)"
    if [[ -n "$SUB_HEADERS" ]] && xhttp_verify_subscription_protection "$SUB_HEADERS"; then SUB_PROTECTION_OK=1; fi
  fi
  if [[ "$ROUTING_CONFIGURED" -eq 1 && "$SUB_OK" -eq 1 ]] \
    && xhttp_verify_subscription_routing "$DOMAIN" "${SUB_PATH}/${CLIENT_SUB_ID}"; then
    ROUTING_OK=1
  fi
  if [[ "$MIHOMO_CONFIGURED" -eq 1 ]]; then
    MIHOMO_DATA="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 10 "$MIHOMO_ROUTING_URL" 2>/dev/null || true)"
    if grep -q '^rule-providers:' <<<"$MIHOMO_DATA" && grep -Fq "$MIHOMO_PROVIDER_URL" <<<"$MIHOMO_DATA"; then MIHOMO_OK=1; fi
  fi
fi

CURRENT_STEP='restoring panel network access policy'
if [[ -n "${SSH_ALLOWED_IP:-}" ]]; then
  xhttp_configure_ssh_source || die 'Could not restore the selected SSH source policy.'
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
esac

if [[ "$PANEL_ACCESS_MODE" == "private" ]]; then
  /usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 >/dev/null
else
  /usr/local/x-ui/x-ui setting -listenIP 0.0.0.0 >/dev/null
fi
xhttp_restart_vpn_service x-ui
PANEL_WEB_OK=0
for _ in $(seq 1 20); do
  if curl -kfsS --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" --connect-timeout 2 --max-time 5 \
    -o /dev/null "https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}/" 2>/dev/null; then PANEL_WEB_OK=1; break; fi
  sleep 1
done
PANEL_BIND_OK=0
PANEL_LISTEN_ADDRESSES="$(ss -H -ltn "sport = :$PANEL_PORT" | awk '{print $4}')"
if [[ "$PANEL_ACCESS_MODE" == "private" ]]; then
  if [[ -n "$PANEL_LISTEN_ADDRESSES" ]] && ! grep -Evq '^127\.0\.0\.1:' <<<"$PANEL_LISTEN_ADDRESSES"; then PANEL_BIND_OK=1; fi
else
  if grep -Eq '^(0\.0\.0\.0|\*):' <<<"$PANEL_LISTEN_ADDRESSES"; then PANEL_BIND_OK=1; fi
fi
PANEL_FIREWALL_OK=0
if [[ "$PANEL_ACCESS_MODE" == "private" ]]; then
  if ! ufw status numbered | grep -Fq "# xhttp-vps:${SAFE_INSTANCE} panel"; then PANEL_FIREWALL_OK=1; fi
else
  if ufw status numbered | grep -Fq "# xhttp-vps:${SAFE_INSTANCE} panel"; then PANEL_FIREWALL_OK=1; fi
fi

CURRENT_STEP='repairing Fail2ban and automatic maintenance'
FAIL2BAN_OK=0; PANEL_FAIL2BAN_OK=0; MAINTENANCE_OK=0; SSH_ACCESS_OK=0
if xhttp_configure_panel_fail2ban; then PANEL_FAIL2BAN_OK=1; fi
if xhttp_configure_automatic_updates; then MAINTENANCE_OK=1; fi
xhttp_apply_ping_policy || die 'Could not restore the selected IPv4 ping policy.'
if [[ "$SSH_HARDENING" == 1 ]]; then
  CURRENT_STEP='repairing the administrative SSH policy'
  xhttp_install_ssh_access || die "Could not repair the selected SSH key access. Root SSH policy was not changed by this attempt."
  xhttp_harden_sshd || die "OpenSSH hardening failed validation. Keep the current session open and repair sshd before disconnecting."
  SSH_ACCESS_OK=1
fi
xhttp_finalize_ssh_port || die 'SSH port migration did not complete. Keep this session open.'
{
  printf 'SSH_PORT=%q\n' "$SSH_PORT"
  printf 'SSH_TARGET_PORT=%q\n' "${SSH_TARGET_PORT:-}"
} >> "${STATE_FILES[0]}"
if command -v fail2ban-client >/dev/null && xhttp_install_fail2ban_sshd; then FAIL2BAN_OK=1; fi
if [[ "$INITIAL_INSTALL_PHASE" != complete ]]; then
  xhttp_enroll_panel_2fa || die '3x-ui has not confirmed two-factor authentication. Resume setup to finish enrollment.'
fi

CURRENT_STEP='running completion audit'
printf '\n%b==================== COMPLETION AUDIT ====================%b\n' "$blue" "$plain"
FAILED=0
report() {
  local label="$1" result="$2"
  if [[ "$result" == OK ]]; then
    printf '  %-32s %bOK%b\n' "$label" "$green" "$plain"
  elif [[ "$result" == SKIP ]]; then
    printf '  %-32s %bSKIP%b\n' "$label" "$yellow" "$plain"
  else
    printf '  %-32s %bERROR%b\n' "$label" "$red" "$plain"
    FAILED=$((FAILED+1))
  fi
}
if [[ "$INSTALL_MODE" == standalone ]]; then
  if xhttp_verify_traffic; then report "VLESS / WARP traffic probe" OK; else report "VLESS / WARP traffic probe" ERROR; fi
else
  report "VLESS traffic (no client yet)" SKIP
  if [[ "${ENABLE_WARP:-0}" == 1 ]]; then
    if xhttp_verify_traffic warp; then report "WARP tunnel traffic" OK; else report "WARP tunnel traffic" ERROR; fi
  fi
fi
if apt-get check >/dev/null 2>&1 && [[ -z "$(dpkg --audit)" ]]; then report "Package update/install" OK; else report "Package update/install" ERROR; fi
if [[ "$MAINTENANCE_OK" -eq 1 ]] && xhttp_verify_automatic_updates; then
  report "Automatic maintenance" OK "$(xhttp_maintenance_label "$MAINTENANCE_MODE")"
else
  report "Automatic maintenance" ERROR
fi
if [[ "$SSH_HARDENING" == 1 ]]; then
  if [[ "$SSH_ACCESS_OK" -eq 1 ]] && xhttp_verify_ssh_access; then report "SSH access policy" OK; else report "SSH access policy" ERROR; fi
else
  report "SSH access policy" SKIP
fi
if systemctl is-active --quiet x-ui; then report "3x-ui panel" OK; else report "3x-ui panel" ERROR; fi
if systemctl is-active --quiet nginx && nginx -t >/dev/null 2>&1; then report "nginx self-steal" OK; else report "nginx self-steal" ERROR; fi
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr && "$(sysctl -n net.core.default_qdisc)" == fq ]]; then report "BBR + fq" OK; else report "BBR + fq" ERROR; fi
if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == 1 ]]; then report "IPv6 disabled" OK; else report "IPv6 disabled" ERROR; fi
if ufw status | grep -q '^Status: active'; then report "UFW firewall" OK; else report "UFW firewall" ERROR; fi
if openssl x509 -in "/root/cert/${DOMAIN}/fullchain.pem" -checkend 86400 -noout >/dev/null 2>&1; then report "TLS certificate" OK; else report "TLS certificate" ERROR; fi
if [[ "$PANEL_WEB_OK" -eq 1 ]]; then report "Panel HTTPS response" OK; else report "Panel HTTPS response" ERROR; fi
if [[ "$PANEL_BIND_OK" -eq 1 && "$PANEL_FIREWALL_OK" -eq 1 ]]; then report "Panel network exposure" OK; else report "Panel network exposure" ERROR; fi
if curl -kfsSI --resolve "$DOMAIN:$FALLBACK_PORT:127.0.0.1" "https://$DOMAIN:$FALLBACK_PORT/" >/dev/null; then report "Cover website" OK; else report "Cover website" ERROR; fi
if [[ "$SELF_STEAL_OK" -eq 1 ]]; then report "Public self-steal website" OK; else report "Public self-steal website" ERROR; fi
if xhttp_probe_foreign_sni; then report "Foreign SNI behavior" OK; else report "Foreign SNI behavior" ERROR; fi
if xhttp_probe_no_sni; then report "Missing SNI behavior" OK; else report "Missing SNI behavior" ERROR; fi
if xhttp_probe_h2_alpn; then report "Fallback ALPN (HTTP/2)" OK; else report "Fallback ALPN (HTTP/2)" ERROR; fi
HTTP_REDIRECT_HEADERS="$(curl -fsSI --resolve "${DOMAIN}:80:127.0.0.1" "http://${DOMAIN}/" 2>/dev/null || true)"
if grep -Eiq "^location:[[:space:]]*https://${DOMAIN}/" <<<"$HTTP_REDIRECT_HEADERS"; then report "HTTP / ACME webroot" OK; else report "HTTP / ACME webroot" ERROR; fi
if xhttp_verify_loopback_listener "$SUB_PORT"; then
  report "Subscription service (loopback only)" OK
else
  report "Subscription service (loopback only)" ERROR
fi
if [[ "$INBOUND_OK" -eq 1 ]] && ss -H -ltn 'sport = :443' | grep -q .; then report "VPN Reality self-steal" OK; else report "VPN Reality self-steal" ERROR; fi
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if [[ "$CLIENT_OK" -eq 1 ]]; then report "First VLESS client" OK; else report "First VLESS client" ERROR; fi
  if [[ "$SUB_OK" -eq 1 ]]; then report "Client subscription URL" OK; else report "Client subscription URL" ERROR; fi
  if [[ "$SUB_PROTECTION_OK" -eq 1 ]]; then report "Subscription privacy policy" OK; else report "Subscription privacy policy" ERROR; fi
  if [[ "$ROUTING_OK" -eq 1 ]]; then report "HAPP + INCY routing" OK; else report "HAPP + INCY routing" ERROR; fi
  if [[ "$MIHOMO_OK" -eq 1 ]]; then report "Mihomo subscription" OK; else report "Mihomo subscription" ERROR; fi
else
  if [[ -n "${NODE_API_TOKEN:-}" ]]; then report "Node-sync API token" OK; else report "Node-sync API token" ERROR; fi
  report "First VLESS client" SKIP
  report "Client subscription URL" SKIP
  report "HAPP + INCY routing" SKIP
  report "Mihomo subscription" SKIP
fi
if [[ "$FAIL2BAN_OK" -eq 1 ]] && systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then report "Fail2ban sshd jail" OK; else report "Fail2ban sshd jail" ERROR; fi
if [[ "$PANEL_ACCESS_MODE" == public ]]; then
  if [[ "$PANEL_FAIL2BAN_OK" -eq 1 ]] && fail2ban-client status xhttp-vps-panel >/dev/null 2>&1; then report "Fail2ban panel jail" OK; else report "Fail2ban panel jail" ERROR; fi
else
  report "Fail2ban panel jail" SKIP
fi
if [[ "${ENABLE_WARP:-0}" -eq 1 ]]; then
  if [[ "$WARP_CONFIGURED" -eq 1 ]]; then report "WARP MASQUE RU routing" OK; else report "WARP MASQUE RU routing" ERROR; fi
else
  report "WARP MASQUE RU routing" SKIP
fi
MEMORY_KIB_FINAL="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
if [[ "${ENABLE_WARP:-0}" -eq 1 && "$MEMORY_KIB_FINAL" =~ ^[0-9]+$ ]] && (( MEMORY_KIB_FINAL <= 1100000 )); then
  if swapon --noheadings --show 2>/dev/null | grep -q .; then
    report "Swap for low-memory WARP" OK
  else
    report "Swap for low-memory WARP" ERROR
  fi
else
  report "Swap for low-memory WARP" SKIP
fi
printf '%b==========================================================%b\n' "$blue" "$plain"
if [[ "$FAILED" -ne 0 ]]; then
  printf '%bRESULT: %s CHECK(S) FAILED%b\n' "$red" "$FAILED" "$plain"
  printf '%bFix every ERROR above before using the VPN or subscriptions.%b\n' "$yellow" "$plain"
  printf '%bSaved state:%b %s\n' "$yellow" "$plain" "${STATE_FILES[0]}"
  exit 1
fi

umask 077
RESULT_FILE="${RESULT_FILE:-/root/xhttp-vps-result-${INSTANCE_NAME}.txt}"
if [[ "$INSTALL_MODE" == standalone && -n "${CLIENT_UUID:-}" && -n "${CLIENT_SUB_ID:-}" ]]; then
  SUBSCRIPTION_DISPLAY="$(xhttp_subscription_links "https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}" "$CLIENT_EMAIL")" \
    || die "Could not generate the selected HAPP and INCY subscription links."
fi
RESULT_TEMP="$(mktemp "${RESULT_FILE}.XXXXXXXX")"
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
{
clear || true
printf '%b================================================================%b\n' "$green" "$plain"
printf '%b                    VPN REPAIR COMPLETED SUCCESSFULLY%b\n' "$green" "$plain"
printf '%b                     ALL APPLICABLE CHECKS PASSED%b\n' "$green" "$plain"
printf '%b================================================================%b\n\n' "$green" "$plain"
printf 'TLS: %s\n\n' "$(xhttp_tls_label)"
printf '%bPANEL%b\n' "$cyan" "$plain"
printf '  %bURL:%b      %s\n' "$yellow" "$plain" "$PANEL_DISPLAY_URL"
printf '  %bAccess:%b   %s\n' "$yellow" "$plain" "$PANEL_ACCESS_DETAILS"
printf '  %bLogin:%b    %s\n' "$yellow" "$plain" "$PANEL_USERNAME"
printf '  %bPassword:%b %s\n\n' "$yellow" "$plain" "$PANEL_PASSWORD"
if [[ "$INSTALL_MODE" == "standalone" && -n "${CLIENT_UUID:-}" && -n "${CLIENT_SUB_ID:-}" ]]; then
  printf '%bCLIENT SUBSCRIPTIONS%b\n' "$cyan" "$plain"
  printf '%s\n' "$SUBSCRIPTION_DISPLAY"
  if [[ -s "$MANAGED_BACKUP/migration.done" ]]; then printf 'Imported VLESS clients: %s\n' "$(cat "$MANAGED_BACKUP/migration.done")"; fi
  printf '  %bMihomo:%b      %s\n' "$yellow" "$plain" "$MIHOMO_ROUTING_URL"
  printf '  %bRouting:%b     HAPP and INCY RoscomVPN routing profiles are included.\n\n' "$yellow" "$plain"
fi
if [[ "$INSTALL_MODE" == "node" && -n "${NODE_API_TOKEN:-}" ]]; then printf '%bNODE API TOKEN:%b %s\n\n' "$cyan" "$plain" "$NODE_API_TOKEN"; fi
if [[ "$PANEL_ACCESS_MODE" == "private" ]]; then
  printf '%bSSH tunnel:%b ssh -p %s -L %s:127.0.0.1:%s %s@%s\n' "$cyan" "$plain" "$SSH_PORT" "$PANEL_PORT" "$PANEL_PORT" "$ADMIN_USER" "$DOMAIN"
  printf '%bMobile:%b create the same local-port forwarding in Termius, or use private Tailscale Serve.\n\n' "$cyan" "$plain"
fi
printf '%bVPN transport:%b %s\n' "$blue" "$plain" "$(xhttp_transport_label "$TRANSPORT")"
xhttp_print_ssh_connection
printf '%bMaintenance:%b %s\n' "$blue" "$plain" "$(xhttp_maintenance_label "$MAINTENANCE_MODE")"
if [[ "$PANEL_ACCESS_MODE" == public ]]; then
  printf '%bSecurity:%b public panel selected; 2FA is recommended as additional protection. Store its recovery codes offline.\n' "$yellow" "$plain"
fi
if [[ "$TWO_FACTOR_GUIDE" == 1 ]]; then
  printf '%b2FA setup:%b open Panel Settings, enable 2FA, scan the QR code and store recovery codes offline.\n' "$cyan" "$plain"
fi
if [[ "$SSH_HARDENING" == 0 ]]; then
  printf '%bSecurity:%b current SSH policy retained; root/password login may still be enabled.\n' "$red" "$plain"
fi
printf '%bSaved state:%b %s\n' "$blue" "$plain" "${STATE_FILES[0]}"
if [[ "$INSTALL_MODE" == node ]]; then
  printf 'Node traffic is not verified until a client is provisioned by the main panel.\n'
fi
printf '%b================================================================%b\n' "$green" "$plain"
} | tee "$RESULT_TEMP"
chmod 600 "$RESULT_TEMP"
mv -f "$RESULT_TEMP" "$RESULT_FILE"
{
  printf 'SSH_ACCESS_MODE=%q\n' "$SSH_ACCESS_MODE"
  printf 'INSTALL_PHASE=complete\n'
} >> "${STATE_FILES[0]}"
rm -f -- /root/optimize-xhttp-memory.sh
printf '%s\n' 'From another network, open the website, refresh subscriptions in your VPN apps, and test that the panel follows the chosen access policy.'
if [[ "$INITIAL_INSTALL_PHASE" != complete && "${CREATE_RECOVERY_BACKUP:-0}" == 1 ]]; then
  xhttp_export_recovery_backup "${STATE_FILES[0]}" || printf '%s\n' 'Backup skipped. You can retry using menu item 5.' >&2
fi
