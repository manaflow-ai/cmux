#!/usr/bin/env bash
# scripts/ios-live/linux.sh (ios-live on a Linux phone) against a fake `agent-sim` on PATH: `take` holds a pooled
# phone once and keeps it; `swap` unpacks a .app or an ios-sim-build tarball, installs it, relaunches it with the
# slot's launch env and returns only once the app is in front with its own elements; a build that never draws fails;
# `release` gives the phone back to the pool. And the client: IOS_LIVE_LINUX=local routes ios-live to it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINUX_SH="$ROOT_DIR/scripts/ios-live/linux.sh"
CLIENT="$ROOT_DIR/scripts/ios-live/ios-live"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" IOS_LIVE_ROOT="$WORK/home/ios-live-linux" FAKE_LOG="$WORK/calls.log" FAKE_DIR="$WORK/fake"
mkdir -p "$HOME" "$WORK/bin" "$FAKE_DIR"
: >"$FAKE_LOG"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# agent-sim: records every call; `launch` puts the app in front unless FAKE_NEVER_DRAWS is set.
cat >"$WORK/bin/agent-sim" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
dev=""
if [[ "${1:-}" == --device ]]; then dev="$2"; shift 2; fi
case "$1" in
  pool) case "$2" in take) echo pool2 ;; release) : ;; esac ;;
  up) : ;;
  install) [[ -f "$2/Info.plist" ]] || { echo "not an app: $2" >&2; exit 1; } ;;
  terminate) rm -f "$FAKE_DIR/front" ;;
  launch) shift; b="${@: -1}"; [[ -n "${FAKE_NEVER_DRAWS:-}" ]] || echo "$b" >"$FAKE_DIR/front" ;;
  snapshot) if [[ -f "$FAKE_DIR/front" ]]; then echo "app $(cat "$FAKE_DIR/front")"; echo '@e1 button "Sign in" (200,400)'
            else echo "app com.apple.springboard"; fi ;;
  screenshot) printf 'PNG' >"$3" ;;
  *) echo "fake agent-sim: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/agent-sim"
export PATH="$WORK/bin:$PATH"

make_app() {  # make_app DIR BUNDLE
  mkdir -p "$1/CmuxMobileApp.app"
  python3 -I -c 'import plistlib,sys; plistlib.dump({"CFBundleIdentifier": sys.argv[2], "CFBundleExecutable": "CmuxMobileApp"}, open(sys.argv[1], "wb"))' \
    "$1/CmuxMobileApp.app/Info.plist" "$2"
  printf 'binary-%s' "$2" >"$1/CmuxMobileApp.app/CmuxMobileApp"
}

phone="$(bash "$LINUX_SH" take)"
[[ "$phone" == pool2 ]] || fail "take gave $phone, want pool2"
again="$(bash "$LINUX_SH" take)"
[[ "$again" == pool2 ]] || fail "a second take gave $again"
[[ "$(grep -c '^pool take' "$FAKE_LOG")" == 1 ]] || fail "take asked the pool twice"
pass "take holds one pooled phone and keeps it"

make_app "$WORK/a" com.cmuxterm.next.ios
printf 'CMUX_TARGET=dev\n# comment\n\n' >"$IOS_LIVE_ROOT/launch.env"
bash "$LINUX_SH" swap "$WORK/a/CmuxMobileApp.app" >"$WORK/out.json" || fail "swap of a .app failed"
python3 -I - "$IOS_LIVE_ROOT/state.json" <<'PY' || fail "state.json after swap"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["phone"] == "pool2" and d["bundle_id"] == "com.cmuxterm.next.ios", d
for k in ("unpack_ms", "install_ms", "launch_ms", "first_frame_ms", "total_ms"):
    assert isinstance(d[k], int) and d[k] >= 0, (k, d)
PY
grep -q -- '--device pool2 launch --env CMUX_TARGET=dev com.cmuxterm.next.ios' "$FAKE_LOG" || fail "launch env not passed: $(cat "$FAKE_LOG")"
grep -q -- '--device pool2 terminate com.cmuxterm.next.ios' "$FAKE_LOG" || fail "no terminate before launch"
pass "swap of a .app installs, relaunches with launch.env and records timings"

mkdir -p "$WORK/t/Products/Debug-iphonesimulator"
make_app "$WORK/t/Products/Debug-iphonesimulator" com.cmuxterm.next.ios.b
mkdir -p "$WORK/t/Products/Debug-iphonesimulator/CmuxMobileAppUITests-Runner.app"
tar -C "$WORK/t" -czf "$WORK/ios-sim-build.tar.gz" Products
bash "$LINUX_SH" swap "$WORK/ios-sim-build.tar.gz" >/dev/null || fail "swap of a tarball failed"
[[ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundle_id"])' "$IOS_LIVE_ROOT/state.json")" == com.cmuxterm.next.ios.b ]] \
  || fail "tarball swap installed the wrong app"
pass "swap of an ios-sim-build tarball picks CmuxMobileApp.app, not the UI test runner"

if FAKE_NEVER_DRAWS=1 IOS_LIVE_VISIBLE_S=1 bash "$LINUX_SH" swap "$WORK/a/CmuxMobileApp.app" >/dev/null 2>"$WORK/err"; then
  fail "a build that never reaches the screen passed"
fi
grep -q "never reached the screen" "$WORK/err" || fail "wrong error: $(cat "$WORK/err")"
pass "a build that never draws fails within its bound"

out="$(IOS_LIVE_LINUX=local bash "$CLIENT" swap "$WORK/a/CmuxMobileApp.app")" || fail "client swap failed"
grep -q "end to end" <<<"$out" || fail "client printed no end-to-end time: $out"
IOS_LIVE_LINUX=local bash "$CLIENT" shot "$WORK/s.png" >/dev/null && [[ -s "$WORK/s.png" ]] || fail "client shot"
pass "IOS_LIVE_LINUX=local routes swap and shot to linux.sh"

bash "$LINUX_SH" release >/dev/null
grep -q '^pool release pool2' "$FAKE_LOG" || fail "release did not give the phone back"
[[ ! -f "$IOS_LIVE_ROOT/phone" ]] || fail "release kept the phone"
pass "release gives the phone back to the pool"
