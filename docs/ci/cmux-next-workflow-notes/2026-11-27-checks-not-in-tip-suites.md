# checks does not run in the tip suite dispatches

The tip Swift suite and tip daemon suite dispatches say they run only their suite (their `inputs` descriptions),
but `cmux-next checks (god files, concurrency, crash safety, l10n)` still ran in them: 11-27 12:2x-12:3x,
runs 45997843322 (tip daemon suite) and 45999687353 (tip Swift suite) each started a ~13 min checks job
on the same feat-cmux-next tree the push run had already checked.
`checks` now skips when `tip_swift_suite` or `tip_daemon_suite` is true. `base_tier` still runs it (its Previous checked tip step reads it).
