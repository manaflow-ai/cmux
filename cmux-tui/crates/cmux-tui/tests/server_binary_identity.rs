//! The shipped `cmux` surface reaches the same release query before host setup.
#![cfg(unix)]

use std::os::unix::process::CommandExt;
use std::process::Command;

#[test]
fn status_binary_identity_is_available_through_the_shipped_cmux_mount() {
    let directory = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg0("cmux")
        .args(["server", "status", "--binary-only", "--json"])
        .env_clear()
        .current_dir(directory.path())
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let actual: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(actual["schema"], 1);
    assert_eq!(actual["kind"], "cmux.server.binary");
    assert_eq!(actual["version"], env!("CARGO_PKG_VERSION"));
    assert!(actual["release_keys"].is_array());
    assert!(actual.get("store").is_none());
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
}
