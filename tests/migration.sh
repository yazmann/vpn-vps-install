#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../xhttp-vps-migrate.sh
source ./xhttp-vps-migrate.sh

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
db="$test_dir/source backup.db"
sqlite_binary="$(command -v sqlite3)"
"$sqlite_binary" "$db" <<'SQL'
CREATE TABLE inbounds (id INTEGER PRIMARY KEY, protocol TEXT, port INTEGER, settings TEXT);
CREATE TABLE client_traffics (email TEXT PRIMARY KEY, enable INTEGER, expiry_time INTEGER, total INTEGER, up INTEGER, down INTEGER, reset_count INTEGER);
INSERT INTO inbounds VALUES (4, 'vless', 443, '{"clients":[{"id":"d58f9000-aff9-4f17-8d34-6defafa12000","email":"alice","subId":"keep-this","enable":true,"tgId":"92","limitIp":2,"resetDay":5},{"id":"0eddb904-56ac-41c0-8da0-85b6add79cb3","email":"bob","enable":false}]}');
INSERT INTO inbounds VALUES (9, 'trojan', 8443, '{"clients":[{"email":"other"}]}');
INSERT INTO client_traffics VALUES ('alice', 0, 1900000000000, 10000000, 105, 240, 3);
SQL
xhttp_migration_snapshot "$db" '' 'xtls-rprx-vision' "$test_dir/legacy.json"
jq -e '
  length==2 and
  (.[0] | .client.email=="alice" and .client.subId=="keep-this" and .client.flow=="xtls-rprx-vision" and
    .client.enable==false and .client.limitIp==2 and .client.tgId==92 and .client.resetDay==5 and
    .client.totalGB==10000000 and .client.expiryTime==1900000000000 and
    .traffic.up==105 and .traffic.down==240 and .traffic.resetCount==3) and
  (.[1] | .client.email=="bob" and .client.enable==false)
' "$test_dir/legacy.json" >/dev/null
if xhttp_migration_snapshot "$db" 9 '' "$test_dir/wrong.json" 2>/dev/null; then exit 1; fi
"$sqlite_binary" "$db" <<'SQL'
CREATE TABLE clients (id INTEGER PRIMARY KEY, uuid TEXT, email TEXT, sub_id TEXT, enable INTEGER, total_gb INTEGER, expiry_time INTEGER, limit_ip INTEGER, limit_hwid INTEGER);
CREATE TABLE client_inbounds (client_id INTEGER, inbound_id INTEGER);
INSERT INTO inbounds VALUES (11, 'vless', 9443, '{"clients":[]}');
INSERT INTO clients VALUES (3, '7d5c7c7e-97bf-4f10-b4ac-c894caff2f1b', 'charlie', 'modern-subid', 1, 6000, -3000, 2, 3);
INSERT INTO clients VALUES (5, '3a933def-f592-4756-8d82-a57114ffe855', 'excluded', 'unrelated', 1, 0, 0, 0, 0);
INSERT INTO client_inbounds VALUES (3, 11), (5, 9);
SQL
if xhttp_migration_snapshot "$db" '' '' "$test_dir/ambiguous.json" 2>/dev/null; then
  exit 1
else
  [[ "$?" == 2 ]]
fi
xhttp_migration_snapshot "$db" 11 '' "$test_dir/modern.json"
jq -e 'length==1 and (.[0].client | .email=="charlie" and .subId=="modern-subid" and
  .flow=="" and .enable==true and .limitHwid==3 and .totalGB==6000 and .expiryTime==-3000)' "$test_dir/modern.json" >/dev/null

MANAGED_BACKUP="$test_dir/journal"
mkdir "$MANAGED_BACKUP"
cp "$test_dir/modern.json" "$MANAGED_BACKUP/migration.json"
export INBOUND_TAG=in-443-xhttp-reality
systemctl() { [[ "$2" == x-ui ]]; }
sqlite3() {
  local op="${*: -1}" filename
  case "$op" in
    ".backup '"*) filename="${op#*.backup \'}"; : > "${filename%\'}" ;;
    ".restore '"*) printf '%s\n' restored >> "$test_dir/events" ;;
    *) return 1 ;;
  esac
}
xhttp_panel_api() {
  case "$1" in
    /panel/api/inbounds/list)
      printf '%s\n' '{"obj":[{"id":53,"tag":"in-443-xhttp-reality","protocol":"vless"}]}'
      ;;
    /panel/api/clients/import)
      jq -e '.data|fromjson|.[0]|.inboundIds==[53] and .client.email=="charlie"' >/dev/null || return 1
      printf '%s\n' imported >> "$test_dir/events"
      if [[ "${REJECT_IMPORT:-0}" == 1 ]]; then printf '%s\n' '{"success":false}'; return 1; fi
      printf '%s\n' '{"success":true,"obj":{"created":1,"skipped":[]}}'
      ;;
    *) return 1 ;;
  esac
}
if REJECT_IMPORT=1 xhttp_import_migrated_clients 2>/dev/null; then exit 1; fi
[[ ! -e "$MANAGED_BACKUP/migration.done" ]]
grep -Fxq restored "$test_dir/events"
xhttp_import_migrated_clients
xhttp_import_migrated_clients
[[ "$(grep -Fxc imported "$test_dir/events")" == 2 ]]
printf 'SQLite migration tests passed.\n'
