#!/usr/bin/env bash
# After base autofix lands (base-autofix-settings-landed.sh): a run that had the settings area on fails
# when feat's settings exports are not the ones its Mac job made for the sources the tip still has, so
# base-autofix-since.sh keeps its changes for the next run instead of moving past exports that never
# landed (#22740's export, 2026-10-21). When a newer commit changed the settings sources, that is the next
# run's work: a warning. The source stamp is derived from each tree, never committed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../base-autofix-settings-landed.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }
schema=schemas/settings/settings-schema.json
mdm=docs/mdm/com.manaflow.cmux.json

# A fake defaults_guard.py: the source stamp of a ref is its sources.txt. It finds its repository the
# way the real one does. The run's commit has old exports; its Mac job made a new schema (in the
# exports dir) and found the MDM file unchanged (not in the dir).
setup() {
  rm -rf "$tmp/remote.git" "$tmp/lane" "$tmp/bot" "$tmp/exports"
  git init -q --bare -b feat "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/lane" 2>/dev/null
  (cd "$tmp/lane" && git checkout -q -b feat && mkdir -p scripts/ci schemas/settings docs/mdm \
    && cat > scripts/ci/defaults_guard.py <<'PY'
import subprocess, sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
cmd, ref = sys.argv[1], sys.argv[sys.argv.index("--ref") + 1]
if cmd != "source-stamp":
    sys.exit(2)
sys.stdout.write(subprocess.run(["git", "-C", str(root), "show", f"{ref}:sources.txt"],
                                capture_output=True, text=True, check=True).stdout)
PY
    for f in docs/mdm/com.manaflow.cmux.plist docs/mdm/com.manaflow.cmux.intune.plist docs/mdm/cmux-example.mobileconfig \
      docs/mdm/managed-preferences.md; do echo same > "$f"; done
    echo s1 > sources.txt && echo "schema old" > "$schema" && echo "mdm" > "$mdm" \
    && git add -A && git commit -q -m run && git push -q origin feat)
  run="$(git -C "$tmp/lane" rev-parse HEAD)"
  mkdir -p "$tmp/exports/schemas/settings" && echo "schema new" > "$tmp/exports/$schema"
  git init -q "$tmp/bot"
  git -C "$tmp/bot" remote add origin "file://$tmp/remote.git"
  git -C "$tmp/bot" fetch -q --depth=1 origin "+$run:refs/remotes/origin/feat"
  git -C "$tmp/bot" checkout -q -B feat refs/remotes/origin/feat
}
lane_commit() { # <file> <text>
  (cd "$tmp/lane" && echo "$2" > "$1" && git add -A && git commit -q -m "lane: $1" && git push -q origin feat)
}
landed() { (cd "$tmp/bot" && bash "$script" "file://$tmp/remote.git" feat "$run" "${1:-}" "$tmp/exports"); }

# 1. The run landed the exports it made: passes.
setup
lane_commit "$schema" "schema new"
landed > "$tmp/out" 2>&1 || fail "landed exports failed: $(cat "$tmp/out")"

# 2. The exports are still the old ones for the sources the run saw: fails with an error naming them.
setup
lane_commit README.md other
landed > "$tmp/out" 2>&1 && fail "exports that never landed passed: $(cat "$tmp/out")"
grep -q "::error::.*$schema" "$tmp/out" || fail "no error naming the stale schema: $(cat "$tmp/out")"

# 3. A newer commit changed the sources after the run's commit: the next run's work, a warning only.
setup
lane_commit sources.txt s2
landed > "$tmp/out" 2>&1 || fail "sources a newer commit changed failed this run: $(cat "$tmp/out")"
grep -q '::warning::' "$tmp/out" || fail "no warning for sources a newer commit changed: $(cat "$tmp/out")"

# 4. A newer commit changed an export the run found unchanged: it is not the one made for these sources.
setup
lane_commit "$schema" "schema new"
lane_commit "$mdm" "mdm hand-edited"
landed > "$tmp/out" 2>&1 && fail "an export changed after the run passed: $(cat "$tmp/out")"
grep -q "::error::.*$mdm" "$tmp/out" || fail "no error naming the changed MDM file: $(cat "$tmp/out")"

# 5. The Mac job retried at a commit with other sources (MADE_AT), and the tip has since gone back to the
#    run's own sources: the exports were made for sources the tip no longer has, so nothing made them for
#    the run's. It fails, so the next run's "since" keeps the run's changes (else no run makes them).
setup
rm -rf "$tmp/exports" && mkdir -p "$tmp/exports"
lane_commit sources.txt s2
made="$(git -C "$tmp/lane" rev-parse HEAD)"
lane_commit sources.txt s1
landed "$made" > "$tmp/out" 2>&1 && fail "the tip back at the run's sources passed with exports made for others: $(cat "$tmp/out")"
grep -q '::error::' "$tmp/out" || fail "no error when the tip went back to the run's sources: $(cat "$tmp/out")"

echo "base-autofix-settings-landed: PASS: a run fails when the exports it made for the tip's settings sources did not land, and only warns when a newer commit changed the sources"
