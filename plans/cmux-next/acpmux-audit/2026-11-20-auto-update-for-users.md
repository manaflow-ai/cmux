# Automatic update activity census

Leo-ask: ask-3683c5e238 — “auto update for ppl”

Owner: auto-update-for-users, PR #47824. Imported the activity census from #47272.
The updater must distinguish known idle from missing state on an older daemon. Session summaries
now always serialize hasDraft and workingBelow, including false. The app refuses automatic
installation for incomplete rows or a lock-only fallback. A census refresh invalidates its old
answer while in flight. Explicit install opt-out leaves downloads enabled but no automatic relaunch.

Detector: AcpmuxUpdateCensusTests and AutomaticInstallDeferralTests; fleet verification pending.
The owning session cmux-4f was unavailable; interim-coord received the owner notice.
Stop condition: exact-head tests, merged PR, and no-click upgrade of a NIGHTLY side copy read back by CLI.
