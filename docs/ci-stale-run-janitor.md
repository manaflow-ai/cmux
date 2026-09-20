# Stale Actions run janitor

`.github/workflows/ci-stale-run-janitor.yml` reports stranded queued and in-progress
runs every 30 minutes. It associates each run's commit with pull requests using
the GitHub API, then considers only runs older than 24 hours whose associated
pull requests are closed or merged. Runs with no pull request or with any open
pull request are preserved, which protects default-branch, scheduled, and
reused-branch work.

Scheduled executions are always dry runs. To perform cleanup, start the
workflow manually, leave the age and action limits conservative, and set
`cleanup` to true. Queued runs are deleted; in-progress runs are cancelled.
The workflow caps each invocation at 25 actions and grants `actions: write`
only to this trusted control-plane workflow.
