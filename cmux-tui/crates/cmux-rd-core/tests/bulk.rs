//! Bulk transfers (rd change C5): file bytes on the reliable stream, with
//! credit-based flow control and at most one chunk per media frame
//! interval, paused while a media frame waits, so control latency stays
//! bounded.

use cmux_rd_core::bulk::{BulkReceiver, BulkSender, INITIAL_CREDIT};
use cmux_rd_proto::{BulkFrame, MAX_BULK_CHUNK};

const INTERVAL: u64 = 16_667;

#[test]
fn chunks_respect_credit_the_interval_and_waiting_media() {
    let mut tx = BulkSender::new(INTERVAL);
    // Larger than the initial credit, so the sender must stop and wait.
    tx.queue(1, vec![5; 20 * MAX_BULK_CHUNK]).expect("queue");
    assert!(tx.next_frame(0, true).is_none(), "a waiting media frame goes first");
    let a = tx.next_frame(0, false).expect("first chunk");
    assert_eq!((a.transfer, a.offset, a.bytes.len()), (1, 0, MAX_BULK_CHUNK));
    assert!(tx.next_frame(INTERVAL - 1, false).is_none(), "one chunk per interval");
    assert_eq!(tx.next_deadline_us(), Some(INTERVAL));
    let mut now = INTERVAL;
    let mut sent = a.bytes.len() as u64;
    while let Some(f) = tx.next_frame(now, false) {
        assert_eq!(f.offset, sent);
        sent += f.bytes.len() as u64;
        now += INTERVAL;
    }
    assert_eq!(sent, INITIAL_CREDIT, "never past the credit");
    assert_eq!(tx.next_deadline_us(), None, "blocked on credit: no wakeup");
    tx.on_credit(1, 20 * MAX_BULK_CHUNK as u64);
    while let Some(f) = tx.next_frame(now, false) {
        sent += f.bytes.len() as u64;
        now += INTERVAL;
    }
    assert_eq!(sent, 20 * MAX_BULK_CHUNK as u64);
    assert!(tx.is_idle(), "a finished transfer is dropped");
}

#[test]
fn the_receiver_takes_chunks_in_order_and_grants_credit() {
    let mut rx = BulkReceiver::new();
    let chunk = |offset: u64, len: usize| BulkFrame { transfer: 4, offset, bytes: vec![1; len] };
    let first = rx.accept(&chunk(0, MAX_BULK_CHUNK)).expect("in order");
    assert_eq!(first.bytes.len(), MAX_BULK_CHUNK);
    assert!(rx.accept(&chunk(5, 10)).is_err(), "a gap or overlap is refused");
    // After half the window arrives, the receiver grants more.
    let mut offset = MAX_BULK_CHUNK as u64;
    let mut credit = None;
    while credit.is_none() {
        let a = rx.accept(&chunk(offset, MAX_BULK_CHUNK)).expect("in order");
        offset += MAX_BULK_CHUNK as u64;
        credit = a.credit;
    }
    let c = credit.expect("credit");
    assert_eq!(c.transfer, 4);
    assert_eq!(c.offset, offset + INITIAL_CREDIT);
    rx.finish(4);
    assert!(rx.accept(&chunk(offset, 1)).is_err(), "a finished transfer takes nothing");
}
