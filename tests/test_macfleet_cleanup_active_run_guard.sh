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
bin="$tmp/bin"
mkdir -p \
  "$bin" \
  "$home/cmux-ci/DerivedData/active-run" \
  "$home/cmux-ci/postgres-active-run-5432" \
  "$home/Library/Developer/Xcode/DerivedData/active-run" \
  "$home/cmux-ci/tmp/active-run" \
  "$tmp/system-tmp"
touch -t 200001010000 "$home/cmux-ci/postgres-active-run-5432"

cat > "$bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$bin/pgrep"

fake_runner="$tmp/run-ci.sh"
cat > "$fake_runner" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do
  sleep 1
done
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
PATH="$bin:$PATH" \
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

if [ ! -d "$home/cmux-ci/postgres-active-run-5432" ]; then
  echo "cleanup removed active Postgres data" >&2
  cat "$tmp/cleanup.log" >&2
  exit 1
fi

kill "$fake_pid" >/dev/null 2>&1 || true
wait "$fake_pid" >/dev/null 2>&1 || true
fake_pid=""

echo "$$" > "$home/cmux-ci/tmp/active-run/pids"
ps -o pgid= -p "$$" | tr -d ' ' > "$home/cmux-ci/tmp/active-run/pgids"
touch -t 200001010000 \
  "$home/cmux-ci/DerivedData/active-run" \
  "$home/cmux-ci/postgres-active-run-5432" \
  "$home/Library/Developer/Xcode/DerivedData/active-run" \
  "$home/cmux-ci/tmp/active-run"

CMUX_MACFLEET_HOME_GLOB="$tmp/cmuxvnc*" \
CMUX_MACFLEET_TMP_PRUNE_ROOTS="$tmp/system-tmp" \
CMUX_MACFLEET_MIN_FREE_GIB=999999 \
CMUX_MACFLEET_DERIVED_MAX_AGE_MINUTES=0 \
CMUX_MACFLEET_TMP_MAX_AGE_MINUTES=0 \
CMUX_MACFLEET_POSTGRES_MAX_AGE_MINUTES=0 \
PATH="$bin:$PATH" \
  scripts/macfleet-cleanup.sh > "$tmp/stale-cleanup.log"

if grep -q "active macfleet run detected" "$tmp/stale-cleanup.log"; then
  echo "cleanup treated stale run metadata as active" >&2
  cat "$tmp/stale-cleanup.log" >&2
  exit 1
fi

if [ -d "$home/cmux-ci/DerivedData/active-run" ]; then
  echo "cleanup kept cmux-ci DerivedData for stale run metadata" >&2
  cat "$tmp/stale-cleanup.log" >&2
  exit 1
fi

if [ -d "$home/Library/Developer/Xcode/DerivedData/active-run" ]; then
  echo "cleanup kept user DerivedData for stale run metadata" >&2
  cat "$tmp/stale-cleanup.log" >&2
  exit 1
fi

if [ -d "$home/cmux-ci/postgres-active-run-5432" ]; then
  echo "cleanup kept Postgres data for stale run metadata" >&2
  cat "$tmp/stale-cleanup.log" >&2
  exit 1
fi

if ! grep -q "active macfleet run detected" "$tmp/cleanup.log"; then
  echo "cleanup did not detect the active macfleet run" >&2
  cat "$tmp/cleanup.log" >&2
  exit 1
fi
