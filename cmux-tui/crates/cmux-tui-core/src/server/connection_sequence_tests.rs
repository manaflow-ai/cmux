//! Connections run on the daemon-wide sequenced pool: their
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

/// `when_settled` (a connection's close goes on from it and
/// never waits) runs each hook exactly once: a hook given while a request
/// still runs runs when it ends, not at the close before it; a later close
/// runs it no second time; a hook given to a settled scheduler runs at once.
#[test]
fn when_settled_runs_each_hook_once_and_at_once_when_settled() {
    use std::sync::atomic::{AtomicUsize, Ordering};

    let mux = crate::Mux::new_for_test("connection-settled", crate::SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let runs = Arc::new(AtomicUsize::new(0));
    let hook = || {
        let runs = runs.clone();
        Box::new(move || {
            runs.fetch_add(1, Ordering::SeqCst);
        })
    };
    let mut clear = Some(Request {
        id: Some(json!(1)),
        cmd: Command::ClearHistory(crate::server::terminal_io_wire::ClearHistoryParams {
            surface: surface.id,
            fallback_key: None,
        }),
    });
    // The clear waits for the terminal lock held here, so it still runs
    // when the scheduler closes.
    let held = surface.with_terminal(|_| {
        assert_eq!(scheduler.dispatch(mux.clone(), client, &mut clear, 0, writer), Some(true));
        let deadline = Instant::now() + Duration::from_secs(5);
        while mux.work.stats()[cmux_threads::work::Lane::System as usize].running == 0 {
            assert!(Instant::now() < deadline, "the clear-history item never started");
            std::thread::yield_now();
        }
        scheduler.when_settled(hook());
        scheduler.finish();
        assert_eq!(runs.load(Ordering::SeqCst), 0, "the clear still runs");
    });
    assert!(held.is_some(), "a PTY surface");
    let reply = pop_within(&outbound, Duration::from_secs(5)).expect("the clear answers");
    assert_eq!(reply["id"], 1, "{reply}");
    let deadline = Instant::now() + Duration::from_secs(5);
    while runs.load(Ordering::SeqCst) == 0 {
        assert!(Instant::now() < deadline, "the hook never ran");
        std::thread::yield_now();
    }
    assert_eq!(runs.load(Ordering::SeqCst), 1);
    scheduler.close();
    assert_eq!(runs.load(Ordering::SeqCst), 1, "a later close runs no hook again");
    scheduler.when_settled(hook());
    assert_eq!(runs.load(Ordering::SeqCst), 2, "a settled scheduler runs the hook at once");
    scheduler.close();
    assert_eq!(runs.load(Ordering::SeqCst), 2);
    mux.close_surface(surface.id).unwrap();
}

/// The person's requests run on the pool's input workers, automation's on
/// its control workers: an agent's burst of requests
/// never queues ahead of a key. A fresh mux has no worker of either.
#[test]
fn the_persons_requests_run_on_the_input_workers() {
    use super::super::sequenced_pool::SequencePriority;
    use super::connection_qos::{ConnectionClass, ConnectionClassCell};

    for (class, input_workers) in [(ConnectionClass::Automation, 0), (ConnectionClass::Person, 1)] {
        let mux =
            crate::Mux::new_for_test("connection-person-input", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let cell = Arc::new(ConnectionClassCell::default());
        cell.set(class);
        let scheduler = Arc::new(
            ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()).classed(cell),
        );
        let pool = &mux.sequenced_pool;
        assert_eq!(pool.worker_count(SequencePriority::Input), 0);
        let mut ping = Some(Request { id: Some(json!(1)), cmd: Command::Ping });
        assert_eq!(scheduler.dispatch(mux.clone(), client, &mut ping, 0, writer), Some(true));
        let reply = pop_within(&outbound, Duration::from_secs(5)).expect("the ping answers");
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(pool.worker_count(SequencePriority::Input), input_workers, "{class:?}");
        assert_eq!(pool.worker_count(SequencePriority::Control), 1 - input_workers, "{class:?}");
        scheduler.finish_and_wait();
    }
}
