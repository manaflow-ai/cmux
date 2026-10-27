//! A producer waiting for room on a backpressured stream wakes on the event
//! that ends its wait (a pop, a cancel, a close by another thread), with no
//! re-check period (p14-energy-077g).

use super::*;
use crate::server::{MessageWriter, RenderService};
use serde_json::json;
use std::sync::mpsc::RecvTimeoutError;
use std::thread;

/// Far longer than any wake takes; a missing notification hangs until it.
const WAKE_BOUND: Duration = Duration::from_secs(5);

struct Blocked {
    outbound: Arc<BoundedOutbound>,
    stream: OutboundStream,
    done: std::sync::mpsc::Receiver<std::io::Result<()>>,
}

/// `stream` is full and a producer thread waits for room on it: a
/// backpressured push behind as many items as such a stream may queue, or an
/// ordered terminal behind the stream's whole item capacity.
fn blocked_producer(ordered_terminal: bool) -> Blocked {
    let service = RenderService::new();
    let outbound = Arc::new(BoundedOutbound::default());
    let overflow = service.serialize_control(&json!({"event": "overflow", "stream": 1})).unwrap();
    let stream = OutboundStream::new(1, overflow);
    let queued =
        if ordered_terminal { OUTBOUND_CAPACITY } else { OUTBOUND_BACKPRESSURED_STREAM_CAPACITY };
    for index in 0..queued {
        outbound
            .push_regular(service.serialize(&json!({"item": index})).unwrap(), &stream)
            .unwrap();
    }
    let text = service.serialize(&json!({"item": "next"})).unwrap();
    let (done_tx, done) = std::sync::mpsc::channel();
    let producer = outbound.clone();
    let producer_stream = stream.clone();
    thread::spawn(move || {
        let result = if ordered_terminal {
            producer.push_ordered_terminal(text, &producer_stream)
        } else {
            producer.push_regular_backpressured(text, &producer_stream)
        };
        let _ = done_tx.send(result);
    });
    // Give the producer time to reach its wait; the wake under test must
    // work either way.
    thread::sleep(Duration::from_millis(20));
    assert!(matches!(done.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));
    Blocked { outbound, stream, done }
}

fn finished(blocked: &Blocked) -> std::io::Result<()> {
    match blocked.done.recv_timeout(WAKE_BOUND) {
        Ok(result) => result,
        Err(RecvTimeoutError::Timeout) => panic!("the waiting producer never woke"),
        Err(RecvTimeoutError::Disconnected) => panic!("the producer thread died"),
    }
}

#[test]
fn backpressured_push_wakes_when_the_writer_makes_room() {
    let blocked = blocked_producer(false);
    assert!(blocked.outbound.recv().is_some());
    finished(&blocked).expect("room admits the item");
}

#[test]
fn backpressured_push_wakes_when_its_stream_is_canceled() {
    let blocked = blocked_producer(false);
    let service = RenderService::new();
    let end = service.serialize_control(&json!({"event": "stream-end"})).unwrap();
    blocked.outbound.push_terminal(end, &blocked.stream).unwrap();
    let error = finished(&blocked).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
}

#[test]
fn backpressured_push_wakes_when_another_send_on_its_stream_fails() {
    let blocked = blocked_producer(false);
    let writer =
        MessageWriter::new(QueuedSink { outbound: blocked.outbound.clone(), control: None });
    // A map with non-string keys does not serialize: the failed send closes
    // the stream outside the queue's lock.
    let unencodable = std::collections::BTreeMap::from([((1u8, 2u8), 3u8)]);
    assert!(writer.send_stream(&unencodable, &blocked.stream).is_err());
    assert!(!blocked.stream.is_open());
    let error = finished(&blocked).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
}

#[test]
fn backpressured_push_wakes_when_the_connection_closes() {
    let blocked = blocked_producer(false);
    blocked.outbound.close();
    let error = finished(&blocked).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
}

#[test]
fn ordered_terminal_wakes_when_another_send_on_its_stream_fails() {
    let blocked = blocked_producer(true);
    let writer =
        MessageWriter::new(QueuedSink { outbound: blocked.outbound.clone(), control: None });
    let unencodable = std::collections::BTreeMap::from([((1u8, 2u8), 3u8)]);
    assert!(writer.send_stream(&unencodable, &blocked.stream).is_err());
    let error = finished(&blocked).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
}
