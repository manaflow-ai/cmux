#!/usr/bin/env bash
# A plain `git clone https://github.com/OWNER/REPO` straight to GitHub, then through the git cache
# proxy (cold, then warm), n runs each, plus K clones at once both ways (the Duress line).
# GitHub bytes: the received bytes of every non-loopback interface (/proc/net/dev) over the clone;
# the proxy serves on loopback, so a warm clone's GitHub bytes are only what it asked upstream.
#
# usage: bench/clone-bench.sh [REPO_URL] [N] [K]   (from cmux-tui; Linux)
set -euo pipefail
URL=${1:-https://github.com/manaflow-ai/cmux}
N=${2:-3}
K=${3:-4}
cargo build -q --release -p cmux-git-cache --example git-cache
BIN=$(pwd)/target/release/examples/git-cache
T=$(mktemp -d)
PORT=47391
cleanup() { [[ -n "${PID:-}" ]] && kill "$PID" 2>/dev/null; wait 2>/dev/null; rm -rf -- "$T"; }
trap cleanup EXIT

rx() { awk 'NR>2 { sub(":", " "); if ($1 != "lo") s += $2 } END { printf "%d", s }' /proc/net/dev; }
direct() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git clone -q "$URL" "$1"; }
proxied() { GIT_CONFIG_GLOBAL="$T/include" GIT_CONFIG_NOSYSTEM=1 git clone -q "$URL" "$1"; }

one() { # label fn
  local label=$1 fn=$2 a b s e
  a=$(rx); s=$(date +%s.%N)
  "$fn" "$T/clone"
  e=$(date +%s.%N); b=$(rx)
  printf '%-14s %7.1f s  github_rx=%6.1f MiB\n' "$label" "$(echo "$e - $s" | bc)" \
    "$(echo "($b - $a) / 1048576" | bc -l)"
  rm -rf -- "$T/clone"
}

many() { # label fn
  local label=$1 fn=$2 a b s e i
  a=$(rx); s=$(date +%s.%N)
  for i in $(seq "$K"); do "$fn" "$T/many-$i" & done
  wait
  e=$(date +%s.%N); b=$(rx)
  printf 'duress %-7s K=%d %7.1f s wall  github_rx=%6.1f MiB total\n' "$label" "$K" \
    "$(echo "$e - $s" | bc)" "$(echo "($b - $a) / 1048576" | bc -l)"
  for i in $(seq "$K"); do rm -rf -- "$T/many-$i"; done
}

echo "repo=$URL n=$N K=$K host=$(hostname) git=$(git --version | cut -d' ' -f3) nproc=$(nproc)"
for i in $(seq "$N"); do one "direct#$i" direct; done

"$BIN" serve --listen "127.0.0.1:$PORT" --cache "$T/cache" --tenant bench \
  --include "$T/include" --helper "!'$BIN' credential" 2>"$T/proxy.log" &
PID=$!
for _ in $(seq 100); do [[ -s "$T/include" ]] && break; sleep 0.1; done
[[ -s "$T/include" ]] || { cat "$T/proxy.log"; exit 1; }

one "proxy-cold" proxied
for i in $(seq "$N"); do one "proxy-warm#$i" proxied; done
many direct direct
many proxy proxied
grep -c 'served=local' "$T/proxy.log" | sed 's/^/local serves: /'
curl -s "http://127.0.0.1:$PORT/_cmux/git-cache/health"; echo
