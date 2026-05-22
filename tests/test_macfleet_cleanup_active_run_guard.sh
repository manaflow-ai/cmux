#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp -d)"
fake_pid=""
cleanup() {
  if [ -n "$fake_pid" ]; then
    kill "$fake_pid" >/dev/null 2>&1 || true
    wait "$fake_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

home="$tmp/cmuxvnc1"
mkdir -p \
  "$home/cmux-ci/DerivedData/active-run" \
  "$home/Library/Developer/Xcode/DerivedData/active-run" \
  "$home/cmux-ci/tmp/active-run" \
  "$tmp/system-tmp"

fake_runner="$tmp/run-ci.sh"
cat > "$fake_runner" <<'SH'
#!/usr/bin/env bash
sleep 60
SH
chmod +x "$fake_runner"
"$fake_runner" main tests-build-and-lag &
fake_pid="$!"

cat > "$home/cmux-ci/tmp/active-run/run.lock" <<EOF
pid=$fake_pid
mode=tests-build-and-lag
run_id=fake-active-run
root=$home/cmux-ci
derived=$home/cmux-ci/DerivedData/active-run
EOF

CMUX_MACFLEET_HOME_GLOB="$tmp/cmuxvnc*" \
CMUX_MACFLEET_TMP_PRUNE_ROOTS="$tmp/system-tmp" \
CMUX_MACFLEET_MIN_FREE_GIB=999999 \
CMUX_MACFLEET_DERIVED_MAX_AGE_MINUTES=0 \
CMUX_MACFLEET_TMP_MAX_AGE_MINUTES=0 \
CMUX_MACFLEET_POSTGRES_MAX_AGE_MINUTES=0 \
  scripts/macfleet-cleanup.sh > "$tmp/cleanup.log"

if [ ! -d "$home/cmux-ci/DerivedData/active-run" ]; then
  echo "cleanup removed active cmux-ci DerivedData" >&2
  cat "$tmp/cleanup.log" >&2
  exit 1
fi

if [ ! -d "$home/Library/Developer/Xcode/DerivedData/active-run" ]; then
  echo "cleanup removed active user DerivedData" >&2
  cat "$tmp/cleanup.log" >&2
  exit 1
fi

if ! grep -q "active macfleet run detected" "$tmp/cleanup.log"; then
  echo "cleanup did not detect the active macfleet run" >&2
  cat "$tmp/cleanup.log" >&2
  exit 1
fi
