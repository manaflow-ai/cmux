#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Build the tip while its tree publishes".
# NIGHTLY_NEXT_TREE_AT_INSTALL (nightly.yml env; main's promote guard reads it):
# a nightly-next tip whose own cmux-tui tree is not published yet (verify-key's
# clean 404) is built as it is. The app compiles now; build-nightly-app installs
# the tree's attested client once its manifest is uploaded
# (scripts/cmux-next/await-tree-client.sh), and publish-nightly waits for the
# commit's tree-commit marker (await-nightly-tree-marker). A published tree or
# a read failure leaves the decision to the resolver step after this one.
# A tree nothing will publish is not pending either: when every candidate's
# cmux-tui artifacts runs ended (one at least ran) and no active run has the key
# (pin-cmux-tui.sh tree-publisher, as await-tree-client.sh reads
# them), or every active run with the key is stuck (pin-cmux-tui.sh tree-publisher:
# a build failed on its last attempt, or waits for a runner past
# CMUX_TUI_TREE_RUNNER_STALL_SECONDS), the resolver builds the newest commit whose
# tree is published. Waiting on
# it failed 5 builds in a row 45 min in, at "Bundle the cmux-tui client" (2026-11-09).
# An unreadable runs list keeps the tip pending.
# Env: TIP_SHA, GH_TOKEN (actions: read). Writes tree_pending=, and when true key=, source_commit=,
# candidates= (the tip and its first-parent ancestors with the same key, oldest
# first, within the last 40: the oldest is the one whose artifacts run builds it)
# and fallback= ("<publishing commit> <tree key>" of the newest published tree in
# the tip's history, pin-cmux-tui.sh resolve-newest-published with no wait and no
# same-path rule, since only its client is used; empty when none is within 24 h).
# "Bundle the cmux-tui client" installs that tree's client when the tip's own tree
# is still not published after the compile, instead of waiting up to 45 min for
# it and failing (RFD 0021 row 1: 23.8 h of 48.6 h, 2026-11-19 to 21).
# The fallback search does not depend on the candidate and runs reads, so it runs beside them from the
# moment the tip's tree reads unpublished (in its own process group, ended when the step leaves early):
# run 44893172356 of 89a0aaea (2026-11-21) spent 4.6 min in this step, every phase one after another.
# A fallback whose client lacks a daemon capability the tip's app lists is dropped
# (scripts/ci/nightly_fallback_covers.py, from git, about 3 s; run 44975559258, 2026-11-22).
# Each phase logs its seconds ("phase NAME: Ns").
set -euo pipefail
[[ "$(git rev-parse HEAD)" == "$TIP_SHA" ]] || { echo "error: the checkout is not the tip $TIP_SHA" >&2; exit 1; }
key="$(python3 scripts/ci/cmux_tui_tree_key.py --version v2 HEAD)"
[[ "$key" =~ ^[0-9a-f]{40}$ ]] || { echo "error: no tree key for $TIP_SHA" >&2; exit 1; }
rc=0
bash scripts/cmux-next/pin-cmux-tui.sh verify-key "$key" >/dev/null || rc=$?
if (( rc != 1 )); then
  echo "tree_pending=false" >> "$GITHUB_OUTPUT"
  if (( rc == 0 )); then echo "tree $key of the tip is published; the resolver takes it"
  else echo "::notice title=cmux-tui tree::could not tell whether tree $key is published (verify-key exit $rc); the resolver decides"; fi
  exit 0
fi
fallback_out="$(mktemp)"
fallback_err="$(mktemp)"
# The first look covers the last CMUX_TUI_TREE_SEARCH_COMMITS (default 50) commits, as before. On a miss
# a second look reaches CMUX_TUI_TREE_FALLBACK_SEARCH_COMMITS (default 300); the 24 h age bound
# (CMUX_TUI_TREE_MAX_AGE_HOURS) still ends it first. Each look stops at its first published tree, so a
# hit in the last 50 costs what it did. Run 45097887921 (2026-11-23) found no fallback: the newest
# published tree was 87 commits back (two hours of trees that did not compile, at about 40 merges an
# hour), so "Bundle the cmux-tui client" waited the full 45 min for a tree nothing published and failed.
fallback_search() {
  CMUX_TUI_TREE_TIP_WAIT_SECONDS=0 CMUX_TUI_TREE_SAME_PATHS="" CMUX_TUI_TREE_DISPATCH="" GITHUB_STEP_SUMMARY="" \
    CMUX_TUI_TREE_SEARCH_COMMITS="$1" bash scripts/cmux-next/pin-cmux-tui.sh resolve-newest-published </dev/null
}
set -m
{ fallback_search "${CMUX_TUI_TREE_SEARCH_COMMITS:-50}" \
    || fallback_search "${CMUX_TUI_TREE_FALLBACK_SEARCH_COMMITS:-300}"; } >"$fallback_out" 2>"$fallback_err" &
fallback_pid=$!
set +m
fallback_began=$SECONDS
end_fallback() {
  if [[ -n "${fallback_pid:-}" ]]; then kill -TERM -- "-$fallback_pid" 2>/dev/null || true; wait "$fallback_pid" 2>/dev/null || true; fi
  rm -f "$fallback_out" "$fallback_err"
}
trap end_fallback EXIT
phase() { echo "phase $1: $(( SECONDS - $2 ))s"; }
began=$SECONDS
candidates=()
while read -r commit; do
  [[ "$(python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$commit" 2>/dev/null)" == "$key" ]] || break
  candidates=("$commit" ${candidates[@]+"${candidates[@]}"})
done < <(git rev-list --first-parent -n 40 HEAD)
phase "candidates (${#candidates[@]})" "$began"
# The same reading as await-tree-client.sh (pin-cmux-tui.sh tree-publisher): an active
# run counts only while its jobs make progress.
began=$SECONDS
publisher="$(bash scripts/cmux-next/pin-cmux-tui.sh tree-publisher "$key" "${candidates[@]}" 2>/dev/null || echo unknown)"
phase tree-publisher "$began"
why=""
case "$publisher" in
  ended) why="its artifacts runs ended, no same-key run is active" ;;
  stuck\ *) why="no artifacts run that builds it is making progress: ${publisher#stuck }" ;;
esac
if [[ -n "$why" ]]; then
  echo "tree_pending=false" >> "$GITHUB_OUTPUT"
  echo "::warning title=cmux-tui tree::tree $key of the tip is not published and nothing will publish it in time ($why); the resolver builds the tip with the newest published tree whose daemon-capabilities.json matches (older-tree-for-tip.sh), else the newest commit whose tree is published"
  {
    echo "### Nightly build commit"
    echo "- the tip \`$TIP_SHA\`: its cmux-tui tree \`$key\` is not published and nothing will publish it in time ($why); the resolver picks an older published tree"
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
fallback="" fallback_note="none within 24 h; the bundle step waits for the tip's tree"
began=$SECONDS
fallback_rc=0
wait "$fallback_pid" || fallback_rc=$?
fallback_pid=""
phase "fallback (waited $(( SECONDS - began ))s here)" "$fallback_began"
if (( fallback_rc == 0 )); then
  resolved="$(cat "$fallback_out")"
  fallback_commit="$(sed -n 's/^commit=//p' <<<"$resolved" | head -1)"
  fallback_key="$(sed -n 's/^key=//p' <<<"$resolved" | head -1)"
  fallback_source="$(sed -n 's/^source_commit=//p' <<<"$resolved" | head -1)"
  if [[ "$fallback_commit" =~ ^[0-9a-f]{40}$ && "$fallback_key" =~ ^[0-9a-f]{40}$ && "$fallback_key" != "$key" ]]; then
    fallback="$fallback_commit $fallback_key"
    fallback_note="tree \`$fallback_key\` of \`${fallback_source:-?}\`, published by \`$fallback_commit\`"
  fi
fi
# A fallback client older than a daemon capability the tip's app lists fails "Bundle the cmux-tui
# client" at check-daemon-capabilities.sh after the whole build: run 44975559258 (2026-11-22) bundled
# client 602f51e1, 24 commits behind, without language-packs-v1. Read it from git now, not 20 min in:
# a client that lacks one is dropped, so the bundle step waits for the tip's own tree. Could not tell
# (exit 2: the commit's objects are not here and one fetch did not bring them) keeps the fallback.
if [[ -n "$fallback" && "${fallback_source:-}" =~ ^[0-9a-f]{40}$ ]]; then
  began=$SECONDS
  fallback_depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && fallback_depth=(--depth=1)
  git cat-file -e "$fallback_source^{commit}" 2>/dev/null \
    || bash scripts/ci/timeout.sh 90 git fetch -q --no-tags ${fallback_depth[@]+"${fallback_depth[@]}"} origin "$fallback_source" 2>/dev/null || true
  covers_rc=0
  covers="$(python3 scripts/ci/nightly_fallback_covers.py --app-commit "$TIP_SHA" --client-commit "$fallback_source" 2>/dev/null)" || covers_rc=$?
  missing="$(sed -n 's/^missing=//p' <<<"$covers" | head -1)"
  phase "fallback capabilities (exit $covers_rc)" "$began"
  if (( covers_rc == 1 )); then
    echo "::warning title=cmux-tui tree::fallback tree $fallback_key of $fallback_source lacks ${missing}, which the tip's app needs; the bundle step waits for the tip's tree instead"
    fallback=""
    fallback_note="none: tree \`$fallback_key\` of \`$fallback_source\` lacks \`${missing}\`, which the tip's app needs; the bundle step waits for the tip's tree"
  elif (( covers_rc != 0 )); then
    echo "::notice title=cmux-tui tree::could not tell whether fallback client $fallback_source serves every capability the tip's app needs (exit $covers_rc); keeping it"
  fi
fi
# Why no fallback: the search's last word (it was discarded, so run 45097887921's miss read as nothing).
[[ -n "$fallback" ]] || { echo "no fallback tree:"; tail -n 3 "$fallback_err"; } >&2
{
  echo "tree_pending=true"
  echo "key=$key"
  echo "source_commit=$TIP_SHA"
  echo "candidates=${candidates[*]}"
  echo "fallback=$fallback"
} >> "$GITHUB_OUTPUT"
echo "::notice title=cmux-tui tree::tree $key of the tip is not published yet; the app builds now and installs the tree's client if it is published by then, else the newest published tree's (candidates: ${candidates[*]}; fallback: ${fallback:-none})"
{
  echo "### Nightly build commit"
  echo "- the tip \`$TIP_SHA\`; its cmux-tui tree \`$key\` is still publishing (NIGHTLY_NEXT_TREE_AT_INSTALL)"
  echo "- fallback client if it is still unpublished after the compile: $fallback_note"
} >> "$GITHUB_STEP_SUMMARY"
