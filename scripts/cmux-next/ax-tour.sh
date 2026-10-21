#!/usr/bin/env bash
# Computer-use tour of a tagged cmux-next DEV app through the accessibility API only
# (ax-tour.swift): find controls by `cmux.<area>.<control>` identifiers, press them with AXPress,
# screenshot the app's window after each step, and check each result in the AX tree.
#
#   scripts/cmux-next/ax-tour.sh --tag TAG [--out DIR] [--steps new-workspace,new-tab,...]
#   scripts/cmux-next/ax-tour.sh --app "/path/cmux DEV TAG.app" [--out DIR]   # launches it, quits it after
#   scripts/cmux-next/ax-tour.sh --tag TAG --dump                              # print the AX tree, act on nothing
#
# --tag targets a running tagged build (com.cmuxterm.app.debug.<tag>, from reload.sh --tag TAG).
# --app launches that tagged bundle hidden (open -n -g), runs the tour, and quits only the pid it
# launched. Any bundle id that is not com.cmuxterm.app.debug.<tag> is refused, so the user's cmux,
# NIGHTLY, RC or an untagged DEV app is never read or driven.
#
# The host needs the Accessibility grant for AXPress (and Screen Recording for screenshots; the
# tour still runs and records the screenshot problem without it; $NX_CAPTURE is used when set).
# On the GUI build host, which launches and stops the app itself:
#   nx-remote --needs gui --app-from-fleet cmux --tag TAG --ref SHA -- \
#     'open -n --env ACPMUX_AGENT_LAUNCH=deny --env NX_REMOTE=1 "$NX_APP"; sleep 10;
#      scripts/cmux-next/ax-tour.sh --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/ax-tour"; rc=$?; "$NX_APP_STOP"; exit $rc'
# Exit status: 0 every step passed, 1 a step failed, 2 refused target or missing grant.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tag="" app="" out="" pass=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) tag="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) pass+=("$1"); shift ;;
  esac
done

bundle_id=""
if [ -n "$app" ]; then
  [ -d "$app" ] || { echo "ax-tour: no app at $app" >&2; exit 2; }
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
elif [ -n "$tag" ]; then
  # The same bundle segment reload.sh derives from a tag (scripts/lib/mobile-attach.sh).
  source "$here/../lib/mobile-attach.sh"
  bundle_id="$(cmux_attach_mac_bundle_id "$tag")"
else
  echo "usage: ax-tour.sh --tag TAG | --app PATH [--out DIR] [--steps a,b] [--dump]" >&2
  exit 2
fi
case "$bundle_id" in
  com.cmuxterm.app.debug.?*) ;;
  *) echo "ax-tour: refusing $bundle_id: only a tagged debug build (com.cmuxterm.app.debug.<tag>)" >&2; exit 2 ;;
esac

build="${TMPDIR:-/tmp}/cmux-ax-tour"
mkdir -p "$build"
if [ ! -x "$build/ax-tour" ] || [ "$here/ax-tour.swift" -nt "$build/ax-tour" ]; then
  swiftc -O -o "$build/ax-tour" "$here/ax-tour.swift"
fi

out="${out:-$(mktemp -d "${TMPDIR:-/tmp}/ax-tour.XXXXXX")}"
launched_pid=""
cleanup() {
  if [ -n "$launched_pid" ]; then kill "$launched_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

if [ -n "$app" ]; then
  if pgrep -f "$app/Contents/MacOS/" >/dev/null; then
    echo "ax-tour: $app is already running; pass --tag to tour it without relaunching" >&2
    exit 2
  fi
  open -n -g "$app"
  for _ in $(seq 1 300); do
    launched_pid="$(pgrep -nf "$app/Contents/MacOS/" || true)"
    [ -n "$launched_pid" ] && break
    sleep 0.1
  done
  [ -n "$launched_pid" ] || { echo "ax-tour: $app did not start" >&2; exit 2; }
  # The tour's first step waits for its own control; give the window time to appear.
  sleep 5
fi

# On the GUI build host the job has no Screen Recording grant of its own; its capture helper has.
capture=()
if [ -n "${NX_CAPTURE:-}" ]; then capture=(--capture-helper "$NX_CAPTURE"); fi

"$build/ax-tour" --bundle-id "$bundle_id" --out "$out" ${capture[@]+"${capture[@]}"} ${pass[@]+"${pass[@]}"}
