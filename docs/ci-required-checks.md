# Required CI checks

`ci-status-gate` is the only check intended for the `main` required-check
ruleset. It is produced by GitHub Actions app `15368` from
`.github/workflows/ci-status-gate.yml`.

The gate is base-owned. It runs on `pull_request_target` lifecycle events and
again when the `CI` workflow completes. It checks the live pull request, pins
the exact head SHA, reads the matching CI workflow run, and fetches check runs
for that SHA. It derives the changed-file routes with the trusted base
classifier, then invokes `scripts/ci/check_ci_status.py` from the trusted base
revision. The publisher uses the narrow `checks: write` permission to create
or update `ci-status-gate` and `ci-status` check runs on that exact head. No
repository contents are written. Missing, stale, pending, failed, or
unexpected CI jobs fail closed.

For a `workflow_run` event whose API response omits pull-request associations,
the gate resolves the commit to exactly one open PR targeting this repository's
`main` branch with the same head SHA. It checks out the explicit protected
`refs/heads/main` ref for that recovery path and never uses the event default
ref or SHA as trusted code.

Each published run has a deterministic `external_id` with generation `v2`,
the check name, and the head SHA. The gate updates only a run with that exact
identity and refuses a response from another producer. A future migration
must use a new generation instead of reusing old check runs.

The `pull_request` workflow remains untrusted. Its `ci-status-advisory` job
and `ci-status-validator-canary` job are diagnostic only and must not be added
to branch protection. The advisory jobs may execute pull-request code, but
they have read-only permissions and do not control mergeability.

During rollout, the base-owned gate workflow also publishes the legacy
`ci-status` context. It mirrors `ci-status-gate` only so an existing
required-check rule does not become permanently pending. Remove that alias in
the same ruleset update that makes `ci-status-gate` required. The untrusted
`pull_request` workflow retains a temporary `ci-status` producer so this
bootstrap PR can pass the existing rule before the gate workflow is on `main`.
Remove that producer immediately after the base-owned gate is merged and the
ruleset switches. The untrusted workflow must never remain a required
authority.

The base-owned gate compares the blob SHA for `.github/workflows/ci.yml` at
the live base and head commits. A changed workflow definition is rejected
unless Austin (`austinywang`, account ID `38676809`) or Aziz
(`azooz2003-bit`, account ID `67667005`) has an approving human review for the
exact head commit. Later changes, dismissals, and self-approval do not count.

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
as security-sensitive changes. The gate helper itself is imported only from
the `.ci-trusted` checkout of the base commit, so a pull request cannot replace
the code that evaluates its own checks.

To roll back, remove only the `ci-status-gate` required-check rule, keep the
base-owned workflow and validator, and investigate the failing snapshot. Do
not restore a path-filtered `pull_request` trigger, because that leaves a
required check permanently pending for unmatched paths.
