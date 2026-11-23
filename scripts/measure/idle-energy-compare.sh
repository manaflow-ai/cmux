#!/usr/bin/env bash
# Idle energy of cmux NEXT, Claude Code desktop and Terminal.app on one Mac, same conditions (cmuxterm-hq#14069).
# Downloads the newest cmux NEXT NIGHTLY and the current Claude desktop DMG, copies each app to a private folder
# (so only its own processes match its bundle path), then runs idle-energy-compare.py: a calibration window
# (no app; a known-active control), then ROUNDS interleaved rounds of one SECONDS idle window per app, each app
# launched from a fresh, signed-out profile and settled SETTLE seconds first. Records CPU energy (mW), CPU % and
# wakeups/s per window, with baseline counters read at each window's start (cmuxterm-hq#19931).
#   cmux-ci run --class exclusive --measurement --display \
#     --script scripts/measure/idle-energy-compare.sh --ref <sha> [--arg=rounds=3] [--arg=seconds=60] \
#     [--arg=settle=60] [--arg=calibrate=60] [--arg=next_dmg=URL] [--arg=claude_dmg=URL] [--arg=apps=next,claude,terminal] \
#     --artifact artifacts/idle-energy-compare.tgz --timeout 3600
# Registered as the `idle-compare` bench (scripts/bench/benches/idle_compare.py; --import reads the log).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
root="$PWD"
rounds=3 seconds=60 settle=60 calibrate=60 apps=next,claude,terminal
next_dmg="" claude_dmg=""
feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
# claude.ai answers this redirect to an app-like user agent only (a browser or curl one gets a 403 challenge).
claude_latest="https://claude.ai/api/desktop/darwin/universal/dmg/latest/redirect"
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    seconds=*) seconds="${arg#seconds=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    calibrate=*) calibrate="${arg#calibrate=}" ;;
    apps=*) apps="${arg#apps=}" ;;
    next_dmg=https://*) next_dmg="${arg#next_dmg=}" ;;
    claude_dmg=https://*) claude_dmg="${arg#claude_dmg=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
for n in "$rounds" "$seconds" "$settle" "$calibrate"; do [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "not a positive integer: $n" >&2; exit 2; }; done
(( rounds >= 3 && seconds <= 600 && settle <= 600 && calibrate <= 600 )) || { echo "rounds >= 3; seconds, settle, calibrate <= 600" >&2; exit 2; }
[[ "$apps" =~ ^(next|claude|terminal)(,(next|claude|terminal))*$ ]] || { echo "apps: a comma list of next, claude, terminal" >&2; exit 2; }

mkdir -p artifacts
out="$(mktemp -d "$root/artifacts/idle-energy-compare.XXXXXX")"
work="$(mktemp -d "${TMPDIR:-/tmp}/idle-energy-compare.XXXXXX")"
cleanup() {
  rm -rf "$work"
  tar -czf "$root/artifacts/idle-energy-compare.tgz" -C "$out" . 2>/dev/null || true
  rm -rf "$out"
}
trap cleanup EXIT
echo "IDLE-COMPARE host $(hostname -s) macOS $(sw_vers -productVersion) $(uname -m)"

# The app inside DMG URL, copied to $work/NAME/ (ditto keeps the signature); prints the copy's path. Runs in a
# command substitution, so it detaches its own mount on every path.
fetch_app() {
  local name="$1" url="$2" ua="$3" mount="$work/mnt-$1" app status=0
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A "$ua" -o "$work/$name.dmg" "$url" || { echo "IDLE-COMPARE $name download failed: $url" >&2; return 3; }
  mkdir -p "$mount" "$work/$name"
  hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mount" "$work/$name.dmg" >/dev/null || { echo "IDLE-COMPARE $name mount failed" >&2; return 3; }
  app="$(ls -d "$mount"/*.app 2>/dev/null | head -n 1)"
  if [[ ! -d "$app" ]]; then
    echo "IDLE-COMPARE $name: no .app in the DMG" >&2; status=3
  elif ! ditto "$app" "$work/$name/${app##*/}"; then
    echo "IDLE-COMPARE $name: copy failed" >&2; status=3
  fi
  hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true
  rm -f "$work/$name.dmg"
  [[ "$status" == 0 ]] && echo "$work/$name/${app##*/}"
  return "$status"
}

args=()
IFS=, read -r -a wanted <<<"$apps"
for name in "${wanted[@]}"; do
  case "$name" in
    next)
      if [[ -z "$next_dmg" ]]; then
        next_dmg="$(curl -fsSL --retry 3 --retry-all-errors -H 'Cache-Control: no-cache' "$feed" | grep -o -E 'enclosure url="https://[^"]+\.dmg"' | head -n 1 | cut -d'"' -f2)"
        [[ -n "$next_dmg" ]] || { echo "IDLE-COMPARE no DMG in $feed"; exit 3; }
      fi
      echo "IDLE-COMPARE next dmg $next_dmg"
      app="$(fetch_app next "$next_dmg" cmux-idle-energy/1)" || exit 3 ;;
    claude)
      if [[ -z "$claude_dmg" ]]; then
        claude_dmg="$(curl -fsS -o /dev/null -w '%{redirect_url}' -A 'Claude/1.0 Electron' "$claude_latest")"
        [[ "$claude_dmg" == https://downloads.claude.ai/* ]] || { echo "IDLE-COMPARE could not resolve the Claude desktop DMG ($claude_latest)"; exit 3; }
      fi
      echo "IDLE-COMPARE claude dmg $claude_dmg"
      app="$(fetch_app claude "$claude_dmg" 'Claude/1.0 Electron')" || exit 3 ;;
    terminal)
      app=/System/Applications/Utilities/Terminal.app
      [[ -d "$app" ]] || { echo "IDLE-COMPARE no $app"; exit 3; } ;;
  esac
  args+=(--app "$name=$app")
done

python3 -I scripts/measure/idle-energy-compare.py ${args[@]+"${args[@]}"} --rounds "$rounds" --seconds "$seconds" \
  --settle "$settle" --calibrate "$calibrate" --out "$out" 2>&1 | tee "$out/run.log"
exit "${PIPESTATUS[0]}"
