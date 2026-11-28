#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/capture-memory.sh --pid <pid> [--out <dir>] [--heavy]

Capture memory diagnostics for a live process. The default capture is lightweight
and safe for a primary cmux instance: ps, footprint, and vmmap -summary. Pass
--heavy to also run leaks and malloc_history; use that only on a fresh profiled
instance because heap walks can freeze a busy terminal host.
USAGE
}

pid=""
out_dir=""
heavy="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pid)
      if [ "$#" -lt 2 ] || [[ "${2:-}" == --* ]]; then
        echo "capture-memory: --pid requires a value" >&2
        usage
        exit 2
      fi
      pid="$2"
      shift 2
      ;;
    --out)
      if [ "$#" -lt 2 ] || [[ "${2:-}" == --* ]]; then
        echo "capture-memory: --out requires a value" >&2
        usage
        exit 2
      fi
      out_dir="$2"
      shift 2
      ;;
    --heavy)
      heavy="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "capture-memory: unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! ps -p "$pid" >/dev/null 2>&1; then
  echo "capture-memory: --pid must name a live process" >&2
  usage
  exit 2
fi

if [ -z "$out_dir" ]; then
  out_dir="memory-capture-${pid}-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$out_dir"

run_capture() {
  local name="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  } > "$out_dir/$name.txt" 2>&1 || {
    rc="$?"
    printf '\ncommand exited with %s\n' "$rc" >> "$out_dir/$name.txt"
  }
}

run_capture "ps" ps -o pid,ppid,lstart,etime,rss,vsz,command -p "$pid"
run_capture "footprint-summary" footprint -summary -pid "$pid"
run_capture "vmmap-summary" vmmap -summary "$pid"

if [ "$heavy" = "true" ]; then
  run_capture "leaks" leaks "$pid"
  run_capture "malloc-history-all-by-size" malloc_history "$pid" -allBySize
else
  cat > "$out_dir/heavy-tools-skipped.txt" <<'EOF'
Skipped leaks and malloc_history.

Pass --heavy only for a fresh instance launched with MallocStackLogging when a
heap walk is acceptable. Running heavy tools against a primary terminal-hosting
cmux process can freeze the user's active terminal.
EOF
fi

cat > "$out_dir/manifest.json" <<EOF
{
  "captured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pid": $pid,
  "heavy": $heavy
}
EOF

printf 'memory capture written to %s\n' "$out_dir"
