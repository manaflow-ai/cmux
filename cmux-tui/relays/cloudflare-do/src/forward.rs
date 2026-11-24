//! The outbound-queue ledger and forwarding steps both relays share: a `RelayCircuit` forwards between its two
//! joined sockets, a `RelaySlot` between an inline client and its daemon standby (`crate::inline`).

use crate::abuse::CIRCUIT_IDLE_TIMEOUT_MS;
use crate::attachment::OutboundQueue;

/// A socket attachment a frame is forwarded to: it keeps the socket's idle deadline.
pub(crate) trait ForwardTarget {
    fn set_idle_deadline_ms(&mut self, deadline_ms: u64);
}

impl ForwardTarget for crate::attachment::CircuitAttachment {
    fn set_idle_deadline_ms(&mut self, deadline_ms: u64) {
        self.idle_deadline_ms = deadline_ms;
    }
}

pub(crate) const MAX_OUTBOUND_QUEUE_FRAMES: usize = 128;
pub(crate) const MAX_OUTBOUND_QUEUE_BYTES: u32 = 2 * 1024 * 1024;
pub(crate) const CLOSE_UNSUPPORTED: u16 = 1003;
pub(crate) const CLOSE_OVERLOADED: u16 = 1013;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum OutboundQueueError {
    EmptyFrame,
    FrameLimit,
    ByteLimit,
}

pub(crate) fn outbound_queue_close(error: OutboundQueueError) -> (u16, &'static str, &'static str) {
    match error {
        OutboundQueueError::EmptyFrame => (
            CLOSE_UNSUPPORTED,
            "circuit frames must not be empty",
            "circuit peer sent an empty frame",
        ),
        OutboundQueueError::FrameLimit | OutboundQueueError::ByteLimit => (
            CLOSE_OVERLOADED,
            "circuit peer is backpressured",
            "circuit outbound queue limit exceeded",
        ),
    }
}

pub(crate) fn reserve_outbound_frame(
    queue: &mut OutboundQueue,
    buffered_bytes: u32,
    frame_bytes: usize,
) -> std::result::Result<(), OutboundQueueError> {
    // Worker WebSocket sends are synchronous but not backpressured. Keep the
    // runtime's byte count and our per-frame ledger in the socket attachment
    // so the limits survive Durable Object hibernation.
    if frame_bytes == 0 {
        return Err(OutboundQueueError::EmptyFrame);
    }

    if buffered_bytes == 0 {
        queue.untracked_bytes = 0;
        queue.frame_bytes.clear();
    } else if buffered_bytes < queue.observed_bytes {
        let mut drained = queue.observed_bytes - buffered_bytes;
        let untracked_drained = drained.min(queue.untracked_bytes);
        queue.untracked_bytes -= untracked_drained;
        drained -= untracked_drained;
        while drained > 0 {
            let Some(front) = queue.frame_bytes.front_mut() else {
                break;
            };
            let frame_drained = drained.min(*front);
            *front -= frame_drained;
            drained -= frame_drained;
            if *front == 0 {
                queue.frame_bytes.pop_front();
            }
        }
    } else if buffered_bytes > queue.observed_bytes {
        queue.untracked_bytes =
            queue.untracked_bytes.saturating_add(buffered_bytes - queue.observed_bytes);
    }
    queue.observed_bytes = buffered_bytes;

    if queue.frame_bytes.len() >= MAX_OUTBOUND_QUEUE_FRAMES {
        return Err(OutboundQueueError::FrameLimit);
    }
    let frame_bytes = u32::try_from(frame_bytes).map_err(|_| OutboundQueueError::ByteLimit)?;
    let projected = buffered_bytes
        .checked_add(frame_bytes)
        .filter(|bytes| *bytes <= MAX_OUTBOUND_QUEUE_BYTES)
        .ok_or(OutboundQueueError::ByteLimit)?;
    queue.frame_bytes.push_back(frame_bytes);
    queue.observed_bytes = projected;
    Ok(())
}

pub(crate) fn persist_peer_before_forward<P: ForwardTarget, E>(
    now_ms: u64,
    peer: &mut P,
    persist_peer: impl FnOnce(&P) -> std::result::Result<(), E>,
    forward: impl FnOnce() -> std::result::Result<(), E>,
) -> std::result::Result<(), E> {
    // The latest deadline across the ready pair is the shared circuit idle
    // deadline. Persisting only the destination attachment also durably saves
    // its outbound FIFO ledger, while avoiding a second attachment write on
    // every interactive frame.
    peer.set_idle_deadline_ms(now_ms.saturating_add(CIRCUIT_IDLE_TIMEOUT_MS));
    persist_peer(peer)?;
    forward()
}
