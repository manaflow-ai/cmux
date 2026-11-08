//! Which registered daemon control socket a client `Connect` is allocated to.
//!
//! A Connect allocated to a daemon sends that daemon `Incoming`; the client
//! then waits on the circuit for the daemon to join. A daemon that is gone
//! never joins, and the client waits out its whole join timeout before it
//! tries again.

use cmux_remote_protocol::RelayRole;

use crate::abuse::websocket_counts_toward_capacity;
use crate::attachment::{SlotAttachment, SlotPhase};

/// Whether `attachment` is a daemon registration on `slot` that a Connect
/// may be allocated to at `now_ms`.
pub(crate) fn accepts_connects(
    attachment: &SlotAttachment,
    ready_state: u16,
    slot: &str,
    now_ms: u64,
) -> bool {
    websocket_counts_toward_capacity(ready_state, attachment.idle_deadline_ms, now_ms)
        && attachment.phase == SlotPhase::Registered
        && attachment.relay.role == RelayRole::Daemon
        && attachment.relay.slot == slot
        && attachment.expires_at > now_ms / 1_000
}

/// The first candidate a Connect on `slot` may be allocated to at `now_ms`.
/// Each candidate is a handle, its socket's ready state and its attachment.
pub(crate) fn live_daemon<T>(
    candidates: impl IntoIterator<Item = (T, u16, SlotAttachment)>,
    slot: &str,
    now_ms: u64,
) -> Option<T> {
    candidates.into_iter().find_map(|(handle, ready_state, attachment)| {
        accepts_connects(&attachment, ready_state, slot, now_ms).then_some(handle)
    })
}

/// Whether a new daemon `Register` on `slot` closes this existing control
/// socket: one slot has one daemon registration at a time.
pub(crate) fn replaced_by_register(attachment: &SlotAttachment, slot: &str) -> bool {
    attachment.phase == SlotPhase::Registered && attachment.relay.slot == slot
}

#[cfg(test)]
mod tests {
    use cmux_remote_protocol::{LaneToken, RelaySocketAttachment};

    use super::*;
    use crate::abuse::{CLIENT_CONTROL_IDLE_TIMEOUT_MS, DAEMON_CONTROL_IDLE_TIMEOUT_MS};
    use crate::park::{ConnectDisposition, ParkedConnect, connect_disposition, parked_and_live};

    const OPEN: u16 = 1;
    const CLOSED: u16 = 3;
    const SLOT: &str = "slot";
    /// The client's relay join timeout (`control_timeout`): what a Connect
    /// allocated to a daemon that never joins costs before the client retries.
    const CLIENT_JOIN_TIMEOUT_MS: u64 = 15_000;
    const T: u64 = 1_000_000_000;

    /// A daemon registration whose control socket last spoke at
    /// `last_seen_ms`, kept the way `RelaySlot` keeps it.
    fn daemon(last_seen_ms: u64) -> SlotAttachment {
        SlotAttachment {
            relay: RelaySocketAttachment::control(SLOT.into()),
            phase: SlotPhase::Registered,
            generation: 0,
            expires_at: last_seen_ms / 1_000 + 300,
            idle_deadline_ms: last_seen_ms + DAEMON_CONTROL_IDLE_TIMEOUT_MS,
            parked: None,
            last_seen_ms,
        }
    }

    fn parked_client(parked_at_ms: u64) -> SlotAttachment {
        SlotAttachment {
            relay: RelaySocketAttachment {
                role: RelayRole::Client,
                slot: SLOT.into(),
                circuit: None,
                lane: None,
            },
            phase: SlotPhase::ClientControl,
            generation: 1,
            expires_at: parked_at_ms / 1_000 + 300,
            idle_deadline_ms: parked_at_ms + CLIENT_CONTROL_IDLE_TIMEOUT_MS,
            parked: Some(ParkedConnect {
                lane: LaneToken("lane".into()),
                generation: 1,
                parked_at_ms,
            }),
            last_seen_ms: 0,
        }
    }

    /// The 11-08 staging sequence on a fresh Cloud machine:
    /// (1) create answers running;
    /// (2) the daemon registration from the machine's previous boot is still
    ///     on the slot: its socket reads OPEN and its 45 s idle deadline has
    ///     not passed, but nothing behind it will ever join a circuit;
    /// (3) the client's Connect arrives before the fresh daemon registers;
    /// (4) the fresh daemon sends Register.
    ///
    /// The Connect must park and be answered by that Register, so the client
    /// joins one hop after the fresh daemon is up, with no retry and without
    /// waiting out its join timeout on the previous boot's daemon.
    #[test]
    fn staging_sequence_parks_past_a_stale_registration_and_pairs_on_register() {
        // (1)
        let running_ms = T;
        // (2) The previous boot's daemon last pinged 20 s before create
        // answered (inside the 45 s idle window).
        let stale = daemon(running_ms - 20_000);
        assert!(stale.idle_deadline_ms > running_ms, "the stale socket still counts as open");

        // (3)
        let connect_ms = running_ms + 500;
        let target = live_daemon([("previous-boot", OPEN, stale.clone())], SLOT, connect_ms);
        assert_eq!(target, None, "the Connect was allocated to the previous boot's daemon");
        assert_eq!(connect_disposition(target.is_some(), 0, 0), ConnectDisposition::Park);
        let client = parked_client(connect_ms);

        // (4) The fresh Register closes the previous registration and
        // answers every parked Connect on the slot.
        let register_ms = running_ms + 1_500;
        assert!(replaced_by_register(&stale, SLOT));
        let fresh = daemon(register_ms);
        let candidates = [("previous-boot", CLOSED, stale), ("fresh", OPEN, fresh)];
        assert_eq!(live_daemon(candidates, SLOT, register_ms), Some("fresh"));
        assert!(parked_and_live(&client, OPEN, SLOT, register_ms));

        let connect_to_allocated_ms = register_ms - connect_ms;
        assert_eq!(connect_to_allocated_ms, 1_000);
        assert!(connect_to_allocated_ms < CLIENT_JOIN_TIMEOUT_MS);
    }
}
