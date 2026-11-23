//! The rollback check (`cmux-tui __store-schemas --stored`) over a store that
//! no process has open, through the real executable.
//!
//! The check reads the stored schema number of each store of each session
//! folder. The store of a session with no daemon is a closed store in WAL
//! mode. A plain read of such a store makes a `-wal` file and a `-shm` file
//! in the session's folder and leaves them, and a second read writes the
//! `-shm` file again. The check must not do that: it must leave the folder of
//! a closed store as it found it.
//!
//! The first 4 rows show why, with the reset command (`cmux session NAME
//! reset-state`). That command works in 2 calls. The first call changes
//! nothing and gives a confirmation text that stands for each file in the
//! session's folder. The second call, with `--force` and that text, does the
//! reset only when the folder is still as the text says. So a check that
//! changes the folder between the 2 calls makes the second call refuse: the
//! person did what the first call said and gets an error. Each of these rows
//! makes the first call 2 times and wants the same text from both: that says
//! that the folder is at rest when no check runs. 2 of the 4 rows are for a
//! store that has the 2 files before the first call, as a store that an
//! earlier check read one time: the row makes them with a plain read of its
//! own.
//!
//! The rows after them are for the conditions of the read that makes no
//! file. That read does not look at a `-wal` file, so the check uses it only
//! for a store with no `-wal` file or an empty one, with no `-journal` file,
//! and with a store file that nothing wrote for some time. For each other
//! store the check reads as it did before, and that read can make the 2
//! files.
//!
//! No row here measures a time, and no row waits. A row that needs a store
//! file with an old time or with a time ahead sets that time. Each call gets
//! its config file and its log file in the test folder.

#![cfg(any(target_os = "macos", target_os = "linux"))]

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

/// The registry's file in a session folder.
const REGISTRY_FILE: &str = "workspace-registry.sqlite3";

/// A time of the last write long before each run of a row: in the year 2017.
fn long_ago() -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(1_500_000_000)
}

/// A time of the last write ahead of each run of a row: in the year 2100.
fn far_ahead() -> SystemTime {
    UNIX_EPOCH + Duration::from_secs(4_102_444_800)
}

/// Sets the time of the last write of the file at `path` to `time`.
fn set_written(path: &Path, time: SystemTime) {
    let file = fs::File::options().write(true).open(path).unwrap();
    file.set_modified(time).unwrap();
}

/// A test folder and its state root, with the saved state of the session
/// `session` and no process that has its store open: the registry is opened
/// one time and closed again, as a daemon that stopped leaves it. The time
/// of the last write of the registry's file is long ago, as it is for a
/// daemon that stopped some time before.
fn a_state_root_with_a_closed_session(session: &str) -> (tempfile::TempDir, PathBuf) {
    let folder = tempfile::tempdir().unwrap();
    let state = fs::canonicalize(folder.path()).unwrap().join("state");
    drop(cmux_tui_core::WorkspaceRegistry::open(&state, session).unwrap());
    set_written(&the_registry_file(&state), long_ago());
    (folder, state)
}

/// The registry's file of the one session folder in the state root `state`.
fn the_registry_file(state: &Path) -> PathBuf {
    let mut files: Vec<PathBuf> = fs::read_dir(state)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.path().join(REGISTRY_FILE))
        .filter(|file| file.is_file())
        .collect();
    assert_eq!(files.len(), 1, "the state root does not have one registry file: {files:?}");
    files.pop().unwrap()
}

/// One plain read of the closed store at `file` by the row itself: a
/// read-only connection, one query, then closed. The rollback check read
/// each store that way before, so a store that it read one time has the 2
/// files that such a read leaves: a `-wal` file of 0 bytes and a `-shm`
/// file. The 2 files must be there after the read, and no other side file.
/// Then the time of the last write of the store file and of the 2 files is
/// set to long ago, so a later write of one of them shows.
fn a_plain_read_leaves_its_two_files(file: &Path) {
    let session_dir = file.parent().unwrap();
    let store = Connection::open_with_flags(
        file,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    let tables: i64 =
        store.query_row("SELECT count(*) FROM sqlite_master", [], |row| row.get(0)).unwrap();
    drop(store);
    assert!(tables > 0, "the store at {} has no table", file.display());
    let shm = format!("{REGISTRY_FILE}-shm");
    let wal = format!("{REGISTRY_FILE}-wal");
    let files = side_files(session_dir);
    assert!(
        files.len() == 2
            && files.iter().any(|(name, length)| *name == shm && *length > 0)
            && files.iter().any(|(name, length)| *name == wal && *length == 0),
        "the plain read of the row did not leave a -shm file and a -wal file of 0 bytes: {files:?}"
    );
    for written in [file.to_path_buf(), session_dir.join(shm), session_dir.join(wal)] {
        set_written(&written, long_ago());
    }
}

/// Each file in `session_dir` with its length in bytes and its time of the
/// last write in seconds and nanoseconds, in the order of the names.
fn files_with_lengths_and_times(session_dir: &Path) -> Vec<(String, u64, i64, i64)> {
    let mut files: Vec<(String, u64, i64, i64)> = fs::read_dir(session_dir)
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let file = entry.metadata().ok()?;
            Some((name, file.len(), file.mtime(), file.mtime_nsec()))
        })
        .collect();
    files.sort();
    files
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

/// The `-wal`, `-shm` and `-journal` files in `session_dir`, each with its
/// length in bytes, in the order of the names.
fn side_files(session_dir: &Path) -> Vec<(String, u64)> {
    let mut files: Vec<(String, u64)> = fs::read_dir(session_dir)
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let length = entry.metadata().ok()?.len();
            let side =
                name.ends_with("-wal") || name.ends_with("-shm") || name.ends_with("-journal");
            side.then_some((name, length))
        })
        .collect();
    files.sort();
    files
}

/// The length and the time of the last write of the registry's `-shm` file
/// in `session_dir`, for a text; `not there` when the folder has none.
fn text_of_shm(session_dir: &Path) -> String {
    fs::metadata(session_dir.join(format!("{REGISTRY_FILE}-shm"))).map_or_else(
        |_| "not there".to_string(),
        |file| {
            format!(
                "length {} time of the last write {}.{:09}",
                file.len(),
                file.mtime(),
                file.mtime_nsec()
            )
        },
    )
}

/// The rollback check with no end time over the state root `state`, not
/// yet run.
fn check_command(folder: &Path, state: &Path) -> Command {
    let mut command = the_executable(folder);
    command.args(["__store-schemas", "--stored"]).env("CMUX_TUI_STATE_DIR", state);
    command
}

/// One run of `check`: its exit code, its stdout as JSON (null when it is
/// not JSON) and its stderr.
fn answer_of(check: &mut Command) -> (Option<i32>, Value, String) {
    let output = check.output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let answer = serde_json::from_str(stdout.trim()).unwrap_or(Value::Null);
    (output.status.code(), answer, String::from_utf8_lossy(&output.stderr).trim().to_string())
}

/// One run of the rollback check with no end time over the state root
/// `state`, as [`answer_of`] gives it.
fn rollback_check(folder: &Path, state: &Path) -> (Option<i32>, Value, String) {
    answer_of(&mut check_command(folder, state))
}

/// One run of the rollback check that must end with exit 0 and with a number
/// for the registry.
fn a_rollback_check_that_gives_the_number(folder: &Path, state: &Path) {
    let (code, answer, stderr) = rollback_check(folder, state);
    assert_eq!(code, Some(0), "the check: {answer}, stderr: {stderr}");
    assert!(
        answer.get("workspace_registry").is_some_and(Value::is_i64),
        "the check gave no number of the registry: {answer}, stderr: {stderr}"
    );
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
        "the reset is not done; the session's folder is there: {}; side files in it with their \
         lengths after the first call: {before:?}, before the second call: {after:?}; the second \
         call: {}",
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
    a_rollback_check_that_gives_the_number(folder.path(), &state);
    let after = side_files(&session_dir);
    let reset = second_call(folder.path(), &state, session, &confirmation);
    assert!(
        reset.status.success() && !session_dir.exists(),
        "the reset is not done after a rollback check; the session's folder is there: {}; side \
         files in it with their lengths before the check: {before:?}, after the check: \
         {after:?}; the second call: {}",
        session_dir.exists(),
        text_of(&reset)
    );
}

/// The control of the row after it: the store has the 2 files of a plain
/// read before the first call, and no check runs between the 2 calls. The 2
/// files are in the confirmation text, nothing changes them, and the reset
/// is done.
#[test]
fn the_reset_command_does_the_reset_of_a_store_that_has_the_two_files_of_a_plain_read() {
    let session = "reset-row-with-the-two-files";
    let (folder, state) = a_state_root_with_a_closed_session(session);
    a_plain_read_leaves_its_two_files(&the_registry_file(&state));
    let (session_dir, confirmation) = first_call(folder.path(), &state, session);
    the_folder_is_at_rest(folder.path(), &state, session, &confirmation);
    let files = side_files(&session_dir);
    let shm = text_of_shm(&session_dir);
    let reset = second_call(folder.path(), &state, session, &confirmation);
    assert!(
        reset.status.success() && !session_dir.exists(),
        "the reset is not done; the session's folder is there: {}; side files in it with their \
         lengths before the second call: {files:?}; the -shm file: {shm}; the second call: {}",
        session_dir.exists(),
        text_of(&reset)
    );
}

/// The store has the 2 files of a plain read before the first call, as a
/// store that an earlier rollback check read one time. One run of the check
/// reads it between the 2 calls. The reset must be done all the same: the
/// check must not write the 2 files again. When the row is red, its text
/// gives the side files, and the length and the time of the last write of
/// the `-shm` file, directly before the check and directly after it.
#[test]
fn the_reset_command_does_the_reset_after_a_rollback_check_of_a_store_that_has_the_two_files() {
    let session = "reset-row-after-a-check-with-the-two-files";
    let (folder, state) = a_state_root_with_a_closed_session(session);
    a_plain_read_leaves_its_two_files(&the_registry_file(&state));
    let (session_dir, confirmation) = first_call(folder.path(), &state, session);
    the_folder_is_at_rest(folder.path(), &state, session, &confirmation);
    let before = side_files(&session_dir);
    let shm_before = text_of_shm(&session_dir);
    a_rollback_check_that_gives_the_number(folder.path(), &state);
    let shm_after = text_of_shm(&session_dir);
    let after = side_files(&session_dir);
    let reset = second_call(folder.path(), &state, session, &confirmation);
    assert!(
        reset.status.success() && !session_dir.exists(),
        "the reset is not done after a rollback check of a store with the 2 files; the session's \
         folder is there: {}; side files in it with their lengths before the check: {before:?}, \
         after the check: {after:?}; the -shm file before the check: {shm_before}; after the \
         check: {shm_after}; the second call: {}",
        session_dir.exists(),
        text_of(&reset)
    );
}

/// A session folder `session-0` in the state root `state`, with a registry
/// file in WAL mode whose stored schema number is `number`. The store is
/// closed: no connection to it is open. The time of the last write of its
/// file is long ago. This gives the session folder.
fn a_closed_store_at_rest(state: &Path, number: i64) -> PathBuf {
    let session = state.join("session-0");
    fs::create_dir_all(&session).unwrap();
    let file = session.join(REGISTRY_FILE);
    let store = Connection::open(&file).unwrap();
    let mode: String = store.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0)).unwrap();
    assert_eq!(mode, "wal");
    store
        .execute_batch(&format!(
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO meta (key, value) VALUES ('schema_version', '{number}');"
        ))
        .unwrap();
    drop(store);
    set_written(&file, long_ago());
    session
}

/// One run of `check` over a state root whose one session folder is
/// `session`: the check must give `number` for the registry, and the folder
/// must have no side file before the check and none after it.
fn the_check_gives_the_number_and_makes_no_file(mut check: Command, session: &Path, number: i64) {
    let before = side_files(session);
    let (code, answer, stderr) = answer_of(&mut check);
    let after = side_files(session);
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "workspace_registry": number })),
        "the check gave another answer; stderr: {stderr}"
    );
    assert!(
        before.is_empty() && after.is_empty(),
        "the folder of the closed store has a side file; before the check: {before:?}, after \
         the check: {after:?}"
    );
}

/// A store file whose time of the last write is ahead of the clock is not at
/// rest: something can write it now. The check reads it as it did before,
/// and that read leaves the `-shm` file and the `-wal` file. This row pins
/// that the read that makes no file is not for each store.
#[test]
fn the_check_of_a_store_with_a_time_that_is_ahead_reads_it_as_before() {
    let folder = tempfile::tempdir().unwrap();
    let state = folder.path().join("sessions");
    let session = a_closed_store_at_rest(&state, 7);
    set_written(&session.join(REGISTRY_FILE), far_ahead());
    let (code, answer, stderr) = rollback_check(folder.path(), &state);
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "workspace_registry": 7 })),
        "the check gave another answer; stderr: {stderr}"
    );
    let names: Vec<String> = side_files(&session).into_iter().map(|(name, _)| name).collect();
    assert_eq!(
        names,
        [format!("{REGISTRY_FILE}-shm"), format!("{REGISTRY_FILE}-wal")],
        "the read of a store that is not at rest did not leave the 2 files"
    );
}

/// A closed store at rest that has the 2 files of a plain read, as a store
/// that an earlier rollback check read one time. The check gives the number
/// and leaves the folder as it found it: no new file, and the same length
/// and the same time of the last write for the store file, the `-shm` file
/// and the `-wal` file. When the row is red, its text gives each file with
/// its length and its time before the check and after it.
#[test]
fn the_check_of_a_store_that_has_the_two_files_of_a_plain_read_changes_no_file() {
    let folder = tempfile::tempdir().unwrap();
    let state = folder.path().join("sessions");
    let session = a_closed_store_at_rest(&state, 7);
    a_plain_read_leaves_its_two_files(&session.join(REGISTRY_FILE));
    let before = files_with_lengths_and_times(&session);
    let (code, answer, stderr) = rollback_check(folder.path(), &state);
    let after = files_with_lengths_and_times(&session);
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "workspace_registry": 7 })),
        "the check gave another answer; stderr: {stderr}"
    );
    assert_eq!(
        before, after,
        "the check changed the folder of the closed store; each file with its length and its \
         time of the last write, before the check (left) and after it (right)"
    );
}

/// A closed store at rest with an empty `-journal` file next to it. A
/// `-journal` file is the sign of a write in the other journal mode, so the
/// check does not use the read that makes no file: it reads the store as it
/// did before. That read leaves the `-shm` file and the `-wal` file, and
/// that is what shows it here.
#[test]
fn the_check_of_a_store_with_an_empty_journal_file_reads_it_as_before() {
    let folder = tempfile::tempdir().unwrap();
    let state = folder.path().join("sessions");
    let session = a_closed_store_at_rest(&state, 7);
    fs::write(session.join(format!("{REGISTRY_FILE}-journal")), "").unwrap();
    let (code, answer, stderr) = rollback_check(folder.path(), &state);
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "workspace_registry": 7 })),
        "the check gave another answer; stderr: {stderr}"
    );
    let files = side_files(&session);
    let has = |tail: &str| files.iter().any(|(name, _)| *name == format!("{REGISTRY_FILE}{tail}"));
    assert!(
        has("-shm") && has("-wal"),
        "the read of a store with a -journal file did not leave the 2 files: {files:?}"
    );
}

/// A store that a process has open can hold its newest number in the `-wal`
/// file only. Here the row holds a connection open, as a daemon does, and
/// writes the number 9 with no checkpoint: the store file still holds the
/// number 5, and its time of the last write is long ago. A read that does
/// not look at the `-wal` file gives 5, and the row shows that first. The
/// check must give 9.
#[test]
fn the_check_gives_a_number_that_is_only_in_the_wal_file() {
    let folder = tempfile::tempdir().unwrap();
    let state = folder.path().join("sessions");
    let session = a_closed_store_at_rest(&state, 5);
    let file = session.join(REGISTRY_FILE);
    let store = Connection::open(&file).unwrap();
    store.execute("UPDATE meta SET value = '9' WHERE key = 'schema_version'", []).unwrap();
    assert_eq!(
        fs::metadata(&file).unwrap().modified().unwrap(),
        long_ago(),
        "the write of the row changed the time of the store file"
    );
    let wal_bytes =
        fs::metadata(session.join(format!("{REGISTRY_FILE}-wal"))).map_or(0, |wal| wal.len());
    assert!(wal_bytes > 0, "the write of the row is not in a -wal file with bytes");
    let no_wal = Connection::open_with_flags(
        format!("file://{}?immutable=1", file.display()),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
    .unwrap();
    let in_the_file: String = no_wal
        .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| row.get(0))
        .unwrap();
    drop(no_wal);
    assert_eq!(in_the_file, "5", "the store file holds the new number: it is not in the -wal only");
    let (code, answer, stderr) = rollback_check(folder.path(), &state);
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "workspace_registry": 9 })),
        "the check did not give the number that is in the -wal file; stderr: {stderr}"
    );
    drop(store);
}

/// A state root whose name has a `?`, a `#`, a `%` with 2 hex digits after
/// it, a space and a letter that is not ASCII. Each of them has a meaning in
/// a file URI or cannot be in one as it is.
#[test]
fn the_check_of_a_state_root_with_uri_characters_gives_the_number_and_makes_no_file() {
    let folder = tempfile::tempdir().unwrap();
    let state = folder.path().join("state ?#%41 \u{e9}");
    let session = a_closed_store_at_rest(&state, 7);
    let check = check_command(folder.path(), &state);
    the_check_gives_the_number_and_makes_no_file(check, &session, 7);
}

/// A state root whose name is not UTF-8. A file system of macOS can refuse
/// such a name, so this row is for Linux only.
#[cfg(target_os = "linux")]
#[test]
fn the_check_of_a_state_root_whose_name_is_not_utf8_gives_the_number_and_makes_no_file() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;
    let folder = tempfile::tempdir().unwrap();
    let state = folder.path().join(OsStr::from_bytes(b"state-\xff\xfe"));
    let session = a_closed_store_at_rest(&state, 7);
    let check = check_command(folder.path(), &state);
    the_check_gives_the_number_and_makes_no_file(check, &session, 7);
}

/// A state root that is not absolute: the check gets the name `sessions`
/// and runs with the test folder as its working folder.
#[test]
fn the_check_of_a_relative_state_root_gives_the_number_and_makes_no_file() {
    let folder = tempfile::tempdir().unwrap();
    let session = a_closed_store_at_rest(&folder.path().join("sessions"), 7);
    let mut check = check_command(folder.path(), Path::new("sessions"));
    check.current_dir(folder.path());
    the_check_gives_the_number_and_makes_no_file(check, &session, 7);
}

/// A store file that is no SQLite file, with a time of the last write long
/// ago. The check ends with exit 1, with no answer and with the error of
/// SQLite, and it makes no side file.
#[test]
fn the_check_of_a_file_that_is_no_store_answers_as_before() {
    let folder = tempfile::tempdir().unwrap();
    let state = folder.path().join("sessions");
    let session = state.join("session-0");
    fs::create_dir_all(&session).unwrap();
    let file = session.join(REGISTRY_FILE);
    fs::write(&file, "this is no store\n".repeat(64)).unwrap();
    set_written(&file, long_ago());
    let (code, answer, stderr) = rollback_check(folder.path(), &state);
    assert_eq!((code, answer), (Some(1), Value::Null), "stderr: {stderr}");
    assert!(stderr.contains("file is not a database"), "stderr: {stderr}");
    let files = side_files(&session);
    assert!(files.is_empty(), "the check of a file that is no store made a side file: {files:?}");
}
