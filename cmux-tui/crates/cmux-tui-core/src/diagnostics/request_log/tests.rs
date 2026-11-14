//! The slow request log's own bounds: the allow-list, the disk bound, no write at rest, and a
//! request path that never waits for the writer. The request path's records are tested in
//! `server/tests/slow_request_log.rs`.

use super::*;
use serde_json::Value;

fn open_log() -> (cmux_unix_socket::TestDir, Arc<RequestLog>) {
    let dir = cmux_unix_socket::short_test_dir("srl");
    let log = RequestLog::open(dir.path()).expect("the log's writer starts");
    (dir, log)
}

/// One request of `line` that took `took` and was answered `ok`.
fn request(log: &Arc<RequestLog>, connection: &Arc<AtomicBool>, line: &str, took: Duration) {
    let guard =
        log.begin(7, (Label::client("cmux-next"), Label::client("frontend")), connection, line);
    decoded_command();
    backdate(took);
    reply_follows(true, None);
    reply_mark(connection, 64).expect("the request's reply is marked").written();
    drop(guard);
}

fn file_text(dir: &cmux_unix_socket::TestDir) -> String {
    let older = std::fs::read_to_string(dir.path().join(format!("{FILE_NAME}.1")));
    let newest = std::fs::read_to_string(dir.path().join(FILE_NAME));
    older.unwrap_or_default() + &newest.unwrap_or_default()
}

fn records(dir: &cmux_unix_socket::TestDir) -> Vec<Value> {
    file_text(dir)
        .lines()
        .map(|line| serde_json::from_str(line).expect("each line is one JSON object"))
        .collect()
}

const SLOW: Duration = Duration::from_millis(150);

#[test]
fn a_param_that_is_not_on_the_allow_list_is_not_in_the_file() {
    let (dir, log) = open_log();
    let connection = Arc::new(AtomicBool::new(true));
    let line = serde_json::json!({
        "id": "client-chosen-id-SECRET0",
        "cmd": "send",
        "surface": 3,
        "text": "rm -rf ~/secret-typed-text",
        "workspace": "My Private Project",
        "terminal_id": "../../etc/passwd",
        "env": {"API_TOKEN": "SECRET5"},
        "params": {
            "pane": "pane_0123456789abcdef0123456789abcdef",
            "command": "curl https://x.test/?token=SECRET1",
            "browser": "https://x.test/?q=SECRET2",
            "unknown_param": "SECRET3",
            "tab": ["SECRET6"],
        },
    })
    .to_string();
    // A TUI sends the computer's hostname as its name: a name that is not a fixed word of a cmux
    // client gives no label at all.
    let labels = (Label::client("Lawrences-MacBook-Pro"), Label::client("my own kind"));
    let guard = log.begin(7, labels, &connection, &line);
    decoded_command();
    backdate(SLOW);
    reply_follows(false, Some("Not A Code: SECRET4"));
    reply_mark(&connection, 64).expect("the request's reply is marked").written();
    drop(guard);
    // A line the daemon did not decode: its `cmd` is the client's text, not a command's name.
    let labels = (Label::client("cmux-next"), Label::client("frontend"));
    let guard = log.begin(7, labels, &connection, r#"{"cmd":"my-secret-word","surface":4}"#);
    backdate(SLOW);
    reply_follows(false, None);
    reply_mark(&connection, 64).expect("the request's reply is marked").written();
    drop(guard);
    log.settle();

    let text = file_text(&dir);
    let records = records(&dir);
    assert_eq!(records.len(), 2, "one record for each request: {text}");
    assert_eq!(records[0]["name"], "send");
    assert_eq!(records[0]["surface"], 3);
    assert_eq!(records[0]["pane"], "pane_0123456789abcdef0123456789abcdef");
    assert_eq!(records[0]["error"], "error", "an error code that is not a code is not written");
    assert!(
        records[0].get("client_name").is_none(),
        "a client's own name is in the record: {text}"
    );
    assert!(
        records[0].get("client_kind").is_none(),
        "a client's own kind is in the record: {text}"
    );
    assert_eq!(records[1]["client_name"], "cmux-next");
    assert_eq!(records[1]["client_kind"], "frontend");
    assert_eq!(records[1]["name"], "other");
    assert_eq!(records[1]["surface"], 4);
    for key in ["text", "workspace", "terminal", "browser", "tab", "id", "env", "command"] {
        assert!(records[0].get(key).is_none(), "{key} is in the record: {text}");
    }
    for secret in [
        "SECRET",
        "secret",
        "typed",
        "Private",
        "passwd",
        "curl",
        "token",
        "unknown_param",
        "client-chosen",
        "x.test",
        "rm -rf",
        "Lawrences",
        "MacBook",
        "my own kind",
        "my_own_kind",
    ] {
        assert!(!text.contains(secret), "{secret:?} is in the file: {text}");
    }
}

#[test]
fn a_storm_of_slow_requests_stays_inside_the_stated_bytes_and_keeps_the_newest() {
    const REQUESTS: u64 = 100_000;
    let (dir, log) = open_log();
    let connection = Arc::new(AtomicBool::new(true));
    for number in 0..REQUESTS {
        let line = format!(r#"{{"id":{number},"cmd":"close-surface","surface":{number}}}"#);
        request(&log, &connection, &line, SLOW);
        if number % 128 == 127 {
            log.settle();
        }
    }
    log.settle();

    assert_eq!(log.dropped_total(), 0, "the writer kept up, so the newest records are the last");
    let mut on_disk = 0;
    for entry in std::fs::read_dir(dir.path()).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name().to_string_lossy().into_owned();
        assert!(name == FILE_NAME || name == format!("{FILE_NAME}.1"), "an extra file: {name}");
        let bytes = entry.metadata().unwrap().len();
        assert!(bytes <= FILE_BYTES, "{name} holds {bytes} bytes");
        on_disk += bytes;
    }
    assert!(on_disk > FILE_BYTES / 2, "the storm left a full file: {on_disk}");
    assert!(on_disk <= 2 * FILE_BYTES, "{on_disk} bytes on disk");
    let records = records(&dir);
    let newest: Vec<u64> = records.iter().filter_map(|record| record["surface"].as_u64()).collect();
    assert_eq!(newest.last(), Some(&(REQUESTS - 1)), "the newest record is the last line");
    let first = newest[0];
    let expected: Vec<u64> = (first..REQUESTS).collect();
    assert_eq!(newest, expected, "the file holds the newest records, in order, with no gap");
}

#[test]
fn at_rest_the_log_writes_nothing() {
    let (dir, log) = open_log();
    let connection = Arc::new(AtomicBool::new(true));
    // The writer has no timer: time alone cannot make it write. Fast requests are all that
    // happens at rest (the app's heartbeat), so 10,000 of them and a wait stand for the minutes.
    for number in 0..10_000 {
        let line = format!(r#"{{"id":{number},"cmd":"ping"}}"#);
        request(&log, &connection, &line, Duration::from_millis(5));
    }
    std::thread::sleep(Duration::from_millis(300));
    log.settle();

    assert_eq!(log.bytes_written(), 0);
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0, "at rest there is no file");

    // The same log does write a slow request: the zero above is not a dead writer.
    request(&log, &connection, r#"{"id":1,"cmd":"ping"}"#, SLOW);
    log.settle();
    assert_eq!(records(&dir).len(), 1);
}

#[test]
fn a_blocked_writer_does_not_hold_the_request_path() {
    const REQUESTS: u64 = 1_000;
    let (dir, log) = open_log();
    let connection = Arc::new(AtomicBool::new(true));
    let blocked = log.block_writer();
    let started = Instant::now();
    for number in 0..REQUESTS {
        let line = format!(r#"{{"id":{number},"cmd":"close-surface","surface":{number}}}"#);
        request(&log, &connection, &line, SLOW);
    }
    let took = started.elapsed();
    let dropped = log.dropped_total();
    drop(blocked);
    log.settle();

    assert!(took < Duration::from_secs(2), "1,000 requests waited {took:?} for a blocked writer");
    // The queue holds 256 records and the writer one more.
    assert!(dropped >= REQUESTS - 257, "{dropped} records were dropped");
    let records = records(&dir);
    let written = records.iter().filter(|record| record["kind"] == "request").count() as u64;
    let reported: u64 = records.iter().filter_map(|record| record["queue_full"].as_u64()).sum();
    assert_eq!(written + dropped, REQUESTS, "each request is written or counted as dropped");
    assert_eq!(reported, dropped, "the file says how many records it lost: {records:?}");
}

#[test]
fn a_session_name_and_an_app_id_in_a_thread_name_are_not_labels() {
    let hash = Label::session_hash("acme-merger-0123456789abcdef").expect("the folder's hash");
    assert_eq!(hash.as_str(), "0123456789abcdef");
    assert!(Label::session_hash("acme-merger").is_none(), "a folder name with no hash is a label");
    assert!(Label::session_hash("acme-0123456789abcdeg").is_none(), "16 bytes that are not hex");
    let thread = Label::thread("cmux-app-host:com.example.private-app").expect("the thread's name");
    assert_eq!(thread.as_str(), "cmux-app-host");
    assert_eq!(Label::thread("mux-slow-log").expect("a plain name").as_str(), "mux-slow-log");
}

/// The older file cannot be made here (its name is a folder): the file must still obey the limit.
#[test]
fn a_rotation_that_fails_does_not_let_the_file_pass_the_limit() {
    let dir = cmux_unix_socket::short_test_dir("srl");
    let path = dir.path().join(FILE_NAME);
    std::fs::create_dir(dir.path().join(format!("{FILE_NAME}.1"))).expect("the folder");
    std::fs::write(&path, vec![b'a'; (FILE_BYTES - 10) as usize]).expect("a file near the limit");
    let line = format!("{}\n", "b".repeat(200));
    let mut ring = Ring::new(dir.path());
    for _ in 0..3 {
        ring.append(&line);
    }
    let written = std::fs::read(&path).expect("the file");
    assert!(written.len() as u64 <= FILE_BYTES, "the file passed 1 MiB: {} bytes", written.len());
    assert!(written.ends_with(line.as_bytes()), "the newest record is not the last line");
}
