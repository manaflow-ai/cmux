//! acpmux in the Release trace ring (`src/trace_layer.rs`): with the black box on and no
//! recording, an event costs no allocation; with a recording on, events decode as instants under
//! their callsite's name and every request over a connection as one async slice keyed by its id,
//! which ends once when the request completes, panics or is dropped.
//! One test: the ring is process-wide, and the cases must run in this order.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent: the hub serves list requests only.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use acpmux::trace_layer::{RequestSlice, TraceLayer, method_hash, request_slice_id};
use cmux_trace::{FLAG_ID, Phase, Role, category};
use serde_json::{Value, json};
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tracing_subscriber::layer::SubscriberExt;

struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

// SAFETY: forwards every call to the system allocator; the counter is a const-initialised thread-local Cell.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc(layout) }
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc_zeroed(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn allocations() -> usize {
    ALLOCATIONS.with(Cell::get)
}

/// The connections of the request that panics and the one dropped before it completes.
const PANIC_CONN: &str = "a connection whose request panics";
const DROP_CONN: &str = "a connection whose request is dropped";

/// The target of the test's `log` crate record, as a dependency's module path would be.
const LOG_TARGET: &str = "acpmux_trace_probe::dependency";

fn log_events(count: u64) {
    for index in 0..count {
        tracing::info!(index, text = "dropped", "trace layer probe");
    }
}

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({})).expect("an empty config");
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent"))
        .expect("a memory store");
    Hub::new(cfg, store)
}

/// Sends `requests` on one connection and waits for each reply; the connection's id is not
/// visible to a client, so the slices are matched by the request ids they carry.
async fn serve_requests(hub: &Arc<Hub>, requests: &[(Value, &str)]) {
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    let served = tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    for (id, method) in requests {
        let line = Message::Request { id: id.clone(), method: (*method).into(), params: None };
        tx.send(line.to_line()).await.expect("the connection reads");
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), rx.recv())
                .await
                .expect("a reply in time")
                .expect("the connection writes");
            let reply: Value = serde_json::from_str(&line).expect("a JSON reply");
            if reply.get("id") == Some(id) {
                break;
            }
        }
    }
    drop(tx);
    let _ = tokio::time::timeout(Duration::from_secs(20), served).await;
}

#[tokio::test]
async fn trace_layer_records_events_and_request_slices_only_when_on() {
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("acpmux-trace-layer-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let open = cmux_trace::init_blackbox(&dir, Role::Acpmux).expect("the first init");
    open.wait().expect("the black box has its file");
    // The daemon's `.init()` installs the same forwarder of `log` crate records.
    tracing_log::LogTracer::init().expect("the log forwarder installs");
    let subscriber = tracing_subscriber::registry().with(TraceLayer::new());
    let _default = tracing::subscriber::set_default(subscriber);

    // The black box runs, no recording: an event is one load and a branch.
    assert!(!cmux_trace::enabled(category::RECORDING));
    log_events(1);
    let before = allocations();
    log_events(10_000);
    assert_eq!(allocations() - before, 0, "an event allocated while no recording runs");

    // A recording of another category records no event instants.
    let status = cmux_trace::start_recording(category::FRAME).expect("a frame recording starts");
    let recording = status.recording_path.expect("a recording file");
    log_events(2);
    cmux_trace::stop().expect("the frame recording stops");
    let decoded = cmux_trace::decode(&std::fs::read(&recording).expect("reads the recording"))
        .expect("the frame recording decodes");
    let prefix = format!("log.{}:", module_path!());
    assert!(
        !decoded.names.iter().any(|n| n.text.starts_with(&prefix)),
        "an event recorded under a frame-only recording: {:?}",
        decoded.names
    );

    let status = cmux_trace::start_recording(category::ALL).expect("a recording starts");
    let recording = status.recording_path.expect("a recording file");
    log_events(3);
    log::warn!(target: LOG_TARGET, "a dependency's log record");
    let hub = hub();
    let requests = [(json!(7), "_acpmux/sessions"), (json!("seven"), "_acpmux/sessions")];
    serve_requests(&hub, &requests).await;
    // A request whose task panics, and one dropped before it completes (its task aborted, as a
    // closing connection's are), still end their slices.
    let panicked = tokio::spawn(
        RequestSlice::begin(PANIC_CONN, &json!(1), "_acpmux/sessions")
            .wrap(async { panic!("a request that panics") }),
    )
    .await;
    assert!(panicked.expect_err("the request panics").is_panic());
    let dropped = tokio::spawn(
        RequestSlice::begin(DROP_CONN, &json!(1), "_acpmux/sessions")
            .wrap(std::future::pending::<()>()),
    );
    tokio::task::yield_now().await;
    dropped.abort();
    assert!(dropped.await.expect_err("the request is dropped").is_cancelled());
    cmux_trace::stop().expect("the recording stops");

    let decoded = cmux_trace::decode(&std::fs::read(&recording).expect("reads the recording"))
        .expect("the recording decodes");
    // This file's one event callsite, named `log.<module>:<line>`, in the `log` category.
    let log_bit = category::LOG.trailing_zeros() as u8;
    let names: Vec<_> = decoded.names.iter().filter(|n| n.text.starts_with(&prefix)).collect();
    assert_eq!(names.len(), 1, "one name per callsite: {names:?}");
    assert_eq!(names[0].category, log_bit, "event names carry the category they record under");
    let instants: Vec<_> = decoded.records.iter().filter(|r| r.name == names[0].id).collect();
    assert_eq!(instants.len(), 3, "one instant per event while recording");
    assert!(
        instants.iter().all(|r| r.phase == Phase::Instant as u8 && r.arg0 == 3 && r.arg1 == 0),
        "an info instant, its fields dropped: {instants:?}"
    );

    // A `log` crate record keeps its own target and line, not tracing-log's shared callsite.
    let log_prefix = format!("log.{LOG_TARGET}:");
    let log_names: Vec<_> =
        decoded.names.iter().filter(|n| n.text.starts_with(&log_prefix)).collect();
    assert_eq!(log_names.len(), 1, "one name for the log record's site: {:?}", decoded.names);
    assert!(log_names[0].text[log_prefix.len()..].parse::<u32>().is_ok(), "{log_names:?}");
    assert_eq!(log_names[0].category, log_bit);
    assert!(
        !decoded.names.iter().any(|n| n.text.starts_with("log.log")),
        "a log record named by tracing-log's shared callsite: {:?}",
        decoded.names
    );
    assert!(
        !decoded.names.iter().any(|n| n.text.starts_with("task.") && n.text.contains(':')),
        "an event under the task category: {:?}",
        decoded.names
    );
    let log_instants: Vec<_> =
        decoded.records.iter().filter(|r| r.name == log_names[0].id).collect();
    assert_eq!(log_instants.len(), 1);
    assert_eq!(log_instants[0].arg0, 2, "a warn instant");

    let slices: Vec<_> =
        decoded.records.iter().filter(|r| decoded.name(r.name) == Some("daemon.request")).collect();
    let begins: Vec<_> = slices.iter().filter(|r| r.phase == Phase::AsyncBegin as u8).collect();
    let ends: Vec<_> = slices.iter().filter(|r| r.phase == Phase::AsyncEnd as u8).collect();
    let slices_in_all = requests.len() + 2;
    assert_eq!(begins.len(), slices_in_all, "one begin per request: {slices:?}");
    assert_eq!(ends.len(), slices_in_all, "one end per request: {slices:?}");
    assert!(slices.iter().all(|r| r.flags & FLAG_ID != 0), "arg1 is the slice id");
    assert!(begins.iter().all(|r| r.arg0 == method_hash("_acpmux/sessions")));
    for begin in &begins {
        let ended: Vec<_> = ends.iter().filter(|end| end.arg1 == begin.arg1).collect();
        assert_eq!(ended.len(), 1, "the slice ends once: {slices:?}");
        assert!(ended[0].t_ns >= begin.t_ns, "the slice ends after it begins");
    }
    let ids: std::collections::HashSet<u64> = begins.iter().map(|r| r.arg1).collect();
    assert_eq!(ids.len(), slices_in_all, "each request has its own slice id");
    for (conn, how) in [(PANIC_CONN, "panics"), (DROP_CONN, "is dropped")] {
        let id = request_slice_id(conn, &json!(1));
        assert!(ids.contains(&id), "the request that {how} begins its slice: {slices:?}");
    }
    // The slice id hashes the connection with the request id; the same request id on another
    // connection gets another id.
    assert!(!ids.contains(&request_slice_id("another connection", &json!(7))));
    let _ = std::fs::remove_dir_all(&dir);
}
