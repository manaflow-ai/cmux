#!/usr/bin/env bash
# Caps the size of the CmuxNextApp target. Every edit in CmuxNextApp re-emits
# its whole module (about 6.7 s at 111k lines, plus about 0.06 s per 1,000
# lines; hq-11 Swift edit-loop measurement, 2026-10-11), so new features go in
# their own target (plans/cmux-next/code-quality.md SW14) and the App only
# shrinks.
#
# Rule: the sum of physical lines (newline-terminated or not, blank and comment
# lines included) of every *.swift file under
# Packages/macOS/CmuxNext/Sources/CmuxNextApp in the working tree. The cap is
# the number in scripts/cmux-next/app-size-baseline.txt. More lines than the
# cap fails; fewer passes and prints a hint to lower the cap.
#
# Usage: scripts/cmux-next/check-app-size.sh [--update-baseline] [--base REF] [repo-root]
#   --base REF         (pull requests) over the cap still passes when the count
#                      is not above the count at REF, so a change that shrinks
#                      or keeps the App size never fails.
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

if (( lines > cap )) && [[ -n "$base" ]]; then
  # git grep -c '' counts every line of a tracked file at REF, a last line
  # with no newline too. An unknown REF falls through to the plain cap check.
  if base_lines="$(git -C "$root" grep -c '' "$base" -- 'Packages/macOS/CmuxNext/Sources/CmuxNextApp/*.swift' | awk -F: '{ s += $NF } END { print s + 0 }')" \
    && git -C "$root" rev-parse --verify --quiet "$base^{commit}" > /dev/null && (( lines <= base_lines )); then
    echo "check-app-size: ok, CmuxNextApp has $lines lines, over the cap $cap but not above the base ($base_lines at $base)"
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
