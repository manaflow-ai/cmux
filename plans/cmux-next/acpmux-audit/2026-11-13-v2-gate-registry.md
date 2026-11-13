# Notice to PL-acpmux: every v2 lane appends its gate rows to the v2 bench registry (2026-11-13, standing)

From the agent service v2 architect lane. This is a standing notice: it covers every v2 PR, so a
v2 lane does not write one of its own for this edit.

Every agent service v2 PR that adds a god-vs-small gate appends its rows to `GATE_ROWS` in
`cmux-tui/crates/acpmux/benches/v2/mod.rs`. That is by design. The design doc
(`docs/design/agent-service-v2.md`, "How a gate measures") keeps one registry for all v2 gates:
each measure a gate writes has one `GateRow` there with its PR, its done-when line and its
bounds, and the bench home joins the rows with the measures into the one report
`quality-report.py --god-small` reads. A PR whose gates land also takes out its own placeholder
row. So the owner warning on that file is expected for a v2 lane, and the lane goes on.

The file stays in the owner map (`plans/cmux-next/OWNERS.md`, `cmux-tui/crates/acpmux/`), and
this notice covers that one file and that one kind of edit: rows appended, a lane's own
placeholder removed. Any other change under `cmux-tui/crates/acpmux/` gets its own notice as
before.

Since PR #42602 the registry has no hand-kept list of emitted names for lanes to edit. Three
tests in the same file read the gate names from the sources of the `acpmux*` crates:
`every_gate_name_in_a_source_has_a_registry_row`, `a_pr_that_writes_a_row_has_no_placeholder_left`
and `a_format_built_name_fits_only_its_own_rows`. A name with no row, or a placeholder left in a
PR whose other rows are written, fails CI in the PR that adds it.

A gate that lives in `acpmux`'s own tests is run with the `gate` cargo profile
(`cmux-tui/Cargo.toml`), from `cmux-tui/`:
`cargo test --profile gate -p acpmux --lib NAME -- --ignored --nocapture` (the gates are
ignored tests, and the measured line is printed before the bound is checked). It is the release profile with link-time optimization off and 16 codegen units. A plain
`--release` test build of `acpmux` does not end on the CI runner, so no lane starts one. The
gates of the other three v2 crates (`acpmux-book`, `acpmux-client`, `acpmux-core`) build in
`--release` as before. A row stays `measured: false` until its run with one of these two
commands is in the PR that sets it.
