//! Request spans: the `daemon.request` slice and its instants, the per-class
//! latency histograms and the dispatch queue in `server-stats`. Cases that
//! start tracing run in a child of this test binary, so the process-wide
//! trace state never reaches another test.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_trace::{Decoded, DecodedRecord, Phase, Role, decode};
use serde_json::{Value, json};

use super::super::client_registry::ClientTransport;
use super::super::command_names::{COMMANDS, MethodClass};
use super::super::connection_frame::handle_connection_frame;
use super::super::connection_scheduler::ConnectionSurfaceScheduler;
use super::super::tests::{captured_writer, test_mux};
use super::super::{Command, Mux, handle_command};
use super::{AsyncReply, RequestArrival, RequestSpan, request_id_hash};
use crate::diagnostics::{REQUEST_CLASSES, RequestStats};

/// Sends each line through the connection's frame handler, as its reader
/// does, then drains the connection's dispatcher.
fn run_lines(mux: &Arc<Mux>, lines: &[&str]) -> Vec<Value> {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    for line in lines {
        assert!(handle_connection_frame(
            mux,
            client,
            ClientTransport::Unix,
            line,
            &writer,
            &scheduler
        ));
    }
    scheduler.finish_and_wait();
    std::iter::from_fn(|| outbound.try_pop())
        .map(|text| serde_json::from_str(&text).expect("a JSON reply"))
        .collect()
}

fn server_stats(mux: &Arc<Mux>, include: Value) -> Value {
    let (writer, _) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let command: Command =
        serde_json::from_value(json!({"cmd": "server-stats", "include": include})).unwrap();
    handle_command(mux, client, command, &writer).unwrap()
}

#[test]
fn request_spans_classes_are_the_method_classes_in_order() {
    assert_eq!(MethodClass::ALL.len(), REQUEST_CLASSES.len());
    for (index, class) in MethodClass::ALL.into_iter().enumerate() {
        assert_eq!(class as usize, index, "{class:?} is not at its index");
        assert_eq!(class.as_str(), REQUEST_CLASSES[index], "{class:?} has another name");
    }
}

#[test]
fn request_spans_method_id_is_the_commands_row() {
    for (cmd, wire) in [(Command::Ping, "ping"), (Command::ReloadConfig, "reload-config")] {
        let row = &COMMANDS[usize::from(cmd.method_id())];
        assert_eq!(row.wire, wire);
        assert_eq!(row.wire, cmd.wire_name());
    }
}

#[test]
fn request_spans_request_id_hash_is_fnv1a_of_the_id_text() {
    assert_eq!(request_id_hash(None), 0);
    // FNV-1a 64 of "1" and of "\"a\"".
    assert_eq!(request_id_hash(Some(&json!(1))), 0xaf63_ac4c_8601_9afc);
    assert_eq!(request_id_hash(Some(&json!("a"))), request_id_hash(Some(&json!("a"))));
    assert_ne!(request_id_hash(Some(&json!("1"))), request_id_hash(Some(&json!(1))));
}

#[test]
fn request_spans_server_stats_reports_latency_by_class_only_when_included() {
    let mux = test_mux();
    let replies = run_lines(
        &mux,
        &[r#"{"id":1,"cmd":"ping"}"#, r#"{"id":2,"cmd":"ping"}"#, r#"{"id":3,"cmd":"ping"}"#],
    );
    assert_eq!(replies.len(), 3, "{replies:?}");

    let plain = server_stats(&mux, Value::Null);
    assert!(plain.get("request_latency_us").is_none(), "{plain}");
    assert!(plain.get("dispatch_queue_us").is_none(), "{plain}");

    let stats = server_stats(&mux, json!(["requests"]));
    let latency = &stats["request_latency_us"];
    for class in REQUEST_CLASSES {
        assert!(latency[class]["count"].is_u64(), "no {class} histogram: {stats}");
    }
    // The three pings; the server-stats calls above ran outside a connection.
    assert_eq!(latency["query"]["count"], 3, "{stats}");
    assert_eq!(latency["topology"]["count"], 0, "{stats}");
    assert_eq!(stats["dispatch_queue_us"]["count"], 3, "{stats}");
}

#[test]
fn request_spans_count_a_request_that_returns_early() {
    let mux = test_mux();
    // vt-state answers on its own path; an invalid url-open answers before
    // its worker would start.
    let replies = run_lines(
        &mux,
        &[
            r#"{"id":1,"cmd":"vt-state","surface":424242}"#,
            r#"{"id":2,"cmd":"url-open","terminal_id":"t-none","url":"https://example.com"}"#,
        ],
    );
    assert_eq!(replies.len(), 2, "{replies:?}");
    let stats = mux.request_stats().snapshot();
    let total = |snapshot: &crate::diagnostics::RequestLatencySnapshot| {
        [
            &snapshot.topology,
            &snapshot.terminal_io,
            &snapshot.create,
            &snapshot.query,
            &snapshot.browser,
            &snapshot.agent,
            &snapshot.cloud,
            &snapshot.other,
        ]
        .iter()
        .map(|histogram| histogram.count)
        .sum::<u64>()
    };
    assert_eq!(total(&stats.request_latency_us), 2, "{stats:?}");
    assert_eq!(stats.request_latency_us.browser.count, 1, "url-open is a browser request");
}

#[test]
fn request_spans_record_once_from_arrival() {
    let stats = Arc::new(RequestStats::default());
    let arrived = Instant::now() - Duration::from_millis(40);
    let arrival = RequestArrival { arrived, parsed: arrived + Duration::from_millis(10) };
    {
        let mut span = RequestSpan::open(&stats, &Command::Ping, None, arrival);
        assert!(span.reply(|| true));
    }
    let snapshot = stats.snapshot();
    assert_eq!(snapshot.request_latency_us.query.count, 1, "the drop after reply counted again");
    assert!(snapshot.request_latency_us.query.max >= 40_000, "{snapshot:?}");
    assert_eq!(snapshot.dispatch_queue_us.count, 1);
    assert!(snapshot.dispatch_queue_us.max >= 30_000, "{snapshot:?}");

    // An async reply counts when the worker drops it, not when the span ends.
    let reply: AsyncReply = {
        let mut span = RequestSpan::open(&stats, &Command::Ping, None, RequestArrival::now());
        span.start_async()
    };
    assert_eq!(stats.snapshot().request_latency_us.query.count, 1);
    std::thread::spawn(move || drop(reply)).join().unwrap();
    assert_eq!(stats.snapshot().request_latency_us.query.count, 2);
}

// MARK: trace records

fn scratch_dir(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-request-spans-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// The child half of [`request_spans_decode_as_pairs_with_four_instants`]
/// (does nothing in a normal run).
#[test]
fn request_spans_child_process() {
    let Some(dir) = std::env::var_os("CMUX_REQUEST_SPANS_CHILD_DIR") else { return };
    child_three_requests(Path::new(&dir));
}

#[test]
fn request_spans_decode_as_pairs_with_four_instants() {
    let dir = scratch_dir("pairs");
    let status = std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args([
            "--exact",
            "server::request_spans::tests::request_spans_child_process",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("CMUX_REQUEST_SPANS_CHILD_DIR", &dir)
        .status()
        .expect("runs the child");
    let _ = std::fs::remove_dir_all(&dir);
    assert!(status.success(), "the child failed (see its output above)");
}

fn text<'a>(decoded: &'a Decoded, record: &DecodedRecord) -> &'a str {
    decoded.name(record.name).unwrap_or("<no name>")
}

fn child_three_requests(dir: &Path) {
    cmux_trace::init_blackbox(dir, Role::Daemon)
        .expect("first init")
        .wait()
        .expect("the black box moved into its file");
    let mux = test_mux();
    let replies = run_lines(
        &mux,
        &[r#"{"id":1,"cmd":"ping"}"#, r#"{"id":2,"cmd":"ping"}"#, r#"{"id":3,"cmd":"ping"}"#],
    );
    assert_eq!(replies.len(), 3, "{replies:?}");

    let decoded = decode(&cmux_trace::snapshot_active().expect("initialised")).expect("decodes");
    let mut by_thread: HashMap<(u32, u32), Vec<DecodedRecord>> = HashMap::new();
    for record in &decoded.records {
        if text(&decoded, record).starts_with("daemon.request") {
            by_thread
                .entry((record.thread_index, record.thread_generation))
                .or_default()
                .push(*record);
        }
    }
    let mut requests = Vec::new();
    for records in by_thread.values_mut() {
        records.sort_by_key(|record| (record.position, record.slot));
        let mut open: Option<(DecodedRecord, Vec<String>)> = None;
        for record in records.iter() {
            let name = text(&decoded, record).to_owned();
            match Phase::from_raw(record.phase) {
                Some(Phase::Begin) => {
                    assert_eq!(name, "daemon.request");
                    assert!(open.is_none(), "a request slice opened inside another");
                    open = Some((*record, Vec::new()));
                }
                Some(Phase::Instant) => {
                    open.as_mut().expect("an instant outside a request slice").1.push(name);
                }
                Some(Phase::End) => {
                    let (begin, instants) = open.take().expect("an end with no begin");
                    assert_eq!(name, "daemon.request");
                    assert!(record.t_ns >= begin.t_ns, "a slice ended before it began");
                    requests.push((begin, instants));
                }
                other => panic!("unexpected {other:?} record {name}"),
            }
        }
        assert!(open.is_none(), "a request slice never ended");
    }

    assert_eq!(requests.len(), 3, "three requests, three slices: {requests:?}");
    let mut hashes: Vec<u64> = requests.iter().map(|(begin, _)| begin.arg1).collect();
    hashes.sort_unstable();
    let mut expected: Vec<u64> =
        [1, 2, 3].iter().map(|id| request_id_hash(Some(&json!(id)))).collect();
    expected.sort_unstable();
    assert_eq!(hashes, expected, "each slice names its request id");
    for (begin, instants) in &requests {
        assert_eq!(begin.arg0, u64::from(Command::Ping.method_id()), "the slice names its method");
        assert_eq!(
            instants,
            &[
                "daemon.request.parsed",
                "daemon.request.dispatched",
                "daemon.request.reply.queued",
                "daemon.request.reply.sent",
            ],
            "a request slice holds its four instants in order"
        );
    }
}
