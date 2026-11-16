//! Carries `scripts/cmux-next/chat_open_seed_proof.py` to a host that builds the acpmux binary.
//!
//! A proof run for the chat-open bench's seed, on a branch that never merges: the script makes the
//! bench's subagent chat on a daemon of its own and prints what the daemon stored. The printed lines
//! are the result; the test is red when the stored chat does not hold each subagent.

use std::path::Path;
use std::process::Command;

#[test]
fn the_chat_open_seed_stores_each_subagent() {
    let script = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../scripts/cmux-next/chat_open_seed_proof.py");
    let status = Command::new("python3")
        .arg(&script)
        .arg("--acpmux")
        .arg(env!("CARGO_BIN_EXE_acpmux"))
        .status()
        .expect("python3 starts the proof script");
    assert!(status.success(), "the proof script ended with {status}");
}
