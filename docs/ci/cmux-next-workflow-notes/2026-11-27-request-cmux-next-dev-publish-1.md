# 2026-11-27-request-cmux-next-dev-publish-1

Above `- name: Dispatch with GITHUB_TOKEN, waiting through a rate limit` (job `request-cmux-next-dev-publish`) in `.github/workflows/cmux-next.yml`.

The quota-goblin CI pool's tokens (leo-workspace gh-app-roles push.actions_secrets CI_POOL_TOKEN_*) each
have an hour of their own, so the hand-off tries them before it waits for github.token's reset.
