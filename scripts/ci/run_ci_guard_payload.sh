#!/usr/bin/env bash
# Run scripts/ci/workloads/ci-guard.sh's commands without the workload profile
# runner, all at once. The profile runner (cmux_workload_profile.py) refuses
# anything but Linux, while the commands (the self-hosted runner policy, change
# routing, required checks, test wiring) are portable. run_ci_guards.py uses
# this on macOS so a local guard run still covers them.
#
# It reads the commands from ci-guard.sh itself. A line it does not recognize
# fails the run rather than being skipped.
set -uo pipefail

payload="${1:-scripts/ci/workloads/ci-guard.sh}"
[[ -f "$payload" ]] || { echo "run_ci_guard_payload.sh: no $payload" >&2; exit 2; }
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

commands=()
while IFS= read -r line || [[ -n "$line" ]]; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in
    ""|"#"*|"set -"*|"root="*|'cd "$root"'|"stage() {"|"}"|"stage "*) continue ;;
    'python3 "$root/scripts/ci/cmux_workload_profile.py" stage "$1" "$2"') continue ;;
    "./"*|"python3 "*|"bash "*) commands+=("$trimmed") ;;
    *) echo "run_ci_guard_payload.sh: unrecognized line in $payload: $line" >&2; exit 2 ;;
  esac
done < "$payload"
[[ ${#commands[@]} -gt 0 ]] || { echo "run_ci_guard_payload.sh: no commands in $payload" >&2; exit 2; }

pids=()
for i in "${!commands[@]}"; do
  bash -eo pipefail -c "${commands[$i]}" >"$logs/$i" 2>&1 &
  pids[$i]=$!
done
status=0
for i in "${!commands[@]}"; do
  if ! wait "${pids[$i]}"; then
    echo "FAIL: ${commands[$i]}"
    cat "$logs/$i"
    status=1
  fi
done
[[ $status -eq 0 ]] && echo "ci-guard payload: ${#commands[@]} commands passed"
exit "$status"
