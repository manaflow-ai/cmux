#!/usr/bin/env bash
# blocking-checks.sh --app PATH --expect nightly|release on fake app bundles: nm and swift demangle are
# replaced (CMUX_NM_TOOL, CMUX_SWIFT_DEMANGLE_TOOL), so it runs on any host with bash and python3.
# Run: bash scripts/measure/tests/blocking-checks-app.test.sh
# shellcheck disable=SC2016 # the single-quoted $s... strings are Swift mangled names, not expansions
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/scripts/measure/blocking-checks.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/blocking-checks-app-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

cat >"$work/nm" <<'SH'
#!/bin/sh
[ -n "${FAKE_NM_FAIL:-}" ] && { echo "nm: cannot read" >&2; exit 1; }
cat "$FAKE_NM_OUT"
SH
printf '#!/bin/sh\ncat\n' >"$work/demangle"
printf '#!/bin/sh\nexit 1\n' >"$work/demangle-broken"
chmod +x "$work/nm" "$work/demangle" "$work/demangle-broken"
export CMUX_NM_TOOL="$work/nm" CMUX_SWIFT_DEMANGLE_TOOL="$work/demangle"

# make_app NAME [MAP_NAME...]: an app whose executable is cmux; with names, a cmux-symbols.bin holding them.
make_app() {
  local app="$work/$1.app"; shift
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  : >"$app/Contents/MacOS/cmux"
  python3 -I -c 'import plistlib, sys; plistlib.dump({"CFBundleExecutable": "cmux"}, open(sys.argv[1], "wb"))' \
    "$app/Contents/Info.plist"
  if [[ $# -gt 0 ]]; then
    python3 -I - "$app/Contents/Resources/cmux-symbols.bin" "$@" <<'PY'
import struct, sys, zlib
names = sys.argv[2:] + [""]  # the map ends with the unnamed end-of-__text entry
body = bytearray(struct.pack("<I", len(names)))
for delta in [0x100] * len(names):
    while True:
        byte, delta = delta & 0x7F, delta >> 7
        body.append(byte | (0x80 if delta else 0))
        if not delta:
            break
body += "\0".join(names).encode()
c = zlib.compressobj(9, zlib.DEFLATED, -15)
packed = c.compress(bytes(body)) + c.flush()
open(sys.argv[1], "wb").write(b"CMXSYM1\0" + struct.pack("<I", 1) + bytes(16) + struct.pack("<I", len(packed)) + packed)
PY
  fi
  printf '%s\n' "$app"
}

failures=0
# expect_exit WANT DESCRIPTION NM_OUTPUT_FILE ARGS...
expect_exit() {
  local want="$1" what="$2" nm_out="$3"; shift 3
  FAKE_NM_OUT="$nm_out" bash "$SCRIPT" "$@" >"$work/out.log" 2>&1
  local got=$?
  if [[ "$got" -eq "$want" ]]; then
    echo "ok: $what (exit $got)"
  else
    echo "FAIL: $what: exit $got, want $want"; sed 's/^/    /' "$work/out.log"
    failures=$((failures + 1))
  fi
}

printf '%s\n' \
  '0000000100001000 t _$s14CmuxNextCompat22BlockingViolationTableC6recordyyF' \
  '0000000100002000 T _main' >"$work/nm-detector.txt"
printf '%s\n' \
  '0000000100001000 t _$s11CmuxNextApp8AppStateC4loadyyF' \
  '0000000100002000 T _main' >"$work/nm-clean.txt"
printf '%s\n' \
  '0000000100000000 T __mh_execute_header' \
  '                 U _pthread_main_np' >"$work/nm-stripped.txt"

plain="$(make_app plain)"
expect_exit 0 "nightly app with detector symbols passes --expect nightly" "$work/nm-detector.txt" --app "$plain" --expect nightly
expect_exit 1 "nightly app with detector symbols fails --expect release" "$work/nm-detector.txt" --app "$plain" --expect release
expect_exit 1 "app without detector symbols fails --expect nightly" "$work/nm-clean.txt" --app "$plain" --expect nightly
expect_exit 0 "app without detector symbols passes --expect release" "$work/nm-clean.txt" --app "$plain" --expect release
expect_exit 2 "stripped app with no symbol map cannot be read (nightly)" "$work/nm-stripped.txt" --app "$plain" --expect nightly
expect_exit 2 "stripped app with no symbol map cannot be read (release)" "$work/nm-stripped.txt" --app "$plain" --expect release
FAKE_NM_FAIL=1 expect_exit 2 "nm failure is an error, never clean" "$work/nm-clean.txt" --app "$plain" --expect release
CMUX_SWIFT_DEMANGLE_TOOL="$work/demangle-broken" \
  expect_exit 2 "demangle failure is an error, never clean" "$work/nm-clean.txt" --app "$plain" --expect release

shipped="$(make_app shipped '$s14CmuxNextCompat22BlockingViolationTableC6recordyyF' 'main')"
expect_exit 0 "stripped nightly app: the symbol map shows the detector" "$work/nm-stripped.txt" --app "$shipped" --expect nightly
expect_exit 1 "stripped nightly app fails --expect release through the map" "$work/nm-stripped.txt" --app "$shipped" --expect release
shipped_clean="$(make_app shipped-clean '$s11CmuxNextApp8AppStateC4loadyyF' 'main')"
expect_exit 1 "stripped app whose map lacks the detector fails --expect nightly" "$work/nm-stripped.txt" --app "$shipped_clean" --expect nightly
expect_exit 0 "stripped app whose map lacks the detector passes --expect release" "$work/nm-stripped.txt" --app "$shipped_clean" --expect release
printf 'not a map' >"$work/broken.app.tmp"
broken="$(make_app broken)"; mv "$work/broken.app.tmp" "$broken/Contents/Resources/cmux-symbols.bin"
expect_exit 2 "an unreadable symbol map is an error" "$work/nm-stripped.txt" --app "$broken" --expect nightly

expect_exit 2 "--expect without --app" "$work/nm-clean.txt" --expect nightly
expect_exit 2 "--app without --expect" "$work/nm-clean.txt" --app "$plain"
expect_exit 2 "unknown --expect value" "$work/nm-clean.txt" --app "$plain" --expect debug
expect_exit 2 "--app with no value" "$work/nm-clean.txt" --expect nightly --app
expect_exit 2 "not an app bundle" "$work/nm-clean.txt" --app "$work/missing.app" --expect nightly

if [[ "$failures" -gt 0 ]]; then echo "$failures failed"; exit 1; fi
echo "all passed"
