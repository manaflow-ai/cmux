# v1 tap recording

`v1-tap.json` is captured from a fixture harness on hosted Linux, through the agent host reader and v1's real tap. Its header identifies the source commit, capture command and run. Each entry contains the canonical host message, the tap's context before processing, every record v1 wrote, and the index of the pure table's record (or `null` when the entry was kept nowhere).

The fixture runs initialize and a complete prompt/result exchange, then exits under Ready, Running, Idle and hibernating Idle status. The test sets each exit status explicitly. It also captures the first stream delta, the later discarded delta, a discarded context answer, and repeated initialization across harness restarts. It uses no person's chat.

The ordinary `v2_record_replays_recorded_v1_fixture` test compares the pure table's serialized event bytes against the recording and checks that those cases are present. The hand-written tests in `tap_bodies_tests.rs` cover additional table cases. Neither is whole-stage parity for stateful update normalization.

To reproduce, check out the header's source commit and run the ignored `v2_record_capture_fixture_run` test on cmux-ci with a same-commit `acpmux` binary. Build the binary first, get Cargo's target directory with `cargo metadata`, and export `CARGO_BIN_EXE_acpmux=<target>/debug/acpmux` and `V2_RECORD_CAPTURE_BASE_SHA=<source commit>` before compiling the unit test. Keep the CI-provided `GITHUB_RUN_ID`. The test-support environment re-execs only this capture test in its hermetic environment; all started hosts are owned by the test.

The run prints one `V2_RECORD_CAPTURE` line. Store the JSON after that prefix, preserving its header; the fixture must remain below 256 KiB. A capture that fails its coverage or replay assertions produces no fixture.
