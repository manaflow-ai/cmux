# published-in: timeout-minutes: 420

Where: the `published-in` job in `.github/workflows/nightly.yml`, above `timeout-minutes: 420`.

Each write is paced at 7.5 s under GitHub's hourly content limit.
A shared edit plus a legacy deletion for all 1,000 allowed PRs takes
250 min; leave room for reads. This runs after publication.
