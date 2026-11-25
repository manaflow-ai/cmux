use std::time::Duration;

use super::{MAX_OUTPUT_EVENT_BYTES, ProcessEventLog};

/// P1-F1 (review of #43048): the room check and the reservation are one
/// step. With a held subscriber and room for exactly one more output event,
/// a second reader (stdout beside stderr) must wait until the first has
/// published, or both publish and the second evicts unread output.
#[tokio::test]
async fn output_room_is_reserved_atomically_across_readers() {
    let log = ProcessEventLog::new(MAX_OUTPUT_EVENT_BYTES);
    let _held = log.subscribe_holding(0).expect("held subscription");
    let first = log.wait_for_room().await;
    let second = tokio::time::timeout(Duration::from_millis(100), log.wait_for_room()).await;
    assert!(second.is_err(), "two readers took the last room at once");
    drop(first);
    let after = tokio::time::timeout(Duration::from_secs(5), log.wait_for_room()).await;
    assert!(after.is_ok(), "the released room was not handed on");
}
