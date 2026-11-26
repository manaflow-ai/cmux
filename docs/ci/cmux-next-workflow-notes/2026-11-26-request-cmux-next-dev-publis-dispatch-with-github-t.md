# request-cmux-next-dev-publish: Dispatch with GITHUB_TOKEN, waiting through a rate limit

Where: the `request-cmux-next-dev-publish` job in `.github/workflows/cmux-next.yml`, above `- name: Dispatch with GITHUB_TOKEN, waiting through a rate limit`.

Why: 2026-11-24-request-cmux-next-dev-publish-1.md, note-339
The quota-goblin CI pool's tokens (leo-workspace gh-app-roles push.actions_secrets CI_POOL_TOKEN_*) each
have an hour of their own, so the hand-off tries them before it waits for github.token's reset.
