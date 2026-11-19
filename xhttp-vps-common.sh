#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Shared lifecycle and verification functions. No actions on source.

xhttp_valid_ipv4() {
  local value="$1" octet
  local -a parts
  IFS='.' read -r -a parts <<<"$value"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for octet in "${parts[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

xhttp_validate_single_dns_ipv4() {
  local expected="$1" value
  local -a addresses=()
  xhttp_valid_ipv4 "$expected" || return 1
  while IFS= read -r value; do
    value="${value//$'\r'/}"
    [[ -z "$value" ]] && continue
    xhttp_valid_ipv4 "$value" || return 1
    addresses+=("$value")
  done
  mapfile -t addresses < <(printf '%s\n' "${addresses[@]}" | sed '/^$/d' | sort -u)
  [[ ${#addresses[@]} -eq 1 && "${addresses[0]}" == "$expected" ]]
}

xhttp_transport_flow() {
  case "$1" in
    vision) printf '%s' 'xtls-rprx-vision' ;;
    xhttp) printf '%s' '' ;;
    *) return 1 ;;
  esac
}

xhttp_transport_label() {
  case "$1" in
    vision) printf '%s' 'VLESS + TCP + XTLS Vision + REALITY' ;;
    xhttp) printf '%s' 'VLESS + XHTTP + REALITY' ;;
    amneziawg) printf '%s' 'AmneziaWG' ;;
    hysteria2) printf '%s' 'Hysteria 2' ;;
    *) return 1 ;;
  esac
}

xhttp_uses_panel() { [[ "${TRANSPORT:-xhttp}" == vision || "${TRANSPORT:-xhttp}" == xhttp ]]; }

xhttp_service_name() {
  case "${TRANSPORT:-xhttp}" in
    vision|xhttp) printf '%s\n' x-ui ;;
    amneziawg) printf '%s\n' awg-quick@awg-vps ;;
    hysteria2) printf '%s\n' xhttp-vps-hysteria ;;
    *) return 1 ;;
  esac
}

xhttp_incy_subscription() {
  # Public crypt1 interoperability key from the official INCY link encoder.
  node -e '
    const {createCipheriv, randomBytes} = require("crypto");
    const url = require("fs").readFileSync(0, "utf8").trim();
    if (!url.startsWith("https://") || /\s/.test(url)) process.exit(1);
    const key = Buffer.from("f6d40ea0c8a8899d7c682d09ba0d4165dfe2b3dd45e6bb3e25cb233cf00c2462", "hex");
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", key, iv);
    const payload = JSON.stringify({url, v: 1});
    const encoded = Buffer.concat([iv, cipher.update(payload, "utf8"), cipher.final(), cipher.getAuthTag()])
      .toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    process.stdout.write("incy://crypt1/" + encoded + "\n");
  '
}

xhttp_subscription_links() {
  local url="$1" email="$2" response email_path client_id happ incy
  if [[ "${SUB_ENCRYPT_LINKS:-}" != true ]]; then
    printf 'HAPP / INCY subscription: %s\n' "$url"
    return 0
  fi
  email_path="$(jq -rn --arg email "$email" '$email|@uri')" || return 1
  response="$(xhttp_memory_api "/panel/api/clients/get/$email_path")" || return 1
  client_id="$(jq -er '.obj.client.id | select(type=="number" and .>0 and floor==.)' <<<"$response")" || return 1
  response="$(xhttp_memory_api "/panel/api/clients/happLink/$client_id" -X POST)" || return 1
  happ="$(jq -er '.obj.encryptedLink | select(test("^happ://crypt[0-9]*/[a-zA-Z0-9_+=/-]+$"))' <<<"$response")" || return 1
  incy="$(printf '%s\n' "$url" | xhttp_incy_subscription)" || return 1
  printf 'HAPP subscription: %s\nINCY subscription: %s\n' "$happ" "$incy"
}

xhttp_lock() {
  local lock=/run/xhttp-vps-setup.lock
  if [[ ! /proc/$$/fd/9 -ef "$lock" ]]; then exec 9>"$lock"; fi
  flock -n 9
}

xhttp_delete_firewall_rules() {
  local marker="$1" listing number
  listing="$(ufw status numbered)" || return 1
  while IFS= read -r number; do
    ufw --force delete "$number" || return 1
  done < <(awk -v tag="# $marker" '
    index($0,tag) && (length($0)==index($0,tag)+length(tag)-1 || substr($0,index($0,tag)+length(tag),1)==" ") {
      sub(/^\[[[:space:]]*/, ""); sub(/\].*$/, ""); print
    }
  ' <<<"$listing" | sort -rn)
}

xhttp_configure_ssh_source() {
  local marker="xhttp-vps-ssh:${SAFE_INSTANCE} ${SSH_PORT}" rules
  if [[ -z "${SSH_ALLOWED_IP:-}" ]]; then
    ufw allow "$SSH_PORT"/tcp comment "$marker allow"
    return
  fi
  xhttp_valid_ipv4 "$SSH_ALLOWED_IP" || return 1
  if [[ "${1:-}" != keep-legacy ]]; then
    xhttp_delete_firewall_rules "xhttp-vps-ssh:${SAFE_INSTANCE} allow" &&
      xhttp_delete_firewall_rules "xhttp-vps-ssh:${SAFE_INSTANCE} deny" || return 1
  fi
  xhttp_delete_firewall_rules "$marker" || return 1
  # Insert the allow first so a failed operation never leaves only a deny.
  ufw insert 1 allow in from "$SSH_ALLOWED_IP" to any port "$SSH_PORT" proto tcp comment "$marker allow" || return 1
  rules="$(ufw show added)" || return 1
  [[ "$rules" == *"$marker allow"* ]] || return 1
  ufw insert 2 deny in from 0.0.0.0/0 to any port "$SSH_PORT" proto tcp comment "$marker deny"
}

xhttp_render_ssh_ports() {
  local kind="$1" port
  shift
  case "$kind" in
    socket) printf '[Socket]\nListenStream=\n' ;;
    daemon) ;;
    *) return 1 ;;
  esac
  for port in "$@"; do
    if [[ "$kind" == socket ]]; then printf 'ListenStream=0.0.0.0:%s\n' "$port"; else printf 'Port %s\n' "$port"; fi
  done
}

xhttp_reload_ssh_listeners() {
  if [[ "$1" == socket ]]; then
    # Ubuntu uses KillMode=process so stopping the listener retains accepted sessions.
    [[ "$(systemctl show --property=KillMode --value ssh.service)" == process ]] || return 1
    systemctl stop ssh.service && systemctl daemon-reload &&
      systemctl restart ssh.socket && systemctl start ssh.service
  else
    systemctl reload ssh.service
  fi
}

xhttp_wait_ssh_ports() {
  local port="$1" other="${2:-}" state="${3:-up}" attempt
  for (( attempt=0; attempt<50; attempt++ )); do
    if port_busy "$port"; then
      if [[ -z "$other" ]]; then return 0; fi
      if [[ "$state" == up ]] && port_busy "$other"; then return 0; fi
      if [[ "$state" == down ]] && ! port_busy "$other"; then return 0; fi
    fi
    sleep 0.2
  done
  return 1
}

xhttp_move_ssh_port() (
  local old="$SSH_PORT" new="$SSH_TARGET_PORT" kind=daemon directory reply sudo_command='sudo -n'
  local daemon_file=/etc/ssh/sshd_config.d/00-xhttp-vps-port.conf
  local socket_file=/etc/systemd/system/ssh.socket.d/99-xhttp-vps-port.conf
  local changed=0 committed=0
  [[ -t 0 ]] && port_busy "$old" || exit 1
  if [[ -e "$daemon_file" ]]; then
    [[ "$(<"$daemon_file")" == "$(xhttp_render_ssh_ports daemon "$old" "$new")" ]] || exit 1
    if [[ -e "$socket_file" ]]; then
      [[ "$(<"$socket_file")" == "$(xhttp_render_ssh_ports socket "$old" "$new")" ]] || exit 1
    fi
    changed=1
  else
    [[ ! -e "$socket_file" ]] && ! port_busy "$new" || exit 1
  fi
  if systemctl is-active --quiet ssh.socket; then
    kind=socket
    [[ "$(systemctl show --property=KillMode --value ssh.service)" == process ]] || exit 1
    install -d -m 755 /etc/systemd/system/ssh.socket.d || exit 1
  fi
  directory="$(mktemp -d /run/xhttp-vps-ssh-port.XXXXXXXX)" || exit 1
  cleanup_ssh_port_change() {
    local status="$?"
    if [[ "$committed" == 0 ]]; then
      if [[ "$changed" == 1 ]]; then
        if ! rm -f -- "$daemon_file" "$socket_file" || ! xhttp_reload_ssh_listeners "$kind" || ! xhttp_wait_ssh_ports "$old"; then
          printf 'Could not restore SSH on port %s. Keep this session open and use the provider console.\n' "$old" >&2
          exit 70
        fi
      fi
      xhttp_delete_firewall_rules "xhttp-vps-ssh:${SAFE_INSTANCE} $new" || true
    fi
    rm -f -- "$directory/verified" "$directory/daemon" "$directory/socket"
    rmdir -- "$directory"
    return "$status"
  }
  apply_ssh_ports() {
    xhttp_render_ssh_ports daemon "$@" > "$directory/daemon" &&
      install -m 644 "$directory/daemon" "$daemon_file" || return 1
    if [[ "$kind" == socket ]]; then
      xhttp_render_ssh_ports socket "$@" > "$directory/socket" &&
        install -m 644 "$directory/socket" "$socket_file" || return 1
    fi
    sshd -t && xhttp_reload_ssh_listeners "$kind"
  }
  trap cleanup_ssh_port_change EXIT
  trap 'exit 1' INT TERM HUP
  SSH_PORT="$new" xhttp_configure_ssh_source keep-legacy || exit 1
  changed=1
  apply_ssh_ports "$old" "$new" && xhttp_wait_ssh_ports "$old" "$new" up || exit 1
  SSH_PORT="$new" xhttp_print_ssh_connection
  printf '\nAllow TCP/%s in the provider firewall. Connect in a separate SSH session on the new port and run:\n' "$new"
  if [[ "$SSH_ACCESS_MODE" == existing ]]; then sudo_command=sudo; fi
  printf '  test "${SSH_CONNECTION##* }" = %s && test "$(id -un)" = %s && %s touch %s/verified\n' "$new" "$ADMIN_USER" "$sudo_command" "$directory"
  until [[ -f "$directory/verified" ]]; do
    read -rp 'Press Enter once the new login succeeds, or type cancel to keep the original port: ' reply || exit 1
    [[ "$reply" != cancel ]] || exit 2
  done
  apply_ssh_ports "$new" && xhttp_wait_ssh_ports "$new" "$old" down || exit 1
  committed=1
  xhttp_delete_firewall_rules "xhttp-vps-ssh:${SAFE_INSTANCE} $old" ||
    printf 'Remove the installer firewall rule for the old SSH port %s manually.\n' "$old" >&2
)

xhttp_finalize_ssh_port() {
  local config=/etc/ssh/sshd_config.d/00-xhttp-vps-port.conf
  [[ -n "${SSH_TARGET_PORT:-}" && "$SSH_TARGET_PORT" != "$SSH_PORT" ]] || return 0
  if [[ -f "$config" && "$(<"$config")" == "Port $SSH_TARGET_PORT" ]] &&
    port_busy "$SSH_TARGET_PORT" && ! port_busy "$SSH_PORT"; then
    xhttp_delete_firewall_rules "xhttp-vps-ssh:${SAFE_INSTANCE} $SSH_PORT" || true
    SSH_PORT="$SSH_TARGET_PORT"
  elif xhttp_move_ssh_port; then
    SSH_PORT="$SSH_TARGET_PORT"
  elif [[ "$?" == 2 ]]; then
    printf 'SSH port change cancelled. Keeping port %s.\n' "$SSH_PORT"
    SSH_TARGET_PORT=''
  else
    return 1
  fi
}

xhttp_apply_ping_policy() {
  [[ "${DISABLE_PING:-0}" == 1 ]] || return 0
  printf '%s\n' 'net.ipv4.icmp_echo_ignore_all = 1' > /etc/sysctl.d/99-xhttp-vps-ping.conf &&
    sysctl -w net.ipv4.icmp_echo_ignore_all=1 >/dev/null
}

xhttp_panel_2fa_enabled() {
  local response
  response="$(xhttp_memory_api /panel/api/setting/all -X POST)" || return 1
  jq -e '.obj | if type == "string" then fromjson else . end | .twoFactorEnable == true and .hasTwoFactorToken != false' <<<"$response" >/dev/null
}

xhttp_enroll_panel_2fa() {
  [[ "${PANEL_2FA_ENROLL:-0}" == 1 ]] || return 0
  if xhttp_panel_2fa_enabled; then return 0; fi
  [[ -t 0 ]] || return 1
  printf '\n3X-UI TWO-FACTOR AUTHENTICATION\n'
  printf '  Panel URL: https://%s:%s/%s/\n  Username:  %s\n  Password:  %s\n' "$DOMAIN" "$PANEL_PORT" "$PANEL_PATH" "$PANEL_USERNAME" "$PANEL_PASSWORD"
  if [[ "$PANEL_ACCESS_MODE" != public ]]; then
    printf '  Local SSH forward: %s -> 127.0.0.1:%s (SSH host %s, port %s, user %s)\n' "$PANEL_PORT" "$PANEL_PORT" "$PUBLIC_IP" "$SSH_PORT" "$ADMIN_USER"
    printf '  Resolve %s to 127.0.0.1 locally while using the tunnel so HTTPS validates the panel certificate.\n' "$DOMAIN"
  fi
  printf '%s\n' 'In 3x-ui, open Settings → Security → Two-factor authentication. Scan the QR code, confirm the current code and save.'
  until xhttp_panel_2fa_enabled; do
    read -rp 'Press Enter after saving 2FA in 3x-ui, or Ctrl+C to pause setup: ' || return 1
    if ! xhttp_panel_2fa_enabled; then printf '%s\n' 'The panel has not confirmed an active 2FA token yet.'; fi
  done
  printf '%s\n' '3x-ui confirmed that 2FA is enabled. Test it in a second browser session and store the authenticator backup separately.'
}

xhttp_subscription_profile_settings() {
  jq -c --arg mode "${SUB_PROFILE_MODE:-}" '
    if $mode == "" then .
    else .subProfileMode = $mode | .subProfileUrl = ""
    end'
}

xhttp_verify_subscription_protection() {
  local headers="${1//$'\r'/}"
  if [[ "${SUB_PRIVACY_HEADERS:-false}" == true ]]; then
    grep -Eiq '^cache-control:[[:space:]]*private, no-store$' <<<"$headers" || return 1
    grep -Eiq '^referrer-policy:[[:space:]]*no-referrer$' <<<"$headers" || return 1
  fi
  case "${SUB_PROFILE_MODE:-}" in
    none) ! grep -Eiq '^profile-web-page-url:' <<<"$headers" ;;
    builtin) grep -Eiq '^profile-web-page-url:[[:space:]]*https://' <<<"$headers" ;;
    *) return 0 ;;
  esac
}

xhttp_verify_subscription_routing() {
  local domain="$1" path="$2" headers body decoded
  local url="https://${domain}/${path}"
  # 3x-ui returns the routing profile for the requesting client.
  headers="$(curl -q --user-agent Happ -kfsS --resolve "${domain}:443:127.0.0.1" \
    --max-time 5 -D - -o /dev/null "$url")" || return 1
  headers="${headers//$'\r'/}"
  grep -Eiq '^routing-enable:[[:space:]]*true[[:space:]]*$' <<<"$headers" || return 1
  grep -Eiq '^routing:[[:space:]]*happ://routing/onadd/' <<<"$headers" || return 1
  body="$(curl -q --user-agent INCY -kfsS --resolve "${domain}:443:127.0.0.1" \
    --max-time 5 "$url")" || return 1
  decoded="$(printf '%s' "$body" | base64 -d)" || return 1
  grep -Fq 'incy://routing/onadd/' <<<"$decoded"
}

xhttp_write_recovery_backup() (
  set -o pipefail
  umask 077
  local state="$1" output_dir="$2" source_root="${3:-/}" stage archive file suffix
  local -a configs=(etc/nginx/sites-available/3xui-self-steal.conf var/www/3xui-cover)
  stage="$(mktemp -d "$output_dir/.xhttp-recovery.XXXXXXXX")" || return 1
  trap 'rm -rf -- "$stage"' EXIT
  trap 'exit 1' INT TERM HUP
  mkdir "$stage/files" "$stage/gnupg" || return 1
  install -m 600 "$state" "$stage/files/installer.env" || return 1
  case "${TRANSPORT:-xhttp}" in
    vision|xhttp)
      mkdir -p "$stage/files/etc/x-ui" || return 1
      sqlite3 -batch -bail -readonly -cmd '.timeout 5000' "${source_root%/}/etc/x-ui/x-ui.db" \
        ".backup '$stage/files/etc/x-ui/x-ui.db'" || return 1
      [[ "$(sqlite3 -batch -bail -readonly "$stage/files/etc/x-ui/x-ui.db" 'PRAGMA quick_check;')" == ok ]] || return 1
      ;;
    amneziawg) configs+=(etc/amnezia/amneziawg/awg-vps.conf etc/xhttp-vps-awg) ;;
    hysteria2) configs+=(etc/xhttp-vps-hysteria.yaml root/xhttp-vps-hysteria.uri) ;;
    *) return 1 ;;
  esac
  ( cd "$source_root" && cp -a --parents -- "${configs[@]}" "$stage/files" ) || return 1
  archive="$stage/archive.gpg"
  local -a gpg_command=(gpg --homedir "$stage/gnupg" --batch --no-tty --quiet
    --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3)
  tar -C "$stage/files" -czf - . |
    "${gpg_command[@]}" --cipher-algo AES256 --symmetric --output "$archive" 3<<<"$RECOVERY_PASSPHRASE" || return 1
  "${gpg_command[@]}" --decrypt "$archive" 3<<<"$RECOVERY_PASSPHRASE" | tar -tzf - >/dev/null || return 1
  suffix="${stage##*.}"
  file="$output_dir/xhttp-recovery-${DOMAIN}-$(date -u +%Y%m%dT%H%M%SZ)-${suffix}.tar.gz.gpg"
  mv -T -- "$archive" "$file" || return 1
  printf '%s\n' "$file"
)

xhttp_export_recovery_backup() {
  local RECOVERY_PASSPHRASE confirmation file
  [[ -t 0 ]] || { printf '%s\n' 'Open an interactive terminal to export a backup.' >&2; return 1; }
  read -rsp 'Backup passphrase (leave empty to cancel): ' RECOVERY_PASSPHRASE || return 1
  printf '\n'
  [[ -n "$RECOVERY_PASSPHRASE" ]] || return 1
  read -rsp 'Confirm backup passphrase: ' confirmation || return 1
  printf '\n'
  [[ "$RECOVERY_PASSPHRASE" == "$confirmation" ]] || { printf '%s\n' 'Passphrases did not match.' >&2; return 1; }
  if ! command -v gpg >/dev/null; then
    xhttp_apt_get -o APT::Update::Error-Mode=any update || return 1
    xhttp_apt_apply install -y --no-install-recommends gnupg || return 1
  fi
  file="$(xhttp_write_recovery_backup "$1" /root)" || return 1
  printf 'Verified encrypted backup: %s\n' "$file"
  printf '%s\n' 'Copy the archive off the VPS and store its passphrase separately.'
}

xhttp_ssh_access_label() {
  case "$1" in
    admin-cert) printf '%s' 'new sudo administrator, SSH certificate only, root and password login disabled' ;;
    admin) printf '%s' 'new sudo administrator, SSH key only, direct root login disabled' ;;
    root-key) printf '%s' 'root login by SSH key only; password login disabled' ;;
    root-password) printf '%s' 'root login with the system password' ;;
    existing) printf '%s' 'current SSH policy retained (not recommended)' ;;
    *) return 1 ;;
  esac
}

xhttp_print_ssh_connection() {
  local mode="${SSH_ACCESS_MODE:-existing}"
  printf '\nSSH CONNECTION\n'
  printf '  %-16s %s\n' 'Host:' "$DOMAIN" 'IPv4:' "${PUBLIC_IP:-Unknown}" 'Port:' "$SSH_PORT" 'Username:' "$ADMIN_USER" \
    'Authentication:' "$(xhttp_ssh_access_label "$mode")" 'Source IPv4:' "${SSH_ALLOWED_IP:-Any}"
  if [[ -n "${ADMIN_KEY_FINGERPRINTS:-}" ]]; then
    printf '  %-16s %s\n' 'Key / CA SHA256:' "$ADMIN_KEY_FINGERPRINTS"
  fi
  case "$mode" in
    admin-cert)
      printf '  %-16s %s\n' 'Principal:' "$ADMIN_USER" 'Termius:' 'Attach the signed user certificate and its matching private key.'
      printf '  Command:         ssh -p %s -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 -o CertificateFile=~/.ssh/id_ed25519-cert.pub %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$DOMAIN"
      ;;
    root-password)
      printf '  %-16s %s\n' 'Password:' 'Use the root password set on the VPS.'
      printf '  Command:         ssh -p %s -o PreferredAuthentications=password %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$DOMAIN"
      ;;
    *) printf '  Command:         ssh -p %s %s@%s\n' "$SSH_PORT" "$ADMIN_USER" "$DOMAIN" ;;
  esac
  if [[ "$mode" == admin || "$mode" == admin-cert ]]; then
    printf '  %-16s %s\n' 'Check access:' 'Run sudo -n id -u in a new SSH session. Expected output: 0.'
  fi
}

xhttp_inbound_tag_for() {
  case "$1" in
    vision) printf '%s' 'in-443-vision-reality' ;;
    xhttp) printf '%s' 'in-443-xhttp-reality' ;;
    *) return 1 ;;
  esac
}

xhttp_build_stream_settings() {
  local transport="$1" domain="$2" target="$3" private_key="$4" public_key="$5" short_id="$6"
  local reality
  reality="$(jq -nc --arg d "$domain" --arg target "$target" --arg private "$private_key" \
    --arg public "$public_key" --arg sid "$short_id" '
      {show:false,xver:0,target:$target,privateKey:$private,minClientVer:"",maxClientVer:"",maxTimeDiff:0,
       serverNames:[$d],shortIds:[$sid],settings:{publicKey:$public,fingerprint:"firefox",serverName:"",spiderX:"/"}}
    ')" || return 1
  case "$transport" in
    vision)
      jq -nc --argjson reality "$reality" '
        {network:"tcp",security:"reality",externalProxy:[],realitySettings:$reality,
         tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}}
      '
      ;;
    xhttp)
      jq -nc --arg d "$domain" --argjson reality "$reality" '
        {network:"xhttp",security:"reality",externalProxy:[],realitySettings:$reality,
         xhttpSettings:{host:$d,path:"/",mode:"auto",xPaddingBytes:"100-1000",xPaddingObfsMode:false,
           noSSEHeader:false,scMaxEachPostBytes:"1000000",scMaxBufferedPosts:30,
           scStreamUpServerSecs:"20-80",headers:{}}}
      '
      ;;
    *) return 1 ;;
  esac
}

xhttp_rebuild_managed_inbound() {
  local transport="$1" domain="$2" target="$3" tag="$4"
  local inbound settings stream private_key public_key short_ids short_id rebuilt_stream sniffing id
  inbound="$(cat)"
  id="$(jq -er '.id | select(type=="number" and .>0 and floor==.)' <<<"$inbound")" || return 1
  settings="$(jq -ce '.settings | if type=="string" then fromjson else . end | select(type=="object")' <<<"$inbound")" || return 1
  stream="$(jq -ce '.streamSettings | if type=="string" then fromjson else . end | select(type=="object")' <<<"$inbound")" || return 1
  private_key="$(jq -er '.realitySettings.privateKey | select(type=="string" and length>0)' <<<"$stream")" || return 1
  public_key="$(jq -er '.realitySettings.settings.publicKey | select(type=="string" and length>0)' <<<"$stream")" || return 1
  short_ids="$(jq -ce '.realitySettings.shortIds | select(type=="array" and length>0 and all(.[]; type=="string" and length>0))' <<<"$stream")" || return 1
  short_id="$(jq -r '.[0]' <<<"$short_ids")"
  rebuilt_stream="$(xhttp_build_stream_settings "$transport" "$domain" "$target" "$private_key" "$public_key" "$short_id")" || return 1
  rebuilt_stream="$(jq -ce --argjson ids "$short_ids" '.realitySettings.shortIds=$ids' <<<"$rebuilt_stream")" || return 1
  sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
  jq -ce --argjson id "$id" --arg settings "$settings" --arg stream "$rebuilt_stream" \
    --arg sniffing "$sniffing" --arg tag "$tag" '
      .id=$id | .listen="" | .port=443 | .protocol="vless" | .settings=$settings
      | .streamSettings=$stream | .tag=$tag | .sniffing=$sniffing
    ' <<<"$inbound"
}

xhttp_rotate_node_sync_token() {
  local token_name="${1:-xhttp-node-sync}" response ids id payload token
  [[ "$token_name" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1
  response="$(xhttp_memory_api /panel/api/setting/apiTokens)" || return 1
  ids="$(jq -ce --arg name "$token_name" '
    .obj | if type=="string" then fromjson else . end
    | select(type=="array")
    | map(select(.name==$name and .scope=="node-sync") | .id)
    | select(all(.[]; type=="number" and .>0 and floor==.))
  ' <<<"$response")" || return 1
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    payload='{"expectedScope":"node-sync"}'
    xhttp_memory_api "/panel/api/setting/apiTokens/delete/$id" -X POST \
      -H 'Content-Type: application/json' --data-binary "$payload" >/dev/null || return 1
  done < <(jq -r '.[]' <<<"$ids")
  payload="$(jq -nc --arg name "$token_name" '{name:$name,scope:"node-sync",expiresAt:0}')"
  response="$(xhttp_memory_api /panel/api/setting/apiTokens/create -X POST \
    -H 'Content-Type: application/json' --data-binary "$payload")" || return 1
  token="$(jq -er '
    .obj | if type=="string" then fromjson else . end
    | select(.scope=="node-sync" and .enabled==true)
    | .token | select(type=="string" and length>=32)
  ' <<<"$response")" || return 1
  printf '%s' "$token"
}

xhttp_validate_authorized_keys_b64() (
  set -Eeuo pipefail
  local encoded="$1" directory keys line one count=0
  [[ -n "$encoded" && ${#encoded} -le 131072 ]] || return 1
  directory="$(mktemp -d /tmp/xhttp-ssh-key-check.XXXXXXXX)"
  trap 'rm -f "$directory/keys" "$directory/one"; rmdir "$directory"' EXIT
  keys="$directory/keys"; one="$directory/one"
  printf '%s' "$encoded" | base64 -d > "$keys" 2>/dev/null || return 1
  [[ -s "$keys" && "$(stat -c '%s' "$keys")" -le 65536 ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]] \
      || return 1
    printf '%s\n' "$line" > "$one"
    ssh-keygen -l -f "$one" >/dev/null 2>&1 || return 1
    count=$((count + 1))
  done < "$keys"
  (( count > 0 ))
)

xhttp_authorized_key_fingerprints() (
  set -Eeuo pipefail
  local encoded="$1" temporary
  temporary="$(mktemp /tmp/xhttp-ssh-fingerprints.XXXXXXXX)"
  trap 'rm -f "$temporary"' EXIT
  printf '%s' "$encoded" | base64 -d > "$temporary"
  ssh-keygen -l -f "$temporary" | awk '{print $2}' | paste -sd, -
)

xhttp_validate_ssh_ca_b64() {
  local key
  xhttp_validate_authorized_keys_b64 "$1" || return 1
  key="$(printf '%s' "$1" | base64 -d)" || return 1
  [[ "$key" =~ ^ssh-ed25519[[:blank:]] && "$key" != *$'\n'* && "$key" != *$'\r'* ]]
}

xhttp_install_admin_access() {
  local home_dir temporary_sudo
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || return 1
  if [[ "$SSH_ACCESS_MODE" == admin-cert ]]; then
    xhttp_validate_ssh_ca_b64 "$ADMIN_KEYS_B64" || return 1
  else
    xhttp_validate_authorized_keys_b64 "$ADMIN_KEYS_B64" || return 1
  fi
  if getent passwd "$ADMIN_USER" >/dev/null; then
    home_dir="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [[ "$home_dir" == "/home/$ADMIN_USER" ]] || return 1
  else
    useradd --create-home --user-group --shell /bin/bash "$ADMIN_USER"
  fi
  home_dir="/home/$ADMIN_USER"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home_dir/.ssh"
  {
    if [[ "$SSH_ACCESS_MODE" == admin-cert ]]; then printf 'cert-authority,principals="%s" ' "$ADMIN_USER"; fi
    printf '%s' "$ADMIN_KEYS_B64" | base64 -d
    if [[ "$SSH_ACCESS_MODE" == admin-cert ]]; then printf '\n'; fi
  } > "$home_dir/.ssh/authorized_keys.new"
  chown "$ADMIN_USER:$ADMIN_USER" "$home_dir/.ssh/authorized_keys.new"
  chmod 600 "$home_dir/.ssh/authorized_keys.new"
  mv -f "$home_dir/.ssh/authorized_keys.new" "$home_dir/.ssh/authorized_keys"
  usermod -aG sudo "$ADMIN_USER"
  usermod -L "$ADMIN_USER"
  temporary_sudo="$(mktemp /etc/sudoers.d/90-xhttp-vps-admin.XXXXXXXX)"
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ADMIN_USER" > "$temporary_sudo"
  chmod 440 "$temporary_sudo"
  visudo -cf "$temporary_sudo" >/dev/null
  mv -f "$temporary_sudo" /etc/sudoers.d/90-xhttp-vps-admin
  sudo -u "$ADMIN_USER" sudo -n true
}

xhttp_install_root_key_access() {
  xhttp_validate_authorized_keys_b64 "$ADMIN_KEYS_B64" || return 1
  install -d -m 700 -o root -g root /root/.ssh
  printf '%s' "$ADMIN_KEYS_B64" | base64 -d > /root/.ssh/authorized_keys.new
  chown root:root /root/.ssh/authorized_keys.new
  chmod 600 /root/.ssh/authorized_keys.new
  mv -f /root/.ssh/authorized_keys.new /root/.ssh/authorized_keys
}

xhttp_install_ssh_access() {
  case "${SSH_ACCESS_MODE:-admin}" in
    admin|admin-cert) xhttp_install_admin_access ;;
    root-key) xhttp_install_root_key_access ;;
    root-password)
      if [[ "$(passwd -S root | awk '{print $2}')" != P ]]; then
        [[ -t 0 ]] || return 1
        printf '%s\n' 'Set a root password for the selected SSH login mode.'
        passwd root || return 1
      fi
      [[ "$(passwd -S root | awk '{print $2}')" == P ]]
      ;;
    existing) return 0 ;;
    *) return 1 ;;
  esac
}

xhttp_render_sshd_hardening() {
  local mode="$1" login_user="$2" permit_root allow_user password=no authentication=publickey
  case "$mode" in
    admin|admin-cert)
      [[ "$login_user" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$login_user" != root ]] || return 1
      permit_root=no
      allow_user="$login_user"
      ;;
    root-key)
      [[ "$login_user" == root ]] || return 1
      permit_root=prohibit-password
      allow_user=root
      ;;
    root-password)
      [[ "$login_user" == root ]] || return 1
      permit_root=yes
      allow_user=root
      password=yes
      authentication=password
      ;;
    *) return 1 ;;
  esac
  cat <<EOF
# Managed by xhttp-vps-setup. Keep local TCP forwarding for the private panel.
PubkeyAuthentication yes
PasswordAuthentication ${password}
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods ${authentication}
PermitEmptyPasswords no
PermitRootLogin ${permit_root}
AllowUsers ${allow_user}
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
GatewayPorts no
PermitTunnel no
PermitUserEnvironment no
EOF
  if [[ "$mode" == admin-cert ]]; then
    cat <<'EOF'
# Only the CA and principal installed for this administrator may be used.
AuthorizedKeysFile .ssh/authorized_keys
AuthorizedKeysCommand none
TrustedUserCAKeys none
PubkeyAcceptedAlgorithms *-cert-v01@openssh.com
EOF
  fi
}

xhttp_verify_managed_sshd_config() {
  local config root_config host_name source_ip="${SSH_CONNECTION:-}" password=no authentication=publickey
  source_ip="${source_ip%% *}"
  host_name="$(hostname -f 2>/dev/null || hostname)" || return 1
  config="$(sshd -T -C "user=$ADMIN_USER,host=$host_name,addr=${source_ip:-127.0.0.1}")" || return 1
  root_config="$(sshd -T -C "user=root,host=$host_name,addr=${source_ip:-127.0.0.1}")" || return 1
  case "$SSH_ACCESS_MODE" in
    admin|admin-cert) grep -Fxq 'permitrootlogin no' <<<"$root_config" || return 1 ;;
    root-key) grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$root_config" || return 1 ;;
    root-password)
      grep -Fxq 'permitrootlogin yes' <<<"$root_config" || return 1
      password=yes
      authentication=password
      ;;
    *) return 1 ;;
  esac
  if [[ "$SSH_ACCESS_MODE" == admin-cert ]]; then
    grep -Fxq 'passwordauthentication no' <<<"$root_config" || return 1
    grep -Fxq 'authorizedkeysfile .ssh/authorized_keys' <<<"$config" || return 1
    grep -Fxq 'authorizedkeyscommand none' <<<"$config" || return 1
    grep -Fxq 'trustedusercakeys none' <<<"$config" || return 1
    awk '$1=="pubkeyacceptedalgorithms" {n=split($2,algorithms,","); for(i=1;i<=n;i++) if(algorithms[i]!~/-cert-v01@openssh\.com$/) exit 1; found=n} END {if(!found) exit 1}' <<<"$config" || return 1
  fi
  grep -Fxq "passwordauthentication $password" <<<"$config" &&
    grep -Fxq 'kbdinteractiveauthentication no' <<<"$config" &&
    grep -Fxq "authenticationmethods $authentication" <<<"$config" &&
    grep -Eq "^allowusers( .*)? ${ADMIN_USER}( .*)?$|^allowusers ${ADMIN_USER}$" <<<"$config"
}

xhttp_verify_ssh_access() {
  local key_path
  xhttp_verify_managed_sshd_config || return 1
  case "$SSH_ACCESS_MODE" in
    admin|admin-cert)
      sudo -u "$ADMIN_USER" sudo -n true || return 1
      key_path="/home/$ADMIN_USER/.ssh/authorized_keys"
      ;;
    root-key) key_path=/root/.ssh/authorized_keys ;;
    root-password) [[ "$(passwd -S root | awk '{print $2}')" == P ]]; return ;;
    *) return 1 ;;
  esac
  [[ -s "$key_path" && "$(stat -c '%a' "$key_path")" == 600 ]] || return 1
  if [[ "$SSH_ACCESS_MODE" == admin-cert ]]; then
    cmp -s "$key_path" <(printf 'cert-authority,principals="%s" ' "$ADMIN_USER"; printf '%s' "$ADMIN_KEYS_B64" | base64 -d; printf '\n') || return 1
  fi
  [[ "$(passwd -S root | awk '{print $2}')" == L ]]
}

xhttp_confirm_certificate_login() (
  [[ "$SSH_ACCESS_MODE" == admin-cert ]] || return 0
  if xhttp_verify_ssh_access; then return 0; fi
  [[ -t 0 ]] || { printf '%s\n' 'An interactive terminal is required to confirm certificate login.' >&2; return 1; }
  local directory
  directory="$(mktemp -d /run/xhttp-vps-cert-test.XXXXXXXX)" || return 1
  trap 'rm -f -- "$directory/verified"; rmdir -- "$directory"' EXIT
  trap 'exit 1' INT TERM HUP
  xhttp_print_ssh_connection
  printf '\nOpen a second SSH session with the signed certificate. In that session run:\n'
  printf '  test "$(id -un)" = %s && sudo -n touch %s/verified\n' "$ADMIN_USER" "$directory"
  until [[ -f "$directory/verified" ]]; do
    read -rp 'Press Enter after the second-session test succeeds, or Ctrl+C to pause setup: ' || return 1
    if [[ ! -f "$directory/verified" ]]; then printf '%s\n' 'Waiting for a successful login and sudo check.'; fi
  done
)

xhttp_harden_sshd() {
  local target=/etc/ssh/sshd_config.d/00-xhttp-vps-hardening.conf temporary previous had_previous=0
  xhttp_confirm_certificate_login || return 1
  previous="$(mktemp /etc/ssh/sshd_config.d/xhttp-vps-previous.XXXXXXXX)" || return 1
  if [[ -e "$target" ]]; then
    cp -a "$target" "$previous" || return 1
    had_previous=1
  fi
  temporary="$(mktemp /etc/ssh/sshd_config.d/00-xhttp-vps-hardening.conf.XXXXXXXX)" || return 1
  if ! xhttp_render_sshd_hardening "$SSH_ACCESS_MODE" "$ADMIN_USER" > "$temporary" ||
    ! chmod 600 "$temporary" || ! mv -f "$temporary" "$target"; then
    rm -f -- "$temporary" "$previous"
    return 1
  fi
  if ! sshd -t || ! xhttp_verify_managed_sshd_config || ! systemctl reload ssh; then
    if [[ "$had_previous" == 1 ]]; then
      mv -f "$previous" "$target" || return 1
    else
      rm -f "$target" "$previous" || return 1
    fi
    systemctl reload ssh || true
    return 1
  fi
  rm -f -- "$previous"
  if [[ "$SSH_ACCESS_MODE" != root-password ]]; then passwd -l root >/dev/null; fi
}

xhttp_install_fail2ban_sshd() {
  cat > /etc/fail2ban/jail.d/xhttp-vps-sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
EOF
  systemctl enable --now fail2ban
  fail2ban-client reload >/dev/null
  fail2ban-client status sshd >/dev/null
}

xhttp_render_panel_fail2ban_filter() {
  cat <<'EOF'
[Definition]
failregex = ^.*failed login: username=.*IP="<HOST>".*$
ignoreregex =
EOF
}

xhttp_render_panel_fail2ban_jail() {
  [[ "${PANEL_PORT:-}" =~ ^[0-9]+$ ]] && (( PANEL_PORT >= 1 && PANEL_PORT <= 65535 )) || return 1
  cat <<EOF
[xhttp-vps-panel]
enabled = true
filter = xhttp-vps-panel
backend = systemd
journalmatch = _SYSTEMD_UNIT=x-ui.service
port = ${PANEL_PORT}
protocol = tcp
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
banaction = ufw
EOF
}

xhttp_configure_panel_fail2ban() {
  if [[ "${PANEL_ACCESS_MODE:-}" != public ]]; then
    fail2ban-client stop xhttp-vps-panel >/dev/null 2>&1 || true
    rm -f /etc/fail2ban/filter.d/xhttp-vps-panel.conf /etc/fail2ban/jail.d/xhttp-vps-panel.local
    systemctl enable --now fail2ban
    fail2ban-client reload >/dev/null
    return 0
  fi
  xhttp_render_panel_fail2ban_filter > /etc/fail2ban/filter.d/xhttp-vps-panel.conf
  xhttp_render_panel_fail2ban_jail > /etc/fail2ban/jail.d/xhttp-vps-panel.local
  systemctl enable --now fail2ban
  fail2ban-client reload >/dev/null
  fail2ban-client status xhttp-vps-panel >/dev/null
}

xhttp_maintenance_label() {
  case "${1:-}" in
    security) printf 'daily Ubuntu security updates at 05:30, no automatic reboot (%s)' "${MAINTENANCE_TIMEZONE:-Europe/Moscow}" ;;
    weekly) printf '05:30 daily security updates, full maintenance on Sundays, then reboot if required (%s)' "${MAINTENANCE_TIMEZONE:-Europe/Moscow}" ;;
    none) printf '%s' 'no automatic updates or reboot' ;;
    *) return 1 ;;
  esac
}

xhttp_render_maintenance_timer() {
  cat <<EOF
[Unit]
Description=Daily maintenance for xhttp-vps

[Timer]
OnCalendar=*-*-* 05:30:00 ${MAINTENANCE_TIMEZONE}
AccuracySec=1s
Persistent=false
Unit=xhttp-vps-maintenance.service

[Install]
WantedBy=timers.target
EOF
}

xhttp_render_maintenance_script() {
  printf '#!/usr/bin/env bash\n'
  declare -f xhttp_apt_get xhttp_repair_apt xhttp_apt_apply xhttp_restart_vpn_service || return 1
  declare -f xhttp_download_verified xhttp_latest_release_asset xhttp_release_arch \
    xhttp_stage_panel_release xhttp_wait_for_vpn_service xhttp_update_panel xhttp_update_hysteria || return 1
  cat <<'EOF'
set -Eeuo pipefail
mode="$1"
vpn_service="$2"
export TZ="$3"
panel_port="${4:-}"
case "$mode" in weekly|security) ;; *) exit 1 ;; esac
exec 9>/run/xhttp-vps-setup.lock
if ! flock -n 9; then
  logger -t xhttp-vps-maintenance 'Skipped maintenance while setup or maintenance held the lock.'
  exit 0
fi

check_health() {
  apt-get -o DPkg::Lock::Timeout=0 check || return 1
  local audit service
  audit="$(dpkg --audit)" || return 1
  [[ -z "$audit" ]] || return 1
  nginx -t || return 1
  systemctl is-active --quiet ssh.service ssh.socket || return 1
  for service in nginx "$vpn_service"; do
    systemctl is-active --quiet "$service" || return 1
  done
}

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
xhttp_apt_get -o APT::Update::Error-Mode=any update
if ! unattended-upgrade; then
  logger -t xhttp-vps-maintenance 'Security updates failed. Repairing APT and retrying.'
  xhttp_repair_apt
  unattended-upgrade
fi

if [[ "$mode" == weekly && "$(date +%u)" == 7 ]]; then
  xhttp_apt_apply -o DPkg::Lock::Timeout=1800 -y -o Dpkg::Options::="--force-confold" --with-new-pkgs upgrade
  xhttp_apt_get -o DPkg::Lock::Timeout=1800 -y autoremove
  apt-get autoclean
  case "$vpn_service" in
    x-ui|xhttp-vps-hysteria)
      # A separate shell keeps errexit active even when the caller handles failure.
      export -f xhttp_download_verified xhttp_latest_release_asset xhttp_release_arch \
        xhttp_stage_panel_release xhttp_wait_for_vpn_service xhttp_update_panel xhttp_update_hysteria \
        xhttp_restart_vpn_service
      if bash -ec 'case "$1" in x-ui) xhttp_update_panel "$2" ;; *) xhttp_update_hysteria ;; esac' \
        bash "$vpn_service" "$panel_port"; then
        logger -t xhttp-vps-maintenance 'VPN release check completed.'
      else
        [[ "$?" != 70 ]] || exit 70
        xhttp_wait_for_vpn_service "$vpn_service" "$panel_port"
        logger -t xhttp-vps-maintenance 'VPN component update deferred. The existing service is healthy.'
      fi
      ;;
  esac
fi

check_health
logger -t xhttp-vps-maintenance 'Scheduled maintenance completed.'
if [[ "$mode" == weekly && -f /var/run/reboot-required ]]; then
  if systemctl is-active --quiet apt-daily.service apt-daily-upgrade.service; then
    logger -t xhttp-vps-maintenance 'Reboot skipped while another APT job was active.'
    exit 0
  fi
  logger -t xhttp-vps-maintenance 'Updates require a reboot. Rebooting after completed maintenance.'
  systemctl --no-block reboot
fi
EOF
}

xhttp_remove_legacy_reboot_timer() {
  if systemctl is-enabled --quiet xhttp-vps-reboot.timer 2>/dev/null ||
    systemctl is-active --quiet xhttp-vps-reboot.timer 2>/dev/null; then
    systemctl disable --now xhttp-vps-reboot.timer || return 1
  fi
  rm -f /etc/systemd/system/xhttp-vps-reboot.service /etc/systemd/system/xhttp-vps-reboot.timer \
    /run/xhttp-vps-maintenance.ok
}

xhttp_install_maintenance() {
  local name=xhttp-vps-maintenance service temporary
  service="$(xhttp_service_name)" || return 1
  if [[ "$service" == x-ui ]]; then
    [[ "${PANEL_PORT:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$PANEL_PORT > 0 && 10#$PANEL_PORT <= 65535 )) || return 1
  fi
  [[ "$MAINTENANCE_TIMEZONE" =~ ^([A-Za-z0-9_+-]+/)*[A-Za-z0-9_+-]+$ ]] || return 1
  [[ -f "/usr/share/zoneinfo/$MAINTENANCE_TIMEZONE" ]] || return 1
  systemd-analyze calendar "*-*-* 05:30:00 ${MAINTENANCE_TIMEZONE}" >/dev/null || return 1
  temporary="$(mktemp /usr/local/sbin/.xhttp-vps-maintenance.XXXXXXXX)" || return 1
  if ! xhttp_render_maintenance_script > "$temporary" || ! chmod 700 "$temporary" ||
    ! mv -fT "$temporary" /usr/local/sbin/xhttp-vps-maintenance; then
    rm -f -- "$temporary"
    return 1
  fi
  cat > "/etc/systemd/system/$name.service" <<EOF || return 1
[Unit]
Description=Run scheduled VPN maintenance
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xhttp-vps-maintenance $MAINTENANCE_MODE $service $MAINTENANCE_TIMEZONE "${PANEL_PORT:-}"
Nice=10
IOSchedulingClass=idle
UMask=0027
TimeoutStartSec=2h
EOF
  temporary="$(mktemp "/etc/systemd/system/$name.timer.XXXXXXXX")" || return 1
  xhttp_render_maintenance_timer > "$temporary" &&
    chmod 644 "$temporary" && mv -fT "$temporary" "/etc/systemd/system/$name.timer" || {
    rm -f -- "$temporary"
    return 1
  }
  xhttp_remove_legacy_reboot_timer || return 1
  systemctl daemon-reload || return 1
  systemctl enable xhttp-vps-maintenance.timer && systemctl restart xhttp-vps-maintenance.timer
}

xhttp_disable_maintenance() {
  if systemctl is-enabled --quiet xhttp-vps-maintenance.timer 2>/dev/null ||
    systemctl is-active --quiet xhttp-vps-maintenance.timer 2>/dev/null; then
    systemctl disable --now xhttp-vps-maintenance.timer || return 1
  fi
  xhttp_remove_legacy_reboot_timer || return 1
  rm -f /usr/local/sbin/xhttp-vps-maintenance \
    /etc/systemd/system/xhttp-vps-maintenance.service \
    /etc/systemd/system/xhttp-vps-maintenance.timer || return 1
  systemctl daemon-reload
}

xhttp_verify_automatic_updates() {
  local config
  config="$(apt-config dump)" || return 1
  grep -Fqx 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$config" || return 1
  grep -Fqx 'APT::Periodic::Enable "0";' <<<"$config" || return 1
  ! systemctl is-enabled --quiet xhttp-vps-reboot.timer 2>/dev/null &&
    ! systemctl is-active --quiet xhttp-vps-reboot.timer 2>/dev/null || return 1
  if [[ "$MAINTENANCE_MODE" == none ]]; then
    ! systemctl is-enabled --quiet xhttp-vps-maintenance.timer 2>/dev/null &&
      ! systemctl is-active --quiet xhttp-vps-maintenance.timer 2>/dev/null
  else
    systemctl is-enabled --quiet xhttp-vps-maintenance.timer && systemctl is-active --quiet xhttp-vps-maintenance.timer
  fi
}

xhttp_configure_automatic_updates() {
  case "${MAINTENANCE_MODE:-}" in
    security|weekly|none) ;;
    *) return 1 ;;
  esac
  cat > /etc/apt/apt.conf.d/52xhttp-vps-auto-upgrades <<'EOF' || return 1
// xhttp-vps-maintenance controls the update window.
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
  cat > /etc/apt/apt.conf.d/53xhttp-vps-unattended-upgrades <<'EOF' || return 1
// Use official Ubuntu security pockets and the base release for dependencies.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
EOF
  if [[ "$MAINTENANCE_MODE" == none ]]; then
    xhttp_disable_maintenance
  else
    xhttp_install_maintenance
  fi
}

xhttp_apt_get() {
  apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=300 "$@"
}

xhttp_repair_apt() {
  if ! dpkg --force-confold --configure -a; then
    printf '%s\n' 'dpkg could not finish pending packages. Trying to repair dependencies through APT.' >&2
  fi
  xhttp_apt_get -y --no-remove -o Dpkg::Options::="--force-confold" -f install || return 1
  dpkg --force-confold --configure -a && xhttp_apt_get check
}

xhttp_apt_apply() {
  if xhttp_apt_get "$@"; then return 0; fi
  printf '%s\n' 'APT operation failed. Repairing pending packages and retrying once.' >&2
  xhttp_repair_apt && xhttp_apt_get "$@"
}

xhttp_restart_vpn_service() {
  local service="$1"
  if systemctl restart "$service"; then return 0; fi
  systemctl reset-failed "$service" && systemctl restart "$service"
}

xhttp_download_verified() {
  local url="$1" expected="$2" output="$3" actual
  curl -q -fL --proto '=https' --proto-redir '=https' --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 "$url" -o "$output" || {
    rm -f -- "$output"
    return 1
  }
  actual="$(sha256sum "$output" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Checksum mismatch for %s: expected %s, received %s\n' "$url" "$expected" "$actual" >&2
    rm -f -- "$output"
    return 1
  fi
}

xhttp_latest_release_asset() {
  local repo="$1" asset="$2" output="$3" current_digest="${4:-}" release record url digest
  release="$(curl -q -fsSL --proto '=https' --proto-redir '=https' --retry 3 --retry-all-errors --connect-timeout 10 --max-time 30 \
    "https://api.github.com/repos/$repo/releases/latest")" || return 1
  record="$(jq -er --arg asset "$asset" '
    select(.draft == false and .prerelease == false)
    | [.assets[] | select(.name == $asset and .state == "uploaded"
         and ((.digest // "") | test("^sha256:[a-f0-9]{64}$")))]
    | select(length == 1) | .[0] | [.browser_download_url, (.digest | ltrimstr("sha256:"))] | @tsv
  ' <<<"$release")" || return 1
  IFS=$'\t' read -r url digest <<<"$record"
  [[ "$url" == "https://github.com/$repo/releases/download/"*"/$asset" ]] || return 1
  [[ "$digest" != "$current_digest" ]] || return 0
  xhttp_download_verified "$url" "$digest" "$output" || return 1
  printf '%s\n' "$digest" > "$output.sha256"
}

xhttp_release_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    aarch64|arm64) printf '%s\n' arm64 ;;
    armv7l) printf '%s\n' armv7 ;;
    s390x) printf '%s\n' s390x ;;
    *) return 1 ;;
  esac
}

xhttp_stage_panel_release() {
  local stage="$1" arch="$2" current="${3:-}" xray_arch panel_digest='' xray_digest=''
  case "$arch" in
    amd64) xray_arch=64 ;;
    arm64) xray_arch=arm64-v8a ;;
    armv7) xray_arch=arm32-v7a ;;
    s390x) xray_arch=s390x ;;
    *) return 1 ;;
  esac
  if [[ -n "$current" ]]; then
    if [[ -f "$current/.xhttp-panel.sha256" ]]; then panel_digest="$(<"$current/.xhttp-panel.sha256")"; fi
    if [[ -f "$current/.xhttp-xray.sha256" ]]; then xray_digest="$(<"$current/.xhttp-xray.sha256")"; fi
  fi
  xhttp_latest_release_asset MHSanaei/3x-ui "x-ui-linux-$arch.tar.gz" "$stage/panel.tar.gz" "$panel_digest" || return 1
  xhttp_latest_release_asset XTLS/Xray-core "Xray-linux-$xray_arch.zip" "$stage/xray.zip" "$xray_digest" || return 1
  if [[ -f "$stage/panel.tar.gz" ]]; then
    tar -xzf "$stage/panel.tar.gz" --no-same-owner -C "$stage" || return 1
    [[ -x "$stage/x-ui/x-ui" && -f "$stage/x-ui/x-ui.sh" && -d "$stage/x-ui/bin" ]] || return 1
    mv -T "$stage/panel.tar.gz.sha256" "$stage/x-ui/.xhttp-panel.sha256" || return 1
  fi
  if [[ -f "$stage/xray.zip" ]]; then
    unzip -p "$stage/xray.zip" xray > "$stage/xray" || return 1
    chmod 755 "$stage/xray" && "$stage/xray" version >/dev/null || return 1
  fi
}

xhttp_install_panel() (
  set -Eeuo pipefail
  umask 077
  local stage arch
  arch="$(xhttp_release_arch)"
  stage="$(mktemp -d /usr/local/.xhttp-panel.XXXXXXXX)"
  trap 'rm -rf -- "$stage"' EXIT
  xhttp_stage_panel_release "$stage" "$arch"
  mv -fT "$stage/xray" "$stage/x-ui/bin/xray-linux-$arch"
  mv -T "$stage/xray.zip.sha256" "$stage/x-ui/.xhttp-xray.sha256"
  install -m 700 "$stage/x-ui/x-ui.sh" /usr/bin/x-ui
  install -m 644 "$stage/x-ui/x-ui.service.debian" /etc/systemd/system/x-ui.service
  systemctl daemon-reload
  mv -T "$stage/x-ui" /usr/local/x-ui
)

xhttp_wait_for_vpn_service() {
  local service="$1" port="${2:-}" pid previous='' listeners core attempt
  for (( attempt=0; attempt<30; attempt++ )); do
    pid="$(systemctl show --property=MainPID --value "$service")" || return 1
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && systemctl is-active --quiet "$service"; then
      if [[ "$service" == x-ui ]]; then
        listeners="$(ss -H -ltnp "sport = :$port")" || return 1
        core="$(ss -H -ltnp 'sport = :443')" || return 1
        if [[ "$core" != *'"xray-linux-'* ]]; then listeners=''; fi
      else
        listeners="$(ss -H -lunp 'sport = :443')" || return 1
      fi
      if [[ "$listeners" == *"pid=$pid,"* ]]; then
        [[ "$previous" != "$pid" ]] || return 0
        previous="$pid"
      else
        previous=''
      fi
    else
      previous=''
    fi
    sleep 1
  done
  return 1
}

xhttp_update_panel() (
  set -Eeuo pipefail
  umask 077
  local port="$1" panel=/usr/local/x-ui cli=/usr/bin/x-ui database=/etc/x-ui/x-ui.db
  local arch stage core cli_changed=0 stopped=0
  arch="$(xhttp_release_arch)"
  core="bin/xray-linux-$arch"
  [[ "$port" =~ ^[0-9]{1,5}$ && -x "$panel/x-ui" && -x "$panel/$core" && -s "$database" ]]
  stage="$(mktemp -d /usr/local/.xhttp-panel.XXXXXXXX)"
  restore_panel() {
    if [[ -d "$stage/previous" ]]; then
      systemctl stop x-ui || return 1
      if [[ -d "$panel" ]]; then mv -T "$panel" "$stage/failed" || return 1; fi
      mv -T "$stage/previous" "$panel" || return 1
      sqlite3 -batch -bail -cmd '.timeout 5000' "$database" ".restore '$stage/x-ui.db'" || return 1
      if [[ "$cli_changed" == 1 ]]; then cp -aT "$stage/cli" "$cli" || return 1; fi
    fi
    xhttp_restart_vpn_service x-ui && xhttp_wait_for_vpn_service x-ui "$port"
  }
  cleanup_panel_update() {
    local status="$?"
    if [[ "$status" != 0 && "$stopped" == 1 ]]; then
      if ! restore_panel; then
        printf '3x-ui rollback failed. Retained recovery files at %s\n' "$stage" >&2
        exit 70
      fi
      printf '%s\n' '3x-ui/Xray update failed. The previous service was restored.' >&2
    fi
    rm -rf -- "$stage"
  }
  trap cleanup_panel_update EXIT
  trap 'exit 1' INT TERM HUP
  xhttp_stage_panel_release "$stage" "$arch" "$panel"
  [[ -d "$stage/x-ui" || -f "$stage/xray" ]] || exit 0
  if [[ -d "$stage/x-ui" ]]; then
    cp -aT "$cli" "$stage/cli"
    if [[ ! -f "$stage/xray" ]]; then
      cp -aT "$panel/$core" "$stage/x-ui/$core"
      cp -aT "$panel/.xhttp-xray.sha256" "$stage/x-ui/.xhttp-xray.sha256"
    fi
  fi
  stopped=1
  systemctl stop x-ui
  sqlite3 -batch -bail -cmd '.timeout 5000' "$database" ".backup '$stage/x-ui.db'"
  if [[ ! -d "$stage/x-ui" ]]; then cp -aT "$panel" "$stage/x-ui"; fi
  if [[ -f "$stage/xray" ]]; then
    mv -fT "$stage/xray" "$stage/x-ui/$core"
    mv -fT "$stage/xray.zip.sha256" "$stage/x-ui/.xhttp-xray.sha256"
  fi
  if [[ ! -f "$stage/panel.tar.gz" && -s "$panel/bin/config.json" ]]; then
    XRAY_LOCATION_ASSET="$stage/x-ui/bin" "$stage/x-ui/$core" run -test -config "$panel/bin/config.json"
  fi
  mv -T "$panel" "$stage/previous"
  mv -T "$stage/x-ui" "$panel"
  xhttp_restart_vpn_service x-ui
  xhttp_wait_for_vpn_service x-ui "$port"
  if [[ -f "$stage/cli" ]]; then
    cli_changed=1
    install -m 700 "$panel/x-ui.sh" "$cli"
  fi
  printf '%s\n' '3x-ui/Xray releases applied and the panel and VPN listeners are ready.'
)

xhttp_update_hysteria() (
  set -Eeuo pipefail
  umask 077
  local binary=/usr/local/bin/xhttp-vps-hysteria service=xhttp-vps-hysteria arch stage digest deployed=0
  [[ -x "$binary" ]]
  arch="$(xhttp_release_arch)"
  if [[ "$arch" == armv7 ]]; then arch=arm; fi
  digest="$(sha256sum "$binary" | awk '{print $1}')"
  stage="$(mktemp -d /usr/local/bin/.xhttp-hysteria.XXXXXXXX)"
  cleanup_hysteria_update() {
    local status="$?"
    if [[ "$status" != 0 && "$deployed" == 1 ]]; then
      if ! cp -aT "$stage/previous" "$stage/restore" || ! mv -fT "$stage/restore" "$binary" ||
        ! xhttp_restart_vpn_service "$service" ||
        ! xhttp_wait_for_vpn_service "$service"; then
        printf 'Hysteria 2 rollback failed. Retained recovery files at %s\n' "$stage" >&2
        exit 70
      fi
      printf '%s\n' 'Hysteria 2 update failed. The previous service was restored.' >&2
    fi
    rm -rf -- "$stage"
  }
  trap cleanup_hysteria_update EXIT
  trap 'exit 1' INT TERM HUP
  xhttp_latest_release_asset HyNetworks/hysteria "hysteria-linux-$arch" "$stage/hysteria" "$digest"
  [[ -f "$stage/hysteria" ]] || exit 0
  chmod 755 "$stage/hysteria"
  "$stage/hysteria" version >/dev/null
  cp -aT "$binary" "$stage/previous"
  deployed=1
  mv -fT "$stage/hysteria" "$binary"
  xhttp_restart_vpn_service "$service"
  xhttp_wait_for_vpn_service "$service"
  printf '%s\n' 'Hysteria 2 release applied and the UDP listener is ready.'
)

xhttp_issue_certbot_certificate() {
  local config_dir="$1" work_dir="$2" logs_dir="$3" webroot="$4"
  local -a ca_options=()
  if [[ "${TLS_MODE:-production}" == staging ]]; then ca_options+=(--test-cert); fi
  certbot certonly --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring \
    "${ca_options[@]}" --config-dir "$config_dir" --work-dir "$work_dir" --logs-dir "$logs_dir" \
    --webroot --webroot-path "$webroot" --cert-name "$DOMAIN" -d "$DOMAIN"
}

xhttp_tls_ca_file() {
  if [[ "${TLS_MODE:-production}" == staging ]]; then
    printf '%s\n' "$CERT_DIR/staging-ca.pem"
  else
    printf '%s\n' /etc/ssl/certs/ca-certificates.crt
  fi
}

xhttp_prepare_staging_ca() (
  [[ "${TLS_MODE:-production}" == staging ]] || return 0
  local bundle root name
  bundle="$(xhttp_tls_ca_file)"
  if [[ ! -s "$bundle" ]]; then
    root="$(mktemp "$CERT_DIR/.staging-root.XXXXXXXX")" || return 1
    local temporary
    temporary="$(mktemp "$CERT_DIR/.staging-ca.XXXXXXXX")" || { rm -f -- "$root"; return 1; }
    trap 'rm -f -- "$root" "$temporary"' EXIT
    for name in letsencrypt-stg-root-x1.pem letsencrypt-stg-root-x2.pem gen-y/root-ye.pem gen-y/root-yr.pem; do
      curl -q -fsS --proto '=https' --connect-timeout 5 --max-time 20 --retry 2 \
        "https://letsencrypt.org/certs/staging/$name" --output "$root" || return 1
      openssl x509 -in "$root" -outform PEM >> "$temporary" || return 1
    done
    mv -fT "$temporary" "$bundle" || return 1
  fi
  openssl verify -purpose sslserver -verify_hostname "$DOMAIN" -no-CApath -no-CAstore \
    -CAfile "$bundle" -untrusted "$CERT_DIR/fullchain.pem" "$CERT_DIR/fullchain.pem" >/dev/null
)

xhttp_tls_label() {
  case "${TLS_MODE:-production}" in
    production) printf "%s\n" "Trusted Let's Encrypt certificate" ;;
    staging) printf '%s\n' "Let's Encrypt staging certificate (test trust only)" ;;
    *) printf '%s\n' 'Test self-signed certificate' ;;
  esac
}

xhttp_install_cert_renewal() {
  local reload='systemctl reload nginx'
  local ca_option=
  if [[ "${TLS_MODE:-production}" == staging ]]; then ca_option=' --test-cert'; fi
  case "${TRANSPORT:-xhttp}" in
    vision|xhttp) reload+=' && systemctl try-restart x-ui' ;;
    hysteria2) reload+=' && systemctl try-restart xhttp-vps-hysteria' ;;
  esac
  cat > /etc/systemd/system/xhttp-vps-cert-renew.service <<EOF
[Unit]
Description=Renew the VPN site's Let's Encrypt certificate
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
UMask=0077
ExecStart=/usr/bin/certbot renew --quiet${ca_option} --config-dir /etc/xhttp-vps-acme --work-dir /var/lib/xhttp-vps-acme --logs-dir /var/log/xhttp-vps-acme --deploy-hook "$reload"
EOF
  cat > /etc/systemd/system/xhttp-vps-cert-renew.timer <<'EOF'
[Unit]
Description=Check the VPN site's certificate twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 /etc/systemd/system/xhttp-vps-cert-renew.{service,timer}
  systemctl daemon-reload
  systemctl enable --now xhttp-vps-cert-renew.timer
}

xhttp_routing_revision() {
  curl -q -fsS --proto '=https' --retry 2 --connect-timeout 5 --max-time 15 \
    https://api.github.com/repos/hydraponique/roscomvpn-routing/git/ref/heads/main \
    | jq -er '.object.sha | select(type=="string" and test("^[a-f0-9]{40}$"))'
}

xhttp_fetch_routing() (
  local revision="$1" path="$2"
  case "$path" in HAPP/DEFAULT.DEEPLINK|INCY/DEFAULT.DEEPLINK|MIHOMO/default.yaml) ;; *) exit 1 ;; esac
  xhttp_fetch_repo_text hydraponique/roscomvpn-routing "$revision" "$path"
)

xhttp_fetch_repo_text() (
  set -Eeuo pipefail
  local repo="$1" revision="$2" path="$3" response temporary sha blob
  [[ "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ && "$revision" =~ ^[a-f0-9]{40}$ ]] || exit 1
  [[ "$path" =~ ^[a-zA-Z0-9_./-]+$ && "$path" != *..* ]] || exit 1
  temporary="$(mktemp)" || exit 1
  trap 'rm -f -- "$temporary"' EXIT
  response="$(curl -q -fsS --proto '=https' --retry 2 --connect-timeout 5 --max-time 20 \
    "https://api.github.com/repos/$repo/contents/$path?ref=$revision")" || exit 1
  sha="$(jq -er '.sha | select(type=="string" and test("^[a-f0-9]{40}$"))' <<<"$response")" || exit 1
  jq -er 'select(.type=="file" and .encoding=="base64") | .content' <<<"$response" | base64 -d > "$temporary" || exit 1
  blob="$({ printf 'blob %s\0' "$(stat -c '%s' "$temporary")"; cat "$temporary"; } | sha1sum)" || exit 1
  [[ "${blob%% *}" == "$sha" ]] || exit 1
  cat "$temporary"
)

xhttp_create_api_header_file() {
  local token="$1" file
  [[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || return 1
  file="$(mktemp /root/xhttp-api-headers.XXXXXXXX)"
  chmod 600 "$file"
  printf 'Authorization: Bearer %s\nX-Requested-With: XMLHttpRequest\n' "$token" > "$file"
  printf '%s' "$file"
}

xhttp_render_acme_nginx() {
cat <<EOF
server {
    listen 80 default_server;
    server_name _;
    server_tokens off;
    access_log off;
    return 404;
}
server {
    listen 80;
    server_name ${DOMAIN};
    server_tokens off;
    access_log off;
    root /var/www/3xui-cover;
    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 301 https://${DOMAIN}\$request_uri; }
}
EOF
}

xhttp_install_acme_nginx() (
  set -Eeuo pipefail
  local staging target=/etc/nginx/sites-available/3xui-self-steal.conf
  local link=/etc/nginx/sites-enabled/3xui-self-steal.conf
  staging="$(mktemp -d /etc/nginx/xhttp-acme-config.XXXXXXXX)"
  trap 'rm -f "$staging/new" "$staging/previous" "$staging/link"; rmdir "$staging"' EXIT
  [[ ! -d "$target" && ! -d "$link" ]] || return 1
  if [[ -e "$target" || -L "$target" ]]; then cp -a "$target" "$staging/previous"; fi
  if [[ -e "$link" || -L "$link" ]]; then cp -a "$link" "$staging/link"; fi
  xhttp_render_acme_nginx > "$staging/new"
  chmod 644 "$staging/new"
  mv -T "$staging/new" "$target"
  ln -sfn "$target" "$link"
  if ! nginx -t; then
    rm -f "$target" "$link"
    if [[ -e "$staging/previous" || -L "$staging/previous" ]]; then mv -T "$staging/previous" "$target"; fi
    if [[ -e "$staging/link" || -L "$staging/link" ]]; then mv -T "$staging/link" "$link"; fi
    return 1
  fi
)

xhttp_nginx_version() {
  local version
  version="${XHTTP_NGINX_VERSION_OVERRIDE:-$(nginx -v 2>&1 | sed -n 's#^nginx version: nginx/\([0-9][0-9.]*\).*#\1#p')}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

xhttp_version_at_least() {
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" == "$2" ]]
}

xhttp_render_nginx_http2() {
  local version
  version="$(xhttp_nginx_version)" || return 1
  if xhttp_version_at_least "$version" 1.25.1; then
    printf '    listen 127.0.0.1:%s ssl;\n    http2 on;\n' "$FALLBACK_PORT"
  else
    printf '    listen 127.0.0.1:%s ssl http2;\n' "$FALLBACK_PORT"
  fi
}

xhttp_install_nginx() (
  set -Eeuo pipefail
  local staging version target=/etc/nginx/sites-available/3xui-self-steal.conf
  local link=/etc/nginx/sites-enabled/3xui-self-steal.conf
  if ! xhttp_prepare_staging_ca; then
    printf "%s\n" "Could not verify the Let's Encrypt staging certificate." >&2
    return 1
  fi
  staging="$(mktemp -d /etc/nginx/xhttp-config.XXXXXXXX)"
  trap 'rm -f "$staging/new" "$staging/previous" "$staging/link" "$staging/default.pem" "$staging/default-key.pem"; rmdir "$staging"' EXIT
  [[ ! -d "$target" && ! -d "$link" ]] || return 1
  if [[ -e "$target" || -L "$target" ]]; then cp -a "$target" "$staging/previous"; fi
  if [[ -e "$link" || -L "$link" ]]; then cp -a "$link" "$staging/link"; fi
  version="$(xhttp_nginx_version)" || return 1
  if ! xhttp_version_at_least "$version" 1.19.4 &&
     [[ ! -s "$CERT_DIR/default.pem" || ! -s "$CERT_DIR/default-key.pem" ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj '/CN=localhost' -keyout "$staging/default-key.pem" -out "$staging/default.pem" >/dev/null 2>&1 || return 1
    install -m 600 "$staging/default-key.pem" "$CERT_DIR/default-key.pem" || return 1
    install -m 644 "$staging/default.pem" "$CERT_DIR/default.pem" || return 1
  fi
  xhttp_render_nginx > "$staging/new"
  chmod 644 "$staging/new"
  mv -T "$staging/new" "$target"
  ln -sfn "$target" "$link"
  if ! nginx -t; then
    rm -f "$target" "$link"
    if [[ -e "$staging/previous" || -L "$staging/previous" ]]; then mv -T "$staging/previous" "$target"; fi
    if [[ -e "$staging/link" || -L "$staging/link" ]]; then mv -T "$staging/link" "$link"; fi
    return 1
  fi
)

xhttp_render_nginx() {
local listener default_listener default_tls version subscriptions='' FALLBACK_PORT="${FALLBACK_PORT:-}"
if xhttp_uses_panel; then
  listener="$(xhttp_render_nginx_http2)" || return 1
  subscriptions="$(xhttp_render_subscription_locations)" || return 1
else
  FALLBACK_PORT=443
  listener="$(xhttp_render_nginx_http2)" || return 1
  listener="${listener/127.0.0.1:/0.0.0.0:}"
fi
default_listener="${listener/;/ default_server;}"
if [[ "${TRANSPORT:-}" == hysteria2 ]]; then
  listener+=$'\n    add_header Alt-Svc \'h3=":443"; ma=86400\' always;'
fi
version="$(xhttp_nginx_version)" || return 1
if xhttp_version_at_least "$version" 1.19.4; then
  default_tls='    ssl_reject_handshake on;'
else
  printf -v default_tls '    ssl_certificate %s/default.pem;\n    ssl_certificate_key %s/default-key.pem;' "$CERT_DIR" "$CERT_DIR"
fi
xhttp_render_acme_nginx
cat <<EOF
server {
$default_listener
    server_name _;
    server_tokens off;
    access_log off;
    ssl_protocols TLSv1.2 TLSv1.3;
$default_tls
    return 421;
}
server {
$listener
    server_name ${DOMAIN};
    server_tokens off;
    access_log off;
    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/3xui-cover;
    index index.html;
$subscriptions
    location / { try_files \$uri \$uri/ =404; }
}
EOF
}

xhttp_render_subscription_locations() {
local path ca_file
ca_file="$(xhttp_tls_ca_file)"
for path in "$SUB_PATH" "${SUB_JSON_PATH:-}" "${SUB_CLASH_PATH:-}"; do
[[ -n "$path" ]] || continue
cat <<EOF
    location ^~ /${path}/ {
        proxy_pass https://127.0.0.1:${SUB_PORT};
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate $ca_file;
        proxy_ssl_verify_depth 3;
        proxy_ssl_server_name on;
        proxy_ssl_name ${DOMAIN};
        proxy_set_header Host ${DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
EOF
if [[ "${SUB_PRIVACY_HEADERS:-false}" == true ]]; then
  cat <<'EOF'
        proxy_hide_header Cache-Control;
        proxy_hide_header Referrer-Policy;
        add_header Cache-Control 'private, no-store' always;
        add_header Referrer-Policy 'no-referrer' always;
EOF
fi
printf '    }\n'
done
}

xhttp_probe_cover_website() (
  local index="${1:-/var/www/3xui-cover/index.html}" response status
  [[ -s "$index" ]] || return 1
  response="$(mktemp)" || return 1
  trap 'rm -f -- "$response"' EXIT
  status="$(curl -q -fsS --cacert "$(xhttp_tls_ca_file)" --noproxy '*' --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 \
    --output "$response" --write-out '%{http_code}' "https://${DOMAIN}/")" || return 1
  [[ "$status" == 200 ]] && cmp -s -- "$index" "$response"
)

xhttp_verify_loopback_listener() {
  local port="$1" listeners
  listeners="$(ss -H -ltn "sport = :$port")" || return 1
  awk -v expected="127.0.0.1:$port" '
    NF { if ($4 != expected) { wrong=1; exit }; seen=1 }
    END { exit (!seen || wrong) }
  ' <<<"$listeners"
}

xhttp_probe_foreign_sni() {
  xhttp_probe_rejected_sni -servername unrelated.invalid
}

xhttp_probe_no_sni() {
  xhttp_probe_rejected_sni -noservername
}

xhttp_probe_rejected_sni() {
  local response version fingerprint peer
  response="$(
    timeout 12 openssl s_client -connect 127.0.0.1:443 -tls1_3 "$@" </dev/null 2>&1 || true
  )"
  if grep -Eiq 'unrecognized name|alert number 112' <<<"$response"; then return 0; fi
  version="$(xhttp_nginx_version)" || return 1
  if xhttp_version_at_least "$version" 1.19.4; then return 1; fi
  fingerprint="$(openssl x509 -noout -fingerprint -sha256 -in "$CERT_DIR/default.pem")" || return 1
  peer="$(openssl x509 -noout -fingerprint -sha256 <<<"$response" 2>/dev/null)" || return 1
  [[ "$peer" == "$fingerprint" ]]
}

xhttp_probe_h2_alpn() {
  local response
  response="$(
    timeout 12 openssl s_client -connect 127.0.0.1:443 -tls1_3 \
      -servername "$DOMAIN" -verify_hostname "$DOMAIN" -verify_return_error -CAfile "$(xhttp_tls_ca_file)" \
      -alpn 'h2,http/1.1' </dev/null 2>&1 || true
  )"
  grep -Fq 'ALPN protocol: h2' <<<"$response" && grep -Fq 'Verify return code: 0 (ok)' <<<"$response"
}

random_hex() { od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'; }
port_busy() { ss -H -ltn "sport = :$1" | grep -q .; }
random_port() {
  local p attempt
  for ((attempt=0; attempt<100; attempt++)); do
    p=$((20000 + 0x$(random_hex 2) % 40000))
    [[ "$p" != 40000 ]] || continue
    port_busy "$p" || { printf '%s' "$p"; return; }
  done
  return 1
}

xhttp_build_warp_outbound() {
  local data_json="$1" config_json="$2" private_key client_id peer_key endpoint addresses reserved
  local ipv4_endpoint ipv4 port
  private_key="$(jq -r '.private_key // empty' <<<"$data_json")"
  client_id="$(jq -r '.client_id // empty' <<<"$data_json")"
  peer_key="$(jq -r '.config.peers[0].public_key // empty' <<<"$config_json")"
  endpoint="$(jq -r '.config.peers[0].endpoint.host // empty' <<<"$config_json")"
  ipv4_endpoint="$(jq -r '.config.peers[0].endpoint.v4 // empty' <<<"$config_json")"
  # The VPS uses IPv4 and the account response can use port 0 as a placeholder.
  ipv4="${ipv4_endpoint%%:*}"
  port="${ipv4_endpoint#*:}"
  if [[ "$ipv4_endpoint" != *:* || "$port" == 0 ]]; then port="${endpoint##*:}"; fi
  if xhttp_valid_ipv4 "$ipv4" && [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then
    endpoint="$ipv4:$port"
  fi
  addresses="$(jq -nc --arg v4 "$(jq -r '.config.interface.addresses.v4 // empty' <<<"$config_json")" \
    --arg v6 "$(jq -r '.config.interface.addresses.v6 // empty' <<<"$config_json")" \
    '[$v4, $v6 | select(length > 0) | if contains(":") then . + "/128" else . + "/32" end]')"
  [[ -n "$private_key" && -n "$client_id" && -n "$peer_key" && -n "$endpoint" && "$addresses" != "[]" ]] || return 1
  reserved="$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1 | awk 'BEGIN { printf "[" } { for (i=1; i<=NF; i++) { if (n++) printf ","; printf $i } } END { print "]" }')" || return 1
  [[ "$reserved" != "[]" ]] || return 1
  jq -nc --arg private "$private_key" --arg public "$peer_key" --arg endpoint "$endpoint" \
    --argjson addresses "$addresses" --argjson reserved "$reserved" \
    '{tag:"warp",protocol:"wireguard",settings:{mtu:1420,secretKey:$private,address:$addresses,reserved:$reserved,domainStrategy:"ForceIPv4v6",peers:[{publicKey:$public,endpoint:$endpoint}],noKernelTun:true}}'
}

xhttp_warp_config() {
  jq -ce --argjson w "$1" '
    def catchall:
      del(.type,.ruleTag,.outboundTag,.balancerTag)
      | if .network=="tcp,udp" or .network=="udp,tcp" then del(.network) else . end
      | length==0;
    .outbounds=((.outbounds//[])|map(select(.tag!="warp")))+[$w]
    | .routing.domainStrategy="IPOnDemand"
    | ((.routing.rules//[]) | map(select(
        .ruleTag!="xhttp-vps-warp-ru-domain" and .ruleTag!="xhttp-vps-warp-ru-ip"))) as $rules
    | [$rules | to_entries[] | select(.value|catchall) | .key] as $defaults
    | if ($defaults|length)>1 or (($defaults|length)==1 and $defaults[0]!=($rules|length)-1)
      then error("Catch-all must be the final rule; review routing before adding WARP") else . end
    | ($defaults[0] // ($rules|length)) as $at
    | if ($defaults|length)==1 and
        ([.outbounds[] | select(.tag==$rules[$at].outboundTag and .protocol=="freedom")]|length)!=1
      then error("Only a terminal direct/freedom catch-all may follow WARP; review the terminal policy") else . end
    | [.outbounds[] | select(.protocol=="blackhole") | .tag] as $blocked
    | (.api.tag // "api") as $api
    | def protected_rule:
        .outboundTag as $tag
        | ($tag==$api or ($blocked|index($tag))!=null);
      .routing.rules = ($rules | map(select(protected_rule))) + [
        {type:"field",domain:["domain:ru","domain:su","domain:xn--p1ai","geosite:category-ru"],outboundTag:"warp",network:"tcp,udp",ruleTag:"xhttp-vps-warp-ru-domain"},
        {type:"field",ip:["geoip:ru"],outboundTag:"warp",network:"tcp,udp",ruleTag:"xhttp-vps-warp-ru-ip"}
      ] + ($rules | map(select(protected_rule|not)))
  '
}

# Validate regional datasets with the installed core before changing panel state.
xhttp_validate_warp_routes() (
  set -Eeuo pipefail
  umask 077
  local check_dir
  local -a binaries=(/usr/local/x-ui/bin/xray-linux-*)
  [[ -x "${binaries[0]}" ]] || return 1
  check_dir="$(mktemp -d /root/xhttp-route-check.XXXXXXXX)"
  trap 'rm -f "$check_dir/config.json" "$check_dir/log"; rmdir "$check_dir"' EXIT
  jq -ce '{outbounds:[{tag:"direct",protocol:"freedom"}],routing:{domainStrategy:.routing.domainStrategy,rules:[.routing.rules[]|select(.ruleTag=="xhttp-vps-warp-ru-domain" or .ruleTag=="xhttp-vps-warp-ru-ip")|.outboundTag="direct"]}}' > "$check_dir/config.json"
  if ! XRAY_LOCATION_ASSET=/usr/local/x-ui/bin "${binaries[0]}" run -test -config "$check_dir/config.json" > "$check_dir/log" 2>&1; then
    printf '%s\n' 'Russian routing validation failed; check geosite:category-ru and geoip:ru. No panel settings changed.' >&2
    cat "$check_dir/log" >&2
    return 1
  fi
)

xhttp_managed_paths() {
  if xhttp_uses_panel; then
    printf '%s\n' /etc/systemd/system/x-ui.service /usr/lib/systemd/system/x-ui.service \
      /usr/bin/x-ui /etc/default/x-ui /usr/local/x-ui /etc/x-ui /var/log/x-ui \
      /etc/fail2ban/filter.d/xhttp-vps-panel.conf /etc/fail2ban/jail.d/xhttp-vps-panel.local \
      /etc/systemd/system/x-ui.service.d/10-xui-sandbox.conf
  fi
  printf '%s\n' /etc/nginx/sites-available/3xui-self-steal.conf /etc/nginx/sites-enabled/3xui-self-steal.conf \
    /etc/nginx/sites-enabled/default /var/www/3xui-cover \
    /etc/modules-load.d/bbr.conf /etc/sysctl.d/99-xhttp-vps-network.conf \
    /etc/apt/apt.conf.d/52xhttp-vps-auto-upgrades /etc/apt/apt.conf.d/53xhttp-vps-unattended-upgrades \
    /etc/fail2ban/jail.d/xhttp-vps-sshd.local \
    /usr/local/sbin/xhttp-vps-maintenance /etc/systemd/system/xhttp-vps-maintenance.service \
    /etc/systemd/system/xhttp-vps-maintenance.timer /etc/systemd/system/xhttp-vps-reboot.service \
    /etc/systemd/system/xhttp-vps-reboot.timer \
    "/root/cert/$DOMAIN" "$RESULT_FILE"
  if [[ "${DISABLE_PING:-0}" == 1 ]]; then printf '%s\n' /etc/sysctl.d/99-xhttp-vps-ping.conf; fi
  if [[ "${ACME_CLIENT:-}" == certbot ]]; then
    printf '%s\n' /etc/xhttp-vps-acme /var/lib/xhttp-vps-acme /var/log/xhttp-vps-acme \
      /etc/systemd/system/xhttp-vps-cert-renew.service /etc/systemd/system/xhttp-vps-cert-renew.timer
  fi
  case "${TRANSPORT:-xhttp}" in
    amneziawg) printf '%s\n' /etc/amnezia/amneziawg/awg-vps.conf /etc/xhttp-vps-awg \
      /usr/local/sbin/xhttp-vps-awg-firewall /etc/sysctl.d/99-xhttp-vps-awg.conf \
      /etc/apt/keyrings/xhttp-vps-amnezia.gpg /etc/apt/sources.list.d/xhttp-vps-amnezia.sources \
      /etc/apt/preferences.d/xhttp-vps-amnezia ;;
    hysteria2) printf '%s\n' /etc/xhttp-vps-hysteria.yaml /root/xhttp-vps-hysteria.uri \
      /usr/local/bin/xhttp-vps-hysteria /etc/systemd/system/xhttp-vps-hysteria.service ;;
  esac
}

xhttp_validate_ssh_access_state() {
  local ssh_mode
  ssh_mode="${SSH_ACCESS_MODE:-}"
  if [[ -z "$ssh_mode" ]]; then
    if [[ "${SSH_HARDENING:-0}" == 1 ]]; then ssh_mode='admin'; else ssh_mode='existing'; fi
  fi
  case "$ssh_mode" in
    admin-cert)
      [[ "${SSH_HARDENING:-0}" == 1 && "${ADMIN_USER:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || return 1
      xhttp_validate_ssh_ca_b64 "${ADMIN_KEYS_B64:-}" || return 1
      ;;
    admin)
      [[ "${SSH_HARDENING:-0}" == 1 ]] || return 1
      [[ "${ADMIN_USER:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || return 1
      xhttp_validate_authorized_keys_b64 "${ADMIN_KEYS_B64:-}" || return 1
      ;;
    root-key)
      [[ "${SSH_HARDENING:-0}" == 1 && "${ADMIN_USER:-}" == root ]] || return 1
      xhttp_validate_authorized_keys_b64 "${ADMIN_KEYS_B64:-}" || return 1
      ;;
    root-password)
      [[ "${SSH_HARDENING:-0}" == 1 && "${ADMIN_USER:-}" == root ]] || return 1
      ;;
    existing)
      [[ "${SSH_HARDENING:-0}" == 0 ]] || return 1
      ;;
    *) return 1 ;;
  esac
}

xhttp_validate_state() {
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$DOMAIN" == *.* && "$DOMAIN" != *..* ]] || return 1
  [[ "$RESULT_FILE" =~ ^/root/xhttp-vps-result-[A-Za-z0-9_-]+\.txt$ ]] || return 1
  [[ "${MANAGED_BACKUP:-}" =~ ^/root/xhttp-managed\.[A-Za-z0-9]+$ ]] || return 1
  [[ -d "$MANAGED_BACKUP" && ! -L "$MANAGED_BACKUP" ]] || return 1
  [[ "${SAFE_INSTANCE:-}" =~ ^[A-Za-z0-9_-]+$ || -z "${SAFE_INSTANCE:-}" ]] || return 1
  case "${ACME_CLIENT:-acme.sh}" in certbot|acme.sh) ;; *) return 1 ;; esac
  [[ "${TLS_MODE:-production}" != staging || "${ACME_CLIENT:-}" == certbot ]] || return 1
  case "${SUB_ENCRYPT_LINKS:-}" in true|false|'') ;; *) return 1 ;; esac
  case "${SUB_PROFILE_MODE:-}" in none|builtin|'') ;; *) return 1 ;; esac
  case "${SUB_PRIVACY_HEADERS:-}" in true|false|'') ;; *) return 1 ;; esac
  case "${CREATE_RECOVERY_BACKUP:-0}" in 0|1) ;; *) return 1 ;; esac
  [[ -z "${SSH_ALLOWED_IP:-}" ]] || xhttp_valid_ipv4 "$SSH_ALLOWED_IP" || return 1
  case "${TRANSPORT:-xhttp}" in
    vision|xhttp) ;;
    amneziawg|hysteria2)
      [[ "${INSTALL_MODE:-}" == standalone && "${UDP_PORT:-}" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
      (( UDP_PORT <= 65535 )) || return 1
      xhttp_valid_ipv4 "${PUBLIC_IP:-}" || return 1
      if [[ "$TRANSPORT" == hysteria2 ]]; then
        [[ "$UDP_PORT" == 443 && "${HY_PASSWORD:-}" =~ ^[a-f0-9]{64}$ ]] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  case "${MAINTENANCE_MODE:-weekly}" in security|weekly|none) ;; *) return 1 ;; esac
  case "${TWO_FACTOR_GUIDE:-0}" in 0|1) ;; *) return 1 ;; esac
  case "${PANEL_2FA_ENROLL:-0}" in 0|1) ;; *) return 1 ;; esac
  case "${DISABLE_PING:-0}" in 0|1) ;; *) return 1 ;; esac
  case "${PREV_IPV4_ECHO_IGNORE:-0}" in 0|1) ;; *) return 1 ;; esac
  if [[ -n "${SSH_TARGET_PORT:-}" ]]; then
    [[ "$SSH_TARGET_PORT" =~ ^[1-9][0-9]{4}$ ]] && (( SSH_TARGET_PORT <= 65535 )) || return 1
  fi
  xhttp_validate_ssh_access_state
}

xhttp_validate_ownership_journal() {
  [[ -f "$MANAGED_BACKUP/ready" && -s "$MANAGED_BACKUP/paths" ]] || return 1
  awk -F '\t' '$1!=NR || NF!=2 {exit 1}' "$MANAGED_BACKUP/paths" || return 1
  [[ "$(cut -f2- "$MANAGED_BACKUP/paths" | sort | uniq -d | wc -l)" == 0 ]] || return 1
  local path
  while IFS=$'\t' read -r _ path; do
    grep -Fxq -- "$path" < <(xhttp_managed_paths) || return 1
  done < "$MANAGED_BACKUP/paths"
}

xhttp_record_ownership() (
  set -e
  umask 077
  xhttp_validate_state || return 1
  local path index=0
  if [[ -e "$MANAGED_BACKUP/ready" ]]; then
    xhttp_validate_ownership_journal || return 1
    index="$(wc -l < "$MANAGED_BACKUP/paths")"
    while IFS= read -r path; do
      grep -Fxq -- "$path" < <(cut -f2- "$MANAGED_BACKUP/paths") && continue
      index=$((index+1))
      if [[ -e "$path" || -L "$path" ]]; then
        rm -rf -- "$MANAGED_BACKUP/original-$index.new" || return 1
        cp -a -- "$path" "$MANAGED_BACKUP/original-$index.new" || return 1
        mv -T -- "$MANAGED_BACKUP/original-$index.new" "$MANAGED_BACKUP/original-$index" || return 1
      fi
      printf '%s\t%s\n' "$index" "$path" >> "$MANAGED_BACKUP/paths" || return 1
    done < <(xhttp_managed_paths)
    return 0
  fi
  # A failed initial snapshot is never trusted.
  : > "$MANAGED_BACKUP/paths.new" || return 1
  while IFS= read -r path; do
    index=$((index+1))
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "$MANAGED_BACKUP/original-$index" || return 1
    fi
    printf '%s\t%s\n' "$index" "$path" >> "$MANAGED_BACKUP/paths.new" || return 1
  done < <(xhttp_managed_paths)
  mv "$MANAGED_BACKUP/paths.new" "$MANAGED_BACKUP/paths" || return 1
  touch "$MANAGED_BACKUP/ready"
)

xhttp_restore_owned_files() (
  set -e
  umask 077
  xhttp_validate_state || return 1
  [[ -f "$MANAGED_BACKUP/ready" ]] || return 1
  local index path
  # Validate every recorded target against the allowlist before deleting anything.
  xhttp_validate_ownership_journal || return 1
  while IFS=$'\t' read -r index path; do
    [[ "$index" =~ ^[0-9]+$ ]] || return 1
    if [[ -e "$path" || -L "$path" ]]; then
      rm -rf -- "$path" || return 1
    fi
    if [[ -e "$MANAGED_BACKUP/original-$index" || -L "$MANAGED_BACKUP/original-$index" ]]; then
      mkdir -p -- "$(dirname "$path")" || return 1
      cp -a -- "$MANAGED_BACKUP/original-$index" "$path" || return 1
    fi
  done < "$MANAGED_BACKUP/paths"
  rm -rf -- "$MANAGED_BACKUP" || return 1
  printf '%s\n' 'Managed VPN files were permanently deleted; pre-existing files were restored.'
)

xhttp_probe_config() {
  local port="$1"
  jq -ce --argjson port "$port" '
    def decode: if type=="string" then fromjson else . end;
    (.streamSettings|decode) as $s | (.settings|decode) as $v
    | [$v.clients[]? | select(.enable==true and ((.expiryTime//0)<=0 or .expiryTime>(now*1000)))] as $clients
    | if .enable!=true or (["xhttp","tcp","raw"]|index($s.network))==null or $s.security!="reality" or ($clients|length)==0
      then error("No enabled supported REALITY client available for a traffic probe") else . end
    | if $s.network=="xhttp" and (($clients[0].flow//"")!="")
      then error("XHTTP client flow must be empty")
      elif ($s.network=="tcp" or $s.network=="raw") and (($clients[0].flow//"")!="xtls-rprx-vision")
      then error("TCP/RAW client must use xtls-rprx-vision") else . end
    | {log:{loglevel:"warning"},
       inbounds:[{listen:"127.0.0.1",port:$port,protocol:"socks",settings:{auth:"noauth",udp:false}}],
       outbounds:[{tag:"probe",protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:.port,
         users:[{id:$clients[0].id,encryption:($v.encryption//"none"),flow:($clients[0].flow//"")}]}]},
         streamSettings:({network:$s.network,security:"reality",
           realitySettings:{serverName:$s.realitySettings.serverNames[0],
             fingerprint:($s.realitySettings.settings.fingerprint//"chrome"),
             password:$s.realitySettings.settings.publicKey,shortId:$s.realitySettings.shortIds[0]}}
           + if $s.network=="xhttp" then {xhttpSettings:$s.xhttpSettings}
             else {tcpSettings:($s.tcpSettings//{header:{type:"none"}})} end)}]}
  '
}

xhttp_run_probe() (
  set -Eeuo pipefail
  umask 077
  local config="$1" expected="$2" probe_dir probe_pid='' port result attempt
  probe_dir="$(mktemp -d /root/xhttp-probe.XXXXXXXX)"
  trap 'if [[ -n "$probe_pid" ]]; then kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true; fi; rm -f "$probe_dir/config.json" "$probe_dir/log"; rmdir "$probe_dir"' EXIT
  printf '%s\n' "$config" > "$probe_dir/config.json"
  "$XRAY_BINARY" run -test -config "$probe_dir/config.json" > "$probe_dir/log" 2>&1
  "$XRAY_BINARY" run -config "$probe_dir/config.json" > "$probe_dir/log" 2>&1 &
  probe_pid=$!
  port="$(jq -r '.inbounds[0].port' <<<"$config")"
  for ((attempt=0; attempt<20; attempt++)); do
    kill -0 "$probe_pid" 2>/dev/null || return 1
    if port_busy "$port"; then break; fi
    sleep 0.2
  done
  # Disable environment proxy overrides and fail if the response is not a trace.
  result="$(curl --noproxy '' --proxy "socks5h://127.0.0.1:$port" -fsS \
    --connect-timeout 10 --max-time 30 https://www.cloudflare.com/cdn-cgi/trace)"
  kill -0 "$probe_pid" 2>/dev/null
  grep -Eq '^ip=.+' <<<"$result"
  if [[ "$expected" == warp ]]; then grep -Eq '^warp=(on|plus)$' <<<"$result"; fi
)

xhttp_verify_traffic() {
  local response inbound config port test_mode="${1:-all}"
  local -a binaries
  mapfile -t binaries < <(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -executable)
  [[ ${#binaries[@]} == 1 ]] || return 1
  XRAY_BINARY="${binaries[0]}"
  port="$(random_port)" || return 1
  export XRAY_BINARY
  export -f xhttp_run_probe port_busy
  if [[ "$test_mode" != warp ]]; then
  response="$(xhttp_memory_api /panel/api/inbounds/list)" || return 1
  inbound="$(jq -ce --arg tag "${INBOUND_TAG:-in-443-xhttp-reality}" '.obj | if type=="string" then fromjson else . end | map(select(.tag==$tag)) | if length==1 then .[0] else error("Missing managed inbound") end' <<<"$response")" || return 1
  config="$(xhttp_probe_config "$port" <<<"$inbound")" || return 1
  # Invoke in a new Bash so callers may test failure without suppressing errexit.
  bash -c 'xhttp_run_probe "$(cat)" direct' <<<"$config" || return 1
  fi
  if [[ "${ENABLE_WARP:-0}" == 1 ]]; then
    response="$(xhttp_memory_api /panel/api/xray/ -X POST)" || return 1
    config="$(jq -ce --argjson p "$port" '
      def decode: if type=="string" then fromjson else . end;
      .obj|decode|.xraySetting|decode
      | [.outbounds[]|select(.tag=="warp")] as $w
      | if ($w|length)!=1 then error("Missing WARP outbound") else . end
      | {log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$p,protocol:"socks",settings:{auth:"noauth"}}],outbounds:$w}
    ' <<<"$response")" || return 1
    bash -c 'xhttp_run_probe "$(cat)" warp' <<<"$config" || return 1
  fi
}
