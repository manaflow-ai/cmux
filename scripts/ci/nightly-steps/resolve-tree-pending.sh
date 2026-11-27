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
# (pin-cmux-tui.sh runs-state and active-publisher, as await-tree-client.sh reads
# them), the resolver builds the newest commit whose tree is published. Waiting on
# it failed 5 builds in a row 45 min in, at "Bundle the cmux-tui client" (2026-11-09).
# An unreadable runs list keeps the tip pending.
# Env: TIP_SHA, GH_TOKEN (actions: read). Writes tree_pending=, and when true key=, source_commit= and
# candidates= (the tip and its first-parent ancestors with the same key, oldest
# first, within the last 40: the oldest is the one whose artifacts run builds it).
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
candidates=()
while read -r commit; do
  [[ "$(python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$commit" 2>/dev/null)" == "$key" ]] || break
  candidates=("$commit" ${candidates[@]+"${candidates[@]}"})
done < <(git rev-list --first-parent -n 40 HEAD)
ended=0 publisher=""
for commit in "${candidates[@]}"; do
  case "$(bash scripts/cmux-next/pin-cmux-tui.sh runs-state "$commit" 2>/dev/null || echo unknown)" in
    active) publisher="$commit"; break ;;
    unknown) publisher=unknown ;;
    ended\ *) ended=$(( ended + 1 )) ;;
  esac
done
[[ -n "$publisher" ]] || publisher="$(bash scripts/cmux-next/pin-cmux-tui.sh active-publisher "$key" 2>/dev/null || echo unknown)"
if [[ -z "$publisher" ]] && (( ended > 0 )); then
  echo "tree_pending=false" >> "$GITHUB_OUTPUT"
  echo "::warning title=cmux-tui tree::tree $key of the tip is not published and nothing will publish it (its artifacts runs ended, no same-key run is active); the resolver builds the newest commit whose tree is published"
  {
    echo "### Nightly build commit"
    echo "- the tip \`$TIP_SHA\`: its cmux-tui tree \`$key\` is not published and nothing will publish it; building the newest published tree instead"
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
{
  echo "tree_pending=true"
  echo "key=$key"
  echo "source_commit=$TIP_SHA"
  echo "candidates=${candidates[*]}"
} >> "$GITHUB_OUTPUT"
echo "::notice title=cmux-tui tree::tree $key of the tip is not published yet; the app builds now and installs the tree's client once its manifest is uploaded (candidates: ${candidates[*]})"
{
  echo "### Nightly build commit"
  echo "- the tip \`$TIP_SHA\`; its cmux-tui tree \`$key\` is still publishing (NIGHTLY_NEXT_TREE_AT_INSTALL)"
} >> "$GITHUB_STEP_SUMMARY"
