//! The cmux-tui binary (`cmux-tui acp ...`) carries acpmux's
//! `<version> (<build id>)` as one string, as the standalone acpmux binary
//! does (acpmux `tests/binary_build_stamp.rs`): acpmux updaters read the
//! build id out of a pushed binary's bytes without running it.

#[test]
fn the_binary_holds_acpmuxs_version_and_build_id_as_one_string() {
    let bytes = std::fs::read(env!("CARGO_BIN_EXE_cmux-tui")).unwrap();
    let line = format!("{} ({})", acpmux::hub::VERSION, acpmux_build_id::build());
    assert!(
        bytes.windows(line.len()).any(|w| w == line.as_bytes()),
        "the cmux-tui binary does not contain `{line}` as one string"
    );
}

/// The cmux-tui binary carries acpmux-build-id's `acpmux-commit-time=<secs>;`
/// too: a host's install step reads it from the installed and the pushed
/// binary to refuse a move back to an older commit (acpmux `cli/hosts.rs`).
#[test]
fn the_binary_holds_acpmuxs_commit_time_stamp() {
    let bytes = std::fs::read(env!("CARGO_BIN_EXE_cmux-tui")).unwrap();
    let stamp = acpmux_build_id::COMMIT_STAMP.as_bytes();
    assert!(
        bytes.windows(stamp.len()).any(|w| w == stamp),
        "the cmux-tui binary does not contain `{}`",
        acpmux_build_id::COMMIT_STAMP
    );
}
