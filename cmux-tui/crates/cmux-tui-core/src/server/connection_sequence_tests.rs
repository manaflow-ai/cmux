//! Connections run on the daemon-wide sequenced pool (p05-ipc-073): their
//! thread count does not follow the number of connections.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::{
    BoundedOutbound, ClientTransport, Command, ConnectionSurfaceScheduler, MessageWriter,
    QueuedSink, Request,
};

/// The next message on `outbound`, waiting at most `bound`.
fn pop_within(outbound: &BoundedOutbound, bound: Duration) -> Option<Value> {
    let deadline = Instant::now() + bound;
    loop {
        if let Some(line) = outbound.try_pop() {
            return Some(serde_json::from_str(&line).expect("a JSON message"));
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_micros(200));
    }
}

/// 32 open connections, each with a request answered, hold no thread of
/// their own: no `mux-control-dispatch` per connection.
#[test]
fn open_connections_add_no_dispatcher_threads() {
    const CONNECTIONS: usize = 32;
    let mux = crate::Mux::new_for_test("connection-sequences", crate::SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let schedulers: Vec<_> = (0..CONNECTIONS)
        .map(|_| Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone())))
        .collect();
    for (id, scheduler) in schedulers.iter().enumerate() {
        let mut ping = Some(Request { id: Some(json!(id)), cmd: Command::Ping });
        assert_eq!(
            scheduler.dispatch(mux.clone(), client, &mut ping, 0, writer.clone()),
            Some(true)
        );
    }
    for _ in 0..CONNECTIONS {
        let reply = pop_within(&outbound, Duration::from_secs(5)).expect("every ping answers");
        assert_eq!(reply["ok"], true, "{reply}");
    }
    let dispatchers = cmux_threads::snapshot()
        .into_iter()
        .filter(|row| row.name == "mux-control-dispatch")
        .count();
    let pool = &mux.sequenced_pool;
    let (workers, fixed) = (
        pool.total_workers(),
        pool.config().workers(super::super::sequenced_pool::SequencePriority::Control),
    );
    for scheduler in &schedulers {
        scheduler.finish_and_wait();
    }
    assert!(
        dispatchers < CONNECTIONS,
        "{dispatchers} dispatcher threads for {CONNECTIONS} open connections"
    );
    assert!(
        workers <= fixed.min(CONNECTIONS),
        "{workers} pool workers for {CONNECTIONS} connections"
    );
}
