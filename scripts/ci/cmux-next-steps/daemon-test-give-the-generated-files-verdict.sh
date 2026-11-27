#!/usr/bin/env bash
# cmux-next.yml daemon-test: "Give the generated files verdict".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
if [[ "$ACTIONS" == failure && "$CATALOG" == failure ]]; then
  verdict=catalog
  {
    echo "### The action catalog checks fail: a catalog failure, not stale files"
    echo
    echo "Fresh exports fail the same checks, so regenerating changes nothing. The step \"Check generated action catalog, surfaces and inventory\" names the failing test."
    [[ "$SETTINGS" != failure ]] || echo "- settings exports are also stale: scripts/cmux-next/regenerate-settings-exports.sh"
  } | tee -a "$GITHUB_STEP_SUMMARY"
elif [[ "$ACTIONS" == failure || "$SETTINGS" == failure ]] && [[ "$AUTOFIXED_OK" == true ]] \
  && why="$(scripts/cmux-next/generated-autofixable.sh)"; then
  verdict=autofixed
  echo "### Generated cmux-next files are stale: autofixed ($why)" | tee -a "$GITHUB_STEP_SUMMARY"
elif [[ "$ACTIONS" == failure || "$SETTINGS" == failure ]]; then
  verdict=stale
  {
    echo "### Generated cmux-next files are stale"
    echo
    [[ "$ACTIONS" != failure ]] || echo "- action catalog, surfaces or inventory: scripts/cmux-next/regenerate-action-contracts.sh"
    [[ "$SETTINGS" != failure ]] || echo "- settings exports: scripts/cmux-next/regenerate-settings-exports.sh"
    echo
    echo "The cmux-next-generated-patch artifact holds the regenerated files at their repository paths."
  } | tee -a "$GITHUB_STEP_SUMMARY"
elif [[ "$ACTIONS" == success && "$SETTINGS" == success ]]; then
  verdict=fresh
else
  # Why: note-542
  verdict=
fi
echo "verdict=$verdict" >> "$GITHUB_OUTPUT"
