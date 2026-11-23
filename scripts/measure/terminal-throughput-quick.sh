#!/usr/bin/env bash
# Terminal throughput in about a minute on any Mac with cmux NEXT installed (goal terminal-throughput): the same
# 200 MB burst as the perf cron's `throughput` part (scripts/cmux-next/terminal-throughput-bench.py, the one
# measuring path), through an installed NEXT and an installed Ghostty back to back, MB/s each and NEXT/Ghostty.
# No build, no virtual display, no measurement slot or bench lock: terminal-throughput.sh is the per-commit path.
#
#   scripts/measure/terminal-throughput-quick.sh [--next APP] [--ghostty APP] [BENCH ARGS...]
#
#   --next APP      the NEXT to measure (default /Applications/cmux NIGHTLY.app). The bench runs a side-instance
#                   copy of it (scripts/cmux-next/side-instance.sh, name tt-bench, remade only when APP's version
#                   changes; the first make re-seals the copy and takes longer than a minute), so the installed app
#                   and a running cmux are never touched. Its window and Ghostty's open in front while they run.
#   --ghostty APP   default /Applications/Ghostty.app; without one there, the bench's pinned Ghostty release
#                   (downloaded once into ~/Library/Caches/cmux-bench unless CI_SHARED_CACHE_DIR is set)
#   BENCH ARGS      passed on (they win over the defaults here): --mb N, --runs N, --payload sgr, --breakdown, ...
#
# Prints the bench's TERMINAL-THROUGHPUT lines, then one line: NEXT MB/s, Ghostty MB/s, ratio, seconds, report path.
# Exits as the bench does (1 when a terminal gave no timed burst).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
die() { echo "terminal-throughput-quick: $*" >&2; exit 2; }

next="${CMUX_TT_NEXT_APP:-/Applications/cmux NIGHTLY.app}"
ghostty="${CMUX_TT_GHOSTTY_APP:-/Applications/Ghostty.app}"
pass=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --next) [[ $# -ge 2 ]] || die "--next takes an app"; next="${2%/}"; shift 2 ;;
    --ghostty) [[ $# -ge 2 ]] || die "--ghostty takes an app"; ghostty="${2%/}"; shift 2 ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) pass+=("$1"); shift ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || die "it runs on a Mac (both terminals open windows)"
[[ -f "$next/Contents/Info.plist" ]] || die "no cmux NEXT at $next (--next APP)"
ghostty_args=()
if [[ -d "$ghostty" ]]; then
  ghostty_args=(--ghostty-app "$ghostty")
else
  export CI_SHARED_CACHE_DIR="${CI_SHARED_CACHE_DIR:-$HOME/Library/Caches/cmux-bench}"
  echo "terminal-throughput-quick: no Ghostty at $ghostty; the bench's pinned release (cached in $CI_SHARED_CACHE_DIR)" >&2
fi
# Leo's laptop admits agents' app copies through mac-budget (side-instance.sh launch); a minute, not its 30 minutes.
export SIDE_INSTANCE_BUDGET_WAIT_S="${SIDE_INSTANCE_BUDGET_WAIT_S:-60}"

out="$(mktemp -d "${TMPDIR:-/tmp}/tt-quick.XXXXXX")"
started=$SECONDS
set +e
/usr/bin/python3 -I "$here/../cmux-next/terminal-throughput-bench.py" --installed "$next" \
  ${ghostty_args[@]+"${ghostty_args[@]}"} --out "$out" --json "$out/report.json" \
  --interrupt-runs 0 --timeout 60 ${pass[@]+"${pass[@]}"}
rc=$?
set -e
/usr/bin/python3 -I - "$out/report.json" "$((SECONDS - started))" <<'PY'
import json, sys
path, seconds = sys.argv[1], sys.argv[2]
try:
    report = json.load(open(path))
except (OSError, ValueError):
    print(f"terminal-throughput-quick: no report ({path}); see the lines above")
    sys.exit(0)
rows = {r["name"].rsplit(".", 1)[1]: r["p50"] for r in report.get("rows", [])}
fmt = lambda v, unit: f"{v} {unit}" if v is not None else "none"
print(f"terminal-throughput-quick: NEXT {fmt(rows.get('next_mb_s'), 'MB/s')}, "
      f"Ghostty {fmt(rows.get('ghostty_mb_s'), 'MB/s')} ({report.get('ghostty', {}).get('version', '?')}), "
      f"ratio {fmt(rows.get('ratio'), 'x')}; payload {report.get('payload')} {report.get('payload_bytes', 0) // 10**6} MB, "
      f"{report.get('runs_per_terminal')} runs each, host {report.get('host')}, {seconds} s, report {path}")
for item in report.get("missing", []):
    print(f"terminal-throughput-quick: missing {item['name']}: {item['reason']}")
PY
exit "$rc"
