//! The slow request log's own bounds: the allow-list, the disk bound, no write at rest, and a
//! request path that never waits for the writer. The request path's records are tested in
//! `server/tests/slow_request_log.rs`.

use super::*;
use serde_json::Value;

fn open_log() -> (cmux_unix_socket::TestDir, Arc<RequestLog>) {
    let dir = cmux_unix_socket::short_test_dir("srl");
    let log = RequestLog::open(dir.path(), crate::startup_timings::unix_now_ms)
        .expect("the log's writer starts");
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

// Repeats of one failed request (`repeats.rs`): counted, not written. The tests give each time
// themselves: no test here reads a clock or waits.

use repeats::{REPEAT_WINDOW_MS, RUNS};

/// A key of the connection with the number 7.
fn key(name: &str, error: &str, kind: &str) -> Key {
    Key::new(Label::token(name), Label::token(error).expect("an error code"), Label::token(kind), 7)
}

/// What `offer` said: none for a counted record, else the count of the run that it ended and
/// how many records its own line stands for.
fn said(offered: Offered<u32>) -> Option<(Option<(u32, u64)>, u64)> {
    match offered {
        Offered::Write { ended, stands_for, .. } => Some((ended, stands_for)),
        Offered::Counted => None,
    }
}

const REFUSED: (&str, &str, &str) = ("session.journal.subscribe", "validation.invalid", "plugin");

#[test]
fn the_first_record_of_a_run_is_written_at_once_and_the_next_ones_are_counted() {
    let mut repeats = Repeats::default();
    let run = key(REFUSED.0, REFUSED.1, REFUSED.2);
    assert_eq!(said(repeats.offer(run, 1_000, 1)), Some((None, 1)), "the first record");
    assert!(!repeats.waits(), "with no counted record no count waits");
    assert_eq!(repeats.wait_ms(1_000), None, "with no counted record there is no time-out");
    assert_eq!(said(repeats.offer(run, 1_001, 2)), None, "the second record is counted");
    assert_eq!(said(repeats.offer(run, 60_999, 3)), None, "the last millisecond of the window");
    assert!(repeats.waits());
    assert_eq!(repeats.wait_ms(2_000), Some(59_000), "the wait ends at the end of the window");
    assert_eq!(repeats.take_due(60_999), None, "no count is due inside the window");
    assert_eq!(repeats.wait_ms(61_000), Some(0), "the count is due at the end of the window");
    assert_eq!(repeats.take_due(61_000), Some((3, 2)), "the newest record, for 2 records");
    assert_eq!(repeats.take_due(61_000), None, "a count is given one time");
    assert!(!repeats.waits());
    // The next window starts at the time of the count's line.
    assert_eq!(said(repeats.offer(run, 120_999, 4)), None, "inside the window after the count");
    assert_eq!(repeats.take_due(121_000), Some((4, 1)));
}

#[test]
fn a_record_after_the_window_is_written_with_the_count_before_it() {
    let mut repeats = Repeats::default();
    let run = key(REFUSED.0, REFUSED.1, REFUSED.2);
    assert_eq!(said(repeats.offer(run, 0, 1)), Some((None, 1)));
    assert_eq!(said(repeats.offer(run, 10, 2)), None);
    assert_eq!(said(repeats.offer(run, 20, 3)), None);
    // The writer did not come to the count in time: the record that ends the window has it.
    assert_eq!(said(repeats.offer(run, REPEAT_WINDOW_MS, 4)), Some((None, 3)));
    assert!(!repeats.waits(), "the count went with the line");
    // A run with no counted record: the next record after its window is a plain line.
    assert_eq!(said(repeats.offer(run, 3 * REPEAT_WINDOW_MS, 5)), Some((None, 1)));
}

#[test]
fn a_time_before_the_last_line_is_counted_until_it_is_a_whole_window_before_it() {
    let mut repeats = Repeats::default();
    let run = key(REFUSED.0, REFUSED.1, REFUSED.2);
    assert_eq!(said(repeats.offer(run, 100_000, 1)), Some((None, 1)));
    // A request that arrived before the run's last line and ended after it.
    assert_eq!(said(repeats.offer(run, 99_000, 2)), None);
    assert_eq!(repeats.wait_ms(90_000), Some(REPEAT_WINDOW_MS), "a wait is one window at most");
    // A clock that was set back by a window or more: the record is written, the count with it.
    assert_eq!(said(repeats.offer(run, 40_000, 3)), Some((None, 2)));
    assert_eq!(said(repeats.offer(run, 40_001, 4)), None);
    assert_eq!(repeats.take_due(39_000), None);
    assert_eq!(repeats.take_due(0), None, "40,000 ms before the line is inside the window");
    assert_eq!(repeats.take_due(100_001), Some((4, 1)));
}

#[test]
fn records_that_differ_in_name_error_or_client_kind_are_different_runs() {
    let mut repeats = Repeats::default();
    let keys = [
        key(REFUSED.0, REFUSED.1, REFUSED.2),
        key("session.events", REFUSED.1, REFUSED.2),
        key(REFUSED.0, "error", REFUSED.2),
        key(REFUSED.0, REFUSED.1, "frontend"),
    ];
    for (number, run) in keys.into_iter().enumerate() {
        assert_eq!(said(repeats.offer(run, 5, number as u32)), Some((None, 1)), "key {number}");
    }
    for (number, run) in keys.into_iter().enumerate() {
        assert_eq!(said(repeats.offer(run, 6, number as u32)), None, "key {number} again");
    }
}

#[test]
fn a_ninth_key_ends_the_oldest_run_and_gives_its_count() {
    let mut repeats = Repeats::default();
    let names: Vec<String> = (0..=RUNS).map(|number| format!("op-{number}")).collect();
    let run = |number: usize| key(&names[number], REFUSED.1, REFUSED.2);
    for number in 0..RUNS {
        let at_ms = 1_000 + number as u64;
        assert_eq!(said(repeats.offer(run(number), at_ms, 0)), Some((None, 1)), "key {number}");
    }
    assert_eq!(said(repeats.offer(run(0), 1_100, 70)), None, "the oldest run counts a record");
    assert_eq!(said(repeats.offer(run(0), 1_101, 71)), None);
    // One key more than the table holds: the oldest run (the one with the oldest last line)
    // goes, and its count is not lost.
    assert_eq!(said(repeats.offer(run(RUNS), 1_200, 9)), Some((Some((71, 2)), 1)));
    assert!(!repeats.waits(), "the count of the run that ended is not given a second time");
    // The key of the run that ended starts a new run: a plain first line. The run that is the
    // oldest now has no count, so no line goes before it.
    assert_eq!(said(repeats.offer(run(0), 1_300, 72)), Some((None, 1)));
    assert_eq!(said(repeats.offer(run(RUNS), 1_301, 10)), None, "the ninth key has a run");
    assert_eq!(said(repeats.offer(run(1), 1_302, 11)), Some((None, 1)), "key 1 lost its run");
}

/// A writer with no thread. Its clock says 0: a test that needs the writer's clock sets it.
fn test_writer(dir: &cmux_unix_socket::TestDir) -> Writer {
    Writer {
        ring: Ring::new(dir.path()),
        dropped: Arc::default(),
        repeats: Repeats::default(),
        clock: || 0,
        written: Arc::default(),
        gate: Arc::default(),
    }
}

/// The record of one request that arrived at `at_ms`, as the request path hands it to the writer.
fn ended(name: &str, error: Option<&str>, kind: &str, at_ms: u64) -> Entry {
    ended_by(7, name, error, kind, at_ms)
}

/// [`ended`] for a request of the connection with the number `client`.
fn ended_by(client: u64, name: &str, error: Option<&str>, kind: &str, at_ms: u64) -> Entry {
    let now = Instant::now();
    let line = r#"{"id":1,"cmd":"request","surface":3}"#;
    Entry::Request(Box::new(Data {
        connection: Arc::new(AtomicBool::new(true)),
        client,
        client_name: None,
        client_kind: Label::token(kind),
        fields: allowed_fields(line),
        name: Label::token(name),
        request_bytes: line.len(),
        arrived: now,
        started: now,
        queued: None,
        reply_bytes: 0,
        lock_wait: Duration::ZERO,
        registry_wait: Duration::ZERO,
        error: error.and_then(Label::token),
        reply_follows: true,
        timed_out: false,
        at_ms,
        total: SLOW,
        reply: None,
        outcome: if error.is_some() { "error" } else { "ok" },
    }))
}

/// How many records the lines stand for: `repeats` of a line, or 1.
fn stood_for(records: &[Value]) -> u64 {
    records.iter().map(|record| record["repeats"].as_u64().unwrap_or(1)).sum()
}

#[test]
fn a_thousand_equal_refused_requests_inside_one_window_write_two_lines() {
    const FIRST_MS: u64 = 1_700_000_000_000;
    let dir = cmux_unix_socket::short_test_dir("srl");
    let mut writer = test_writer(&dir);
    let mut line = String::new();
    for number in 0..1_000 {
        writer.take(ended(REFUSED.0, Some(REFUSED.1), REFUSED.2, FIRST_MS + number), &mut line);
        if number == 0 {
            // What a reader of the file depends on: the first record of a run is on disk at
            // once, with the client kind and the error code.
            let text = file_text(&dir);
            let records = records(&dir);
            assert_eq!(records.len(), 1, "the first record is written at once: {text}");
            assert_eq!(records[0]["kind"], "request");
            assert_eq!(records[0]["client_kind"], "plugin");
            assert_eq!(records[0]["error"], "validation.invalid");
            assert_eq!(records[0]["at_ms"], FIRST_MS);
            assert!(records[0].get("repeats").is_none(), "a first record has no count: {text}");
        }
    }
    assert_eq!(records(&dir).len(), 1, "999 equal records inside the window add no line");

    // The clock of the test: 1 ms before the end of the window, then its end.
    let wait = writer.due_wait(FIRST_MS + REPEAT_WINDOW_MS - 1, &mut line);
    assert_eq!(wait, Some(Duration::from_millis(1)), "the writer's wait ends with the window");
    assert_eq!(records(&dir).len(), 1, "no count is written before the end of the window");
    let wait = writer.due_wait(FIRST_MS + REPEAT_WINDOW_MS, &mut line);
    assert_eq!(wait, None, "after the count no wait has a time-out");

    let text = file_text(&dir);
    let records = records(&dir);
    assert_eq!(records.len(), 2, "one line for the first record and one for the 999: {text}");
    assert_eq!(records[1]["repeats"], 999);
    assert_eq!(records[1]["at_ms"], FIRST_MS + 999, "the line is the newest record: {text}");
    assert_eq!(records[1]["client_kind"], "plugin");
    assert_eq!(records[1]["error"], "validation.invalid");
    assert_eq!(stood_for(&records), 1_000, "each request is in a line or in a count");
}

#[test]
fn a_refusal_each_second_for_five_minutes_writes_six_lines() {
    const FIRST_MS: u64 = 1_700_000_000_000;
    let dir = cmux_unix_socket::short_test_dir("srl");
    let mut writer = test_writer(&dir);
    let mut line = String::new();
    for second in 0..300 {
        let now_ms = FIRST_MS + second * 1_000;
        // As the writer's thread does: the counts that are due first, then the record.
        writer.due_wait(now_ms, &mut line);
        writer.take(ended(REFUSED.0, Some(REFUSED.1), REFUSED.2, now_ms), &mut line);
    }
    let in_five_minutes = records(&dir);
    assert_eq!(in_five_minutes.len(), 5, "the first record and one line for each minute after it");
    assert_eq!(writer.due_wait(FIRST_MS + 300_000, &mut line), None);

    let text = file_text(&dir);
    let records = records(&dir);
    let counts: Vec<Option<u64>> =
        records.iter().map(|record| record["repeats"].as_u64()).collect();
    assert_eq!(counts, [None, Some(59), Some(60), Some(60), Some(60), Some(60)], "{text}");
    assert_eq!(stood_for(&records), 300, "each refusal is in a line or in a count: {text}");
}

#[test]
fn equal_slow_requests_with_no_error_keep_a_line_each() {
    let dir = cmux_unix_socket::short_test_dir("srl");
    let mut writer = test_writer(&dir);
    let mut line = String::new();
    for number in 0..5 {
        writer.take(ended("list-workspaces", None, "frontend", 1_000 + number), &mut line);
    }
    assert_eq!(writer.due_wait(1_005, &mut line), None, "a request with no error is not counted");
    let records = records(&dir);
    assert_eq!(records.len(), 5, "one line for each slow request");
    assert!(records.iter().all(|record| record.get("repeats").is_none()));
}

#[test]
fn a_ninth_run_writes_the_count_of_the_oldest_run_before_its_own_first_line() {
    let dir = cmux_unix_socket::short_test_dir("srl");
    let mut writer = test_writer(&dir);
    let mut line = String::new();
    for number in 0..RUNS as u64 {
        let name = format!("op-{number}");
        writer.take(ended(&name, Some("error"), "frontend", 1_000 + number), &mut line);
    }
    for number in 0..3 {
        writer.take(ended("op-0", Some("error"), "frontend", 2_000 + number), &mut line);
    }
    assert_eq!(records(&dir).len(), RUNS, "one first line for each of the runs");
    writer.take(ended("op-new", Some("error"), "frontend", 3_000), &mut line);

    let text = file_text(&dir);
    let records = records(&dir);
    assert_eq!(records.len(), RUNS + 2, "the count of the oldest run, then the new run: {text}");
    assert_eq!(records[RUNS]["name"], "op-0");
    assert_eq!(records[RUNS]["repeats"], 3);
    assert_eq!(records[RUNS]["at_ms"], 2_002);
    assert_eq!(records[RUNS + 1]["name"], "op-new");
    assert!(records[RUNS + 1].get("repeats").is_none(), "{text}");
    assert_eq!(writer.due_wait(4_000, &mut line), None, "no count waits after it");
}

/// The log is read to find WHICH client failed: the failed requests of 2 clients are 2 runs,
/// also with the same name, error code and kind.
#[test]
fn equal_failed_requests_of_two_clients_write_a_line_each_at_once() {
    const FIRST_MS: u64 = 1_700_000_000_000;
    let dir = cmux_unix_socket::short_test_dir("srl");
    let mut writer = test_writer(&dir);
    let mut line = String::new();
    writer.take(ended_by(7, "list-workspaces", Some("error"), "agent", FIRST_MS), &mut line);
    writer.take(ended_by(8, "list-workspaces", Some("error"), "agent", FIRST_MS + 1), &mut line);

    let text = file_text(&dir);
    let first = records(&dir);
    assert_eq!(first.len(), 2, "one line at once for each client: {text}");
    assert_eq!(first[0]["client"], 7);
    assert_eq!(first[1]["client"], 8);
    assert!(first.iter().all(|record| record["client_kind"] == "agent"), "{text}");
    assert!(first.iter().all(|record| record.get("repeats").is_none()), "{text}");

    // Each client has its own run: its repeats are counted there, and its count has its number.
    writer.take(ended_by(7, "list-workspaces", Some("error"), "agent", FIRST_MS + 2), &mut line);
    writer.take(ended_by(8, "list-workspaces", Some("error"), "agent", FIRST_MS + 3), &mut line);
    writer.take(ended_by(8, "list-workspaces", Some("error"), "agent", FIRST_MS + 4), &mut line);
    assert_eq!(records(&dir).len(), 2, "a repeat of a client adds no line inside its window");
    assert_eq!(writer.due_wait(FIRST_MS + 1 + REPEAT_WINDOW_MS, &mut line), None);

    let text = file_text(&dir);
    let records = records(&dir);
    assert_eq!(records.len(), 4, "one count line for each client: {text}");
    assert_eq!(records[2]["client"], 7);
    assert!(records[2].get("repeats").is_none(), "client 7 had 1 repeat: {text}");
    assert_eq!(records[2]["at_ms"], FIRST_MS + 2);
    assert_eq!(records[3]["client"], 8);
    assert_eq!(records[3]["repeats"], 2, "client 8 had 2 repeats: {text}");
    assert_eq!(records[3]["at_ms"], FIRST_MS + 4);
    assert_eq!(stood_for(&records), 5, "each request is in a line or in a count: {text}");
}

/// The journal plugin's connection is a new one for each pass of the plugin: its run has no
/// client number, or no refusal of it would be a repeat.
#[test]
fn equal_refused_requests_of_plugin_connections_are_one_run() {
    const FIRST_MS: u64 = 1_700_000_000_000;
    let dir = cmux_unix_socket::short_test_dir("srl");
    let mut writer = test_writer(&dir);
    let mut line = String::new();
    for client in 7..10 {
        let at_ms = FIRST_MS + client;
        writer.take(ended_by(client, REFUSED.0, Some(REFUSED.1), REFUSED.2, at_ms), &mut line);
    }
    let text = file_text(&dir);
    let first = records(&dir);
    assert_eq!(first.len(), 1, "3 connections of the plugin are one run: {text}");
    assert_eq!(first[0]["client"], 7);
    assert_eq!(first[0]["client_kind"], "plugin");

    assert_eq!(writer.due_wait(FIRST_MS + 7 + REPEAT_WINDOW_MS, &mut line), None);
    let text = file_text(&dir);
    let records = records(&dir);
    assert_eq!(records.len(), 2, "one count line for the 2 later connections: {text}");
    assert_eq!(records[1]["client"], 9, "the count line is the newest record: {text}");
    assert_eq!(records[1]["repeats"], 2);
    assert_eq!(stood_for(&records), 3, "each request is in a line or in a count: {text}");
}

#[test]
fn at_rest_the_writer_waits_with_no_time_out() {
    let dir = cmux_unix_socket::short_test_dir("srl");
    let mut writer = test_writer(&dir);
    let mut line = String::new();
    assert_eq!(writer.due_wait(1_000, &mut line), None, "a new log has no count");
    writer.take(ended(REFUSED.0, Some(REFUSED.1), REFUSED.2, 1_000), &mut line);
    writer.take(ended("list-workspaces", None, "frontend", 1_001), &mut line);
    assert!(!writer.repeats.waits(), "a first failed record and a slow record leave no count");
    assert_eq!(writer.due_wait(500_000, &mut line), None, "so the wait has no time-out");
    assert_eq!(records(&dir).len(), 2);
}

/// The writer's own wait, with the log's clock at the end of the run's window: the count is
/// written before the next entry is taken. The entry is in the queue before the call, so the
/// test waits for nothing.
#[test]
fn the_writer_writes_a_due_count_before_it_takes_the_next_entry() {
    const FIRST_MS: u64 = 1_000;
    let dir = cmux_unix_socket::short_test_dir("srl");
    let mut writer = test_writer(&dir);
    writer.clock = || FIRST_MS + REPEAT_WINDOW_MS;
    let mut line = String::new();
    for number in 0..3 {
        writer.take(ended(REFUSED.0, Some(REFUSED.1), REFUSED.2, FIRST_MS + number), &mut line);
    }
    assert_eq!(records(&dir).len(), 1, "the first record; a count of 2 waits");

    let (sender, receiver) = sync_channel(1);
    sender.send(ended("list-workspaces", None, "frontend", 70_000)).expect("the queue is open");
    let next = writer.next_entry(&receiver, &mut line);
    assert!(matches!(next, Some(Entry::Request(_))), "the entry of the queue is the next one");
    let text = file_text(&dir);
    let records = records(&dir);
    assert_eq!(records.len(), 2, "the count is written, the next entry is not yet: {text}");
    assert_eq!(records[1]["repeats"], 2, "{text}");
    assert_eq!(records[1]["at_ms"], FIRST_MS + 2, "the newest equal record: {text}");
    assert!(!writer.repeats.waits(), "no count waits after it");

    drop(sender);
    assert!(
        writer.next_entry(&receiver, &mut line).is_none(),
        "a log that is gone ends the writer"
    );
}

/// Inside the window the writer takes the next entry and writes no count; and a log that is
/// gone ends the writer also while a count waits.
#[test]
fn inside_the_window_the_writer_takes_the_next_entry_and_writes_no_count() {
    const FIRST_MS: u64 = 1_000;
    let dir = cmux_unix_socket::short_test_dir("srl");
    let mut writer = test_writer(&dir);
    writer.clock = || FIRST_MS + 10;
    let mut line = String::new();
    for number in 0..3 {
        writer.take(ended(REFUSED.0, Some(REFUSED.1), REFUSED.2, FIRST_MS + number), &mut line);
    }

    let (sender, receiver) = sync_channel(1);
    sender.send(ended("list-workspaces", None, "frontend", 1_005)).expect("the queue is open");
    let next = writer.next_entry(&receiver, &mut line);
    assert!(matches!(next, Some(Entry::Request(_))), "the entry of the queue is the next one");
    assert_eq!(records(&dir).len(), 1, "the window did not end: no count is written");
    assert!(writer.repeats.waits(), "the count of 2 waits");

    drop(sender);
    assert!(
        writer.next_entry(&receiver, &mut line).is_none(),
        "a log that is gone ends the writer"
    );
}

#[test]
fn a_plugin_restart_is_one_line_of_numbers() {
    let (dir, log) = open_log();
    log.plugin_restart(4, 2, Duration::from_secs(2));
    log.settle();

    let text = file_text(&dir);
    let records = records(&dir);
    assert_eq!(records.len(), 1, "one line for the restart: {text}");
    let record = records[0].as_object().expect("an object");
    assert_eq!(record["kind"], "plugin_restart");
    assert_eq!(record["side"], "daemon");
    assert_eq!(record["restarts"], 4);
    assert_eq!(record["failures"], 2);
    assert_eq!(record["delay_ms"], 2_000);
    let mut keys: Vec<&str> = record.keys().map(String::as_str).collect();
    keys.sort_unstable();
    let expected = ["at", "at_ms", "delay_ms", "failures", "kind", "restarts", "side"];
    assert_eq!(keys, expected, "the line holds no text of the plugin: {text}");
}
