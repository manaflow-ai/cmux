use std::cell::{Cell, RefCell};

use super::*;
use crate::attachment::OutboundQueue;
use crate::forward::{
    CLOSE_OVERLOADED, MAX_OUTBOUND_QUEUE_BYTES, MAX_OUTBOUND_QUEUE_FRAMES, OutboundQueueError,
};

#[test]
fn active_release_record_survives_hibernation_and_retry() {
    let active = ActiveCircuit {
        slot: "slot".into(),
        circuit: CircuitId("ab".repeat(32)),
        releasing: true,
        renew_at_ms: 500,
        lease_expires_ms: 1_000,
    };
    let encoded = serde_json::to_vec(&active).unwrap();
    let decoded: ActiveCircuit = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(decoded.slot, active.slot);
    assert_eq!(decoded.circuit, active.circuit);
    assert!(decoded.releasing);
    assert_eq!(decoded.renew_at_ms, 500);
    assert_eq!(decoded.lease_expires_ms, 1_000);
}

#[test]
fn forwarded_activity_persists_one_peer_deadline_before_payload() {
    let mut peer = CircuitAttachment::pending(CircuitId("peer".into()), 2);
    let operations = RefCell::new(Vec::new());

    persist_peer_before_forward(
        10_000,
        &mut peer,
        |_| {
            operations.borrow_mut().push("peer");
            Ok::<_, &'static str>(())
        },
        || {
            operations.borrow_mut().push("forward");
            Ok(())
        },
    )
    .unwrap();

    let expected = 10_000 + CIRCUIT_IDLE_TIMEOUT_MS;
    assert_eq!(peer.idle_deadline_ms, expected);
    assert_eq!(&*operations.borrow(), &["peer", "forward"]);
}

#[test]
fn peer_attachment_failure_prevents_payload() {
    let mut peer = CircuitAttachment::pending(CircuitId("peer".into()), 2);
    let forwarded = Cell::new(false);

    let result = persist_peer_before_forward(
        10_000,
        &mut peer,
        |_| Err("peer serialization failed"),
        || {
            forwarded.set(true);
            Ok(())
        },
    );

    assert_eq!(result, Err("peer serialization failed"));
    assert!(!forwarded.get());
}

#[test]
fn outbound_queue_reconciles_runtime_drain_before_reserving() {
    let mut queue = OutboundQueue::default();
    reserve_outbound_frame(&mut queue, 20, 100).unwrap();
    assert_eq!(queue.untracked_bytes, 20);
    assert_eq!(queue.frame_bytes.iter().copied().collect::<Vec<_>>(), vec![100]);
    assert_eq!(queue.observed_bytes, 120);

    reserve_outbound_frame(&mut queue, 50, 10).unwrap();
    assert_eq!(queue.untracked_bytes, 0);
    assert_eq!(queue.frame_bytes.iter().copied().collect::<Vec<_>>(), vec![50, 10]);
    assert_eq!(queue.observed_bytes, 60);

    reserve_outbound_frame(&mut queue, 0, 1).unwrap();
    assert_eq!(queue.frame_bytes.iter().copied().collect::<Vec<_>>(), vec![1]);
    assert_eq!(queue.observed_bytes, 1);
}

#[test]
fn outbound_queue_rejects_slow_consumers_by_frame_and_byte_budget() {
    let mut frames = OutboundQueue::default();
    for _ in 0..MAX_OUTBOUND_QUEUE_FRAMES {
        let buffered = frames.observed_bytes;
        reserve_outbound_frame(&mut frames, buffered, 1).unwrap();
    }
    let buffered = frames.observed_bytes;
    assert_eq!(
        reserve_outbound_frame(&mut frames, buffered, 1),
        Err(OutboundQueueError::FrameLimit)
    );

    let mut bytes = OutboundQueue::default();
    reserve_outbound_frame(&mut bytes, 0, MAX_RELAY_BATCH_BYTES).unwrap();
    reserve_outbound_frame(&mut bytes, MAX_RELAY_BATCH_BYTES as u32, MAX_RELAY_BATCH_BYTES)
        .unwrap();
    assert_eq!(
        reserve_outbound_frame(&mut bytes, MAX_OUTBOUND_QUEUE_BYTES, MAX_RELAY_BATCH_BYTES,),
        Err(OutboundQueueError::ByteLimit)
    );
    assert_eq!(
        reserve_outbound_frame(&mut OutboundQueue::default(), 0, 0),
        Err(OutboundQueueError::EmptyFrame)
    );
}

#[test]
fn outbound_queue_close_reasons_match_the_failure() {
    assert_eq!(
        outbound_queue_close(OutboundQueueError::EmptyFrame),
        (CLOSE_UNSUPPORTED, "circuit frames must not be empty", "circuit peer sent an empty frame",)
    );
    for error in [OutboundQueueError::FrameLimit, OutboundQueueError::ByteLimit] {
        assert_eq!(
            outbound_queue_close(error),
            (
                CLOSE_OVERLOADED,
                "circuit peer is backpressured",
                "circuit outbound queue limit exceeded",
            )
        );
    }
}

#[test]
fn maximum_outbound_queue_fits_the_hibernation_attachment_limit() {
    let mut attachment = CircuitAttachment::pending(CircuitId("ab".repeat(32)), 1_000);
    attachment.outbound.observed_bytes = MAX_OUTBOUND_QUEUE_BYTES;
    attachment.outbound.frame_bytes =
        std::iter::repeat_n(MAX_RELAY_BATCH_BYTES as u32, MAX_OUTBOUND_QUEUE_FRAMES).collect();

    let encoded = serde_json::to_vec(&attachment).unwrap();
    assert!(encoded.len() <= 2_048, "attachment used {} bytes", encoded.len());
}

#[test]
fn ready_pair_uses_the_latest_shared_activity_deadline() {
    let ready = |state| (state, CircuitPhase::Ready, 200);
    assert!(has_live_ready_pair([ready(1), ready(1)], 100));
    assert!(!has_live_ready_pair([ready(1)], 100));
    assert!(!has_live_ready_pair([ready(1), ready(2)], 100));
    assert!(has_live_ready_pair(
        [(1, CircuitPhase::Ready, 200), (1, CircuitPhase::Ready, 100)],
        100,
    ));
    assert!(!has_live_ready_pair(
        [(1, CircuitPhase::Ready, 100), (1, CircuitPhase::Ready, 100)],
        100,
    ));
    assert!(!has_live_ready_pair(
        [(1, CircuitPhase::Ready, 200), (1, CircuitPhase::Joined, 200)],
        100,
    ));
}
