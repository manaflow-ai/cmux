# 2026-11-28-resolve-nightly-ghostty-cli-helper-find-an-earlier-helper-with-the-same-inp

Where: `.github/workflows/nightly.yml`, job `resolve-nightly-ghostty-cli-helper`, step "Find an earlier helper with the same inputs": above `GH_TOKEN: ${{ secrets.NIGHTLY_HELPER_LOOKUP_TOKEN || github.token }}`.

Its own goblin App token first (leo-workspace machines/gh-app-roles.json push.actions_secrets NIGHTLY_HELPER_LOOKUP_TOKEN), then github.token; a 403 waits to the limit's reset, at most 240 s a token.
