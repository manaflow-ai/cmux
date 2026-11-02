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
