# cmux-next.yml swift-test: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `swift-test` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `echo "ACPMUX_SOCKET=" >> "$GITHUB_ENV"`

An inherited socket would still name another home's daemon; empty is unset.

## 2

Stood above: `submodules: false`

The package graph reads no submodule; GhosttyNextKit comes from
SwiftPM (Packages/Shared/CmuxGhosttyKit).

## 3

Stood above: `submodules: false`

The package graph reads no submodule; GhosttyNextKit comes from
SwiftPM (Packages/Shared/CmuxGhosttyKit).

## 4

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-222`

A feat-cmux-next push or dispatch lists the pass artifacts with a cmux-bot token,

## 5

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-224`

The sidebar layout reducer's cargo tests run in fast-tier-cargo on Linux

## 6

Stood above: `deadline=$(( $(date +%s) + 2280 ))`

One deadline for both passes, 2 min inside the step timeout, so a pass
hung before any test starts is still sampled and reported.

## 7

Stood above: `heavy_skip=()`

The heavy suites only ever run in their own step: never --skip "" (an
empty pattern matches, and so skips, every test).

## 8

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-233`

The commit-boundary audit reads every observer on the main run loop, so

## 9

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-234`

The CLI parity tests assert routing, not scheduler throughput. Concurrent

## 10

Stood above: `out="$RUNNER_TEMP/generated/files"`

The regenerated files themselves, at their repository paths, so
they copy onto the PR head. A diff would be against the merge
commit, whose context the head may not have.

## 11

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-238`

Also after a failure or a cancel: end the daemon of this job's home and

## 12

Stood above: `actions: read`

The reuse lookup lists artifacts.

## 13

Stood above: `- name: Keep Swift package builds on this owned Mac`

Checkout removes .build. Link the owned Mac's kept build after Xcode

## 14

Stood above: `- name: Restore pinned Bun 1.4.4 from the CI cache bucket`

The package's resources include the web bundles (agent pane, pages,

## 15

Stood above: `- name: Run package tests (changed suites first, then selected targets)`

Samples and fails a run still going after 15 minutes, so a hang shows

## 16

Stood above: `- name: Run CloudBringBack cases in fresh processes`

Cloud bring-back round trips launch two daemons and mutate shared

## 17

Stood above: `- name: Run control package tests and callback regressions`

Each isolated step below runs when its suites' target is selected and

## 18

Stood above: `- name: Upload the test helper's crash reports`

A test helper that died on a signal leaves its crash report here
