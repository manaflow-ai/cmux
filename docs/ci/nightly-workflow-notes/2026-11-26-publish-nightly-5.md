# 2026-11-26-publish-nightly-5

Above `- &x81` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

One nightly-next feed writer at a time across runs (publish-lease.sh), from the first
feed read to the read-back. TTL 15 minutes, renewed every minute by a heartbeat that
dies with the job, so a dead holder blocks the feed one TTL, inside its 30-minute
freshness bound; publish-release-notes passes the same TTL, since a waiter judges
expiry by its own. Max hold: this job's 180-minute timeout. The wait (60 minutes) is
added to the timeout.
