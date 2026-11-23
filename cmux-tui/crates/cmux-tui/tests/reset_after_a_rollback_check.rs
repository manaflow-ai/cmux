//! The reset command (`cmux session NAME reset-state`) with one run of the
//! rollback check (`cmux-tui __store-schemas --stored`) between its 2 calls,
//! through the real executable.
//!
//! The reset command works in 2 calls. The first call changes nothing and
//! gives a confirmation text that stands for each file in the session's
//! folder. The second call, with `--force` and that text, does the reset
//! only when the folder is still as the text says.
//!
//! The rollback check reads the stored schema number of each store of each
//! session folder. The store of a session with no daemon is a closed store
//! in WAL mode. A read of a closed store in WAL mode can make a `-wal` file
//! and a `-shm` file in the session's folder and leave them. So a check
//! that runs between the 2 calls can change the folder, and then the second
//! call refuses the text. The person did what the first call said and gets
//! an error.
//!
//! The first row is the control: the 2 calls with no check between them do
//! the reset. The second row has one run of the check between the 2 calls
//! and wants the same end. When it is red, its text says which `-wal` and
//! `-shm` files the session's folder had before the check and after it,
//! each with its length.
//!
//! Each row makes the first call 2 times and wants the same confirmation
//! text from both. A different text says that something wrote in the
//! session's folder after the fixture closed the store: then the folder was
//! not at rest, and the end of the row says nothing about the check.
//!
//! No row here measures a time, and no row waits. Each call gets its config
//! file and its log file in the test folder.

#![cfg(any(target_os = "macos", target_os = "linux"))]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use serde_json::Value;

/// The registry's file in a session folder.
const REGISTRY_FILE: &str = "workspace-registry.sqlite3";

/// A test folder and its state root, with the saved state of the session
/// `session` and no process that has its store open: the registry is opened
/// one time and closed again, as a daemon that stopped leaves it.
fn a_state_root_with_a_closed_session(session: &str) -> (tempfile::TempDir, PathBuf) {
    let folder = tempfile::tempdir().unwrap();
    let state = fs::canonicalize(folder.path()).unwrap().join("state");
    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    (folder, state)
}

/// The executable with its config file and its log file in `folder`, and
/// with no socket and no terminal of the process that runs the rows.
fn the_executable(folder: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_CONFIG", folder.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", folder.join("client.log"))
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID");
    command
}

/// One call of `cmux --json session SESSION reset-state` with `more` and
/// the state root `state`.
fn reset_command(folder: &Path, state: &Path, session: &str, more: &[&str]) -> Output {
    the_executable(folder)
        .args(["--json", "session", session, "reset-state"])
        .args(more)
        .arg("--state")
        .arg(state)
        .output()
        .unwrap()
}

/// The stdout and the stderr of `output`, for the text of an expect.
fn text_of(output: &Output) -> String {
    format!(
        "exit {:?}\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// The first call of the reset command: the session's folder and the
/// confirmation text for the second call. The folder holds the registry's
/// file after the call.
fn first_call(folder: &Path, state: &Path, session: &str) -> (PathBuf, String) {
    let output = reset_command(folder, state, session, &[]);
    assert!(output.status.success(), "the first call: {}", text_of(&output));
    let preview: Value = serde_json::from_slice(&output.stdout).unwrap();
    let session_dir = preview.get("session_dir").and_then(Value::as_str).map(PathBuf::from);
    let confirmation = preview.get("confirm_reset").and_then(Value::as_str).map(str::to_string);
    let (Some(session_dir), Some(confirmation)) = (session_dir, confirmation) else {
        panic!("the first call gave no folder or no confirmation: {preview}");
    };
    assert!(
        session_dir.join(REGISTRY_FILE).is_file(),
        "no registry file in {} after the first call",
        session_dir.display()
    );
    (session_dir, confirmation)
}

/// The first call one more time. Its confirmation text must be `confirmation`,
/// the text of the first call before it: nothing wrote in the session's
/// folder between the 2 calls, so the folder is at rest.
fn the_folder_is_at_rest(folder: &Path, state: &Path, session: &str, confirmation: &str) {
    let (_, again) = first_call(folder, state, session);
    assert_eq!(
        again, confirmation,
        "the session's folder was not at rest: a second first call gave another confirmation text"
    );
}

/// The second call of the reset command, with `--force` and `confirmation`.
fn second_call(folder: &Path, state: &Path, session: &str, confirmation: &str) -> Output {
    reset_command(folder, state, session, &["--force", "--confirm-reset", confirmation])
}

/// The `-wal` and `-shm` files in `session_dir`, each with its length in
/// bytes, in the order of the names.
fn side_files(session_dir: &Path) -> Vec<(String, u64)> {
    let mut files: Vec<(String, u64)> = fs::read_dir(session_dir)
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let length = entry.metadata().ok()?.len();
            (name.ends_with("-wal") || name.ends_with("-shm")).then_some((name, length))
        })
        .collect();
    files.sort();
    files
}

/// One run of the rollback check with no end time over the state root
/// `state`: its exit code, its stdout as JSON (null when it is not JSON)
/// and its stderr.
fn rollback_check(folder: &Path, state: &Path) -> (Option<i32>, Value, String) {
    let output = the_executable(folder)
        .args(["__store-schemas", "--stored"])
        .env("CMUX_TUI_STATE_DIR", state)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let answer = serde_json::from_str(stdout.trim()).unwrap_or(Value::Null);
    (output.status.code(), answer, String::from_utf8_lossy(&output.stderr).trim().to_string())
}

/// The control: the 2 calls of the reset command with no check between them
/// do the reset, and the session's folder is gone. It makes each call that
/// the row after it makes, but the check.
#[test]
fn the_reset_command_does_the_reset_with_nothing_between_its_two_calls() {
    let session = "reset-row-with-no-check";
    let (folder, state) = a_state_root_with_a_closed_session(session);
    let (session_dir, confirmation) = first_call(folder.path(), &state, session);
    let before = side_files(&session_dir);
    the_folder_is_at_rest(folder.path(), &state, session, &confirmation);
    let after = side_files(&session_dir);
    let reset = second_call(folder.path(), &state, session, &confirmation);
    assert!(
        reset.status.success() && !session_dir.exists(),
        "the reset is not done; the session's folder is there: {}; -wal and -shm files in it \
         with their lengths after the first call: {before:?}, before the second call: \
         {after:?}; the second call: {}",
        session_dir.exists(),
        text_of(&reset)
    );
}

/// One run of the rollback check between the 2 calls of the reset command.
/// The check reads the session's store and gives its number. The person
/// then makes the second call with the text of the first call, and the
/// reset must be done: the session's folder is gone.
#[test]
fn the_reset_command_does_the_reset_after_a_rollback_check_between_its_two_calls() {
    let session = "reset-row-after-a-check";
    let (folder, state) = a_state_root_with_a_closed_session(session);
    let (session_dir, confirmation) = first_call(folder.path(), &state, session);
    the_folder_is_at_rest(folder.path(), &state, session, &confirmation);
    let before = side_files(&session_dir);
    let (code, answer, stderr) = rollback_check(folder.path(), &state);
    assert_eq!(code, Some(0), "the check: {answer}, stderr: {stderr}");
    assert!(
        answer.get("workspace_registry").is_some_and(Value::is_i64),
        "the check gave no number of the registry: {answer}, stderr: {stderr}"
    );
    let after = side_files(&session_dir);
    let reset = second_call(folder.path(), &state, session, &confirmation);
    assert!(
        reset.status.success() && !session_dir.exists(),
        "the reset is not done after a rollback check; the session's folder is there: {}; \
         -wal and -shm files in it with their lengths before the check: {before:?}, after the \
         check: {after:?}; the second call: {}",
        session_dir.exists(),
        text_of(&reset)
    );
}
