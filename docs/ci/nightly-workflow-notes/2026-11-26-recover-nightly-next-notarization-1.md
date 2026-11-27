# 2026-11-26-recover-nightly-next-notarization-1

Above `- &gh-app-token-read` (job `recover-nightly-next-notarization`) in `.github/workflows/nightly.yml`.

notarize-nightly-dmg.sh runs the bundle notice check after Apple
accepts, and that check reads ghostty-next/build.zig.zon. Without the
submodule, run 38669958906 skipped five accepted builds.
Release App first, github.token as the fallback (scripts/ci/gh_app_token.sh): the App is
its own actor, so a limit that every workflow's github.token shares does not refuse it.
Later jobs reuse three of these steps by YAML alias (*gh-app-token-read, -write, -install-tooling):
GitHub refuses a workflow file over 512,000 bytes before any job starts.
