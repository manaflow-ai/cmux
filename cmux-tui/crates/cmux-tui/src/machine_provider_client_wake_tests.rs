//! The provider event receiver blocks until an event, a disconnect or its one deadline: no period.

use super::*;
use cmux_tui_machine_protocol::{NoticeLevel, ProviderNotice};
use std::thread;
use std::time::Instant;

fn notice(message: &str) -> ReceivedProviderEvent {
    ReceivedProviderEvent {
        event: ProviderEvent::Notice(ProviderNotice {
            level: NoticeLevel::Info,
            message: message.into(),
        }),
        delivery: None,
    }
}

#[test]
fn event_receiver_times_out_once_at_its_deadline() {
    let events = ProviderEventReceiver { queue: Arc::new(ProviderEventQueue::new()) };
    let started = Instant::now();
    assert_eq!(events.recv_timeout(Duration::from_millis(30)), Err(RecvTimeoutError::Timeout));
    assert!(started.elapsed() >= Duration::from_millis(30), "timed out before its deadline");
}

#[test]
fn event_receiver_wakes_on_publish() {
    let queue = Arc::new(ProviderEventQueue::new());
    let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
    let publisher = Arc::clone(&queue);
    let publish = thread::spawn(move || {
        thread::sleep(Duration::from_millis(20));
        publisher.publish(notice("woken")).unwrap();
    });
    let started = Instant::now();
    let event = events.recv_timeout(Duration::from_secs(30)).expect("publish wakes the waiter");
    assert!(started.elapsed() < Duration::from_secs(5), "receiver waited past the publish");
    assert_eq!(event, notice("woken"));
    publish.join().unwrap();
}

#[test]
fn event_receiver_wakes_on_disconnect() {
    let queue = Arc::new(ProviderEventQueue::new());
    let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
    let disconnector = Arc::clone(&queue);
    let disconnect = thread::spawn(move || {
        thread::sleep(Duration::from_millis(20));
        disconnector.disconnect();
    });
    let started = Instant::now();
    assert_eq!(events.recv_timeout(Duration::from_secs(30)), Err(RecvTimeoutError::Disconnected));
    assert!(started.elapsed() < Duration::from_secs(5), "receiver waited past the disconnect");
    disconnect.join().unwrap();
}

#[test]
fn event_receiver_returns_a_queued_event_before_a_disconnect() {
    let queue = Arc::new(ProviderEventQueue::new());
    let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
    queue.publish(notice("first")).unwrap();
    queue.state.lock().unwrap().disconnected = true;
    assert_eq!(events.recv_timeout(Duration::ZERO), Ok(notice("first")));
    assert_eq!(events.recv_timeout(Duration::ZERO), Err(RecvTimeoutError::Disconnected));
}
