#!/usr/bin/env bash
# cmux-next.yml path_route: "Classify pull request paths". Moved out of the workflow to keep cmux-next.yml under
# its size budget (tests/test_ci_workflow_file_size.py); the step's env: still sets every input, and the step runs
# it with `bash -e` as GitHub's default `bash -e {0}` ran the inline block.
set -euo pipefail
changed="$RUNNER_TEMP/changed-files.txt"
labels=""
if [[ "$EVENT_NAME" == pull_request ]]; then
  git diff --no-renames --name-only HEAD^1 HEAD > "$changed"
  # Live labels on every attempt (docs/ci/cmux-next-workflow-notes.md#note-97): a late synchronize event carries
  # the labels from before full-ci was added and, sharing the concurrency group, cancels the labeled run.
  labels="$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/labels" --jq '[.[].name] | join(",")' 2>/dev/null)" || {
    echo "::warning::could not read the pull request labels; routing on the event's labels (${EVENT_LABELS:-none})"
    labels="$EVENT_LABELS"
  }
else
  : > "$changed"
fi
# Read by every job's label check as contains(needs.path_route.outputs.labels, ',full-ci,').
echo "labels=,$labels," >> "$GITHUB_OUTPUT"
echo "changed files: $(wc -l < "$changed"); labels: ${labels:-none}"
if [[ "$EVENT_NAME" == workflow_dispatch && "$DEV_DAILY" == true ]]; then
  # Why: docs/ci/cmux-next-workflow-notes.md#note-391
  [[ "$GITHUB_REF" == refs/heads/feat-cmux-next ]] || {
    echo "error: dev_daily runs on refs/heads/feat-cmux-next, got $GITHUB_REF" >&2
    exit 1
  }
  if [[ -n "$SAME_TREE_SHA" ]]; then
    [[ "$DEV_DAILY_SHA" == "$SAME_TREE_SHA" ]] || {
      echo "error: deferred dev_daily asked for $DEV_DAILY_SHA but same-tree mode is $SAME_TREE_SHA" >&2
      exit 1
    }
  else
    [[ "$DEV_DAILY_SHA" == "$GITHUB_SHA" ]] || {
      echo "error: dev_daily asked for $DEV_DAILY_SHA but feat-cmux-next moved to $GITHUB_SHA; the next dispatcher tick takes the new tip" >&2
      exit 1
    }
  fi
  {
    echo 'native=false'
    echo 'swift_canary=false'
    echo 'cmuxnext_swift=false'
    echo 'swift_canary_targets='
    echo 'macos=true'
    echo 'scheme=true'
    echo 'generated=false'
    echo 'swift=false'
    echo 'daemon=false'
    echo 'full=false'
    echo 'swift_filter='
    echo 'swift_priority_filter='
    echo 'swift_targets='
  } >> "$GITHUB_OUTPUT"
  {
    echo '### cmux-next tiers'
    echo
    echo '| tier | runs |'
    echo '| --- | --- |'
    echo '| generated | false |'
    echo '| native | false |'
    echo '| swift_canary | false |'
    echo '| scheme | true |'
    echo '| swift | false |'
    echo '| daemon | false |'
    echo '| full | false |'
    echo
    echo '- scheduled dev-daily dispatch: the exact feat-cmux-next SHA builds the Release cmux NEXT DEV artifact in the scheme job.'
  } >> "$GITHUB_STEP_SUMMARY"
elif [[ "$EVENT_NAME" == workflow_dispatch && "$TIP_SWIFT_SUITE" == true ]]; then
  # Why: docs/ci/cmux-next-workflow-notes.md#note-392
  [[ "$GITHUB_REF" == refs/heads/feat-cmux-next ]] || {
    echo "error: tip_swift_suite runs on refs/heads/feat-cmux-next, got $GITHUB_REF" >&2
    exit 1
  }
  {
    echo 'native=false'
    echo 'swift_canary=false'
    echo 'cmuxnext_swift=false'
    echo 'swift_canary_targets='
    echo 'macos=true'
    echo 'scheme=false'
    echo 'generated=false'
    echo 'swift=true'
    echo 'daemon=false'
    echo 'full=false'
    echo 'swift_filter='
    echo 'swift_priority_filter='
    echo 'swift_targets=all'
  } >> "$GITHUB_OUTPUT"
  {
    echo '### cmux-next tiers'
    echo
    echo '| tier | runs |'
    echo '| --- | --- |'
    echo '| swift | true (every target) |'
    echo
    echo '- scheduled tip Swift suite: every CmuxNext Swift target on the feat-cmux-next tip.'
  } >> "$GITHUB_STEP_SUMMARY"
elif [[ "$EVENT_NAME" == workflow_dispatch && "$BASE_TIER" == true ]]; then
  # cmux-next-base-tier-kick.yml, at most once every 15 minutes: the base Mac tier a
  # feat-cmux-next push leaves to it (below), on the tip. Its tree wait marker carries
  # tip_suite=base, so a same-tree run tests this exact commit even after the tip moves on.
  [[ "$GITHUB_REF" == refs/heads/feat-cmux-next ]] || {
    echo "error: base_tier runs on refs/heads/feat-cmux-next, got $GITHUB_REF" >&2
    exit 1
  }
  {
    echo 'native=false'
    echo 'swift_canary=false'
    echo 'cmuxnext_swift=false'
    echo 'swift_canary_targets='
    echo 'macos=true'
    echo 'scheme=true'
    echo 'generated=true'
    echo 'swift=false'
    echo 'daemon=true'
    echo 'full=false'
    echo 'swift_filter='
    echo 'swift_priority_filter='
    echo 'swift_targets='
  } >> "$GITHUB_OUTPUT"
  {
    echo '### cmux-next tiers'
    echo
    echo '| tier | runs |'
    echo '| --- | --- |'
    echo '| generated | true |'
    echo '| scheme | true |'
    echo '| daemon | true |'
    echo
    echo '- base tier: daemon tests, generated files and the Debug app scheme compile on the feat-cmux-next tip.'
  } >> "$GITHUB_STEP_SUMMARY"
elif [[ "$EVENT_NAME" == workflow_dispatch && "$TIP_DAEMON_SUITE" == true ]]; then
  # Why: docs/ci/cmux-next-workflow-notes.md#note-393
  [[ "$GITHUB_REF" == refs/heads/feat-cmux-next ]] || {
    echo "error: tip_daemon_suite runs on refs/heads/feat-cmux-next, got $GITHUB_REF" >&2
    exit 1
  }
  {
    echo 'native=false'
    echo 'swift_canary=false'
    echo 'cmuxnext_swift=false'
    echo 'swift_canary_targets='
    echo 'macos=true'
    echo 'scheme=false'
    echo 'generated=false'
    echo 'swift=false'
    echo 'daemon=true'
    echo 'full=false'
    echo 'swift_filter='
    echo 'swift_priority_filter='
    echo 'swift_targets='
  } >> "$GITHUB_OUTPUT"
  {
    echo '### cmux-next tiers'
    echo
    echo '| tier | runs |'
    echo '| --- | --- |'
    echo '| daemon | true |'
    echo
    echo '- scheduled tip daemon suite: the live-daemon suites on the feat-cmux-next tip.'
  } >> "$GITHUB_STEP_SUMMARY"
else
  # --base-rev: the merge commit's first parent, so a change to this workflow that leaves
  # every Mac job and what it needs as it was (`on:` paths, a Linux-only job) is CI-only.
  # The router runs every tier when it cannot read or compare that base.
  routed="$GITHUB_OUTPUT"
  if [[ "$EVENT_NAME" == push && "$GITHUB_REF" == refs/heads/feat-cmux-next && "$BASE_TIER_COALESCE" == true ]]; then
    routed="$RUNNER_TEMP/route-outputs.txt"
    : > "$routed"
  fi
  python3 scripts/ci/cmux_next_route.py --event "$EVENT_NAME" --changed-files "$changed" \
    --labels "$labels" --base-rev HEAD^1 --github-output "$routed" --summary "$GITHUB_STEP_SUMMARY"
  if [[ "$routed" != "$GITHUB_OUTPUT" ]]; then
    # Why: docs/ci/cmux-next-workflow-notes.md#note-406
    keep=()
    [[ "$DEV_LANDING_COMPILE" == 0 ]] && keep=(--keep scheme)
    python3 scripts/ci/cmux_next_base_tier.py defer "$routed" "${keep[@]}" >> "$GITHUB_OUTPUT"
    echo '- base tier (daemon tests, generated files, scheme compile): left to the cmux-next base tier run on the tip, at most 15 minutes away (cmux-next-base-tier-kick.yml); the Swift canary is left to the scheduled tip Swift suite.' >> "$GITHUB_STEP_SUMMARY"
  fi
  # Why: docs/ci/cmux-next-workflow-notes.md#note-365
  if [[ "$EVENT_NAME" == workflow_dispatch && -z "$SAME_TREE_SHA" && "$FULL_DISPATCH" != true \
    && "$GITHUB_REF" != refs/heads/feat-cmux-next && "$GITHUB_REF" != refs/heads/next-batch/* ]]; then
    printf 'scheme=false\nnative=false\n' >> "$GITHUB_OUTPUT"
    echo '- working-branch dispatch: the scheme and Release compiles are skipped (dispatch with full=true to run them).' >> "$GITHUB_STEP_SUMMARY"
  fi
  # Why: docs/ci/cmux-next-workflow-notes.md#note-388
  if [[ "$EVENT_NAME" == pull_request && "$SAME_REPO_PR" == true && "$BASE_MERGE_CARRY" == true ]]; then
    python3 scripts/ci/cmux_next_base_merge_carry.py --repo "$GITHUB_REPOSITORY" --head "$PR_HEAD_SHA" \
      --base-ref "$PR_BASE_REF" --labels "$labels" --github-output "$GITHUB_OUTPUT" \
      --summary "$GITHUB_STEP_SUMMARY" || true
  fi
fi
# A draft head, a ready head without ready-to-land (the land rule), or a base merge into a PR idle 24 h runs
# the cheap tier: no Mac tier, and no cargo fast tier (set again after its route below; a later line of an
# output wins). scripts/ci/head_tier.py decides.
head_tier=""
if [[ "$EVENT_NAME" == pull_request && -f scripts/ci/head_tier.py ]]; then
  head_tier="$(python3 -I scripts/ci/head_tier.py tier 2>/dev/null || true)"
fi
if [[ "$head_tier" == cheap || "$head_tier" == none ]]; then
  printf '%s=false\n' native swift_canary cmuxnext_swift mac_release macos scheme generated swift daemon full fast_tier >> "$GITHUB_OUTPUT"
  echo "- head tier $head_tier (a draft, a ready head without the ready-to-land label, or a base merge into a PR idle 24 h): path routing only; the cargo fast tier and the Mac tiers run when the ready-to-land or full-ci label is added (the label re-runs this workflow at the same head)." >> "$GITHUB_STEP_SUMMARY"
fi
# Whether this pull request changes the cmux-tui it would test against:
# any v2 tree-key input (cmux-tui-tree-inputs.txt), such as cmux-tui/,
# ghostty-next or cmux-cloud's crate. One that does not is never
# failed for an unpublished merge tree (the probe steps below,
# CMUX_TUI_TREE_BASE_FALLBACK).
if [[ "$EVENT_NAME" == pull_request ]] && ! python3 - "$changed" <<'PY'
import sys
inputs = []
for raw in open("scripts/cmux-next/cmux-tui-tree-inputs.txt", encoding="utf-8"):
    raw = raw.strip()
    if raw and not raw.startswith("#"):
        kind, path = raw.split(maxsplit=1)
        if (kind, path) != ("gitlink", "ghostty"):  # v1 key only
            inputs.append((kind, path))
changed = [line.strip() for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
hit = any(c == p or (k == "tree" and c.startswith(p + "/")) for c in changed for k, p in inputs)
sys.exit(0 if hit else 1)
PY
then
  echo "own_tui=false" >> "$GITHUB_OUTPUT"
else
  echo "own_tui=true" >> "$GITHUB_OUTPUT"
fi
# Leo, 2026-11-21: "id rather we simply cut shit now and revisit later." A pull request runs fast-tier-cargo
# only when its change reaches a cargo or script entry of the fast tier (2.94% of pull request runner-minutes,
# 0.06% of heads with it as their only own red over 11-13..19: cmuxterm-hq#16094). Any failure reads as reached.
# Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes of ci time, period." Only the entries' own crates,
# the workspace root and the job's inputs reach it; dependency crates and tree inputs are tested after the merge.
if [[ "$EVENT_NAME" == pull_request ]]; then
  python3 -I scripts/ci/fast_tier_cargo_route.py --changed-files "$changed" --labels "$labels" \
    --github-output "$GITHUB_OUTPUT" >> "$GITHUB_STEP_SUMMARY" || echo "fast_tier_cargo=true" >> "$GITHUB_OUTPUT"
fi
# Why: docs/ci/cmux-next-workflow-notes.md#note-557
# Leo, 2026-11-21: "help 100x ci speed ... while maintaining a partial semblance of checks. and we can infrequenrly
# have fuller checks." A pull request into feat-cmux-next runs only the Linux fast tier here; every Mac job, the
# cargo fast tier, web bundles and the tests and compiles they feed run in the feat-cmux-next push run (the batched
# tier), where a red is fixed forward. full-ci runs everything; dev-build keeps its scheme compile;
# vars.CI_PR_FAST_ONLY=0 turns this off. Last, so these lines win over every route above.
if [[ "$EVENT_NAME" == pull_request && "${PR_BASE_REF:-}" == feat-cmux-next && "${PR_FAST_ONLY:-true}" == true \
  && ",$labels," != *,full-ci,* ]]; then
  deferred=(swift_canary cmuxnext_swift mac_release macos swift daemon full fast_tier fast_tier_cargo)
  # Leo, 2026-11-25: "if like... it works on linux and is at least as fast if not faster, then we ought to just go
  # ahead." Generated files runs on the Linux pool (generated-files-linux), so a pull request keeps it unless
  # vars.CI_GENERATED_FILES_LINUX=0 sends it back to the Mac.
  [[ "${GENERATED_LINUX:-true}" == true ]] || deferred+=(generated)
  [[ ",$labels," == *,dev-build,* ]] || deferred+=(scheme)
  printf '%s=false\n' "${deferred[@]}" >> "$GITHUB_OUTPUT"
  echo "::notice title=cmux-next PR fast tier::Mac jobs, the cargo fast tier and web bundles are deferred to the feat-cmux-next push run; add the full-ci label to run them here"
  echo "- PR fast tier (vars.CI_PR_FAST_ONLY): deferred to the feat-cmux-next push run: ${deferred[*]}. The full-ci label runs every tier here." >> "$GITHUB_STEP_SUMMARY"
fi
# Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes of ci time, period." The cheap tier skips the
# cargo fast tier too; the ready-to-land label runs it at the head handed to land.
if [[ "$head_tier" == cheap || "$head_tier" == none ]]; then
  echo "fast_tier_cargo=false" >> "$GITHUB_OUTPUT"
fi
