#!/usr/bin/env bash
# cmux-next.yml's path_route "Classify pull request paths" step (id: route): the tiers a run takes,
# written to GITHUB_OUTPUT and the step summary. The step's env sets every variable this reads.
# It lives here, not inline, to keep cmux-next.yml under GitHub's 500 KB workflow file limit
# (tests/test_ci_workflow_file_size.py).
set -euo pipefail
changed="$RUNNER_TEMP/changed-files.txt"
labels=""
if [[ "$EVENT_NAME" == pull_request ]]; then
  git diff --no-renames --name-only HEAD^1 HEAD > "$changed"
  if [[ "$GITHUB_RUN_ATTEMPT" == 1 ]]; then
    labels="$EVENT_LABELS"
  else
    labels="$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/labels" --jq '[.[].name] | join(",")' 2>/dev/null)" || {
      echo "::warning::could not read the pull request labels; routing on its paths only"
      labels=""
    }
  fi
else
  : > "$changed"
fi
echo "changed files: $(wc -l < "$changed"); labels: ${labels:-none}"
if [[ "$EVENT_NAME" == workflow_dispatch && "$DEV_DAILY" == true ]]; then
  # The dispatcher (main's cmux-next-dev-daily-dispatch.yml) asks for
  # the feat-cmux-next tip it saw. A merge that lands before this run
  # starts moves github.sha: fail without building, and the next tick
  # asks for the new tip. No snapshot ref: creating a ref at a
  # feat-cmux-next commit needs the workflows permission (HTTP 403).
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
  # main's cmux-next-tip-swift-suite-dispatch.yml, every few hours: a
  # feat-cmux-next push skips swift-test (push CI is the app build
  # only), so a Swift suite red on the base stayed invisible for a day
  # (2026-10-21). This run gives swift-test a verdict on the tip, the
  # base run scripts/ci/base_red_excuse.py compares a PR's reds with.
  # Only the Swift suite: no scheme, daemon, native or generated tier.
  # It tests the tip it starts on, whatever the dispatcher saw.
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
  # main's tip suite dispatcher (its daemon suite): a feat-cmux-next push never gets
  # daemon-test (its same-tree run has origin push, and in a landing burst the tip moves
  # before the tree publishes), so the base had no daemon-test verdict for
  # scripts/ci/base_red_excuse.py to compare a pull request's daemon-test red with
  # (2026-10-30, #27692). Only the daemon tier. Its tree wait marker carries tip_suite, so
  # the same-tree run tests this exact commit even after the tip moves on.
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
    # The base Mac tier (daemon tests, generated files, the Debug app scheme compile) runs
    # at most once every 15 minutes on the tip, in the run cmux-next-base-tier-kick.yml
    # dispatches (cmuxterm-hq#5424). The Release compiles (nightly-next's input), the DEV
    # landing compile and the fast tier still run on this push.
    keep=()
    [[ "$DEV_LANDING_COMPILE" == 0 ]] && keep=(--keep scheme)
    python3 scripts/ci/cmux_next_base_tier.py defer "$routed" "${keep[@]}" >> "$GITHUB_OUTPUT"
    echo '- base tier (daemon tests, generated files, scheme compile): left to the cmux-next base tier run on the tip, at most 15 minutes away (cmux-next-base-tier-kick.yml).' >> "$GITHUB_STEP_SUMMARY"
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
# Whether this pull request changes the cmux-tui it would test against:
# any v2 tree-key input (cmux-tui-tree-inputs.txt), such as cmux-tui/,
# ghostty-next or cmux-cloud's crate. One that does not is never
# failed for an unpublished merge tree (the probe steps after this one in cmux-next.yml,
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
