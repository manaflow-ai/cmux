# decide: promote-nightly-next:

Where: the `decide` job in `.github/workflows/nightly.yml`, above `promote-nightly-next:`.

Moves the protected branch `nightly-next` to a feat-cmux-next commit whose cmux-next.yml
push run passed its Release compile. Runs only on main, in `release`, with the release App
(the ruleset's only bypass actor). Guard: scripts/ci/promote-nightly-next.mjs, from this
main checkout. One concurrency group keeps a single writer; decideNewest() also decides the
newest request GitHub evicted (checks: read) whose commit contains this one's.
