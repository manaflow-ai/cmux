#!/usr/bin/env bash
# scripts/ci/pool-disk-need.sh: a package leg asks the pool VM's disk-floor hook for its own need.
# df is a stub reading $TMP/free; the hook is a stub that records its environment and may free space.
# - off a pool VM (no hook): ok, the hook never runs;
# - enough free: the hook never runs;
# - short, and the hook frees enough: the hook ran "started" with this leg's need as job and floor bytes;
# - short, and the hook frees too little: a ::warning:: with the numbers, exit 0 all the same;
# - a bad argument: exit 2.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
script="$ROOT/scripts/ci/pool-disk-need.sh"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/df" <<EOF
#!/usr/bin/env bash
printf 'Avail\n%s\n' "\$(cat "$TMP/free")"
EOF
cat > "$TMP/hook" <<EOF
#!/usr/bin/env bash
printf '%s %s %s %s\n' "\$1" "\$CMUX_DISK_JOB_BYTES" "\$CMUX_DISK_FLOOR_BYTES" "\$CMUX_DISK_START_WAIT" > "$TMP/called"
[ ! -f "$TMP/freed" ] || cp "$TMP/freed" "$TMP/free"
EOF
chmod +x "$TMP/bin/df" "$TMP/hook"
G=$((1 << 30))

run() { # <hook path> <need gib>: stdout+stderr to $TMP/log, status to $TMP/status
  rm -f "$TMP/called"; : > "$TMP/summary"
  set +e
  PATH="$TMP/bin:$PATH" CMUX_DISK_FLOOR_HOOK="$1" GITHUB_STEP_SUMMARY="$TMP/summary" bash "$script" "$2" > "$TMP/log" 2>&1
  echo $? > "$TMP/status"
  set -e
}

echo $((10 * G)) > "$TMP/free"; rm -f "$TMP/freed"
run "$TMP/no-such-hook" 45
[[ "$(cat "$TMP/status")" == 0 ]] || fail "no hook: exit $(cat "$TMP/status")"
[[ ! -e "$TMP/called" ]] || fail "no hook: something ran"
grep -q 'not a pool VM' "$TMP/log" || fail "no hook: $(cat "$TMP/log")"

echo $((60 * G)) > "$TMP/free"
run "$TMP/hook" 45
[[ ! -e "$TMP/called" ]] || fail "enough free: the hook ran"
grep -q '60.0 GiB free.*45 GiB: ok' "$TMP/log" || fail "enough free: $(cat "$TMP/log")"

echo $((20 * G)) > "$TMP/free"; echo $((50 * G)) > "$TMP/freed"
run "$TMP/hook" 45
[[ "$(cat "$TMP/called")" == "started $((45 * G)) $((45 * G)) 180" ]] || fail "short: hook got $(cat "$TMP/called" 2>&1)"
grep -q '20.0 -> 50.0 GiB free.*: ok' "$TMP/log" || fail "short, freed: $(cat "$TMP/log")"
! grep -q '::warning::' "$TMP/log" || fail "short, freed: warned"
grep -q ', ok' "$TMP/summary" || fail "short, freed: summary $(cat "$TMP/summary")"

echo $((20 * G)) > "$TMP/free"; echo $((30 * G)) > "$TMP/freed"
run "$TMP/hook" 45
[[ "$(cat "$TMP/status")" == 0 ]] || fail "still short: exit $(cat "$TMP/status")"
grep -q '::warning::.*20.0 -> 30.0 GiB free.*need 45 GiB' "$TMP/log" || fail "still short: $(cat "$TMP/log")"
grep -q ', short' "$TMP/summary" || fail "still short: summary $(cat "$TMP/summary")"

run "$TMP/hook" lots
[[ "$(cat "$TMP/status")" == 2 ]] || fail "bad argument: exit $(cat "$TMP/status")"

echo "pool-disk-need: ok"
