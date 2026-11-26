# sign-release-notes: env:

Where: the `sign-release-notes` job in `.github/workflows/nightly.yml`, above `env:`.

With the job token, for this step only, as "Fetch the published span" does: an anonymous
fetch shares the runner egress IP's anonymous limit and got 403s on 2026-11-26.
