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
//! No row here measures a time, and no row waits. 16 rows call only the
//! check's functions of cmux-tui-core. 2 of them use an end time that is
//! past or far ahead and the text of `--within-ms`: the executable cannot
//! show those with no wait. 14 of them use a first call that started 1 hour
//! ahead of the clock: for the executable each file that a row made is a
//! file that changed a moment ago, so it cannot show which session a call
//! does not read again. Where such a row needs a file that changed after
//! that start, it sets the file's time of the last write to 2 hours ahead.
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

use cmux_tui_core::store_schemas::{
    Pass, Place, Stored, root_part, stored_from, stored_until, within_of,
};
use rusqlite::Connection;
use serde_json::{Value, json};

/// The registry's file in a session folder.
const REGISTRY_FILE: &str = "workspace-registry.sqlite3";

/// The file of the conversation store in a session folder.
const CONVERSATIONS_FILE: &str = "conversations.sqlite3";

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

/// The clock of the 14 rows below: 1 hour ahead of the wall clock, in
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

/// [`set_written_after_the_start`] for a folder, which cannot be opened for
/// a write.
fn set_folder_written_after_the_start(folder: &Path) {
    let folder = fs::File::open(folder).unwrap();
    folder.set_modified(SystemTime::now() + Duration::from_secs(7200)).unwrap();
}

/// The place after the session `after` of a check of the state root
/// `sessions` whose first call started at `since_ms` and found `number` in
/// the registry (`None`: no number). No pass stopped yet.
fn place_at(sessions: &Path, after: &str, number: Option<i64>, since_ms: u64) -> Place {
    let found =
        number.map(|number| ("workspace_registry".to_string(), number)).into_iter().collect();
    let root = root_part(sessions).unwrap();
    Place { root, after: after.to_string(), found, since_ms, pass: None }
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
    let from = place_at(&sessions, "session-0", Some(16), now_ms);
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(16));
    let from = place_at(&sessions, "session-0", Some(16), 0);
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
    let from = place_at(&sessions, "session-0", None, now_ms);
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(14));
    set_written_after_the_start(&sessions.join("session-0").join(REGISTRY_FILE));
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(17));
}

/// A session can get its second store after the check read its folder. The
/// check looks at the times of each store file that a folder at or before
/// the place has now, so a store file that is new there makes the check
/// read the folder again: the number 9 of the new store is in the answer.
#[test]
fn a_store_file_that_is_new_in_a_folder_at_or_before_the_place_is_read() {
    let root = state_root_of(&[13, 14]);
    let sessions = sessions_of(root.path());
    let now_ms = an_hour_ahead_ms();
    let from = place_at(&sessions, "session-0", None, now_ms);
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(14));
    let new_store = sessions.join("session-0").join(CONVERSATIONS_FILE);
    let store = Connection::open(&new_store).unwrap();
    store
        .execute_batch(
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO meta (key, value) VALUES ('schema_version', '9');",
        )
        .unwrap();
    drop(store);
    set_written_after_the_start(&new_store);
    let numbers = BTreeMap::from([
        ("conversation_store".to_string(), 9),
        ("workspace_registry".to_string(), 14),
    ]);
    assert_eq!(
        stored_from(&sessions, None, Some(&from), now_ms).unwrap(),
        (Stored::Schemas(numbers), None)
    );
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
    let store = Connection::open(sessions.join("session-0").join(REGISTRY_FILE)).unwrap();
    let mode: String = store.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0)).unwrap();
    assert_eq!(mode, "wal");
    store.execute("UPDATE meta SET value = '17' WHERE key = 'schema_version'", []).unwrap();
    let wal = sessions.join("session-0").join(format!("{REGISTRY_FILE}-wal"));
    assert!(wal.is_file(), "the store has no -wal file");
    let now_ms = an_hour_ahead_ms();
    let from = place_at(&sessions, "session-0", None, now_ms);
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(14));
    set_written_after_the_start(&wal);
    assert_eq!(stored_from(&sessions, None, Some(&from), now_ms).unwrap(), the_number(17));
    drop(store);
}

/// The name of a store in a session folder can be a link to a store file in
/// another folder. SQLite then keeps the `-wal` file next to the target of
/// the link, not next to the link, and a write changes no time of the target
/// before a checkpoint. A write through the link after the call that read
/// the session must be seen all the same. Here the first call has an end
/// time that is past: it reads the session with the link, whose number is
/// 13, and stops with the place. Then the row sets the target's time of the
/// last write to long ago, and a connection through the link writes 17 and
/// stays open: the number is only in the `-wal` file next to the target, and
/// the session folder has the link and nothing more. The call with the
/// place must give 17, not the 14 of the other session.
///
/// Before that call the row gives that `-wal` file a time 2 hours ahead, as
/// the row before does for a write after the start. That time is no part of
/// the proof: the pass does not look at a `-wal` file next to the target of
/// a link, so the time changes no result. It is there for a pass that looks
/// at that file.
#[test]
fn a_change_through_a_store_name_that_is_a_link_is_seen() {
    let root = tempfile::tempdir().unwrap();
    let kept = root.path().join("kept");
    closed_wal_session(&kept, "store", 13);
    let target = sessions_of(&kept).join("store").join(REGISTRY_FILE);
    let sessions = sessions_of(root.path());
    let linked = sessions.join("session-0");
    fs::create_dir_all(&linked).unwrap();
    let link = linked.join(REGISTRY_FILE);
    std::os::unix::fs::symlink(&target, &link).unwrap();
    session(root.path(), "session-1", 14);

    let now_ms = an_hour_ahead_ms();
    let place = place_at(&sessions, "session-0", Some(13), now_ms);
    assert_eq!(
        stored_from(&sessions, Some(Instant::now()), None, now_ms).unwrap(),
        (Stored::NotReady { sessions: 2, sessions_read: 1 }, Some(place.clone())),
        "the first call did not stop after the session with the link"
    );

    let long_ago = UNIX_EPOCH + Duration::from_secs(1_500_000_000);
    fs::File::options().write(true).open(&target).unwrap().set_modified(long_ago).unwrap();
    let store = Connection::open(&link).unwrap();
    store.execute("UPDATE meta SET value = '17' WHERE key = 'schema_version'", []).unwrap();
    assert_eq!(
        fs::metadata(&target).unwrap().modified().unwrap(),
        long_ago,
        "the write of the number changed the time of the target"
    );
    let wal = sessions_of(&kept).join("store").join(format!("{REGISTRY_FILE}-wal"));
    assert!(
        fs::metadata(&wal).is_ok_and(|wal| wal.len() > 0),
        "the write of the number is not in a -wal file with bytes next to the target"
    );
    let in_the_session_folder: Vec<String> = fs::read_dir(&linked)
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    assert!(
        in_the_session_folder == [REGISTRY_FILE]
            && fs::symlink_metadata(&link).unwrap().file_type().is_symlink(),
        "the session folder does not have the link and nothing more: {in_the_session_folder:?}"
    );
    set_written_after_the_start(&wal);
    assert_eq!(
        stored_from(&sessions, None, Some(&place), now_ms).unwrap(),
        the_number(17),
        "the call with the place did not count the number that a write through the link made"
    );
    drop(store);
}

/// The name of a store's `-wal` file can be a link too. The pass follows no
/// link, so that name says nothing of a time: the session counts as written
/// and each pass reads it again. The store here is not in WAL mode and the
/// link names nothing: that is a state that SQLite can read. SQLite opens no
/// `-wal` file through a link, so the read of a store in WAL mode with such
/// a name is an error, with a pass and with none. After the first call a
/// plain write puts 17 in the store, then 19. The times of those writes are
/// before the start, 1 hour ahead: only the link makes a pass read the
/// session. Each call with the place must give the number of that moment.
#[test]
fn a_wal_name_that_is_a_link_makes_each_pass_read_the_session_again() {
    let root = state_root_of(&[13, 14]);
    let sessions = sessions_of(root.path());
    let wal = sessions.join("session-0").join(format!("{REGISTRY_FILE}-wal"));
    std::os::unix::fs::symlink(root.path().join("not-there"), &wal).unwrap();

    let now_ms = an_hour_ahead_ms();
    let place = place_at(&sessions, "session-0", Some(13), now_ms);
    assert_eq!(
        stored_from(&sessions, Some(Instant::now()), None, now_ms).unwrap(),
        (Stored::NotReady { sessions: 2, sessions_read: 1 }, Some(place.clone())),
        "the first call did not read the store whose -wal name is a link"
    );
    for number in [17, 19] {
        set_number(root.path(), "session-0", number);
        assert!(
            fs::symlink_metadata(&wal).unwrap().file_type().is_symlink() && !wal.exists(),
            "the -wal name is not a link to nothing after the write of {number}"
        );
        assert_eq!(
            stored_from(&sessions, None, Some(&place), now_ms).unwrap(),
            the_number(number),
            "a pass did not read again the session whose -wal name is a link"
        );
    }
}

/// A store's name can be a link to nothing. Such a name is no store: the
/// check reads the other store of that session and gives no error. The pass
/// follows no link, so the session counts as written and each pass reads it
/// again: the call with the place gives the numbers that a call with no
/// place gives. After that a plain write puts 12 in the other store, with
/// times before the start, 1 hour ahead: only the link makes a pass read
/// the session, and the next call with the place must give 12.
#[test]
fn a_store_name_that_is_a_link_to_nothing_is_no_error() {
    let root = tempfile::tempdir().unwrap();
    let sessions = sessions_of(root.path());
    let linked = sessions.join("session-0");
    fs::create_dir_all(&linked).unwrap();
    let other_store = linked.join(CONVERSATIONS_FILE);
    Connection::open(&other_store)
        .unwrap()
        .execute_batch(
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO meta (key, value) VALUES ('schema_version', '9');",
        )
        .unwrap();
    std::os::unix::fs::symlink(root.path().join("not-there"), linked.join(REGISTRY_FILE)).unwrap();
    session(root.path(), "session-1", 14);
    let numbers = |conversations: i64| -> (Stored, Option<Place>) {
        let numbers = BTreeMap::from([
            ("conversation_store".to_string(), conversations),
            ("workspace_registry".to_string(), 14),
        ]);
        (Stored::Schemas(numbers), None)
    };

    let now_ms = an_hour_ahead_ms();
    let place = Place {
        root: root_part(&sessions).unwrap(),
        after: "session-0".to_string(),
        found: BTreeMap::from([("conversation_store".to_string(), 9)]),
        since_ms: now_ms,
        pass: None,
    };
    assert_eq!(
        stored_from(&sessions, Some(Instant::now()), None, now_ms).unwrap(),
        (Stored::NotReady { sessions: 2, sessions_read: 1 }, Some(place.clone())),
        "the first call did not stop after the session whose store name is a link to nothing"
    );
    assert_eq!(
        stored_from(&sessions, None, None, now_ms).unwrap(),
        numbers(9),
        "the call with no place gave an error or other numbers"
    );
    assert_eq!(
        stored_from(&sessions, None, Some(&place), now_ms).unwrap(),
        numbers(9),
        "the call with the place did not give the numbers of the call with no place"
    );
    Connection::open(&other_store)
        .unwrap()
        .execute("UPDATE meta SET value = '12' WHERE key = 'schema_version'", [])
        .unwrap();
    assert_eq!(
        stored_from(&sessions, None, Some(&place), now_ms).unwrap(),
        numbers(12),
        "a pass did not read again the session whose store name is a link to nothing"
    );
}

/// A session folder `name` in the state root of `folder`, with a registry
/// file in WAL mode, as the daemon's stores are, whose stored schema number
/// is `number`. The store is closed: no connection to it is open.
fn closed_wal_session(folder: &Path, name: &str, number: i64) {
    let session = sessions_of(folder).join(name);
    fs::create_dir_all(&session).unwrap();
    let store = Connection::open(session.join(REGISTRY_FILE)).unwrap();
    let mode: String = store.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0)).unwrap();
    assert_eq!(mode, "wal");
    store
        .execute_batch(&format!(
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO meta (key, value) VALUES ('schema_version', '{number}');"
        ))
        .unwrap();
    drop(store);
}

/// For each session folder of `names` in the state root of `folder`: whether
/// its registry has a `-wal` file, and whether it has a `-shm` file.
fn side_files(folder: &Path, names: &[&str]) -> Vec<(bool, bool)> {
    names
        .iter()
        .map(|name| {
            let session = sessions_of(folder).join(name);
            (
                session.join(format!("{REGISTRY_FILE}-wal")).is_file(),
                session.join(format!("{REGISTRY_FILE}-shm")).is_file(),
            )
        })
        .collect()
}

/// What the check's own read does to the file times that a later call looks
/// at. The daemon's stores are in WAL mode, and a store that was closed has
/// no `-wal` file: the check's read of it makes one, and that changes the
/// time of the session folder. The first call here started 1 hour ahead of
/// the clock. After each call the row sets the time of each session folder,
/// and of each `-wal` file that is there, to 2 hours ahead: for the call
/// after it, that is what a read does to a store that was closed long
/// before. Each call has an end time that is past, so it stops before the
/// second store that it reads: the count of calls to the numbers is the
/// count of store reads. 3 calls for 3 stores = each store was read one
/// time. One call more = a call read again a store that nothing but the
/// check itself touched.
#[test]
fn a_check_of_closed_wal_stores_reads_each_store_one_time() {
    const NAMES: [&str; 3] = ["session-0", "session-1", "session-2"];
    let root = tempfile::tempdir().unwrap();
    for (name, number) in NAMES.iter().zip([13, 15, 14]) {
        closed_wal_session(root.path(), name, number);
    }
    assert_eq!(
        side_files(root.path(), &NAMES),
        vec![(false, false); 3],
        "a closed store has a -wal file or a -shm file before the first call"
    );
    let sessions = sessions_of(root.path());
    let now_ms = an_hour_ahead_ms();
    let past = Instant::now();
    let mut place: Option<Place> = None;
    let mut calls = 0;
    let mut last = None;
    while calls < 9 {
        calls += 1;
        let (stored, next) = stored_from(&sessions, Some(past), place.as_ref(), now_ms).unwrap();
        for name in NAMES {
            let session = sessions.join(name);
            set_folder_written_after_the_start(&session);
            let wal = session.join(format!("{REGISTRY_FILE}-wal"));
            if wal.is_file() {
                set_written_after_the_start(&wal);
            }
        }
        let at_the_numbers = matches!(stored, Stored::Schemas(_));
        last = Some(stored);
        if at_the_numbers {
            break;
        }
        place = next;
    }
    let side = side_files(root.path(), &NAMES);
    let wal_bytes: Vec<u64> = NAMES
        .iter()
        .map(|name| {
            let wal = sessions.join(name).join(format!("{REGISTRY_FILE}-wal"));
            fs::metadata(wal).map_or(0, |wal| wal.len())
        })
        .collect();
    let numbers = BTreeMap::from([("workspace_registry".to_string(), 15)]);
    assert_eq!(
        (calls, last),
        (3, Some(Stored::Schemas(numbers))),
        "not 3 store reads to the numbers; -wal and -shm of each store after the calls: \
         {side:?}; bytes of each -wal: {wal_bytes:?}"
    );
}

/// A pass over the sessions read before that stops keeps its place. Each of
/// the 3 stores here was written after the first call started (1 hour
/// ahead: the row sets each file's time to 2 hours ahead), and each call
/// starts 3 hours ahead with an end time that is past. So the first pass
/// reads one store in each call, and the place that a call gives names the
/// folder that the pass is at. After its read, the row puts bytes that are
/// no store in a store file, with the time of now: a later read of that
/// file is an error. The third call reads the last store, and its pass that
/// follows compares the times with the start of the first pass: nothing was
/// written since, it reads no store, and the call gives the numbers.
#[test]
fn a_pass_that_stops_gives_a_place_that_moved_and_the_calls_end() {
    let root = state_root_of(&[13, 15, 14]);
    let sessions = sessions_of(root.path());
    let since_ms = an_hour_ahead_ms();
    for name in ["session-0", "session-1", "session-2"] {
        set_written_after_the_start(&sessions.join(name).join(REGISTRY_FILE));
    }
    let now_ms = since_ms + 2 * 3_600_000;
    let past = Instant::now();
    let all_read = Stored::NotReady { sessions: 3, sessions_read: 3 };
    let first = place_at(&sessions, "session-2", None, since_ms);

    let (stored, second) = stored_from(&sessions, Some(past), Some(&first), now_ms).unwrap();
    assert_eq!(stored, all_read);
    let second = second.unwrap();
    assert_ne!(second, first, "the pass stopped and the place did not move");
    assert_eq!(second.pass, Some(Pass { after: "session-0".to_string(), began_ms: now_ms }));
    fs::write(sessions.join("session-0").join(REGISTRY_FILE), vec![b'x'; 8192]).unwrap();

    let (stored, third) = stored_from(&sessions, Some(past), Some(&second), now_ms).unwrap();
    assert_eq!(stored, all_read);
    let third = third.unwrap();
    assert_ne!(third, second, "the pass stopped and the place did not move");
    assert_eq!(third.pass, Some(Pass { after: "session-1".to_string(), began_ms: now_ms }));
    fs::write(sessions.join("session-1").join(REGISTRY_FILE), vec![b'x'; 8192]).unwrap();

    assert_eq!(stored_from(&sessions, Some(past), Some(&third), now_ms).unwrap(), the_number(15));
}

/// A pass that reads no store reads the clock too: after each 64 folders
/// that it looked at. Each of the 66 store files here is no store, so a read
/// of one is an error, and none changed after the first call started (1
/// hour ahead). With an end time that is past, the pass stops after 64
/// folders, and its place names the folder 64. A call with that place and an
/// end time far ahead looks at the 2 folders that are left, then makes the
/// pass that follows, and gives the number that the place carries.
#[test]
fn a_pass_that_only_looks_reads_the_clock_after_each_64_folders() {
    let root = tempfile::tempdir().unwrap();
    let sessions = sessions_of(root.path());
    for index in 0..66 {
        let session = sessions.join(format!("session-{index:02}"));
        fs::create_dir_all(&session).unwrap();
        fs::write(session.join(REGISTRY_FILE), b"this is no store").unwrap();
    }
    let now_ms = an_hour_ahead_ms();
    let first = place_at(&sessions, "session-65", Some(16), now_ms);
    let past = Instant::now();
    let (stored, second) = stored_from(&sessions, Some(past), Some(&first), now_ms).unwrap();
    assert_eq!(stored, Stored::NotReady { sessions: 66, sessions_read: 66 });
    let second = second.unwrap();
    assert_eq!(second.pass, Some(Pass { after: "session-63".to_string(), began_ms: now_ms }));
    let far = Instant::now() + Duration::from_secs(3600);
    assert_eq!(stored_from(&sessions, Some(far), Some(&second), now_ms).unwrap(), the_number(16));
}

/// A place is a place of one state root, and the app's check has more than
/// one root. A place of root A that comes to a call for root B is no place:
/// the call is a first call and no error, and the call with no end time
/// gives the numbers of root B whole (15, not the 17 of root A that the
/// place carries). A place with no `root` part is no place too. The place
/// names its root with no path in it.
#[test]
fn a_place_of_another_state_root_is_no_place() {
    let root_a = state_root(3, 17);
    let root_b = state_root_of(&[13, 15, 14]);
    let (code, first, stderr) = check(root_a.path(), &["--within-ms", "0", "--place", ""]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    let place_a = place_of(&first);
    let folder_a = root_a.path().file_name().unwrap().to_str().unwrap();
    assert!(
        !place_a.contains('/') && !place_a.contains(folder_a),
        "the place holds a part of a path: {place_a}"
    );

    let (code, answer, stderr) = check(root_b.path(), &["--within-ms", "0", "--place", &place_a]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&answer), Some((3, 1)), "{answer}");
    let (code, answer, stderr) = check(root_b.path(), &["--place", &place_a]);
    assert_eq!((code, answer), (Some(0), json!({ "workspace_registry": 15 })), "stderr: {stderr}");

    let mut no_root: Value = serde_json::from_str(&place_a).unwrap();
    no_root.as_object_mut().unwrap().remove("root").unwrap();
    let no_root = no_root.to_string();
    let (code, answer, stderr) = check(root_a.path(), &["--within-ms", "0", "--place", &no_root]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&answer), Some((3, 1)), "{answer}");
    // The control: the place with its root goes on in root A.
    let (code, answer, stderr) = check(root_a.path(), &["--within-ms", "0", "--place", &place_a]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&answer), Some((3, 2)), "{answer}");
}

/// The name that the reset command gives the folder of the session `name`
/// before it deletes it: `.reset-NAME-KIND-UUID.deleting`, in the same state
/// root.
fn reset_name(name: &str) -> String {
    format!(".reset-{name}-session-6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f.deleting")
}

/// The reset command renames a session folder to a name that starts with a
/// dot, which sorts before the place, and deletes it later. The rename
/// changes no time of a store file. Here the reset renames a session that no
/// call read yet, between 2 calls, and no file changed after the first call
/// started (1 hour ahead). The pass reads each folder of the reset's form,
/// so the number 17 of that session is in the answer.
#[test]
fn a_session_that_the_reset_renames_between_two_calls_is_in_the_answer() {
    let root = state_root_of(&[13, 14, 17]);
    let sessions = sessions_of(root.path());
    let now_ms = an_hour_ahead_ms();
    let (stored, place) = stored_from(&sessions, Some(Instant::now()), None, now_ms).unwrap();
    assert_eq!(stored, Stored::NotReady { sessions: 3, sessions_read: 1 });
    let place = place.unwrap();
    assert_eq!(place.after, "session-0");
    fs::rename(sessions.join("session-2"), sessions.join(reset_name("session-2"))).unwrap();
    assert_eq!(stored_from(&sessions, None, Some(&place), now_ms).unwrap(), the_number(17));
}

/// Each pass reads each folder of the reset's form: here 2 of them, and no
/// file changed after the first call started. With an end time that is past
/// the call reads the first one (17) and stops at the second one. The reset
/// then deletes the second folder. The next call is no error, and the number
/// 19 of the folder that is gone is not in the answer: no call read it.
#[test]
fn a_folder_of_the_reset_that_is_gone_at_the_next_call_is_no_error() {
    let root = state_root_of(&[13]);
    let sessions = sessions_of(root.path());
    session(root.path(), &reset_name("session-8"), 17);
    session(root.path(), &reset_name("session-9"), 19);
    let now_ms = an_hour_ahead_ms();
    let first = place_at(&sessions, "session-0", Some(13), now_ms);
    let (stored, second) =
        stored_from(&sessions, Some(Instant::now()), Some(&first), now_ms).unwrap();
    assert_eq!(stored, Stored::NotReady { sessions: 3, sessions_read: 3 });
    let mut wanted = place_at(&sessions, "session-0", Some(17), now_ms);
    wanted.pass = Some(Pass { after: reset_name("session-8"), began_ms: now_ms });
    assert_eq!(second, Some(wanted.clone()));
    fs::remove_dir_all(sessions.join(reset_name("session-9"))).unwrap();
    assert_eq!(stored_from(&sessions, None, Some(&wanted), now_ms).unwrap(), the_number(17));
}

/// The text of a place that has a `pass` part is the same place after the
/// check reads it. Through the executable too: a call with that text goes on
/// in the pass after the folder that the `pass` part names, and the place
/// that it gives back has the pass at the next folder, with the same start.
#[test]
fn a_place_with_a_pass_goes_through_its_text_and_through_the_check() {
    const SINCE_MS: u64 = 1_700_000_000_000;
    let root = state_root_of(&[13, 15, 14]);
    let sessions = sessions_of(root.path());
    let mut place = place_at(&sessions, "session-2", None, SINCE_MS);
    assert_eq!(Place::of(&place.text()), Some(place.clone()));
    place.pass = Some(Pass { after: "session-0".to_string(), began_ms: SINCE_MS + 500 });
    let text = place.text();
    assert_eq!(Place::of(&text), Some(place));

    // Each file here was written after `SINCE_MS`, so the pass reads the
    // session 1 and, with no time, stops at the session 2.
    let (code, answer, stderr) = check(root.path(), &["--within-ms", "0", "--place", &text]);
    assert_eq!(code, Some(0), "stderr: {stderr}");
    assert_eq!(counts_of(&answer), Some((3, 3)), "{answer}");
    let mut wanted = place_at(&sessions, "session-2", Some(15), SINCE_MS);
    wanted.pass = Some(Pass { after: "session-1".to_string(), began_ms: SINCE_MS + 500 });
    assert_eq!(Place::of(&place_of(&answer)), Some(wanted));
}

/// A pass that an earlier call started comes to its end in this call, and
/// the pass that follows it stops. The place that the call gives then
/// compares with the start of the call in which the pass before started
/// (`since_ms`), and its `pass` part has the start of this call. The first
/// call started 1 hour ahead, the pass before 30 minutes after that, and
/// this call 2 hours after it; the 2 stores that changed have a time 1 hour
/// after the first start. The next call reads the store that is left, and
/// its pass that follows compares with the start of this call: nothing was
/// written since, and it gives the numbers. The store file of the session 0
/// is no store after its read: a second read of it is an error.
#[test]
fn a_pass_that_follows_a_pass_stops_and_keeps_the_start_of_the_pass_before() {
    let root = state_root_of(&[13, 15, 14]);
    let sessions = sessions_of(root.path());
    let since_ms = an_hour_ahead_ms();
    let began_ms = since_ms + 1_800_000;
    let now_ms = since_ms + 2 * 3_600_000;
    for name in ["session-0", "session-1"] {
        set_written_after_the_start(&sessions.join(name).join(REGISTRY_FILE));
    }
    let past = Instant::now();
    let mut first = place_at(&sessions, "session-2", None, since_ms);
    first.pass = Some(Pass { after: "session-1".to_string(), began_ms });

    let (stored, second) = stored_from(&sessions, Some(past), Some(&first), now_ms).unwrap();
    assert_eq!(stored, Stored::NotReady { sessions: 3, sessions_read: 3 });
    let mut wanted = place_at(&sessions, "session-2", Some(13), began_ms);
    wanted.pass = Some(Pass { after: "session-0".to_string(), began_ms: now_ms });
    assert_eq!(second, Some(wanted.clone()));
    fs::write(sessions.join("session-0").join(REGISTRY_FILE), vec![b'x'; 8192]).unwrap();

    assert_eq!(stored_from(&sessions, Some(past), Some(&wanted), now_ms).unwrap(), the_number(15));
}

/// A call that carries a pass and stops before it comes to the pass (it has
/// sessions after the place to read first) gives the pass back as it got
/// it. The call after it reads the session that is left and goes on in that
/// pass.
#[test]
fn a_call_that_stops_before_the_pass_that_it_carries_gives_the_pass_back() {
    let root = state_root_of(&[13, 15, 14]);
    let sessions = sessions_of(root.path());
    let now_ms = an_hour_ahead_ms();
    let carried = Pass { after: "session-0".to_string(), began_ms: now_ms };
    let mut first = place_at(&sessions, "session-0", Some(13), now_ms);
    first.pass = Some(carried.clone());

    let (stored, second) =
        stored_from(&sessions, Some(Instant::now()), Some(&first), now_ms).unwrap();
    assert_eq!(stored, Stored::NotReady { sessions: 3, sessions_read: 2 });
    let mut wanted = place_at(&sessions, "session-1", Some(15), now_ms);
    wanted.pass = Some(carried);
    assert_eq!(second, Some(wanted.clone()));

    assert_eq!(stored_from(&sessions, None, Some(&wanted), now_ms).unwrap(), the_number(15));
}
