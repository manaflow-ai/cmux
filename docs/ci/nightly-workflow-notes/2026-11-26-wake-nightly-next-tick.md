# nightly.yml `wake-nightly-next-tick`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `- &mint-dispatch-pools`

Run 45562645699 (2026-11-25): github.token's hour was spent, so this dispatch and dispatch-published-in's
slept in gh_budget_wait.sh until its reset (18.4 and 12.9 min, both out at 07:54Z) though the feed was
live at 44.9 min. Each App installation has its own hour: a refused dispatch moves to cmux-bot, then the CI
pools, at once (GH_TOKEN_SPARE, GH_TOKEN_SPARES), and waits for a reset only when every one refuses.

## 2

Above: `- name: Check the published feed offers deltas`

The detector (hq#13299): the build this run published must reach the feed with its deltas, each
served at its length; a newer build already live passes with a notice. Red here names a feed
where every Mac downloads the full 243 MB DMG.
