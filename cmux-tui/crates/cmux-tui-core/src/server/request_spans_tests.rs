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
use super::{AsyncReply, RequestArrival, RequestMethod, RequestSpan, request_id_hash};
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

/// Every method has its own lock op inside the lock tables, named by its
/// wire name (`debug-daemon-locks`).
#[test]
fn request_spans_every_method_has_a_distinct_named_lock_op() {
    use crate::diagnostics::{LOCK_OPS, LockOp};
    use crate::resource::ResourceOperation;
    let mut methods: Vec<(RequestMethod, String)> = COMMANDS
        .iter()
        .enumerate()
        .map(|(index, row)| {
            let method = RequestMethod { id: index as u16, class: row.class };
            (method, row.wire.to_owned())
        })
        .collect();
    methods.extend(ResourceOperation::ALL.iter().map(|operation| {
        (RequestMethod::of_resource(*operation), operation.wire_name().to_owned())
    }));
    methods.extend(MethodClass::ALL.iter().map(|class| {
        let method =
            RequestMethod { id: RequestMethod::ROUTED_BASE + *class as u16, class: *class };
        (method, format!("routed.{}", class.as_str()))
    }));
    let mut seen = std::collections::HashSet::new();
    for (method, name) in methods {
        let op = method.lock_op();
        assert!(usize::from(op.0) < LOCK_OPS, "{name} is past the lock table");
        assert_ne!(op, LockOp::NONE, "{name}");
        assert!(seen.insert(op.0), "{name} shares lock op {}", op.0);
        assert_eq!(super::lock_op_name(op), name);
    }
    assert_eq!(super::lock_op_name(LockOp::NONE), "none");
}

#[test]
fn request_spans_request_id_hash_is_fnv1a_of_the_id_text() {
    assert_eq!(request_id_hash::<Value>(None), 0);
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
fn request_spans_count_resource_lines_and_feature_routes() {
    let mux = test_mux();
    let resource = |id: &str, operation: &str| {
        json!({"protocol":"cmux.protocol/2","type":"request","id":id,"operation":operation,
            "params":{"machine":"current","session":"current"}})
        .to_string()
    };
    let (ping, list) = (resource("r-1", "session.ping"), resource("r-2", "workspace.list"));
    let replies = run_lines(
        &mux,
        &[
            &ping,
            &list,
            r#"{"id":1,"cmd":"agent-inventory","unknown_field":1}"#,
            r#"{"id":2,"cmd":"no-such-command"}"#,
        ],
    );
    assert_eq!(replies.len(), 4, "{replies:?}");
    let stats = mux.request_stats().snapshot();
    let latency = &stats.request_latency_us;
    assert_eq!(latency.query.count, 2, "both v2 reads are queries: {stats:?}");
    assert_eq!(latency.agent.count, 1, "the agent route: {stats:?}");
    assert_eq!(latency.other.count, 1, "the bad request: {stats:?}");
    assert_eq!(stats.dispatch_queue_us.count, 4, "{stats:?}");
}

#[test]
fn request_spans_resource_operations_take_the_command_classes() {
    use crate::resource::ResourceOperation as Op;
    for (operation, class) in [
        (Op::WorkspaceCreate, MethodClass::Create),
        (Op::TabCreateTerminal, MethodClass::Create),
        (Op::PaneSplit, MethodClass::Create),
        (Op::PaneCreate, MethodClass::Create),
        (Op::WorkspaceList, MethodClass::Query),
        (Op::SessionPing, MethodClass::Query),
        (Op::WorkspaceRename, MethodClass::Topology),
        (Op::PaneClose, MethodClass::Topology),
        (Op::TerminalInputWrite, MethodClass::TerminalIo),
        (Op::BrowserNavigate, MethodClass::Browser),
        (Op::ConversationSend, MethodClass::Agent),
        (Op::SettingsSet, MethodClass::Other),
    ] {
        let method = RequestMethod::of_resource(operation);
        assert_eq!(method.class, class, "{operation:?}");
        assert!(
            method.id >= RequestMethod::RESOURCE_BASE && method.id < RequestMethod::ROUTED_BASE
        );
    }
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

/// One `daemon.request` slice: its begin and the records inside it.
#[derive(Debug)]
struct Slice {
    begin: DecodedRecord,
    inner: Vec<(Phase, String, DecodedRecord)>,
}

impl Slice {
    fn instants(&self) -> Vec<&str> {
        self.inner
            .iter()
            .filter(|(phase, ..)| *phase == Phase::Instant)
            .map(|(_, name, _)| name.as_str())
            .collect()
    }
}

/// Every `daemon.request` slice in the trace. Each begin has its end on
/// its thread, and slices do not nest.
fn request_slices(decoded: &Decoded) -> Vec<Slice> {
    let mut by_thread: HashMap<(u32, u32), Vec<DecodedRecord>> = HashMap::new();
    for record in &decoded.records {
        if text(decoded, record).starts_with("daemon.request") {
            by_thread
                .entry((record.thread_index, record.thread_generation))
                .or_default()
                .push(*record);
        }
    }
    let mut slices = Vec::new();
    for records in by_thread.values_mut() {
        records.sort_by_key(|record| (record.position, record.slot));
        let mut open: Option<Slice> = None;
        for record in records.iter() {
            let name = text(decoded, record).to_owned();
            match Phase::from_raw(record.phase) {
                Some(Phase::Begin) => {
                    assert_eq!(name, "daemon.request");
                    assert!(open.is_none(), "a request slice opened inside another");
                    open = Some(Slice { begin: *record, inner: Vec::new() });
                }
                Some(phase @ (Phase::Instant | Phase::AsyncBegin | Phase::AsyncEnd)) => {
                    let slice = open.as_mut().unwrap_or_else(|| {
                        panic!("{name} outside a request slice: the reply left its span")
                    });
                    slice.inner.push((phase, name, *record));
                }
                Some(Phase::End) => {
                    let slice = open.take().expect("an end with no begin");
                    assert_eq!(name, "daemon.request");
                    assert!(record.t_ns >= slice.begin.t_ns, "a slice ended before it began");
                    slices.push(slice);
                }
                other => panic!("unexpected {other:?} record {name}"),
            }
        }
        assert!(open.is_none(), "a request slice never ended");
    }
    slices
}

fn child_three_requests(dir: &Path) {
    cmux_trace::init_blackbox(dir, Role::Daemon)
        .expect("first init")
        .wait()
        .expect("the black box moved into its file");
    let mux = test_mux();
    let resource = json!({"protocol":"cmux.protocol/2","type":"request","id":"r-1",
        "operation":"session.ping","params":{"machine":"current","session":"current"}})
    .to_string();
    let replies = run_lines(
        &mux,
        &[
            r#"{"id":1,"cmd":"ping"}"#,
            r#"{"id":2,"cmd":"ping"}"#,
            r#"{"id":3,"cmd":"ping"}"#,
            r#"{"id":4,"cmd":"vt-state","surface":424242}"#,
            r#"{"id":5,"cmd":"url-open","terminal_id":"t-none","url":"https://example.com"}"#,
            &resource,
            r#"{"id":6,"cmd":"agent-inventory","unknown_field":1}"#,
        ],
    );
    assert_eq!(replies.len(), 7, "{replies:?}");

    let decoded = decode(&cmux_trace::snapshot_active().expect("initialised")).expect("decodes");
    let slices = request_slices(&decoded);
    assert_eq!(slices.len(), 7, "seven requests, seven slices: {slices:?}");
    let hash = |id: Value| request_id_hash(Some(&id));
    let find = |id: Value| {
        let hash = hash(id.clone());
        slices.iter().find(|slice| slice.begin.arg1 == hash).unwrap_or_else(|| {
            panic!("no slice names request {id}: {slices:?}");
        })
    };

    for id in [1, 2, 3] {
        let slice = find(json!(id));
        assert_eq!(
            slice.begin.arg0,
            u64::from(Command::Ping.method_id()),
            "the slice names its method"
        );
        assert_eq!(
            slice.instants(),
            [
                "daemon.request.parsed",
                "daemon.request.dispatched",
                "daemon.request.handled",
                "daemon.request.reply.queued",
            ],
            "a request slice holds its four instants in order"
        );
    }
    // vt-state answers on its own path, under the same four instants.
    assert_eq!(find(json!(4)).instants().len(), 4, "{:?}", find(json!(4)));

    // url-open's reply is the async slice's: begin, its reply, end.
    let url_open = find(json!(5));
    let async_records: Vec<_> = url_open
        .inner
        .iter()
        .filter(|(phase, ..)| matches!(phase, Phase::AsyncBegin | Phase::AsyncEnd))
        .collect();
    let [(Phase::AsyncBegin, begin_name, begin), (Phase::AsyncEnd, end_name, end)] =
        async_records.as_slice()
    else {
        panic!("url-open has no async begin and end: {url_open:?}");
    };
    assert_eq!(
        (begin_name.as_str(), end_name.as_str()),
        ("daemon.request.async", "daemon.request.async")
    );
    assert_eq!(begin.arg1, end.arg1, "the async slice ends under its own id");
    assert_ne!(begin.arg1, 0);
    let url_open_method = Command::method_of_wire("url-open").expect("a command").0;
    assert_eq!(begin.arg0, u64::from(url_open_method), "the async slice names its method");
    assert!(
        url_open
            .instants()
            .ends_with(&["daemon.request.async.handled", "daemon.request.async.reply.queued"]),
        "{url_open:?}"
    );

    // A v2 resource line and a feature route each get their slice.
    let resource = find(json!("r-1"));
    let session_ping = RequestMethod::of_resource(crate::resource::ResourceOperation::SessionPing);
    assert_eq!(resource.begin.arg0, u64::from(session_ping.id));
    assert_eq!(
        resource.instants(),
        ["daemon.request.parsed", "daemon.request.dispatched", "daemon.request.reply.queued"],
        "{resource:?}"
    );
    let routed = find(json!(6));
    assert_eq!(
        routed.begin.arg0,
        u64::from(RequestMethod::ROUTED_BASE + MethodClass::Agent as u16),
        "{routed:?}"
    );
    assert_eq!(routed.instants().last(), Some(&"daemon.request.reply.queued"), "{routed:?}");
}
