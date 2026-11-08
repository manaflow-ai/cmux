# Routing CI by capability instead of by vendor (proposed)

**Status: proposed. Nothing in this document is implemented.** No workflow,
repository variable, guard or runner registration described here exists today.
The routing contract that *is* live is [`ci-runners.md`](ci-runners.md); read it
first. This document argues for replacing part of it and says what that would
cost.

## The problem

A cmux job names the company that owns the machine it wants:

```yaml
# today, ci-macos.yml — names who owns the machine
runs-on: ${{ github.event_name == 'pull_request' && (vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15') || vars.CI_PAID_MACOS_OVERFLOW == '1' && vars.MACOS_RUNNER_DISPLAY || 'blacksmith-6vcpu-macos-15' }}
```

Nothing in that line says what `tests-build-and-lag` actually needs, which is a
macOS machine with a foreground Aqua login session. It says Blacksmith, twice,
plus two repository variables and a cost gate.

The consequences are countable on `main` today:

- **9 distinct `vars.MACOS_RUNNER_*` variables** are referenced by workflows
  (`_15`, `_26`, `_26_LARGE`, `_BACKGROUND`, `_DISPLAY`, `_DUAL_XCODE`,
  `_IOS`, `_PR`, `_TESTS`), plus `CI_PAID_MACOS_OVERFLOW` and
  `CMUX_CI_XCODE_APP_PR`.
- Between them they carry **three distinct macOS label values** —
  `blacksmith-6vcpu-macos-15`, `blacksmith-6vcpu-macos-26`,
  `blacksmith-12vcpu-macos-26` — plus "unset".
- `tests/test_ci_self_hosted_guard.sh` defines **35 distinct `check_*`
  functions** and invokes them **40 times**. At least ten of those exist only
  to police which vendor string may appear in which position.

That is more configuration than there are answers, and the excess is where
drift hides. [#14002](https://github.com/manaflow-ai/cmux/pull/14002)
documents one instance: one lane-named variable served two
jobs with incompatible macOS requirements, their two fallbacks disagreed, and
`ci-runners.md` recorded the contradiction as a feature for as long as it took
someone to read it.

The forecast makes this worse, not better. The owner's requirement, verbatim:

> eventually we have glaeda and a fleet of minis + interacting macbooks + mac
> ultras + blacksmith sponsoring + assorted cloud shit — we need to STOP
> NEEDING TO THINK ABOUT THIS BULLSHIT.

Under the current scheme, each new machine class needs a label, a variable or
a guard exemption, and probably all three. `check_no_self_hosted_fleet_runners`
already carries a hand-maintained regex of every machine name anyone has ever
enrolled (`cmux-aws-macos`, `cmux-local-macos`, `macfleet`, `mac4`, `mac-mini`,
`slot-[0-9]`, `xcode-[0-9]+-[0-9]`) purely so those names cannot appear in a
`runs-on`.

## The proposal

A job declares the capabilities it requires. Capacity advertises the
capabilities it provides. GitHub's label matching joins the two.

```yaml
# proposed — names what the job requires
runs-on: [self-hosted, macos-26, gui]
```

Adding a Mac Ultra becomes: register the runner, give it the labels its
hardware and image actually support. No workflow edit, no repository variable,
no guard change, no doc update.

### The rule this encodes

**Image and machine size are properties of a job.** Which macOS version,
which SDKs, whether a GUI session is needed, whether a simulator is needed,
how much disk the build writes — those are determined by the code under test
and change in a pull request, where they are reviewed next to the change that
caused them.

**Vendor and cost policy are operator choices.** Whether that job runs on a
sponsored Blacksmith VM, a metered Warp VM, an owned glaeda mini,
or a Mac Ultra in someone's office is not a property of the code, is not
reviewable in a pull request, and changes for reasons the code never sees.

Today both live in the same expression, as repository variables. That is why
there are more variables than distinct values: each new *job* requirement
needs a new *operator* knob to express it.

## The capability vocabulary

Derived from distinctions that jobs on `main` actually make. Nothing here is
proposed for a requirement no job has.

| Label | Means | Required today by | Replaces |
| --- | --- | --- | --- |
| `macos-14`, `macos-15`, `macos-26` | the macOS major version, and therefore the default SDK | every macOS job; `macos-14` only by the `ci-macos-compat.yml` and `relay-publish-npm.yml` compat legs | `MACOS_RUNNER_15`, `MACOS_RUNNER_26`, the `matrix.os` compat legs |
| `x86_64` | Intel silicon | `ci-macos-compat.yml`'s `macos-15-intel` leg, the only job in the tree that needs it | the bare hosted labels the guard exempts by exact line |
| `sdk-15` | carries an SDK 15 Xcode *alongside* the pinned one | `swift-package-tests`, which pins `CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15` for the Release helper and then asserts `HELPER_SDK_VERSION == 15.*` | `MACOS_RUNNER_DUAL_XCODE` |
| `gui` | a foreground Aqua login session, not just a macOS shell | `tests-build-and-lag` (XCUITest, virtual display) | `MACOS_RUNNER_DISPLAY` |
| `ios-simulator` | installed iOS runtimes and a working `simctl` | `test-ios.yml`, `ios-testflight.yml`, `ios-screenshots.yml`, `ios-app-store.yml`, `iroh-v2.yml` | `MACOS_RUNNER_IOS` |
| `macos-large` | the larger machine tier: more vCPU, memory and disk | the changed-revision universal Nightly build | `MACOS_RUNNER_26_LARGE` |

Plus `self-hosted`, which GitHub requires as the first element of a
self-hosted label array, and the existing Linux equivalents (`linux`, `arm64`)
for `LINUX_RUNNER` / `LINUX_ARM64_RUNNER`.

Six capability labels against nine variables. The three variables with no
capability row are the tell:

- `MACOS_RUNNER_PR`, `MACOS_RUNNER_TESTS`, `MACOS_RUNNER_BACKGROUND` describe
  **who is asking** — a pull request, a manual flake hunt, non-urgent work.
  They are cost and priority policy, not capability, and under this proposal
  they leave the workflow file entirely (see "Cost policy" below).

`macos-large` replaces two labels from the first draft, `cpu-12` and
`disk-large`. On Blacksmith they are one tier, so a job cannot ask for one
without the other:

| Tag | vCPU | RAM | Storage |
| --- | --- | --- | --- |
| `blacksmith-6vcpu-macos-*` | 6 | 24 GB | 150 GB |
| `blacksmith-12vcpu-macos-*` | 12 | 48 GB | 250 GB |

`release-build` now runs on the 6-vCPU macOS 26 pool, so the universal
Nightly build is the only job on `main` that uses the large tier. It is still
the weakest entry in this table: the threshold is the tier Blacksmith sells,
not a requirement anyone measured. Measure it before minting the label. A
capability label with an arbitrary threshold is a vendor label wearing a
costume.

## Two pieces that do not go away

### 1. A vendor translation layer is permanent

Blacksmith and Warp own their label names. `blacksmith-6vcpu-macos-26` is
their vocabulary, and there is no documented way to make a third-party
provider advertise `[self-hosted, macos-26, gui]` instead.

GitHub's matching makes this irreducible rather than merely inconvenient.
[GitHub's documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job)
states that when `runs-on` specifies an array of labels, "jobs will be queued
on runners that have all the labels that you specify" — the labels are
cumulative, an AND, matched by exact name. There is no set-intersection,
no partial match, no preference ordering and no documented fallback between
runner types. Combining a group with labels is also an AND: the runner must be
in the group *and* carry every label.

Two consequences:

- `runs-on: [self-hosted, macos-26, gui]` will never match a Blacksmith
  runner. Blacksmith offers only its fixed tags,
  `blacksmith-{6,12}vcpu-macos-{15,26,27,latest}`, and no customer-defined
  labels ([instance types](https://docs.blacksmith.sh/blacksmith-runners/overview)).
  The translation table therefore stays for as long as any Blacksmith capacity
  is in use.
- A GitHub-hosted image label cannot be combined with capability labels
  either. `runs-on: macos-15` is a single hosted label; `[macos-15, gui]`
  is a self-hosted match that no hosted runner satisfies.

So something must translate a capability set into whatever string each
provider answers to. The proposal is that it is **one** thing — a checked-in
table and a resolver — rather than nine repository variables and ten guard
functions, and that jobs never see it.

```
capability set                          →  label
[self-hosted, macos-26]                 →  blacksmith-6vcpu-macos-26
[self-hosted, macos-26, macos-large]    →  blacksmith-12vcpu-macos-26
[self-hosted, macos-15, sdk-15]         →  blacksmith-6vcpu-macos-15
[self-hosted, macos-26, gui]            →  (owned capacity; passes through unchanged)
```

Owned capacity is the case where the translation is the identity function,
because CMUX controls what labels those machines register with. That is the
whole win: the translation layer shrinks as owned capacity grows, and a Mac
Ultra never enters the table at all.

### 2. Cost policy stays one explicit decision

Label matching answers "any machine that fits". It cannot express "prefer the
free pool, fall back to the paid one" — GitHub has no preference ordering
between eligible runners, so a job whose labels match both free and paid
capacity will take whichever the scheduler hands it.

This is not a regression. cmux has no automatic overflow today either;
`ci-runners.md` says so outright, and `CI_PAID_MACOS_OVERFLOW` is a manual
two-action switch precisely because between 2026-09-19 and 2026-09-23 the
gated variables pointed at Warp and nothing in the repository could see it.

Under this proposal that decision survives as **one** operator control over
the translation table — which vendor a capability set resolves to, and
therefore whether metered capacity is reachable at all. What disappears is
its spread across four gated variables and
`check_no_paid_overflow_fallbacks`, which today exists because a fork PR
resolves every variable to empty and lands on the literal fallback, so every
fallback in the tree must be audited for the string `warp-`.

## What this deletes

**Repository variables.** 9 `MACOS_RUNNER_*`, `CI_PAID_MACOS_OVERFLOW`, and
`CMUX_CI_XCODE_APP_PR` — 11 in all — collapse to the
translation table plus a single cost control. `CMUX_CI_XCODE_APP_PR` is the
least certain of these: it exists because the pool and its Xcode pin must move
together, which a capability label makes structural rather than conventional,
but `scripts/select-ci-xcode.sh` still has to resolve a concrete
`/Applications/Xcode_*.app` path at runtime. That resolution is a script
problem, not a variable, but it has not been designed here.

**Guard functions.** Of the 33 `check_*` functions in
`tests/test_ci_self_hosted_guard.sh`, these become unnecessary — not
unenforced, but *unrepresentable*, because a job that cannot name a vendor
cannot name the wrong one:

| Function | Invariant it polices |
| --- | --- |
| `check_no_bare_github_hosted_runners` | no job pins a bare `ubuntu-*` / `macos-NN` |
| `check_no_self_hosted_fleet_runners` | the fleet-name regex, its self-test probes, and the line-number exemption for owned E2E dropdown options |
| `check_macos_runner` (7 call sites) | each named job routes through a paid macOS label |
| `check_release_build_runner_disk_capacity` | `release-build` uses the exact macOS 26 pool expression and fallback |
| `check_display_runner_identity_guard` | `tests-build-and-lag` validates Depot identity when `MACOS_RUNNER_DISPLAY` resolves to Depot |
| `check_ios_runner_routing` | every macOS iOS job takes the runner job's pool, which reads the dispatch input and `MACOS_RUNNER_*` |
| `check_macos_xcode_pin_tracks_pull_request_lane` | the Xcode pin follows the same lane variable as the pool |
| `check_macos_runner_identity_env_tracks_routing` | every `MACOS_RUNNER`-bearing env value equals its job's `runs-on` |
| `check_no_paid_overflow_fallbacks` | no workflow falls back to `warp-` |
| `check_background_macos_lane` (+ `background_lane_blocking_events`, `strip_background_lane_expr`) | hosted macOS labels appear only as the background-lane fallback, on non-blocking workflows |

**Ten check functions and two helpers, covering 15 of the 38 invocations.**

One more stays. `check_e2e_runner_fallbacks` polices the concurrency and
`continue-on-error` rules, which are unrelated (its Tart-choice and
runner-identity assertions went with the Tart VM fleet on 2026-09-25). `check_cla_guard_runner`
inverts: it asserts a job is *not* redirectable, which still needs saying.

The remaining 22 checks — signing, DMG, Sentry, XCTest skips, web tests,
concurrency — are untouched. This proposal deletes a third of the file's
routing surface, not the file.

The `.github/actionlint.yaml` label list also shrinks to the capability
vocabulary, and `warp-macos-26-arm64-6x` — listed there today only to record
that CMUX minis carry that label and GitHub would prefer them — stops being a
hazard that needs a comment.

## Migration

Each step is independently revertible and leaves CI green. No flag day.

**Step 0 — prove matching on real label sets, change nothing.**
`runs-on` accepts a computed label array, such as
`runs-on: ${{ fromJSON(needs.route.outputs.labels) }}`, and a runner must
carry every listed label. GitHub's syntax reference does not show the array
form ([github/docs#20495](https://github.com/github/docs/issues/20495)), and
community reports describe dynamic multi-label jobs that queue forever
([#78674](https://github.com/orgs/community/discussions/78674),
[#49302](https://github.com/orgs/community/discussions/49302),
[#50172](https://github.com/orgs/community/discussions/50172)). Run a scratch
dispatch-only workflow against the label sets this design would use, plus one
deliberate set that no runner satisfies.
*Verifiable:* each matching run lands on the expected runner, and the no-match
run is detected rather than left queued. If matching misbehaves on these label
sets, stop here.

**Step 1 — land the table and resolver, unused.**
A checked-in capability→label table, a resolver script, and a test asserting
the table is total over the capability sets the vocabulary can express.
*Verifiable:* the resolver reproduces, for every macOS job on `main`, exactly
the label that job resolves to today. That is a pure-function test; it needs
no CI run.

**Step 2 — convert one non-required job.**
`build-ghosttykit.yml`: dispatch-only, post-merge, already outside required CI.
*Verifiable:* `runner_name` on the converted run equals `runner_name` on the
previous run. A difference here is the whole signal.

**Step 3 — label owned capacity.**
Register enrolled machines (the owned glaeda minis) with the capability vocabulary
*in addition to* their existing labels. Nothing routes to them yet.
*Verifiable:* the runners API lists each machine's label set, and every set is
in the resolver's image. A machine advertising a capability it lacks is caught
here, by inspection, before any job depends on it.

**Step 4 — convert required lanes, one workflow per PR, `main`-only first.**
Keep the existing variable expression as the resolver's output for that lane,
so the emitted string is byte-identical and the change is provably inert.
*Verifiable:* `scripts/ci/ci_health_report.py` over a window before and after
shows an unchanged `runner_name` distribution and unchanged metered minutes.

**Step 5 — delete.**
Once no workflow names a vendor, delete the guard functions listed above, then
the repository variables. Deleting the guards first is deliberate: a guard
whose invariant is unrepresentable is dead weight, but a variable deleted
while something still reads it silently resolves to the fallback.

## Risks and open questions

**Runner groups are the security boundary; labels are not.** A self-hosted
runner declares its own labels at registration, so a label is a scheduling
hint that the machine asserts about itself. A workflow-restricted runner
group is administered in organization settings where a branch-modified
workflow copy cannot reach it. Group and labels compose correctly (both must
match), so capability labels can be added to a grouped job without weakening
it, but no capability label may ever become the thing that keeps an untrusted
job off owned hardware. This proposal does not change the
direct-physical-host boundary in `ci-runners.md`.

**A mislabelled machine fails two ways, one of them silent.** A machine
labelled `macos-26` that actually runs macOS 15 fails loudly and quickly:
`scripts/select-ci-xcode.sh` exits non-zero on a pinned Xcode path that is not
installed. A machine labelled `gui` with no Aqua session fails later, inside
XCUITest, and looks like a product bug. The dangerous case is the *missing*
label: a capability set no runner satisfies produces a job that queues
indefinitely with no error, which `ci-runners.md`'s own cost section warns is
routinely misread — GitHub sets a queued job's `started_at` to when it
entered the queue, so an unroutable job reports as a long expensive job that
burned nothing. A preflight assertion (the job verifies at runtime that it has
what it asked for) would convert late failures to early ones, but does nothing
for the never-scheduled case. **Unresolved:** what detects "no runner can
satisfy this capability set" and how fast.

**Heterogeneous performance behind one label is a real dependency, not a
theoretical one.** A MacBook and a Mac Ultra both advertising `macos-26` means
build times vary by a large multiple. Something already depends on that not
happening: `ci-runners.md`'s own background-lane criteria exclude any job that
"is a timing benchmark or incremental-build probe, whose numbers only compare
on the same hardware", and `tests-build-and-lag` is exactly such a job.
`docs/ci/mac-fleet.md` carries service-time percentiles per lane that assume a
homogeneous pool. Under capability routing those measurements stop meaning
what they mean now. The options are a `perf-class` label (which reintroduces a
machine property into the job, and is hard to define honestly) or keeping
timing-sensitive jobs pinned to specific capacity. **Unresolved, and it should
be resolved before `tests-build-and-lag` converts** — it is the last lane to
move, not the first.

**`CMUX_PRODUCT_RUNNER` needs replacing, not porting.** It is a field of the
compiled-product contract (`scripts/ci/reuse_app_host_products.py`) and a
required product-identity key for E2E
(`scripts/ci/product_input_identity.py`), and today it holds a pool name
resolved at expression time. A capability set is a *weaker* identity than a
pool name — two machines that fit the same capability set can have different
workspace layouts, which is the exact failure
`check_macos_runner_identity_env_tracks_routing` was written to prevent.

The encouraging part: the same contract already stamps runtime-derived
identity — `xcodebuild -version`, the SDK build version, `sw_vers
-buildVersion`, `platform.machine()`, and the `ImageOS`/`ImageVersion`
environment variables. Those discriminate a machine image more precisely than
any pool name, and they are collected on the machine rather than asserted by
the workflow. The proposal is to drop `CMUX_PRODUCT_RUNNER` in favour of them.
Two things block that: `ImageOS` and `ImageVersion` are set by GitHub-hosted
and provider images, and it is **not established** what owned machines set
them to, if anything; and changing a product-identity key invalidates every
cached product once, which needs scheduling. This deserves its own design
document.

**Not addressed here:** Linux routing beyond the two variables named above,
the `macos-15-intel` and `macos-14` compatibility legs (which need hosted
images no provider offers, so they may simply stay pinned and exempt), and
what the translation table's own review process is — it is operator policy
living in the repository, which is a shape cmux does not have elsewhere.
