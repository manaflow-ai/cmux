# cmux-next Swift test timing

The 2026-10-05 run for PR [#17470](https://github.com/manaflow-ai/cmux/pull/17470),
workflow run [37402420094](https://github.com/manaflow-ai/cmux/actions/runs/37402420094),
spent 28m21s in `cmux-next swift test` (the brief rounded this to 29 minutes).
The step timings were:

| Step | Time | What it consumes |
| --- | ---: | --- |
| `swift build --build-tests` | 2m36s | Cold package graph build for CmuxNext, Shared and iOS test dependencies |
| same-tree `cmux-tui` wait | 13m15s | Waiting for the matching Linux artifact before the Mac test lane can start |
| package tests (first group) | 10m25s | The broad Swift Testing group, excluding the explicitly isolated suites |
| control, routing, field-editor, WebKit and attach groups | 1m01s | Five smaller follow-up invocations, run sequentially |

The dominant delay is the same-tree artifact wait plus the first test group. The
Mac job also rebuilds the package graph on a cold runner, so a cache miss adds
another few minutes before any test starts.

This report is intentionally descriptive; it does not change the `cmux-next`
test workflow. The lowest-risk improvements for the cx-fleet-heal queue are:

1. Keep one package build, then run the existing test groups as independent
   shards. The control/routing, field-editor/resource, WebKit and attach groups
   already have explicit filters, so they can run concurrently after the build.
2. Cache SwiftPM checkouts and the package build directory on the same Xcode,
   macOS and `Package.resolved` key. Include the head SHA in the product key (or
   validate module inputs) so a cached product is never mistaken for a changed
   source build.
3. Move the same-tree `cmux-tui` wait ahead of Mac admission, or publish that
   artifact from the Linux workflow before requesting a Mac. This removes idle
   Mac time but does not replace the exact-tree check.
4. Record per-shard timing in the job summary and rebalance the broad group
   when one test family becomes the new tail.

