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

# 4. An earlier base autofix run already replayed its repair of the same file: this run's
#    repair (from a newer tree) wins instead of being refused by the bot's own commit.
setup
lane_push source.txt "src v2"
(cd "$tmp/lane" && git pull -q --ff-only origin feat && echo "older repair" > generated.txt \
  && git commit -q -am "chore(next): base autofix at 0123456789ab" && git push -q origin feat)
moved="$(remote_tip)"
run > "$tmp/out" 2>&1 || fail "a repair over an earlier autofix commit was refused: $(cat "$tmp/out")"
[[ "$(git -C "$tmp/remote.git" rev-parse feat^)" == "$moved" ]] || fail "the repair is not on top of the bot's commit"
[[ "$(remote_show generated.txt)" == repaired ]] || fail "the newer repair did not replace the older one"
[[ "$(remote_show source.txt)" == "src v2" ]] || fail "the moved tip's change was lost"

# 5. The tip already holds exactly this repair: nothing is pushed, and the run passes.
setup
(cd "$tmp/lane" && git pull -q --ff-only origin feat && echo repaired > generated.txt \
  && git commit -q -am "chore(next): base autofix at 0123456789ab" && git push -q origin feat)
moved="$(remote_tip)"
run > "$tmp/out" 2>&1 || fail "an already-landed repair failed the run: $(cat "$tmp/out")"
[[ "$(remote_tip)" == "$moved" ]] || fail "an empty repair commit was pushed"

# 6. The repair adds a file in a directory a newer commit deleted: refused, nothing pushed.
setup
(cd "$tmp/lane" && mkdir -p page && echo src > page/source.txt && git add -A && git commit -q -m "add page" && git push -q origin feat)
rm -rf "$tmp/bot"; git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/bot"
base="$(git -C "$tmp/bot" rev-parse HEAD)"
(cd "$tmp/bot" && mkdir -p page && echo gen > page/generated.txt && git add -A && git commit -q -m "chore(next): base autofix")
(cd "$tmp/lane" && git rm -q -r page && git commit -q -m "drop page" && git push -q origin feat)
moved="$(remote_tip)"
if run > "$tmp/out" 2>&1; then fail "a generated file for a deleted directory was pushed"; fi
[[ "$(remote_tip)" == "$moved" ]] || fail "the remote moved although the repair was refused"
grep -q "page/generated.txt" "$tmp/out" || fail "the refusal does not name the file: $(cat "$tmp/out")"

# The cmux NEXT tree from here on: the settings exports (schema, stamp, docs/mdm) read
# CmuxNextSettings; the strings tables and the defaults snapshot follow them; the CI
# target graph reads Packages/. A fake defaults_guard.py derives the snapshot from the
# settings schema and a flag in the sources, as the real one reads both.
setup_next() {
  rm -rf "$tmp/remote.git" "$tmp/bot" "$tmp/lane"
  git init -q --bare -b feat "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/lane" 2>/dev/null
  (cd "$tmp/lane" && git checkout -q -b feat \
    && mkdir -p Packages/macOS/CmuxNext/Sources/CmuxNextSettings schemas/settings schemas/settings-export \
      docs/mdm schemas/defaults scripts/ci webviews/src/pages/home/generated \
    && echo "setting v1" > Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift \
    && echo "flag on" > Packages/macOS/CmuxNext/Sources/Flags.swift \
    && echo "graph old" > Packages/macOS/CmuxNext/ci-target-graph.json \
    && echo "schema old" > schemas/settings/settings-schema.json \
    && echo "stamp old" > schemas/settings-export/settings-schema.sources.sha256 \
    && echo "mdm old" > docs/mdm/com.manaflow.cmux.json \
    && echo "strings old" > webviews/src/pages/home/generated/strings.json \
    && printf '%s\n' 'import pathlib' \
      'r = pathlib.Path(".")' \
      'out = r.joinpath("schemas/settings/settings-schema.json").read_text() + r.joinpath("Packages/macOS/CmuxNext/Sources/Flags.swift").read_text()' \
      'r.joinpath("schemas/defaults/cmux-next.json").write_text(out)' > scripts/ci/defaults_guard.py \
    && python3 scripts/ci/defaults_guard.py snapshot \
    && git add -A && git commit -q -m base && git push -q origin feat)
  git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/bot"
  base="$(git -C "$tmp/bot" rev-parse HEAD)"
  (cd "$tmp/bot" && echo "graph new" > Packages/macOS/CmuxNext/ci-target-graph.json \
    && echo "schema new" > schemas/settings/settings-schema.json \
    && echo "stamp new" > schemas/settings-export/settings-schema.sources.sha256 \
    && echo "mdm new" > docs/mdm/com.manaflow.cmux.json \
    && echo "strings new" > webviews/src/pages/home/generated/strings.json \
    && python3 scripts/ci/defaults_guard.py snapshot \
    && git commit -q -am "chore(next): base autofix at ${base:0:12}")
}
lane_commit() { # <subject> <file> <text> [<file> <text>]...
  local subject="$1"; shift
  (cd "$tmp/lane" && git pull -q --ff-only origin feat \
    && while (( $# )); do mkdir -p "$(dirname "$1")" && echo "$2" > "$1" && shift 2; done \
    && git add -A && git commit -q -m "$subject" && git push -q origin feat)
}
settings_files=(schemas/settings/settings-schema.json schemas/settings-export/settings-schema.sources.sha256 docs/mdm/com.manaflow.cmux.json)

# 7. The livelock (base autofix run 39553409406, 2026-10-21): feat-cmux-next moved during the
#    ten-minute Mac export, and the move touched CmuxNextSettings, the exports' inputs. The
#    exports regenerated at BASE_SHA still land with their stamp, which names the sources they
#    were made from, so the stamp check flags only the sources changed since and the newer run
#    regenerates those. Leaving them to the next run left them stale while merges kept coming.
setup_next
lane_commit "lane edits a setting" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2"
moved="$(remote_tip)"
run > "$tmp/out" 2>&1 || fail "the settings exports were left although only their inputs moved: $(cat "$tmp/out")"
[[ "$(git -C "$tmp/remote.git" rev-parse feat^)" == "$moved" ]] || fail "the repair is not on top of the moved tip"
for f in "${settings_files[@]}"; do
  [[ "$(remote_show "$f")" == *new ]] || fail "$f did not land: $(remote_show "$f")"
done

# 8. The base workflow lands its repair through base-autofix-push.sh, so the run above is the
#    path feat-cmux-next takes, and no step leaves a repair to the next run because the tip
#    changed the repair's inputs.
workflow="$here/../../../.github/workflows/cmux-next-base-autofix.yml"
# shellcheck disable=SC2016 # the workflow's own text
grep -qF 'scripts/cmux-next/base-autofix-push.sh "$remote" feat-cmux-next "$HEAD_SHA"' "$workflow" \
  || fail "the Push the repairs step does not land the repair with base-autofix-push.sh"
if grep -q 'changed their inputs' "$workflow"; then
  fail "the workflow still leaves a repair to the next run when the tip changed its inputs"
fi

# 9. A newer commit wrote one repaired file: only that file waits, the rest lands, and the run
#    fails, so the next run still diffs from an older successful one.
setup_next
lane_commit "lane regenerates the graph" Packages/macOS/CmuxNext/ci-target-graph.json "graph lane"
if run > "$tmp/out" 2>&1; then fail "a partial repair passed the run"; fi
[[ "$(remote_show Packages/macOS/CmuxNext/ci-target-graph.json)" == "graph lane" ]] || fail "the newer graph was overwritten"
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema new" ]] \
  || fail "the settings exports did not land beside a newer graph: $(cat "$tmp/out")"
grep -q "ci-target-graph.json" "$tmp/out" || fail "the run does not name the file it left: $(cat "$tmp/out")"

# 10. The settings exports land together or not at all: a newer commit that wrote only the stamp
#     keeps the schema and docs/mdm out too, and the strings tables built from the schema.
setup_next
lane_commit "lane regenerates the stamp" schemas/settings-export/settings-schema.sources.sha256 "stamp lane"
if run > "$tmp/out" 2>&1; then fail "a repair without its settings exports passed the run"; fi
[[ "$(remote_show schemas/settings-export/settings-schema.sources.sha256)" == "stamp lane" ]] || fail "the newer stamp was overwritten"
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema old" ]] || fail "the schema landed without its stamp"
[[ "$(remote_show docs/mdm/com.manaflow.cmux.json)" == "mdm old" ]] || fail "docs/mdm landed without its stamp"
[[ "$(remote_show webviews/src/pages/home/generated/strings.json)" == "strings old" ]] || fail "strings built from a held-back schema landed"
[[ "$(remote_show Packages/macOS/CmuxNext/ci-target-graph.json)" == "graph new" ]] || fail "the graph did not land: $(cat "$tmp/out")"

# 11. A repair made from a newer tree already landed (a late re-run of an older run): the older
#     repair never overwrites it.
setup_next
lane_commit "lane edits a setting" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2"
newer="$(remote_tip)"
lane_commit "chore(next): base autofix at ${newer:0:12}" schemas/settings/settings-schema.json "schema newer" \
  schemas/settings-export/settings-schema.sources.sha256 "stamp newer" docs/mdm/com.manaflow.cmux.json "mdm newer"
if run > "$tmp/out" 2>&1; then fail "an older repair under a newer one passed the run"; fi
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema newer" ]] || fail "an older run overwrote a newer repair"
[[ "$(remote_show schemas/settings-export/settings-schema.sources.sha256)" == "stamp newer" ]] || fail "an older run overwrote a newer stamp"

# 12. The defaults snapshot reads flags anywhere in the sources, so on a moved tip it is derived
#     again there from the landed exports, never copied from BASE_SHA.
setup_next
lane_commit "lane flips a flag" Packages/macOS/CmuxNext/Sources/Flags.swift "flag off"
run > "$tmp/out" 2>&1 || fail "the repair with a snapshot did not land: $(cat "$tmp/out")"
[[ "$(remote_show schemas/defaults/cmux-next.json)" == "$(printf 'schema new\nflag off')" ]] \
  || fail "the snapshot is not the moved tip's: $(remote_show schemas/defaults/cmux-next.json)"

# 13. The retries are bounded: a remote that refuses every push ends the run after the attempts.
setup_next
printf '#!/bin/sh\nexit 1\n' > "$tmp/remote.git/hooks/pre-receive"; chmod +x "$tmp/remote.git/hooks/pre-receive"
if (cd "$tmp/bot" && CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS=2 timeout 60 bash "$script" "$tmp/remote.git" feat "$base") > "$tmp/out" 2>&1; then
  fail "a refused push passed the run"
fi
grep -q "attempt 2 of 2" "$tmp/out" || fail "the run did not stop after its attempts: $(cat "$tmp/out")"

echo "PASS: base autofix lands its repair on a moved feat-cmux-next; only the files a newer commit wrote wait"
