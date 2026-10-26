#!/usr/bin/env bash
# cef_build_flags.py reads a CEF folder's archive.json (written by the fork's
# build-cmux-cef.sh, cmux.17 and later) and checks that the framework was
# built with dcheck_always_on = false: with DCHECKs on, a DCHECK that web
# content reaches aborts the app (plans/cmux-next/crash-elimination.md).
# Without --require it only warns (frameworks before cmux.17 have no
# gn_args); with --require it refuses. --require-official-pgo also refuses a
# framework that is not is_official_build=true with its revision's PGO profile.
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

# --require-official-pgo (manifest "require_official_pgo", chrome-parity
# p08-startup-047): is_official_build=true, PGO phase 2, the profile of the
# pinned Chromium revision and arch, and a measured mismatch rate below 10 %.
official() { /usr/bin/python3 "$check" "$1" --require-official-pgo --chromium 154.0.8037.58 --arch "${2:-arm64}"; }
sha1=0123456789abcdef0123456789abcdef01234567
arm_profile="chrome-mac-arm-8037-1761091200-$sha1.profdata"
write_official() { # <name> <gn_args json> <pgo_profile json> <pgo_mismatch_rate json>
  mkdir -p "$work/$1"
  echo "{\"type\":\"minimal\",\"name\":\"n\",\"cmux_ref\":\"r\",\"gn_args\":$2,\"pgo_profile\":$3,\"pgo_mismatch_rate\":$4}" > "$work/$1/archive.json"
}
good_args='{"dcheck_always_on":false,"is_official_build":true,"chrome_pgo_phase":2}'
write_official pgo "$good_args" "\"$arm_profile\"" 0.031
write_official pgo-default-phase '{"dcheck_always_on":false,"is_official_build":true}' "\"$arm_profile\"" 0
write_official pgo-data-path '{"dcheck_always_on":false,"is_official_build":true,"pgo_data_path":"//chrome/build/pgo_profiles/'"$arm_profile"'"}' "\"$arm_profile\"" 0.05
write_official pgo-x86 "$good_args" "\"chrome-mac-8037-1761091200-$sha1.profdata\"" 0.02
official "$work/pgo" 2>/dev/null || fail "an official PGO framework of the pinned revision was refused"
official "$work/pgo" 2>"$work/err"
[[ ! -s "$work/err" ]] || fail "an official PGO framework printed a message"
official "$work/pgo-default-phase" 2>/dev/null || fail "an official framework with the default PGO phase was refused"
official "$work/pgo-data-path" 2>/dev/null || fail "a pgo_data_path naming the recorded profile was refused"
official "$work/pgo-x86" x86_64 2>/dev/null || fail "the x86_64 profile of the pinned revision was refused"

refuse() { # <name> <why> [arch]
  if official "$work/$1" "${3:-arm64}" 2>"$work/err"; then fail "--require-official-pgo accepted $2"; fi
  grep -q "^error: " "$work/err" || fail "no error for $2"
}
write_official not-official '{"dcheck_always_on":false,"is_official_build":false}' "\"$arm_profile\"" 0.01
refuse not-official "is_official_build=false"
grep -q "is_official_build = true" "$work/err" || fail "the error does not name is_official_build = true"
write_official no-official-flag '{"dcheck_always_on":false}' "\"$arm_profile\"" 0.01
refuse no-official-flag "gn_args without is_official_build"
write_official pgo-off '{"dcheck_always_on":false,"is_official_build":true,"chrome_pgo_phase":0}' "\"$arm_profile\"" 0.01
refuse pgo-off "chrome_pgo_phase=0"
write_official pgo-phase-true '{"dcheck_always_on":false,"is_official_build":true,"chrome_pgo_phase":true}' "\"$arm_profile\"" 0.01
refuse pgo-phase-true "chrome_pgo_phase=true"
write_official dcheck-on '{"is_official_build":true}' "\"$arm_profile\"" 0.01
refuse dcheck-on "an official framework without dcheck_always_on=false"
write_official other-revision "$good_args" "\"chrome-mac-arm-8036-1761091200-$sha1.profdata\"" 0.01
refuse other-revision "the profile of another Chromium build"
write_official main-profile "$good_args" "\"chrome-mac-arm-main-1761091200-$sha1.profdata\"" 0.01
refuse main-profile "a main-branch profile"
refuse pgo-x86 "the x86_64 profile for an arm64 framework"
refuse pgo "the arm64 profile for an x86_64 framework" x86_64
write_official no-profile "$good_args" null 0.01
refuse no-profile "no recorded pgo_profile"
write_official data-path-mismatch '{"dcheck_always_on":false,"is_official_build":true,"pgo_data_path":"/p/chrome-mac-arm-8037-1-'"$sha1"'.profdata"}' "\"$arm_profile\"" 0.01
refuse data-path-mismatch "a pgo_data_path that is not the recorded profile"
write_official high-mismatch "$good_args" "\"$arm_profile\"" 0.10
refuse high-mismatch "a 10 % profile mismatch rate"
write_official no-mismatch "$good_args" "\"$arm_profile\"" null
refuse no-mismatch "no measured mismatch rate"
write_official bool-mismatch "$good_args" "\"$arm_profile\"" false
refuse bool-mismatch "a boolean mismatch rate"
write_official negative-mismatch "$good_args" "\"$arm_profile\"" -0.5
refuse negative-mismatch "a negative mismatch rate"
if official "$work/missing" 2>/dev/null; then fail "--require-official-pgo accepted a folder without archive.json"; fi
# Without --require-official-pgo a non-official framework passes as before.
/usr/bin/python3 "$check" "$work/not-official" --require 2>/dev/null || fail "--require alone refused a non-official framework"

usage() { # <why> <args...>
  local why="$1"; shift
  set +e; /usr/bin/python3 "$check" "$work/pgo" "$@" 2>/dev/null; local code=$?; set -e
  [[ "$code" == 2 ]] || fail "$why exited $code, not 2"
}
usage "--require-official-pgo without --chromium" --require-official-pgo --arch arm64
usage "--require-official-pgo with a short version" --require-official-pgo --chromium 154.0 --arch arm64
usage "--require-official-pgo without --arch" --require-official-pgo --chromium 154.0.8037.58
usage "--require-official-pgo with an unknown arch" --require-official-pgo --chromium 154.0.8037.58 --arch arm64e
usage "an unknown flag" --requires

# The pinned manifest: when it requires an official PGO framework, it also
# requires DCHECKs off and records the Chromium version the profile must match.
manifest="$here/../cef-manifest.json"
/usr/bin/python3 - "$manifest" <<'PY' || fail "cef-manifest.json require_official_pgo is not consistent"
import json, sys
m = json.load(open(sys.argv[1]))
flag = m.get("require_official_pgo")
assert isinstance(flag, bool), "require_official_pgo must be true or false"
if flag:
    assert m.get("require_dcheck_off") is True
    parts = str(m.get("chromium", "")).split(".")
    assert len(parts) == 4 and all(p.isdigit() for p in parts)
PY
echo "cef-build-flags: ok"
