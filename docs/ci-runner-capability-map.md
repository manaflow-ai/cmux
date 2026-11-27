# The runner capability map

A job says what it needs. `.github/runners.json` says which label answers that
need on whichever repository the run is happening in.

This is foundation only. One workflow is wired to it
(`ios-app-store.yml`); the other call sites still read `vars.MACOS_RUNNER_*`
and [`ci-runners.md`](ci-runners.md) remains the live contract for them.
A job wired to the map stops reading its old variable: `ios-app-store.yml`'s
upload no longer follows `MACOS_RUNNER_IOS`, so moving it takes
`CMUX_CI_RUNNER_OVERRIDES` or `CMUX_CI_RUNNER_FLEET` instead.
[PR #14010](https://github.com/manaflow-ai/cmux/pull/14010) argues the general
case for capability routing; this is the translation layer that proposal calls
irreducible, built small enough to use.

## What a fork gets

A fork of cmux cannot run macOS or Linux CI today. Blacksmith is an
organization-level GitHub App, so a fork on a personal account has no
Blacksmith access — and a `blacksmith-*` label there does not fail. The job
sits `queued` indefinitely and holds the workflow's concurrency group while it
waits. The workaround has been hand-setting eight repository variables on the
fork.

With the map in the tree, the repository owner selects the fleet:

```console
$ GITHUB_REPOSITORY_OWNER=some-personal-account python3 scripts/ci/resolve_runners.py
resolve_runners: fleet=hosted (owner some-personal-account is not a mapped owner; using default_fleet)
{"linux":"ubuntu-24.04","linux_arm64":"ubuntu-24.04-arm","macos_15":"macos-15", ...}
```

Zero configuration. `owners` lists `manaflow-ai: blacksmith`; every other owner
falls to `default_fleet`, which is the free GitHub-hosted fleet.

The hosted fleet is a working fleet, not an identical one. `macos_26`,
`macos_26_ios` and `macos_26_large` resolve to GitHub's hosted `macos-26`
image, which has the OS but not the 12 vCPU size. `macos-26` is also a label
the self-hosted mini fleet carries, which is why workflows in manaflow-ai may
not name it; the map only hands it to other owners, where no runner carries
that label (the one on teamleaderleo/cmux is labelled `cmux-local-mac`).

The resolver job itself runs on `ubuntu-24.04`, never on a mapped label, so it
starts on any owner before anything is resolved.

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
