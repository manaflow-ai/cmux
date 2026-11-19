#!/usr/bin/env bash
# background-ready.sh refuses a bad argument before it touches anything (no .build folder, no socket folder), and
# sourced it defines its functions on top of launch-ready.sh's (side_defaults, quiesce: reused, not copied) and runs
# nothing.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/background-ready.sh"
root="$(cd "$(dirname "$script")/../.." && pwd)"
out="$root/.build/background-ready"
had_out=0
[[ -e "$out" ]] && had_out=1

refuses() {
  local want="$1" err status
  shift
  set +e
  err="$(bash "$script" "$@" 2>&1 >/dev/null)"
  status=$?
  set -e
  [[ "$status" == 2 ]] || { echo "background-ready $*: exit $status, want 2 ($err)" >&2; exit 1; }
  [[ "$err" == *"$want"* ]] || { echo "background-ready $*: said '$err', want '$want'" >&2; exit 1; }
}

refuses "runs= must be 1 to 10" runs=11
refuses "runs= must be 1 to 10" runs=0
refuses "arms= takes cold, hide, close, quit: not warm" arms=cold,warm
refuses "arms= names hide twice" arms=hide,hide
refuses "idle= takes 0 to 3600" idle=-1
refuses "settle= takes 1 to 120" settle=0
refuses "head= takes a 40-hex commit, with dmg=build" head=0123456789012345678901234567890123456789
refuses "head= takes a 40-hex commit" dmg=build head=abc
refuses "setting= is the quit arm's" setting=afterQuit
refuses "unknown argument: setting=afterQuitAndLogin" arms=quit setting=afterQuitAndLogin
refuses "unknown argument: front=chat" front=chat
if [[ "$had_out" == 0 && -e "$out" ]]; then echo "background-ready: a refused run made $out" >&2; exit 1; fi

# shellcheck source=../background-ready.sh
source "$script"
for fn in br_main br_arm br_get_dmg br_stop side_defaults defaults_aside defaults_restore quiesce load_1m; do
  declare -F "$fn" >/dev/null || { echo "background-ready: $fn not defined when sourced" >&2; exit 1; }
done
echo "background-ready args: ok"
