#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../xhttp-vps-common.sh
source ./xhttp-vps-common.sh

export MAINTENANCE_TIMEZONE=Europe/Moscow
timer="$(xhttp_render_maintenance_timer)"
grep -Fqx 'OnCalendar=*-*-* 05:30:00 Europe/Moscow' <<<"$timer"
grep -Fqx 'Persistent=false' <<<"$timer"
grep -Fqx 'Unit=xhttp-vps-maintenance.service' <<<"$timer"

test_dir="$(mktemp -d)"
export test_dir
trap 'rm -rf "$test_dir"' EXIT
(
  xhttp_update_panel() {
    printf 'vpn-release\n' >> "$test_dir/apt"
    return "${UPDATE_STATUS:-0}"
  }
  xhttp_wait_for_vpn_service() { [[ "${VPNSERVICE_HEALTHY:-1}" == 1 ]]; }
  xhttp_render_maintenance_script
) | sed \
  -e "s#/run/xhttp-vps-setup.lock#$test_dir/lock#" \
  -e "s#/var/run/reboot-required#$test_dir/reboot-required#" > "$test_dir/run"

flock() { [[ "${LOCK_BUSY:-0}" == 0 ]]; }
logger() { :; }
date() { [[ "$1" == +%u ]] && printf '%s\n' "${TEST_WEEKDAY:-1}"; }
apt-get() {
  printf '%s\n' "${*: -1}" >> "$test_dir/apt"
  if [[ "${*: -1}" == "${FAIL_APT_ONCE:-}" && ! -e "$test_dir/apt-failed" ]]; then
    touch "$test_dir/apt-failed"
    return 1
  fi
  [[ "${*: -1}" != "${FAIL_APT:-}" ]]
}
unattended-upgrade() {
  printf 'security\n' >> "$test_dir/apt"
  if [[ "${FAIL_SECURITY_ONCE:-0}" == 1 && ! -e "$test_dir/security-failed" ]]; then
    touch "$test_dir/security-failed"
    return 1
  fi
}
dpkg() { :; }
nginx() { [[ "${BAD_NGINX:-0}" == 0 ]]; }
systemctl() {
  case "$*" in
    '--no-block reboot') printf 'reboot\n' >> "$test_dir/apt" ;;
    'is-active --quiet apt-daily.service apt-daily-upgrade.service') [[ "${APT_ACTIVE:-0}" == 1 ]] ;;
    'is-active --quiet ssh.service ssh.socket') [[ "${NO_SSH:-0}" == 0 ]] ;;
    'is-active --quiet '*) return 0 ;;
    *) return 1 ;;
  esac
}
export -f flock logger date apt-get unattended-upgrade dpkg nginx systemctl

run_maintenance() {
  : > "$test_dir/apt"
  bash "$test_dir/run" "$1" "${2:-awg-quick@awg-vps}" Europe/Moscow 2020
}

assert_no_reboot() {
  if grep -Fqx reboot "$test_dir/apt"; then return 1; fi
}

run_maintenance weekly x-ui
cmp "$test_dir/apt" <(printf '%s\n' update security check)
touch "$test_dir/reboot-required"
run_maintenance weekly
cmp "$test_dir/apt" <(printf '%s\n' update security check reboot)
TEST_WEEKDAY=7 run_maintenance security x-ui
cmp "$test_dir/apt" <(printf '%s\n' update security check)
TEST_WEEKDAY=7 run_maintenance weekly x-ui
cmp "$test_dir/apt" <(printf '%s\n' update security upgrade autoremove autoclean vpn-release check reboot)

LOCK_BUSY=1 run_maintenance weekly
[[ ! -s "$test_dir/apt" ]]
APT_ACTIVE=1 run_maintenance weekly
cmp "$test_dir/apt" <(printf '%s\n' update security check)
if BAD_NGINX=1 run_maintenance weekly; then exit 1; fi
assert_no_reboot
if NO_SSH=1 run_maintenance weekly; then exit 1; fi
assert_no_reboot
if TEST_WEEKDAY=7 FAIL_APT=autoremove run_maintenance weekly; then exit 1; fi
assert_no_reboot

FAIL_SECURITY_ONCE=1 run_maintenance weekly
cmp "$test_dir/apt" <(printf '%s\n' update security install check security check reboot)
TEST_WEEKDAY=7 FAIL_APT_ONCE=upgrade UPDATE_STATUS=1 run_maintenance weekly x-ui
cmp "$test_dir/apt" <(printf '%s\n' update security upgrade install check upgrade autoremove autoclean vpn-release check reboot)
if TEST_WEEKDAY=7 VPNSERVICE_HEALTHY=0 UPDATE_STATUS=1 run_maintenance weekly x-ui; then exit 1; fi
assert_no_reboot
if TEST_WEEKDAY=7 UPDATE_STATUS=70 run_maintenance weekly x-ui; then exit 1; fi
assert_no_reboot

# Check the actual APT fragments without replacing the runner's configuration.
eval "$(declare -f xhttp_configure_automatic_updates | sed "s#/etc/apt/apt.conf.d#$test_dir#g")"
xhttp_install_maintenance() { :; }
MAINTENANCE_MODE=weekly xhttp_configure_automatic_updates
apt_policy="$(cat "$test_dir/52xhttp-vps-auto-upgrades" "$test_dir/53xhttp-vps-unattended-upgrades")"
printf '%s\n' "$apt_policy" > "$test_dir/apt.conf"
effective_policy="$(apt-config -c "$test_dir/apt.conf" dump)"
grep -Fqx 'APT::Periodic::Enable "0";' <<<"$effective_policy"
grep -Fqx 'Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-security";' <<<"$effective_policy"
grep -Fqx 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$effective_policy"

# Exercise binary deployment and SQLite rollback without touching system services.
eval "$(declare -f xhttp_update_panel xhttp_update_hysteria | sed \
  -e "s#/usr/local/bin#$test_dir/bin#g" \
  -e "s#/usr/local#$test_dir/local#g" \
  -e "s#/usr/bin#$test_dir/bin#g" \
  -e "s#/etc/x-ui#$test_dir/etc#g")"
mkdir -p "$test_dir/local/x-ui/bin" "$test_dir/bin" "$test_dir/etc"
database="$test_dir/etc/x-ui.db"
panel="$test_dir/local/x-ui"
printf 'old\n' > "$panel/x-ui"
printf 'old\n' > "$panel/bin/xray-linux-amd64"
printf 'old\n' > "$test_dir/bin/x-ui"
chmod +x "$panel/x-ui" "$panel/bin/xray-linux-amd64"
sqlite3 "$database" 'CREATE TABLE clients (id TEXT); INSERT INTO clients VALUES ("keep");'

xhttp_release_arch() { printf 'amd64\n'; }
xhttp_stage_panel_release() {
  [[ "${ATTEMPT:-changed}" != current ]] || return 0
  mkdir -p "$1/x-ui/bin"
  printf 'new\n' > "$1/x-ui/x-ui"
  printf 'new\n' > "$1/x-ui/x-ui.sh"
  printf 'new-core\n' > "$1/xray"
  printf 'updated-hash\n' > "$1/xray.zip.sha256"
}
xhttp_latest_release_asset() {
  printf '#!/usr/bin/env bash\nexit 0\n# new\n' > "$3"
}
systemctl() {
  printf '%s\n' "$*" >> "$test_dir/services"
  if [[ "$*" == 'restart x-ui' && $(<"$test_dir/local/x-ui/x-ui") == new ]]; then
    sqlite3 "$test_dir/etc/x-ui.db" 'DELETE FROM clients;'
  fi
}
xhttp_wait_for_vpn_service() {
  if [[ "${ATTEMPT:-changed}" != fail ]]; then return 0; fi
  if [[ "$1" == x-ui ]]; then
    [[ $(<"$test_dir/local/x-ui/x-ui") == old ]]
  else
    grep -Fqx '# old' "$test_dir/bin/xhttp-vps-hysteria"
  fi
}
export -f xhttp_update_panel xhttp_update_hysteria xhttp_release_arch xhttp_stage_panel_release \
  xhttp_latest_release_asset systemctl xhttp_wait_for_vpn_service xhttp_restart_vpn_service

ATTEMPT=current bash -c 'xhttp_update_panel 2020'
[[ ! -e "$test_dir/services" ]]
if ATTEMPT=fail bash -c 'xhttp_update_panel 2020'; then exit 1; fi
grep -Fxq old "$panel/x-ui"
grep -Fxq old "$panel/bin/xray-linux-amd64"
grep -Fxq old "$test_dir/bin/x-ui"
[[ $(sqlite3 "$database" 'SELECT id FROM clients') == keep ]]
bash -c 'xhttp_update_panel 2020'
grep -Fxq new "$panel/x-ui"
grep -Fxq new-core "$panel/bin/xray-linux-amd64"
grep -Fxq new "$test_dir/bin/x-ui"

printf '#!/usr/bin/env bash\nexit 0\n# old\n' > "$test_dir/bin/xhttp-vps-hysteria"
chmod +x "$test_dir/bin/xhttp-vps-hysteria"
if ATTEMPT=fail bash -c 'xhttp_update_hysteria'; then exit 1; fi
grep -Fqx '# old' "$test_dir/bin/xhttp-vps-hysteria"
bash -c 'xhttp_update_hysteria'
grep -Fqx '# new' "$test_dir/bin/xhttp-vps-hysteria"
printf 'Scheduled maintenance tests passed.\n'
