#!/bin/bash
# Staging check of a new CEF pin before it lands (plans/cmux-next/cef-layer-hosting-DESIGN.md): cef-layer-verify.py
# with layer hosting on and off, then Chromium page live checks (internal pages, restore). Run inside
#   nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- bash scripts/cmux-next/cef-pin-staging.sh
# VERIFY_INPUT=hid (with nx-remote --needs input) sends real HID events instead of debug.mouse/debug.key.
set -u
out="$NX_ARTIFACTS/staging"; mkdir -p "$out"
rc=0
run() { echo "== $*"; "$@" > "$out/$1-$(date +%s).log" 2>&1; local c=$?; echo "   exit $c"; tail -25 "$out/$1-"*.log | grep -E "PASS|FAIL|ok|error" | tail -12; [ $c -eq 0 ] || rc=1; }
for m in on off; do
  echo "== cef-layer-verify mode=$m input=${VERIFY_INPUT:-debug}"
  python3 scripts/cmux-next/cef-layer-verify.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$out/verify" --mode $m --input "${VERIFY_INPUT:-debug}" 2>&1 | grep -E "PASS|FAIL"
  [ ${PIPESTATUS[0]} -eq 0 ] || rc=1
done
if [ "${VERIFY_INPUT:-debug}" = debug ]; then
  run python3 scripts/cmux-next/chrome-internal-pages-live.py --tag "$NX_APP_TAG" --app "$NX_APP" --out "$out/internal"
  run python3 scripts/cmux-next/browser-restore-live.py --tag "$NX_APP_TAG" --app "$NX_APP" --out "$out/restore"
fi
echo "staging rc=$rc"
exit $rc
