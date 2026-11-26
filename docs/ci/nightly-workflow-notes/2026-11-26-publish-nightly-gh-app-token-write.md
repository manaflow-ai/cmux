# publish-nightly: &gh-app-token-write

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `- &gh-app-token-write`.

Release App first, github.token as the fallback (scripts/ci/gh_app_token.sh): the App is
its own actor, so a limit that every workflow's github.token shares does not refuse it.
