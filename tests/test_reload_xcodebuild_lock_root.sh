#!/usr/bin/env bash
# reload.sh's xcodebuild slots live in macOS's per-user temp dir, not under
# TMPDIR: an ssh session has no TMPDIR, and a /tmp fallback there was a second,
# separate set of slots beside the GUI session's.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Use the real function, not a copy.
eval "$(awk '/^xcodebuild_lock_dir\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
declare -F xcodebuild_lock_dir >/dev/null || fail "xcodebuild_lock_dir not found in reload.sh"
grep -Fxq 'XCODEBUILD_LOCK_DIR="$(xcodebuild_lock_dir)"' "$ROOT/scripts/reload.sh" \
  || fail "reload.sh does not take XCODEBUILD_LOCK_DIR from xcodebuild_lock_dir"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
uid="$(id -u)"

# getconf answers like macOS, with a trailing slash.
printf '#!/bin/sh\n[ "$1" = DARWIN_USER_TEMP_DIR ] || exit 1\necho /var/folders/zz/user/T/\n' > "$tmp/bin/getconf"
chmod +x "$tmp/bin/getconf"
want="/var/folders/zz/user/T/cmux-xcodebuild-$uid.locks"
for tmpdir in /var/folders/zz/user/T/ /tmp ""; do
  if [[ -n "$tmpdir" ]]; then
    got="$(PATH="$tmp/bin:$PATH" TMPDIR="$tmpdir" xcodebuild_lock_dir)"
  else
    got="$(env -u TMPDIR PATH="$tmp/bin:$PATH" bash -c "$(declare -f xcodebuild_lock_dir); xcodebuild_lock_dir")"
  fi
  [[ "$got" == "$want" ]] || fail "TMPDIR='${tmpdir:-unset}' gave $got, want $want"
done

# Off macOS getconf has no DARWIN_USER_TEMP_DIR: /tmp, never TMPDIR.
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/getconf"
got="$(PATH="$tmp/bin:$PATH" TMPDIR=/elsewhere xcodebuild_lock_dir)"
[[ "$got" == "/tmp/cmux-xcodebuild-$uid.locks" ]] || fail "fallback gave $got"

echo "PASS: reload.sh xcodebuild lock root"
