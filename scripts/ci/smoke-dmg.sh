#!/usr/bin/env bash
# Launch-smoke the app inside a final, stapled DMG, in a job that holds no
# secrets. The signing and notarization jobs defer these smokes
# (CMUX_DEFER_LAUNCH_SMOKES=true) so no bundle code runs where a signing,
# notarization or publishing credential exists.
#
# Usage: smoke-dmg.sh <dmg> <channel> [--expect-sha256 HEX] [--require-stapled-app | --stapled-app-fallback ID]
# The app inside must carry its own ticket (notarize-nightly-dmg.sh
# CMUX_STAPLE_APP_IN_DMG); --require-stapled-app says so explicitly.
# --stapled-app-fallback ID: only for the 6 h fallback of notarize-nightly-dmg.sh
# (or resume-stapled-app-notarization.sh on main's track),
# which ships the first DMG because Apple has not accepted stapled-app
# submission ID: the app inside may then lack its own ticket (a warning).
# Writes "tested <sha256> <dmg name>" to fd 3 (or stdout), for the job that
# publishes it; everything else goes to stderr so the job log keeps it.
# A smoke that skips (an x86_64 app on a runner without Rosetta) is reported
# as a warning, as the in-job smokes did before.
set -euo pipefail
# Logs go to stderr. Only the final "tested" line goes to fd 3 when the caller
# opened it (smoke-dmg.sh ... 3>file), else to stdout.
if { true >&3; } 2>/dev/null; then
  exec 4>&3
else
  exec 4>&1
fi
exec 1>&2

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <dmg> <channel> [--expect-sha256 HEX] [--require-stapled-app | --stapled-app-fallback ID]" >&2
  exit 2
fi
DMG="$1"
CHANNEL="$2"
shift 2
EXPECTED=""
REQUIRE_STAPLED_APP=true
STAPLED_APP_FALLBACK_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --expect-sha256)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then echo "--expect-sha256 needs a value" >&2; exit 2; fi
      EXPECTED="$2"; shift 2 ;;
    --require-stapled-app) REQUIRE_STAPLED_APP=true; shift ;;
    --stapled-app-fallback)
      if [ "$#" -lt 2 ] || ! [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]]; then echo "--stapled-app-fallback needs the pending submission id" >&2; exit 2; fi
      STAPLED_APP_FALLBACK_ID="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HDIUTIL_TOOL="${CMUX_HDIUTIL_TOOL:-hdiutil}"
SPCTL_TOOL="${CMUX_SPCTL_TOOL:-spctl}"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
SMOKE_TOOL="${CMUX_SMOKE_TOOL:-$ROOT_DIR/scripts/smoke-launch-macos-app.sh}"
VERIFY_METADATA_TOOL="${CMUX_VERIFY_METADATA_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-channel-metadata.sh}"
VERIFY_LICENSES_TOOL="${CMUX_VERIFY_LICENSES_TOOL:-$ROOT_DIR/scripts/verify-app-bundle-licenses.sh}"
# shellcheck source=lib/signing-runtime-guard.sh
source "$ROOT_DIR/scripts/ci/lib/signing-runtime-guard.sh"
cmux_signing_runtime_guard

[ -f "$DMG" ] || { echo "DMG not found: $DMG" >&2; exit 1; }
actual="$(shasum -a 256 "$DMG" | awk '{print $1}')"
expected_lower="$(printf '%s' "$EXPECTED" | tr '[:upper:]' '[:lower:]')"
if [ -n "$EXPECTED" ] && [ "$actual" != "$expected_lower" ]; then
  echo "$DMG SHA-256 $actual does not match the expected $EXPECTED" >&2
  exit 1
fi

"$XCRUN_TOOL" stapler validate "$DMG"
MOUNT_DIR="$(mktemp -d)"
# The app the smoke launched leaves daemons (cmux-tui owners, the acpmux
# daemon, helper hosts) that run from the mount. A forced detach takes their
# executables away while they run; in run 39481846284 every step after the
# DMG smoke was then 10 to 100 times slower (bundle size 13 min, a one-file
# upload 8 min) and the verify job hit its 30-minute limit. Stop them right
# after the launches, and again before every detach (an error path):
# SIGTERM the exact PIDs of this user whose command runs from this mount,
# wait at most 5 s (kill -0, no new ps per check), then SIGKILL a listed PID
# that still runs from it.
mount_pids() {
  local real pid args
  real="$(cd -P "$MOUNT_DIR" 2>/dev/null && pwd)" || real="$MOUNT_DIR"
  ps -ww -o pid= -o args= -U "$(id -u)" 2>/dev/null | while read -r pid args; do
    case "$args" in
      *"$MOUNT_DIR/"* | *"$real/"*) echo "$pid" ;;
    esac
  done || true
}
stop_mount_processes() {
  local pids pid alive grace survivors
  pids="$(mount_pids)"
  [ -n "$pids" ] || return 0
  echo "SIGTERM to the processes still running from the DMG mount: $(echo $pids)"
  # shellcheck disable=SC2086 # one PID per word
  kill -TERM $pids 2>/dev/null || true
  grace=$((SECONDS + 5))
  while [ "$SECONDS" -lt "$grace" ]; do
    alive=""
    for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive="$alive $pid"; done
    [ -n "$alive" ] || break
    sleep 0.2
  done
  survivors=""
  for pid in $(mount_pids); do
    case " $(echo $pids) " in *" $pid "*) survivors="$survivors $pid" ;; esac
  done
  if [ -n "$survivors" ]; then
    echo "SIGKILL to the processes that outlived SIGTERM:$survivors"
    # shellcheck disable=SC2086
    kill -KILL $survivors 2>/dev/null || true
  fi
}
detach() {
  stop_mount_processes || true
  "$HDIUTIL_TOOL" detach "$MOUNT_DIR" >/dev/null 2>&1 \
    || "$HDIUTIL_TOOL" detach -force "$MOUNT_DIR" >/dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" 2>/dev/null || true
  rm -f "${SMOKE_LOG:-}"
}
trap detach EXIT
"$HDIUTIL_TOOL" attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_DIR"
APP="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' -type d -print -quit)"
[ -n "$APP" ] || { echo "No app found in $DMG" >&2; exit 1; }
if [ -n "$STAPLED_APP_FALLBACK_ID" ]; then
  if ! "$XCRUN_TOOL" stapler validate "$APP"; then
    echo "::warning title=App without its own ticket::the 6 h fallback ships the first DMG; stapled-app submission $STAPLED_APP_FALLBACK_ID is not accepted"
  fi
elif [ "$REQUIRE_STAPLED_APP" = true ]; then
  # The app carries its own ticket: a copy taken out of the DMG (Sparkle
  # installs one) needs no online ticket lookup.
  "$XCRUN_TOOL" stapler validate "$APP"
fi
"$SPCTL_TOOL" -a -vv --type execute "$APP"
SMOKE_LOG="$(mktemp)"
# The app must not inherit the fd that carries the tested line.
if [ "${CMUX_SKIP_LAUNCH_SMOKES:-false}" = true ]; then
  echo "launch smoke skipped by CMUX_SKIP_LAUNCH_SMOKES=true"
else
  CMUX_SMOKE_ALLOW_UNSUPPORTED_GUI=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP" 3>&- 4>&- 2>&1 | tee "$SMOKE_LOG"
  CMUX_SMOKE_DIRECT_EXEC=1 CMUX_SMOKE_DEBUG_LOGS=1 "$SMOKE_TOOL" "$APP" 3>&- 4>&- 2>&1 | tee -a "$SMOKE_LOG"
fi
# The launches are done; the checks below only read files. Stop the daemons
# the app left on the mount now: in run 39490194618 they ran on through the
# metadata and license checks, which then took 6.5 min instead of seconds.
stop_mount_processes || true
if grep -q '^SKIP: cannot smoke-launch' "$SMOKE_LOG"; then
  # The same policy the in-job smokes had: an x86_64 app on a runner without
  # Rosetta is an environment gap. The stapler, Gatekeeper, metadata and
  # license checks still ran on this exact DMG.
  echo "::warning::the launch smoke skipped $APP on this runner (no Rosetta); the static checks passed"
fi
"$VERIFY_METADATA_TOOL" "$APP" "$CHANNEL"
"$VERIFY_LICENSES_TOOL" "$APP"
detach
trap - EXIT

# The DMG must be byte-identical after the smoke (it was mounted read-only).
after="$(shasum -a 256 "$DMG" | awk '{print $1}')"
[ "$after" = "$actual" ] || { echo "$DMG changed during the smoke" >&2; exit 1; }
echo "tested $actual $(basename "$DMG")" >&4
