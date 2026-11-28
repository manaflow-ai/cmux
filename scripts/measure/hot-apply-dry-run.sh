#!/usr/bin/env bash
# hot-apply.py's fetch side timed on any host, Linux included (measurement only): for each SHA,
# `apply SHA --base SHA^ --dry-run` with a cold state folder (nothing fetched before), then the same
# again warm (the state folder kept), and one line per run with its phases.
#   cmux-ci test --setup none -- scripts/measure/hot-apply-dry-run.sh SHA...
#   scripts/measure/hot-apply-dry-run.sh SHA...       (a checkout with SHA and its parent)
#   triple=aarch64-apple-darwin SHA...  fetch that target's build (a Mac's) instead of this host's
# Prints `HAD <sha> <cold|warm> <seconds> <exit> <phases json>` per run. Nothing outside the
# temporary state folders changes: no app is read (--base) and none is touched.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
if [[ "${1:-}" == triple=* ]]; then export CMUX_HOT_APPLY_TRIPLE="${1#triple=}"; shift; fi
[[ $# -gt 0 ]] || { echo "give one or more commit shas" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/tmp}/hot-apply-dry-run.XXXXXX")"
trap 'rm -rf "$work"' EXIT
status=0
for sha in "$@"; do
  git cat-file -e "$sha^^{commit}" 2>/dev/null || git fetch --no-recurse-submodules -q origin "$sha" 2>/dev/null || git fetch --no-recurse-submodules -q https://github.com/manaflow-ai/cmux.git "$sha" || true
  base="$(git rev-parse --verify --quiet "$sha^")" || { echo "HAD $sha no-parent"; status=1; continue; }
  export CMUX_HOT_APPLY_STATE_DIR="$work/${sha:0:12}"
  for run in cold warm; do
    receipt="$(python3 scripts/cmux-next/hot-apply.py apply "$sha" --base "$base" --dry-run 2>"$work/err")"
    code=$?
    line="$(printf '%s\n' "$receipt" | tail -1)"
    python3 -c 'import json,sys
r = json.loads(sys.argv[1]) if sys.argv[1].startswith("{") else {}
print("HAD", sys.argv[2], sys.argv[3], r.get("seconds"), sys.argv[4], json.dumps({"parts": r.get("parts"), "phases": r.get("phases"), "error": r.get("error")}))' \
      "$line" "$sha" "$run" "$code"
    [[ $code -eq 0 || $code -eq 3 ]] || { status=1; tail -5 "$work/err" >&2; }
  done
done
exit "$status"
