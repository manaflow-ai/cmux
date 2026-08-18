# Why this lane hydrates main only

Full reasoning behind the `--ref main` rule in `skills/blacksmith-testbox/SKILL.md`.
Read this before changing the warmup workflow, the environment configuration, or
anything that runs before `begin-testbox`.

`useblacksmith/begin-testbox` writes `/tmp/.testbox/auth_token` into the CI job,
and `permissions: contents: read` does not stop a later step from reading it.
`blacksmith testbox warmup` resolves the workflow definition and the hydrated
source from the same `--ref`, so warming a candidate branch would run that
branch's copy of the workflow beside the token, and the branch could delete its
own guards.

The lane hydrates `main` only. The first step refuses any other ref, no
repository code runs before the token, and your revision arrives afterwards
through `blacksmith testbox run` as an authenticated org member who could
already reach the box. `tests/test_ci_testbox_broker_guard.py` enforces that
shape on every pull request through
`.github/workflows/testbox-broker-guard.yml`.

A repository administrator owns the `blacksmith-testbox-trusted` environment:
required reviewers, no secrets, admin bypass disabled, and a deployment branch
rule of exactly `main`. If that drifts, disable the lane and stop. Never edit
the workflow to work around a missing control.
