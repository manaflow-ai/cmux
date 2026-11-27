# 2026-11-27-publish-nightly-6

Above `- &gh-app-token-write` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

Release App first, github.token as the fallback (scripts/ci/gh_app_token.sh): the App is
its own actor, so a limit that every workflow's github.token shares does not refuse it.
