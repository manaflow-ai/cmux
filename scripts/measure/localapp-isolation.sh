#!/usr/bin/env bash
# SPIKE, not for landing (branch hq48-localapp-isolation-spike): measures the two designs that keep
# the acpmux LocalApp token out of the agent pane's page world (spikes/localapp-isolation).
# Run alone on a worker: cmux-ci run --class exclusive --script scripts/measure/localapp-isolation.sh
#   --ref SHA [--arg=probe-only] [--arg=rounds=N]
# 1. WebKit: the isolation probes (Swift Testing), then the frame bench (direct, A, B).
# 2. Chromium: the same probes and bench through CDP on a headless Chrome (system Chrome, else
#    Chrome for Testing's headless shell, downloaded into the step's checkout).
# Everything it writes stays under .build/localapp-spike in the step's own checkout.
set -euo pipefail

probe_only=0
rounds=5
for arg in "$@"; do
  case "$arg" in
    probe-only) probe_only=1 ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    *) echo "localapp-isolation.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done

root="$(pwd)"
out="$root/.build/localapp-spike"
mkdir -p "$out"

machine() {
  echo "SPIKE-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)"
  echo "SPIKE-LOAD $1 $(uptime | sed 's/.*load averages*: //')"
}
machine before

if [ -z "${DEVELOPER_DIR:-}" ]; then
  env_file="$out/xcode.env"
  : > "$env_file"
  GITHUB_ENV="$env_file" CMUX_CI_SKIP_XCODE_SELECT=1 ./scripts/select-ci-xcode.sh
  DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$env_file" | tail -n 1)"
  export DEVELOPER_DIR
fi
echo "SPIKE-INFO xcode=$DEVELOPER_DIR $(swift --version 2>&1 | head -1)"

status=0
cd "$root/spikes/localapp-isolation"
swift build --build-tests --scratch-path "$out/swift" 2>&1 | tail -40
swift test --skip-build --scratch-path "$out/swift" --filter IsolationProbeTests 2>&1 | tail -60 || status=1
if [ "$probe_only" = 0 ]; then
  machine webkit-bench
  LOCALAPP_SPIKE_BENCH=1 LOCALAPP_SPIKE_ROUNDS="$rounds" LOCALAPP_SPIKE_OUT="$out" \
    swift test --skip-build --scratch-path "$out/swift" --filter RelayBench 2>&1 | tail -40 || status=1
fi

chrome=""
for candidate in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
  [ -x "$candidate" ] && { chrome="$candidate"; break; }
done
if [ -z "$chrome" ]; then
  version="$(curl -fsSL https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_STABLE)"
  curl -fsSL -o "$out/headless.zip" \
    "https://storage.googleapis.com/chrome-for-testing-public/$version/mac-arm64/chrome-headless-shell-mac-arm64.zip"
  rm -rf "$out/headless" && mkdir -p "$out/headless" && unzip -q "$out/headless.zip" -d "$out/headless"
  chrome="$out/headless/chrome-headless-shell-mac-arm64/chrome-headless-shell"
  xattr -dr com.apple.quarantine "$out/headless" 2>/dev/null || true
fi
echo "SPIKE-INFO chrome=$chrome"
machine chromium-bench
chromium_args=("$chrome" "$out" --rounds "$rounds")
[ "$probe_only" = 1 ] && chromium_args+=(--probe-only)
python3 chromium/bench.py "${chromium_args[@]}" || status=1
machine after
exit "$status"
