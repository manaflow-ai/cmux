# 2026-11-27-sign-release-notes-2

Above `env:` (job `sign-release-notes`) in `.github/workflows/nightly.yml`.

With the job token, for this step only, as "Fetch the published span" does: an anonymous
fetch shares the runner egress IP's anonymous limit and got 403s on 2026-11-26.
