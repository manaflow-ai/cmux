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
mkdir -p "$repo/schemas/settings" "$repo/schemas/defaults" "$repo/plans/cmux-next" "$repo/Packages/macOS/CmuxNext/Sources" "$repo/scripts/ci" "$repo/web/data" "$repo/web/scripts"
printf '{"rows":[]}\n' > "$repo/schemas/settings/settings-schema.json"
printf '{"defaults":{}}\n' > "$repo/schemas/defaults/cmux-next.json"
printf '{}\n' > "$repo/plans/cmux-next/action-surfaces.json"
printf '// source\n' > "$repo/Packages/macOS/CmuxNext/Sources/Defaults.swift"
printf '# guard\n' > "$repo/scripts/ci/defaults_guard.py"
printf '{"sections":[]}\n' > "$repo/web/data/cmux-shortcuts.generated.json"
printf '// exporter\n' > "$repo/web/scripts/export-docs-shortcuts.ts"
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

# The docs shortcuts exporter is a generator input too: a merge resolution
# that keeps the PR's older exporter over the base's is refused.
for path in web/scripts/export-docs-shortcuts.ts; do
  git -C "$repo" checkout -q base
  git -C "$repo" checkout -qb "base-$path" base
  printf 'base: newer exporter\n' > "$repo/$path"
  git -C "$repo" commit -qam "base updates $path"
  newer_base="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -qb "kept-$path" "$pr"
  printf 'pr: older copy\n' > "$repo/$path"
  git -C "$repo" commit -qam "pr carries an older $path"
  git -C "$repo" merge -q --no-edit "base-$path" >/dev/null 2>&1 && { echo "expected a conflict on $path" >&2; exit 1; }
  git -C "$repo" checkout -q --ours "$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -q -m "keep the PR's $path"
  kept="$(git -C "$repo" rev-parse HEAD)"
  if (cd "$repo" && "$checker" --base-ref "$newer_base" --merge-ref "$kept") >"$repo/red.log" 2>&1; then
    cat "$repo/red.log" >&2
    echo "expected a merge snapshot that kept the PR's $path to be rejected" >&2
    exit 1
  fi
  grep -qF "$path (merge snapshot kept the PR side)" "$repo/red.log"
  printf '%s\n' "red: stale $path refused"
done
