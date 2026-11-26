# nightly-next-deltas, its own job after nightly-next-one

Follows [note-31](../nightly-workflow-notes.md#note-31) (nightly-next-one builds the nearest deltas after the feed write).

Since 2026-11-25 (ask-c0123d25e8) those deltas run in their own job, nightly-next-deltas, which needs nightly-next-one: published-build and the GitHub release start as soon as nightly-next-one ends instead of waiting the ~5 min the deltas took (run 45575194160: 283 s build, 17 s upload). nightly-next-one only hands the job the build number, DMG names, appcast and minimum system version (step deltas-inputs, no secret); the job downloads the arm64 variant artifact into its own `.nightly-next-deltas` directory, runs the same two scripts with DELTAS_ONLY_WHILE_NEWEST=1, and removes that directory. It is continue-on-error, so a missing delta never fails the run.
