#!/usr/bin/env bash
# Behavior fixture for the cmux-next autofix freshness boundary. A stale PR
# must stop before its generator can overwrite a base default; after the PR
# incorporates base, the same generator keeps that default.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$root/scripts/cmux-next/check-generator-inputs.sh"
repo="$(mktemp -d "${TMPDIR:-/tmp}/cmux-generator-freshness.XXXXXX")"
trap 'rm -rf "$repo"' EXIT

git -C "$repo" init -q -b base
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
mkdir -p "$repo/plans/cmux-next" "$repo/schemas/settings" "$repo/schemas/defaults" "$repo/Packages/macOS/CmuxNext/Sources" "$repo/scripts/ci"
printf '{"actions":[]}\n' > "$repo/plans/cmux-next/action-surfaces.json"
printf '{"rows":[]}\n' > "$repo/schemas/settings/settings-schema.json"
printf '{"defaults":{}}\n' > "$repo/schemas/defaults/cmux-next.json"
printf '// generator source\n' > "$repo/Packages/macOS/CmuxNext/Sources/Defaults.swift"
printf '# generator\n' > "$repo/scripts/ci/defaults_guard.py"
git -C "$repo" add .
git -C "$repo" commit -q -m initial

git -C "$repo" checkout -qb pr
printf 'pr change\n' > "$repo/pr.txt"
git -C "$repo" add pr.txt
git -C "$repo" commit -q -m 'pr change'

git -C "$repo" checkout -q base
printf '{"rows":[{"key":"setting.baseOnly","default":true}]}\n' > "$repo/schemas/settings/settings-schema.json"
printf '{"defaults":{"setting.baseOnly":true}}\n' > "$repo/schemas/defaults/cmux-next.json"
git -C "$repo" add schemas/settings/settings-schema.json
git -C "$repo" add schemas/defaults/cmux-next.json
git -C "$repo" commit -q -m 'base adds a default'
git -C "$repo" checkout -q pr

# Red: the old head-only generator sees no baseOnly row, while the base snapshot
# already has it. It would drop that key, so the freshness gate must reject this
# tree before regeneration.
python3 - "$repo" <<'PY'
import json
import pathlib
import subprocess
import sys

repo = pathlib.Path(sys.argv[1])
schema = json.loads((repo / "schemas/settings/settings-schema.json").read_text())
snapshot = {row["key"]: row["default"] for row in schema["rows"]}
assert "setting.baseOnly" not in snapshot
base = json.loads(subprocess.check_output(["git", "-C", str(repo), "show", "base:schemas/defaults/cmux-next.json"], text=True))
assert "setting.baseOnly" in base["defaults"]
PY
if (cd "$repo" && "$checker" --base-ref base) >"$repo/red.log" 2>&1; then
  cat "$repo/red.log" >&2
  echo "expected stale generator inputs to be rejected" >&2
  exit 1
fi
grep -q "generator inputs are stale" "$repo/red.log"
printf '%s\n' 'red: stale PR refused before generation'

# Red again: a merge can resolve a generator-input conflict by keeping the PR
# parent. The merge is still stale until the source is explicitly refreshed.
git -C "$repo" branch merge-pr pr
git -C "$repo" checkout -q merge-pr
printf '{"rows":[{"key":"setting.prOnly","default":false}]}\n' > "$repo/schemas/settings/settings-schema.json"
git -C "$repo" add schemas/settings/settings-schema.json
git -C "$repo" commit -q -m 'pr edits the same generator input'
if git -C "$repo" merge -q --no-edit base; then
  echo "expected a generator-input merge conflict" >&2
  exit 1
fi
git -C "$repo" checkout -q --ours schemas/settings/settings-schema.json
git -C "$repo" add schemas/settings/settings-schema.json
git -C "$repo" commit -q -m 'merge base but keep stale generator input'
if (cd "$repo" && "$checker" --base-ref base) >"$repo/merge-red.log" 2>&1; then
  cat "$repo/merge-red.log" >&2
  echo "expected stale merge resolution to be rejected" >&2
  exit 1
fi
grep -q "resolved away from the base parent" "$repo/merge-red.log"
printf '%s\n' 'red: stale merge resolution refused'
printf '{"rows":[{"key":"setting.baseOnly","default":true},{"key":"setting.prOnly","default":false}]}\n' > "$repo/schemas/settings/settings-schema.json"
git -C "$repo" add schemas/settings/settings-schema.json
git -C "$repo" commit -q -m 'refresh generator input after merge'
(cd "$repo" && "$checker" --base-ref base)
printf '%s\n' 'green: refreshed merge resolution allowed'

# Green: once the PR incorporates base, the same head-only generator retains
# the base default and the freshness gate allows the run.
git -C "$repo" merge -q --no-edit base
(cd "$repo" && "$checker" --base-ref base)
python3 - "$repo" <<'PY'
import json
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
schema = json.loads((repo / "schemas/settings/settings-schema.json").read_text())
snapshot = {row["key"]: row["default"] for row in schema["rows"]}
assert snapshot["setting.baseOnly"] is True
PY
printf '%s\n' 'green: merged PR retains base default'
