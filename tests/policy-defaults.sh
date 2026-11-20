#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../xhttp-vps-common.sh
source ./xhttp-vps-common.sh

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
legacy='{"log":{"loglevel":"warning"},"policy":{"system":{"statsInboundUplink":true},"levels":{"0":{"bufferSize":64,"connIdle":180,"statsUserUplink":true,"handshake":4},"1":{"bufferSize":128}}},"routing":{"rules":[{"outboundTag":"blocked"}]}}'
expected="$(jq -c 'del(.policy.levels["0"].bufferSize,.policy.levels["0"].connIdle)' <<<"$legacy")"
fixture_url='https://example.com/probe'

mktemp() { command mktemp -d "$test_dir/backup.XXXXXXXX"; }
sqlite3() { printf 'backup\n' >> "$test_dir/calls"; }
xhttp_panel_api() {
  local path="$1" arg
  shift
  case "$path" in
    /panel/api/xray/)
      jq -nc --argjson setting "$(cat "$test_dir/template")" --arg url "$fixture_url" \
        '{success:true,obj:({xraySetting:($setting|tojson),outboundTestUrl:$url}|tojson)}'
      ;;
    /panel/api/xray/update)
      [[ "$*" == *"outboundTestUrl=$fixture_url"* ]] || return 1
      printf 'update\n' >> "$test_dir/calls"
      for arg in "$@"; do
        if [[ "$arg" == xraySetting=* ]]; then printf '%s\n' "${arg#xraySetting=}" > "$test_dir/template"; fi
      done
      if [[ "${reject_update:-0}" == 1 && ! -e "$test_dir/rejected" ]]; then
        touch "$test_dir/rejected"
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

printf '%s\n' "$legacy" > "$test_dir/template"
xhttp_restore_policy_defaults
[[ "$(cat "$test_dir/template")" == "$expected" ]]
[[ "$(cat "$test_dir"/backup.*/xray.json)" == "$legacy" ]]
[[ "$(cat "$test_dir/calls")" == $'backup\nupdate' ]]

xhttp_restore_policy_defaults
custom="$(jq -c '.policy.levels["0"].connIdle = 600' <<<"$legacy")"
printf '%s\n' "$custom" > "$test_dir/template"
xhttp_restore_policy_defaults
[[ "$(cat "$test_dir/template")" == "$custom" ]]
[[ "$(cat "$test_dir/calls")" == $'backup\nupdate' ]]

printf '%s\n' "$legacy" > "$test_dir/template"
: > "$test_dir/calls"
if reject_update=1 xhttp_restore_policy_defaults; then exit 1; fi
[[ "$(cat "$test_dir/template")" == "$legacy" ]]
[[ "$(cat "$test_dir/calls")" == $'backup\nupdate\nupdate' ]]
printf 'Xray policy migration tests passed.\n'
