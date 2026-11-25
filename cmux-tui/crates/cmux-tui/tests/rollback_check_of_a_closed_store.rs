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
//! The last 3 rows are for a registry at the number 16: its journal has
//! subject rows due. For a session that no daemon owns, the check takes the
//! session's guard and writes those rows itself. That guard has the name of
//! the session's folder, so the check must not write through a link: a
//! store name or a session folder that is a link names a file of another
//! folder. And a folder that a session reset left has no guard: its 16
//! counts as 15 with no write.
//!
//! No row here measures a time, and no row waits. A row that needs a store
//! file with an old time or with a time ahead sets that time. Each call gets
//! its config file and its log file in the test folder, and each reset call
//! gets its runtime folder there too.

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

/// The folder in the test folder `folder` that a reset call of a row gets as
/// its runtime folder.
fn the_runtime_folder(folder: &Path) -> PathBuf {
    folder.join("run")
}

/// A test folder and its state root, with the saved state of the session
/// `session` and no process that has its store open: the registry is opened
/// one time and closed again, as a daemon that stopped leaves it. The time
/// of the last write of the registry's file is long ago, as it is for a
/// daemon that stopped some time before.
///
/// The test folder is in `/tmp`, so its name is short. A reset that is done
/// drops the queue of hook events of its session, and that queue is next to
/// the session's socket in the runtime folder. A socket name that is too
/// long for a unix socket is put in a folder that each session of the
/// machine's user shares. So each reset call of a row gets a runtime folder
/// in the test folder, and the socket name of `session` there must be short
/// enough to stay in it: then no call of a row can reach a file of a session
/// that is not its own.
fn a_state_root_with_a_closed_session(session: &str) -> (tempfile::TempDir, PathBuf) {
    let folder = tempfile::tempdir_in("/tmp").unwrap();
    let runtime = the_runtime_folder(folder.path());
    let socket =
        cmux_tui_core::server::try_default_socket_path_in_base_scoped(session, &runtime, None)
            .unwrap();
    assert!(
        socket.starts_with(&runtime),
        "the socket of the row's session is not in the test folder: {}",
        socket.display()
    );
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
/// the state root `state`. Its runtime folder is in `folder`, with no
/// runtime scope of the process that runs the rows.
fn reset_command(folder: &Path, state: &Path, session: &str, more: &[&str]) -> Output {
    the_executable(folder)
        .env("XDG_RUNTIME_DIR", the_runtime_folder(folder))
        .env_remove("CMUX_TUI_RUNTIME_SCOPE")
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

/// A connection to the store with the name `name`, open, after it wrote the
/// number 9 with no checkpoint. `file` is the store's file, made by
/// [`a_closed_store_at_rest`] with the number 5; `name` is `file` or a link
/// to it. After the write the number 9 is in the `-wal` file next to `file`
/// only: `file` still holds the number 5, with its time of the last write
/// long ago, and a read that does not look at the `-wal` file gives 5. This
/// shows each of these.
fn a_connection_with_the_number_9_in_the_wal_file_only(name: &Path, file: &Path) -> Connection {
    let store = Connection::open(name).unwrap();
    store.execute("UPDATE meta SET value = '9' WHERE key = 'schema_version'", []).unwrap();
    assert_eq!(
        fs::metadata(file).unwrap().modified().unwrap(),
        long_ago(),
        "the write of the row changed the time of the store file"
    );
    let mut wal = file.as_os_str().to_os_string();
    wal.push("-wal");
    let wal_bytes = fs::metadata(&wal).map_or(0, |wal| wal.len());
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
    store
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
    let store = a_connection_with_the_number_9_in_the_wal_file_only(&file, &file);
    let (code, answer, stderr) = rollback_check(folder.path(), &state);
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "workspace_registry": 9 })),
        "the check did not give the number that is in the -wal file; stderr: {stderr}"
    );
    drop(store);
}

/// The store's name in the session folder is a link to a store file in
/// another folder. SQLite follows the link and keeps the `-wal` file next to
/// the file that the link names, so the session folder has the link and no
/// side file. Here the row holds a connection open through the link, as a
/// daemon does, and writes the number 9 with no checkpoint: the number 9 is
/// only in the `-wal` file in the other folder, and the file that the link
/// names still holds the number 5, with its time of the last write long ago.
/// A check that looks for the `-wal` file next to the link sees none and
/// gives 5. The check must give 9.
#[test]
fn the_check_of_a_store_file_that_is_a_link_gives_a_number_that_is_only_in_the_wal_file() {
    let folder = tempfile::tempdir().unwrap();
    let state = folder.path().join("sessions");
    let file = a_closed_store_at_rest(&folder.path().join("kept"), 5).join(REGISTRY_FILE);
    let session = state.join("session-0");
    fs::create_dir_all(&session).unwrap();
    let link = session.join(REGISTRY_FILE);
    std::os::unix::fs::symlink(&file, &link).unwrap();
    let store = a_connection_with_the_number_9_in_the_wal_file_only(&link, &file);
    let in_the_session_folder: Vec<String> = fs::read_dir(&session)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    assert!(
        in_the_session_folder == [REGISTRY_FILE]
            && fs::symlink_metadata(&link).unwrap().file_type().is_symlink(),
        "the session folder does not have the link and nothing more: {in_the_session_folder:?}"
    );
    let (code, answer, stderr) = rollback_check(folder.path(), &state);
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "workspace_registry": 9 })),
        "the check of a store file that is a link did not give the number that is in the -wal \
         file; stderr: {stderr}"
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

/// The number of a registry whose journal has subject rows due. For a
/// session that no daemon owns, the check takes the session's guard and
/// writes those rows itself: the store then holds the number 15.
const ROWS_DUE: i64 = 16;

/// Words of the error that the check gives when its look at the 2 names (the
/// session's folder and the store) finds a link, before it asks a guard. No
/// other error of the check has these words.
const THE_WORDS_OF_THE_LOOK: &str = "the store or its session folder is reached through a link";

/// A name that the reset command gives the folder of a session before it
/// deletes it: the exact form, with the kind and a UUID of version 4.
const LEFT_BY_A_RESET: &str =
    ".reset-session-7-session-6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f.deleting";

/// A test folder, its state root and the folder of its one session. The
/// session is closed, as [`a_state_root_with_a_closed_session`] makes it,
/// and its registry holds the number 16 and is at rest: it has no side file,
/// and the time of the last write of its file is long ago. The 2 lock files
/// of the session's guard are in the state root: the open of the session
/// made them and its close left them. So the check can ask the guard, and it
/// finds no owner.
fn a_state_root_with_a_closed_session_at_16(
    session: &str,
) -> (tempfile::TempDir, PathBuf, PathBuf) {
    let (folder, state) = a_state_root_with_a_closed_session(session);
    let file = the_registry_file(&state);
    let session_dir = file.parent().unwrap().to_path_buf();
    let store = Connection::open(&file).unwrap();
    let rows = store
        .execute("UPDATE meta SET value = ?1 WHERE key = 'schema_version'", [ROWS_DUE.to_string()])
        .unwrap();
    drop(store);
    assert_eq!(rows, 1, "the registry of the closed session has no stored schema number");
    let files = side_files(&session_dir);
    assert!(files.is_empty(), "the closed registry at 16 has a side file: {files:?}");
    set_written(&file, long_ago());
    let locks = state.join("session-locks");
    let mut guard = session_dir.file_name().unwrap().to_os_string();
    guard.push(".lock");
    for lock in [locks.join(guard), locks.join(".coordinator.lock")] {
        assert!(lock.is_file(), "the lock file {} is not there", lock.display());
    }
    (folder, state, session_dir)
}

/// The time of the last write of the store file `file`, in seconds and
/// nanoseconds, and each file of its folder with its length, in the order of
/// the names.
fn the_time_and_the_folder_of(file: &Path) -> ((i64, i64), Vec<(String, u64)>) {
    let store = fs::metadata(file).unwrap();
    let files = files_with_lengths_and_times(file.parent().unwrap())
        .into_iter()
        .map(|(name, length, _, _)| (name, length))
        .collect();
    ((store.mtime(), store.mtime_nsec()), files)
}

/// One run of the rollback check over the state root `state`, whose one
/// registry holds the number 16 and is reached through a link. `name` is the
/// store's name in the session's folder, and `file` is the store file that
/// it names, in a folder that is not in the state root. The check must not
/// write through a link: it ends with exit 1, with no answer and with an
/// error that names the session's folder. After the check the store file
/// has the same bytes and the same time of the last write, and its folder
/// has the same files with the same lengths. A write that commits gives the
/// store file the number 15 and a new time.
///
/// The times of the other files are not compared: the check reads the
/// number of a store whose name is a link with a plain read, and a plain
/// read writes the `-shm` file again.
///
/// The error must be the error of the check's look at the 2 names
/// ([`THE_WORDS_OF_THE_LOOK`]). An error of the guard question or of the
/// write names the session's folder too and writes nothing, so without these
/// words such an error passes the row.
fn the_check_is_an_error_and_writes_nothing_through_the_link(
    folder: &Path,
    state: &Path,
    name: &Path,
    file: &Path,
) {
    assert_eq!(fs::canonicalize(name).unwrap(), file, "the store's name does not name the file");
    assert!(!file.starts_with(state), "the store file is in the state root: {}", file.display());
    let bytes = fs::read(file).unwrap();
    let before = the_time_and_the_folder_of(file);
    let (code, answer, stderr) = rollback_check(folder, state);
    let same_bytes = fs::read(file).unwrap() == bytes;
    assert_eq!(
        (code, answer, same_bytes, the_time_and_the_folder_of(file)),
        (Some(1), Value::Null, true, before),
        "the check of a store at 16 that is reached through a link: its exit code, its answer, \
         whether the store file has the same bytes as before, the time of the last write of the \
         store file, and each file of its folder with its length (left: after the check; \
         right: what the row wants, with the time and the files as before the check); stderr: \
         {stderr}"
    );
    let session = name.parent().unwrap().file_name().unwrap().to_string_lossy().into_owned();
    assert!(stderr.contains(&session), "the error does not name the session's folder: {stderr}");
    assert!(
        stderr.contains(THE_WORDS_OF_THE_LOOK),
        "the error is not the error of the look at the 2 names: {stderr}"
    );
}

/// The registry's name in the session's folder is a link to a store file at
/// 16 in a folder that is not in the state root. The session's guard is the
/// guard of the folder that holds the link, not of the store that the link
/// names, and SQLite follows the link for a write. The store has the 2 files
/// of a plain read, as a store that an earlier check read one time through
/// the link. The check must give an error and write nothing.
#[test]
fn the_check_of_a_store_at_16_whose_name_is_a_link_is_an_error_and_writes_nothing() {
    let (folder, state, session_dir) = a_state_root_with_a_closed_session_at_16("link-row-store");
    let name = session_dir.join(REGISTRY_FILE);
    let kept = state.parent().unwrap().join("kept");
    fs::create_dir(&kept).unwrap();
    let file = kept.join(REGISTRY_FILE);
    fs::rename(&name, &file).unwrap();
    std::os::unix::fs::symlink(&file, &name).unwrap();
    a_plain_read_leaves_its_two_files(&file);
    the_check_is_an_error_and_writes_nothing_through_the_link(folder.path(), &state, &name, &file);
}

/// The session's folder in the state root is a link to a folder that is not
/// in the state root, and the registry in that folder holds 16. The check
/// lists a folder that is a link as a session, and the guard that it can ask
/// has the name of the link. The check must give an error and write nothing.
/// The store is at rest and its name is a plain file, so the check reads its
/// number with the read that makes no file.
#[test]
fn the_check_of_a_store_at_16_whose_session_folder_is_a_link_is_an_error_and_writes_nothing() {
    let (folder, state, session_dir) = a_state_root_with_a_closed_session_at_16("link-row-folder");
    let kept = state.parent().unwrap().join("kept");
    fs::rename(&session_dir, &kept).unwrap();
    std::os::unix::fs::symlink(&kept, &session_dir).unwrap();
    let name = session_dir.join(REGISTRY_FILE);
    let file = kept.join(REGISTRY_FILE);
    the_check_is_an_error_and_writes_nothing_through_the_link(folder.path(), &state, &name, &file);
}

/// A session reset renames the session's folder to a name of its own, then
/// deletes it. A reset that did not end leaves that folder in the state
/// root, and no guard file has its name. Here such a folder holds a registry
/// at 16, next to a session at 14. The check reads the folder and counts its
/// 16 as 15, with no guard question and no write: it gives 15 and changes no
/// file of the 2 folders. A check that does not read the folder gives 14,
/// and a check that asks the guard for it ends with an error.
#[test]
fn the_check_of_a_store_at_16_in_a_folder_that_a_reset_left_gives_15_and_writes_nothing() {
    let folder = tempfile::tempdir().unwrap();
    let state = folder.path().join("sessions");
    let session = a_closed_store_at_rest(&state, 14);
    let left = state.join(LEFT_BY_A_RESET);
    fs::rename(a_closed_store_at_rest(&folder.path().join("made"), ROWS_DUE), &left).unwrap();
    let before = (files_with_lengths_and_times(&session), files_with_lengths_and_times(&left));
    let (code, answer, stderr) = rollback_check(folder.path(), &state);
    let after = (files_with_lengths_and_times(&session), files_with_lengths_and_times(&left));
    assert_eq!(
        (code, answer),
        (Some(0), json!({ "workspace_registry": 15 })),
        "the check of a folder that a reset left with a store at 16, next to a session at 14; \
         stderr: {stderr}"
    );
    assert_eq!(
        before, after,
        "the check changed a file; each file of the session's folder and of the folder that the \
         reset left, with its length and its time of the last write, before the check (left) \
         and after it (right)"
    );
}
