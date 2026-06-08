# macOS CI runners

All paid macOS CI/CD jobs run on Blacksmith. The runner labels are hardcoded in the workflows (git-tracked); there is no repo-variable override.

- `blacksmith-6vcpu-macos-15` for jobs that build the universal Ghostty CLI helper (zig 0.15.2 can only cross-link the x86_64 slice against a pre-26 SDK), for the GhosttyKit framework build, for unit/UI tests, and for the nightly app build (which uses Xcode 26 on the macOS 15 host).
- `blacksmith-6vcpu-macos-26` for the app builds that must link the macOS 26 SDK so SDK-gated SwiftUI Liquid Glass code compiles in: stable `release` `build-sign-notarize` and the CI `release-build` SDK-validation lane. `ci-macos-compat.yml` also exercises macOS 26 with `CMUX_SKIP_ZIG_BUILD=1`.

Workflows reference these labels directly, e.g. `runs-on: blacksmith-6vcpu-macos-15`.

## Changing the runner

To switch providers or roll back to Warp, edit the `runs-on` labels in `.github/workflows/*.yml` and open a PR. There is no variable to flip; the runner choice lives in git so every change is reviewed and recorded.

If a new runner label is introduced, add it to `.github/actionlint.yaml` so `actionlint` recognizes it.

## Manual runs

`perf-activation.yml` and `test-e2e.yml` keep a `runner` choice input that defaults to `auto`. `auto` (and the empty `pull_request` case for perf) resolves to the hardcoded Blacksmith default; an explicit choice wins. `test-e2e.yml` also keeps `depot-macos-*` choices and a Depot identity guard for GUI-activation runs.

## Guard

`tests/test_ci_self_hosted_guard.sh` (run by the `workflow-guard-tests` job) asserts every paid macOS job references a Blacksmith label, so a job can never silently fall back to a free GitHub-hosted runner. `tests/test_ci_release_sdk_lane.sh` asserts the release/CI app builds use macOS 26 with a macOS-15-built helper.
