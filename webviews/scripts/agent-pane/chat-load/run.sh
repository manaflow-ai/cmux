#!/usr/bin/env bash
# Chat-load benchmark (perf100), both stages, on a Linux VM with the webviews browser snapshot
# (Freestyle `--snapshot webviews`): fixtures, the acpmux daemon stage, then the shipped pane in
# Chromium and WebKit against the same daemon, and the mock chat. Results go to $OUT (JSON).
#
#   run.sh ACPMUX_BIN OUT_DIR [--turns 100,1000,10000] [--noise 0] [--engines chromium,webkit]
#          [--repeat 3] [--scroll-max-turns 1000] [--scroll-timeout MS] [--mock-turns 100,1000,10000] [--pane DIR]
#
# Run from the repository root (needs webviews/ and scripts/cmux-next/build-agent-pane-web.sh).
set -euo pipefail
bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
out="$1"; shift
mkdir -p "$out"; out="$(cd "$out" && pwd)"
turns=100,1000,10000; noise=0; engines=chromium,webkit; repeat=3; scroll_max=1000; mock_turns=100,1000,10000; pane=""; scroll_timeout=120000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --turns) turns="$2"; shift 2 ;;
    --noise) noise="$2"; shift 2 ;;
    --engines) engines="$2"; shift 2 ;;
    --repeat) repeat="$2"; shift 2 ;;
    --scroll-max-turns) scroll_max="$2"; shift 2 ;;
    --mock-turns) mock_turns="$2"; shift 2 ;;
    --pane) pane="$2"; shift 2 ;;
    --scroll-timeout) scroll_timeout="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
work="$(mktemp -d /tmp/chat-load.XXXXXX)"
chmod +x "$bin"
"$bin" --version

if [[ -z "$pane" ]]; then
  (cd "$root/webviews" && bun install --frozen-lockfile >/dev/null)
  # Readable function names in profiles (CHAT_LOAD_NO_MINIFY=1): the bundle unminified, on the VM's copy only.
  # The app's page (cmux-agent:) highlights code in its worker pool; this page is served over
  # http:, which the pane treats as the dev server (main-thread highlighting). The VM's copy
  # treats http: as the app's page, so the bench runs the app's highlighting path.
  sed -i 's/return protocol === "cmux-agent:" ||/return protocol === "http:" || protocol === "cmux-agent:" ||/' \
    "$root/webviews/src/agent-session/acpmux/conversation/highlightPool.ts"
  grep -q 'protocol === "http:"' "$root/webviews/src/agent-session/acpmux/conversation/highlightPool.ts"
  if [[ "${CHAT_LOAD_NO_MINIFY:-}" == 1 ]]; then sed -i 's/minify: !cssInputsOnly/minify: false/' "$root/webviews/scripts/agent-pane/bundle.mjs"; fi
  pane="$work/pane"
  "$root/scripts/cmux-next/build-agent-pane-web.sh" --out "$pane"
fi

home="$work/home"
(cd "$root/webviews" && bun scripts/agent-pane/chat-load/fixture.ts --home "$home" --turns "$turns" --noise "$noise") > "$work/fixture.json"
cat "$work/fixture.json"
du -sh "$home"

token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
python3 -I "$here/daemon_bench.py" "$bin" "$work/fixture.json" "$out/daemon.json" --repeat "$repeat" \
  --listen 127.0.0.1:47931 --token "$token" --allow-dev-origin http://127.0.0.1:4319 --keep-pidfile "$work/daemon.pid"
pid="$(cat "$work/daemon.pid")"
trap 'kill "$pid" 2>/dev/null || true' EXIT

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-webviews/browsers}"
if [[ -n "${CHAT_LOAD_PROFILE:-}" ]]; then
  for p in ${CHAT_LOAD_PROFILE//,/ }; do
    node "$here/browser_bench.mjs" --pane "$pane" --fixture "$work/fixture.json" --endpoint ws://127.0.0.1:47931 \
      --token "$token" --daemon-pid "$pid" --engine chromium --profile "$p" | tee -a "$out/profiles.txt"
  done
  exit 0
fi
for engine in ${engines//,/ }; do
  node "$here/browser_bench.mjs" --pane "$pane" --fixture "$work/fixture.json" --endpoint ws://127.0.0.1:47931 \
    --token "$token" --daemon-pid "$pid" --out "$out/page-$engine.json" --engine "$engine" --repeat "$repeat" \
    --switch --scroll --scroll-max-turns "$scroll_max" --scroll-timeout "$scroll_timeout" --mock --mock-turns "$mock_turns"
done
grep -E 'VmHWM|VmRSS' "/proc/$pid/status" | tee "$out/daemon-final-status.txt"
cp "$work/fixture.json" "$out/fixture.json"
echo "results in $out"
