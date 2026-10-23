#!/usr/bin/env bash
# After base autofix lands (base-autofix-settings-landed.sh): a run that had the settings area on fails
# when feat's settings exports are still stale for the sources the run itself saw, so base-autofix-since.sh
# keeps its changes for the next run instead of moving past exports that never landed (#22740's export,
# 2026-10-21). When a newer commit changed the settings sources, that is the next run's work: a warning.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../base-autofix-settings-landed.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }

# A fake defaults_guard.py: the stamp is current when stamp.txt equals sources.txt at the ref, and the
# source stamp of a ref is its sources.txt. It finds its repository the way the real one does.
setup() { # <stamp at the run's commit>
  rm -rf "$tmp/remote.git" "$tmp/lane" "$tmp/bot"
  git init -q --bare -b feat "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/lane" 2>/dev/null
  (cd "$tmp/lane" && git checkout -q -b feat && mkdir -p scripts/ci \
    && cat > scripts/ci/defaults_guard.py <<'PY'
import subprocess, sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
def show(ref, path):
    return subprocess.run(["git", "-C", str(root), "show", f"{ref}:{path}"], capture_output=True, text=True, check=True).stdout
cmd, ref = sys.argv[1], sys.argv[sys.argv.index("--ref") + 1]
if cmd == "source-stamp":
    sys.stdout.write(show(ref, "sources.txt"))
elif cmd == "check-stamp":
    if show(ref, "stamp.txt") != show(ref, "sources.txt"):
        print("settings exports are stale")
        sys.exit(1)
PY
    echo s1 > sources.txt && echo "$1" > stamp.txt && git add -A && git commit -q -m run && git push -q origin feat)
  run="$(git -C "$tmp/lane" rev-parse HEAD)"
  git init -q "$tmp/bot"
  git -C "$tmp/bot" remote add origin "file://$tmp/remote.git"
  git -C "$tmp/bot" fetch -q --depth=1 origin "+$run:refs/remotes/origin/feat"
  git -C "$tmp/bot" checkout -q -B feat refs/remotes/origin/feat
}
lane_commit() { # <file> <text>
  (cd "$tmp/lane" && echo "$2" > "$1" && git add -A && git commit -q -m "lane: $1" && git push -q origin feat)
}
landed() { (cd "$tmp/bot" && bash "$script" "file://$tmp/remote.git" feat "$run"); }

# 1. The run landed current exports: passes.
setup s0
lane_commit stamp.txt s1
landed > "$tmp/out" 2>&1 || fail "current exports after landing failed: $(cat "$tmp/out")"

# 2. The exports are still stale for the sources the run saw: fails with an error.
setup s0
lane_commit README.md other
landed > "$tmp/out" 2>&1 && fail "stale exports for the run's own sources passed: $(cat "$tmp/out")"
grep -q '::error::' "$tmp/out" || fail "no error for stale exports: $(cat "$tmp/out")"

# 3. A newer commit changed the sources after the run's commit: the next run's work, a warning only.
setup s1
lane_commit sources.txt s2
landed > "$tmp/out" 2>&1 || fail "sources a newer commit changed failed this run: $(cat "$tmp/out")"
grep -q '::warning::' "$tmp/out" || fail "no warning for sources a newer commit changed: $(cat "$tmp/out")"

echo "base-autofix-settings-landed: PASS: a run fails when its own settings sources' exports are still stale after landing, and only warns when a newer commit changed them"
