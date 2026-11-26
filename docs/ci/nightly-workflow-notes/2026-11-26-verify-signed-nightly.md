# nightly.yml `verify-signed-nightly`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, build-sign-notarize-nightly, pick-nightly-sign-runne`

No environment and no secrets: this job verifies the signed app's static
artifacts and sidecar (#21024). Runtime behavior is covered by the
path-routed daemon/app integration lane. publish-nightly publishes this
run's build only when both verification jobs passed.

## 2

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_MIN`

A failed-jobs rerun retains an older picker. Rejoin the fleet pool, never
that old runner choice, once; later attempts use the Blacksmith overflow.

## 3

Above: `- &x74`

cmux-next: the app's CFBundleShortVersionString and every bundled
CLI's `--version` say the cmux-next version (cmux-tui/Cargo.toml
[workspace.package]); a 0.1.0 `cmux` inside a 1.0.0 app fails here.

## 4

Above: `- &x77`

The post-sign checks of sign-cmux-bundle.sh (entitlements, helpers,
browser host) on this signed app whichever signer made it.
A build commit older than these checks has none to run.
