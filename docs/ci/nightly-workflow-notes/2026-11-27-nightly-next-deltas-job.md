# nightly-next-deltas follows publication in its own job

Where: `.github/workflows/nightly.yml`, `nightly-next-one`'s "Hand the deltas job its inputs" step and the `nightly-next-deltas` job.

This updates the topology described in [the earlier delta note](2026-11-25-nightly-next-deltas.md) and [note-31](../nightly-workflow-notes.md#note-31). The deltas still follow the feed and remain optional. The separate job lets `published-build` and the GitHub release start when `nightly-next-one` ends, without waiting for the delta build and upload (run 45575194160: 283 s build, 17 s upload; ask-c0123d25e8).

`nightly-next-one` hands over the build number, DMG names, appcast and minimum system version through `deltas-inputs`, without secrets. The delta job downloads the arm64 artifact into its own `.nightly-next-deltas` directory, runs the same scripts with `DELTAS_ONLY_WHILE_NEWEST=1`, then removes that directory. The job continues on error; a missing delta does not fail publication.

The signing key still reaches only the delta build after its stray-process check. The claim and build steps keep their success dependency, so a failed claim skips signing. Nothing from the bundle runs in these steps. `tests/test_nightly_next_one_job.py` and `tests/test_ci_signing_owned_mac.py` cover those boundaries and the publication dependency.

The historical note remains unchanged: risk evidence run 45931527121 detected its replacement as a takeback of #57512. New workflow behavior belongs in this separate note.

The delta job sets `TMPDIR` to `runner.temp` so interrupted `mktemp` signing keys are inside the existing final wipe. When `CI_NIGHTLY_MINI` is configured, routing requires both its only permitted label, `glaeda-nightly-mini`, and `glaeda-trusted-next-signing`; without it the trusted signer pool remains the default. The feed's delta check runs after upload, independently of the next-tick dispatch. The one-job and trusted-routing tests detect regressions in these boundaries.

The failure reporter is extracted unchanged to `scripts/ci/nightly-steps/report-nightly-failure.cjs`, checked out at the workflow commit with credentials disabled, to keep the workflow below its file-size cap. The file-size, rate-limit and trusted-routing tests cover this extraction.

Post-merge evidence still required: the deployed fleet hook's exclusive claim for `nightly-next-deltas`, a run containing this merge, feed and GitHub publication timestamps, signed artifact digest, and installed NIGHTLY readback. The old run's delta duration above is a baseline, not a measurement of this change or proof of the 30-minute target.
