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
//!
//! No row here measures a time. 5 rows call the check's functions of
//! cmux-tui-core directly. 2 of them use an end time that is past or far
//! ahead and the text of `--within-ms`: the executable cannot show those
//! with no wait. 3 of them use a first call that started 1 hour ahead of the
//! clock: for the executable each file that a row made is a file that
//! changed a moment ago, so it cannot show which session a call does not
//! read again.
//!
//! A call that starts at zero each time gains only what the file cache
//! keeps. So a caller can ask for a place (`--place ""`): the `not_ready`
//! answer then has one more part, `place`, a text that the caller gives back
//! with `--place` at its next call. That call goes on after the sessions
//! that the calls before it read. The rows on the place use an end time of
//! 0 ms, with which a call reads exactly one session that it did not read
//! before, and a last call with no end time, as the app's rule has it.

#![cfg(unix)]

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::store_schemas::{Place, Stored, stored_from, stored_until, within_of};
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
    state_root_of(&vec![number; sessions])
}

/// A test folder whose state root has one session folder for each of
/// `numbers`, with a registry file whose stored schema number is that number.
fn state_root_of(numbers: &[i64]) -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    for (index, number) in numbers.iter().enumerate() {
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
    let mut all = vec!["--stored"];
    all.extend_from_slice(arguments);
    call(folder, &all)
}

/// One run of `cmux-tui __store-schemas` with `arguments` and no other
/// argument, for the state root of `folder`: as [`check`] gives it.
fn call(folder: &Path, arguments: &[&str]) -> (Option<i32>, Value, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("__store-schemas")
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

/// A session folder `name` in the state root of `folder`, with a registry
/// file whose stored schema number is `number`.
fn session(folder: &Path, name: &str, number: i64) {
    let session = sessions_of(folder).join(name);
    fs::create_dir_all(&session).unwrap();
    let store = Connection::open(session.join(REGISTRY_FILE)).unwrap();
    store
        .execute_batch(&format!(
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO meta (key, value) VALUES ('schema_version', '{number}');"
        ))
        .unwrap();
}

/// Writes `number` as the stored schema number of the session `name`.
fn set_number(folder: &Path, name: &str, number: i64) {
    let store = Connection::open(sessions_of(folder).join(name).join(REGISTRY_FILE)).unwrap();
    let rows = store
        .execute("UPDATE meta SET value = ?1 WHERE key = 'schema_version'", [number.to_string()])
        .unwrap();
    assert_eq!(rows, 1, "the session {name} has no stored schema number");
}

/// The 2 counts of a `not_ready` answer: the sessions of the root and the
/// sessions read. `None` when the answer is not of that form.
fn counts_of(answer: &Value) -> Option<(u64, u64)> {
    let not_ready = answer.get("not_ready")?;
    Some((not_ready.get("sessions")?.as_u64()?, not_ready.get("sessions_read")?.as_u64()?))
}

/// The place of a `not_ready` answer: the text that the next call gives
/// back with `--place`.
fn place_of(answer: &Value) -> String {
    answer
        .pointer("/not_ready/place")
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("the answer has no place: {answer}"))
        .to_string()
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

/// The answer is the newest number over the sessions: not the first one, not
/// the last one, not the oldest.
#[test]
fn a_check_of_sessions_with_different_numbers_gives_the_newest() {
    let root = state_root_of(&[13, 15, 14]);
    let (code, answer, stderr) = check(root.path(), &[]);
    assert_eq!((code, answer), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");
}

/// A state root that is not there has no session: the answer is an empty
/// object, with an end time and with none.
#[test]
fn a_state_root_that_is_not_there_gives_an_empty_object() {
    let root = tempfile::tempdir().unwrap();
    let forms: [&[&str]; 2] = [&[], &["--within-ms", "0"]];
    for arguments in forms {
        let (code, answer, stderr) = check(root.path(), arguments);
        assert_eq!((code, answer), (Some(0), json!({})), "{arguments:?}, stderr: {stderr}");
    }
}

/// Each form of the arguments that is not `--stored` alone or `--stored
/// --within-ms N` with a count of milliseconds is the usage error: exit 1
/// and no answer, never a check with no end time.
#[test]
fn a_wrong_form_of_the_arguments_is_the_usage_error() {
    let root = state_root(1, 15);
    let forms: [&[&str]; 5] = [
        &["--stored", "--within-ms"],
        &["--stored", "--within-ms", "x"],
        &["--stored", "--within-ms", "-1"],
        &["--stored", "--within-ms", "5", "--within-ms", "5"],
        &["--within-ms", "5"],
    ];
    for form in forms {
        let (code, answer, stderr) = call(root.path(), form);
        assert_eq!((code, answer), (Some(1), Value::Null), "{form:?}, stderr: {stderr}");
        assert!(stderr.contains("usage: cmux-tui __store-schemas"), "{form:?}, stderr: {stderr}");
    }
}

/// `--within-ms N` is a count of milliseconds.
#[test]
fn a_within_ms_of_1500_is_1500_milliseconds() {
    assert_eq!(within_of("1500"), Some(Duration::from_millis(1500)));
    assert_eq!(within_of("0"), Some(Duration::ZERO));
    for text in ["", "x", "-1", "1.5", "5ms"] {
        assert_eq!(within_of(text), None, "{text:?}");
    }
}

/// The check's function with an end time that is past stops after the first
/// session; with an end time far ahead it reads each session.
#[test]
fn a_check_with_a_past_end_time_stops_and_one_with_a_far_end_time_reads_each_session() {
    let root = state_root(3, 15);
    let sessions = sessions_of(root.path());
    let start = Instant::now();
    assert_eq!(
        stored_until(&sessions, Some(start)).unwrap(),
        Stored::NotReady { sessions: 3, sessions_read: 1 }
    );
    let numbers = BTreeMap::from([("workspace_registry".to_string(), 15)]);
    assert_eq!(
        stored_until(&sessions, Some(start + Duration::from_secs(3600))).unwrap(),
        Stored::Schemas(numbers)
    );
}

/// A call with the place of the call before it goes on after the sessions
/// that were read: its count of sessions read is the count of all calls so
/// far, where a call with no place reads the first session again. The last
/// call has the place and no end time, and gives the numbers.
#[test]
fn a_call_with_the_place_goes_on_after_the_sessions_read_before() {
    let root = state_root(3, 15);
    let (code, first, stderr) = check(root.path(), &["--within-ms", "0", "--place", ""]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&first), Some((3, 1)), "{first}");
    let (code, second, stderr) =
        check(root.path(), &["--within-ms", "0", "--place", &place_of(&first)]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&second), Some((3, 2)), "{second}");
    let (code, last, stderr) = check(root.path(), &["--place", &place_of(&second)]);
    assert_eq!((code, last), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");
}

/// A call with a place and an end time that it does not reach gives the
/// numbers, as a call with no end time does. So does a first call that asks
/// for a place and reads each session.
#[test]
fn a_call_with_the_place_that_ends_in_its_time_gives_the_numbers() {
    let root = state_root_of(&[13, 15, 14]);
    let (code, first, stderr) = check(root.path(), &["--within-ms", "0", "--place", ""]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    let (code, answer, stderr) =
        check(root.path(), &["--within-ms", "60000", "--place", &place_of(&first)]);
    assert_eq!((code, answer), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");
    let (code, answer, stderr) = check(root.path(), &["--within-ms", "60000", "--place", ""]);
    assert_eq!((code, answer), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");
}

/// The calls of one check take longer together than one call. A store that
/// an earlier call read can get a newer number before the last call ends:
/// the call that gives the numbers reads that store again.
#[test]
fn a_store_that_changes_after_its_read_is_read_again_before_the_numbers() {
    let root = state_root_of(&[13, 14, 14]);
    let (code, first, stderr) = check(root.path(), &["--within-ms", "0", "--place", ""]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&first), Some((3, 1)), "{first}");
    set_number(root.path(), "session-0", 16);
    let (code, last, stderr) = check(root.path(), &["--place", &place_of(&first)]);
    assert_eq!((code, last), (Some(0), json!({ "workspace_registry": 16 })), "stderr: {stderr}");
}

/// A session that starts after the first call, with a name that sorts
/// before the place, is read by the call that gives the numbers.
#[test]
fn a_session_that_is_new_and_sorts_before_the_place_is_read() {
    let root = tempfile::tempdir().unwrap();
    for name in ["session-1", "session-2", "session-3"] {
        session(root.path(), name, 14);
    }
    let (code, first, stderr) = check(root.path(), &["--within-ms", "0", "--place", ""]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&first), Some((3, 1)), "{first}");
    session(root.path(), "session-0", 17);
    let (code, last, stderr) = check(root.path(), &["--place", &place_of(&first)]);
    assert_eq!((code, last), (Some(0), json!({ "workspace_registry": 17 })), "stderr: {stderr}");
}

/// A place that names a folder that is no longer there is no error: the
/// call starts at the next name. The number that an earlier call found in
/// the folder that is gone stays in the numbers: the check can refuse a
/// rollback for it, and it never lets one pass for it.
#[test]
fn a_place_that_names_a_folder_that_is_gone_starts_at_the_next_name() {
    let root = state_root_of(&[15, 13, 14]);
    let (code, first, stderr) = check(root.path(), &["--within-ms", "0", "--place", ""]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    let place = place_of(&first);
    fs::remove_dir_all(sessions_of(root.path()).join("session-0")).unwrap();
    let (code, second, stderr) = check(root.path(), &["--within-ms", "0", "--place", &place]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&second), Some((2, 1)), "{second}");
    let (code, last, stderr) = check(root.path(), &["--place", &place]);
    assert_eq!((code, last), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");
}

/// A caller that asks for no place gets the answer of before, with no part
/// more, and its next call starts at the first session again.
#[test]
fn a_call_with_no_place_answers_as_before_and_starts_at_the_first_session_again() {
    let root = state_root(3, 15);
    for turn in 1..=2 {
        let (code, answer, stderr) = check(root.path(), &["--within-ms", "0"]);
        assert_eq!(
            (code, answer),
            (Some(0), json!({ "not_ready": { "sessions": 3, "sessions_read": 1 } })),
            "call {turn}, stderr: {stderr}"
        );
    }
}

/// A place that is not a place of this check is the usage error: exit 1 and
/// no answer, never a check from the first session with what the caller
/// sent. The error does not print what the caller sent.
#[test]
fn a_wrong_form_of_the_place_is_the_usage_error_and_is_not_printed() {
    const MARK: &str = "place-mark-5d1e";
    let root = state_root(1, 15);
    let forms: [&[&str]; 7] = [
        &["--stored", "--place"],
        &["--stored", "--place", MARK],
        &["--stored", "--place", r#"{"after":"place-mark-5d1e"}"#],
        &[
            "--stored",
            "--place",
            r#"{"after":"place-mark-5d1e","found":{"workspace_registry":"x"},"since_ms":1}"#,
        ],
        &["--stored", "--place", r#"{"after":"place-mark-5d1e","found":{},"since_ms":1,"more":1}"#],
        &["--stored", "--place", "", "--within-ms", "5"],
        &["--place", ""],
    ];
    for form in forms {
        let (code, answer, stderr) = call(root.path(), form);
        assert_eq!((code, answer), (Some(1), Value::Null), "{form:?}, stderr: {stderr}");
        assert!(stderr.contains("usage: cmux-tui __store-schemas"), "{form:?}, stderr: {stderr}");
        assert!(!stderr.contains(MARK), "{form:?}, stderr: {stderr}");
    }
}

/// The place names a session folder, and a session folder's name is a
/// session's id. It goes from the check to its caller and back only: it is
/// in the answer, and it is in no line of stderr and in no file that the
/// check writes.
#[test]
fn a_place_is_in_the_answer_and_in_no_other_line_or_file_of_the_check() {
    const MARK: &str = "mark-7c2e";
    let root = tempfile::tempdir().unwrap();
    for name in ["mark-7c2e-a", "mark-7c2e-b", "mark-7c2e-c"] {
        session(root.path(), name, 15);
    }
    let (code, first, stderr) = check(root.path(), &["--within-ms", "0", "--place", ""]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    let place = place_of(&first);
    assert!(place.contains(MARK), "the place does not name the session: {place}");
    assert!(!stderr.contains(MARK), "stderr: {stderr}");
    let (code, second, stderr) = check(root.path(), &["--within-ms", "0", "--place", &place]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert!(!stderr.contains(MARK), "stderr: {stderr}");
    let (code, last, stderr) = check(root.path(), &["--place", &place_of(&second)]);
    assert_eq!((code, last), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");
    assert!(!stderr.contains(MARK), "stderr: {stderr}");
    // Each file of the test folder itself (the config and the log of the
    // calls): the session folders are below `sessions`, a folder.
    for entry in fs::read_dir(root.path()).unwrap() {
        let path = entry.unwrap().path();
        if path.is_file() {
            let text = String::from_utf8_lossy(&fs::read(&path).unwrap()).into_owned();
            assert!(!text.contains(MARK), "{} names the session", path.display());
        }
    }
}

/// The place holds the start time of the first call. A place whose start
/// time is after the start of this call is no place: the call starts at the
/// first session, with a start time of its own.
#[test]
fn a_place_whose_start_time_is_after_this_call_is_no_place() {
    const FAR: u64 = 9_000_000_000_000_000;
    let root = state_root(3, 15);
    let (code, first, stderr) = check(root.path(), &["--within-ms", "0", "--place", ""]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    let (code, second, stderr) =
        check(root.path(), &["--within-ms", "0", "--place", &place_of(&first)]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&second), Some((3, 2)), "{second}");
    let mut place: Value = serde_json::from_str(&place_of(&second)).unwrap();
    place["since_ms"] = json!(FAR);
    let (code, again, stderr) =
        check(root.path(), &["--within-ms", "0", "--place", &place.to_string()]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&again), Some((3, 1)), "{again}");
    let place: Value = serde_json::from_str(&place_of(&again)).unwrap();
    assert_eq!(place["after"], json!("session-0"), "{place}");
    assert!(place["since_ms"].as_u64().is_some_and(|since| since < FAR), "{place}");
}

/// The clock of the 3 rows below: 1 hour ahead of the wall clock, in
/// milliseconds since 1970. For a first call that started then, each file
/// that a row made is a file that did not change after it.
fn an_hour_ahead_ms() -> u64 {
    let ahead = SystemTime::now() + Duration::from_secs(3600);
    u64::try_from(ahead.duration_since(UNIX_EPOCH).unwrap().as_millis()).unwrap()
}

/// Sets the time of the last write of the file at `path` to 2 hours ahead of
/// the wall clock: after the start that [`an_hour_ahead_ms`] gives.
fn set_written_after_the_start(path: &Path) {
    let file = fs::File::options().write(true).open(path).unwrap();
    file.set_modified(SystemTime::now() + Duration::from_secs(7200)).unwrap();
}

/// The place after the session `after` of a check whose first call started
/// at `since_ms` and found `number` in the registry (`None`: no number).
fn place_at(after: &str, number: Option<i64>, since_ms: u64) -> Place {
    let found =
        number.map(|number| ("workspace_registry".to_string(), number)).into_iter().collect();
    Place { after: after.to_string(), found, since_ms }
}

/// What a call that read each session gives when the registry's newest
/// number is `number`: the numbers and no place.
fn the_number(number: i64) -> (Stored, Option<Place>) {
    (Stored::Schemas(BTreeMap::from([("workspace_registry".to_string(), number)])), None)
}

/// A session folder at or before the place whose files did not change after
/// the first call started is not read again. Its store file here is not a
/// store, and the call gives no error; its number is the number that the
/// place carries. The control: the same call with a start of 0, after which
/// each file changed, reads that file and gives the error.
#[test]
fn a_folder_at_or_before_the_place_that_did_not_change_is_not_read_again() {
    let root = state_root_of(&[13, 14]);
    let sessions = sessions_of(root.path());
    fs::write(sessions.join("session-0").join(REGISTRY_FILE), vec![b'x'; 8192]).unwrap();
    let now_ms = an_hour_ahead_ms();
    let from = place_at("session-0", Some(16), now_ms);
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(16));
    let from = place_at("session-0", Some(16), 0);
    assert!(stored_from(&sessions, None, Some(&from), now_ms).is_err());
}

/// A store whose file was written after the first call started is read
/// again. Before that write the call does not read it: the number 17 of the
/// session at the place is not in the answer.
#[test]
fn a_store_whose_file_time_is_after_the_start_time_is_read_again() {
    let root = state_root_of(&[17, 14]);
    let sessions = sessions_of(root.path());
    let now_ms = an_hour_ahead_ms();
    let from = place_at("session-0", None, now_ms);
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(14));
    set_written_after_the_start(&sessions.join("session-0").join(REGISTRY_FILE));
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(17));
}

/// Each store of the daemon is in WAL mode: a write goes to the store's
/// `-wal` file, and the store file can keep its time. So the check looks at
/// the time of the `-wal` file too. Here the store is in WAL mode and is
/// held open, as the daemon holds it, and the write of the number 17 is
/// after that.
#[test]
fn a_change_that_is_in_the_wal_file_is_seen() {
    let root = state_root_of(&[13, 14]);
    let sessions = sessions_of(root.path());
    let store_file = sessions.join("session-0").join(REGISTRY_FILE);
    let store = Connection::open(&store_file).unwrap();
    let mode: String = store.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0)).unwrap();
    assert_eq!(mode, "wal");
    store.execute("UPDATE meta SET value = '17' WHERE key = 'schema_version'", []).unwrap();
    let wal = sessions.join("session-0").join(format!("{REGISTRY_FILE}-wal"));
    assert!(wal.is_file(), "the store has no -wal file");
    let now_ms = an_hour_ahead_ms();
    let from = place_at("session-0", None, now_ms);
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(14));
    set_written_after_the_start(&wal);
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(17));
    drop(store);
}
