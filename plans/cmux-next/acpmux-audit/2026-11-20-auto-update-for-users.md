# Automatic update activity census

Leo-ask: ask-3683c5e238 — “auto update for ppl”

Owner: auto-update-for-users, PR #47824. Imported the activity census from #47272.
The updater must distinguish known idle from missing state on an older daemon. Session summaries
now always serialize hasDraft and workingBelow, including false. The app refuses automatic
installation for incomplete rows or a lock-only fallback. A clear census expires after two seconds; a refresh retains it only within that bound, avoiding a
refresh/timer race that could keep every install held forever. Busy, draft and unknown answers
back off to five seconds between reads. Explicit install opt-out leaves downloads enabled but no
automatic relaunch. The card's Automatic Updates switch writes both settings in click order;
turning it off disables installation first.

The underlying failure class was treating absent fields as false and refresh-in-flight as idle or
permanently unknown. Release gates must test missing/false protocol fields, stale reads, delayed
readers, and off/on policy races. Missing FFI support deliberately holds installation; Rust Step A
must publish and re-pin before the Swift caller lands.

Detector: AcpmuxUpdateCensusTests, UpdateAgentActivityRefreshTests, UpdateCardSettingsTests and
AutomaticInstallDeferralTests; fleet verification pending.
The owning session cmux-4f was unavailable; interim-coord received the owner notice.
Stop condition: exact-head tests, merged PR, and no-click upgrade of a NIGHTLY side copy read back by CLI.
