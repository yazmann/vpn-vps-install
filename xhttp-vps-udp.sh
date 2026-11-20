#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Independent UDP transports. Sourcing this file performs no installation.

xhttp_udp_port_busy() { ss -H -lun "sport = :$1" | grep -q .; }

xhttp_udp_random_port() {
  local port
  for _ in {1..100}; do
    port="$(random_port)" || return 1
    if ! xhttp_udp_port_busy "$port"; then printf '%s\n' "$port"; return 0; fi
  done
  return 1
}

xhttp_install_amnezia_packages() (
  set -Eeuo pipefail
  local suite stage fingerprint=75C9DD72C799870E310542E24166F2C257290828
  # shellcheck disable=SC1091
  source /etc/os-release
  suite="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ "$suite" =~ ^[a-z]+$ ]]
  stage="$(mktemp -d)"
  trap 'rm -rf -- "$stage"' EXIT
  export GNUPGHOME="$stage"
  curl -q -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 30 \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$fingerprint" -o "$stage/ppa.asc"
  gpg --batch --show-keys --with-colons "$stage/ppa.asc" | awk -F: -v expected="$fingerprint" '
    $1=="pub" {public_keys++; primary=1; next}
    $1=="fpr" && primary {matched=($10==expected); primary=0}
    END {exit !(public_keys==1 && matched)}
  '
  gpg --batch --dearmor --output "$stage/ppa.gpg" "$stage/ppa.asc"
  install -d -m 755 /etc/apt/keyrings
  install -m 644 "$stage/ppa.gpg" /etc/apt/keyrings/xhttp-vps-amnezia.gpg
  cat > /etc/apt/preferences.d/xhttp-vps-amnezia <<'EOF'
Package: amneziawg amneziawg-dkms amneziawg-tools
Pin: release o=LP-PPA-amnezia
Pin-Priority: 500

Package: *
Pin: release o=LP-PPA-amnezia
Pin-Priority: -1
EOF
  cat > /etc/apt/sources.list.d/xhttp-vps-amnezia.sources <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: $suite
Components: main
Signed-By: /etc/apt/keyrings/xhttp-vps-amnezia.gpg
EOF
  xhttp_apt_get -o APT::Update::Error-Mode=any update
  xhttp_apt_apply install -y --no-install-recommends \
    "linux-headers-$(uname -r)" amneziawg
)

xhttp_amnezia_current_defaults() {
  local repo=amnezia-vpn/amnezia-client response tag revision
  response="$(curl -q -fsS --proto '=https' --retry 2 --connect-timeout 5 --max-time 20 \
    "https://api.github.com/repos/$repo/releases/latest")" || return 1
  tag="$(jq -er 'select(.draft==false and .prerelease==false) | .tag_name | select(test("^v?[0-9]+(\\.[0-9]+)+$"))' <<<"$response")" || return 1
  response="$(curl -q -fsS --proto '=https' --retry 2 --connect-timeout 5 --max-time 20 \
    "https://api.github.com/repos/$repo/commits/$tag")" || return 1
  revision="$(jq -er '.sha' <<<"$response")" || return 1
  xhttp_fetch_repo_text "$repo" "$revision" client/core/utils/constants/protocolConstants.h
}

xhttp_amnezia_params() {
  local header_key field index value defaults
  local -A cfg
  defaults="$(awk '
    /^[[:space:]]*namespace awg[[:space:]]*$/ {in_awg=1; next}
    in_awg && /^[[:space:]]*}[[:space:]]*$/ {exit}
    in_awg && /^[[:space:]]*constexpr char (default|awgV)[A-Za-z0-9]+\[\] = "[^"]*";/ {
      key=$3; sub(/\[\]$/, "", key)
      split($0, parts, "\"")
      print key "\t" parts[2]
    }
  ')" || return 1
  while IFS=$'\t' read -r field value; do
    [[ -z "$field" ]] || cfg["$field"]="$value"
  done <<<"$defaults"
  [[ "${cfg[defaultPadding]:-}" =~ ^(1[2-9]|[2-9][0-9]|1[0-4][0-9]|150)$ ]] || return 1
  header_key="$(awg genkey)" || return 1
  for field in defaultJunkPacketCount defaultJunkPacketMinSize defaultJunkPacketMaxSize \
    defaultInitPacketMagicHeader defaultResponsePacketMagicHeader defaultUnderloadPacketMagicHeader defaultTransportPacketMagicHeader \
    defaultContentPaddingAddition defaultRekeyAfterTime defaultRekeyTimeout defaultRejectAfterTime defaultKeepaliveTimeout \
    defaultMaxHandshakeAttempts defaultPersistentKeepAlive; do
    [[ "${cfg[$field]:-}" =~ ^[0-9]{1,10}(-[0-9]{1,10})?$ ]] || return 1
  done
  for field in defaultRandomTrailers defaultDisableCookies; do
    [[ "${cfg[$field]:-}" == on || "${cfg[$field]:-}" == off ]] || return 1
  done

  printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "${cfg[defaultJunkPacketCount]}" "${cfg[defaultJunkPacketMinSize]}" "${cfg[defaultJunkPacketMaxSize]}"
  for index in {1..4}; do printf 'S%d = %s\n' "$index" "${cfg[defaultPadding]}"; done
  printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "${cfg[defaultInitPacketMagicHeader]}" \
    "${cfg[defaultResponsePacketMagicHeader]}" "${cfg[defaultUnderloadPacketMagicHeader]}" "${cfg[defaultTransportPacketMagicHeader]}"
  for index in {1..5}; do
    value="${cfg[defaultSpecialJunk$index]:-}"
    if [[ -n "$value" ]]; then
      [[ "$value" =~ ^[[:alnum:][:blank:]\<\>.:,+-]+$ ]] || return 1
      printf 'I%d = %s\n' "$index" "$value"
    fi
  done
  printf 'HeaderProtectionKey = %s\n' "$header_key"
  for field in ContentPaddingAddition RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts RandomTrailers DisableCookies; do
    printf '%s = %s\n' "$field" "${cfg[default$field]}"
  done
  printf 'PersistentKeepalive = %s\n' "${cfg[defaultPersistentKeepAlive]}"
}

xhttp_verify_amnezia_profile() {
  awg showconf awg-vps | awk -F '[[:blank:]]+=[[:blank:]]+' '
    $1=="HeaderProtectionKey" && length($2)==44 {header=1}
    $1=="ContentPaddingAddition" && $2 ~ /^[1-9][0-9]*(-[1-9][0-9]*)?$/ {padding=1}
    $1=="RandomTrailers" && ($2=="on" || $2=="off") {trailers=1}
    END {exit !(header && padding && trailers)}
  '
}

xhttp_install_amnezia() (
  set -Eeuo pipefail
  umask 077
  local dir=/etc/xhttp-vps-awg stage server_public client_public iface subnet marker
  local -a keys
  install -d -m 700 "$dir" /etc/amnezia/amneziawg
  if [[ ! -f "$dir/packages-ready" ]] || ! command -v awg-quick >/dev/null ||
     ! command -v awg >/dev/null || ! modprobe amneziawg 2>/dev/null; then
    xhttp_install_amnezia_packages
    modprobe amneziawg
    touch "$dir/packages-ready"
  fi
  if ! ip link show dev awg-vps >/dev/null 2>&1; then
    ip -4 -j route get 10.66.66.2 | jq -e '.[0] | has("gateway")' >/dev/null || {
      printf '%s\n' 'AmneziaWG requires a free 10.66.66.0/24 and an IPv4 Internet route.' >&2
      exit 1
    }
  fi
  iface="$(ip -4 -j route get 1.1.1.1 | jq -er '.[0].dev')"
  [[ "$iface" =~ ^[a-zA-Z0-9_.-]{1,15}$ && "$iface" != lo && "$iface" != awg-vps ]]
  stage="$(mktemp -d "$dir/.stage.XXXXXXXX")"
  trap 'rm -rf -- "$stage"' EXIT
  if [[ ! -s "$dir/keys" ]]; then
    { awg genkey && awg genkey && awg genpsk; } > "$stage/keys"
    mv -T "$stage/keys" "$dir/keys"
  fi
  if [[ ! -s "$dir/protocol.conf" ]]; then
    xhttp_amnezia_current_defaults | xhttp_amnezia_params > "$stage/protocol.conf" || {
      printf '%s\n' 'Could not load a supported profile from the current stable AmneziaVPN release.' >&2
      exit 1
    }
    mv -T "$stage/protocol.conf" "$dir/protocol.conf"
  fi
  mapfile -t keys < "$dir/keys"
  [[ "${#keys[@]}" == 3 ]]
  server_public="$(awg pubkey <<<"${keys[0]}")"
  client_public="$(awg pubkey <<<"${keys[1]}")"
  cat > "$stage/server.conf" <<EOF
[Interface]
Address = 10.66.66.1/24
ListenPort = $UDP_PORT
PrivateKey = ${keys[0]}
MTU = 1280
PostUp = /usr/local/sbin/xhttp-vps-awg-firewall up
PreDown = /usr/local/sbin/xhttp-vps-awg-firewall down
$(grep -v '^PersistentKeepalive ' "$dir/protocol.conf")

[Peer]
PublicKey = $client_public
PresharedKey = ${keys[2]}
AllowedIPs = 10.66.66.2/32
EOF
  cat > "$stage/client.conf" <<EOF
[Interface]
Address = 10.66.66.2/32, fd42:66:66::2/128
PrivateKey = ${keys[1]}
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280
$(grep -v '^PersistentKeepalive ' "$dir/protocol.conf")

[Peer]
PublicKey = $server_public
PresharedKey = ${keys[2]}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $DOMAIN:$UDP_PORT
$(grep '^PersistentKeepalive ' "$dir/protocol.conf")
EOF
  if systemctl is-active --quiet awg-quick@awg-vps; then systemctl stop awg-quick@awg-vps; fi
  ! xhttp_udp_port_busy "$UDP_PORT"
  if [[ ! -s /etc/amnezia/amneziawg/awg-vps.conf ]]; then
    install -m 600 "$stage/server.conf" /etc/amnezia/amneziawg/awg-vps.conf
  fi
  mv -T "$stage/client.conf" "$dir/client.conf"
  cat > "$stage/firewall" <<'EOF'
#!/bin/bash
set -euo pipefail
rule=(-s 10.66.66.2/32 -m comment --comment xhttp-vps-awg -j MASQUERADE)
case "$1" in
  up)
    iptables -w -t nat -C POSTROUTING "${rule[@]}" 2>/dev/null ||
      iptables -w -t nat -A POSTROUTING "${rule[@]}"
    ;;
  down)
    if iptables -w -t nat -C POSTROUTING "${rule[@]}" 2>/dev/null; then
      iptables -w -t nat -D POSTROUTING "${rule[@]}"
    fi
    ;;
  *) exit 1 ;;
esac
EOF
  install -m 700 "$stage/firewall" /usr/local/sbin/xhttp-vps-awg-firewall
  printf '%s\n' 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-xhttp-vps-awg.conf
  sysctl -p /etc/sysctl.d/99-xhttp-vps-awg.conf >/dev/null
  marker="xhttp-vps:${SAFE_INSTANCE}"
  xhttp_delete_firewall_rules "$marker AWG"
  ufw insert 1 deny in on awg-vps comment "$marker AWG local"
  for subnet in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
    172.16.0.0/12 192.168.0.0/16 198.18.0.0/15 224.0.0.0/3; do
    ufw route insert 1 deny in on awg-vps to "$subnet" comment "$marker AWG private"
  done
  ufw route allow in on awg-vps out on "$iface" from 10.66.66.2/32 comment "$marker AWG forward"
  if ! systemctl start awg-quick@awg-vps; then
    printf '%s\n' 'AmneziaWG could not start. Check DKMS, kernel headers and support for the 3.1 profile.' >&2
    exit 1
  fi
  if ! xhttp_verify_amnezia_profile; then
    systemctl disable --now awg-quick@awg-vps
    printf '%s\n' 'AmneziaWG 3.1 or newer is required. The active kernel module did not apply the 3.1 profile.' >&2
    exit 1
  fi
  [[ "$(awg show awg-vps listen-port)" == "$UDP_PORT" ]]
  awg show awg-vps peers | grep -Fxq -- "$client_public"
  iptables -w -t nat -C POSTROUTING -s 10.66.66.2/32 -m comment --comment xhttp-vps-awg -j MASQUERADE
  systemctl enable awg-quick@awg-vps
)

xhttp_render_hysteria_config() {
  cat <<EOF
listen: 0.0.0.0:443
tls:
  cert: /run/credentials/xhttp-vps-hysteria.service/fullchain.pem
  key: /run/credentials/xhttp-vps-hysteria.service/privkey.pem
  sniGuard: strict
auth:
  type: password
  password: "$HY_PASSWORD"
acl:
  inline:
    - reject(0.0.0.0/8)
    - reject(10.0.0.0/8)
    - reject(100.64.0.0/10)
    - reject(127.0.0.0/8)
    - reject(169.254.0.0/16)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(198.18.0.0/15)
    - reject(224.0.0.0/3)
    - reject($PUBLIC_IP/32)
# Restrict egress without rejecting dual-stack domains in the ACL.
outbounds:
  - name: direct-ipv4
    type: direct
    direct:
      mode: "4"
masquerade:
  type: file
  file:
    dir: /var/www/3xui-cover
EOF
}

xhttp_install_hysteria() (
  set -Eeuo pipefail
  umask 077
  local arch stage pid binary=/usr/local/bin/xhttp-vps-hysteria
  arch="$(xhttp_release_arch)"
  if [[ "$arch" == armv7 ]]; then arch=arm; fi
  stage="$(mktemp -d)"
  trap 'rm -rf -- "$stage"' EXIT
  if [[ ! -x "$binary" ]]; then
    xhttp_latest_release_asset HyNetworks/hysteria "hysteria-linux-$arch" "$stage/hysteria"
    install -m 755 "$stage/hysteria" "$binary"
  fi
  xhttp_render_hysteria_config > "$stage/config"
  install -m 600 "$stage/config" /etc/xhttp-vps-hysteria.yaml
  cat > "$stage/service" <<EOF
[Unit]
Description=Hysteria 2 VPN server
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=exec
DynamicUser=yes
UMask=0077
LoadCredential=config.yaml:/etc/xhttp-vps-hysteria.yaml
LoadCredential=privkey.pem:$CERT_DIR/privkey.pem
LoadCredential=fullchain.pem:$CERT_DIR/fullchain.pem
ExecStart=$binary server -c %d/config.yaml
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
  install -m 644 "$stage/service" /etc/systemd/system/xhttp-vps-hysteria.service
  systemctl daemon-reload
  if ! systemctl is-active --quiet xhttp-vps-hysteria; then ! xhttp_udp_port_busy 443; fi
  systemctl enable xhttp-vps-hysteria
  xhttp_restart_vpn_service xhttp-vps-hysteria
  for _ in {1..20}; do
    pid="$(systemctl show --property=MainPID --value xhttp-vps-hysteria)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ss -H -lunp 'sport = :443' | grep -Fq "pid=$pid,"; then
      printf 'hysteria2://%s@%s:443/\n' "$HY_PASSWORD" "$DOMAIN" > "$stage/uri"
      install -m 600 "$stage/uri" /root/xhttp-vps-hysteria.uri
      exit 0
    fi
    sleep 0.5
  done
  journalctl -u xhttp-vps-hysteria -n 25 --no-pager >&2
  return 1
)

xhttp_udp_finish() {
  local profile service
  service="$(xhttp_service_name)"
  xhttp_delete_firewall_rules "xhttp-vps:${SAFE_INSTANCE} UDP"
  case "$TRANSPORT" in
    amneziawg) xhttp_install_amnezia; profile=/etc/xhttp-vps-awg/client.conf ;;
    hysteria2) xhttp_install_hysteria; profile=/root/xhttp-vps-hysteria.uri ;;
  esac
  systemctl is-active --quiet "$service"
  curl -q -fsS --cacert "$(xhttp_tls_ca_file)" --noproxy '*' --resolve "$DOMAIN:443:127.0.0.1" --max-time 10 \
    "https://$DOMAIN/" -o /dev/null
  xhttp_probe_foreign_sni
  xhttp_probe_no_sni
  xhttp_probe_h2_alpn
  xhttp_udp_port_busy "$UDP_PORT"
  ufw allow "$UDP_PORT"/udp comment "xhttp-vps:${SAFE_INSTANCE} UDP"
  local report
  report="$(mktemp "${RESULT_FILE}.XXXXXXXX")"
  {
    printf 'VPN NAME: %s\nTRANSPORT: %s\nENDPOINT: %s:%s/UDP\nCLIENT PROFILE: %s\n' \
      "$VPN_NAME" "$(xhttp_transport_label "$TRANSPORT")" "$DOMAIN" "$UDP_PORT" "$profile"
    printf 'TLS: %s\n' "$(xhttp_tls_label)"
    xhttp_print_ssh_connection
    if [[ "${DISABLE_PING:-0}" == 1 ]]; then printf 'IPV4 PING REPLIES: Disabled\n'; fi
  } > "$report"
  mv -T "$report" "$RESULT_FILE"
  cat "$RESULT_FILE"
}
