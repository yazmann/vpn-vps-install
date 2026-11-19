#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../xhttp-vps-common.sh
source ./xhttp-vps-common.sh
# shellcheck source=../xhttp-vps-udp.sh
source ./xhttp-vps-udp.sh

export DOMAIN=vpn.example.com CERT_DIR=/root/cert/vpn.example.com PUBLIC_IP=192.0.2.3
export HY_PASSWORD=000102030405060708090a0b0c0d0e0f00112233445566778899aabbccddeeff
export RESULT_FILE=/root/xhttp-vps-result-test.txt ACME_CLIENT=certbot
export XHTTP_NGINX_VERSION_OVERRIDE=1.24.0
TRANSPORT=hysteria2
[[ "$(xhttp_service_name)" == xhttp-vps-hysteria ]]
nginx="$(xhttp_render_nginx)"
grep -Fq 'listen 0.0.0.0:443 ssl http2;' <<<"$nginx"
grep -Fq 'ssl_reject_handshake on;' <<<"$nginx"
grep -Fq 'add_header Alt-Svc' <<<"$nginx"
if grep -Fq proxy_pass <<<"$nginx"; then exit 1; fi
jammy="$(XHTTP_NGINX_VERSION_OVERRIDE=1.18.0 xhttp_render_nginx)"
grep -Fq 'listen 0.0.0.0:443 ssl http2 default_server;' <<<"$jammy"
grep -Fq 'ssl_certificate /root/cert/vpn.example.com/default.pem;' <<<"$jammy"
if grep -Fq ssl_reject_handshake <<<"$jammy"; then exit 1; fi
paths="$(xhttp_managed_paths)"
grep -Fxq /etc/xhttp-vps-hysteria.yaml <<<"$paths"
grep -Fxq /etc/xhttp-vps-acme <<<"$paths"
if grep -Fxq /etc/x-ui <<<"$paths"; then exit 1; fi
hysteria="$(xhttp_render_hysteria_config)"
grep -Fq 'listen: 0.0.0.0:443' <<<"$hysteria"
grep -Fq 'sniGuard: strict' <<<"$hysteria"
grep -Fq 'reject(169.254.0.0/16)' <<<"$hysteria"
grep -Fq 'reject(192.0.2.3/32)' <<<"$hysteria"
grep -Fq 'dir: /var/www/3xui-cover' <<<"$hysteria"

export TRANSPORT=amneziawg
[[ "$(xhttp_service_name)" == awg-quick@awg-vps ]]
if xhttp_render_nginx | grep -Fq 'Alt-Svc'; then exit 1; fi
awg() {
  case "$1" in
    genkey) printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' ;;
    showconf) printf '%s\n' "${AWG_RUNNING_CONFIG:-}" ;;
    *) return 1 ;;
  esac
}
profile="$(xhttp_amnezia_params <<'UPSTREAM'
namespace awg
{
    constexpr char defaultJunkPacketCount[] = "7";
    constexpr char defaultJunkPacketMinSize[] = "16";
    constexpr char defaultJunkPacketMaxSize[] = "80";
    constexpr char defaultInitPacketMagicHeader[] = "1";
    constexpr char defaultResponsePacketMagicHeader[] = "2";
    constexpr char defaultUnderloadPacketMagicHeader[] = "3";
    constexpr char defaultTransportPacketMagicHeader[] = "4";
    constexpr char defaultPadding[] = "15";
    constexpr char defaultContentPaddingAddition[] = "12-80";
    constexpr char defaultRekeyAfterTime[] = "100-120";
    constexpr char defaultRekeyTimeout[] = "3-7";
    constexpr char defaultRejectAfterTime[] = "150-180";
    constexpr char defaultKeepaliveTimeout[] = "5-15";
    constexpr char defaultMaxHandshakeAttempts[] = "15-20";
    constexpr char defaultPersistentKeepAlive[] = "15-35";
    constexpr char defaultRandomTrailers[] = "on";
    constexpr char defaultDisableCookies[] = "on";
}
UPSTREAM
)"
grep -Fxq 'Jc = 7' <<<"$profile"
grep -Fxq 'S1 = 15' <<<"$profile"
grep -Fxq 'ContentPaddingAddition = 12-80' <<<"$profile"
grep -Fxq 'H1 = 1' <<<"$profile"
grep -Fxq 'H4 = 4' <<<"$profile"
awk -F ' = ' '$1~/^S[1-4]$/ {count++; if ($2<12) exit 1} END {if (count!=4) exit 1}' <<<"$profile"
AWG_RUNNING_CONFIG="$profile" xhttp_verify_amnezia_profile
if AWG_RUNNING_CONFIG=$'S1 = 77\nS2 = 98' xhttp_verify_amnezia_profile; then exit 1; fi
if xhttp_amnezia_params <<< 'namespace awg' > /dev/null; then exit 1; fi

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
release_digest="$(printf %s 'release payload' | sha256sum)"
release_digest="${release_digest%% *}"
curl() {
  case "$*" in
    *api.github.com/repos/example/project/releases/latest*)
      printf '{"draft":false,"prerelease":%s,"assets":[{"name":"asset","state":"uploaded","digest":"sha256:%s","browser_download_url":"%s"}]}' \
        "${PRERELEASE:-false}" "$release_digest" "${ASSET_URL:-https://github.com/example/project/releases/download/current/asset}"
      ;;
    *https://github.com/example/project/releases/download/current/asset*)
      [[ "${*: -2:1}" == '-o' ]]
      printf %s "${PAYLOAD:-release payload}" > "${*: -1}"
      ;;
    *api.github.com/repos/hydraponique/roscomvpn-routing/contents/HAPP/DEFAULT.DEEPLINK*)
      printf '{"type":"file","encoding":"base64","content":"dGVzdA==","sha":"%s"}' "${BLOB_SHA:-30d74d258442c7c65512eafab474568dd706c430}"
      ;;
    *) return 1 ;;
  esac
}
xhttp_latest_release_asset example/project asset "$test_dir/asset"
[[ "$(cat "$test_dir/asset")" == 'release payload' ]]
[[ "$(cat "$test_dir/asset.sha256")" == "$release_digest" ]]
PAYLOAD=corrupt xhttp_latest_release_asset example/project asset "$test_dir/unchanged" "$release_digest"
[[ ! -e "$test_dir/unchanged" ]]
if PAYLOAD=corrupt xhttp_latest_release_asset example/project asset "$test_dir/asset" 2>/dev/null; then exit 1; fi
[[ ! -e "$test_dir/asset" ]]
if PRERELEASE=true xhttp_latest_release_asset example/project asset "$test_dir/asset"; then exit 1; fi
if ASSET_URL=https://example.com/asset xhttp_latest_release_asset example/project asset "$test_dir/asset"; then exit 1; fi
ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
[[ "$(xhttp_fetch_routing "$ref" HAPP/DEFAULT.DEEPLINK)" == test ]]
if BLOB_SHA="$ref" xhttp_fetch_routing "$ref" HAPP/DEFAULT.DEEPLINK; then exit 1; fi

subscription_url=https://vpn.example.com/sub/test-subscription
xhttp_memory_api() {
  case "$1" in
    /panel/api/clients/get/test%40example.com) printf '%s\n' '{"obj":{"client":{"id":123}}}' ;;
    /panel/api/clients/happLink/123) printf '%s\n' '{"obj":{"encryptedLink":"happ://crypt5/test-envelope"}}' ;;
    *) return 1 ;;
  esac
}
plain="$(SUB_ENCRYPT_LINKS=false xhttp_subscription_links "$subscription_url" test@example.com)"
grep -Fxq "HAPP / INCY subscription: $subscription_url" <<<"$plain"
encrypted="$(SUB_ENCRYPT_LINKS=true xhttp_subscription_links "$subscription_url" test@example.com)"
grep -Fxq 'HAPP subscription: happ://crypt5/test-envelope' <<<"$encrypted"
if grep -Fq "$subscription_url" <<<"$encrypted"; then exit 1; fi
awk '/^INCY subscription: /{print $3}' <<<"$encrypted" | node -e '
  const {createDecipheriv, createHash} = require("crypto");
  const link = require("fs").readFileSync(0, "utf8").trim();
  if (!link.startsWith("incy://crypt1/")) process.exit(1);
  const data = Buffer.from(link.slice(14).replace(/-/g, "+").replace(/_/g, "/"), "base64");
  const key = Buffer.from("f6d40ea0c8a8899d7c682d09ba0d4165dfe2b3dd45e6bb3e25cb233cf00c2462", "hex");
  if (createHash("sha256").update(key).digest("hex") !== "b6bf708471cc90043232967660aade86a50b4e57929db2e53c5fa34db624c08c")
    process.exit(1);
  const decipher = createDecipheriv("aes-256-gcm", key, data.slice(0, 12));
  decipher.setAuthTag(data.slice(-16));
  const body = JSON.parse(Buffer.concat([decipher.update(data.slice(12, -16)), decipher.final()]).toString());
  if (body.url !== process.argv[1] || body.v !== 1) process.exit(1);
' "$subscription_url"
if SUB_ENCRYPT_LINKS=true xhttp_subscription_links "$subscription_url" missing@example.com; then exit 1; fi

# A real SQLite snapshot and OpenPGP round trip using fixture files only.
fixture="$test_dir/backup-fixture"
mkdir -p "$fixture/etc/x-ui" "$fixture/etc/nginx/sites-available" "$fixture/var/www/3xui-cover" "$test_dir/readback"
printf 'domain test\n' > "$fixture/installer.env"
printf 'test config\n' > "$fixture/etc/nginx/sites-available/3xui-self-steal.conf"
printf 'test site\n' > "$fixture/var/www/3xui-cover/index.html"
sqlite3 "$fixture/etc/x-ui/x-ui.db" 'CREATE TABLE users(name TEXT); INSERT INTO users VALUES ("client");'
RECOVERY_PASSPHRASE='fixture archive passphrase'
backup="$(TRANSPORT=xhttp DOMAIN=example.com xhttp_write_recovery_backup "$fixture/installer.env" "$test_dir" "$fixture")"
[[ "$(stat -c '%a' "$backup")" == 600 ]]
mkdir -m 700 "$test_dir/backup-reader"
gpg --homedir "$test_dir/backup-reader" --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
  --decrypt "$backup" 3<<<"$RECOVERY_PASSPHRASE" | tar -xzf - -C "$test_dir/readback"
cmp "$fixture/installer.env" "$test_dir/readback/installer.env"
[[ "$(sqlite3 "$test_dir/readback/etc/x-ui/x-ui.db" 'SELECT name FROM users;')" == client ]]
printf 'Transport and download tests passed.\n'
