//! A client `Connect` that reaches the slot before its daemon has registered
//! waits on the client's allocation socket instead of being refused. The
//! daemon's accepted `Register` is the readiness event: the slot then sends
//! `Allocated` and `Incoming` for every waiting request, so the client is
//! paired one WebSocket hop after the daemon comes up, with no retry.
//!
//! The waiting request lives in the socket attachment, so it survives
//! hibernation. It ends at the socket's idle deadline, which is already bounded
//! by the Connect ticket's expiry; the alarm then answers it with the same
//! retryable `daemon-offline` error an offline slot gave before, so a client
//! that expects an immediate answer behaves as it did.

use cmux_remote_protocol::{LaneToken, RelayControl, RelayRole};
use serde::{Deserialize, Serialize};

use crate::abuse::{MAX_PENDING_CIRCUITS_PER_SLOT, websocket_counts_toward_capacity};
use crate::attachment::{SlotAttachment, SlotPhase};

pub(crate) const DAEMON_OFFLINE_CODE: &str = "daemon-offline";
pub(crate) const DAEMON_OFFLINE_MESSAGE: &str = "daemon is not connected";

/// One verified Connect waiting for the slot's daemon. The ticket was checked
/// when it arrived; its expiry is the attachment's `expires_at`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ParkedConnect {
    pub lane: LaneToken,
    pub generation: u64,
    pub parked_at_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ConnectDisposition {
    /// A daemon is registered: allocate the circuit now.
    Allocate,
    /// No daemon yet: hold the request until one registers.
    Park,
    /// No daemon and the slot already holds as many waiting or pending
    /// allocations as it may: answer `daemon-offline` now.
    Offline,
}

/// Decides what a verified Connect gets. A waiting request counts against the
/// same 16 pending allocations as a pending circuit, since each one becomes a
/// pending circuit when the daemon registers.
pub(crate) fn connect_disposition(
    daemon_registered: bool,
    parked_on_other_sockets: usize,
    pending_circuits: usize,
) -> ConnectDisposition {
    if daemon_registered {
        ConnectDisposition::Allocate
    } else if parked_on_other_sockets.saturating_add(pending_circuits)
        < MAX_PENDING_CIRCUITS_PER_SLOT
    {
        ConnectDisposition::Park
    } else {
        ConnectDisposition::Offline
    }
}

/// The `Parked` notice a client gets when its Connect waits. Only a client
/// that set `accepts_parked` gets one: an older client fails on a control
/// type it does not know, and keeps waiting for `Allocated` without it.
pub(crate) fn parked_notice(
    accepts_parked: bool,
    lane: &LaneToken,
    generation: u64,
) -> Option<RelayControl> {
    accepts_parked.then(|| RelayControl::Parked { lane: lane.clone(), generation })
}

/// Whether this socket holds a Connect that a newly registered daemon on
/// `slot` should answer now.
pub(crate) fn parked_and_live(
    attachment: &SlotAttachment,
    ready_state: u16,
    slot: &str,
    now_ms: u64,
) -> bool {
    attachment.parked.is_some()
        && attachment.phase == SlotPhase::ClientControl
        && attachment.relay.role == RelayRole::Client
        && attachment.relay.slot == slot
        && attachment.expires_at > now_ms / 1_000
        && websocket_counts_toward_capacity(ready_state, attachment.idle_deadline_ms, now_ms)
}

/// Orders the waiting requests a registration answers: oldest first.
pub(crate) fn pairing_order<T>(mut waiting: Vec<(T, ParkedConnect)>) -> Vec<(T, ParkedConnect)> {
    waiting.sort_by_key(|(_, parked)| parked.parked_at_ms);
    waiting
}

/// Whether the alarm, closing this expired socket, must first answer a
/// waiting Connect with `daemon-offline`.
pub(crate) fn expired_while_parked(attachment: &SlotAttachment, now_ms: u64) -> bool {
    attachment.parked.is_some() && attachment.idle_deadline_ms <= now_ms
}

#[cfg(test)]
#[path = "park_tests.rs"]
mod tests;
