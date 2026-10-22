#!/usr/bin/env bash
# The action exports (plans/cmux-next/action-surfaces.json, actions.md, links.json) for base autofix.
# The Mac job makes them once, at the newest feat-cmux-next tip (base-autofix-action-exports.sh), and
# base-autofix-push.sh lands them from that commit (ACTIONS_MADE_AT), as progress when the tip moved
# their inputs again. Before, they were judged from the run's own commit: with the Mac job queued for
# half an hour and the actions area moving every few minutes, every run held them, and none landed
# after 02:14Z on 2026-10-21 (runs 39607727081 and 39609533631; ActionSurfaceParityTests.reportIsFresh
# red). Then three regenerations in a row raced the merges and none landed (run 39633520123).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
push_script="$here/../base-autofix-push.sh"
land_script="$here/../base-autofix-land.sh"
mac_script="$here/../base-autofix-action-exports.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }
actions_src=Packages/macOS/CmuxNext/Sources/CmuxNextActions/Actions.swift
surfaces=plans/cmux-next/action-surfaces.json
md=plans/cmux-next/actions.md
links=plans/cmux-next/links.json

# A remote at one base commit; a bot clone holding the repair (new action exports) on top of it;
# a lane clone that pushes other people's commits.
setup() {
  rm -rf "$tmp/remote.git" "$tmp/bot" "$tmp/lane"
  git init -q --bare -b feat "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/lane" 2>/dev/null
  (cd "$tmp/lane" && git checkout -q -b feat \
    && mkdir -p "$(dirname "$actions_src")" plans/cmux-next web/scripts \
    && echo "action v1" > "$actions_src" && echo "surfaces old" > "$surfaces" && echo "md old" > "$md" \
    && echo "links old" > "$links" && echo "export v1" > web/scripts/export-docs-shortcuts.ts && echo readme > README.md \
    && git add -A && git commit -q -m base && git push -q origin feat)
  git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/bot"
  base="$(git -C "$tmp/bot" rev-parse HEAD)"
  (cd "$tmp/bot" && echo "surfaces new" > "$surfaces" && echo "md new" > "$md" \
    && git commit -q -am "chore(next): base autofix at ${base:0:12}")
}
lane_commit() { # <subject> <file> <text> [<file> <text>]...
  local subject="$1"; shift
  (cd "$tmp/lane" && git pull -q --ff-only origin feat \
    && while (( $# )); do mkdir -p "$(dirname "$1")" && echo "$2" > "$1" && shift 2; done \
    && git add -A && git commit -q -m "$subject" && git push -q origin feat)
}
remote_tip() { git -C "$tmp/remote.git" rev-parse feat; }
remote_show() { git -C "$tmp/remote.git" show "feat:$1"; }
push_at() { (cd "$tmp/bot" && bash "$push_script" "$tmp/remote.git" feat "$base" "" "$1"); }

# 1. The runs of 2026-10-21: the actions area moved during the run, including a pull request's own
#    write of action-surfaces.json (#21921), and the Mac job made the exports after that, at T1. They
#    land on a tip that moved again elsewhere, whole, as made at T1.
setup
lane_commit "#21921 regenerates the surfaces" "$actions_src" "action v2" "$surfaces" "surfaces lane"
made="$(remote_tip)"
lane_commit "lane edits a doc" README.md "lane"
moved="$(remote_tip)"
push_at "$made" > "$tmp/out" 2>&1 || fail "action exports made at the moved tip did not land: $(cat "$tmp/out")"
[[ "$(git -C "$tmp/remote.git" rev-parse feat^)" == "$moved" ]] || fail "the exports are not on top of the newest tip"
[[ "$(remote_show "$surfaces")" == "surfaces new" ]] || fail "action-surfaces.json made at T1 did not land: $(remote_show "$surfaces")"
[[ "$(remote_show "$md")" == "md new" ]] || fail "actions.md made at T1 did not land"

# 2. Exports made at T1 whose inputs moved after T1 land as progress on the newest tip, whole, with
#    a warning: the next push run makes them there.
setup
lane_commit "lane edits an action" "$actions_src" "action v2"
made="$(remote_tip)"
lane_commit "lane edits it again" "$actions_src" "action v3"
moved="$(remote_tip)"
push_at "$made" > "$tmp/out" 2>&1 || fail "action exports whose inputs moved after they were made did not land as progress: $(cat "$tmp/out")"
[[ "$(git -C "$tmp/remote.git" rev-parse feat^)" == "$moved" ]] || fail "the progress is not on top of the newest tip"
[[ "$(remote_show "$surfaces")" == "surfaces new" ]] || fail "action-surfaces.json made at T1 did not land as progress"
[[ "$(remote_show "$md")" == "md new" ]] || fail "actions.md made at T1 did not land with it"
[[ "$(remote_show "$actions_src")" == "action v3" ]] || fail "the progress overwrote the newer action source"
grep -q "::warning::.*land as progress" "$tmp/out" || fail "landing progress raises no warning: $(cat "$tmp/out")"

# 3. A newer commit after T1 wrote one of them itself: its copy stays (a generated file takes either
#    side), this repair's whole export is dropped, and nothing waits for it.
setup
lane_commit "lane edits an action" "$actions_src" "action v2"
made="$(remote_tip)"
lane_commit "lane writes the doc export" "$md" "md lane"
push_at "$made" > "$tmp/out" 2>&1 || fail "action exports a newer commit wrote made the run fail: $(cat "$tmp/out")"
[[ "$(remote_show "$md")" == "md lane" ]] || fail "the newer commit's own actions.md was overwritten"
[[ "$(remote_show "$surfaces")" == "surfaces old" ]] || fail "action-surfaces.json landed apart from actions.md"

# 4. A made-at commit that is not between BASE_SHA and the tip proves nothing: they wait, with an error.
setup
lane_commit "lane edits a doc" README.md "lane"
if push_at "$(printf 'de%.0s' {1..20})" > "$tmp/out" 2>&1; then fail "action exports made at an unknown commit passed"; fi
[[ "$(remote_show "$surfaces")" == "surfaces old" ]] || fail "action exports made at an unknown commit landed"
grep -q "::error::the action exports were made at" "$tmp/out" || fail "an unproven made-at raises no error: $(cat "$tmp/out")"

# 5. The exports land whole as made at T1: one T1 left as at BASE_SHA still replaces the tip's stale copy.
setup
lane_commit "lane edits an action and writes a stale links.json" "$actions_src" "action v2" "$links" "links stale"
made="$(remote_tip)"
push_at "$made" > "$tmp/out" 2>&1 || fail "action exports made at the moved tip did not land: $(cat "$tmp/out")"
[[ "$(remote_show "$links")" == "links old" ]] || fail "links.json as made at T1 did not replace the stale copy: $(remote_show "$links")"

# 6. Their inputs are the actions area only: a move of the docs-shortcuts exporter (the shortcuts
#    area, which reads the exports) does not hold them, made-at or not.
setup
lane_commit "lane edits the shortcuts exporter" web/scripts/export-docs-shortcuts.ts "export v2"
(cd "$tmp/bot" && bash "$push_script" "$tmp/remote.git" feat "$base") > "$tmp/out" 2>&1 \
  || fail "a shortcuts-exporter move held the action exports: $(cat "$tmp/out")"
[[ "$(remote_show "$surfaces")" == "surfaces new" ]] || fail "the action exports did not land past a shortcuts-exporter move"

# 7. base-autofix-land.sh hands the push the commit the action exports were made at.
setup
cat > "$tmp/fake-push.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_ARGS"
FAKE
chmod +x "$tmp/fake-push.sh"
(cd "$tmp/bot" && FAKE_ARGS="$tmp/args" CMUX_BASE_AUTOFIX_PUSH="$tmp/fake-push.sh" \
  bash "$land_script" "$tmp/remote.git" feat "$base" "settings-at" "actions-at") > "$tmp/out" 2>&1 \
  || fail "base-autofix-land.sh failed: $(cat "$tmp/out")"
[[ "$(sed -n 4,5p "$tmp/args" | tr '\n' ' ')" == "settings-at actions-at " ]] \
  || fail "base-autofix-land.sh does not hand on both made-at commits: $(tr '\n' ' ' < "$tmp/args")"

# What is built from the action exports (the docs shortcuts; the defaults snapshot, which also reads
# the settings exports) is judged from the run's commit: a CmuxNextActions move during the run holds
# it at the first push even though the exports made after that move land. base-autofix-land.sh then
# makes it again on the tip from the tip's committed exports, which are the ones just landed. Before,
# it waited for the next run, which held it the same way (the "keyboard-shortcuts docs freshness"
# base red). A stand-in for base-autofix-repair.sh builds them from the checkout it runs in.
shortcuts=web/data/cmux-shortcuts.generated.json
snapshot=schemas/defaults/cmux-next.json
cat > "$tmp/fake-repair.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
cd "$1"
env | grep '^CMUX_BASE_AUTOFIX_.*_CURRENT=' | sort >> "$FAKE_SEEN"
if [[ "${CMUX_BASE_AUTOFIX_ACTION_EXPORTS_CURRENT:-}" == 1 ]]; then
  echo "shortcuts for $(cat plans/cmux-next/action-surfaces.json), $(cat Packages/macOS/CmuxNext/Sources/CmuxNextActions/Actions.swift)" \
    > web/data/cmux-shortcuts.generated.json
  echo "fixed: regenerated web/data/cmux-shortcuts.generated.json"
  if [[ "${CMUX_BASE_AUTOFIX_SETTINGS_EXPORTS_CURRENT:-}" == 1 ]]; then
    echo "snapshot for $(cat plans/cmux-next/action-surfaces.json)" > schemas/defaults/cmux-next.json
    echo "fixed: regenerated schemas/defaults/cmux-next.json"
  fi
fi
FAKE
chmod +x "$tmp/fake-repair.sh"
# The base gains the files built from the exports and a defaults guard that, like the real one, finds
# the repository from its own path (parents[2]). Its source-stamp of a ref is the ref's settings
# sources (here one file outside every area). The bot's repair builds them at its commit.
settings_src=settings-sources.txt
setup_built() {
  setup
  cat > "$tmp/guard.py" <<'GUARD'
import pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[2]
if sys.argv[1:2] == ["source-stamp"]:
    ref = sys.argv[sys.argv.index("--ref") + 1]
    sys.stdout.write(subprocess.run(["git", "-C", str(root), "show", f"{ref}:settings-sources.txt"],
                                    capture_output=True, text=True, check=True).stdout)
GUARD
  lane_commit "built files" "$shortcuts" "shortcuts old" "$snapshot" "snapshot old" "$settings_src" "setting v1" \
    scripts/ci/defaults_guard.py "$(cat "$tmp/guard.py")"
  rm -rf "$tmp/bot"
  git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/bot"
  base="$(git -C "$tmp/bot" rev-parse HEAD)"
  (cd "$tmp/bot" && echo "surfaces new" > "$surfaces" && echo "md new" > "$md" \
    && echo "shortcuts for surfaces new, action v1" > "$shortcuts" && echo "snapshot for surfaces new" > "$snapshot" \
    && git commit -q -am "chore(next): base autofix at ${base:0:12}")
  : > "$tmp/seen"
}
land_at() { # <actions made at> [env...]
  local made="$1"; shift
  (cd "$tmp/bot" && env FAKE_SEEN="$tmp/seen" CMUX_BASE_AUTOFIX_REPAIR="$tmp/fake-repair.sh" RUN_URL=https://example.invalid "$@" \
    bash "$land_script" "$tmp/remote.git" feat "$base" "" "$made")
}

# 8. The run of 2026-10-21: CmuxNextActions moved during the run, the Mac job made the exports after
#    it (T1). The exports land at the first push; the shortcuts and snapshot built at the run's
#    commit wait there, and are made again on the tip from the exports that landed, and land too.
setup_built
lane_commit "lane edits an action" "$actions_src" "action v2"
made="$(remote_tip)"
land_at "$made" > "$tmp/out" 2>&1 || fail "the files built from the exports did not land on the tip: $(cat "$tmp/out")"
[[ "$(remote_show "$surfaces")" == "surfaces new" ]] || fail "the action exports did not land"
[[ "$(remote_show "$shortcuts")" == "shortcuts for surfaces new, action v2" ]] \
  || fail "the shortcuts were not made on the tip from its exports: $(remote_show "$shortcuts")"
[[ "$(remote_show "$snapshot")" == "snapshot for surfaces new" ]] || fail "the snapshot was not made on the tip: $(remote_show "$snapshot")"
grep -qx "CMUX_BASE_AUTOFIX_ACTION_EXPORTS_CURRENT=1" "$tmp/seen" || fail "the repair on the tip was not told the exports are current"

# 9. The settings sources moved after the run's commit, and this run made no settings exports: the
#    shortcuts land, the snapshot (it reads the settings exports too) waits, and the run fails so the
#    next run repairs it.
setup_built
lane_commit "lane edits an action and a setting" "$actions_src" "action v2" "$settings_src" "setting v2"
made="$(remote_tip)"
if land_at "$made" > "$tmp/out" 2>&1; then fail "a run whose snapshot waits passed: $(cat "$tmp/out")"; fi
[[ "$(remote_show "$shortcuts")" == "shortcuts for surfaces new, action v2" ]] || fail "the shortcuts did not land: $(remote_show "$shortcuts")"
[[ "$(remote_show "$snapshot")" == "snapshot old" ]] || fail "the snapshot landed though the settings sources moved"
grep -qF "$snapshot" "$tmp/out" || fail "the run does not name the waiting snapshot: $(cat "$tmp/out")"

# 10. The actions area moved after T1: the exports land as progress, and what is built from them is
#     made again on the tip from the exports committed there, so the two always match.
setup_built
lane_commit "lane edits an action" "$actions_src" "action v2"
made="$(remote_tip)"
lane_commit "lane edits it again" "$actions_src" "action v3"
land_at "$made" > "$tmp/out" 2>&1 || fail "the progress and what is built from it did not land: $(cat "$tmp/out")"
[[ "$(remote_show "$surfaces")" == "surfaces new" ]] || fail "the action exports did not land as progress"
[[ "$(remote_show "$shortcuts")" == "shortcuts for surfaces new, action v3" ]] \
  || fail "the shortcuts were not made on the tip from its exports: $(remote_show "$shortcuts")"

# 11. Without ACTIONS_MADE_AT the run made no action exports (the CI target graph job calls this with
#     none, and has no bun): nothing built from them is made on the tip; it waits and the run fails.
setup_built
lane_commit "lane edits an action" "$actions_src" "action v2"
if land_at "" > "$tmp/out" 2>&1; then fail "a run with no action exports made what is built from them: $(cat "$tmp/out")"; fi
[[ "$(remote_show "$shortcuts")" == "shortcuts old" ]] || fail "the shortcuts were made in a run with no action exports"
grep -q "ACTION_EXPORTS_CURRENT=1" "$tmp/seen" && fail "a run with no action exports told the repair they are current"

# 11b. An unproven ACTIONS_MADE_AT still holds the exports, and what is built from them waits.
setup_built
lane_commit "lane edits an action" "$actions_src" "action v2"
if land_at "$(printf 'de%.0s' {1..20})" > "$tmp/out" 2>&1; then fail "exports made at an unknown commit passed"; fi
[[ "$(remote_show "$surfaces")" == "surfaces old" ]] || fail "exports made at an unknown commit landed"
[[ "$(remote_show "$shortcuts")" == "shortcuts old" ]] || fail "the shortcuts were made beside held exports"

# base-autofix-action-exports.sh (the Mac job). A stand-in for regenerate-action-exports.sh writes
# exports naming the action source of the commit it ran on and counts its runs; FAKE_MOVE pushes a
# lane commit after each run (always, once, elsewhere) or makes it fail.
cat > "$tmp/fake-regenerate.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
n="$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 ))"; echo "$n" > "$FAKE_COUNT"
[[ "$FAKE_MOVE" != broken ]] || exit 3
source="$(cat Packages/macOS/CmuxNext/Sources/CmuxNextActions/Actions.swift)"
echo "surfaces for $source" > plans/cmux-next/action-surfaces.json
echo "md for $source" > plans/cmux-next/actions.md
case "$FAKE_MOVE" in
  always | once) [[ "$FAKE_MOVE" == always || "$n" == 1 ]] || exit 0
    file=Packages/macOS/CmuxNext/Sources/CmuxNextActions/Actions.swift text="action moved $n" ;;
  elsewhere) file=README.md text="readme $n" ;;
  *) exit 0 ;;
esac
(cd "$FAKE_LANE" && git pull -q --ff-only origin feat && echo "$text" > "$file" && git add -A \
  && git commit -q -m "lane moves $file" && git push -q origin feat)
FAKE
cat > "$tmp/fake-prepare.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$(git rev-parse HEAD)" >> "$FAKE_PREPARED"
FAKE
chmod +x "$tmp/fake-regenerate.sh" "$tmp/fake-prepare.sh"
mac_clone() { # a fresh shallow checkout of the remote's tip, as actions/checkout makes it
  rm -rf "$tmp/mac" "$tmp/mac-out" "$tmp/count" "$tmp/prepared"
  git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/mac"
  start="$(git -C "$tmp/mac" rev-parse HEAD)"
}
mac_run() { # <FAKE_MOVE>
  (cd "$tmp/mac" && FAKE_MOVE="$1" FAKE_COUNT="$tmp/count" FAKE_LANE="$tmp/lane" FAKE_PREPARED="$tmp/prepared" \
    CMUX_ACTIONS_REGENERATE="$tmp/fake-regenerate.sh" CMUX_BASE_AUTOFIX_ACTIONS_PREPARE="$tmp/fake-prepare.sh" \
    bash "$mac_script" "$tmp/mac-out" "$tmp/remote.git" feat)
}
mac_head_is_start() { [[ "$(git -C "$tmp/mac" rev-parse HEAD)" == "$start" ]] && [[ -z "$(git -C "$tmp/mac" status --porcelain)" ]]; }

# 12. Nothing moved: one regeneration at the run's commit; only the files that differ from it go out.
setup
mac_clone
mac_run none > "$tmp/out" 2>"$tmp/err" || fail "an unmoved regeneration failed: $(cat "$tmp/out" "$tmp/err")"
grep -qx "made at: $start" "$tmp/out" || fail "the exports are not made at the run's commit: $(cat "$tmp/out")"
[[ "$(cat "$tmp/count")" == 1 ]] || fail "an unmoved regeneration ran $(cat "$tmp/count") times"
[[ "$(cat "$tmp/mac-out/$surfaces")" == "surfaces for action v1" ]] || fail "the export is not the run's"
grep -qx "regenerated: $surfaces" "$tmp/out" || fail "the regenerated export is not named: $(cat "$tmp/out")"
[[ ! -e "$tmp/mac-out/$links" ]] || fail "an export the same as the run's commit was handed on"
[[ ! -e "$tmp/prepared" ]] || fail "an unmoved regeneration prepared a checkout again"

# 13. The actions area moved while the job waited for a runner: the first regeneration is already on
#    the newest tip, prepared for it, and the checkout is back at the run's commit afterwards.
setup
mac_clone
lane_commit "lane edits an action" "$actions_src" "action v2"
tip="$(remote_tip)"
mac_run none > "$tmp/out" 2>"$tmp/err" || fail "a regeneration on the tip the queue moved failed: $(cat "$tmp/out" "$tmp/err")"
grep -qx "made at: $tip" "$tmp/out" || fail "the exports are not made at the newest tip: $(cat "$tmp/out")"
[[ "$(cat "$tmp/count")" == 1 ]] || fail "it regenerated $(cat "$tmp/count") times, not once on the tip"
[[ "$(cat "$tmp/mac-out/$surfaces")" == "surfaces for action v2" ]] || fail "the export is not the tip's"
[[ "$(head -1 "$tmp/prepared")" == "$tip" ]] || fail "the tip was not prepared before its regeneration"
[[ "$(tail -1 "$tmp/prepared")" == "$start" ]] || fail "the run's commit was not prepared again for the steps after"
mac_head_is_start || fail "the checkout is not back at the run's commit"

# 14. The inputs moved during the regeneration: the exports go out as made at the commit it ran on,
#     once, never regenerated again (base-autofix-push.sh lands them as progress).
setup
mac_clone
mac_run once > "$tmp/out" 2>"$tmp/err" || fail "a regeneration the tip moved under failed: $(cat "$tmp/out" "$tmp/err")"
grep -qx "made at: $start" "$tmp/out" || fail "the exports are not made at the commit they ran on: $(cat "$tmp/out")"
[[ "$(cat "$tmp/count")" == 1 ]] || fail "the regeneration ran $(cat "$tmp/count") times, not once"
[[ "$(cat "$tmp/mac-out/$surfaces")" == "surfaces for action v1" ]] || fail "the export made at the run's commit was not handed on"
grep -q "land as progress" "$tmp/err" || fail "the move during the regeneration is not reported: $(cat "$tmp/err")"
mac_head_is_start || fail "the checkout is not back at the run's commit"

# 15. Only the actions inputs count: a move elsewhere needs no second regeneration.
setup
mac_clone
mac_run elsewhere > "$tmp/out" 2>"$tmp/err" || fail "a regeneration past an unrelated move failed: $(cat "$tmp/out" "$tmp/err")"
grep -qx "made at: $start" "$tmp/out" || fail "an unrelated move made it regenerate: $(cat "$tmp/out")"
[[ "$(cat "$tmp/count")" == 1 ]] || fail "an unrelated move ran the regeneration $(cat "$tmp/count") times"

# 16. The run of 2026-10-21 (39633520123), end to end: the actions area moves during the regeneration
#     and again before the push. The exports made at the run's commit land on the newest tip as
#     progress, the shortcuts are made there from them, and the run passes; the next run catches up.
setup_built
mac_clone
mac_run once > "$tmp/out" 2>"$tmp/err" || fail "the Mac job failed on a moving tip: $(cat "$tmp/out" "$tmp/err")"
[[ "$(cat "$tmp/count")" == 1 ]] || fail "the Mac job regenerated $(cat "$tmp/count") times"
made="$(sed -n 's/^made at: //p' "$tmp/out")"
lane_commit "lane edits it again" "$actions_src" "action v3"
(cd "$tmp/bot" && cp "$tmp/mac-out/$surfaces" "$surfaces" && cp "$tmp/mac-out/$md" "$md" \
  && echo "shortcuts for $(cat "$surfaces"), action v1" > "$shortcuts" && git commit -q -a --amend --no-edit)
land_at "$made" > "$tmp/out" 2>&1 || fail "the progress did not land on a moving tip: $(cat "$tmp/out")"
[[ "$(remote_show "$surfaces")" == "surfaces for action v1" ]] || fail "the exports did not land as progress: $(remote_show "$surfaces")"
[[ "$(remote_show "$shortcuts")" == "shortcuts for surfaces for action v1, action v3" ]] \
  || fail "the shortcuts do not match the landed exports: $(remote_show "$shortcuts")"
[[ "$(remote_show "$actions_src")" == "action v3" ]] || fail "the landing overwrote a newer action source"

# 17. A failed regeneration fails the step and hands on nothing.
setup
mac_clone
if mac_run broken > "$tmp/out" 2>"$tmp/err"; then fail "a failed regeneration passed"; fi
grep -q "::error::regenerating the action exports" "$tmp/err" || fail "a failed regeneration raises no error: $(cat "$tmp/err")"
[[ -z "$(find "$tmp/mac-out" -type f 2>/dev/null)" ]] || fail "a failed regeneration handed on exports"

# 18. A checkout of the tip that fails (a stale index.lock on a reused runner) fails the step: the
#     exports regenerated on the old commit are never named as made at the tip.
setup
mac_clone
lane_commit "lane edits an action" "$actions_src" "action v2"
touch "$tmp/mac/.git/index.lock"
if mac_run none > "$tmp/out" 2>"$tmp/err"; then fail "a failed checkout of the tip passed: $(cat "$tmp/out")"; fi
grep -q "^made at:" "$tmp/out" && fail "a failed checkout still names a commit: $(cat "$tmp/out")"
[[ ! -e "$tmp/count" ]] || fail "it regenerated after the checkout of the tip failed"
grep -q "::error::cannot check out" "$tmp/err" || fail "a failed checkout raises no error: $(cat "$tmp/err")"
rm -f "$tmp/mac/.git/index.lock"

echo "PASS: the action exports are made once at the newest tip and land, as progress when the tip moved their inputs again; what is built from them is made again on the tip"
