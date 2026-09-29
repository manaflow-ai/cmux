#!/usr/bin/env bash
# Fails when any CmuxNext Swift file grows into a god file.
# Limits: 400 lines per file (tests 600), one primary type per file.
# Usage: scripts/cmux-next/check-no-godfiles.sh [root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
status=0
while IFS= read -r -d '' file; do
  lines=$(wc -l < "$file" | tr -d ' ')
  limit=400
  [[ "$file" == */Tests/* ]] && limit=600
  if (( lines > limit )); then
    echo "god file: ${file#"$root"/} has $lines lines (limit $limit)"
    status=1
  fi
  # Top-level primary declarations (extensions and small nested helpers are fine).
  types=$(grep -cE '^(public |internal |package |fileprivate |private |final |nonisolated |indirect |@MainActor |@Observable |@frozen )*(final )?(class|struct|enum|actor|protocol) ' "$file" || true)
  if [[ "$file" != */Tests/* ]] && (( types > 3 )); then
    echo "god file: ${file#"$root"/} declares $types top-level types (limit 3)"
    status=1
  fi
done < <(find "$root/Sources" "$root/Tests" -name '*.swift' -print0 2>/dev/null)
exit $status
