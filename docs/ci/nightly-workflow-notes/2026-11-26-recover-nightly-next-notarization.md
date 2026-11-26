# nightly.yml `recover-nightly-next-notarization`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 270 || 150 }}`

An accepted continuation builds, signs and notarizes the DMG around the
stapled app (notarize-nightly-dmg.sh, CMUX_STAPLE_APP_IN_DMG): a 20m wait
and packaging per candidate; a failed one moves on to the next of 3.

## 2

Above: `- *hold-the-whole-mac`

First, before any checkout or secret: on an owned Mac this job holds the whole mini (glaeda's
exclusive class) or fails here (tests/test_ci_signing_owned_mac.py CLAIM_GATE).

## 3

Above: `- &gh-app-token-read`

notarize-nightly-dmg.sh runs the bundle notice check after Apple
accepts, and that check reads ghostty-next/build.zig.zon. Without the
submodule, run 38669958906 skipped five accepted builds.
Release App first, github.token as the fallback (scripts/ci/gh_app_token.sh): the App is
its own actor, so a limit that every workflow's github.token shares does not refuse it.
Later jobs reuse three of these steps by YAML alias (*gh-app-token-read, -write, -install-tooling):
GitHub refuses a workflow file over 512,000 bytes before any job starts.
