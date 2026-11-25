//! The slow request log on the request path (diagnostics/request_log.rs): one record for a slow
//! request with the time of each part, none for a fast one, one for an error reply, one for a
//! long hold of the session lock, and nothing of a request line but its allow-listed keys.

use super::*;
use crate::diagnostics::request_log::FILE_NAME;

struct Logged {
    mux: Arc<Mux>,
    dir: cmux_unix_socket::TestDir,
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Logged {
    fn new() -> Self {
        Self::with_clock(crate::startup_timings::unix_now_ms)
    }

    /// A session whose slow request log has `clock` as its wall clock.
    fn with_clock(clock: crate::diagnostics::request_log::Clock) -> Self {
        let mux = test_mux();
        let dir = cmux_unix_socket::short_test_dir("srl-server");
        mux.open_slow_request_log(dir.path(), None, clock);
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux, dir, client, writer, outbound, scheduler }
    }

    /// Sends `line` as the connection's reader does, then writes its reply as the connection's
    /// writer thread does, after `hold`. Returns the reply.
    fn request(&self, line: &str, hold: Duration) -> Value {
        assert!(handle_connection_message(
            &self.mux,
            self.client,
            line,
            &self.writer,
            &self.scheduler
        ));
        let item = self.outbound.recv().expect("the request is answered");
        std::thread::sleep(hold);
        let mut socket = Vec::new();
        write_line_outbound_item(&mut socket, item).unwrap();
        serde_json::from_slice(&socket).expect("the reply is one JSON line")
    }

    /// The file's records, without the start line.
    fn records(&self) -> (String, Vec<Value>) {
        self.mux.connection_stats().request_log().expect("the log is open").settle();
        let text = std::fs::read_to_string(self.dir.path().join(FILE_NAME)).unwrap_or_default();
        let records = text
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("each line is one JSON object"))
            .filter(|record| record["kind"] != "start")
            .collect();
        (text, records)
    }
}

impl Drop for Logged {
    fn drop(&mut self) {
        self.scheduler.close();
        disconnect_client(&self.mux, self.client, false);
    }
}

#[test]
fn a_request_held_150_ms_gives_one_record_with_its_parts_and_a_fast_one_gives_none() {
    let logged = Logged::new();
    let fast = json!({"id": "fast-id", "cmd": "list-workspaces"}).to_string();
    let reply = logged.request(&fast, Duration::from_millis(5));
    assert_eq!(reply["ok"], true, "{reply}");
    let (text, records) = logged.records();
    assert!(records.is_empty(), "a 5 ms request left a record: {text}");

    let slow = json!({"id": "slow-id", "cmd": "list-workspaces"}).to_string();
    let reply = logged.request(&slow, Duration::from_millis(150));
    assert_eq!(reply["ok"], true, "{reply}");
    let (text, records) = logged.records();
    assert_eq!(records.len(), 1, "one record for the slow request: {text}");
    let record = &records[0];
    assert_eq!(record["kind"], "request");
    assert_eq!(record["side"], "daemon");
    assert_eq!(record["name"], "list-workspaces");
    assert_eq!(record["client"], logged.client);
    assert_eq!(record["outcome"], "ok");
    assert_eq!(record["request_bytes"], slow.len());
    assert!(record["reply_bytes"].as_u64().unwrap() > 0, "{text}");
    assert!(record["at_ms"].as_u64().unwrap() > 1_700_000_000_000, "{text}");
    let part = |name: &str| record[name].as_f64().unwrap_or_else(|| panic!("no {name}: {text}"));
    assert!(part("total_ms") >= 150.0, "{text}");
    assert!(part("reply_ms") >= 150.0, "the hold was in the reply's write: {text}");
    assert!(part("queue_ms") >= 0.0 && part("handler_ms") >= 0.0, "{text}");
    assert!(part("lock_wait_ms") >= 0.0 && part("registry_wait_ms") >= 0.0, "{text}");
    let sum = part("queue_ms") + part("handler_ms") + part("reply_ms");
    assert!((sum - part("total_ms")).abs() < 1.0, "the parts add up to the total: {text}");
    assert!(!text.contains("slow-id"), "the client's request id is not logged: {text}");
}

#[test]
fn an_error_reply_gives_a_record_with_no_text_of_the_request() {
    let logged = Logged::new();
    let refused =
        json!({"id": "typed secret", "cmd": "set-divider-visible", "split": 999_999, "visible": false})
            .to_string();
    let reply = logged.request(&refused, Duration::ZERO);
    assert_eq!(reply["ok"], false, "{reply}");
    let unknown = json!({"id": 2, "cmd": "no-such-command", "text": "typed secret"}).to_string();
    let reply = logged.request(&unknown, Duration::ZERO);
    assert_eq!(reply["ok"], false, "{reply}");

    let (text, records) = logged.records();
    assert_eq!(records.len(), 2, "one record for each error reply: {text}");
    assert_eq!(records[0]["name"], "set-divider-visible");
    assert_eq!(records[0]["outcome"], "error");
    assert_eq!(records[0]["error"], "layout-ratio-target-missing", "the code, not the message");
    assert_eq!(records[1]["name"], "other", "an unknown command's name is the client's text");
    assert_eq!(records[1]["outcome"], "error");
    for secret in ["typed", "secret", "no-such-command", "bad request", "unknown"] {
        assert!(!text.contains(secret), "{secret:?} is in the file: {text}");
    }
}

#[test]
fn a_long_hold_of_the_session_lock_gives_a_record_that_names_the_holder() {
    let logged = Logged::new();
    logged.mux.with_state(|_| {
        cmux_flow_trace::hop("test.long_hold.inside", 77, "00ff");
        std::thread::sleep(Duration::from_millis(150));
    });
    logged.mux.with_state(|_| std::thread::sleep(Duration::from_millis(5)));

    let (text, records) = logged.records();
    assert_eq!(records.len(), 1, "one record for the long hold: {text}");
    assert_eq!(records[0]["kind"], "lock");
    assert_eq!(records[0]["lock"], "mux.state");
    assert!(records[0]["held_ms"].as_f64().unwrap() >= 150.0, "{text}");
    let holder = records[0]["holder"].as_str().unwrap();
    assert!(holder.contains("slow_request_log.rs:"), "the holder's site: {text}");
    let recent = records[0]["recent"].as_array().expect("the hops before the hang");
    assert!(
        recent.iter().any(|hop| hop["hop"] == "test.long_hold.inside"
            && hop["flow"] == 77
            && hop["terminal"] == "00ff"
            && hop["ago_ms"].as_f64().unwrap() >= 150.0),
        "the hop inside the hold, with its age: {text}"
    );
}

#[test]
fn the_start_line_says_what_the_session_holds() {
    let logged = Logged::new();
    logged.mux.connection_stats().request_log().unwrap().settle();
    let text = std::fs::read_to_string(logged.dir.path().join(FILE_NAME)).unwrap();
    let start: Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
    assert_eq!(start["kind"], "start");
    assert_eq!(start["pid"], std::process::id());
    assert!(start["version"].is_string(), "{text}");
    assert!(start["workspaces"].is_u64() && start["surfaces"].is_u64(), "{text}");
    assert_eq!(start["slow_ms"], 100);
    assert_eq!(start["file_bytes"], 1_048_576);
}

/// What a reader of the file depends on for the session's journal plugin: the kind word `plugin`
/// and the error code, in the first record of a run, which is on disk at once. The daemon sets
/// the connection's kind at accept (`line_connection.rs`); here the test makes the same call,
/// and no plugin process runs.
#[test]
fn a_refused_request_of_the_plugin_connection_has_the_kind_word_plugin() {
    let logged = Logged::new();
    logged.writer.kind.registered(
        logged.mux.connection_stats().commands(),
        crate::diagnostics::ClientKind::Plugin,
    );
    let refused =
        json!({"id": 1, "cmd": "set-divider-visible", "split": 999_999, "visible": false})
            .to_string();
    let reply = logged.request(&refused, Duration::ZERO);
    assert_eq!(reply["ok"], false, "{reply}");

    let (text, records) = logged.records();
    assert_eq!(records.len(), 1, "the first refused request is written at once: {text}");
    assert_eq!(records[0]["client_kind"], "plugin", "{text}");
    assert_eq!(records[0]["error"], "layout-ratio-target-missing", "{text}");
    assert!(records[0].get("repeats").is_none(), "a first record has no count: {text}");
}

#[test]
fn equal_refused_requests_of_one_connection_write_one_line() {
    const REQUESTS: usize = 50;
    // The log's clock says 0 for the whole test. A record's time is the clock less the request's
    // own length, never below 0: each record has the time 0, the window of the run never ends,
    // and the count does not depend on how long the test takes.
    let logged = Logged::with_clock(|| 0);
    let refused =
        json!({"id": 1, "cmd": "set-divider-visible", "split": 999_999, "visible": false})
            .to_string();
    for _ in 0..REQUESTS {
        let reply = logged.request(&refused, Duration::ZERO);
        assert_eq!(reply["ok"], false, "{reply}");
    }

    // The writer's thread counts the 49 that follow the first one; their count is due at the
    // end of the run's window, which the clock of this test never reaches.
    let (text, records) = logged.records();
    assert_eq!(records.len(), 1, "{REQUESTS} equal refused requests: {text}");
    assert_eq!(records[0]["error"], "layout-ratio-target-missing", "{text}");
    assert!(records[0].get("repeats").is_none(), "a first record has no count: {text}");
    // A connection that is not the plugin's and declared nothing has no kind word.
    assert!(records[0].get("client_kind").is_none(), "{text}");
}

#[test]
fn a_restart_of_the_journal_plugin_gives_one_line_with_its_numbers() {
    let logged = Logged::new();
    logged.mux.record_journal_plugin_restart(crate::journal_plugin::JournalPluginRestart {
        restarts: 3,
        failures: 2,
        delay: Duration::from_secs(2),
    });

    let (text, records) = logged.records();
    assert_eq!(records.len(), 1, "one line for the restart: {text}");
    assert_eq!(records[0]["kind"], "plugin_restart");
    assert_eq!(records[0]["restarts"], 3);
    assert_eq!(records[0]["failures"], 2);
    assert_eq!(records[0]["delay_ms"], 2_000);
}
