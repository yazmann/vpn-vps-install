#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Read VLESS clients from a SQLite snapshot and import via the panel API.

xhttp_migration_snapshot() (
  set -Eeuo pipefail
  umask 077
  local db="$1" requested_id="$2" flow="$3" output="$4"
  local list inbound_id normalized clients traffic tmp
  local -a read_db=(sqlite3 -batch -bail -readonly -noheader)
  local schema_guard='PRAGMA trusted_schema=OFF;'
  [[ "$db" == /* && -f "$db" && -r "$db" ]] || exit 1
  [[ -z "$requested_id" || "$requested_id" =~ ^[1-9][0-9]{0,9}$ ]] || exit 1
  [[ "$("${read_db[@]}" "$db" "$schema_guard PRAGMA quick_check(1);" | tr -d '\r')" == ok ]] || exit 1
  list="$("${read_db[@]}" -json "$db" "$schema_guard SELECT id, port FROM inbounds WHERE protocol = 'vless' ORDER BY id;")" || exit 1
  if ! inbound_id="$(jq -er --arg id "$requested_id" '
      map(select($id=="" or (.id|tostring)==$id)) | select(length==1) | .[0].id
    ' <<<"${list:-[]}")"; then
    printf '%s\n' 'Specify the ID of one VLESS inbound. Available IDs and ports:' >&2
    jq -r '.[] | "  \(.id) (TCP/\(.port))"' <<<"${list:-[]}" >&2
    exit 2
  fi
  [[ "$inbound_id" =~ ^[1-9][0-9]{0,9}$ ]] || exit 1
  normalized="$("${read_db[@]}" "$db" "$schema_guard SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN ('clients','client_inbounds');" | tr -d '\r')" || exit 1
  if [[ "$normalized" == 2 ]]; then
    clients="$("${read_db[@]}" -json "$db" "$schema_guard SELECT clients.* FROM clients JOIN client_inbounds ON clients.id = client_inbounds.client_id WHERE client_inbounds.inbound_id = $inbound_id ORDER BY clients.id;")" || exit 1
  else
    clients="$("${read_db[@]}" "$db" "$schema_guard SELECT json_extract(settings, '\$.clients') FROM inbounds WHERE id = $inbound_id AND json_valid(settings);")" || exit 1
  fi
  traffic="$("${read_db[@]}" -json "$db" "$schema_guard SELECT * FROM client_traffics;")" || exit 1
  tmp="$(mktemp "${output}.XXXXXXXX")" || exit 1
  trap 'rm -f -- "$tmp"' EXIT
  printf '%s\n%s\n' "${clients:-[]}" "${traffic:-[]}" |
    jq -sce --arg flow "$flow" --arg normalized "$normalized" '
      def number: if . == null or . == "" then 0 else tonumber end |
        if floor==. and .>=-9007199254740991 and .<=9007199254740991
        then . else error("Unsupported numeric field") end;
      def enabled: if .==null then true else .==true or .==1 end;
      .[0] as $clients | (.[1] | INDEX(.email)) as $traffic
      | if ($clients|type)!="array" or ($clients|length)==0 then error("Selected inbound has no clients") else . end
      | [$clients[] | . as $c | $traffic[$c.email] as $t
        | {
          client: {
            id: (if $normalized=="2" then $c.uuid else $c.id end),
            email: $c.email, subId: ($c.sub_id // $c.subId // ""), flow: $flow,
            enable: (($c.enable|enabled) and ($t.enable|enabled)),
            expiryTime: (($t.expiry_time // $c.expiry_time // $c.expiryTime)|number),
            limitIp: (($c.limit_ip // $c.limitIp)|number),
            limitHwid: (($c.limit_hwid // $c.limitHwid)|number),
            totalGB: (($t.total // $c.total_gb // $c.totalGB)|number),
            tgId: (($c.tg_id // $c.tgId)|number),
            comment: ($c.comment // ""),
            group: ($c.group // ""),
            reset: (($t.reset // $c.reset)|number),
            resetDay: (($t.reset_day // $c.reset_day // $c.resetDay)|number),
            resetWeekday: (($t.reset_weekday // $c.reset_weekday // $c.resetWeekday)|number),
            resetMax: (($t.reset_max // $c.reset_max // $c.resetMax)|number),
            trafficReset: ($c.traffic_reset // $c.trafficReset // ""),
            trafficResetDay: (($c.traffic_reset_day // $c.trafficResetDay)|number),
            created_at: (($c.created_at // $c.createdAt)|number)
          },
          traffic: {
            up: ($t.up|number), down: ($t.down|number), resetCount: ($t.reset_count|number),
            lastOnline: ($t.last_online|number), lastSubFetch: ($t.last_sub_fetch|number)
          }
        }]
      | if all(.[]; (.client.id|type)=="string" and (.client.id|length)>0
                   and (.client.email|type)=="string" and (.client.email|length)>0)
           and ((map(.client.email)|unique|length)==length)
           and ((map(.client.id)|unique|length)==length)
        then . else error("Missing or duplicate client identity") end
    ' > "$tmp" || exit 1
  mv -T "$tmp" "$output"
)

xhttp_restore_migration_backup() {
  local backup="$1"
  systemctl stop x-ui || return 1
  sqlite3 -batch -bail /etc/x-ui/x-ui.db ".restore '$backup'" || return 1
  systemctl start x-ui || return 1
  for _ in {1..15}; do
    if xhttp_memory_api /panel/api/inbounds/list >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

xhttp_import_migrated_clients() (
  set -Eeuo pipefail
  umask 077
  local snapshot="$MANAGED_BACKUP/migration.json" backup="$MANAGED_BACKUP/pre-import.db"
  local done="$MANAGED_BACKUP/migration.done" inbound_id response count
  [[ -s "$snapshot" ]] || exit 1
  [[ ! -f "$done" ]] || exit 0
  if [[ -f "$backup" ]]; then
    xhttp_restore_migration_backup "$backup" || exit 1
  else
    rm -f -- "$backup.new" || exit 1
    sqlite3 -batch -bail /etc/x-ui/x-ui.db ".timeout 5000" ".backup '$backup.new'" || exit 1
    mv -T "$backup.new" "$backup" || exit 1
  fi
  response="$(xhttp_memory_api /panel/api/inbounds/list)" || exit 1
  inbound_id="$(jq -er --arg tag "$INBOUND_TAG" '
    .obj | if type=="string" then fromjson else . end |
    map(select(.tag==$tag and .protocol=="vless")) | select(length==1) | .[0].id
  ' <<<"$response")" || exit 1
  count="$(jq -er 'length | select(.>0)' "$snapshot")" || exit 1
  if ! response="$(
    jq -c --argjson inbound "$inbound_id" 'map(.inboundIds=[$inbound]) | {data:tojson}' "$snapshot" |
      xhttp_memory_api /panel/api/clients/import -X POST -H 'Content-Type: application/json' --data-binary @-
  )" || ! jq -e --argjson count "$count" '
    .success==true and .obj.created==$count and ((.obj.skipped // [])|length)==0
  ' <<<"$response" >/dev/null; then
    xhttp_restore_migration_backup "$backup" || exit 1
    printf '%s\n' 'Panel rejected one or more clients. Restored the database from before import.' >&2
    exit 1
  fi
  printf '%s\n' "$count" > "$done.new" || exit 1
  mv -T "$done.new" "$done" || exit 1
  printf 'Imported %s VLESS clients, including their usage counters. Refresh client profiles for the new server.\n' "$count"
)
