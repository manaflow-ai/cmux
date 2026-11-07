#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Run the deterministic tiers on a disposable Linux VM (Debian/Ubuntu, root):
# installs Xvfb, Tk, a small window manager and the AT-SPI bus, starts display :99,
# then runs the self-test and the tool tier for each arm given.
#
#   scripts/linux-xvfb.sh [ARM ...]        (default: cua-driver-0.38.0)
#
# Writes everything under ${ARTIFACTS_DIR:-out}. Never run it on a person's desktop.
set -uo pipefail
cd "$(dirname "$0")/.."
out="${ARTIFACTS_DIR:-$PWD/out}"
mkdir -p "$out"
arms=("$@")
[ ${#arms[@]} -gt 0 ] || arms=(cua-driver-0.38.0)

if ! command -v Xvfb >/dev/null || ! python3 -c 'import tkinter' 2>/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq xvfb python3-tk openbox dbus-x11 at-spi2-core x11-utils >/dev/null
fi

export DISPLAY=:99
Xvfb :99 -screen 0 1280x900x24 -nolisten tcp >"$out/xvfb.log" 2>&1 &
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done
eval "$(dbus-launch --sh-syntax)"
/usr/libexec/at-spi-bus-launcher --launch-immediately >/dev/null 2>&1 &
openbox >"$out/openbox.log" 2>&1 &

status=0
# cmux-cu: its bridge asks a cmux daemon for the worker, so start one in this
# display's session. CMUX_CU_HEADLESS=0: the person_undisturbed case puts a
# person on this Xvfb display, so cmux must not take the headless shortcut
# (XTest, which moves the real pointer and focus) it would on an unwatched one.
if [[ " ${arms[*]} " == *" cmux-cu "* ]]; then
  CMUX_CU_HEADLESS=0 cmux server ensure >"$out/cmux-daemon.txt" 2>&1 || status=1
fi
# The baseline's own switch for its default telemetry: an eval VM sends nothing.
if [ -n "${CUEVAL_CUA_DRIVER_BIN:-}" ] || bin=$(python3 -I arms/resolve_cua_driver.py fetch 2>/dev/null | tail -1); then
  "${CUEVAL_CUA_DRIVER_BIN:-$bin}" telemetry disable >/dev/null 2>&1 || true
fi
python3 -m cueval selftest --out "$out/selftest" 2>&1 | tee "$out/selftest.txt" || status=1
for arm in "${arms[@]}"; do
  python3 -m cueval tools --arm "$arm" --out "$out/tools" 2>&1 | tee "$out/tools-$arm.txt" || status=1
done
cp "$out/selftest/agent/report.html" "$out/selftest-report.html" 2>/dev/null || true
exit $status
