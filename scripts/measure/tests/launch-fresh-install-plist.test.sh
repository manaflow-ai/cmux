#!/usr/bin/env bash
# The capture in first() must preserve the measured app's identity, and a failed copy
# must fail that launch without preventing the next launch from retrying it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/scripts/measure" "$root/scripts/ci/lib"
cp "$here/launch-fresh-install.sh" "$here/launch-premain.sh" "$root/scripts/measure/"
echo 'cmux_signing_runtime_guard() { return 0; }' >"$root/scripts/ci/lib/signing-runtime-guard.sh"

out="$root/out"
mkdir -p "$out"
: >"$out/app.dmg"
env -u RUNNER_TEMP OUT="$out" LF_DIR="$root/scripts/measure" CUA="" bash -c '
  source "$LF_DIR/launch-fresh-install.sh"
  hdiutil() {
    if [[ "$1" == attach ]]; then
      mkdir -p "$7/Test.app/Contents"
      printf "%s\n" "<?xml version=\"1.0\"?><plist><dict><key>CFBundleVersion</key><string>test</string></dict></plist>" \
        >"$7/Test.app/Contents/Info.plist"
    fi
  }
  ditto() { cp -R "$1" "$2"; }
  console() {
    case "$*" in
      *launch-premain*) echo "LP-RUN {\"start\":1,\"main_start\":2,\"window_display_done\":3,\"window_usable\":4}" ;;
      *) "$@" ;;
    esac
  }
  quarantine() { :; }
  marker_refresh() { :; }
  checker_cpu() { echo "user=0 system=0"; }
  cpu_delta() { echo 0; }
  qattr() { echo "-"; }
  now_ms() { echo 1; }
  load1() { echo 0; }
  fresh_keychain() { :; }
  sweep_prompts() { :; }
  ps() { return 1; }
  sudo() { return 1; }
  sysctl() { echo 0; }
  sw_vers() { echo 26.0; }
  launchctl() { echo Aqua; }
  cp() {
    if [[ "${2:-}" == "$OUT/Info.plist" && ! -e "$OUT/allow-plist-copy" ]]; then
      : >"$OUT/allow-plist-copy"
      return 1
    fi
    command cp "$@"
  }
  rc=0
  first n 1 || rc=$?
  [[ "$rc" == 1 && -e "$OUT/allow-plist-copy" && ! -e "$OUT/Info.plist" ]] || {
    echo "first launch did not report the plist-copy failure: rc=$rc" >&2
    exit 1
  }
  rc2=0
  first n 2 || rc2=$?
  [[ "$rc2" == 0 ]] || {
    echo "retry launch failed: rc=$rc2" >&2
    exit 1
  }
  grep -q "<key>CFBundleVersion</key>" "$OUT/Info.plist"
'
echo "launch-fresh-install plist: ok"
