//! Poisoned locks never panic the client (crash-elimination.md section 6).

use std::sync::mpsc::sync_channel;
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::json;

use super::tests::test_inner;
use super::*;

/// Poisons `lock` the way a real panic would: a thread panics while it
/// holds the guard.
fn poison<T: Send>(lock: &Mutex<T>) {
    thread::scope(|scope| {
        let holder = scope.spawn(|| {
            let _guard = lock.lock();
            panic!("poison the lock for the test");
        });
        assert!(holder.join().is_err());
    });
    assert!(lock.is_poisoned());
}

fn other_event(method: &str) -> CdpEvent {
    CdpEvent::Other { method: method.to_string(), params: json!({}), session_id: None }
}

#[test]
fn a_poisoned_event_queue_still_takes_events_with_a_rebuilt_byte_count() {
    let (inner, _outbound_rx) = test_inner();
    inner.events.push(other_event("A")).unwrap();
    poison(&inner.events.state);
    inner.events.push(other_event("B")).unwrap();
    let state = inner.events.state.lock().unwrap();
    assert_eq!(state.events.len(), 2);
    let sum: usize = state.events.iter().map(|queued| queued.retained_bytes).sum();
    assert_eq!(state.retained_bytes, sum);
}

#[test]
fn a_poisoned_frame_state_closes_the_connection_instead_of_panicking() {
    let (inner, _outbound_rx) = test_inner();
    let client = CdpClient { inner: inner.clone() };
    client.register_frame_epoch("session-1", Arc::new(FrameEpoch::default()));
    poison(&inner.frame_epochs);
    let error = client.snapshot_main_frame("session-1").unwrap_err();
    assert!(error.to_string().contains("poisoned"), "{error}");
    assert!(inner.closed.load(Ordering::Acquire));
    let (event_tx, event_rx) = sync_channel(4);
    inner.events.drain_into(&event_tx).unwrap();
    assert!(matches!(event_rx.try_recv(), Ok(CdpEvent::Closed(_))));
}

#[test]
fn a_poisoned_pending_map_still_settles_calls() {
    let (inner, _outbound_rx) = test_inner();
    poison(&inner.pending);
    handle_text(&inner, r#"{"id": 9, "result": {}}"#);
    close_inner(&inner, "test end");
    assert!(inner.closed.load(Ordering::Acquire));
}
