# Required CI checks

The `ci-status` job is the single required status for pull requests. It reads
the results of the routed jobs and fails when a selected route is skipped or
fails. Its check is produced by GitHub Actions app `15368`.

## Trust boundary

`ci-status` and `linux-preflight` check out the pull request base commit into
`.ci-trusted`, verify that the checkout has the exact base SHA, and execute
`scripts/ci/check_ci_status.py` from that checkout. This keeps the validator
fixed while a pull request is under review. The `/.github/workflows/**` and
`/scripts/ci/**` patterns in `.github/CODEOWNERS` are owned by
`@austinywang` and `@azooz2003-bit`.

Before making `ci-status` required, the `main` branch ruleset must set
`require_code_owner_review=true` and require at least one approving review
(`required_approving_review_count >= 1`). The ruleset must require the exact
`ci-status` context from Actions app `15368`, with no bypass actor. CODEOWNERS
declares who may approve policy changes; only the branch ruleset enforces that
review requirement.

## Rollout

1. Merge the workflow, validator, tests, and CODEOWNERS change.
2. Wait for a pull request run to publish `ci-status` for each route. Include
   docs-only, macOS, web, Go, agent-session, and workflow changes in the canary
   set.
3. Confirm the `main` ruleset has code-owner review enabled, one approving
   review, strict required checks, and no bypass for `ci-status`.
4. Add a separate active ruleset for `refs/heads/main` with the required
   `ci-status` context and Actions app ID `15368`. This GitHub administration
   step is separate from this source change.
5. Verify a new pull request cannot merge when `ci-status` is missing, skipped,
   or failed, and that an unrelated route may still skip its expensive jobs.

The first rollout has a bootstrap dependency: the trusted base commit must
contain `scripts/ci/check_ci_status.py`. Merge this source change before
activating the required-check ruleset, or stage the validator in an earlier
trusted commit. Activating the ruleset before that commit exists would make
every pull request fail closed.

To roll back, disable or remove only the new `ci-status` ruleset, keep the
workflow and CODEOWNERS files, and investigate the failed contract. Do not
restore a path-filtered pull-request trigger, because GitHub then leaves a
required check pending for paths that do not match the filter.
