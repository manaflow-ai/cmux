#!/usr/bin/env bash
# Caps the size of the CmuxNextApp target. Every edit in CmuxNextApp re-emits
# its whole module (about 6.7 s at 111k lines, plus about 0.06 s per 1,000
# lines; hq-11 Swift edit-loop measurement, 2026-10-11), so new features go in
# their own target (plans/cmux-next/code-quality.md SW14) and the App only
# shrinks.
#
# Rule: the sum of physical lines (newline-terminated or not, blank and comment
# lines included) of every *.swift file under Packages/macOS/CmuxNext/Sources/CmuxNextApp
# in the working tree. The cap is the number in scripts/cmux-next/app-size-baseline.txt.
# More lines than the cap fails; fewer passes and prints a hint to lower the cap.
# For pull-request/push comparisons, source lines are also compared with the
# base tree so merge-tree-only comment and blank-line noise cannot consume the
# hard guard. Any real source-line growth still fails.
#
# Usage: scripts/cmux-next/check-app-size.sh [--update-baseline] [--base REF] [repo-root]
#   --base REF         (pull requests/pushes) compares source lines with REF;
#                      comment/blank-only growth can pass the physical cap,
#                      but real source growth fails.
#   --update-baseline  writes the current count when it is at or below the cap.
#                      It never raises the cap: a raise is a hand edit of the
#                      baseline file with the chief's go.
set -euo pipefail
update=0
base=""
while (( $# )); do
  case "$1" in
    --update-baseline) update=1; shift ;;
    --base) base="${2:?--base needs a ref}"; shift 2 ;;
    *) break ;;
  esac
done
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
app="$root/Packages/macOS/CmuxNext/Sources/CmuxNextApp"
baseline="$root/scripts/cmux-next/app-size-baseline.txt"
doc="plans/cmux-next/code-quality.md SW14"

if [[ ! -d "$app" ]]; then
  echo "check-app-size: $app is missing" >&2
  exit 2
fi
cap="$(grep -Ev '^[[:space:]]*(#|$)' "$baseline" | head -n 1 | tr -d '[:space:]')"
if [[ ! "$cap" =~ ^[0-9]+$ ]]; then
  echo "check-app-size: $baseline has no cap number" >&2
  exit 2
fi
# awk counts a last line with no newline too; -exec + may split the file list
# into batches, so sum the per-batch totals.
lines="$(find "$app" -type f -name '*.swift' -exec awk 'END { print NR }' {} + | awk '{ s += $1 } END { print s + 0 }')"

if (( update )); then
  if (( lines > cap )); then
    echo "check-app-size: CmuxNextApp has $lines lines, over the cap $cap; --update-baseline never raises the cap" >&2
    exit 1
  fi
  if (( lines == cap )); then
    echo "check-app-size: the cap is already $cap"
    exit 0
  fi
  updated="$(sed -E "s/^[[:space:]]*$cap[[:space:]]*$/$lines/" "$baseline")"
  printf '%s\n' "$updated" > "$baseline"
  echo "check-app-size: cap lowered from $cap to $lines"
  exit 0
fi

if [[ -n "$base" ]] \
  && git -C "$root" rev-parse --verify --quiet "$base^{commit}" > /dev/null \
  && base_source_lines="$(python3 "$root/scripts/cmux-next/count-swift-code-lines.py" --git-ref "$base" "$root")" \
  && source_lines="$(python3 "$root/scripts/cmux-next/count-swift-code-lines.py" "$root")"; then
  if (( source_lines > base_source_lines )); then
    echo "check-app-size: CmuxNextApp source grew ($source_lines source lines now, $base_source_lines at $base); real source growth is not allowed" >&2
    echo "check-app-size: source-line changes by file (move new code into its own target, see $doc):" >&2
    python3 "$root/scripts/cmux-next/count-swift-code-lines.py" --grown "$base" "$root" | sed 's/^/  /' >&2 || true
    exit 1
  fi
  if (( lines > cap )); then
    echo "check-app-size: ok, CmuxNextApp has $lines physical lines, over the cap $cap but no source-line growth ($source_lines now, <= $base_source_lines at $base)"
    exit 0
  fi
fi
if (( lines > cap )); then
  echo "check-app-size: CmuxNextApp is capped at $cap lines (now $lines, +$((lines - cap))); new features go in their own target (see $doc)" >&2
  exit 1
fi
if (( lines < cap )); then
  echo "check-app-size: ok, CmuxNextApp has $lines lines, $((cap - lines)) under the cap $cap. Lower the cap: scripts/cmux-next/check-app-size.sh --update-baseline"
else
  echo "check-app-size: ok, CmuxNextApp has $lines lines (cap $cap)"
fi
