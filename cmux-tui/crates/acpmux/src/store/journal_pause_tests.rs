//! The store's log-write pause (`pause_next_log_write_on_this_thread`), a test seam: it stops
//! the next log write made on the thread that set it, and no other thread's (#36142). Under
//! `cargo test` the tests of one binary are threads of one process, so a pause that any
//! thread's log write could take let one test's append take another test's pause: one test then
//! failed with "the append never paused", or passed without testing what it should.

use super::*;
use cmux_journal::SimStorage;
use serde_json::json;
use std::sync::Arc;
use std::sync::mpsc;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(10);

fn open(home: &Path, seed: u64) -> Arc<dyn Store> {
    let config = StoreConfig { journal: true, ..StoreConfig::default() };
    let journal_config = cmux_journal::Config {
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(5),
        ..cmux_journal::Config::default()
    };
    let store = open_with_journal(&config, home, Arc::new(SimStorage::new(seed)), journal_config)
        .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    Arc::from(store)
}

fn record(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "mux".into(),
        kind: "note".into(),
        msg: json!({ "n": seq }),
        host_seq: None,
    }
}

/// Two tests' appends in one process, each to its own store: one thread sets the pause for its
/// own next log write and waits; meanwhile another thread, which set no pause, appends. That
/// append must return without a pause, and only then the first thread's own append pauses. Both
/// events go to one channel in the order they happen (a pause through a forwarder), so the test
/// needs no timer.
#[test]
fn a_log_write_pause_stops_only_the_thread_that_set_it() {
    let home_a = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let home_b = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let store_a = open(home_a.path(), 221);
    let store_b = open(home_b.path(), 222);
    let (events_tx, events) = mpsc::channel::<&'static str>();
    let (arrived_tx, arrived) = mpsc::channel::<()>();
    let (release, release_rx) = mpsc::channel::<()>();
    let forwarder = {
        let paused = events_tx.clone();
        std::thread::spawn(move || {
            for () in arrived {
                let _ = paused.send("a log write paused");
            }
        })
    };
    // The thread that sets the pause, then waits before its own append.
    let (set_tx, set) = mpsc::channel::<()>();
    let (go, go_rx) = mpsc::channel::<()>();
    let owner = {
        let store = Arc::clone(&store_a);
        std::thread::spawn(move || {
            pause_next_log_write_on_this_thread(arrived_tx, release_rx);
            let _ = set_tx.send(());
            go_rx.recv().map_err(|e| anyhow::anyhow!("no go: {e}"))?;
            store.append("chat-a", &record(1))
        })
    };
    set.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the pause was never set: {e}"));
    // Another thread's append, with no pause of its own.
    let other = {
        let store = Arc::clone(&store_b);
        let done = events_tx.clone();
        std::thread::spawn(move || {
            let appended = store.append("chat-b", &record(1));
            let _ = done.send("the other thread's append returned");
            appended
        })
    };
    let first = events.recv_timeout(WAIT).unwrap_or_else(|e| panic!("no append event: {e}"));
    if first != "the other thread's append returned" {
        // The other thread's append took the pause: let it go, so no thread stays held.
        let _ = release.send(());
    }
    assert_eq!(
        first, "the other thread's append returned",
        "another thread's log write took the pause this thread set for its own next log write"
    );
    other
        .join()
        .unwrap_or_else(|_| panic!("the other append panicked"))
        .unwrap_or_else(|e| panic!("the other append: {e:#}"));
    let _ = go.send(());
    let second = events.recv_timeout(WAIT).unwrap_or_else(|e| panic!("no pause event: {e}"));
    assert_eq!(second, "a log write paused", "the thread that set the pause did not pause");
    let _ = release.send(());
    owner
        .join()
        .unwrap_or_else(|_| panic!("the paused append panicked"))
        .unwrap_or_else(|e| panic!("the paused append: {e:#}"));
    forwarder.join().unwrap_or_else(|_| panic!("the forwarder panicked"));
}
