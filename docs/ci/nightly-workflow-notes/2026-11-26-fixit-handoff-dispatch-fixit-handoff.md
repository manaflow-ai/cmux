# fixit-handoff: Dispatch fixit-handoff on feat-cmux-next

Where: the `fixit-handoff` job in `.github/workflows/nightly.yml`, above `- name: Dispatch fixit-handoff on feat-cmux-next`.

Off the publish path: a rate-limited dispatch fails now instead of waiting, and never reds the nightly
(tests/test_gh_budget_wait.py DISPATCH_NEVER_WAITS).
