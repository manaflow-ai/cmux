#!/bin/bash
# A CEF pin before it is a release (plans/cmux-next/cef-layer-hosting-DESIGN.md; chrome-parity p01-process task 003).
#
#   cef-pin-staging.sh pin --arm64 JOB [--x86_64 JOB] [--rb-host-step STEP] [--min-api N] [--accept-missing-api N,N]
#                          [--fork-branch NAME]
#     Stages finished `cmux-ci build cef` jobs of one fork commit as scripts/cmux-next/cef-manifest.json, and with
#     --rb-host-step the remote browser host built against it as remote-browser-host.pin.json (required unless the
#     host pin already links the staged build). No R2 upload and no GitHub release: the pin names the fleet
#     artifacts by sha256, which the controller store serves for 14 days (cef_pin_staging.py has the checks). Both
#     files get a `staging` object, which ensure-cef.sh, ensure-remote-browser-host.sh and check-pinned-assets.sh
#     enforce: fleet builds only, no Release build, a hard failure after store_expires, and no landing on
#     feat-cmux-next or main. The fork's release train (task 178) replaces the pin. The steps:
#       cmux-ci build cef --arch arm64 --ref FORK_SHA --tag cef-stage-<sha12>-arm64        (and --arch x86_64)
#       cmux-ci run --class isolated --script scripts/ci/cmux-remote-browser-host-build.sh --ref <host source> \
#         --cef sha256:<arm64 artifact> --artifact .build/artifacts/cmux-remote-browser-host --arg=--build-only
#       scripts/cmux-next/cef-pin-staging.sh pin --arm64 A --x86_64 X --rb-host-step S
#
#   cef-pin-staging.sh [check]
#     The staging check of a tagged app built on the pin: cef-layer-verify.py with layer hosting off (window-server
#     images of the page, real CGEvents at the page's screen points; mode on needs a fork with every Track A call,
#     fork API 34, so a pin check runs it only by hand), the app's debug.cef fork API
#     against the manifest's cmux_cef_api_version and the app's fork API gates against its missing_api (fork-api),
#     then the Chromium page live checks (internal pages, restore). Run inside
#       nx-remote --needs input --app-from-fleet cmux --tag T --ref SHA -- bash scripts/cmux-next/cef-pin-staging.sh
#     or through the allowlisted fleet entry: split-spring.sh --arg=--suite=cef-pin-staging.
#     STAGING_PARTS=verify,api,internal,restore picks parts (a baseline of the current pin runs internal,restore);
#     VERIFY_INPUT=debug sends debug.mouse/debug.key instead (proves nothing about the page window's input).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
case "${1:-check}" in
  pin) shift; exec python3 "$here/cef_pin_staging.py" pin "$@" ;;
  check) ;;
  *) echo "usage: cef-pin-staging.sh pin --arm64 JOB [...] | cef-pin-staging.sh [check]" >&2; exit 2 ;;
esac

out="$NX_ARTIFACTS/staging"; mkdir -p "$out"
parts=",${STAGING_PARTS:-verify,api,internal,restore},"
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
  for m in off; do
    run "verify-$m" python3 "$here/cef-layer-verify.py" --app "$NX_APP" --tag "$NX_APP_TAG" --out "$out/verify" \
      --mode $m --input "${VERIFY_INPUT:-hid}"
  done
fi
if [[ "$parts" == *",api,"* ]]; then
  # The fork API the app runs, from the layer-hosting check's debug.cef facts (its hosted rows alone when the
  # verify part did not run).
  if [[ ! -f "$out/verify/verify-off.json" ]]; then
    run api-launch python3 "$here/cef-layer-verify.py" --app "$NX_APP" --tag "$NX_APP_TAG" --out "$out/verify" \
      --mode off --checks hosted --input debug
  fi
  run fork-api python3 "$here/cef_pin_staging.py" fork-api --verify "$out/verify/verify-off.json"
fi
[[ "$parts" == *",internal,"* ]] && run internal python3 "$here/chrome-internal-pages-live.py" --tag "$NX_APP_TAG" --app "$NX_APP" --out "$out/internal"
[[ "$parts" == *",restore,"* ]] && run restore python3 "$here/browser-restore-live.py" --tag "$NX_APP_TAG" --app "$NX_APP" --out "$out/restore"
echo "staging rc=$rc"
exit $rc
