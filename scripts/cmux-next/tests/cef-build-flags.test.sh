#!/usr/bin/env bash
# cef_build_flags.py reads a CEF folder's archive.json (written by the fork's
# build-cmux-cef.sh, cmux.17 and later) and checks that the framework was
# built with dcheck_always_on = false: with DCHECKs on, a DCHECK that web
# content reaches aborts the app (plans/cmux-next/crash-elimination.md).
# Without --require it only warns (frameworks before cmux.17 have no
# gn_args); with --require it refuses.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/../cef_build_flags.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/cef-build-flags.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/off" "$work/on" "$work/old"
echo '{"type":"minimal","name":"n","cmux_ref":"r","gn_args":{"dcheck_always_on":false,"is_official_build":false}}' > "$work/off/archive.json"
echo '{"type":"minimal","name":"n","cmux_ref":"r","gn_args":{"is_official_build":false}}' > "$work/on/archive.json"
echo '{"type":"minimal","name":"n","cmux_ref":"r"}' > "$work/old/archive.json"

/usr/bin/python3 "$check" "$work/off" --require 2>/dev/null || fail "a DCHECK-off framework was refused"
/usr/bin/python3 "$check" "$work/off" 2>"$work/err" || fail "a DCHECK-off framework failed without --require"
[[ ! -s "$work/err" ]] || fail "a DCHECK-off framework printed a warning"
for kind in on old; do
  if /usr/bin/python3 "$check" "$work/$kind" --require 2>/dev/null; then fail "--require accepted the $kind framework"; fi
  /usr/bin/python3 "$check" "$work/$kind" 2>"$work/err" || fail "the $kind framework failed without --require"
  grep -q "warning: " "$work/err" || fail "no warning for the $kind framework"
done
if /usr/bin/python3 "$check" "$work/missing" --require 2>/dev/null; then fail "--require accepted a folder without archive.json"; fi
echo "cef-build-flags: ok"
