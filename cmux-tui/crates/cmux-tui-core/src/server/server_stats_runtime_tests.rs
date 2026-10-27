//! `server-stats` `runtime`: the busy time of the daemon's watched tokio
//! workers (`runtime.busy_ms`, cmux-hang-watch `tokio`) and the hang count of
//! the process hang watch (p09-observability task 118).

use std::sync::{Arc, mpsc};
use std::time::Duration;

use cmux_hang_watch::tokio::WorkerHooks;
use serde_json::{Value, json};

use super::super::client_registry::ClientTransport;
use super::super::tests::captured_writer;
use super::super::{Command, Mux, handle_command};
use crate::hang_watch_test_support::Harness;

fn server_stats(mux: &Arc<Mux>, include: Value) -> Value {
    let (writer, _) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let command: Command =
        serde_json::from_value(json!({"cmd": "server-stats", "include": include})).unwrap();
    handle_command(mux, client, command, &writer).unwrap()
}

fn runtime_field(stats: &Value, field: &str) -> u64 {
    stats["runtime"][field].as_u64().unwrap_or_else(|| panic!("no runtime.{field}: {stats}"))
}

#[test]
fn server_stats_runtime_reports_the_busy_time_of_watched_tokio_workers() {
    let harness = Harness::get();
    // No other test moves the watch's clock while this runtime's worker is busy.
    let _serial = harness.serial();
    let mux = Mux::new_for_test("server-stats-runtime", crate::SurfaceOptions::default());
    assert!(server_stats(&mux, Value::Null).get("runtime").is_none(), "only on request");
    let before = server_stats(&mux, json!(["runtime"]));

    let hooks = WorkerHooks::new("stats-rt");
    let (parked_tx, parked) = mpsc::channel();
    let park = hooks.on_thread_park();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .on_thread_start(hooks.on_thread_start())
        .on_thread_unpark(hooks.on_thread_unpark())
        .on_thread_park(move || {
            park();
            let _ = parked_tx.send(());
        })
        .on_thread_stop(hooks.on_thread_stop())
        .build()
        .unwrap();
    // A worker's run before its first park is not a busy period.
    parked.recv_timeout(Duration::from_secs(10)).expect("the worker parked");
    // One busy period of 50 ms on the watch's clock.
    runtime.block_on(runtime.spawn(async { harness.advance(Duration::from_millis(50)) })).unwrap();
    // Dropping the runtime parks and stops its worker, so the period is counted.
    drop(runtime);

    let after = server_stats(&mux, json!(["runtime"]));
    let busy = runtime_field(&after, "busy_ms") - runtime_field(&before, "busy_ms");
    assert!(busy >= 50, "runtime.busy_ms grew by {busy}: {after}");
    assert!(runtime_field(&after, "busy_periods") > runtime_field(&before, "busy_periods"));
    assert!(hooks.busy().busy_ms >= 50, "{:?}", hooks.busy());
    assert!(after["runtime"]["hangs"].is_u64(), "{after}");
}
