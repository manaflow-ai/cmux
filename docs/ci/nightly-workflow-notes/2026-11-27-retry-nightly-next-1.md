# 2026-11-27-retry-nightly-next-1

Above `- name: Read scripts/ci from the host's git mirror` (job `retry-nightly-next`) in `.github/workflows/nightly.yml`.

The retry runs after a failure that is often GitHub refusing this host's git traffic (run 45744507889:
actions/checkout got 403 here too). On an owned Mac, scripts/ci comes from the host's git mirror (fetched
every minute by its one fetcher), with no github.com git fetch; actions/checkout only when it lacks SHA.
