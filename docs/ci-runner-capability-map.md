# The runner capability map

A job says what it needs. `.github/runners.json` says which label answers that
need on whichever repository the run is happening in.

This change has two layers. The capability map and
`resolve-runners.yml` are the long-term translation layer; `ios-app-store.yml`
is the first direct consumer. The normal `CI` call graph also gets an immediate
compatibility bridge: every variable-routed `runs-on` short-circuits
non-`manaflow-ai` owners to GitHub-hosted Linux or macOS before repository
variables are consulted. That makes ordinary fork CI usable now while the
remaining specialized workflows migrate to capability keys.

[`ci-runners.md`](ci-runners.md) remains the live contract for upstream lane
and capacity policy.

## What a fork gets

Before this change, a fork of cmux could not run the normal macOS or Linux CI
without hand-configuring runner variables. Blacksmith is an organization-level
GitHub App, so a fork on a personal account has no Blacksmith access — and a
`blacksmith-*` label there does not fail. The job sits `queued` indefinitely
and holds the workflow's concurrency group while it waits.

With the map in the tree, the repository owner selects the fleet:

```console
$ GITHUB_REPOSITORY_OWNER=some-personal-account python3 scripts/ci/resolve_runners.py
resolve_runners: fleet=hosted (owner some-personal-account is not a mapped owner; using default_fleet)
{"linux":"ubuntu-24.04","linux_arm64":"ubuntu-24.04-arm","macos_15":"macos-15", ...}
```

Zero configuration. `owners` lists `manaflow-ai: blacksmith`; every other owner
falls to `default_fleet`, which is the free GitHub-hosted fleet. The resolver
job itself uses the same principle for its bootstrap runner, so it can start in
a personal fork before the map exists.

Fork safety does not wait for every job to be converted to
`needs.runners.outputs.map`. Every workflow with a `pull_request` trigger,
plus every local reusable workflow reachable from those workflows, carries an
explicit non-`manaflow-ai` GitHub-hosted branch wherever runner variables or
Blacksmith fallbacks are used. `tests/test_ci_runner_capability_resolver.py`
discovers that graph recursively and fails if a variable-routed job can reach
Blacksmith on a fork.

The hosted fleet is a working fleet, not an identical one. GitHub publishes no
macOS 26 image, so `macos_26`, `macos_26_ios` and `macos_26_large` all resolve
to `macos-15` there. A fork gets a runner that starts and an older OS, which is
the trade this makes deliberately. `macos-26` is never used as a hosted
fallback: the self-hosted mini fleet carries that label and GitHub prefers a
matching self-hosted runner.

## Capability keys

The keys are requirements a job in this repository actually distinguishes.
Nothing is minted for a requirement no job has.

| Key | Means |
| --- | --- |
| `linux` | x86_64 Linux; the default for every non-macOS job |
| `linux_arm64` | aarch64 Linux; native ARM64 package entrypoint verification |
| `macos_15` | the macOS 15 image, and therefore the macOS 15 default SDK |
| `macos_15_gui` | macOS 15 with a foreground Aqua login session (XCUITest, virtual display) |
| `macos_15_sdk15` | macOS 15 carrying an SDK 15 Xcode alongside the pinned one |
| `macos_26` | the macOS 26 image |
| `macos_26_ios` | macOS 26 with installed iOS runtimes and a working `simctl` |
| `macos_26_large` | macOS 26 on the large SKU: 12 vCPU, 48 GB RAM, 250 GB disk |

Three keys collapse to the same Blacksmith label today (`macos_15`,
`macos_15_gui`, `macos_15_sdk15`), and so do `macos_26` and `macos_26_ios`.
That is not redundancy to remove. Those are different requirements that one
vendor happens to satisfy with one SKU; they separate the moment a fleet exists
where only some machines foreground an Aqua session or carry iOS runtimes.

`macos_26_large` is one key, not `cpu-12` plus `disk-large`. On Blacksmith the
12-vCPU tier is a single SKU — 12 vCPU, 48 GB RAM, 250 GB disk — so "more CPU"
and "more disk" are not separately purchasable. Two keys would imply a choice
that does not exist. `blacksmith-12vcpu-macos-15` also exists and no job in the
tree needs it, so it has no key.

Deliberately absent: `MACOS_RUNNER_PR`, `MACOS_RUNNER_TESTS` and
`MACOS_RUNNER_BACKGROUND` have no capability keys. They describe who is asking
— a pull request, a manual flake hunt, non-urgent work — which is cost and
priority policy, not a property of the job's code.

## Using it

```yaml
jobs:
  runners:
    uses: ./.github/workflows/resolve-runners.yml

  build:
    needs: runners
    runs-on: ${{ fromJSON(needs.runners.outputs.map).macos_26_ios }}
```

`fromJSON()` is safe on that output because the resolver refuses to print an
incomplete map: every fleet must define every declared capability, or the job
fails before anything is emitted. A missing key would render as `runs-on: ''`,
and an empty or unrecognised label is exactly the failure GitHub does not
report.

## Changing routing without a merge

Two repository variables, both read as plain strings:

| Variable | Effect |
| --- | --- |
| `CMUX_CI_RUNNER_FLEET` | force a declared fleet, e.g. `hosted`, for the whole repository |
| `CMUX_CI_RUNNER_OVERRIDES` | a JSON object of capability → label, e.g. `{"macos_26":"macos-15"}` |

Neither is ever read with `fromJSON(vars.X)` in a workflow expression.
`fromJSON()` on an unset repository variable evaluates `fromJSON('')`, which
fails the whole workflow at expression evaluation — an override nobody set
would break every consumer. Both variables are handed to
`scripts/ci/resolve_runners.py` as environment strings, and an empty or
whitespace-only value means "no override". A malformed override, or one naming
a capability key that does not exist, fails the resolver loudly rather than
being ignored.

`.github/workflows/resolve-runners.yml` also takes a `fleet` input, so a single
caller can pin its own fleet without touching repository state.

## Adding a capability or a fleet

Edit `.github/runners.json`: add the key to `capabilities` with a prose
description of the requirement, then give it a label in *every* fleet.
`tests/test_ci_runner_capability_resolver.py` fails if a fleet is missing a key
or defines one that `capabilities` does not declare. A new fleet is a new entry
under `fleets` plus, if it should serve an owner, a row in `owners`.
