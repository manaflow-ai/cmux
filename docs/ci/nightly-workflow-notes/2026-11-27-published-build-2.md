# 2026-11-27-published-build-2

Above `- name: Read the published build back from the live feed` (job `published-build`) in `.github/workflows/nightly.yml`.

The job's own claim, read back: the build it says went out is on the live nightly-next feed (Leo's app reads
it), as its newest item or under a newer build that already published. Red here stops the dispatch and the tail.
