#!/usr/bin/env bash
# Measurement only (cmuxterm-hq#7111 track 4); not landed. A fleet ci-step runs it only from the
# controller's reviewed list (measureScripts), so until then apply-nightly / apply-dev rows are
# CLASSIFIER-ONLY.
#
# Times, on a fleet display Mac, "select a PR" to "usable changed pixels" when the PR's change is
# applied into an already-built NIGHTLY or DEV app instead of waiting for a new DEV build. The step's
# checkout is the PR head; BASE is its merge base with feat-cmux-next.
#
#   cmux-ci run --class exclusive --display --script scripts/measure/try-pr-apply.sh --ref HEAD \
#     --arg=--kind=nightly|dev --arg=--app-zip=URL_OR_PATH --arg=--base=SHA --artifact OUT/result.json
#
# Phases, each timed apart (result.json "phases", seconds):
#   fetch     download and unzip the prebuilt app (setup: amortized when the app is already installed)
#   side      make a side instance of it (#35544's side-instance.sh mechanics, inlined here so the
#             script is self-contained): own bundle id, config, overlay; setup, amortized per app
#   verdict   live_apply.py BASE HEAD
#   compile   web-live only: build-web-bundles.sh --out-root (the changed component; claim 2)
#   apply     web-overlay.sh install into the side instance's overlay, the toggle on through
#             CMUX_NEXT_DEBUG_TUNABLES_FILE ({"webDev.override": true}); a launch on first apply
#   pixels    screencapture of the app's window before and after; "changed" compares them
# Anything that is not web-live (swift-live, daemon, rebuild) is a fallback row: no Swift live patch
# into the app exists, so it records the verdict and stops (claim 1 not met, claim 2 not implemented).
# No path here is zero-compile (claim 3): the overlay is a Vite build.
set -euo pipefail
kind="" app_zip="" base=""
for a in "$@"; do
  case "$a" in
    --kind=*) kind="${a#*=}" ;; --app-zip=*) app_zip="${a#*=}" ;; --base=*) base="${a#*=}" ;;
    *) echo "usage: try-pr-apply.sh --kind=nightly|dev --app-zip=URL|PATH --base=SHA" >&2; exit 2 ;;
  esac
done
[[ "$kind" == nightly || "$kind" == dev ]] && [[ -n "$app_zip" && "$base" =~ ^[0-9a-f]{40}$ ]] || { echo "try-pr-apply: bad arguments" >&2; exit 2; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
head="$(git -C "$root" rev-parse HEAD)"
out="$root/artifacts/try-pr-apply"; mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/try-pr-apply.XXXXXX")"; work="$(cd "$work" && pwd -P)"
pid=""
cleanup() { [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
declare -A t
mark() { t[$1]=$(now); }
result() { # STATUS FALLBACK
  python3 - "$out/result.json" "$1" "$2" "$kind" "$base" "$head" "$verdict" "$changed" <<PY
import json, sys
out, status, fallback, kind, base, head, verdict, changed = sys.argv[1:]
t = {$(for k in "${!t[@]}"; do printf '"%s": %s, ' "$k" "${t[$k]}"; done)}
pairs = [("fetch", "select", "fetched"), ("side", "fetched", "sided"), ("verdict", "sided", "verdicted"),
         ("launch", "verdicted", "compiled_start"), ("compile", "compiled_start", "compiled"), ("apply", "compiled", "applied"), ("pixels", "applied", "drawn")]
phases = {n: round(t[b] - t[a], 2) for n, a, b in pairs if a in t and b in t}
json.dump({"kind": kind, "base": base, "head": head, "verdict": verdict, "status": status,
           "fallback": fallback or None, "changed_pixels": changed or None, "phases": phases,
           "select_to_pixels_s": round(t["drawn"] - t["select"], 2) if "drawn" in t else None,
           "compile_checked": "pass" if "compiled" in t else "not_run",
           "runtime": "pass" if changed == "yes" else ("fail" if changed == "no" else "not_run")},
          open(out, "w"), indent=1)
print(open(out).read())
PY
}
verdict="" changed=""

mark select
# fetch: the prebuilt app.
if [[ "$app_zip" =~ ^https:// ]]; then curl -fsSL -o "$work/app.zip" "$app_zip"; else cp "$app_zip" "$work/app.zip"; fi
ditto -x -k "$work/app.zip" "$work/unzipped"
src="$(find "$work/unzipped" -maxdepth 2 -name '*.app' -type d | head -1)"
[[ -n "$src" ]] || { echo "try-pr-apply: no .app in $app_zip" >&2; exit 1; }
mark fetched

# side: a copy with its own id, config and overlay (side-instance.sh make, condensed).
side="$work/side"; mkdir -p "$side/config" "$side/web-overlay"
app="$side/cmux try.app"; ditto "$src" "$app"
plist="$app/Contents/Info.plist"; buddy=/usr/libexec/PlistBuddy
orig_id="$($buddy -c 'Print :CFBundleIdentifier' "$plist")"
# A nightly keeps its prefix (WebDevOverride.isAvailable accepts com.cmuxterm.app.nightly.*); the DEV
# id must stay exact, so a DEV copy keeps its id and runs alone on the step's host.
[[ "$kind" == nightly ]] && $buddy -c "Set :CFBundleIdentifier $orig_id.side-try" "$plist"
printf '{"version": 1, "values": {"webDev.override": true}}\n' > "$side/config/debug-tunables.json"
$buddy -c "Add :LSEnvironment dict" "$plist" 2>/dev/null || true
for kv in "CMUX_NEXT_CONFIG_FILE=$side/config/cmux-next.json" "CMUX_WEB_OVERLAY_DIR=$side/web-overlay" \
          "CMUX_NEXT_DEBUG_TUNABLES_FILE=$side/config/debug-tunables.json"; do
  $buddy -c "Delete :LSEnvironment:${kv%%=*}" "$plist" 2>/dev/null || true
  $buddy -c "Add :LSEnvironment:${kv%%=*} string ${kv#*=}" "$plist"
done
codesign --force --sign - --deep "$app" >/dev/null 2>&1
mark sided

verdict="$(python3 "$root/scripts/cmux-next/live_apply.py" --repo "$root" --json "$base" "$head" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')"
mark verdicted
case "$verdict" in
  web-live) ;;
  no-app|ios-only) result skipped "nothing in the Mac app changes"; exit 0 ;;
  *) result fallback "$verdict: needs a new binary (no live Swift or daemon apply into the app)"; exit 0 ;;
esac

# Before pixels: the prebuilt app, bundled UI.
open -g -n "$app"
for _ in $(seq 1 300); do pid="$(pgrep -nf "$app/Contents/MacOS/" || true)"; [[ -n "$pid" ]] && break; sleep 0.1; done
[[ -n "$pid" ]] || { result fail "the side instance did not start"; exit 1; }
window_shot() { # FILE: the app's frontmost window by its pid
  local id; id="$(python3 -c '
import sys, Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
    if w.get("kCGWindowOwnerPID") == int(sys.argv[1]) and w.get("kCGWindowLayer") == 0:
        print(w["kCGWindowNumber"]); break' "$pid")"
  [[ -n "$id" ]] && screencapture -x -o -l "$id" "$1"
}
for _ in $(seq 1 300); do window_shot "$out/before.png" && break; sleep 0.1; done

mark compiled_start
"$root/scripts/cmux-next/build-web-bundles.sh" --force --out-root "$work/web"
mark compiled
CMUX_WEB_OVERLAY_DIR="$side/web-overlay" CMUX_NEXT_CONFIG_FILE="$side/config/cmux-next.json" \
  "$root/scripts/cmux-next/web-overlay.sh" install "$work/web"
mark applied
# The watcher reloads every page on the manifest; take shots until the window differs (60 s cap).
# Known weakness before landing: PNG bytes can differ for the same pixels (live-code-shell.sh judges a
# rendered width instead), so "changed" needs a pixel diff or a PR-specific probe to be trusted.
for _ in $(seq 1 600); do
  window_shot "$out/after.png" || { sleep 0.1; continue; }
  if ! cmp -s "$out/before.png" "$out/after.png"; then changed=yes; break; fi
  sleep 0.1
done
[[ -n "$changed" ]] || changed=no
mark drawn
result ok ""
