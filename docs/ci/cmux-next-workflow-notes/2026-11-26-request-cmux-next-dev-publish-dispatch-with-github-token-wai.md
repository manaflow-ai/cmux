# cmux-next.yml: job `request-cmux-next-dev-publish`, step "Dispatch with GITHUB_TOKEN, waiting through a rate limit"

Moved out of `.github/workflows/cmux-next.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Why: 2026-11-24-request-cmux-next-dev-publish-1.md, note-339
The quota-goblin CI pool's tokens (leo-workspace gh-app-roles push.actions_secrets CI_POOL_TOKEN_*) each
have an hour of their own, so the hand-off tries them before it waits for github.token's reset.
