#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/daemon-static-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/cmux"
cp /bin/true "$bin"
chmod +x "$bin"
manifest="$tmp/daemon-capabilities.json"
requirements="$tmp/requirements.json"
printf '%s\n' '{"cmuxTui":["attach-initial-size","terminal-env-v1","chief-live-v1","browser-host-provider-v1"]}' > "$manifest"
printf '%s\n' '{"required":["attach-initial-size"],"optional":["terminal-env-v1","chief-live-v1","browser-host-provider-v1","terminal-reaper-active-v1"]}' > "$requirements"

bash "$ROOT/scripts/cmux-next/check-daemon-capabilities.sh" --static-only \
  --binary "$bin" --capabilities "$requirements" >/dev/null

printf '%s\n' '{"cmuxTui":[]}' > "$manifest"
if bash "$ROOT/scripts/cmux-next/check-daemon-capabilities.sh" --static-only \
  --binary "$bin" --capabilities "$requirements" >/dev/null 2>&1; then
  echo "FAIL: static capability check accepted a manifest missing required capabilities" >&2
  exit 1
fi

printf '%s\n' '{"cmuxTui":["attach-initial-size"]}' > "$manifest"
if bash "$ROOT/scripts/cmux-next/check-daemon-capabilities.sh" --static-only \
  --binary "$bin" --capabilities "$requirements" >/dev/null 2>&1; then
  echo "FAIL: static capability check accepted a manifest missing an unconditional optional capability" >&2
  exit 1
fi

printf '%s\n' '{"cmuxTui":["attach-initial-size","terminal-env-v1","chief-live-v1","browser-host-provider-v1"]}' > "$manifest"

rm "$manifest"
if bash "$ROOT/scripts/cmux-next/check-daemon-capabilities.sh" --static-only \
  --binary "$bin" --capabilities "$requirements" >/dev/null 2>&1; then
  echo "FAIL: static capability check accepted a missing manifest" >&2
  exit 1
fi

echo "PASS: static daemon capability check validates required manifest entries"
