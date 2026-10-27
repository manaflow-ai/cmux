//! `server-stats` `ipc_methods`: request latency, handler time and lock wait
//! by method (request_spans.rs records them, diagnostics/method_latency.rs
//! keeps them).

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::client_registry::ClientTransport;
use super::super::command_names::{COMMANDS, MethodClass};
use super::super::connection_frame::handle_connection_frame;
use super::super::connection_scheduler::ConnectionSurfaceScheduler;
use super::super::request_spans::{
    REQUEST_METHOD_SLOTS, RequestArrival, RequestMethod, RequestSpan,
};
use super::super::tests::captured_writer;
use super::super::{Command, Mux, handle_command};
use crate::diagnostics::{LockStats, LogLinearHistogram, MethodSample, RequestStats};
use crate::resource::ResourceOperation;

/// The shared bucket vector: the app's send-to-reply histograms
/// (DaemonWireStatsTests) and bench-daemon-latency.py check theirs against it.
const BUCKET_FIXTURE: &str =
    include_str!("../../../../spec/fixtures/ipc-method-latency/buckets.json");

/// Sends each line through a new connection's frame handler, as its reader
/// does, then drains the connection's dispatcher.
fn run_lines(mux: &Arc<Mux>, lines: &[&str]) {
    let (writer, _) = captured_writer();
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
}

fn server_stats(mux: &Arc<Mux>, include: Value) -> Value {
    let (writer, _) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let command: Command =
        serde_json::from_value(json!({"cmd": "server-stats", "include": include})).unwrap();
    handle_command(mux, client, command, &writer).unwrap()
}

fn method<'a>(methods: &'a Value, name: &str) -> &'a Value {
    methods
        .as_array()
        .and_then(|methods| methods.iter().find(|row| row["method"] == name))
        .unwrap_or_else(|| panic!("no {name} row: {methods}"))
}

fn sdk_schema() -> Value {
    serde_json::from_str(include_str!("../../../../spec/sdk-schema.json")).unwrap()
}

/// The `method_id` of v12 command `name` in spec/sdk-schema.json.
fn schema_method_id(name: &str) -> u64 {
    sdk_schema()["commands"][name]["method_id"]
        .as_u64()
        .unwrap_or_else(|| panic!("sdk-schema.json has no method_id for {name}"))
}

#[test]
fn server_stats_ipc_methods_reports_each_method_that_ran() {
    let mux = Mux::new_for_test("server-stats-ipc", crate::SurfaceOptions::default());
    run_lines(
        &mux,
        &[
            r#"{"id":1,"cmd":"ping"}"#,
            r#"{"id":2,"cmd":"ping"}"#,
            r#"{"id":3,"cmd":"ping"}"#,
            r#"{"id":4,"cmd":"identify"}"#,
        ],
    );
    let plain = server_stats(&mux, json!(["requests", "ipc"]));
    assert!(plain.get("ipc_methods").is_none(), "absent unless named: {plain}");

    let full = server_stats(&mux, json!(["ipc_methods"]));
    let methods = &full["ipc_methods"];
    let ping = method(methods, "ping");
    for histogram in ["latency_us", "handler_us", "lock_wait_us"] {
        assert_eq!(ping[histogram]["count"], json!(3), "{histogram}: {methods}");
        for field in ["p50", "p95", "p99", "max"] {
            assert!(ping[histogram][field].is_u64(), "{histogram}.{field}: {ping}");
        }
    }
    assert_eq!(ping["class"], json!("query"), "{methods}");
    assert_eq!(ping["trace_id"], json!(Command::Ping.method_id()), "{methods}");
    assert!(ping["latency_us"]["p50"].as_u64() <= ping["latency_us"]["p99"].as_u64(), "{ping}");
    assert!(ping["handler_us"]["max"].as_u64() <= ping["latency_us"]["max"].as_u64(), "{ping}");
    assert_eq!(method(methods, "identify")["latency_us"]["count"], json!(1), "{methods}");
    let ids: Vec<u64> =
        methods.as_array().unwrap().iter().filter_map(|row| row["id"].as_u64()).collect();
    assert!(ids.windows(2).all(|pair| pair[0] < pair[1]), "rows by schema method id: {ids:?}");
}

/// The app's `debug.daemon.wire` rows carry the schema method id: a daemon
/// row joins them on `id`, and the id does not move when COMMANDS gains a row.
#[test]
fn server_stats_ipc_methods_id_is_the_schema_method_id() {
    let mux = Mux::new_for_test("server-stats-ipc-id", crate::SurfaceOptions::default());
    run_lines(&mux, &[r#"{"id":1,"cmd":"ping"}"#, r#"{"id":2,"cmd":"identify"}"#]);
    let full = server_stats(&mux, json!(["ipc_methods"]));
    let methods = &full["ipc_methods"];
    for name in ["ping", "identify"] {
        assert_eq!(method(methods, name)["id"], json!(schema_method_id(name)), "{methods}");
    }
    // Every command the schema lists reads back with its schema id.
    let schema = sdk_schema();
    for (slot, row) in COMMANDS.iter().enumerate() {
        let named = RequestMethod::of_slot(slot);
        let expected = schema["commands"][row.wire]["method_id"].as_u64();
        assert_eq!(named.id.map(u64::from), expected, "{}", row.wire);
    }
    // A feature-route line has no schema method.
    assert_eq!(RequestMethod::of_slot(REQUEST_METHOD_SLOTS - 1).id, None);
}

/// Every command, resource operation and route class has its own slot, below
/// the table's size, and the slot reads back to the same method.
#[test]
fn server_stats_ipc_methods_slots_are_one_per_method() {
    let mut methods: Vec<RequestMethod> = COMMANDS
        .iter()
        .enumerate()
        .map(|(row, command)| {
            let (id, class) = Command::method_of_wire(command.wire).expect("a command's wire name");
            assert_eq!(usize::from(id), row);
            RequestMethod { id, class }
        })
        .collect();
    methods.extend(ResourceOperation::ALL.iter().map(|op| RequestMethod::of_resource(*op)));
    methods.extend(MethodClass::ALL.iter().map(|class| RequestMethod {
        id: RequestMethod::ROUTED_BASE + *class as u16,
        class: *class,
    }));
    assert_eq!(methods.len(), REQUEST_METHOD_SLOTS);
    let mut seen = vec![false; REQUEST_METHOD_SLOTS];
    for method in methods {
        let slot = method.slot();
        assert!(slot < REQUEST_METHOD_SLOTS, "{method:?} -> {slot}");
        assert!(!seen[slot], "{method:?} shares slot {slot}");
        seen[slot] = true;
        let named = RequestMethod::of_slot(slot);
        assert_eq!(named.trace_id, method.id, "{named:?}");
        assert_eq!(named.class, method.class.as_str(), "{named:?}");
    }
    assert_eq!(RequestMethod::of_slot(0).method, COMMANDS[0].wire);
    for operation in ResourceOperation::ALL {
        let slot = RequestMethod::of_resource(*operation).slot();
        assert_eq!(RequestMethod::of_slot(slot).method, operation.wire_name());
    }
    assert_eq!(RequestMethod::of_slot(REQUEST_METHOD_SLOTS - 1).method, "route:other");
}

/// The shared vector is the Rust histogram's bucketing, so the app and the
/// bench, which check theirs against it, bucket as the daemon does.
#[test]
fn server_stats_ipc_methods_bucket_vector_is_the_histograms() {
    let fixture: Value = serde_json::from_str(BUCKET_FIXTURE).expect("bucket fixture");
    let rows = fixture["buckets"].as_array().expect("buckets");
    assert!(rows.len() > 100, "{} rows", rows.len());
    for row in rows {
        let micros = row["micros"].as_u64().unwrap();
        let bucket = LogLinearHistogram::bucket_index(micros);
        assert_eq!(row["bucket"].as_u64(), Some(bucket as u64), "{row}");
        assert_eq!(
            row["upper_bound"].as_u64(),
            Some(LogLinearHistogram::bucket_upper_bound(bucket)),
            "{row}"
        );
    }
}

/// A row's percentiles use the bench's nearest rank (`ceil(n * q)`) over its
/// samples: each lands in the bucket of the exact sample of that rank.
#[test]
fn server_stats_ipc_methods_percentiles_use_the_nearest_rank() {
    let stats = RequestStats::default();
    let slot = RequestMethod::of_command(&Command::Ping).slot();
    // 1000 samples from 20 us to about 80 ms, with a long tail.
    let mut samples: Vec<u64> =
        (0..1000u64).map(|i| 20 + (i * i * i) / 12_500 + (i * 37) % 101).collect();
    for &us in &samples {
        let latency = Duration::from_micros(us);
        stats.methods().record(
            slot,
            MethodSample { latency, handler: latency / 2, lock_wait: Duration::ZERO },
        );
    }
    samples.sort_unstable();
    let exact = |fraction: f64| {
        let rank = ((samples.len() as f64) * fraction).ceil().max(1.0) as usize;
        samples[rank - 1]
    };
    let snapshot = stats.methods().snapshot(RequestMethod::of_slot);
    let [row] = snapshot.as_slice() else { panic!("one row: {snapshot:?}") };
    assert_eq!(row.method, "ping");
    assert_eq!(row.latency_us.count, 1000);
    assert_eq!(row.latency_us.max, *samples.last().unwrap());
    for (fraction, reported) in
        [(0.50, row.latency_us.p50), (0.95, row.latency_us.p95), (0.99, row.latency_us.p99)]
    {
        let truth = exact(fraction);
        assert_eq!(
            reported,
            LogLinearHistogram::bucket_upper_bound(LogLinearHistogram::bucket_index(truth)),
            "p{fraction}: reported {reported} us, exact {truth} us"
        );
    }
}

/// A handler's lock wait is the time its thread waited on the registry lock
/// (`LockStats`) while it ran; a wait before it started is not counted, and
/// the handler time covers it.
#[test]
fn server_stats_ipc_methods_counts_the_handlers_lock_wait() {
    let stats = Arc::new(RequestStats::default());
    let registry = LockStats::new();
    let site = std::panic::Location::caller();
    let arrived = Instant::now() - Duration::from_millis(3);
    registry.acquired(site, Duration::from_millis(50), None, Instant::now());
    {
        let mut span = RequestSpan::open(
            &stats,
            &Command::Ping,
            None,
            RequestArrival { arrived, parsed: arrived },
        );
        registry.acquired(site, Duration::from_millis(7), None, Instant::now());
        registry.released(site, Duration::ZERO);
        std::thread::sleep(Duration::from_millis(1));
        assert!(span.reply(|| true));
    }
    let snapshot = stats.methods().snapshot(RequestMethod::of_slot);
    let [row] = snapshot.as_slice() else { panic!("one row: {snapshot:?}") };
    assert_eq!(row.lock_wait_us.count, 1);
    assert_eq!(
        LogLinearHistogram::bucket_index(row.lock_wait_us.max),
        LogLinearHistogram::bucket_index(7_000),
        "{row:?}"
    );
    assert!(row.handler_us.max >= 1_000, "{row:?}");
    assert!(row.latency_us.max >= row.handler_us.max, "{row:?}");
    assert!(row.latency_us.max >= 3_000, "{row:?}");
}

/// A request a worker answers counts the dispatching thread's lock waits up
/// to the hand-off and the worker's from its start: 3 ms + 20 ms. The
/// worker's wait before it took the request is not counted.
#[test]
fn server_stats_ipc_methods_counts_the_workers_lock_wait() {
    let stats = Arc::new(RequestStats::default());
    let registry = LockStats::new();
    let site = std::panic::Location::caller();
    let worker = {
        let mut span = RequestSpan::open(&stats, &Command::Ping, None, RequestArrival::now());
        let reply = span.start_async();
        registry.acquired(site, Duration::from_millis(3), None, Instant::now());
        reply.hand_to_worker()
    };
    std::thread::spawn(move || {
        registry.acquired(site, Duration::from_millis(500), None, Instant::now());
        let reply = worker.start();
        registry.acquired(site, Duration::from_millis(20), None, Instant::now());
        assert!(reply.reply(|| true));
    })
    .join()
    .unwrap();
    let snapshot = stats.methods().snapshot(RequestMethod::of_slot);
    let [row] = snapshot.as_slice() else { panic!("one row: {snapshot:?}") };
    assert_eq!(row.lock_wait_us.count, 1);
    assert_eq!(
        LogLinearHistogram::bucket_index(row.lock_wait_us.max),
        LogLinearHistogram::bucket_index(23_000),
        "{row:?}"
    );
}

/// An async reply answered on the dispatching thread (a refusal before any
/// worker) counts that thread's waits after the hand-over too.
#[test]
fn server_stats_ipc_methods_counts_an_inline_async_replys_lock_wait() {
    let stats = Arc::new(RequestStats::default());
    let registry = LockStats::new();
    let site = std::panic::Location::caller();
    {
        let mut span = RequestSpan::open(&stats, &Command::Ping, None, RequestArrival::now());
        registry.acquired(site, Duration::from_millis(2), None, Instant::now());
        let reply = span.start_async();
        registry.acquired(site, Duration::from_millis(9), None, Instant::now());
        assert!(reply.reply(|| true));
    }
    let snapshot = stats.methods().snapshot(RequestMethod::of_slot);
    let [row] = snapshot.as_slice() else { panic!("one row: {snapshot:?}") };
    assert_eq!(
        LogLinearHistogram::bucket_index(row.lock_wait_us.max),
        LogLinearHistogram::bucket_index(11_000),
        "{row:?}"
    );
}

/// The section matches the SDK schema (spec/sdk-schema.json): the generated
/// Rust SDK decodes it and re-encodes every field.
#[test]
fn server_stats_ipc_methods_round_trips_through_the_sdk() {
    let mux = Mux::new_for_test("server-stats-ipc-sdk", crate::SurfaceOptions::default());
    run_lines(&mux, &[r#"{"id":1,"cmd":"ping"}"#]);
    let full = server_stats(&mux, json!(["ipc_methods"]));
    assert!(!full["ipc_methods"].as_array().unwrap().is_empty(), "{full}");
    let decoded: ::cmux::raw::ServerStatsResult =
        serde_json::from_str(&full.to_string()).expect("the SDK decodes server-stats");
    assert_eq!(serde_json::to_value(&decoded).unwrap(), full);
}
