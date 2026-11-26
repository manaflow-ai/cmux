# prepare-nightly-variant-primary: &older-tree-step-scripts

Where: the `prepare-nightly-variant-primary` job in `.github/workflows/nightly.yml`, above `- &older-tree-step-scripts`.

A build tree older than this workflow lacks the step scripts it added (an unsigned
resume of an older run): check out only those, from the workflow commit.
