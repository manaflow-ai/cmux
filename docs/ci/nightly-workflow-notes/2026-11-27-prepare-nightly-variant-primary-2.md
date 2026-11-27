# 2026-11-27-prepare-nightly-variant-primary-2

Above `- &older-tree-step-scripts` (job `prepare-nightly-variant-primary`) in `.github/workflows/nightly.yml`.

A build tree older than this workflow lacks the step scripts it added (an unsigned
resume of an older run): check out only those, from the workflow commit.
