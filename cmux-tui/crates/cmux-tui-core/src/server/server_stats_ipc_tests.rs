//! `server-stats` `ipc`: request latency, handler time and lock wait by
//! method (request_spans.rs records them, diagnostics/method_latency.rs
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

fn method<'a>(section: &'a Value, name: &str) -> &'a Value {
    section["methods"]
        .as_array()
        .and_then(|methods| methods.iter().find(|row| row["method"] == name))
        .unwrap_or_else(|| panic!("no {name} row: {section}"))
}

#[test]
fn server_stats_ipc_reports_each_method_that_ran() {
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
    let plain = server_stats(&mux, json!(["requests"]));
    assert!(plain.get("ipc").is_none(), "ipc is absent unless named: {plain}");

    let full = server_stats(&mux, json!(["ipc"]));
    let section = &full["ipc"];
    let ping = method(section, "ping");
    for histogram in ["latency_us", "handler_us", "lock_wait_us"] {
        assert_eq!(ping[histogram]["count"], json!(3), "{histogram}: {section}");
        for field in ["p50", "p95", "p99", "max"] {
            assert!(ping[histogram][field].is_u64(), "{histogram}.{field}: {ping}");
        }
    }
    assert_eq!(ping["class"], json!("query"), "{section}");
    assert_eq!(ping["id"], json!(Command::Ping.method_id()), "{section}");
    assert!(ping["latency_us"]["p50"].as_u64() <= ping["latency_us"]["p99"].as_u64(), "{ping}");
    assert!(ping["handler_us"]["max"].as_u64() <= ping["latency_us"]["max"].as_u64(), "{ping}");
    assert_eq!(method(section, "identify")["latency_us"]["count"], json!(1), "{section}");
    let ids: Vec<u64> = section["methods"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_u64().unwrap())
        .collect();
    assert!(ids.windows(2).all(|pair| pair[0] < pair[1]), "rows by method id: {ids:?}");
}

/// Every command, resource operation and route class has its own slot, below
/// the table's size, and the slot reads back to the same method.
#[test]
fn server_stats_ipc_slots_are_one_per_method() {
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
        assert_eq!(named.id, method.id, "{named:?}");
        assert_eq!(named.class, method.class.as_str(), "{named:?}");
    }
    assert_eq!(RequestMethod::of_slot(0).method, COMMANDS[0].wire);
    for operation in ResourceOperation::ALL {
        let slot = RequestMethod::of_resource(*operation).slot();
        assert_eq!(RequestMethod::of_slot(slot).method, operation.wire_name());
    }
    assert_eq!(RequestMethod::of_slot(REQUEST_METHOD_SLOTS - 1).method, "route:other");
}

/// The bench's exact percentiles (nearest rank over the raw samples) and the
/// histogram's land in the same bucket, for a skewed spread of latencies.
#[test]
fn server_stats_ipc_percentiles_agree_with_the_samples_within_one_bucket() {
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
    let [row] = snapshot.methods.as_slice() else { panic!("one row: {snapshot:?}") };
    assert_eq!(row.method, "ping");
    assert_eq!(row.latency_us.count, 1000);
    assert_eq!(row.latency_us.max, *samples.last().unwrap());
    for (fraction, reported) in
        [(0.50, row.latency_us.p50), (0.95, row.latency_us.p95), (0.99, row.latency_us.p99)]
    {
        let truth = exact(fraction);
        assert_eq!(
            LogLinearHistogram::bucket_index(reported),
            LogLinearHistogram::bucket_index(truth),
            "p{fraction}: reported {reported} us, exact {truth} us"
        );
        assert!(reported >= truth, "p{fraction}: {reported} < {truth}");
    }
}

/// A handler's lock wait is the time its thread waited on the registry lock
/// (`LockStats`) while it ran; a wait before it started is not counted, and
/// the handler time covers it.
#[test]
fn server_stats_ipc_counts_the_handlers_lock_wait() {
    let stats = Arc::new(RequestStats::default());
    let registry = LockStats::new();
    let site = std::panic::Location::caller();
    let arrived = Instant::now() - Duration::from_millis(3);
    registry.acquired(site, Duration::from_millis(50), None);
    {
        let mut span = RequestSpan::open(
            &stats,
            &Command::Ping,
            None,
            RequestArrival { arrived, parsed: arrived },
        );
        registry.acquired(site, Duration::from_millis(7), None);
        registry.released(site, Duration::ZERO);
        std::thread::sleep(Duration::from_millis(1));
        assert!(span.reply(|| true));
    }
    let snapshot = stats.methods().snapshot(RequestMethod::of_slot);
    let [row] = snapshot.methods.as_slice() else { panic!("one row: {snapshot:?}") };
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

/// The section matches the SDK schema (spec/sdk-schema.json): the generated
/// Rust SDK decodes it and re-encodes every field.
#[test]
fn server_stats_ipc_round_trips_through_the_sdk() {
    let mux = Mux::new_for_test("server-stats-ipc-sdk", crate::SurfaceOptions::default());
    run_lines(&mux, &[r#"{"id":1,"cmd":"ping"}"#]);
    let full = server_stats(&mux, json!(["ipc"]));
    assert!(!full["ipc"]["methods"].as_array().unwrap().is_empty(), "{full}");
    let decoded: ::cmux::raw::ServerStatsResult =
        serde_json::from_value(full.clone()).expect("the SDK decodes server-stats");
    assert_eq!(serde_json::to_value(&decoded).unwrap(), full);
}
