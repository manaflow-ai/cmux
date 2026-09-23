# Derived, not declared

Five of today's CI incidents were the same bug. Something in the tree had to be
updated in lockstep with something else, a pull request that passed on its own
forgot, and main went red for everyone:

| Incident | The list | What happened |
| --- | --- | --- |
| #13535 | guard step ownership manifest | a new guard step plus a hand-kept copy of the step list; main red 88 minutes. #13642 derived ownership from `ci-guards.yml`'s own `if:` conditions |
| #13710, #13731, #13739 | `tests/test-execution.toml` | the registry went stale three times in one day. #13745 narrows the blast radius to the pull request that adds a test |
| #13738 + #13739 | `tests/test-execution.toml` | two pull requests each added the *same* entry. Both were green alone; the merge was conflict-free and invalid: `registered more than once` |
| #13727 | `macos / macOS status` | an unset `compile_admitted` was rejected instead of defaulting |
| #13717 | `vars.CI_PULL_REQUEST_SUITE`, `vars.CI_CACHE_BACKEND` | fork pull requests get no repository variables, so an empty value selected the full macOS suite and a cache that restored nothing |

The class is wider than those five. This is the inventory, and the three rules
that follow from it.

## The three rules

**1. Derive from the source of truth.** If a list can be computed from the thing
it must track, compute it. A manifest of guard steps is a copy of
`ci-guards.yml`; a set of "paths this guard reads" is a copy of what the guard's
`run:` executes. Two copies can disagree, and neither pull request that made
them disagree can see it. One copy cannot.

**2. Fail only the pull request that causes the drift.** When a list genuinely
cannot be derived, the check that enforces it must fail on the change that
introduces the mismatch, not on everyone afterwards. A registry that only
validates on `push: main` turns one author's omission into everybody's red
build. `#13745` is this rule applied to the test execution registry.

**3. Treat missing configuration as the cheap default, never the expensive
one.** An unset repository variable, an unset job output, an absent file: each
must select the smallest amount of work that is still correct. Fork pull
requests receive no repository variables at all, so "unset" is not a rare edge —
it is the normal state for every external contributor.

A corollary of rule 1 that the #13738/#13739 collision makes concrete: an
append-only file where two pull requests can add the same line merges cleanly
into an invalid file. Git cannot see a semantic conflict in a file where both
sides appended to different regions. Prefer a derived list; where the file must
stay hand-written, the validator must reject duplicates *and* the check must run
where the collision first appears, which is the merge queue, not `main`.

## Blast radius

`ci.yml` triggers on `pull_request`, `merge_group` and `workflow_dispatch` — not
on `push: main`. Everything reached through it fails on the offending pull
request and its merge-queue entry only. But because it runs on `merge_group`, a
drift that *reaches* main (merged while the router skipped the guard) then
blocks every subsequent queue entry.

`web-validation.yml`, `web-complexity-trusted.yml`, `testbox-broker-guard.yml`,
`ci-artifact-transport.yml` and `ci-cache-receipts.yml` do run on `push: main`.
Drift reached through those is red for everyone immediately.

"Fails open" in the table below means the drift causes *less* checking, not a
red build — the most expensive kind, because nothing reports it.

## Inventory

Ordered by blast radius times likelihood.

| # | Where | Duplicates | On drift | Who it fails | Derivable |
| --- | --- | --- | --- | --- | --- |
| 1 | `scripts/ci/required_status_checks.py` `REQUIRED_CHECKS` | the `required_status_checks` rule of the `main` ruleset, which is not in the tree | an admin adds a required check, nobody edits the tuple, the guard passes and every pull request waits on a context nothing produces | **everyone**, with no red check anywhere | Not derivable, but **reconcilable** — implemented, see below |
| 2 | `.github/workflows/merge-group-fail-fast.yml:17` | the `name:` of `merge-group-policy-checks.yml` | renaming it silently stops fail-fast; the workflow just never triggers | **everyone** (queue latency), detected by nobody | Partially. `workflow_run` requires the literal display name, but a test can pin it against the producer's `name:`; #13793 proposes identifying the producer by file instead |
| 3 | `tests/test-execution.toml` | every `tests/test_*.py` on disk | an unregistered test fails validation; a duplicated entry is `registered more than once` | everyone, until #13745 lands | Partially. Discovery is derivable; the lane assignment is a judgment |
| 4 | `.github/workflows/ci-artifact-transport.yml:4-40` | its own `pull_request.paths` list, written again under `push.paths` | previously drifted: nine files were guarded on pull requests and not on main | **everyone**, silently — main can regress with no signal | Yes — **implemented** in #13789; parity guard and explicit exemptions |
| 5 | `scripts/ci/detect_linux_guard_changes.py` `WORKFLOW_TEST_INPUTS`, `CLI_INPUTS`, `HISTORY_INPUTS` | what each guard job's steps run in `ci-guards.yml` | a renamed step leaves the path routed to a guard that no longer reads it; also stale the expensive way (31 of 137 paths named) | offending PR, then silent under-coverage | Yes — **implemented**, see below |
| 6 | `.github/workflows/ci.yml:341-345,218` bash `case` lists | `workflow_guard_groups.ROUTING_POLICY_PATHS` (a third and fourth copy) | a routing-policy file missing from one copy takes the wrong fast path | offending PR | Yes. The router already owns the set |
| 7 | `.github/workflows/ci.yml:434-437` hard-coded `linux_guard_test_groups=[...]` JSON | `workflow_guard_groups.GROUPS` | a new group is added to `GROUPS` and a policy-only PR still routes the old eleven | offending PR (a structure test catches the reverse direction) | Yes |
| 8 | `.github/workflows/ci.yml:458` `release_only_jobs` | job **ids** in `ci-macos.yml` (not display names — the surrounding code partitions on `\njobs:\n` and splits on the YAML keys) | renaming a release job id stops it matching, so the narrow route never fires | fails open (extra work) | Yes |
| 9 | `vars.CI_CACHE_BACKEND` (18 sites), `CI_CACHE_R2_PUBLIC_URL`, `LINUX_RUNNER` in `runs-on:` | the value the repository sets, and each other | an empty value restores from no cache and rebuilds cold, or leaves `runs-on:` unschedulable | fork PRs and dispatches; cost, not red | Yes — **implemented**, see below |
| 10 | `scripts/ci/cmux_unit_test_shard.py:40-103` `FOCUSED_GATE_SELECTORS` | `-only-testing:` lines in `ci-macos.yml`, plus `cmuxTests/**` declarations and shard env values — one constant in four places | a new `-only-testing:` line without the edit runs the suite twice per PR | offending PR | Yes. The test already parses the selectors out of `ci-macos.yml` |
| 11 | `scripts/ci/workflow_guard_groups.py:94` `DETERMINISM_SUFFIXES` vs `scripts/check-test-determinism.py:74` `SCANNED_SUFFIXES` | each other, verbatim | adding `.mts` to the scanner but not the router means findings in that extension never route `quality-determinism` | fails open | Yes. Import the scanner's tuple |
| 12 | `scripts/ci/detect_ci_change_areas.py:298-315` `is_cli_change()` | six specific `tests/test_cli_*.py` filenames | a new CLI regression test does not route the CLI lane | fails open, silent | Partially. A `tests/test_cli_*` glob covers most of it |
| 13 | `.github/test-determinism-allowlist.txt` | live test files | **duplicate-prone**: two PRs appending the same `path<TAB>rule` merge cleanly; nothing rejects duplicates. Also silently stale when the test is renamed | offending PR once detected; never, for a stale line | No, but staleness is detectable |
| 14 | `.github/swift-warning-budget.tsv` (114 rows) | actual compiler output | two PRs adding rows for the same path with different messages merge into a valid-looking, wrong budget | next merge-queue entry, i.e. **everyone** | No. It *is* the baseline |
| 15 | `web/oxlint-complexity-baseline.txt` | grandfathered findings; read from the trusted base checkout | same append/duplicate hazard | `push: main`, so **everyone** | No |
| 16 | `tests/test_ci_{release,app_host,quality,source_lint}_guard_structure.py` (~66 step-name→group pairs) | `- name:` + `if: matrix.group ==` pairs in `ci-guards.yml` | renaming any guard step fails these | offending PR | Partially. `workflow_guard_groups.guard_steps()` already parses the same pairs |
| 17 | `.github/actionlint.yaml:8-29` runner labels, `tests/test_ci_self_hosted_guard.sh:1132` `allowed=`, `docs/ci-runners.md:30` | the literal labels used in workflows and the `*_RUNNER` variable values — three copies | an unlisted literal label fails actionlint on every PR *and* every push to main | **everyone** (`testbox-broker-guard.yml` has no path filter) | Partially |
| 18 | `.github/workflows/ci.yml:136,196,290,477` `/tmp/cmux-ci-changed-files.txt` | nothing — but a fixed path is shared state | two runs or two local test copies collide; a stale file from an earlier run is read as this run's diff | flaky, locally and in theory on a reused runner | Yes. `$RUNNER_TEMP`/`mktemp` |
| 19 | `.github/review-bot-rules/README.md:11-38` | the 29 `.md` files in that directory | **already drifted**: `test-determinism.md` exists and is not indexed. Nothing validates it | nobody, ever | Yes, trivially. Glob the directory |
| 20 | `docs/ci-runners.md` | the 43 `vars.*` names used in workflows | 16 undocumented, including `LINUX_RUNNER` and all nine `MACOS_RUNNER_*`, while `actionlint.yaml` and the self-hosted guard both point operators here as the source of truth | nobody | Yes. Grep `vars\.` across workflows |
| 21 | `scripts/ci/run_python_test_lane.py:18-19` vs `validate_test_execution_registry.py:27-28` | `{"legacy","manual"}` and `{"cmux-cli","fish"}`, verbatim in both | the registry validates a lane the runner then rejects at execution time | offending PR, late | Yes. Both already import `test_execution_registry.py` |
| 22 | `tests/test_ci_change_areas.py:25-54` `GUARD_ROUTE_JOBS` vs `tests/test_ci_linux_guard_routing.py:34-40` `JOBS` | each other, and the job ids in three workflows | a new `ci-web.yml` job is never exercised by the aggregation test | fails open | Yes. Both files already parse the workflows |
| 23 | `tests/test_ci_app_host_pipe_capture.py:12-15` `WORKFLOWS` vs `tests/test_ci_app_host_home_isolation.py:14-21` | two different hand-picked workflow subsets for overlapping invariants | **already drifted**: the app-host jobs moved to `ci-macos.yml` and the list did not follow, so the guard scanned 1 step and 31 went unchecked | fails open, silently | Yes — **implemented**, see below |
| 24 | `scripts/ci/select_package_tests.py:27-45` `GLOBAL_INPUTS`, `:49-71` `UNRELATED_PREFIXES` | 17 exact paths and the repo's top-level directories | a missing `GLOBAL_INPUTS` entry fails open; a new top-level directory fails closed | mixed | Partially. `UNRELATED_PREFIXES` is `ls` of the root minus `Packages/` |
| 25 | `scripts/ci/web_subareas.py:56-184` + `emit()` + `ci-web.yml:25-31` `outputs:` | the field names are written out six times | adding a web subarea needs six edits; missing one means the job never runs | fails open | Yes for the `emit`/`outputs` half (`dataclasses.fields`) |
| 26 | `scripts/ghosttykit-checksums.txt` | the `ghostty` submodule pointer | a bump without a row fails the GhosttyKit download once merged | everyone | Partially. The checksum must be measured; "does a row exist for the current SHA" is derivable |
| 27 | `scripts/ci/cmux-unit-test-timings.json` (2387 lines) | a real run's timings | shards slowly unbalance and time out; missing suites fall back to method counts | nobody, then everyone | Yes. `scripts/ci/generate_test_timings.py` already exists |
| 28 | `scripts/retired-feature-flags.txt`, `scripts/ci/app-host-known-failures.json`, `scripts/lint-*-baseline.txt` | deleted code, known failures, grandfathered findings | append-only and duplicate-prone in the #13738 way | varies | No. They record history |
| 29 | `tests/test_ci_reusable_workflow_permissions.py:471-488` `MANUAL_REF_TARGETS` | `resolve-dispatch-ref.yml` consumers | a new consumer is not checked | fails open | Partially. Consumers are greppable |
| 30 | `scripts/ci/check_reusable_workflow_permissions.py:44-61` `SCOPES` | GitHub's documented permission scopes | a scope GitHub adds is unrecognized | offending PR or silent under-checking | No. External source of truth |

Two more that are the same shape but sit outside `.github/`, `scripts/ci/` and
`tests/`, noted so they are not rediscovered: `scripts/ci/workflow_guard_groups.py:80-92`
`ROUTING_POLICY_PATHS` omits `tests/test_ci_source_lint_guard_structure.py`
though it is the same class of file as the four it does list (a `tests/test_ci_*guard_structure.py`
glob fixes it); and `.github/workflows/ci-cache-receipts.yml:4-27` writes ten
paths twice and is currently in sync — the not-yet-drifted twin of row 4.

## Implemented

- **Row 5 — derive the Linux guard route inputs** (#13775). Each guard job in
  `ci-guards.yml` names the route that selects it and the paths its steps run.
  `route_direct_paths()` reads both, so adding a guard step needs no second
  edit and deleting one cannot leave a route behind.
- **Row 9 — cheap defaults for repository variables** (#13777). 21 bare
  `vars.` reads now carry the value the repository sets, and
  `tests/test_ci_repo_variable_defaults.py` scans the workflows rather than a
  list of known-good sites.
- **Row 23 — scan every workflow for app-host capture** (#13780). The
  pipe-capture guard named `ci.yml` and `test-e2e.yml`; the app-host jobs moved
  to `ci-macos.yml` and the list did not follow, so it checked one step and
  reported success while 31 went unscanned. It now asks the directory, and an
  empty result is an error.
- **Row 1 — reconcile the required checks against GitHub** (#13791). The entry
  above said this needed `administration: read`, which PR CI must not have.
  That is true of `branches/main/protection`, and not of the rulesets endpoint
  `repos/:owner/:repo/rules/branches/main`, which returns the same contexts to
  an ordinary read — on this public repository it answers with no token at all.
  `.github/workflows/required-checks-drift.yml` reconciles `REQUIRED_CHECKS`
  against that endpoint every six hours, and separately checks that each
  required context actually reported on recently merged pull request heads,
  which catches the other direction: a renamed job leaves a required name that
  nothing produces, and settings and tree still agree with each other. Every
  unreadable or unrecognised response is a failure, not a skip.

- **Row 4 (`ci-artifact-transport.yml` push/pull_request drift).** Implemented
  in #13789. The cost estimate here was wrong: syncing was measured at 11 of
  67 merges sampled on 2026-09-22 (~16%), not "nearly every push", and the expensive Worker
  half stays gated behind `steps.worker.outputs.run`. The `pull_request` list
  was the correct one — four of the seven test files the job runs appeared only
  there, including one that asserts on `ci-macos.yml`'s contents while a push
  editing that file triggered nothing. `tests/test_ci_workflow_path_filter_parity.py`
  now asserts the two lists agree across every workflow, with exemptions
  written down: `web-complexity.yml` diverges deliberately, because syncing it
  would let a PR editing that workflow self-queue a job running
  contributor-controlled install scripts.

## Not implemented, and what it would take

- **Row 2 (workflow display names).** The trigger names
  `merge-group-policy-checks.yml` by its display name; its later CI lookup
  already uses the stable workflow file path. The producer's checked-in
  `name:` can guard the trigger against drift. #13793 proposes removing the
  display-name dependency by checking the triggering workflow's file identity.
- **Row 1's remaining gap.** The reconciliation reads rulesets. Classic branch
  protection, if anyone ever configures it on top, contributes required
  contexts through an endpoint that answers 404 to a non-admin token whether
  or not it is configured, so those contexts would stay invisible. Repository
  rulesets are the only mechanism in use today (`repos/:owner/:repo/rulesets`
  lists four, and `branches/main/protection` is 404).
- **Rows 6, 7 and 8 (ci.yml's bash path lists and group JSON).** The correct
  shape is for the step to call the router instead of re-deciding in bash, but
  the step deliberately runs *before* trusting candidate Python — that is the
  point of the trusted-base dance above it. Deriving needs the trusted-base
  copy to supply the lists, which is a larger change than the other slices and
  wants its own review.
- **Row 18 (`/tmp/cmux-ci-changed-files.txt`).** One step writes the file and
  the next reads it, so both must move to `$RUNNER_TEMP` together — and
  `tests/test_ci_change_areas.py` extracts and runs the writing step. That file
  is owned by another change in flight; the fix is a two-line path swap plus
  `RUNNER_TEMP` in both tests' environments, once the two land.
- **Row 21 (`run_python_test_lane.py` / registry constants).**
  `validate_test_execution_registry.py` is owned by #13745. Moving both sets to
  `test_execution_registry.py`, which each file already imports, is a
  three-line change afterwards.
- **Rows 13, 14, 15, 28 (baselines and append-only registries).** These record
  history and cannot be derived. What they can have is a duplicate check in
  their own validator and an assertion that every referenced path still exists,
  so a stale suppression is reported instead of silently suppressing nothing.
- **Row 19 (review-bot-rules index).** A five-line test globbing the directory
  and comparing against the README list; deferred only because nothing consumes
  the index, so the drift costs nobody anything today.

Part of #13095.
