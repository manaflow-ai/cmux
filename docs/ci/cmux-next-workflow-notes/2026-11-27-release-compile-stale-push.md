# 2026-11-27-release-compile-stale-push

Step "Run the fast fleet compile check" (job `release-compile-fast`), env `STALE_PUSH_GATE`.

Leo: "de facto, im asking for 99% fewer minutes of ci time, period." / "whatever we need to cut, we cut."

Job `release-compile` ("cmux-next Release compile (Xcode 26)") is the Mac fallback of this fast check: it runs
whenever the verdict is `unavailable` (no fleet answer, mismatch, service down). Until now a push whose branch
head had moved on skipped that fallback only when the fleet answered `superseded`. A push that got no answer at
all (the fleet being down or slow is exactly when pushes pile up) compiled to completion on a Mac, 60 min a try,
for a commit whose result the later tip check already covers. The `git ls-remote` head test now applies to every
state except `pass`/`fail`: head differs from this push -> verdict `superseded`, no Mac fallback. The tip push still
falls back as before. Basis: the minutes of `release-compile` on feat-cmux-next pushes that were not the head when
their fast check ended (read from `mac-job-hours.py --job "cmux-next Release compile (Xcode 26)"`).

Undo: repo variable `CMUX_NEXT_STALE_PUSH_MAC_FALLBACK` = `0`.
