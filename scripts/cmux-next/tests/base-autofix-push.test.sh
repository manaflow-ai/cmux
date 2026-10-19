#!/usr/bin/env bash
# scripts/cmux-next/base-autofix-push.sh lands base autofix's repair commit on
# feat-cmux-next even when the branch moved during the run, as long as no commit
# since touched a file the repair writes. Before it, a run that saw the branch
# move failed, and with a push every minute or two no repair landed for hours
# (the settings export stamp stayed stale from 05:27 on 2026-10-19).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../base-autofix-push.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }

# A remote with one base commit, a clone at it holding a repair commit, and a
# second clone that pushes "other people's" commits.
setup() {
  rm -rf "$tmp/remote.git" "$tmp/bot" "$tmp/lane"
  git init -q --bare -b feat "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/lane" 2>/dev/null
  (cd "$tmp/lane" && git checkout -q -b feat && echo src > source.txt && echo old > generated.txt \
    && git add -A && git commit -q -m base && git push -q origin feat)
  git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/bot"  # actions/checkout is shallow
  base="$(git -C "$tmp/bot" rev-parse HEAD)"
  (cd "$tmp/bot" && echo repaired > generated.txt && git commit -q -am "chore(next): base autofix")
}
lane_push() { # <file> <text>
  (cd "$tmp/lane" && git pull -q --ff-only origin feat && echo "$2" > "$1" && git add -A \
    && git commit -q -m "lane edits $1" && git push -q origin feat)
}
remote_tip() { git -C "$tmp/remote.git" rev-parse feat; }
remote_show() { git -C "$tmp/remote.git" show "feat:$1"; }
run() { (cd "$tmp/bot" && bash "$script" "$tmp/remote.git" feat "$base"); }

# 1. The branch did not move: a plain push of the repair.
setup
repair="$(git -C "$tmp/bot" rev-parse HEAD)"
run > "$tmp/out" || fail "an unmoved branch did not take the repair: $(cat "$tmp/out")"
[[ "$(remote_tip)" == "$repair" ]] || fail "the remote is not at the repair commit"

# 2. The branch moved in files the repair does not write: the repair lands on the new tip.
setup
lane_push source.txt "src v2"
moved="$(remote_tip)"
run > "$tmp/out" || fail "a moved branch did not take the repair: $(cat "$tmp/out")"
[[ "$(git -C "$tmp/remote.git" rev-parse feat^)" == "$moved" ]] || fail "the repair is not on top of the moved tip"
[[ "$(remote_show generated.txt)" == repaired ]] || fail "the repair's file is not on the branch"
[[ "$(remote_show source.txt)" == "src v2" ]] || fail "the moved tip's change was lost"
grep -q "moved" "$tmp/out" || fail "the run does not say the branch moved"

# 3. A commit since touched a file the repair writes: nothing is pushed, and the run fails.
setup
lane_push generated.txt "lane wrote it"
moved="$(remote_tip)"
if run > "$tmp/out" 2>&1; then fail "a repair over a newer edit of its file was pushed"; fi
[[ "$(remote_tip)" == "$moved" ]] || fail "the remote moved although the repair was refused"
grep -q "generated.txt" "$tmp/out" || fail "the refusal does not name the file: $(cat "$tmp/out")"

echo "PASS: base autofix lands its repair on a moved feat-cmux-next unless a newer commit wrote the same files"
