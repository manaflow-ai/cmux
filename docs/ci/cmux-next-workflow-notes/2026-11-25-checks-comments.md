# cmux-next.yml checks: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `checks` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `JOB_TIMEOUT_MINUTES: 15`

The job's own cap (the same expression as its timeout-minutes; tests/test_run_checks_concurrently.py).

## 2

Stood above: `AFFECTED_BASE: ${{ github.event_name == 'pull_request' && 'HEAD^1' || '' }}`

The pull request's base (the merge commit's first parent; fetch-depth 2); empty on a push.

## 3

Stood above: `POOL_TAIL_SECONDS=300`

A check still running POOL_TAIL_SECONDS before the cap stops with its name, so the job ends in a verdict.
The job clock starts when the runner writes the event file (Set up job), before the runner hook's wait.

## 4

Stood above: `(( job_start <= now && now - job_start < JOB_TIMEOUT_MINUTES * 60 )) || job_start="$now"`

A stale or future event file (not this job's) is no clock: count from now.

## 5

Stood above: `scripts/ci/run-checks-concurrently.sh --start "$RUNNER_TEMP/background-checks" --jobs "$(getconf _NPROCESSORS_ONLN)" \`

A pull request runs only the commands its diff reaches (--affected, scripts/ci/check_pool_affected.py); a push
runs every one, so each command skipped here still has a verdict on the base.

## 6

Stood above: `python3 tests/test_cmux_next_prepush_gate.py --shard 1/4`

The pre-push gate refuses a push that adds a violation and names the commit in CI.
Its 145 cases in four parts (tests/unittest_shard.py): one command, it outlasted every other by 2x.

## 7

Stood above: `python3 tests/test_ui_font.py`

UI font: the system font everywhere, no Inter default (check-ui-font.py).

## 8

Stood above: `python3 tests/test_cmux_next_perf_gate_unlit.py`

The perf gate skips its per-frame timings on a window that draws no frames (--frames auto).

## 9

Stood above: `python3 tests/test_base_merge_warning.py`

A base merge pushed while the PR's CI runs gets a warning (scripts/ci/base_merge_warning.py).

## 10

Stood above: `python3 tests/test_job_input_fingerprint.py`

A changed input, workflow file or toolchain never reuses a pass (CI_NEXT_JOB_REUSE).

## 11

Stood above: `python3 tests/test_job_reuse.py`

Only a pass from this repository's own runs is reused, never a fork's (scripts/ci/job_reuse.py).

## 12

Stood above: `python3 tests/test_dev_release_product_key.py`

The DEV Release app's key changes with every path that can reach it (dev-release-product).

## 13

Stood above: `python3 tests/test_dev_release_product_reuse.py`

A reused DEV Release app is trusted and intact, or the job compiles; DEV lane only.

## 14

Stood above: `python3 tests/test_nightly_release_product_key.py`

The cmux NEXT Nightly app's key and record namespace: never a DEV key or record.

## 15

Stood above: `python3 tests/test_nightly_release_product_reuse.py`

The nightly app's products pack and unpack safely, and nightly.yml keys what it skips.

## 16

Stood above: `python3 tests/test_ci_compile_test_plan.py`

The advisory test-compile check: its plan, the lane phase and red only for a compile failure.

## 17

Stood above: `python3 tests/test_guard_hooks_from_base.py`

A merge goes to the landing gate installed from cmuxterm-hq, never a guard in a checkout.

## 18

Stood above: `python3 tests/test_feat_ci_guard_group.py`

ci-guards.yml's `ci` group runs for feat-cmux-next too (cmux-next-guards.yml).

## 19

Stood above: `python3 tests/test_ios_internal_builder.py`

The INTERNAL iOS builder's trigger decisions and What to Test notes.

## 20

Stood above: `python3 -I scripts/cmux-next/tests/test_bench_launch_console.py`

GUI benches read the console user as the hq worker that grants gui-session-v1 does (step 8c947a3b).

## 21

Stood above: `python3 -I scripts/cmux-next/tests/test_typing_bench_launch_arm.py`

A launch-time A/B key writes the build's own override file and proves its switches once per launch.

## 22

Stood above: `python3 -I tests/test_chromium_staleness.py`

The Chromium staleness guard (cmux-next-chromium-staleness.yml) fails a pin 2+ stable majors behind.

## 23

Stood above: `python3 -I scripts/cmux-next/herdr-sync.py check`

The herdr-derived agent plugin's vendored manifests match their pin.

## 24

Stood above: `python3 -I scripts/cmux-next/tests/test_build_names.py`

The restore journey names a DEV build's socket and acpmux home by the app's rule.

## 25

Stood above: `python3 -I scripts/cmux-next/tests/test_rj_rows.py`

Its view-report rows say what they saw (an unreadable report is not a missing grid).

## 26

Stood above: `python3 -I scripts/cmux-next/tests/test_rj_update.py`

Its update to another build installs B with the running copy's identity (rj_update.py).

## 27

Stood above: `python3 -I scripts/cmux-next/tests/test_sidebar_perf_validate.py`

The fleet sidebar benches emit receipts; this portable test keeps their validator deterministic.

## 28

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-134`

Every check runs even when an earlier one fails; the last step fails the

## 29

Stood above: `rc=0`

Exit 1 is a god file (warn-only); any other code is a broken check and fails.

## 30

Stood above: `rc=0`

Exit 1 is a god file (warn-only); any other code is a broken check and fails.

## 31

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-141`

A test that posts to a process-global notification center reaches every

## 32

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-143`

Animation timing comes from the Motion tokens (plans/cmux-next/motion.md),

## 33

Stood above: `- name: Instrument tokens`

Instrument's one token file (schemas/instrument/instrument.json): today's values still match their
sources, and the pending list only shrinks (pending-baseline.json).

## 34

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-145`

The one motion duration scale (schemas/motion-scale/motion-scale.json): its Swift, CSS and

## 35

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-147`

The overlay surface roles (schemas/surface-roles/surface-roles.json): their Swift and CSS

## 36

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-151`

The phone daemon lane's per-command field allowlist, generated from the daemon's request

## 37

Stood above: `bash scripts/cmux-next/tests/bundle-resources-layout.test.sh`

Ghostty's themes survive the Resources phase in either order (Xcode, the fleet builder).

## 38

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-157`

Gallery fixtures are public sample data the gallery and PR captures render: they name

## 39

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-158`

Per-PR kill switches (release-notes/next/kill-switches.json): each switch names its PR,

## 40

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-163`

"Red on the base, so not ours" is judged per failing test, and a crash or a cut-short

## 41

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-165`

A pull request that changes the router replays the last 30 merged PRs' changed files

## 42

Stood above: `mkdir -p "$code/scripts/cmux-next" "$code/scripts/ci"`

The blobs as the base commit stores them: no attribute (export-ignore, a filter) applies.

## 43

Stood above: `echo "note: the base check has no --tree; the checkout copy runs"`

Only while the base predates --tree (the pull request that adds it).

## 44

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-31`

`outcome`, not `conclusion`: continue-on-error makes every conclusion success.
