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

xhttp_ssh_access_label() {
  case "$1" in
    admin) printf '%s' 'new sudo administrator, SSH key only, direct root login disabled' ;;
    root-key) printf '%s' 'root login by SSH key only; password login disabled' ;;
    existing) printf '%s' 'current SSH policy retained (not recommended)' ;;
    *) return 1 ;;
  esac
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

xhttp_install_admin_access() {
  local home_dir temporary_sudo
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || return 1
  xhttp_validate_authorized_keys_b64 "$ADMIN_KEYS_B64" || return 1
  if getent passwd "$ADMIN_USER" >/dev/null; then
    home_dir="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [[ "$home_dir" == "/home/$ADMIN_USER" ]] || return 1
  else
    useradd --create-home --user-group --shell /bin/bash "$ADMIN_USER"
  fi
  home_dir="/home/$ADMIN_USER"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home_dir/.ssh"
  printf '%s' "$ADMIN_KEYS_B64" | base64 -d > "$home_dir/.ssh/authorized_keys.new"
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
    admin) xhttp_install_admin_access ;;
    root-key) xhttp_install_root_key_access ;;
    existing) return 0 ;;
    *) return 1 ;;
  esac
}

xhttp_render_sshd_hardening() {
  local mode="$1" login_user="$2" permit_root allow_user
  case "$mode" in
    admin)
      [[ "$login_user" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$login_user" != root ]] || return 1
      permit_root=no
      allow_user="$login_user"
      ;;
    root-key)
      [[ "$login_user" == root ]] || return 1
      permit_root=prohibit-password
      allow_user=root
      ;;
    *) return 1 ;;
  esac
  cat <<EOF
# Managed by xhttp-vps-setup. Keep local TCP forwarding for the private panel.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
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
}

xhttp_harden_sshd() {
  local temporary host_name root_config login_config allow_user target previous had_previous=0
  case "${SSH_ACCESS_MODE:-admin}" in
    admin) allow_user="$ADMIN_USER" ;;
    root-key)
      [[ "$ADMIN_USER" == root ]] || return 1
      allow_user=root
      ;;
    *) return 1 ;;
  esac
  target=/etc/ssh/sshd_config.d/00-xhttp-vps-hardening.conf
  previous="$(mktemp /etc/ssh/sshd_config.d/xhttp-vps-previous.XXXXXXXX)"
  if [[ -e "$target" ]]; then
    cp -a "$target" "$previous"
    had_previous=1
  fi
  temporary="$(mktemp /etc/ssh/sshd_config.d/00-xhttp-vps-hardening.conf.XXXXXXXX)"
  if ! xhttp_render_sshd_hardening "${SSH_ACCESS_MODE:-admin}" "$ADMIN_USER" > "$temporary"; then
    rm -f "$temporary" "$previous"
    return 1
  fi
  chmod 600 "$temporary"
  mv -f "$temporary" "$target"
  if ! sshd -t; then
    rm -f "$target"
    if [[ "$had_previous" == 1 ]]; then mv -f "$previous" "$target"; else rm -f "$previous"; fi
    return 1
  fi
  host_name="$(hostname -f 2>/dev/null || hostname)"
  root_config="$(sshd -T -C "user=root,host=${host_name},addr=127.0.0.1")"
  login_config="$(sshd -T -C "user=${allow_user},host=${host_name},addr=127.0.0.1")"
  if [[ "${SSH_ACCESS_MODE:-admin}" == admin ]]; then
    grep -qx 'permitrootlogin no' <<<"$root_config" || {
      rm -f "$target"
      if [[ "$had_previous" == 1 ]]; then mv -f "$previous" "$target"; else rm -f "$previous"; fi
      return 1
    }
  else
    grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$root_config" || {
      rm -f "$target"
      if [[ "$had_previous" == 1 ]]; then mv -f "$previous" "$target"; else rm -f "$previous"; fi
      return 1
    }
  fi
  if ! grep -qx 'passwordauthentication no' <<<"$login_config" \
    || ! grep -qx 'kbdinteractiveauthentication no' <<<"$login_config" \
    || ! grep -qx 'authenticationmethods publickey' <<<"$login_config" \
    || ! grep -Eq "^allowusers( .*)? ${allow_user}( .*)?$|^allowusers ${allow_user}$" <<<"$login_config"; then
    rm -f "$target"
    if [[ "$had_previous" == 1 ]]; then mv -f "$previous" "$target"; else rm -f "$previous"; fi
    return 1
  fi
  rm -f "$previous"
  systemctl reload ssh
  passwd -l root >/dev/null
}

xhttp_verify_ssh_access() {
  local host_name config key_path
  host_name="$(hostname -f 2>/dev/null || hostname)"
  case "${SSH_ACCESS_MODE:-admin}" in
    admin)
      getent passwd "$ADMIN_USER" >/dev/null || return 1
      sudo -u "$ADMIN_USER" sudo -n true || return 1
      key_path="/home/${ADMIN_USER}/.ssh/authorized_keys"
      config="$(sshd -T -C "user=${ADMIN_USER},host=${host_name},addr=127.0.0.1")" || return 1
      grep -qx 'permitrootlogin no' < <(sshd -T -C "user=root,host=${host_name},addr=127.0.0.1") || return 1
      ;;
    root-key)
      [[ "$ADMIN_USER" == root ]] || return 1
      key_path=/root/.ssh/authorized_keys
      config="$(sshd -T -C "user=root,host=${host_name},addr=127.0.0.1")" || return 1
      grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$config" || return 1
      ;;
    *) return 1 ;;
  esac
  [[ -s "$key_path" && "$(stat -c '%a' "$key_path")" == 600 ]] || return 1
  [[ "$(passwd -S root | awk '{print $2}')" == L ]] || return 1
  grep -qx 'passwordauthentication no' <<<"$config" \
    && grep -qx 'kbdinteractiveauthentication no' <<<"$config" \
    && grep -qx 'authenticationmethods publickey' <<<"$config"
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
    security) printf '%s' 'daily Ubuntu security updates; no automatic reboot' ;;
    weekly) printf 'daily security updates, Sunday 05:00 APT and VPN component updates, conditional reboot at 05:30 (%s)' "${MAINTENANCE_TIMEZONE:-Europe/Moscow}" ;;
    none) printf '%s' 'no automatic updates or reboot' ;;
    *) return 1 ;;
  esac
}

xhttp_render_maintenance_timer() {
  local unit=xhttp-vps-maintenance time=05:00:00 detail='package and VPN component updates'
  if [[ "${1:-}" == reboot ]]; then
    unit=xhttp-vps-reboot
    time=05:30:00
    detail='conditional reboot'
  fi
  cat <<EOF
[Unit]
Description=Weekly $detail for xhttp-vps

[Timer]
OnCalendar=Sun *-*-* $time ${MAINTENANCE_TIMEZONE}
AccuracySec=1s
Persistent=false
Unit=$unit.service

[Install]
WantedBy=timers.target
EOF
}

xhttp_render_maintenance_script() {
  printf '#!/usr/bin/env bash\n'
  declare -f xhttp_download_verified xhttp_latest_release_asset xhttp_release_arch \
    xhttp_stage_panel_release xhttp_wait_for_vpn_service xhttp_update_panel xhttp_update_hysteria || return 1
  cat <<'EOF'
set -Eeuo pipefail
phase="$1"
vpn_service="$2"
export TZ="$3"
panel_port="${4:-}"
completed=/run/xhttp-vps-maintenance.ok
exec 9>/run/xhttp-vps-setup.lock
if ! flock -n 9; then
  logger -t xhttp-vps-maintenance "Skipped $phase while setup or weekly maintenance held the lock."
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

case "$phase" in
  upgrade)
    rm -f -- "$completed"
    today="$(date +%F)"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt-get -o APT::Update::Error-Mode=any update
    apt-get -o DPkg::Lock::Timeout=1800 -y -o Dpkg::Options::="--force-confold" --with-new-pkgs upgrade
    apt-get -o DPkg::Lock::Timeout=1800 -y autoremove
    apt-get autoclean
    check_health
    case "$vpn_service" in
      x-ui) xhttp_update_panel "$panel_port" ;;
      xhttp-vps-hysteria) xhttp_update_hysteria ;;
    esac
    printf '%s\n' "$today" > "$completed"
    logger -t xhttp-vps-maintenance 'Weekly package and VPN component updates completed.'
    ;;
  reboot)
    [[ "$(date '+%u %H:%M')" == '7 05:30' && -f /var/run/reboot-required ]] || exit 0
    if [[ ! -f "$completed" || "$(<"$completed")" != "$(date +%F)" ]]; then
      logger -t xhttp-vps-maintenance 'Reboot skipped because weekly maintenance did not complete this Sunday.'
      exit 0
    fi
    if systemctl is-active --quiet apt-daily.service apt-daily-upgrade.service; then
      logger -t xhttp-vps-maintenance 'Reboot skipped while automatic APT work was active.'
      exit 0
    fi
    check_health
    [[ "$(date '+%u %H:%M')" == '7 05:30' ]] || exit 0
    logger -t xhttp-vps-maintenance 'Package updates require a reboot. Rebooting in the weekly window.'
    systemctl --no-block reboot
    ;;
  *) exit 1 ;;
esac
EOF
}

xhttp_install_maintenance() {
  local phase name service temporary
  service="$(xhttp_service_name)" || return 1
  if [[ "$service" == x-ui ]]; then
    [[ "${PANEL_PORT:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$PANEL_PORT > 0 && 10#$PANEL_PORT <= 65535 )) || return 1
  fi
  [[ "$MAINTENANCE_TIMEZONE" =~ ^([A-Za-z0-9_+-]+/)*[A-Za-z0-9_+-]+$ ]] || return 1
  [[ -f "/usr/share/zoneinfo/$MAINTENANCE_TIMEZONE" ]] || return 1
  systemd-analyze calendar "Sun *-*-* 05:00:00 ${MAINTENANCE_TIMEZONE}" >/dev/null || return 1
  systemd-analyze calendar "Sun *-*-* 05:30:00 ${MAINTENANCE_TIMEZONE}" >/dev/null || return 1
  temporary="$(mktemp /usr/local/sbin/.xhttp-vps-maintenance.XXXXXXXX)" || return 1
  if ! xhttp_render_maintenance_script > "$temporary" || ! chmod 700 "$temporary" ||
    ! mv -fT "$temporary" /usr/local/sbin/xhttp-vps-maintenance; then
    rm -f -- "$temporary"
    return 1
  fi
  for phase in upgrade reboot; do
    name=xhttp-vps-maintenance
    if [[ "$phase" == reboot ]]; then name=xhttp-vps-reboot; fi
    cat > "/etc/systemd/system/$name.service" <<EOF || return 1
[Unit]
Description=Run weekly VPN maintenance ($phase)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xhttp-vps-maintenance $phase $service $MAINTENANCE_TIMEZONE "${PANEL_PORT:-}"
Nice=10
IOSchedulingClass=idle
UMask=0027
TimeoutStartSec=2h
EOF
    temporary="$(mktemp "/etc/systemd/system/$name.timer.XXXXXXXX")" || return 1
    xhttp_render_maintenance_timer "$phase" > "$temporary" &&
      chmod 644 "$temporary" && mv -f "$temporary" "/etc/systemd/system/$name.timer" || {
      rm -f -- "$temporary"
      return 1
    }
  done
  systemctl daemon-reload || return 1
  systemctl enable --now xhttp-vps-maintenance.timer xhttp-vps-reboot.timer
}

xhttp_disable_maintenance() {
  local timer
  for timer in xhttp-vps-maintenance.timer xhttp-vps-reboot.timer; do
    if systemctl is-enabled --quiet "$timer" || systemctl is-active --quiet "$timer"; then
      systemctl disable --now "$timer" || return 1
    fi
  done
  rm -f /usr/local/sbin/xhttp-vps-maintenance \
    /etc/systemd/system/xhttp-vps-maintenance.service \
    /etc/systemd/system/xhttp-vps-maintenance.timer \
    /etc/systemd/system/xhttp-vps-reboot.service \
    /etc/systemd/system/xhttp-vps-reboot.timer \
    /run/xhttp-vps-maintenance.ok || return 1
  systemctl daemon-reload
}

xhttp_verify_automatic_updates() {
  local config timer
  config="$(apt-config dump)" || return 1
  grep -Fqx 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$config" || return 1
  if [[ "$MAINTENANCE_MODE" == none ]]; then
    grep -Fqx 'APT::Periodic::Enable "0";' <<<"$config" || return 1
  else
    grep -Fqx 'APT::Periodic::Unattended-Upgrade "1";' <<<"$config" || return 1
  fi
  for timer in xhttp-vps-maintenance.timer xhttp-vps-reboot.timer; do
    if [[ "$MAINTENANCE_MODE" == weekly ]]; then
      systemctl is-enabled --quiet "$timer" && systemctl is-active --quiet "$timer" || return 1
    elif systemctl is-enabled --quiet "$timer" 2>/dev/null || systemctl is-active --quiet "$timer" 2>/dev/null; then
      return 1
    fi
  done
}

xhttp_configure_automatic_updates() {
  case "${MAINTENANCE_MODE:-}" in
    security|weekly)
      cat > /etc/apt/apt.conf.d/52xhttp-vps-auto-upgrades <<'EOF' || return 1
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
      cat > /etc/apt/apt.conf.d/53xhttp-vps-unattended-upgrades <<'EOF' || return 1
// Managed by VLESS VPS Setup. Official Ubuntu security updates only.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF
      systemctl enable --now apt-daily.timer apt-daily-upgrade.timer || return 1
      if [[ "$MAINTENANCE_MODE" == weekly ]]; then
        xhttp_install_maintenance
      else
        xhttp_disable_maintenance
      fi
      ;;
    none)
      cat > /etc/apt/apt.conf.d/52xhttp-vps-auto-upgrades <<'EOF' || return 1
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
      cat > /etc/apt/apt.conf.d/53xhttp-vps-unattended-upgrades <<'EOF' || return 1
// Managed by VLESS VPS Setup. Automatic package installation is disabled.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF
      xhttp_disable_maintenance
      ;;
    *) return 1 ;;
  esac
}

xhttp_download_verified() {
  local url="$1" expected="$2" output="$3" actual
  curl -q -fL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$output" || {
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
  release="$(curl -q -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 10 --max-time 30 \
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
    systemctl start x-ui && xhttp_wait_for_vpn_service x-ui "$port"
  }
  cleanup_panel_update() {
    local status="$?"
    if [[ "$status" != 0 && "$stopped" == 1 ]]; then
      if ! restore_panel; then
        printf '3x-ui rollback failed. Retained recovery files at %s\n' "$stage" >&2
        return 1
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
  systemctl start x-ui
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
        ! systemctl restart "$service" ||
        ! xhttp_wait_for_vpn_service "$service"; then
        printf 'Hysteria 2 rollback failed. Retained recovery files at %s\n' "$stage" >&2
        return 1
      fi
      printf '%s\n' 'Hysteria 2 update failed. The previous service was restored.' >&2
    fi
    rm -rf -- "$stage"
  }
  trap cleanup_hysteria_update EXIT
  trap 'exit 1' INT TERM HUP
  xhttp_latest_release_asset apernet/hysteria "hysteria-linux-$arch" "$stage/hysteria" "$digest"
  [[ -f "$stage/hysteria" ]] || exit 0
  chmod 755 "$stage/hysteria"
  "$stage/hysteria" version >/dev/null
  cp -aT "$binary" "$stage/previous"
  deployed=1
  mv -fT "$stage/hysteria" "$binary"
  systemctl restart "$service"
  xhttp_wait_for_vpn_service "$service"
  printf '%s\n' 'Hysteria 2 release applied and the UDP listener is ready.'
)

xhttp_install_cert_renewal() {
  local reload='systemctl reload nginx'
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
ExecStart=/usr/bin/certbot renew --quiet --config-dir /etc/xhttp-vps-acme --work-dir /var/lib/xhttp-vps-acme --logs-dir /var/log/xhttp-vps-acme --deploy-hook "$reload"
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
local path
for path in "$SUB_PATH" "${SUB_JSON_PATH:-}" "${SUB_CLASH_PATH:-}"; do
[[ -n "$path" ]] || continue
cat <<EOF
    location ^~ /${path}/ {
        proxy_pass https://127.0.0.1:${SUB_PORT};
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_verify_depth 3;
        proxy_ssl_server_name on;
        proxy_ssl_name ${DOMAIN};
        proxy_set_header Host ${DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
EOF
done
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
      -servername "$DOMAIN" -verify_hostname "$DOMAIN" -verify_return_error \
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
    admin)
      [[ "${SSH_HARDENING:-0}" == 1 ]] || return 1
      [[ "${ADMIN_USER:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || return 1
      xhttp_validate_authorized_keys_b64 "${ADMIN_KEYS_B64:-}" || return 1
      ;;
    root-key)
      [[ "${SSH_HARDENING:-0}" == 1 && "${ADMIN_USER:-}" == root ]] || return 1
      xhttp_validate_authorized_keys_b64 "${ADMIN_KEYS_B64:-}" || return 1
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
  case "${SUB_ENCRYPT_LINKS:-}" in true|false|'') ;; *) return 1 ;; esac
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
