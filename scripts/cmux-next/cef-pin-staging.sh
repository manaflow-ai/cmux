#!/bin/bash
# Staging check of a new CEF pin before it lands (plans/cmux-next/cef-layer-hosting-DESIGN.md): cef-layer-verify.py
# with layer hosting on and off (window-server images of the page, real CGEvents at the page's screen points), then
# the Chromium page live checks (internal pages, restore). Run inside
#   nx-remote --needs input --app-from-fleet cmux --tag T --ref SHA -- bash scripts/cmux-next/cef-pin-staging.sh
# or through the allowlisted fleet entry: split-spring.sh --arg=--suite=cef-pin-staging.
# STAGING_PARTS=verify,internal,restore picks parts (a baseline of the current pin runs internal,restore);
# VERIFY_INPUT=debug sends debug.mouse/debug.key instead (proves nothing about the page window's input).
set -u
out="$NX_ARTIFACTS/staging"; mkdir -p "$out"
parts=",${STAGING_PARTS:-verify,internal,restore},"
rc=0
run() { # <name> <command...>: its log in $out/<name>.log, the PASS/FAIL rows, and its last lines when it fails
  local name=$1; shift
  echo "== $name: $*"
  "$@" > "$out/$name.log" 2>&1; local c=$?
  grep -E "^(PASS|FAIL|ok  |FAIL )" "$out/$name.log" | cut -c1-220
  echo "   exit $c"
  if [ $c -ne 0 ]; then echo "   -- last lines of $name.log:"; tail -n 25 "$out/$name.log" | cut -c1-220 | sed 's/^/   | /'; rc=1; fi
}
if [[ "$parts" == *",verify,"* ]]; then
  for m in on off; do
    run "verify-$m" python3 scripts/cmux-next/cef-layer-verify.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$out/verify" \
      --mode $m --input "${VERIFY_INPUT:-hid}"
  done
fi
[[ "$parts" == *",internal,"* ]] && run internal python3 scripts/cmux-next/chrome-internal-pages-live.py --tag "$NX_APP_TAG" --app "$NX_APP" --out "$out/internal"
[[ "$parts" == *",restore,"* ]] && run restore python3 scripts/cmux-next/browser-restore-live.py --tag "$NX_APP_TAG" --app "$NX_APP" --out "$out/restore"
echo "staging rc=$rc"
exit $rc
