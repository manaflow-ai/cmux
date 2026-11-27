#!/usr/bin/env bash
# GitHub release assets and codeload archives through the machine's git cache proxy (cmux-git-cache's
# archive route): each URL direct, cold through the proxy (a 307 to GitHub while it fills), then warm from
# disk three times, with sha256 of every copy (one line: identical bytes) and the load average (Duress).
#   cmux-ci test --setup rust -- bash scripts/measure/git-cache-archives.sh
# Starts its own proxy (cargo example git-cache) on a free port with a cache in a new temp dir it deletes.
# Override the URLs with positional arguments.
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
urls=("$@")
((${#urls[@]})) || urls=(
  https://github.com/openai/codex/releases/download/rust-v0.156.1/codex-x86_64-unknown-linux-musl.tar.gz
  https://codeload.github.com/oven-sh/bun/tar.gz/bun-v1.2.0
)
work="$(mktemp -d)"
(cd "$root/cmux-tui" && cargo build -q -p cmux-git-cache --example git-cache) || exit 1
bin="$root/cmux-tui/target/debug/examples/git-cache"
port=$((47400 + RANDOM % 500))
"$bin" serve --listen "127.0.0.1:$port" --cache "$work/cache" 2>"$work/serve.log" &
proxy=$!
trap 'kill "$proxy" 2>/dev/null; wait "$proxy" 2>/dev/null; rm -rf -- "$work"' EXIT
for _ in $(seq 50); do curl -fsS -o /dev/null "http://127.0.0.1:$port/_cmux/git-cache/health" && break; sleep 0.1; done
timed() { local s e; s=$(date +%s%N); curl -fsSL -o "$1" "$2"; local rc=$?; e=$(date +%s%N); printf '%s %6.2f s rc=%d\n' "$3" "$(((e - s) / 1000000))e-3" "$rc"; }
for url in "${urls[@]}"; do
  px="http://127.0.0.1:$port/${url#https://}"
  echo "== $url"
  timed "$work/direct" "$url" direct
  timed "$work/cold" "$px" cold
  for _ in $(seq 240); do [[ "$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 "$px")" == 206 ]] && break; sleep 0.5; done
  for k in 1 2 3; do timed "$work/warm" "$px" "warm$k"; done
  printf 'bytes %s, distinct sha256: %s\n' "$(stat -c %s "$work/warm")" \
    "$(sha256sum "$work/direct" "$work/cold" "$work/warm" | awk '{print $1}' | sort -u | wc -l)"
done
curl -fsS "http://127.0.0.1:$port/_cmux/git-cache/health"; echo
grep -c 'served by cache' "$work/serve.log" | sed 's/^/serve log lines: /'
echo "Duress: load $(cut -d' ' -f1-3 /proc/loadavg), $(nproc) cores"
