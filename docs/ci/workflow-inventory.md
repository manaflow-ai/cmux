# GitHub Actions workflow inventory

Snapshot of the 89 files in `.github/workflows/` on `main` at `ea17450142`, with run data for 2026-09-15 through 2026-09-22 13:30 UTC.

How the numbers were collected:

- **Runs** and the ok/fail/skip/cancel split come from `total_count` on `actions/workflows/<id>/runs?created=>=2026-09-15&status=<conclusion>`. `action_required` runs are counted in the total but not split out.
- **Runner-min** is an estimate: the average summed job duration across up to 20 evenly spaced non-skipped runs, multiplied by the number of non-skipped runs. Queue time is excluded. It counts runner minutes, not billed minutes (Blacksmith and GitHub-hosted runners bill at different rates).
- **Last ok** is the newest successful run. For busy workflows it is taken from the newest 1,000 runs.
- **Owner** is the author of the pull request that added the file. **Last touch** is `git log -1` on the file.
- **Consumers** counts callers through `workflow_call`, required checks, and other files that mention the workflow file name.

Total estimated runner time for the week: **3,431 hours**. `ci.yml` accounts for 48% of it.

The required checks on `main` (ruleset "main: block force-push or delete") are `CLA Assistant`, `CLA policy guard`, `ci-status`, `Web complexity` and `web-validation`. Workflows that feed them are marked REQUIRED and must not be removed.

## Flags

**a. Experimental or canary workflows that have never succeeded, or have no consumer**

- `persistent-macos-compile.yml` (teamleaderleo, #13383, added 09-21): a pilot producer that never ran. Removed with its router when the pilot was retired; owned minis will serve pull requests through the pool picker (`scripts/ci/pr_runner_pool.py` `POOLS`) instead.
- `ci-artifact-canary.yml` (teamleaderleo, #13268, added 09-20): an R2 transport canary. Its one dispatch failed in the measurement step. It is the pre-rollout check for `vars.CI_ARTIFACT_R2_URL`, which is not set.
- Workflows that exist only on branches still appear in the Actions list: 15 `incremental-*` / `incgen-*` / `xcode-incremental-*` canaries (09-21 experiment branches, mostly failed), 7 `zz-13474-*` workflows, `verify-13450`, `verify-issue-13489`, `transport-v3`, `test-remote-connections` (29 of 36 runs cancelled) and `zz-mobile-terminal-package-boundary-benchmark`. None of them is on `main`. The entries disappear once their branches are deleted.

**b. Nearly all runs skipped (the trigger is broader than the job condition)**

- `persistent-macos-router.yml` (teamleaderleo): 6,887 of 6,927 runs skipped and none succeeded. It created one run for every CI run and exited on the unset pilot variable. Removed with the pilot.
- `claude.yml` (lawrencecchen): 9,780 of 10,239 skipped and 7 successful. It fires on every issue comment, review and review comment, and the job filters for an `@claude` mention.
- `indexnow.yml` (lawrencecchen): 804 of 1,199 skipped. It fires on every `deployment_status`, and the job keeps only production successes.
- `merge-group-fail-fast.yml` (teamleaderleo): 11,324 skipped runs before #13476 fixed its trigger at 09-22 00:04 UTC, and none since.
- `cla.yml`: 3,905 skipped runs from `issue_comment`. It is required, so leave it alone.

**c. Duplicates and overlaps**

- `ios-testflight.yml` (every 20 minutes, CMUX INTERNAL) and `ios-appstore-upload.yml` (hourly, cmux.app) both run scheduled TestFlight uploads. About half of each one's runs fail (251 of 507 and 79 of 161). Together they use about 250 runner-hours a week.
- `testbox-broker-guard.yml` runs on every PR and every push to main (6,275 runs) because its header says "The main CI suite is dispatch-only right now". That is no longer true, so the guard could move into `ci-guards.yml`.
- `web-complexity-trusted.yml` and `cla-policy-guard.yml` together ran about 27,000 times. That is roughly 3x the PR events, because `pull_request_target` also fires on `edited`. Do not drop `edited` blindly: it also carries base-branch changes.
- `web-complexity.yml` and `web-complexity-trusted.yml` are an intentional pair: an untrusted diagnostic plus the trusted required check. Not a duplicate.
- `ci-status-fallback.yml` has been a dispatch-only `echo` since 09-18. The 3,697 runs this week came from before that change.
- `test-macos-suite.yml` (formerly `test-depot.yml`) is named "Run macOS test suite". It runs a whole test target cold; focused runs belong on `test-e2e.yml` through `scripts/run-e2e.sh`.
- `test-macos-unit-suite.yml` is the read-only reusable full-unit target used by the pull-request macOS 15 lane; manual focused dispatch remains in `test-macos-suite.yml`.

**Other problems found along the way:** `release.yml` has not succeeded since 08-03 (both runs this week failed), and `iroh-release-gate.yml` not since 08-14. `tmux-corpus.yml` is `disabled_manually`. `ci-macos-compat.yml` fails actionlint on the unknown label `macos-15-intel`, and `test-ios.yml:21` fails actionlint with an empty string.

## Table

Sorted by estimated runner minutes. Trigger abbreviations: pr = pull_request, pr_target = pull_request_target, call = workflow_call, wf_run = workflow_run.

| Workflow | Triggers | Runner | Runs 7d | ok / fail / skip / cancel | Runner-min | Last ok | Owner (PR) | Last touch | Consumers | Flag |
|---|---|---|--:|---|--:|---|---|---|---|---|
| `ci.yml` | pr merge_group dispatch | blacksmith/warp/macos | 4,571 | 788 / 1,392 / 0 / 2,228 | 99,698 | 2026-09-22 | lawrencecchen (direct push)  | Leo 2026-09-22 | REQUIRED: ci-status; 8 wf refs; 26 docs/tests |  |
| `web-complexity-trusted.yml` | pr_target merge_group push (paths) | gh-ubuntu | 13,693 | 5,490 / 179 / 0 / 8,023 | 18,747 | 2026-09-22 | lawrencecchen #11944 | Leo 2026-09-19 | REQUIRED: Web complexity; 2 wf refs; 6 docs/tests |  |
| `nightly.yml` | push schedule dispatch | blacksmith/warp/macos | 489 | 150 / 39 / 0 / 300 | 14,637 | 2026-09-22 | lawrencecchen (direct push)  | Lawrence Chen 2026-09-21 | 7 wf refs; 23 docs/tests |  |
| `ios-testflight.yml` | schedule dispatch | blacksmith/warp/macos | 507 | 231 / 251 / 0 / 25 | 13,771 | 2026-09-22 | lawrencecchen #5448 | Abdulaziz Albahar 2026-09-21 | 11 docs/tests | **c** overlaps ios-appstore-upload; 50% fail |
| `cli-pipe-regressions.yml` | call dispatch | warp/macos | 2,432 | 1,500 / 228 / 0 / 588 | 7,710 | 2026-09-22 | austinywang #12503 | Leo 2026-09-22 | REQUIRED: ci-status (reusable); called by ci; 3 docs/tests | removed: its CLI tests run in compile admission's CLI smoke step |
| `cmux-tui-sdks.yml` | push pr dispatch (paths) | blacksmith | 453 | 235 / 82 / 0 / 132 | 7,271 | 2026-09-22 | lawrencecchen #9215 | Lawrence Chen 2026-09-16 | 1 docs/tests |  |
| `test-e2e.yml` | dispatch | blacksmith/warp/macos | 959 | 270 / 531 / 0 / 158 | 6,730 | 2026-09-22 | lawrencecchen #778 | Leo 2026-09-21 | 6 docs/tests | 55% fail |
| `cmux-tui.yml` | dispatch | blacksmith/macos/gh-ubuntu | 114 | 37 / 47 / 0 / 30 | 5,696 | 2026-09-22 | lawrencecchen #7710 | Austin Wang 2026-09-12 | 1 wf refs; 5 docs/tests |  |
| `test-macos-suite.yml` | call dispatch | blacksmith/warp/macos | 348 | 93 / 213 / 0 / 42 | 5,335 | 2026-09-22 | lawrencecchen #710 | Leo 2026-09-21 | 2 docs/tests | renamed from test-depot.yml; 61% fail, mostly single-test dispatches that belong on run-e2e.sh |
| `reload-build.yml` | dispatch | blacksmith/macos | 276 | 107 / 71 / 0 / 98 | 4,689 | 2026-09-22 | lawrencecchen #6354 | Leo 2026-09-21 | 1 wf refs; 3 docs/tests |  |
| `cla-policy-guard.yml` | pr_target | gh-ubuntu | 13,584 | 12,311 / 1,272 / 0 / 1 | 2,445 | 2026-09-22 | lawrence703 #11387 | Lawrence Chen 2026-09-02 | REQUIRED: CLA policy guard; 2 docs/tests |  |
| `remote-daemon.yml` | pr push dispatch (paths) | blacksmith/warp/macos | 189 | 116 / 7 / 0 / 65 | 2,178 | 2026-09-22 | austinywang #12720 | austinpower1258 2026-09-15 | none |  |
| `test-ios.yml` | dispatch | blacksmith/warp/macos | 163 | 14 / 124 / 0 / 25 | 2,086 | 2026-09-22 | lawrencecchen #5079 | Leo 2026-09-21 | 3 docs/tests | 76% fail |
| `testbox-broker-guard.yml` | pr push | blacksmith | 6,275 | 5,549 / 92 / 0 / 430 | 1,877 | 2026-09-22 | lawrencecchen #10305 | Leo 2026-09-21 | 1 docs/tests | **c** always-on guard; header says CI is dispatch-only (stale) |
| `web-complexity.yml` | pr push (paths) | blacksmith | 5,889 | 4,753 / 135 / 0 / 798 | 1,578 | 2026-09-22 | lawrencecchen #11944 | Leo 2026-09-22 | 2 wf refs; 4 docs/tests |  |
| `cmux-tui-artifacts.yml` | push dispatch (paths) | blacksmith/warp/macos | 41 | 30 / 4 / 0 / 7 | 1,555 | 2026-09-22 | lawrencecchen #7710 | Austin Wang 2026-09-19 | 3 wf refs; 7 docs/tests |  |
| `ios-appstore-upload.yml` | schedule dispatch | blacksmith/warp/macos | 161 | 76 / 79 / 1 / 5 | 1,248 | 2026-09-22 | lawrencecchen #6697 | Abdulaziz Albahar 2026-09-21 | 1 docs/tests | **c** overlaps ios-testflight; 49% fail |
| `cla.yml` | issue_comment pr_target | blacksmith | 10,784 | 6,109 / 669 / 3,905 / 101 | 1,066 | 2026-09-22 | lawrencecchen #11244 | Lawrence Chen 2026-09-02 | REQUIRED: CLA Assistant; 1 wf refs; 1 docs/tests | b 3,905 skipped (issue_comment); required, keep |
| `cmux-tui-testbox-warmup.yml` | dispatch | blacksmith | 50 | 7 / 0 / 0 / 42 | 1,057 | 2026-09-21 | lawrencecchen #10303 | Lawrence Chen 2026-08-17 | 1 wf refs; 3 docs/tests |  |
| `terminal-hang-diagnostics.yml` | pr dispatch (paths) | blacksmith/warp/macos | 291 | 212 / 6 / 0 / 71 | 895 | 2026-09-22 | austinywang #12725 | austinpower1258 2026-09-20 | none |  |
| `web-validation.yml` | pr merge_group push dispatch | blacksmith | 6,043 | 4,523 / 330 / 0 / 994 | 726 | 2026-09-22 | lawrencecchen #12711 | Leo 2026-09-21 | REQUIRED: web-validation; 3 docs/tests |  |
| `docs-channels.yml` | push (paths) | blacksmith | 72 | 72 / 0 / 0 / 0 | 716 | 2026-09-22 | lawrencecchen #7871 | Lawrence Chen 2026-07-15 | none |  |
| `iroh-v2.yml` | pr push dispatch (paths) | blacksmith/warp/macos | 353 | 286 / 15 / 0 / 52 | 597 | 2026-09-22 | azooz2003-bit #12326 | austinpower1258 2026-09-20 | 2 docs/tests |  |
| `relay-tls.yml` | pr dispatch (paths) | blacksmith/warp/macos | 156 | 127 / 10 / 0 / 19 | 531 | 2026-09-22 | austinywang #12723 | Leo 2026-09-19 | 1 docs/tests |  |
| `cloud-machine-tests.yml` | pr dispatch (paths) | blacksmith/warp/macos | 73 | 50 / 3 / 0 / 20 | 383 | 2026-09-22 | austinywang #12919 | Leo 2026-09-21 | 1 docs/tests |  |
| `release.yml` | push dispatch | blacksmith/warp/macos | 2 | 0 / 2 / 0 / 0 | 310 | 2026-08-03 | lawrencecchen (direct push)  | Leo 2026-09-20 | 7 wf refs; 19 docs/tests | 2 runs, both failed; last success 08-03 |
| `auth-refresh-tests.yml` | pr dispatch (paths) | blacksmith/warp/macos | 137 | 95 / 9 / 0 / 33 | 305 | 2026-09-22 | austinywang #12628 | Austin Wang 2026-09-20 | none |  |
| `ci-artifact-transport.yml` | pr push (paths) | blacksmith | 692 | 470 / 22 / 0 / 200 | 297 | 2026-09-22 | teamleaderleo #13268 | Leo 2026-09-21 | 1 docs/tests |  |
| `cmux-tui-spec.yml` | push pr dispatch (paths) | blacksmith | 423 | 380 / 28 / 0 / 11 | 252 | 2026-09-22 | lawrencecchen #9215 | Lawrence Chen 2026-09-01 | 1 wf refs; 1 docs/tests |  |
| `ci-status-fallback.yml` | dispatch | blacksmith | 3,697 | 3,537 / 3 / 0 / 0 | 230 | 2026-09-20 | azooz2003-bit #11342 | Lawrence Chen 2026-09-18 | 1 docs/tests | **dead**: dispatch-only echo since 09-18 |
| `ci-cache-receipts.yml` | pr push (paths) | blacksmith | 718 | 681 / 37 / 0 / 0 | 214 | 2026-09-22 | teamleaderleo #13272 | Leo 2026-09-21 | 1 docs/tests |  |
| `localization-catalog.yml` | pr push dispatch (paths) | blacksmith | 647 | 589 / 28 / 0 / 0 | 144 | 2026-09-22 | lawrencecchen #12906 | Lawrence Chen 2026-09-17 | none |  |
| `cmux-tui-release.yml` | dispatch push | blacksmith/warp/macos/gh-ubuntu | 4 | 3 / 0 / 0 / 1 | 128 | 2026-09-17 | lawrencecchen #7710 | Lawrence Chen 2026-09-16 | 4 wf refs; 2 docs/tests |  |
| `indexnow.yml` | deployment_status dispatch | blacksmith | 1,199 | 307 / 88 / 804 / 0 | 97 | 2026-09-22 | lawrencecchen #8339 | Lawrence Chen 2026-09-17 | 1 wf refs; 1 docs/tests | **b** 804/1,199 skipped (every deployment_status) |
| `cloud-vm-image-contract.yml` | pr push dispatch (paths) | blacksmith | 199 | 137 / 62 / 0 / 0 | 93 | 2026-09-22 | lawrencecchen #11984 | Austin Wang 2026-09-10 | none |  |
| `cloud-command-deadlines.yml` | pr dispatch (paths) | blacksmith/warp/macos | 64 | 46 / 13 / 0 / 5 | 92 | 2026-09-21 | austinywang #12631 | Austin Wang 2026-09-19 | none |  |
| `cloud-vm-image-reachability.yml` | pr push schedule dispatch (paths) | blacksmith | 187 | 183 / 4 / 0 / 0 | 82 | 2026-09-22 | lawrencecchen #12132 | Lawrence Chen 2026-09-17 | 1 docs/tests |  |
| `build-ghosttykit.yml` | dispatch | blacksmith/warp/macos | 11 | 9 / 1 / 0 / 1 | 72 | 2026-09-20 | lawrencecchen #447 | Abdulaziz Albahar 2026-09-01 | 3 docs/tests |  |
| `ci-stale-run-janitor.yml` | schedule dispatch | gh-ubuntu | 83 | 81 / 2 / 0 / 0 | 67 | 2026-09-22 | teamleaderleo #13143 | Leo Li 2026-09-20 | 2 docs/tests |  |
| `iroh-release-gate.yml` | dispatch | blacksmith/warp/macos | 2 | 0 / 2 / 0 / 0 | 60 | 2026-08-14 | azooz2003-bit #8484 | Leo 2026-09-21 | 1 docs/tests | 2 runs, both failed; last success 08-14 |
| `r2-upload-tests.yml` | pr dispatch (paths) | blacksmith | 154 | 153 / 1 / 0 / 0 | 42 | 2026-09-22 | austinywang #12281 | Lawrence Chen 2026-09-17 | none |  |
| `ios-screenshots.yml` | call dispatch | blacksmith/macos | 3 | 1 / 2 / 0 / 0 | 41 | 2026-09-17 | lawrencecchen #6697 | Leo 2026-09-21 | called by release; 4 docs/tests |  |
| `cmux-skill-contract.yml` | pr push (paths) | blacksmith | 131 | 89 / 9 / 0 / 26 | 28 | 2026-09-22 | austinywang #11088 | Leo 2026-09-20 | none |  |
| `cloud-task-local-tests.yml` | pr dispatch (paths) | blacksmith/macos | 59 | 49 / 0 / 0 / 10 | 26 | 2026-09-22 | austinywang #13200 | Austin Wang 2026-09-20 | none |  |
| `cloud-vm-env-audit.yml` | schedule push dispatch (paths) | blacksmith | 31 | 31 / 0 / 0 / 0 | 11 | 2026-09-22 | lawrencecchen #10960 | Benjamin Swerdlow 2026-09-01 | none |  |
| `perf-activation.yml` | dispatch | blacksmith/macos | 1 | 1 / 0 / 0 / 0 | 10 | 2026-09-17 | lawrencecchen #3207 | Leo 2026-09-21 | 4 docs/tests |  |
| `tui-publish-npm.yml` | dispatch | blacksmith | 2 | 2 / 0 / 0 / 0 | 8 | 2026-09-17 | lawrencecchen #7651 | Lawrence Chen 2026-09-16 | 3 wf refs; 5 docs/tests |  |
| `cmux-tui-release-delivery.yml` | dispatch wf_run schedule | blacksmith | 28 | 28 / 0 / 0 / 0 | 7 | 2026-09-22 | lawrencecchen #12763 | Leo 2026-09-19 | 1 wf refs; 1 docs/tests |  |
| `plain-paste-worker.yml` | pr dispatch (paths) | warp/macos | 10 | 8 / 2 / 0 / 0 | 6 | 2026-09-20 | austinywang #13110 | Austin Wang 2026-09-19 | none |  |
| `tui-publish-pypi.yml` | dispatch | blacksmith | 2 | 2 / 0 / 0 / 0 | 6 | 2026-09-17 | lawrencecchen #7651 | Lawrence Chen 2026-09-02 | 2 wf refs; 4 docs/tests |  |
| `cmux-cloud-cli.yml` | pr push dispatch (paths) | blacksmith | 11 | 11 / 0 / 0 / 0 | 5 | 2026-09-21 | lawrencecchen #13100 | Lawrence Chen 2026-09-20 | none |  |
| `cloud-vm-migrate.yml` | dispatch | blacksmith | 6 | 4 / 2 / 0 / 0 | 4 | 2026-09-21 | lawrencecchen #3196 | Lawrence Chen 2026-09-16 | 2 docs/tests |  |
| `merge-group-policy-checks.yml` | merge_group | gh-ubuntu | 34 | 34 / 0 / 0 / 0 | 3 | 2026-09-20 | teamleaderleo #13113 | Leo 2026-09-19 | REQUIRED: CLA checks in merge queue; 2 docs/tests | dormant, merge queue off since 09-20; keep (required checks) |
| `ios-app-store.yml` | dispatch | blacksmith/macos | 1 | 0 / 1 / 0 / 0 | 3 | 2026-09-08 | azooz2003-bit #7644 | Abdulaziz Albahar 2026-09-18 | 1 docs/tests |  |
| `cmux-tui-release-cut.yml` | dispatch | blacksmith | 1 | 0 / 1 / 0 / 0 | 2 | 2026-08-26 | lawrencecchen #7710 | lawrencecchen 2026-08-25 | 1 wf refs; 2 docs/tests |  |
| `repair-nightly-appcast-content-types.yml` | pr dispatch (paths) | blacksmith | 3 | 3 / 0 / 0 / 0 | 2 | 2026-09-17 | austinywang #12281 | Austin Wang 2026-09-10 | none |  |
| `vercel-auth-health.yml` | dispatch schedule | blacksmith | 8 | 8 / 0 / 0 / 0 | 1 | 2026-09-22 | lawrencecchen #8347 | Lawrence Chen 2026-07-17 | 1 docs/tests |  |
| `ci-artifact-canary.yml` | dispatch | blacksmith | 1 | 0 / 1 / 0 / 0 | 1 | never | teamleaderleo #13268 | Leo Li 2026-09-20 | 1 wf refs; 1 docs/tests | **a** canary, 1 run, never succeeded |
| `indexnow-tests.yml` | pr dispatch (paths) | blacksmith | 3 | 3 / 0 / 0 / 0 | 1 | 2026-09-18 | lawrencecchen #12909 | Lawrence Chen 2026-09-17 | none |  |
| `triage-radar.yml` | schedule dispatch | gh-ubuntu | 2 | 2 / 0 / 0 / 0 | 0 | 2026-09-22 | teamleaderleo #13520 | Leo 2026-09-21 | 1 docs/tests |  |
| `update-homebrew.yml` | wf_run dispatch | blacksmith | 3 | 0 / 0 / 3 / 0 | 0 | 2026-08-03 | lawrencecchen (direct push)  | Lawrence Chen 2026-06-22 | 1 docs/tests |  |
| `ci-macos.yml` | call | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | teamleaderleo #13405 | Leo 2026-09-22 | REQUIRED: ci-status (reusable); called by ci-artifact-transport, ci-cache-receipts, ci; 27 docs/tests |  |
| `sdk-publish-java.yml` | dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-07-08 | lawrencecchen #7601 | Lawrence Chen 2026-08-03 | 1 wf refs; 1 docs/tests |  |
| `sdk-bootstrap-pypi.yml` | repo_dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | lawrencecchen #9376 | Lawrence Chen 2026-08-03 | 2 wf refs; 5 docs/tests |  |
| `presence.yml` | dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-09-10 | lawrencecchen #5792 | Abdulaziz Albahar 2026-07-29 | 3 docs/tests |  |
| `claude.yml` | issue_comment pr_review_comment issues pr_review | blacksmith | 10,239 | 7 / 40 / 9,780 / 0 | 0 | 2026-09-21 | lawrencecchen #965 | Lawrence Chen 2026-09-02 | none | **b** 9,780/10,239 skipped |
| `cmux-tui-nightly.yml` | dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | lawrencecchen #7710 | Lawrence Chen 2026-09-16 | 2 wf refs; 3 docs/tests | paused (dispatch-only), 0 runs |
| `tmux-corpus.yml` | dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-07-14 | lawrencecchen #4323 | Leo 2026-09-20 | 2 docs/tests | **dead**: disabled_manually, manual-only since 07-13 |
| `cmux-browser.yml` | pr push (paths) | gh-ubuntu | 0 | 0 / 0 / 0 / 0 | 0 | 2026-08-27 | lawrencecchen #8717 | Lawrence Chen 2026-07-23 | none |  |
| `sdk-publish-go.yml` | call dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-07-08 | lawrencecchen #7601 | Lawrence Chen 2026-08-03 | called by cmux-tui-sdks, sdk-release-cut; 1 docs/tests |  |
| `cloud-vm-smoke.yml` | dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-07-11 | lawrencecchen #3196 | Benjamin Swerdlow 2026-09-02 | none | stale: last success 07-11 |
| `relay-publish-npm.yml` | push | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-08-27 | lawrencecchen #10725 | lawrencecchen 2026-08-25 | 3 wf refs; 2 docs/tests |  |
| `ci-web.yml` | call | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | teamleaderleo #13382 | Leo 2026-09-21 | REQUIRED: ci-status (reusable); called by ci; 5 docs/tests |  |
| `sdk-bootstrap-npm.yml` | repo_dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | lawrencecchen #9376 | Lawrence Chen 2026-08-06 | 2 wf refs; 5 docs/tests |  |
| `sdk-bootstrap-crates.yml` | repo_dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-08-17 | lawrencecchen #9376 | Lawrence Chen 2026-08-05 | 1 wf refs; 2 docs/tests |  |
| `sdk-release-cut.yml` | repo_dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | lawrencecchen #9376 | Lawrence Chen 2026-08-03 | 2 wf refs; 4 docs/tests |  |
| `sdk-publish-python.yml` | call dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-07-28 | lawrencecchen #7601 | Lawrence Chen 2026-08-03 | called by cmux-tui-sdks, sdk-release-cut; 1 docs/tests |  |
| `persistent-macos-compile.yml` | dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | teamleaderleo #13383 | Leo 2026-09-21 | 5 docs/tests | **a** pilot producer, never ran; removed |
| `ci-macos-compat.yml` | dispatch | dynamic:${{ matrix.o | 0 | 0 / 0 / 0 / 0 | 0 | 2026-08-13 | lawrencecchen #769 | Leo 2026-09-20 | 1 docs/tests | stale: last success 08-13; actionlint label error |
| `persistent-macos-router.yml` | wf_run | blacksmith | 6,927 | 0 / 0 / 6,887 / 39 | 0 | never | teamleaderleo #13383 | Leo 2026-09-21 | 1 wf refs; 4 docs/tests | **b** 6,887/6,927 skipped, 0 success (pilot var unset); removed |
| `ios-streamed-validate.yml` | dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-07-04 | lawrencecchen #6697 | Leo 2026-09-19 | none | stale: last success 07-04 |
| `ci-guards.yml` | call | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | teamleaderleo #13378 | Leo 2026-09-21 | REQUIRED: ci-status (reusable); called by ci; 15 docs/tests |  |
| `docs-deploy-reusable.yml` | call | dynamic:${{ vars.LIN | 0 | 0 / 0 / 0 / 0 | 0 | never | lawrencecchen #7871 | Lawrence Chen 2026-07-17 | called by docs-channels; 1 docs/tests |  |
| `iroh-relay-minter.yml` | dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-07-15 | azooz2003-bit #7908 | Lawrence Chen 2026-08-25 | none |  |
| `sdk-publish-crates.yml` | call dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | lawrencecchen #7601 | Lawrence Chen 2026-08-03 | called by cmux-tui-sdks, sdk-release-cut; 1 docs/tests |  |
| `merge-group-fail-fast.yml` | wf_run | gh-ubuntu | 11,427 | 23 / 2 / 11,324 / 78 | 0 | 2026-09-20 | teamleaderleo #13117 | Leo 2026-09-21 | 1 docs/tests | b (fixed by #13476); dormant, merge queue off since 09-20 |
| `cmux-tui-build-package.yml` | call | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | lawrencecchen #7710 | Lawrence Chen 2026-09-16 | called by cmux-tui-artifacts, cmux-tui-nightly, cmux-tui-release; 8 docs/tests |  |
| `resolve-dispatch-ref.yml` | call | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | never | teamleaderleo #13616 | Leo 2026-09-21 | called by cloud-machine-tests, ios-screenshots, iroh-release-gate; 2 docs/tests |  |
| `sdk-publish-npm.yml` | call dispatch | blacksmith | 0 | 0 / 0 / 0 / 0 | 0 | 2026-08-27 | lawrencecchen #7601 | Lawrence Chen 2026-08-03 | called by cmux-tui-sdks, sdk-release-cut; 1 docs/tests |  |
