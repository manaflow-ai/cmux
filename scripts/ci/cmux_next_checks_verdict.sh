#!/usr/bin/env bash
# The cmux-next `checks` job's verdict step ("Fail on any red check" in .github/workflows/cmux-next.yml):
# fails on any red check named in OUTCOMES (`outcome|name` lines), warns on style checks under
# CMUX_NEXT_STYLE_GUARDS=warn, and on a push tells new reds from the base's (scripts/ci/base_red_checks.py).
# Env: OUTCOMES, STYLE_CHECKS, CMUX_NEXT_STYLE_GUARDS, EVENT_NAME, BEFORE, GITHUB_REPOSITORY, RUNNER_TEMP,
# GITHUB_STEP_SUMMARY. Moved out of the workflow to keep it under its size limit.
set -e  # what a workflow `run:` step with no `shell:` runs under (bash -e)
failed=()
warned=()
# `outcome|name`: an empty outcome (a check that never ran) still names its step.
while IFS='|' read -r outcome name; do
  [[ -n "$outcome$name" ]] || continue
  [[ "$outcome" == success ]] && continue
  if [[ "$outcome" == failure && "${CMUX_NEXT_STYLE_GUARDS:-}" == warn ]] \
    && grep -qxF -- "$name" <<<"${STYLE_CHECKS:-}"; then
    warned+=("$name")
    continue
  fi
  failed+=("$name (${outcome:-not run})")
done <<<"$OUTCOMES"
# Why: docs/ci/cmux-next-workflow-notes.md#note-397
if [[ "$EVENT_NAME" == push && "$BEFORE" =~ ^[0-9a-f]{40}$ && ! "$BEFORE" =~ ^0+$ && ${#failed[@]} -gt 0 ]]; then
  current="$RUNNER_TEMP/cmux-next-red-checks.txt"
  printf '%s\n' "${failed[@]}" | sed -E 's/ \((failure|timed_out|cancelled|not run)\)$//' >"$current"
  base_out="$RUNNER_TEMP/cmux-next-base-red.out"
  if python3 scripts/ci/base_red_checks.py --repo "$GITHUB_REPOSITORY" --before "$BEFORE" --current "$current" >"$base_out"; then
    while read -r kind name; do
      [[ -n "$kind$name" ]] || continue
      if [[ "$kind" == BASE_RED ]]; then
        echo "::notice title=cmux-next base red::$name was already red on $BEFORE (or that tip had not finished)"
      else
        echo "::error title=cmux-next new red::$name is new since $BEFORE (green there): fix it first, every open pull request inherits it"
      fi
    done <"$base_out"
  else
    echo "::warning title=cmux-next base-red::could not read the previous tip to tell new reds from inherited ones"
  fi
fi
for name in "${warned[@]+"${warned[@]}"}"; do
  echo "::warning title=cmux-next style guard (warn-only)::$name found issues; see that step's log"
done
if (( ${#warned[@]} > 0 )); then
  {
    echo "### ${#warned[@]} style guard(s) reported findings (warn-only)"
    echo
    printf -- '- %s\n' "${warned[@]}"
    echo
  } | tee -a "$GITHUB_STEP_SUMMARY"
fi
if (( ${#failed[@]} == 0 )); then
  echo "All blocking cmux-next checks passed." | tee -a "$GITHUB_STEP_SUMMARY"
  exit 0
fi
# One annotation per red check: the red-checks line compares them with the base's run, so a
# new red check is told from a base one (scripts/ci/pr_red_checks_comment.py).
for name in "${failed[@]}"; do echo "::error title=cmux-next check::red check: ${name% (*}"; done
{
  echo "### ${#failed[@]} cmux-next check(s) failed"
  echo
  printf -- '- %s\n' "${failed[@]}"
  echo
  echo "Each check's own step log has the details."
} | tee -a "$GITHUB_STEP_SUMMARY"
exit 1
