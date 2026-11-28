#!/bin/bash
# The dependency-cache bench for .github/workflows/machine-join-e2e.yml (bench=deps): run by
# machine-join-e2e.ts as the disposable user while its machine is joined to the development platform.
#
#   deps-bench.sh ACPMUX
#
# The workflow lays out the base (the script's parent's parent): bin/ (acpmux, bun, this script),
# toolchain/ (the pinned Rust sysroot) and bench/ (cmux-tui's sources, the webviews manifest and
# lockfile). Every cache lives under bench/, never in the home the harness scans for secrets.
#
# For Cargo (cmux-tui) and bun (webviews), from empty caches each time:
#   cold  the plain install (`cargo fetch --locked`, `bun install --frozen-lockfile`)
#   seed  `acpmux machine deps warm`: a restore, or (on a miss) the install; the upload runs in
#         the background (timed apart, by `machine deps wait`)
#   warm  `acpmux machine deps warm` again: a restore, or a cold install when this machine's
#         measurements say that is faster
#   fresh the same with this machine's measurements ignored (a new machine), so the uploader's
#         timing record decides
# The last line is one JSON object of numbers and plain strings, the bench's evidence.
set -euo pipefail

acpmux="$1"
base="$(cd -- "$(dirname -- "$0")/.." && pwd)"
bench="$base/bench"
export PATH="$base/toolchain/bin:$base/bin:/usr/local/bin:/usr/bin:/bin"
export CARGO_HOME="$bench/cargo-home"
export BUN_INSTALL="$bench/bun-home"
export BUN_INSTALL_CACHE_DIR="$bench/bun-cache"
export XDG_CACHE_HOME="$bench/xdg-cache"
export TMPDIR="$bench/tmp"
export CARGO_TERM_COLOR=never NO_COLOR=1
mkdir -p -- "$TMPDIR" "$bench/logs"

# bench=deps-slow without netem: every tool's HTTPS goes through a local proxy that delays it.
if [ -f "$bench/link-proxy-ms" ]; then
  delay="$(tr -cd 0-9 <"$bench/link-proxy-ms")"
  : >"$bench/logs/proxy-hosts"
  python3 -I "$base/bin/delay-proxy.py" 18080 "$delay" "$bench/logs/proxy-hosts" 2>"$bench/logs/proxy.log" &
  proxy_pid=$!
  trap 'kill "$proxy_pid" 2>/dev/null || true' EXIT
  for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/18080) 2>/dev/null && break; sleep 0.1; done
  export HTTPS_PROXY=http://127.0.0.1:18080 https_proxy=http://127.0.0.1:18080
  export CARGO_HTTP_PROXY=http://127.0.0.1:18080
fi

cargo_dir="$bench/cmux-tui"
bun_dir="$bench/webviews"

now() { date +%s%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", (b - a) / 1e9 }'; }

wipe() {
  case "$1" in
    cargo) rm -rf -- "$CARGO_HOME" ;;
    bun) rm -rf -- "$bun_dir/node_modules" "$BUN_INSTALL_CACHE_DIR" "$BUN_INSTALL" ;;
  esac
  mkdir -p -- "$CARGO_HOME"
}

# Runs the command with its output in a log; on failure prints the log's tail and exits.
logged() {
  local name="$1"
  shift
  if ! "$@" >"$bench/logs/$name.log" 2>&1; then
    echo "$name failed:"
    tail -n 20 -- "$bench/logs/$name.log"
    exit 1
  fi
}

declare -A out
put() { out["$1"]="$2"; }

# One `machine deps warm` of DIR, timed; its report's fields for ECOSYSTEM go in under PREFIX.
# Further arguments are NAME=VALUE pairs for acpmux's environment.
warm() {
  local prefix="$1" eco="$2" dir="$3" t0 t1 json
  shift 3
  json="$bench/logs/$prefix.json"
  t0="$(now)"
  if ! env "$@" "$acpmux" machine deps warm "$dir" --json >"$json" 2>"$bench/logs/$prefix.log"; then
    echo "$prefix failed:"
    tail -n 20 -- "$bench/logs/$prefix.log"
    exit 1
  fi
  t1="$(now)"
  put "${prefix}S" "$(secs "$t0" "$t1")"
  local field
  for field in restore upload fetchMs unpackMs installMs packMs uploadMs archiveBytes installOk expectedMs coldMs error; do
    local v
    v="$(jq -r --arg eco "$eco" --arg f "$field" '[.projects[] | select(.ecosystem == $eco)][0][$f] // empty' -- "$json" 2>/dev/null || true)"
    if [ -n "$v" ]; then put "${prefix}${field^}" "$v"; fi
  done
}

for eco in cargo bun; do
  if [ "$eco" = cargo ]; then dir="$cargo_dir"; install=(cargo fetch --locked); else dir="$bun_dir"; install=(bun install --frozen-lockfile); fi

  wipe "$eco"
  t0="$(now)"
  (cd -- "$dir" && logged "${eco}Cold" "${install[@]}")
  t1="$(now)"
  put "${eco}ColdS" "$(secs "$t0" "$t1")"
  echo "$eco cold: ${out[${eco}ColdS]}s"

  wipe "$eco"
  warm "${eco}Seed" "$eco" "$dir"
  t0="$(now)"
  logged "${eco}SeedWait" "$acpmux" machine deps wait --json
  t1="$(now)"
  put "${eco}SeedUploadWaitS" "$(secs "$t0" "$t1")"
  echo "$eco seed: ${out[${eco}SeedS]}s (${out[${eco}SeedRestore]:-?}, upload ${out[${eco}SeedUpload]:-none}, then ${out[${eco}SeedUploadWaitS]}s more in the background)"

  wipe "$eco"
  warm "${eco}Warm" "$eco" "$dir"
  echo "$eco warm: ${out[${eco}WarmS]}s (${out[${eco}WarmRestore]:-?})"
  # The CLI exits 0 when the cache is off or a restore fails: a warm that neither restored nor chose
  # a cold install from its measurements says nothing about the cache.
  case "${out[${eco}WarmRestore]:-}" in
    restored | cold_faster | abandoned) ;;
    *)
      echo "$eco warm neither restored nor chose: ${out[${eco}WarmRestore]:-no report}: $(tail -n 5 -- "$bench/logs/${eco}Warm.log" | tr -cd 'A-Za-z0-9 ._:/-' | cut -c1-300)"
      exit 1
      ;;
  esac

  wipe "$eco"
  warm "${eco}Fresh" "$eco" "$dir" ACPMUX_DEPS_LOCAL_STATS=off
  echo "$eco fresh machine: ${out[${eco}FreshS]}s (${out[${eco}FreshRestore]:-?})"
done

if [ -f "$bench/link" ]; then put link "$(tr -cd 'a-z0-9 ' <"$bench/link")"; fi
if [ -n "${proxy_pid:-}" ]; then
  put proxyHosts "$(sort -u -- "$bench/logs/proxy-hosts" | tr -cd 'A-Za-z0-9.\n-' | paste -sd ' ' -)"
fi

# Numbers stay numbers; everything else is a string.
args=()
for k in "${!out[@]}"; do args+=(--arg "$k" "${out[$k]}"); done
jq -cn "${args[@]}" '$ARGS.named | with_entries(.value |= (tonumber? // .))'
