#!/usr/bin/env bash
# A/B the cmux-tui daemon at scale on macOS: published release binaries of
# two commits, interleaved runs on one machine (cmux-tui/scripts/bench-scale.py:
# create latency, echo latency, topology read/write latency under 5% busy
# terminals, durable state on the local disk, so fsync costs what it costs).
# Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/tui-scale-ab.sh --ref SHA
#     --arg=against=SHA [--arg=after=SHA] [--arg=counts=250,1000,2000] [--arg=rounds=2]
# against= is the "before" binary, after= (default: the ref) the "after" one.
# before_key=/after_key= name the published tree keys directly: the key of an
# older commit can differ from what this ref's key inputs compute.
# Both commits need a published cmux-tui tree (pin-cmux-tui.sh docs: push
# cmux-tui-pin-<short> and let cmux-tui-artifacts.yml publish it). The counts
# are capped by the free PTYs (kern.tty.ptmx_max minus PTYs in use minus 64).
# Output: one TUI-AB line per run and count; JSON under .build/tui-scale/ab.
set -euo pipefail
against=""
after=HEAD
before_key=""
after_key=""
counts="250,1000,2000"
rounds=2
for arg in "$@"; do
  case "$arg" in
    against=*) against="${arg#against=}" ;;
    after=*) after="${arg#after=}" ;;
    before_key=*) before_key="${arg#before_key=}" ;;
    after_key=*) after_key="${arg#after_key=}" ;;
    counts=*) counts="${arg#counts=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    *) echo "tui-scale-ab.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[ -n "$against" ] || { echo "tui-scale-ab.sh: against=SHA is required" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/tui-scale"
rm -rf "$work"
mkdir -p "$work/ab"
for rev in "$against" "$after"; do
  git cat-file -e "$rev^{commit}" 2>/dev/null || git fetch --quiet --depth=1 origin "$rev"
done
base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"
fetch() { # label revision [key]
  local key="${3:-}" sum
  [ -n "$key" ] || key="$(python3 scripts/ci/cmux_tui_tree_key.py "$2")"
  curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin" -o "$work/bin-$1"
  sum="$(curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
  [ "$(shasum -a 256 "$work/bin-$1" | awk '{print $1}')" = "$sum" ] || { echo "TUI-AB sha256 mismatch for $1 ($key)" >&2; exit 1; }
  chmod +x "$work/bin-$1"
  echo "TUI-AB-BIN $1 rev=$(git rev-parse --short=12 "$2") key=$key"
}
fetch before "$against" "$before_key"
fetch after "$after" "$after_key"
ptmx_max="$(sysctl -n kern.tty.ptmx_max)"
in_use="$(find /dev -maxdepth 1 -name 'ttys[0-9]*' 2>/dev/null | wc -l | tr -d ' ')"
cap=$(( ptmx_max - in_use - 64 ))
capped=""
IFS=, read -r -a wanted <<< "$counts"
for n in "${wanted[@]}"; do
  if [ "$n" -le "$cap" ]; then capped="${capped:+$capped,}$n"; fi
done
[ -n "$capped" ] || capped="$cap"
echo "TUI-AB-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) ptmx_max=$ptmx_max ptys_in_use=$in_use counts=$capped"
ulimit -n "$(ulimit -Hn)" 2>/dev/null || ulimit -n 65536 2>/dev/null || true
echo "TUI-AB-LIMITS nofile=$(ulimit -n) maxprocperuid=$(sysctl -n kern.maxprocperuid)"
# Daemon state on the boot APFS volume (real fsync); a short path keeps the
# socket under the macOS sun_path limit.
state_root="$(mktemp -d /private/tmp/tsab.XXXXXX)"
trap 'rm -rf "$state_root"' EXIT
status=0
for round in $(seq 1 "$rounds"); do
  for label in before after; do
    echo "TUI-AB-LOAD $label-$round $(uptime | sed 's/.*load averages*: //')"
    python3 cmux-tui/scripts/bench-scale.py --bin "$work/bin-$label" --counts "$capped" \
      --busy-fraction 0.05 --per-workspace 25 --fill sequential --idle-seconds 5 \
      --root-dir "$state_root" --out "$work/ab/$label-$round.json" > "$work/ab/$label-$round.log" 2>&1 || status=$?
    python3 - "$work/ab/$label-$round.json" "$label-$round" <<'EOF' || status=$?
import json, sys
data = json.load(open(sys.argv[1]))
for step in data.get("steps", []):
    c = step.get("create_latency") or {}
    e = step.get("latency") or {}
    t = step.get("topology") or {}
    r, w = t.get("read") or {}, t.get("write") or {}
    print(f"TUI-AB {sys.argv[2]} N={step.get('target')} created={step.get('created')} rate={step.get('create_rate_per_s')} "
          f"c50={c.get('p50_ms')} c99={c.get('p99_ms')} echo99={e.get('p99_ms')} "
          f"r50={r.get('p50_ms')} r99={r.get('p99_ms')} w50={w.get('p50_ms')} w99={w.get('p99_ms')}")
print(f"TUI-AB-STOP {sys.argv[2]} {data.get('stopped')}")
EOF
  done
done
exit "$status"
