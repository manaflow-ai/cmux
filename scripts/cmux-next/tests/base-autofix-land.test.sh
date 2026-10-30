#!/usr/bin/env bash
# scripts/cmux-next/base-autofix-land.sh pushes base autofix's repair and, when feat-cmux-next moved
# the inputs of a file the job can make itself (the CI target graph, the SDK layers, the ratchet, the
# cloud clients, cargo fmt), makes that file again on the new tip and pushes it, a bounded number of
# times. Before it, a held file waited for the next run, whose push found the tip moved again: the
# graph (any Packages/ change moves its inputs) was held on every run from 08:58 to 10:00 on
# 2026-10-21, and the Mac settings exports never landed beside it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../base-autofix-land.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }
manifest=Packages/macOS/CmuxNext/Package.swift
graph=Packages/macOS/CmuxNext/ci-target-graph.json
setting=Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift
schema=schemas/settings/settings-schema.json
cap_source=Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift
cap=plans/cmux-next/daemon-capabilities.json

# A stand-in for base-autofix-repair.sh: the graph names the manifest it was made from. With
# FAKE_MOVE, each repair on a moved tip (CMUX_BASE_AUTOFIX_AGAIN=1) is followed by a lane push that
# moves the manifest again, as a merge landing during the repair would. It records whether it ever
# saw the push token.
cat > "$tmp/fake-repair.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
repo="$1"
echo "${TOKEN-unset}" >> "$FAKE_TOKENS"
[[ "${CMUX_BASE_AUTOFIX_AGAIN:-}" == 1 ]] && echo again >> "$FAKE_AGAIN"
graph="Packages/macOS/CmuxNext/ci-target-graph.json"
cap_source="Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift"
cap="plans/cmux-next/daemon-capabilities.json"
made="graph for $(cat "$repo/Packages/macOS/CmuxNext/Package.swift")"
if [[ "$(cat "$repo/$graph")" != "$made" ]]; then
  echo "$made" > "$repo/$graph"
  echo "fixed: regenerated $graph"
fi
if [[ -f "$repo/$cap_source" && -f "$repo/$cap" ]]; then
  cap_made="capability export for $(cat "$repo/$cap_source")"
  if [[ "$(cat "$repo/$cap")" != "$cap_made" ]]; then
    echo "$cap_made" > "$repo/$cap"
    echo "fixed: regenerated $cap"
  fi
fi
if [[ "${CMUX_BASE_AUTOFIX_AGAIN:-}" == 1 && "${FAKE_MOVE:-}" == always ]]; then
  n="$(wc -l < "$FAKE_AGAIN")"
  (cd "$FAKE_LANE" && git pull -q --ff-only origin feat && echo "manifest moved $n" > Packages/macOS/CmuxNext/Package.swift \
    && git commit -q -am "lane moves the manifest again" && git push -q origin feat)
fi
FAKE
chmod +x "$tmp/fake-repair.sh"

# A remote with one base commit, a shallow bot checkout at it (actions/checkout) holding the run's
# first repair commit, and a lane clone that pushes other people's commits.
setup() {
  with_cap="${1:-}"
  rm -rf "$tmp/remote.git" "$tmp/bot" "$tmp/lane" "$tmp/tokens" "$tmp/again"
  : > "$tmp/tokens"; : > "$tmp/again"
  git init -q --bare -b feat "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/lane" 2>/dev/null
  (cd "$tmp/lane" && git checkout -q -b feat \
    && mkdir -p Packages/macOS/CmuxNext/Sources/CmuxNextSettings schemas/settings \
    && echo "manifest v1" > "$manifest" && echo "graph old" > "$graph" \
    && echo "setting v1" > "$setting" && echo "schema old" > "$schema" \
    && if [[ "$with_cap" == cap ]]; then mkdir -p "$(dirname "$cap_source")" "$(dirname "$cap")" && echo "capability source v1" > "$cap_source" && echo "cap old" > "$cap"; fi \
    && echo readme > README.md \
    && git add -A && git commit -q -m base && git push -q origin feat)
  git clone -q --depth=1 -b feat "file://$tmp/remote.git" "$tmp/bot"
  base="$(git -C "$tmp/bot" rev-parse HEAD)"
}
# The run's own repair at its commit: the graph made from the base's manifest, and with
# "settings" the settings exports the Mac job made there.
first_repair() {
  (cd "$tmp/bot" && echo "graph for manifest v1" > "$graph" \
    && if [[ "$with_cap" == cap ]]; then echo "capability export for capability source v1" > "$cap"; fi \
    && if [[ "${1:-}" == settings ]]; then echo "schema new" > "$schema"; fi \
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
run() { # [env...]
  (cd "$tmp/bot" && env TOKEN=secret-token FAKE_TOKENS="$tmp/tokens" FAKE_AGAIN="$tmp/again" FAKE_LANE="$tmp/lane" \
    CMUX_BASE_AUTOFIX_REPAIR="$tmp/fake-repair.sh" RUN_URL=https://example.invalid/run "$@" \
    bash "$script" "$tmp/remote.git" feat "$base")
}

# 1. The branch did not move: the repair is pushed once, and nothing is made again.
setup
first_repair
repair="$(git -C "$tmp/bot" rev-parse HEAD)"
run > "$tmp/out" 2>&1 || fail "an unmoved branch did not take the repair: $(cat "$tmp/out")"
[[ "$(remote_tip)" == "$repair" ]] || fail "the remote is not at the repair commit"
[[ ! -s "$tmp/again" ]] || fail "an unmoved branch made the repair again"

# 2. A merge moved the graph's inputs during the run: the push holds the graph made at the run's
#    commit (it would be wrong at the tip), and the job makes it again on the tip and lands that.
setup
first_repair
lane_commit "lane edits the manifest" "$manifest" "manifest v2"
moved="$(remote_tip)"
run > "$tmp/out" 2>&1 || fail "the graph was not made again on the moved tip: $(cat "$tmp/out")"
[[ "$(remote_show "$graph")" == "graph for manifest v2" ]] || fail "the graph on the branch is not the tip's: $(remote_show "$graph")"
[[ "$(git -C "$tmp/remote.git" rev-parse feat^)" == "$moved" ]] || fail "the new repair is not on top of the moved tip"
git -C "$tmp/remote.git" log -1 --format=%s feat | grep -qE "^chore\(next\): base autofix at ${moved:0:12}$" \
  || fail "the new repair does not name the tip it was made at: $(git -C "$tmp/remote.git" log -1 --format=%s feat)"
[[ "$(wc -l < "$tmp/again")" == 1 ]] || fail "the repair was made again $(wc -l < "$tmp/again") times, not once"
grep -q "again on ${moved:0:12}" "$tmp/out" || fail "the run does not say it made the repair again on the tip: $(cat "$tmp/out")"

# The source-derived capability export is also remade on a moved tip.
setup cap
first_repair
lane_commit "lane edits a daemon capability" "$cap_source" "capability source v2"
moved="$(remote_tip)"
run > "$tmp/out" 2>&1 || fail "the capability export was not made again on the moved tip: $(cat "$tmp/out")"
[[ "$(remote_show "$cap")" == "capability export for capability source v2" ]] \
  || fail "the capability export on the branch is not the tip's: $(remote_show "$cap")"

# 3. The repair never sees the push token, on any round.
grep -qvx unset "$tmp/tokens" && fail "a repair ran with the push token in its environment"

# 4. The inputs move under every repair: it stops after CMUX_BASE_AUTOFIX_ROUNDS rounds, lands no
#    graph that is wrong for the tip it lands on, fails, and leaves it to the next run.
setup
first_repair
lane_commit "lane edits the manifest" "$manifest" "manifest v2"
if run FAKE_MOVE=always CMUX_BASE_AUTOFIX_ROUNDS=3 > "$tmp/out" 2>&1; then
  fail "a repair whose inputs never held still passed: $(cat "$tmp/out")"
fi
[[ "$(wc -l < "$tmp/again")" == 2 ]] || fail "the repair was made again $(wc -l < "$tmp/again") times, not 2 (3 rounds)"
[[ "$(remote_show "$graph")" == "graph old" ]] || fail "a graph made for an older manifest landed: $(remote_show "$graph")"
grep -q "::error::.*next run" "$tmp/out" || fail "the run does not say the next run repairs it: $(cat "$tmp/out")"

# 5. Someone else already put the tip's own graph on the branch: the push holds this run's copy
#    (a newer commit wrote it), the repair on the tip changes nothing, and the run passes.
setup
first_repair
lane_commit "lane regenerates the graph" "$manifest" "manifest v2" "$graph" "graph for manifest v2"
moved="$(remote_tip)"
run > "$tmp/out" 2>&1 || fail "a graph the tip already holds failed the run: $(cat "$tmp/out")"
[[ "$(remote_tip)" == "$moved" ]] || fail "an empty repair was pushed"

# 6. The Mac settings exports held by a settings move are never made here (they need a Mac): the
#    graph lands from the repair on the tip, the exports stay as the tip has them, and the run
#    fails so the next run's Mac job makes them.
setup
first_repair settings
lane_commit "lane edits a setting and the manifest" "$setting" "setting v2" "$manifest" "manifest v2"
if run > "$tmp/out" 2>&1; then fail "a run that held the settings exports passed: $(cat "$tmp/out")"; fi
[[ "$(remote_show "$graph")" == "graph for manifest v2" ]] || fail "the graph was not made again on the tip: $(remote_show "$graph")"
[[ "$(remote_show "$schema")" == "schema old" ]] || fail "settings exports whose inputs moved landed: $(remote_show "$schema")"
grep -q "$schema" "$tmp/out" || fail "the run does not name the held settings export: $(cat "$tmp/out")"

# 7. Only the settings exports held: nothing here can make them, so no repair runs again.
setup
first_repair settings
(cd "$tmp/bot" && git checkout -q HEAD^ -- "$graph" && git commit -q --amend --no-edit)
lane_commit "lane edits a setting" "$setting" "setting v2"
if run > "$tmp/out" 2>&1; then fail "a run that held the settings exports passed: $(cat "$tmp/out")"; fi
[[ ! -s "$tmp/again" ]] || fail "the repair was made again although only the Mac exports waited"

# 7b. A push that never got through (the branch moved under every attempt) is no hold: nothing of
#     the repair landed, so making only the held part again would drop the rest (the settings
#     exports here) while the run passed. The run fails and the next run repairs it all.
setup
first_repair settings
lane_commit "lane edits the manifest" "$manifest" "manifest v2"
cat > "$tmp/remote.git/hooks/pre-receive" <<HOOK
#!/bin/sh
unset GIT_QUARANTINE_PATH
n=\$(cat "$tmp/rejects" 2>/dev/null || echo 0)
if [ "\$n" -lt 2 ]; then
  echo \$((n + 1)) > "$tmp/rejects"
  (cd "$tmp/lane" && git pull -q --ff-only origin feat && echo "readme \$n" > README.md && git commit -q -am "lane moves" && git push -q origin feat) >/dev/null 2>&1 &
  wait
  exit 1
fi
HOOK
chmod +x "$tmp/remote.git/hooks/pre-receive"
rm -f "$tmp/rejects"
if run CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS=2 > "$tmp/out" 2>&1; then
  fail "a run whose push never got through passed: $(cat "$tmp/out")"
fi
rm -f "$tmp/remote.git/hooks/pre-receive"
[[ ! -s "$tmp/again" ]] || fail "a push that never got through was taken for a hold and made again: $(cat "$tmp/out")"
[[ "$(remote_show "$schema")" == "schema old" ]] || fail "the settings exports landed: $(remote_show "$schema")"

# 7c. A held Chief inspector page comes only from the webviews formatting job's patch, which a round
#     on the tip does not apply: it waits for the next run and the run fails.
setup
inspector=Native/OptChat/optchat-chief/inspector/index.html
(cd "$tmp/bot" && mkdir -p "$(dirname "$inspector")" && echo "page new" > "$inspector" && git add -A \
  && git commit -q -m "chore(next): base autofix at ${base:0:12}")
lane_commit "lane rebuilds the page" "$inspector" "page lane"
if run > "$tmp/out" 2>&1; then fail "a held inspector page passed the run: $(cat "$tmp/out")"; fi
[[ "$(remote_show "$inspector")" == "page lane" ]] || fail "the lane's page was overwritten"
grep -q "$inspector" "$tmp/out" || fail "the run does not name the held page: $(cat "$tmp/out")"

# 8. The workflow lands its repair through this script, with the same repair for every round.
workflow="$here/../../../.github/workflows/cmux-next-base-autofix.yml"
grep -qF 'scripts/cmux-next/base-autofix-land.sh "$remote" feat-cmux-next "$HEAD_SHA" "$SETTINGS_MADE_AT"' "$workflow" \
  || fail "the Push the repairs step does not land the repair with base-autofix-land.sh"
grep -qF 'CMUX_BASE_AUTOFIX_REPAIR: scripts/cmux-next/base-autofix-repair.sh' "$workflow" \
  || fail "the Push the repairs step does not make the repair again with base-autofix-repair.sh"
grep -qF 'scripts/cmux-next/base-autofix-repair.sh "$GITHUB_WORKSPACE"' "$workflow" \
  || fail "the Repair step does not use base-autofix-repair.sh"

# base-autofix-repair.sh: the first round applies the Mac exports and the webviews patch; a round
# on a moved tip makes only what that tree decides, and what is built from the exports waits.
repair_script="$here/../base-autofix-repair.sh"
cat > "$tmp/fake-autofix.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_ARGS"
FAKE
chmod +x "$tmp/fake-autofix.sh"
printf '#!/usr/bin/env bash\necho "{\\"dump\\": \\"$1\\"}"\n' > "$tmp/fake-dump.sh"
chmod +x "$tmp/fake-dump.sh"
mkdir -p "$tmp/exports/plans/cmux-next" "$tmp/patchdir" "$tmp/repo"
echo patch > "$tmp/patchdir/webviews-fmt.patch"
repair_args() { # [env...]
  env GRAPH=true STRINGS=false SDK=true CAPABILITIES=true SHORTCUTS=false APPHOST=false ACTIONS=true SETTINGS=true \
    EXPORTS_VERIFIED=true SETTINGS_VERIFIED=true RATCHETS=true CLOUD=false FMT=false \
    EXPORTS_DIR="$tmp/exports" WEBVIEWS_PATCH="$tmp/patchdir/webviews-fmt.patch" \
    CMUX_BASE_AUTOFIX_SCRIPT="$tmp/fake-autofix.sh" CMUX_BASE_AUTOFIX_DUMP="$tmp/fake-dump.sh" FAKE_ARGS="$tmp/args" "$@" \
    bash "$repair_script" "$tmp/repo" > /dev/null
  tr '\n' ' ' < "$tmp/args"
}
first="$(repair_args)"
for want in "--generated $tmp/exports" --package-dump --sdk --capabilities --docs-shortcuts --app-host --ratchets \
  "--webviews-fmt-patch $tmp/patchdir/webviews-fmt.patch" --no-fmt; do
  [[ " $first" == *" $want "* ]] || fail "the first round does not pass $want: $first"
done
[[ "$first" == *--unverified* ]] && fail "the first round marks verified exports unverified: $first"
again="$(repair_args CMUX_BASE_AUTOFIX_AGAIN=1)"
for want in --package-dump --sdk --ratchets --unverified-exports --unverified-settings-exports --no-fmt; do
  [[ " $again" == *" $want "* ]] || fail "a round on a moved tip does not pass $want: $again"
done
for unwanted in --generated --webviews-fmt-patch --docs-shortcuts --app-host; do
  [[ " $again" == *" $unwanted "* ]] && fail "a round on a moved tip passes $unwanted: $again"
done
unverified="$(repair_args EXPORTS_VERIFIED=false SETTINGS_VERIFIED=)"
[[ " $unverified " == *" --unverified-exports "* && " $unverified " == *" --unverified-settings-exports "* ]] \
  || fail "unverified exports are not marked: $unverified"

echo "PASS: base autofix makes a held repair again on the moved tip and lands it, a bounded number of times, without the push token"
