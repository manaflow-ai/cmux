# 2026-11-27-fixit-handoff-1

Above `- name: Dispatch fixit-handoff on feat-cmux-next` (job `fixit-handoff`) in `.github/workflows/nightly.yml`.

Off the publish path: a rate-limited dispatch fails now instead of waiting, and never reds the nightly
(tests/test_gh_budget_wait.py DISPATCH_NEVER_WAITS).
