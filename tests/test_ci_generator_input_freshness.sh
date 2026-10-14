#!/usr/bin/env bash
# Behavior fixture: a PR behind base is regenerated from its immutable merge
# snapshot, so base defaults survive; a merge that keeps the PR input is red.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$root/scripts/cmux-next/check-generator-inputs.sh"
repo="$(mktemp -d "${TMPDIR:-/tmp}/cmux-generator-freshness.XXXXXX")"
trap 'rm -rf "$repo"' EXIT

git -C "$repo" init -q -b base
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
mkdir -p "$repo/schemas/settings" "$repo/schemas/defaults" "$repo/plans/cmux-next" "$repo/Packages/macOS/CmuxNext/Sources" "$repo/scripts/ci"
printf '{"rows":[]}\n' > "$repo/schemas/settings/settings-schema.json"
printf '{"defaults":{}}\n' > "$repo/schemas/defaults/cmux-next.json"
printf '{}\n' > "$repo/plans/cmux-next/action-surfaces.json"
printf '// source\n' > "$repo/Packages/macOS/CmuxNext/Sources/Defaults.swift"
printf '# guard\n' > "$repo/scripts/ci/defaults_guard.py"
git -C "$repo" add .
git -C "$repo" commit -q -m initial

git -C "$repo" checkout -qb pr
printf 'pr change\n' > "$repo/pr.txt"
git -C "$repo" add pr.txt
git -C "$repo" commit -q -m 'pr change'
pr="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q base
printf '{"rows":[{"key":"setting.baseOnly","default":true}]}\n' > "$repo/schemas/settings/settings-schema.json"
printf '{"defaults":{"setting.baseOnly":true}}\n' > "$repo/schemas/defaults/cmux-next.json"
git -C "$repo" add schemas/settings/settings-schema.json schemas/defaults/cmux-next.json
git -C "$repo" commit -q -m 'base adds a default'
base="$(git -C "$repo" rev-parse HEAD)"

# A normal immutable merge snapshot is green even though the PR head itself is
# behind base. The generated snapshot is read from the merged tree.
git -C "$repo" checkout -qb merged "$pr"
git -C "$repo" merge -q --no-edit base
merged="$(git -C "$repo" rev-parse HEAD)"
(cd "$repo" && "$checker" --base-ref "$base" --merge-ref "$merged")
python3 - "$repo" <<'PYTEST'
import json, pathlib, sys
repo = pathlib.Path(sys.argv[1])
schema = json.loads((repo / 'schemas/settings/settings-schema.json').read_text())
assert 'setting.baseOnly' in {row['key'] for row in schema['rows']}
PYTEST
printf '%s\n' 'green: merged PR retains base default'

# A merge resolution that silently keeps the PR generator input stays red.
git -C "$repo" checkout -qb stale "$pr"
printf '{"rows":[{"key":"setting.prOnly","default":false}]}\n' > "$repo/schemas/settings/settings-schema.json"
git -C "$repo" add schemas/settings/settings-schema.json
git -C "$repo" commit -q -m 'pr edits generator input'
if git -C "$repo" merge -q --no-edit base; then
  echo 'expected a generator-input merge conflict' >&2
  exit 1
fi
git -C "$repo" checkout -q --ours schemas/settings/settings-schema.json
git -C "$repo" add schemas/settings/settings-schema.json
git -C "$repo" commit -q -m 'keep stale PR input'
stale="$(git -C "$repo" rev-parse HEAD)"
if (cd "$repo" && "$checker" --base-ref "$base" --merge-ref "$stale") >"$repo/red.log" 2>&1; then
  cat "$repo/red.log" >&2
  echo 'expected stale merge snapshot to be rejected' >&2
  exit 1
fi
grep -q 'merge snapshot is stale' "$repo/red.log"
printf '%s\n' 'red: stale merge resolution refused'
