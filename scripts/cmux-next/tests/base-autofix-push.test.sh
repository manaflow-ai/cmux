#!/usr/bin/env bash
# scripts/cmux-next/base-autofix-push.sh lands base autofix's repair commit on
# feat-cmux-next even when the branch moved during the run, file by file: a file
# lands unless the move touched its input areas, a newer commit wrote it, or an
# export or input it is built from waits. Before it, a run that saw the branch
# move failed, and with a push every minute or two no repair landed for hours
# (the settings exports stayed stale from 05:27 on 2026-10-19).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../base-autofix-push.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }
# A generated file whose inputs (the action exports) the edits below never touch.
gen=web/data/cmux-shortcuts.generated.json
cap=plans/cmux-next/daemon-capabilities.json

# A remote with one base commit, a clone at it holding a repair commit, and a
# second clone that pushes "other people's" commits.
setup() {
  with_cap="${1:-}"
  rm -rf "$tmp/remote.git" "$tmp/bot" "$tmp/lane"
  git init -q --bare -b feat "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/lane" 2>/dev/null
  (cd "$tmp/lane" && git checkout -q -b feat && mkdir -p web/data \
    && echo src > source.txt && echo old > "$gen" \
    && if [[ "$with_cap" == cap ]]; then mkdir -p "$(dirname "$cap")" && echo old > "$cap"; fi \
    && git add -A && git commit -q -m base && git push -q origin feat)
  git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/bot"  # actions/checkout is shallow
  base="$(git -C "$tmp/bot" rev-parse HEAD)"
  (cd "$tmp/bot" && echo repaired > "$gen" \
    && if [[ "$with_cap" == cap ]]; then echo repaired > "$cap"; fi \
    && git commit -q -am "chore(next): base autofix")
}
lane_push() { # <file> <text>
  (cd "$tmp/lane" && git pull -q --ff-only origin feat && mkdir -p "$(dirname "$1")" && echo "$2" > "$1" && git add -A \
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
[[ "$(remote_show "$gen")" == repaired ]] || fail "the repair's file is not on the branch"
[[ "$(remote_show source.txt)" == "src v2" ]] || fail "the moved tip's change was lost"
grep -q "moved" "$tmp/out" || fail "the run does not say the branch moved"

# A capability source move holds the run's export instead of landing a catalog
# parsed from the older tip.
setup cap
lane_push Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift "capability source v2"
moved="$(remote_tip)"
if run > "$tmp/out" 2>&1; then fail "a capability export made before its source moved was pushed"; fi
[[ "$(remote_show "$cap")" == old ]] || fail "the stale capability export landed after its source moved"
grep -qF "$cap" "$tmp/out" || fail "the capability refusal does not name the export: $(cat "$tmp/out")"

# 3. A commit since touched a file the repair writes: nothing is pushed, and the run fails.
setup
lane_push "$gen" "lane wrote it"
moved="$(remote_tip)"
if run > "$tmp/out" 2>&1; then fail "a repair over a newer edit of its file was pushed"; fi
[[ "$(remote_tip)" == "$moved" ]] || fail "the remote moved although the repair was refused"
grep -qF "$gen" "$tmp/out" || fail "the refusal does not name the file: $(cat "$tmp/out")"

# 4. An earlier base autofix run already replayed its repair of the same file: this run's
#    repair (from a newer tree) wins instead of being refused by the bot's own commit.
setup
lane_push source.txt "src v2"
(cd "$tmp/lane" && git pull -q --ff-only origin feat && echo "older repair" > "$gen" \
  && git commit -q -am "chore(next): base autofix at 0123456789ab" && git push -q origin feat)
moved="$(remote_tip)"
run > "$tmp/out" 2>&1 || fail "a repair over an earlier autofix commit was refused: $(cat "$tmp/out")"
[[ "$(git -C "$tmp/remote.git" rev-parse feat^)" == "$moved" ]] || fail "the repair is not on top of the bot's commit"
[[ "$(remote_show "$gen")" == repaired ]] || fail "the newer repair did not replace the older one"
[[ "$(remote_show source.txt)" == "src v2" ]] || fail "the moved tip's change was lost"

# 5. The tip already holds exactly this repair: nothing is pushed, and the run passes.
setup
(cd "$tmp/lane" && git pull -q --ff-only origin feat && echo repaired > "$gen" \
  && git commit -q -am "chore(next): base autofix at 0123456789ab" && git push -q origin feat)
moved="$(remote_tip)"
run > "$tmp/out" 2>&1 || fail "an already-landed repair failed the run: $(cat "$tmp/out")"
[[ "$(remote_tip)" == "$moved" ]] || fail "an empty repair commit was pushed"

# 6. The repair adds a file in a directory a newer commit deleted: refused, nothing pushed.
setup
(cd "$tmp/lane" && mkdir -p cmux-tui/bindings/page && echo src > cmux-tui/bindings/page/source.txt && git add -A && git commit -q -m "add page" && git push -q origin feat)
rm -rf "$tmp/bot"; git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/bot"
base="$(git -C "$tmp/bot" rev-parse HEAD)"
(cd "$tmp/bot" && mkdir -p cmux-tui/bindings/page && echo gen > cmux-tui/bindings/page/generated.txt && git add -A && git commit -q -m "chore(next): base autofix")
(cd "$tmp/lane" && git rm -q -r cmux-tui/bindings/page && git commit -q -m "drop page" && git push -q origin feat)
moved="$(remote_tip)"
if run > "$tmp/out" 2>&1; then fail "a generated file for a deleted directory was pushed"; fi
[[ "$(remote_tip)" == "$moved" ]] || fail "the remote moved although the repair was refused"
grep -q "cmux-tui/bindings/page/generated.txt" "$tmp/out" || fail "the refusal does not name the file: $(cat "$tmp/out")"

# The cmux NEXT tree from here on: the settings exports (schema, docs/mdm) read
# CmuxNextSettings; the strings tables and the defaults snapshot follow them; the CI
# target graph reads Packages/. A fake defaults_guard.py derives the snapshot from the
# settings schema and a flag file, as the real one reads the schema and flags across the
# sources; the fake flag file sits outside every input area so a flag edit moves nothing else.
setup_next() {
  rm -rf "$tmp/remote.git" "$tmp/bot" "$tmp/lane"
  git init -q --bare -b feat "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/lane" 2>/dev/null
  (cd "$tmp/lane" && git checkout -q -b feat \
    && mkdir -p Packages/macOS/CmuxNext/Sources/CmuxNextSettings schemas/settings \
      docs/mdm schemas/defaults scripts/ci webviews/src/pages/home/generated \
    && echo "setting v1" > Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift \
    && echo "flag on" > Flags.swift \
    && echo "graph old" > Packages/macOS/CmuxNext/ci-target-graph.json \
    && echo "schema old" > schemas/settings/settings-schema.json \
    && echo "plist old" > docs/mdm/com.manaflow.cmux.plist \
    && echo "mdm old" > docs/mdm/com.manaflow.cmux.json \
    && echo "strings old" > webviews/src/pages/home/generated/strings.json \
    && cat > scripts/ci/defaults_guard.py <<'GUARD' &&
import pathlib, subprocess, sys
# source-stamp --ref R: the stamp R's settings sources give.
if sys.argv[1:2] == ["source-stamp"]:
    ref = sys.argv[sys.argv.index("--ref") + 1]
    source = subprocess.run(["git", "show", f"{ref}:Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift"],
                            capture_output=True, text=True, check=True).stdout.strip()
    print(f"stamp for {source}")
    sys.exit(0)
r = pathlib.Path(".")
out = r.joinpath("schemas/settings/settings-schema.json").read_text() + r.joinpath("Flags.swift").read_text()
r.joinpath("schemas/defaults/cmux-next.json").write_text(out)
GUARD
    python3 scripts/ci/defaults_guard.py snapshot \
    && git add -A && git commit -q -m base && git push -q origin feat)
  git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/bot"
  base="$(git -C "$tmp/bot" rev-parse HEAD)"
  (cd "$tmp/bot" && echo "graph new" > Packages/macOS/CmuxNext/ci-target-graph.json \
    && echo "schema new" > schemas/settings/settings-schema.json \
    && echo "plist new" > docs/mdm/com.manaflow.cmux.plist \
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
settings_files=(schemas/settings/settings-schema.json docs/mdm/com.manaflow.cmux.plist docs/mdm/com.manaflow.cmux.json)

# 7. feat-cmux-next moved during the ten-minute Mac export and the move touched CmuxNextSettings,
#    the exports' inputs (a revert, say). The exports made at BASE_SHA could be wrong at the tip,
#    so none of them lands, nor what is built from them or the same Packages/ inputs; the run
#    fails and names them, and the newer run regenerates them (#22474's rule).
setup_next
lane_commit "lane edits a setting" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2"
moved="$(remote_tip)"
if run > "$tmp/out" 2>&1; then fail "exports whose inputs moved passed the run"; fi
[[ "$(remote_tip)" == "$moved" ]] || fail "a repair whose inputs all moved was pushed"
for f in "${settings_files[@]}"; do
  [[ "$(remote_show "$f")" == *old ]] || fail "$f landed although its inputs moved: $(remote_show "$f")"
done
grep -q "schemas/settings/settings-schema.json" "$tmp/out" || fail "the run does not name the held export: $(cat "$tmp/out")"

# 8. The base workflow lands its repair through base-autofix-land.sh, which pushes with
#    base-autofix-push.sh, so the runs here are the path feat-cmux-next takes.
workflow="$here/../../../.github/workflows/cmux-next-base-autofix.yml"
# shellcheck disable=SC2016 # the workflow's own text
grep -qF 'scripts/cmux-next/base-autofix-land.sh "$remote" feat-cmux-next "$HEAD_SHA"' "$workflow" \
  || fail "the Push the repairs step does not land the repair with base-autofix-land.sh"
grep -qF 'base-autofix-push.sh' "$here/../base-autofix-land.sh" \
  || fail "base-autofix-land.sh does not push with base-autofix-push.sh"

# 9. A newer commit wrote one repaired file: only that file waits, the rest lands, and the run
#    fails, so the next run still diffs from an older successful one.
setup_next
lane_commit "lane regenerates the graph" Packages/macOS/CmuxNext/ci-target-graph.json "graph lane"
if run > "$tmp/out" 2>&1; then fail "a partial repair passed the run"; fi
[[ "$(remote_show Packages/macOS/CmuxNext/ci-target-graph.json)" == "graph lane" ]] || fail "the newer graph was overwritten"
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema new" ]] \
  || fail "the settings exports did not land beside a newer graph: $(cat "$tmp/out")"
grep -q "ci-target-graph.json" "$tmp/out" || fail "the run does not name the file it left: $(cat "$tmp/out")"
[[ "$(remote_show webviews/src/pages/home/generated/strings.json)" == "strings old" ]] \
  || fail "strings whose Packages/ inputs moved landed"
[[ "$(remote_show schemas/defaults/cmux-next.json)" == "$(printf 'schema old\nflag on')" ]] \
  || fail "the defaults snapshot landed beside a file that waits: $(remote_show schemas/defaults/cmux-next.json)"

# 10. The settings exports land together or not at all: a newer commit that wrote only the plist
#     keeps the schema and the other docs/mdm files out too, and the strings tables built from the schema.
setup_next
lane_commit "lane regenerates the plist" docs/mdm/com.manaflow.cmux.plist "plist lane"
if run > "$tmp/out" 2>&1; then fail "a repair without its settings exports passed the run"; fi
[[ "$(remote_show docs/mdm/com.manaflow.cmux.plist)" == "plist lane" ]] || fail "the newer plist was overwritten"
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema old" ]] || fail "the schema landed without the plist"
[[ "$(remote_show docs/mdm/com.manaflow.cmux.json)" == "mdm old" ]] || fail "docs/mdm landed without the plist"
[[ "$(remote_show webviews/src/pages/home/generated/strings.json)" == "strings old" ]] || fail "strings built from a held-back schema landed"
[[ "$(remote_show Packages/macOS/CmuxNext/ci-target-graph.json)" == "graph new" ]] || fail "the graph did not land: $(cat "$tmp/out")"

# 11. A repair made from a newer tree already landed (a late re-run of an older run): the older
#     repair never overwrites it.
setup_next
lane_commit "lane edits a setting" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2"
newer="$(remote_tip)"
lane_commit "chore(next): base autofix at ${newer:0:12}" schemas/settings/settings-schema.json "schema newer" \
  docs/mdm/com.manaflow.cmux.plist "plist newer" docs/mdm/com.manaflow.cmux.json "mdm newer"
if run > "$tmp/out" 2>&1; then fail "an older repair under a newer one passed the run"; fi
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema newer" ]] || fail "an older run overwrote a newer repair"
[[ "$(remote_show docs/mdm/com.manaflow.cmux.plist)" == "plist newer" ]] || fail "an older run overwrote a newer plist"

# 12. The defaults snapshot reads flags anywhere in the sources, so on a moved tip it is derived
#     again there from the landed exports, never copied from BASE_SHA.
setup_next
lane_commit "lane flips a flag" Flags.swift "flag off"
run > "$tmp/out" 2>&1 || fail "the repair with a snapshot did not land: $(cat "$tmp/out")"
[[ "$(remote_show schemas/defaults/cmux-next.json)" == "$(printf 'schema new\nflag off')" ]] \
  || fail "the snapshot is not the moved tip's: $(remote_show schemas/defaults/cmux-next.json)"

# 13. The retries are bounded: a remote whose branch moves under every push ends the run after
#     the attempts.
setup_next
cat > "$tmp/remote.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
tree="$(git rev-parse feat^{tree})"
moved="$(echo moved | git commit-tree "$tree" -p feat)"
git update-ref refs/heads/feat "$moved"
exit 1
HOOK
chmod +x "$tmp/remote.git/hooks/pre-receive"
if (cd "$tmp/bot" && CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS=2 timeout 60 bash "$script" "$tmp/remote.git" feat "$base") > "$tmp/out" 2>&1; then
  fail "a refused push passed the run"
fi
grep -q "attempt 2 of 2" "$tmp/out" || fail "the run did not stop after its attempts: $(cat "$tmp/out")"
grep -q "kept moving" "$tmp/out" || fail "the run does not say the branch kept moving: $(cat "$tmp/out")"

# 14. A push rejected while the branch stays put is no race: the run fails at once and says so.
setup_next
printf '#!/bin/sh\nexit 1\n' > "$tmp/remote.git/hooks/pre-receive"; chmod +x "$tmp/remote.git/hooks/pre-receive"
if run > "$tmp/out" 2>&1; then fail "a rejected push passed the run"; fi
grep -q "rejected" "$tmp/out" || fail "the run does not say the push was rejected: $(cat "$tmp/out")"
if grep -q "attempt 2" "$tmp/out"; then fail "an unmoved rejection was retried: $(cat "$tmp/out")"; fi

# 15. History since BASE_SHA that can't be read holds everything: an unreadable range never reads
#     as "no newer writes" (git log fails, say after a bad fetch).
setup_next
lane_commit "lane edits a doc" README.md "lane"
moved="$(remote_tip)"
mkdir -p "$tmp/fakebin"
real_git="$(command -v git)"
printf '#!/bin/sh\n[ "$1" = log ] && [ -n "$FAIL_GIT_LOG" ] && exit 128\nexec "%s" "$@"\n' "$real_git" > "$tmp/fakebin/git"
chmod +x "$tmp/fakebin/git"
if (cd "$tmp/bot" && PATH="$tmp/fakebin:$PATH" FAIL_GIT_LOG=1 bash "$script" "$tmp/remote.git" feat "$base") > "$tmp/out" 2>&1; then
  fail "a run that could not read the newer commits passed: $(cat "$tmp/out")"
fi
[[ "$(remote_tip)" == "$moved" ]] || fail "a repair landed although the newer commits were unreadable"
grep -q "cannot read the commits" "$tmp/out" || fail "the run does not say why: $(cat "$tmp/out")"

# 16. Only a commit's subject marks it as base autofix's own: a lane commit that quotes an autofix
#     subject in its body (a squash merge, say) is a newer write like any other, and its file waits.
setup
(cd "$tmp/lane" && git pull -q --ff-only origin feat && echo "lane wrote it" > "$gen" \
  && git commit -q -am "lane edits $gen" -m "chore(next): base autofix at 0123456789ab" && git push -q origin feat)
moved="$(remote_tip)"
if run > "$tmp/out" 2>&1; then fail "a repair over a lane commit quoting an autofix subject was pushed: $(cat "$tmp/out")"; fi
[[ "$(remote_show "$gen")" == "lane wrote it" ]] || fail "the lane's newer write was overwritten"
[[ "$(remote_tip)" == "$moved" ]] || fail "the remote moved although the repair was refused"

# The settings exports made at SETTINGS_MADE_AT (the 4th argument): the Mac job regenerates them on
# the newest tip when their inputs moved during the run (base-autofix-settings-exports.sh).
settings_exports=(schemas/settings/settings-schema.json docs/mdm/com.manaflow.cmux.plist docs/mdm/com.manaflow.cmux.json)
run_at() { (cd "$tmp/bot" && bash "$script" "$tmp/remote.git" feat "$base" "$1"); }
# The bot's repair writes only these of its files (the rest stay as at BASE_SHA).
repair_only() {
  (cd "$tmp/bot" && for f in $(git diff --name-only HEAD^ HEAD); do
      keep=0; for p in "$@"; do [[ "$f" == "$p" ]] && keep=1; done
      (( keep )) || git checkout -q HEAD^ -- "$f"
    done && git commit -q --amend --no-edit)
}
settings_set=("${settings_exports[@]}" schemas/defaults/cmux-next.json)

# 17. (a) Exports regenerated on the moved tip (made at T1, after its settings change) land there,
#     and on a tip that moved again elsewhere: their inputs did not move after T1.
setup_next
repair_only "${settings_set[@]}"
lane_commit "lane edits a setting" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2"
made="$(remote_tip)"
lane_commit "lane edits a doc" README.md "lane"
moved="$(remote_tip)"
run_at "$made" > "$tmp/out" 2>&1 || fail "exports made at the moved tip did not land: $(cat "$tmp/out")"
[[ "$(git -C "$tmp/remote.git" rev-parse feat^)" == "$moved" ]] || fail "the exports are not on top of the newest tip"
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema new" ]] || fail "the schema made at the tip did not land"
[[ "$(remote_show docs/mdm/com.manaflow.cmux.plist)" == "plist new" ]] || fail "the plist made at the tip did not land"
[[ "$(remote_show docs/mdm/com.manaflow.cmux.json)" == "mdm new" ]] || fail "docs/mdm made at the tip did not land"
[[ "$(remote_show schemas/defaults/cmux-next.json)" == "$(printf 'schema new\nflag on')" ]] \
  || fail "the snapshot was not derived on the tip from the landed exports: $(remote_show schemas/defaults/cmux-next.json)"

# 18. (a) An export the tip's regeneration left as it was at BASE_SHA still replaces what the
#     tip holds: the repair carries the whole export made at T1, not only its diff from BASE_SHA.
setup_next
repair_only schemas/settings/settings-schema.json docs/mdm/com.manaflow.cmux.plist schemas/defaults/cmux-next.json
lane_commit "lane edits a setting and a stale doc" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2" \
  docs/mdm/com.manaflow.cmux.json "mdm stale"
made="$(remote_tip)"
run_at "$made" > "$tmp/out" 2>&1 || fail "exports made at the moved tip did not land: $(cat "$tmp/out")"
[[ "$(remote_show docs/mdm/com.manaflow.cmux.json)" == "mdm old" ]] \
  || fail "docs/mdm as made at the tip did not replace the tip's stale copy: $(remote_show docs/mdm/com.manaflow.cmux.json)"

# 19. (b) The invariant: an export made at T1 whose inputs moved after T1 never lands as it is.
setup_next
repair_only "${settings_set[@]}"
lane_commit "lane edits a setting" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2"
made="$(remote_tip)"
lane_commit "lane edits it again" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v3"
moved="$(remote_tip)"
if run_at "$made" > "$tmp/out" 2>&1; then fail "exports whose inputs moved after they were made passed the run"; fi
[[ "$(remote_tip)" == "$moved" ]] || fail "exports whose inputs moved after they were made were pushed"
for f in "${settings_exports[@]}"; do
  [[ "$(remote_show "$f")" == *old ]] || fail "$f landed although its inputs moved after it was made"
done
grep -q "schemas/settings/settings-schema.json" "$tmp/out" || fail "the run does not name the held export: $(cat "$tmp/out")"

# 20. (b) A made-at commit that is not between BASE_SHA and the tip proves nothing: the exports wait.
setup_next
repair_only "${settings_set[@]}"
lane_commit "lane edits a doc" README.md "lane"
moved="$(remote_tip)"
if run_at "$(printf 'de%.0s' {1..20})" > "$tmp/out" 2>&1; then fail "exports made at an unknown commit passed the run"; fi
[[ "$(remote_tip)" == "$moved" ]] || fail "exports made at an unknown commit were pushed"
grep -q "made at" "$tmp/out" || fail "the run does not say why the exports wait: $(cat "$tmp/out")"

# 21. (d) Someone else regenerated the exports on the tip after moving their sources. Whether the
#     tip's copies are current takes the Mac export to say (the source stamp is derived, not
#     committed), so the held settings exports wait, the tip's copies stay, and the run fails.
setup_next
repair_only "${settings_set[@]}"
lane_commit "lane regenerates the exports" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2" \
  schemas/settings/settings-schema.json "schema lane"
if run > "$tmp/out" 2>&1; then fail "held settings exports passed the run: $(cat "$tmp/out")"; fi
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema lane" ]] || fail "the tip's own export was overwritten"
grep -q "schemas/settings/settings-schema.json" "$tmp/out" || fail "the run does not name the held export: $(cat "$tmp/out")"

# 21b. A made-at commit that exists but is not between BASE_SHA and the tip (here the repair itself)
#      holds the exports and fails the run with an error, even when the tip has its own exports:
#      a bad SETTINGS_MADE_AT is a workflow defect, never a silent pass.
setup_next
repair_only "${settings_set[@]}"
lane_commit "lane regenerates the exports" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2" \
  schemas/settings/settings-schema.json "schema lane"
moved="$(remote_tip)"
if run_at "$(git -C "$tmp/bot" rev-parse HEAD)" > "$tmp/out" 2>&1; then
  fail "exports made at a commit off the branch passed the run: $(cat "$tmp/out")"
fi
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema lane" ]] || fail "exports made off the branch landed"
grep -q "::error::.*made at" "$tmp/out" || fail "the run does not raise an error for the made-at commit: $(cat "$tmp/out")"

# 21c. What changed after SETTINGS_MADE_AT can't be read (the areas script fails on that range):
#      the exports never land as if nothing moved. Here the settings did move after T1.
setup_next
repair_only "${settings_set[@]}"
lane_commit "lane edits a setting" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2" marker.txt "made here"
made="$(remote_tip)"
lane_commit "lane edits it again" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v3"
moved="$(remote_tip)"
# Fails on any range without marker.txt, i.e. on SETTINGS_MADE_AT..tip but not on BASE..tip.
printf '#!/usr/bin/env bash\nin="$(cat)"\ngrep -qx marker.txt <<<"$in" || exit 3\nexec "%s" <<<"$in"\n' \
  "$here/../autofix-areas.sh" > "$tmp/flaky-areas.sh"
chmod +x "$tmp/flaky-areas.sh"
if (cd "$tmp/bot" && CMUX_BASE_AUTOFIX_AREAS="$tmp/flaky-areas.sh" bash "$script" "$tmp/remote.git" feat "$base" "$made") > "$tmp/out" 2>&1; then
  fail "a run that could not read what moved after SETTINGS_MADE_AT passed: $(cat "$tmp/out")"
fi
[[ "$(remote_tip)" == "$moved" ]] || fail "exports landed although what moved after they were made was unreadable"
grep -q "cannot read" "$tmp/out" || fail "the run does not say why: $(cat "$tmp/out")"

# 21d. The settings exports' inputs are what their source stamp hashes: a move of a settings-area
#      path that is no stamp input (here a note beside the sources) leaves the tip's sources giving the
#      stamp of the commit the exports were made at, so they land, and the run passes. Before it they
#      waited on every run.
setup_next
repair_only "${settings_set[@]}"
lane_commit "lane adds a note" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/NOTES.md "a note"
moved="$(remote_tip)"
run > "$tmp/out" 2>&1 || fail "exports whose stamp inputs did not move were held: $(cat "$tmp/out")"
[[ "$(git -C "$tmp/remote.git" rev-parse feat^)" == "$moved" ]] || fail "the exports are not on top of the moved tip"
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema new" ]] || fail "the schema did not land: $(remote_show schemas/settings/settings-schema.json)"
[[ "$(remote_show docs/mdm/com.manaflow.cmux.plist)" == "plist new" ]] || fail "the plist did not land"

# 21e. The same exports wait when the move changed the regeneration itself: what it writes may differ.
setup_next
repair_only "${settings_set[@]}"
lane_commit "lane edits the regeneration" scripts/cmux-next/regenerate-settings-exports.sh "# v2"
moved="$(remote_tip)"
if run > "$tmp/out" 2>&1; then fail "exports made by an older regeneration passed the run: $(cat "$tmp/out")"; fi
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema old" ]] || fail "exports made by an older regeneration landed"

# 21f. A real source move still holds them: the tip's sources no longer give the made-at stamp.
setup_next
repair_only "${settings_set[@]}"
lane_commit "lane edits a setting" Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift "setting v2"
if run > "$tmp/out" 2>&1; then fail "exports whose sources the tip moved passed the run: $(cat "$tmp/out")"; fi
[[ "$(remote_show schemas/settings/settings-schema.json)" == "schema old" ]] || fail "exports whose sources moved landed"

# base-autofix-settings-exports.sh (the Mac job): regenerates on the newest tip while the inputs
# move, at most CMUX_BASE_AUTOFIX_SETTINGS_TRIES times, and says which commit it made them at.
regen_script="$here/../base-autofix-settings-exports.sh"
# A stand-in for regenerate-settings-exports.sh: the export names the source it was made from, and
# FAKE_MOVE pushes a lane commit after each regeneration (always, once, or elsewhere).
cat > "$tmp/fake-regenerate.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
out="$1"
source="$(cat Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift)"
echo "schema for $source" > schemas/settings/settings-schema.json
for f in schemas/settings/settings-schema.json docs/mdm/com.manaflow.cmux.json; do
  if [[ "${CMUX_SETTINGS_EXPORTS_ALL:-}" == 1 ]] || ! git diff --quiet -- "$f"; then
    mkdir -p "$out/$(dirname "$f")"; cp "$f" "$out/$f"; echo "regenerated: $f"
  fi
done
n="$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 ))"; echo "$n" > "$FAKE_COUNT"
case "$FAKE_MOVE" in
  always | once) [[ "$FAKE_MOVE" == always || "$n" == 1 ]] || exit 0
    file=Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift text="setting v$((n + 1))" ;;
  elsewhere) file=README.md text="readme $n" ;;
  notes) file=Packages/macOS/CmuxNext/Sources/CmuxNextSettings/NOTES.md text="note $n" ;;
  *) exit 0 ;;
esac
(cd "$FAKE_LANE" && git pull -q --ff-only origin feat && echo "$text" > "$file" && git add -A \
  && git commit -q -m "lane moves $file" && git push -q origin feat)
FAKE
chmod +x "$tmp/fake-regenerate.sh"
regen() { # <FAKE_MOVE> : runs the Mac step in a fresh shallow checkout of the remote's tip
  rm -rf "$tmp/mac" "$tmp/mac-out" "$tmp/count"
  git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/mac"
  (cd "$tmp/mac" && FAKE_MOVE="$1" FAKE_COUNT="$tmp/count" FAKE_LANE="$tmp/lane" \
    CMUX_SETTINGS_REGENERATE="$tmp/fake-regenerate.sh" bash "$regen_script" "$tmp/mac-out" "$tmp/remote.git" feat)
}

# 22. The inputs did not move: one regeneration, made at the run's own commit.
setup_next
start="$(remote_tip)"
regen none > "$tmp/out" 2>"$tmp/err" || fail "an unmoved regeneration failed: $(cat "$tmp/out" "$tmp/err")"
grep -qx "made at: $start" "$tmp/out" || fail "the exports are not made at the run's commit: $(cat "$tmp/out")"
[[ "$(cat "$tmp/mac-out/schemas/settings/settings-schema.json")" == "schema for setting v1" ]] || fail "the export is not the run's"
[[ "$(cat "$tmp/count")" == 1 ]] || fail "an unmoved regeneration ran $(cat "$tmp/count") times"

# 23. (a) The inputs moved once during the regeneration: it runs again on the newest tip, which it
#     names, and the export is that tip's.
setup_next
regen once > "$tmp/out" 2>"$tmp/err" || fail "a regeneration on the moved tip failed: $(cat "$tmp/out" "$tmp/err")"
grep -qx "made at: $(remote_tip)" "$tmp/out" || fail "the exports are not made at the newest tip: $(cat "$tmp/out")"
[[ "$(cat "$tmp/mac-out/schemas/settings/settings-schema.json")" == "schema for setting v2" ]] \
  || fail "the export is not the newest tip's: $(cat "$tmp/mac-out/schemas/settings/settings-schema.json")"
[[ "$(cat "$tmp/count")" == 2 ]] || fail "the regeneration ran $(cat "$tmp/count") times, not 2"
# Every export file comes along (docs/mdm here is the same as at the start): the repair carries the
# whole export made at the tip.
grep -qx "regenerated: docs/mdm/com.manaflow.cmux.json" "$tmp/out" && fail "an export the same as the run's commit was handed on"

# 24. Only the settings inputs count: a move elsewhere needs no second regeneration.
setup_next
start="$(remote_tip)"
regen elsewhere > "$tmp/out" 2>"$tmp/err" || fail "a regeneration past an unrelated move failed: $(cat "$tmp/out" "$tmp/err")"
grep -qx "made at: $start" "$tmp/out" || fail "an unrelated move made it regenerate: $(cat "$tmp/out")"
[[ "$(cat "$tmp/count")" == 1 ]] || fail "an unrelated move ran the regeneration $(cat "$tmp/count") times"

# 24b. A settings-area move that is no stamp input (a note beside the sources) needs no second
#      regeneration either: the tip's sources give the source stamp of the commit it was made at.
setup_next
start="$(remote_tip)"
regen notes > "$tmp/out" 2>"$tmp/err" || fail "a regeneration past a note failed: $(cat "$tmp/out" "$tmp/err")"
grep -qx "made at: $start" "$tmp/out" || fail "a note beside the sources made it regenerate: $(cat "$tmp/out")"
[[ "$(cat "$tmp/count")" == 1 ]] || fail "a note beside the sources ran the regeneration $(cat "$tmp/count") times"

# 25. (c) The inputs move under every regeneration: it stops after the tries, hands on no export,
#     fails, and says so.
setup_next
if CMUX_BASE_AUTOFIX_SETTINGS_TRIES=3 regen always > "$tmp/out" 2>"$tmp/err"; then
  fail "a regeneration whose inputs never held still passed: $(cat "$tmp/out" "$tmp/err")"
fi
[[ "$(cat "$tmp/count")" == 3 ]] || fail "the regeneration ran $(cat "$tmp/count") times, not 3"
grep -q "::error::" "$tmp/err" || fail "the run does not raise an error: $(cat "$tmp/err")"
[[ -z "$(find "$tmp/mac-out" -type f 2>/dev/null)" ]] || fail "exports whose inputs kept moving were handed on: $(find "$tmp/mac-out" -type f)"
grep -q "^made at:" "$tmp/out" && fail "a held regeneration still names a commit: $(cat "$tmp/out")"

echo "PASS: base autofix lands its repair on a moved feat-cmux-next; files whose inputs moved or that a newer commit wrote wait; the settings exports are regenerated on the newest tip, or wait"
