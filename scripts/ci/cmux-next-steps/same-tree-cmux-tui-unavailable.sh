#!/usr/bin/env bash
# cmux-next.yml same-tree-cmux-tui: "Report the unavailable same-tree cmux-tui".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
if [[ -n "$COMMIT" ]]; then
  # Why: docs/ci/cmux-next-workflow-notes.md#note-451
  marker="$RUNNER_TEMP/cmux-next-tree-wait/marker.json"
  if python3 scripts/ci/cmux_next_same_tree_failed.py --repo "$GITHUB_REPOSITORY" --ref "$REF_NAME" \
      --ref-kind "$REF_KIND" --reason "$REASON" --key "$KEY" --commit "$COMMIT" --status-sha "$STATUS_SHA" \
      --tiers "$TIERS" --origin "$ORIGIN" --origin-run "$ORIGIN_RUN" --dev-daily-sha "$DEV_DAILY_SHA" \
      ${TIP_SUITE:+--tip-suite "$TIP_SUITE"} --marker "$marker" --output "$GITHUB_OUTPUT"; then
    echo "::notice title=same-tree cmux-tui published::the tree was published after this run was dispatched; its tree jobs were dispatched again (ready)"; exit 0
  fi
  [[ -f "$marker" ]] && echo "marker=$marker" >> "$GITHUB_OUTPUT"
fi
if [[ -n "$COMMIT" ]] && python3 scripts/ci/cmux_tui_tree_takeover.py --repo "$GITHUB_REPOSITORY" --commit "$COMMIT" --key "$KEY" --reason "$REASON"; then
  echo "::notice title=same-tree cmux-tui taken over::$REASON"; exit 0
fi
echo "::error title=same-tree cmux-tui unavailable::${KEY:+tree $KEY: }${REASON:-no reason given}"
if [[ "$STATUS_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  for tier in ${TIERS//,/ }; do
    case "$tier" in
      daemon) context="cmux-next daemon tests (same-tree)" ;;
      scheme)
        if [[ "$DEV_DAILY" == true ]]; then
          context="cmux NEXT DEV Release compile (same-tree)"
        else
          context="cmux app scheme compile (Debug) (same-tree)"
        fi ;;
      *) continue ;;
    esac
    scripts_status="$(python3 -c 'import json,sys; print(json.dumps({"state": "failure", "context": sys.argv[1], "target_url": sys.argv[2], "description": "same-tree cmux-tui unavailable"}))' "$context" "$TARGET_URL")"
    curl -fsS -o /dev/null -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
      "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/statuses/$STATUS_SHA" -d "$scripts_status" \
      || echo "::warning::could not post the $context status"
  done
fi
exit 1
