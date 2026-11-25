# Checkups

Leo, 2026-11-20: "we ought to have good tools/scripts checkups for these" (ask-f70cfb2563, on cmux#47799).

A checkup reads what an owner already records and says whether it is sound, from a shell, with no app window. Each
one adds no rules or numbers of its own, prints a breakdown for a person or `--json` for a script, and exits 0
clean, 1 findings, 2 unreadable. An answer it could not read is never reported as clean.

| checkup | reads | the app's view of the same thing |
|---|---|---|
| `session-timing.py SESSION... \| --all \| --from-file F` | `acpmux history --json` (the daemon's `_acpmux/history`) | ACP inspector > Timing |
| `configuration.py [FILE...]` | `cmux --json settings validate` (the Rust settings owner) | Settings > Advanced > Check Configuration |

`session-timing.py` prints per chat the p50, p95 and max of the send delay (prompt accepted to prompt written to the
agent) and the first output (prompt written to the model's first output), unknown stamps, idle time between turns
and the chat's start steps. It fails on a history for another session, a turn ending before it started, a wall time
that is not end minus start, phases longer than their turn, bad or repeated values, and a send delay over
`--send-budget-ms` (2000 by default; `--first-output-budget-ms` is off by default).

`configuration.py` sorts the validator's answer into the page's three states: clean (a missing default file is
clean), problems (each refused key with what it accepts, or a file that is not JSON), and unreadable.

Tests: `python3 -I scripts/checkup/tests/session-timing.test.py` and `configuration.test.py`; CI runs both in
cmux-next guards' tooling-tests.
