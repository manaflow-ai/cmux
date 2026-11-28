//! Every `cmux` grammar verb this binary's help lists is in the palette coverage keep list
//! (plans/cmux-next/palette-coverage.json `cli_verbs`), mapped to the palette action that does the same
//! for a person or kept with a reason, and the list names no verb the binary no longer has.
//!
//! The list used to learn of verbs only when someone ran `palette-coverage.py --refresh-cli`, so a new verb
//! with no palette row never counted as missing, and a removed one stayed mapped to a deleted action (the 4
//! `coderouter` verbs NOW read on 2026-11-28). This runs the same reader against the binary the PR builds,
//! so the PR that adds or removes a verb is the one that fails. Leo: "command palette should be able to
//! "do" more stuff".

use std::path::Path;
use std::process::Command;

#[test]
fn every_cli_verb_has_a_palette_entry_or_a_keep_reason() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let script = root.join("scripts/cmux-next/palette-coverage.py");
    let output = Command::new("python3")
        .arg("-I")
        .arg(&script)
        .arg("--check-cli")
        .arg(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap_or_else(|error| panic!("run {}: {error}", script.display()));
    assert!(
        output.status.success(),
        "palette-coverage.py --check-cli exited {:?}\n{}{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
}
