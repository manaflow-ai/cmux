# dev-daily-tree-wait: any state but ready, and the nightly's older tree

Above `dev-daily-tree-wait` (its `if:` and its checkout's `fetch-depth`) in `.github/workflows/cmux-next.yml`.

The job runs on any DEV daily tree_state but ready (deferred, and skipped: path routing's own fallback looks
only 50 commits back) when the app scheme is routed (a superseded run routes none). Besides its own tree,
`scripts/cmux-next/wait-dev-daily-tree.sh` takes the nightly's older-tree answer
(`scripts/cmux-next/older-tree-for-tip.sh`: the newest published tree within 24 h and 400 commits with this
commit's daemon-capabilities.json), so its checkout fetches 401 commits.

Until 2026-11-27 a skipped state skipped every compile job. feat-cmux-next published no tree of its own from
00:55Z (every artifacts run red), the newest published tree was 160 commits back, and DEV published nothing
after 2026-11-26 13:54Z (run 45955325112 at ea9738b597: "no tree in its recent history is published; the tree
jobs are skipped").
