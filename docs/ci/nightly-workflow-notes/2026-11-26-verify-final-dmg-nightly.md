# nightly.yml `verify-final-dmg-nightly`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, build-sign-notarize-nightly, pick-nightly-sign-runne`

The final-DMG half of verify-signed-nightly, on its own runner so the two
halves run at the same time (each statically verifies an artifact with the same bundle
id, so they cannot share one runner). No environment and no secrets:
this job statically verifies the final DMG (#21024). publish-nightly
publishes this run's build only when both jobs passed, and only the DMG
bytes this job verified.

## 2

Above: `- *legacy-route-shared-5`

The static DMG verifier runs the license check, which reads
ghostty-next/build.zig.zon.

## 3

Above: `- name: Launch smoke from a fresh home`

Leo, 2026-10-29: "Just don't have that be the downloading thing." The app launched from a fresh
home must stay up with Home rendered: a crash fails this job, so publish-nightly puts none of
this build on the feed (scripts/ci/nightly-steps/launch-smoke-gate.sh; cannot-run never holds it).
