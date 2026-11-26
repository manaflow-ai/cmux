# wake-nightly-next-tick: &mint-dispatch-pools

Where: the `wake-nightly-next-tick` job in `.github/workflows/nightly.yml`, above `- &mint-dispatch-pools`.

Run 45562645699 (2026-11-25): github.token's hour was spent, so this dispatch and dispatch-published-in's
slept in gh_budget_wait.sh until its reset (18.4 and 12.9 min, both out at 07:54Z) though the feed was
live at 44.9 min. Each App installation has its own hour: a refused dispatch moves to cmux-bot, then the CI
pools, at once (GH_TOKEN_SPARE, GH_TOKEN_SPARES), and waits for a reset only when every one refuses.
