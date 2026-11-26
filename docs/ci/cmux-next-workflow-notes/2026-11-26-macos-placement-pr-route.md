# macOS placement on a feat-cmux-next pull request

Job `macos-placement` in `.github/workflows/cmux-next.yml`, its `if` (extends note-369 in the frozen file).

A pull request into feat-cmux-next with no full-ci or dev-build label places only when a Mac job of its run can
start: the Release compile fallback (mac_release), the daemon tests on a ready tree, or generated files hosted by
its own job. The fast tier and the Swift canary run only on the push tier (#54763), so they place nothing on a pull
request. `macos` alone is broader: it is also true for the daemon tier on a deferred tree (the same-tree run places
it), the scheme compile and the swift test (full-ci only into feat-cmux-next) and a native route with no mac_release
(the Release compile defers to land). Over 11-23 18Z..11-24 18Z, 2,241 of 3,570 PR placements (7,441 runner minutes,
8.1 per merged PR) started no Mac job. Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes of ci time,
period." `tests/test_cmux_next_route.py` holds the clause: a new consumer of `macos-placement` fails it until the
clause names that consumer's route.
