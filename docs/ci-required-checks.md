# Required CI checks

`ci-status-gate` is the only check intended for the `main` required-check
ruleset. It is produced by GitHub Actions app `15368` from
`.github/workflows/ci-status-gate.yml`.

The gate is base-owned. It runs on `pull_request_target` lifecycle events and
again when the `CI` workflow completes. It checks the live pull request, pins
the exact head SHA, reads the matching CI workflow run, and fetches check runs
for that SHA. It derives the changed-file routes with the trusted base
classifier, then invokes `scripts/ci/check_ci_status.py` from the trusted base
revision. Missing, stale, pending, failed, or unexpected CI jobs fail closed.

The `pull_request` workflow remains untrusted. Its `ci-status-advisory` job
and `ci-status-validator-canary` job are diagnostic only and must not be added
to branch protection. The advisory jobs may execute pull-request code, but
they have read-only permissions and do not control mergeability.

Before activating the rule, merge this bootstrap, rebase the route-aware CI
change, and observe these cases on fresh pull requests: docs-only, macOS,
web, Go, agent-session, and workflow changes. Confirm that the base-owned gate
publishes `ci-status-gate` after CI completion for each case.

The `main` ruleset must require code-owner review for policy inputs, at least
one approving code-owner review, strict required checks, the exact
`ci-status-gate` context from integration `15368`, and no bypass actor. The
CODEOWNERS entries for `/.github/workflows/**`, `/scripts/ci/**`, and
`/.github/CODEOWNERS` are owned by `@austinywang` and `@azooz2003-bit`.

The gate validates CI conclusions, not the contents of every test process.
An approved maintainer could still weaken the pull-request workflow. The
code-owner rule is defense in depth; keep it active and review workflow edits
as security-sensitive changes.

To roll back, remove only the `ci-status-gate` required-check rule, keep the
base-owned workflow and validator, and investigate the failing snapshot. Do
not restore a path-filtered `pull_request` trigger, because that leaves a
required check permanently pending for unmatched paths.
