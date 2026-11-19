#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../xhttp-vps-common.sh
source ./xhttp-vps-common.sh

export MAINTENANCE_TIMEZONE=Europe/Moscow
reboot_timer="$(xhttp_render_maintenance_timer reboot)"
grep -Fqx 'OnCalendar=Sun *-*-* 05:30:00 Europe/Moscow' <<<"$reboot_timer"
grep -Fqx 'Persistent=false' <<<"$reboot_timer"
grep -Fqx 'Unit=xhttp-vps-reboot.service' <<<"$reboot_timer"

test_dir="$(mktemp -d)"
export test_dir
trap 'rm -rf "$test_dir"' EXIT
xhttp_render_maintenance_script | sed \
  -e "s#/run/xhttp-vps-maintenance.ok#$test_dir/completed#" \
  -e "s#/run/xhttp-vps-setup.lock#$test_dir/lock#" \
  -e "s#/var/run/reboot-required#$test_dir/reboot-required#" > "$test_dir/run"

flock() { [[ "${LOCK_BUSY:-0}" == 0 ]]; }
logger() { :; }
date() {
  case "$1" in
    '+%u %H:%M') printf '%s\n' "${TEST_SLOT:-7 05:30}" ;;
    +%F) printf '%s\n' '2026-11-22' ;;
    *) return 1 ;;
  esac
}
apt-get() {
  printf '%s\n' "${*: -1}" >> "$test_dir/apt"
  [[ "${*: -1}" != "${FAIL_APT:-}" ]]
}
dpkg() { :; }
nginx() { [[ "${BAD_NGINX:-0}" == 0 ]]; }
systemctl() {
  case "$*" in
    '--no-block reboot') printf 'reboot\n' >> "$test_dir/reboots" ;;
    'is-active --quiet apt-daily.service apt-daily-upgrade.service') [[ "${APT_ACTIVE:-0}" == 1 ]] ;;
    'is-active --quiet ssh.service ssh.socket') [[ "${NO_SSH:-0}" == 0 ]] ;;
    'is-active --quiet '*) return 0 ;;
    *) return 1 ;;
  esac
}
export -f flock logger date apt-get dpkg nginx systemctl

run_phase() { bash "$test_dir/run" "$1" x-ui Europe/Moscow; }

touch "$test_dir/reboot-required"
run_phase reboot
[[ ! -e "$test_dir/reboots" ]]
FAIL_APT=autoremove run_phase upgrade && exit 1
[[ ! -e "$test_dir/completed" ]]
run_phase reboot
[[ ! -e "$test_dir/reboots" ]]
: > "$test_dir/apt"
run_phase upgrade
cmp "$test_dir/apt" <(printf '%s\n' update upgrade autoremove autoclean check)
grep -Fqx '2026-11-22' "$test_dir/completed"
[[ ! -e "$test_dir/reboots" ]]

TEST_SLOT='7 05:31' run_phase reboot
LOCK_BUSY=1 run_phase reboot
APT_ACTIVE=1 run_phase reboot
BAD_NGINX=1 run_phase reboot && exit 1
NO_SSH=1 run_phase reboot && exit 1
rm -f "$test_dir/reboot-required"
run_phase reboot
[[ ! -e "$test_dir/reboots" ]]

touch "$test_dir/reboot-required"
run_phase reboot
grep -Fqx reboot "$test_dir/reboots"
printf 'Weekly maintenance tests passed.\n'
