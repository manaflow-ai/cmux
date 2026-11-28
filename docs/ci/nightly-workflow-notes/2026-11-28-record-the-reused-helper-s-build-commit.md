# 2026-11-28-record-the-reused-helper-s-build-commit

Where: `.github/workflows/nightly.yml`, Record the reused helper's build commit.

Its own goblin App token first (leo-workspace machines/gh-app-roles.json push.actions_secrets NIGHTLY_HELPER_LOOKUP_TOKEN), then github.token; a 403 waits to the limit's reset, at most 240 s a token.
