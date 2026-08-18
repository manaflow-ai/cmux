#!/usr/bin/env bash
# The Testbox plan is executable documentation: agents copy its shell blocks and
# run them under the `set -euo pipefail` the plan itself mandates. Two separate
# defects have shipped because a block was syntactically fine but died at
# runtime, each time stranding a live 32 vCPU box:
#
#   * `grep -c .` exits 1 when the count is zero, so a poll loop that expects
#     "not visible yet" as its normal first state killed the whole script.
#
# Syntax checking cannot see that. This test parses every documented block and
# executes the fragile constructs for real.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill_dir="$root/skills/blacksmith-testbox"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

files=("$skill_dir/SKILL.md" "$skill_dir/benchmark.md" "$skill_dir/references/operations.md")
for file in "${files[@]}"; do
  test -f "$file" || { echo "FAIL: missing $file" >&2; exit 1; }
done

# 1. Every fenced bash block must parse under the shell the plan mandates.
blocks=0
while IFS= read -r block; do
  blocks=$((blocks + 1))
  printf 'set -euo pipefail\n%s\n' "$(cat "$block")" >"$work/block.sh"
  if ! bash -n "$work/block.sh" 2>"$work/err"; then
    echo "FAIL: $(basename "$block") does not parse:" >&2
    cat "$work/err" >&2
    exit 1
  fi
done < <(python3 - "$work" "${files[@]}" <<'PYX'
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
index = 0
for name in sys.argv[2:]:
    text = pathlib.Path(name).read_text(encoding="utf-8")
    for body in re.findall(r"```bash\n(.*?)```", text, re.S):
        index += 1
        path = out / f"{pathlib.Path(name).stem}-{index}.sh"
        path.write_text(body, encoding="utf-8")
        print(path)
PYX
)
test "$blocks" -gt 0 || { echo "FAIL: no bash blocks found; the parser broke" >&2; exit 1; }

# 2. Every counting construct must survive its normal zero case under set -e.
#    Extract each line that counts with grep -c and run it with an empty input.
found_counts=0
while IFS= read -r line; do
  found_counts=$((found_counts + 1))
  cat >"$work/count.sh" <<COUNT
set -euo pipefail
WAITING=""
waiting=""
$line
echo "survived"
COUNT
  if ! output="$(bash "$work/count.sh" 2>&1)" || [[ "$output" != *survived* ]]; then
    echo "FAIL: this counting line dies under set -e when nothing matches, which" >&2
    echo "      is its normal first state. Guard it with '|| true'." >&2
    echo "      $line" >&2
    exit 1
  fi
done < <(grep -rhE '^[[:space:]]*[A-Za-z_]+=.*grep -c' "${files[@]}" | sed 's/^[[:space:]]*//')
test "$found_counts" -gt 0 || { echo "FAIL: no counting lines found; the extractor broke" >&2; exit 1; }

echo "ok: $blocks documented bash blocks parse, $found_counts counting lines survive an empty result"
