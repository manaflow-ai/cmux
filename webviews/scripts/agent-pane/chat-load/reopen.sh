#!/usr/bin/env bash
# Reopen benchmark (reopen_bench.mjs): an app restart onto a long saved chat with the acpmux daemon
# already running, under load. On the fleet, from the repository root:
#
#   cmux-ci test --setup webviews --timeout 5400 --artifact /tmp/reopen -- \
#     bash webviews/scripts/agent-pane/chat-load/reopen.sh
#
#   reopen.sh [OUT_DIR] [--turns 1500] [--noise 20] [--others 40] [--rounds 10] [--load-pages 30]
#                     [--configs warm:none,restart:none]   (DAEMON:HOST_TAIL pairs)
#
# ACPMUX_BIN names a daemon binary; else the published Linux acpmux of ACPMUX_TREE (a cmux-tui
# tree key, files.cmux.com), sha256-checked.
set -euo pipefail
# OUT_DIR defaults to $FAST_CHECKS_OUT, the folder cmux-ci test brings back as the artifact.
if [[ $# -gt 0 && "$1" != --* ]]; then out="$1"; shift; else out="${FAST_CHECKS_OUT:?OUT_DIR or FAST_CHECKS_OUT}"; fi
mkdir -p "$out"; out="$(cd "$out" && pwd)"
turns=1500; noise=20; others=40; rounds=10; load_pages=30; configs=warm:none,restart:none
while [[ $# -gt 0 ]]; do
  case "$1" in
    --turns) turns="$2"; shift 2 ;;
    --noise) noise="$2"; shift 2 ;;
    --others) others="$2"; shift 2 ;;
    --rounds) rounds="$2"; shift 2 ;;
    --load-pages) load_pages="$2"; shift 2 ;;
    --configs) configs="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
work="$(mktemp -d /tmp/reopen.XXXXXX)"

bin="${ACPMUX_BIN:-}"
if [[ -z "$bin" ]]; then
  tree="${ACPMUX_TREE:-1feb8514a5ec646ed1e4aaf5d2cd8773d8ccd1cd}"
  name="cmux-tui-acpmux-$(uname -m)-unknown-linux-musl"
  curl -fsSL "https://files.cmux.com/cmux-tui/tree/$tree/$name" -o "$work/acpmux"
  want="$(curl -fsSL "https://files.cmux.com/cmux-tui/tree/$tree/$name.sha256" | cut -d' ' -f1)"
  [[ "$(sha256sum "$work/acpmux" | cut -d' ' -f1)" == "$want" ]] || { echo "acpmux sha256 mismatch" >&2; exit 1; }
  chmod +x "$work/acpmux"; bin="$work/acpmux"
fi
"$bin" --version

(cd "$root/webviews" && bun install --frozen-lockfile >/dev/null)
# The app's page highlights code in its worker pool; served over http: the pane would take the dev
# server's main-thread path, so this copy treats http: as the app's page (as run.sh does).
sed -i 's/return protocol === "cmux-agent:" ||/return protocol === "http:" || protocol === "cmux-agent:" ||/' \
  "$root/webviews/src/agent-session/acpmux/conversation/highlightPool.ts"
grep -q 'protocol === "http:"' "$root/webviews/src/agent-session/acpmux/conversation/highlightPool.ts"
"$root/scripts/cmux-next/build-agent-pane-web.sh" --out "$work/pane"

sizes="$turns"; for _ in $(seq 1 "$others"); do sizes="$sizes,20"; done
(cd "$root/webviews" && bun scripts/agent-pane/chat-load/fixture.ts --home "$work/home" --turns "$sizes" --noise "$noise") > "$work/fixture.json"
du -sh "$work/home"
cp "$work/fixture.json" "$out/fixture.json"

for config in ${configs//,/ }; do
  daemon="${config%%:*}"; tail="${config##*:}"
  (cd "$root/webviews" && node "$here/reopen_bench.mjs" --pane "$work/pane" --fixture "$work/fixture.json" \
    --acpmux "$bin" --out "$out/reopen-$daemon-$tail.json" --rounds "$rounds" --load-pages "$load_pages" \
    --daemon "$daemon" --host-tail "$tail") | tee "$out/reopen-$daemon-$tail.log"
done
echo "results in $out"
