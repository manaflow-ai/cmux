# nightly.yml: job `recover-nightly-next-notarization`, step "Claim the whole Mac for signing"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

notarize-nightly-dmg.sh runs the bundle notice check after Apple
accepts, and that check reads ghostty-next/build.zig.zon. Without the
submodule, run 38669958906 skipped five accepted builds.
Release App first, github.token as the fallback (scripts/ci/gh_app_token.sh): the App is
its own actor, so a limit that every workflow's github.token shares does not refuse it.
Later jobs reuse three of these steps by YAML alias (*gh-app-token-read, -write, -install-tooling):
GitHub refuses a workflow file over 512,000 bytes before any job starts.
