//! The rollback check with an end time, through the real executable:
//! `cmux-tui __store-schemas --stored --within-ms N` (cmux-tui-core
//! `store_schemas.rs`). The app gives the check a fixed time and ends its
//! process after it; a check that cannot read each session in that time
//! must say so itself, with how many sessions it read, in place of no
//! answer.
//!
//! Each state root here is a temp folder with session folders that hold one
//! small registry file with a stored schema number and nothing else: the
//! check reads that number only.

#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::Command;

use rusqlite::Connection;
use serde_json::{Value, json};

/// The registry's file in a session folder.
const REGISTRY_FILE: &str = "workspace-registry.sqlite3";

/// The state root of a test folder.
fn sessions_of(folder: &Path) -> std::path::PathBuf {
    folder.join("sessions")
}

/// A test folder whose state root has `sessions` session folders, each with
/// a registry file whose stored schema number is `number`.
fn state_root(sessions: usize, number: i64) -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    for index in 0..sessions {
        let session = sessions_of(root.path()).join(format!("session-{index}"));
        fs::create_dir_all(&session).unwrap();
        let store = Connection::open(session.join(REGISTRY_FILE)).unwrap();
        store
            .execute_batch(&format!(
                "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO meta (key, value) VALUES ('schema_version', '{number}');"
            ))
            .unwrap();
    }
    root
}

/// One run of the check for the state root of `folder` with `arguments`
/// after `--stored`: its exit code, its stdout as JSON (null when it is not
/// JSON) and its stderr. Its config and its log are files of `folder`.
fn check(folder: &Path, arguments: &[&str]) -> (Option<i32>, Value, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["__store-schemas", "--stored"])
        .args(arguments)
        .env("CMUX_TUI_STATE_DIR", sessions_of(folder))
        .env("CMUX_TUI_CONFIG", folder.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", folder.join("client.log"))
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let answer = serde_json::from_str(stdout.trim()).unwrap_or(Value::Null);
    (output.status.code(), answer, String::from_utf8_lossy(&output.stderr).trim().to_string())
}

/// The fixture is what the check reads: with no end time it gives the number.
#[test]
fn a_check_with_no_end_time_gives_the_number_of_three_small_sessions() {
    let root = state_root(3, 15);
    let (code, answer, stderr) = check(root.path(), &[]);
    assert_eq!((code, answer), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");
}

/// A check that cannot end in its time gives a third state, never no
/// answer: exit 0 and one object that names how many sessions the root has
/// and how many it read. With no time at all it still reads one session, so
/// that a call after it always goes on.
#[test]
fn a_check_that_cannot_end_in_its_time_says_how_many_sessions_are_ready() {
    let root = state_root(3, 15);
    let (code, answer, stderr) = check(root.path(), &["--within-ms", "0"]);
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "not_ready": { "sessions": 3, "sessions_read": 1 } })),
        "stderr: {stderr}"
    );
}

/// A check that ends in its time gives the numbers, as a check with no end
/// time does.
#[test]
fn a_check_that_ends_in_its_time_gives_the_numbers() {
    let root = state_root(3, 15);
    let (code, answer, stderr) = check(root.path(), &["--within-ms", "60000"]);
    assert_eq!((code, answer), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");
}

/// A root with one session has nothing to stop before: the check gives its
/// number with no time at all.
#[test]
fn a_check_of_one_session_with_no_time_gives_its_number() {
    let root = state_root(1, 15);
    let (code, answer, stderr) = check(root.path(), &["--within-ms", "0"]);
    assert_eq!((code, answer), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");
}

/// A folder of the state root that holds no store is not a session: the
/// check does not count it.
#[test]
fn a_folder_with_no_store_is_not_counted_as_a_session() {
    let root = state_root(2, 15);
    fs::create_dir(sessions_of(root.path()).join("no-store-here")).unwrap();
    let (code, answer, stderr) = check(root.path(), &["--within-ms", "0"]);
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "not_ready": { "sessions": 2, "sessions_read": 1 } })),
        "stderr: {stderr}"
    );
}
