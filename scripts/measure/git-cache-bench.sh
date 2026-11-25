#!/usr/bin/env bash
# Per-VM git cache proxy (cmux-git-cache, `cmux host git-cache serve`) against a direct clone from
# GitHub. Bounded: every clone runs under a cap (CAP, default 120 s); a clone that hits it is run
# again at CAP2 (default 600 s) and both lines are kept, so a capped clone still shows the bytes it
# pulled (git's own progress, `--progress`, last "Receiving objects" line) and the time it needed.
# Cells, N runs each (default 3):
#   direct        git clone URL straight from GitHub
#   proxy-cold    the first clone through a proxy with an empty cache (it passes GitHub's pack
#                 through and keeps it in the VM mirror)
#   proxy-second  the next clone through the same proxy (served from the kept pack)
# Duress line: K clones at once (default 4), direct, then through a proxy with an empty cache.
# github_rx is every non-loopback byte the host received during the cell (other traffic included,
# so read it on a quiet host), so it is what the cell pulled from GitHub.
# Run on any Linux host with git, cargo and network (a lane VM, or a fleet Linux worker):
#   scripts/measure/git-cache-bench.sh [URL] [--n 3] [--k 4] [--cap 120] [--cap2 600]
#   cmux-ci run --script scripts/measure/git-cache-bench.sh --ref SHA --arg=URL --timeout 7200
# URL defaults to https://github.com/git/git (completes under the cap on a loaded VM);
# https://github.com/manaflow-ai/cmux (~14 GiB) shows the cap path.
set -uo pipefail
URL=https://github.com/git/git; N=3; K=4; CAP=120; CAP2=600; BIN=${GIT_CACHE_BIN:-}
while [ $# -gt 0 ]; do case $1 in
  --n) N=$2; shift 2;; --k) K=$2; shift 2;; --cap) CAP=$2; shift 2;; --cap2) CAP2=$2; shift 2;;
  --bin) BIN=$2; shift 2;; -*) echo "unknown flag $1" >&2; exit 2;; *) URL=$1; shift;; esac; done
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
if [ -z "$BIN" ]; then
  (cd "$ROOT/cmux-tui" && cargo build -q --release -p cmux-git-cache --example git-cache) || exit 2
  BIN="$ROOT/cmux-tui/target/release/examples/git-cache"
fi
T=$(mktemp -d "${TMPDIR:-/tmp}/git-cache-bench.XXXXXX"); PORT=${PORT:-47391}; PGID=""
calc() { awk "BEGIN { printf \"%.1f\", $1 }"; }
now() { date +%s.%N; }
rx() { awk 'NR>2 { sub(":", " "); if ($1 != "lo") s += $2 } END { printf "%d", s }' /proc/net/dev; }
stop() { [ -n "$PGID" ] && kill -- -"$PGID" 2>/dev/null; PGID=""; wait 2>/dev/null; }
trap 'stop; rm -rf -- "$T"' EXIT
# An empty cache and a proxy in its own process group (its background fill goes with it).
start() { stop; rm -rf -- "$T/cache" "$T/include"; mkdir -p "$T/cache"
  setsid "$BIN" serve --listen "127.0.0.1:$PORT" --cache "$T/cache" --tenant bench \
    --include "$T/include" --helper "!'$BIN' credential" >>"$T/proxy.log" 2>&1 & PGID=$!
  for _ in $(seq 100); do [ -s "$T/include" ] && return; sleep 0.1; done; echo "proxy did not start" >&2; exit 2; }
clone() { # clone MODE CAP DEST ERR
  local cfg=/dev/null; [ "$1" = proxy ] && cfg="$T/include"
  GIT_CONFIG_GLOBAL=$cfg GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    timeout "$2" git clone --progress "$URL" "$3" 2>"$4"; }
pulled() { tr '\r' '\n' <"$1" | grep -E 'Receiving objects' | tail -1 | sed -E 's/.*\| *//; s/ *$//'; }
one() { # one LABEL MODE: a clone at CAP, and again at CAP2 when CAP cut it off
  local cap a b s e rc
  for cap in "$CAP" "$CAP2"; do
    a=$(rx); s=$(now); clone "$2" "$cap" "$T/clone" "$T/err"; rc=$?; e=$(now); b=$(rx)
    printf '%-15s cap=%-4s %7s s rc=%-3s github_rx=%8s MiB git: %s\n' "$1" "$cap" "$(calc "$e-$s")" "$rc" \
      "$(calc "($b-$a)/1048576")" "$(pulled "$T/err")"
    rm -rf -- "$T/clone"; [ "$rc" = 124 ] || return 0
    [ "$2" = proxy ] && start # a cut-off cold clone kept nothing: retry on an empty cache
  done; }
many() { # many LABEL MODE: K clones at once
  local cap a b s e i rcs
  for cap in "$CAP" "$CAP2"; do
    [ "$2" = proxy ] && start
    rcs=""; a=$(rx); s=$(now)
    for i in $(seq "$K"); do ( clone "$2" "$cap" "$T/m$i" "$T/m$i.err"; echo $? >"$T/m$i.rc" ) & done
    for i in $(seq "$K"); do while [ ! -s "$T/m$i.rc" ]; do sleep 0.2; done; done; e=$(now); b=$(rx)
    for i in $(seq "$K"); do rcs="$rcs$(cat "$T/m$i.rc"),"; done
    printf 'duress %-8s K=%d cap=%-4s %7s s wall rc=%s github_rx=%8s MiB total\n' "$1" "$K" "$cap" \
      "$(calc "$e-$s")" "${rcs%,}" "$(calc "($b-$a)/1048576")"
    for i in $(seq "$K"); do rm -rf -- "$T/m$i" "$T/m$i.rc" "$T/m$i.err"; done
    case ",$rcs" in *,124,*) ;; *) return 0;; esac
  done; }
echo "repo=$URL n=$N K=$K cap=${CAP}s/${CAP2}s host=$(hostname) git=$(git --version | cut -d' ' -f3)" \
  "nproc=$(nproc) load=$(cut -d' ' -f1-3 /proc/loadavg)"
for i in $(seq "$N"); do one "direct#$i" direct; done
for i in $(seq "$N"); do start; one "proxy-cold#$i" proxy; one "proxy-second#$i" proxy; done
many direct direct; many proxy proxy
stop
echo "proxy log: kept=$(grep -c "kept github.com's pack" "$T/proxy.log")" \
  "served-by-cache=$(grep -c 'served by cache' "$T/proxy.log")" \
  "served-by-github=$(grep -c 'served by github.com' "$T/proxy.log")"
grep -E "kept github.com's pack|keep failed|fill" "$T/proxy.log" | tail -5
echo "load end: $(cut -d' ' -f1-3 /proc/loadavg)"
