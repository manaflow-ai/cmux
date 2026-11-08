//! Which registered daemon control socket a client `Connect` is allocated to.
//!
//! A Connect allocated to a daemon sends that daemon `Incoming`; the client
//! then waits on the circuit for the daemon to join. A daemon that is gone
//! never joins, and the client waits out its whole join timeout (15 s)
//! before it tries again.
//!
//! A daemon that goes away without closing its socket (a machine that
//! reboots, or a session host restarted while its old socket is still open
//! at the edge) leaves a registration that reads OPEN until its 45 s idle
//! deadline. So a Connect is allocated only to a daemon heard from within
//! [`DAEMON_LIVENESS_WINDOW_MS`]; otherwise it parks, and the next Register
//! or Ping on the slot answers it.
//!
//! A daemon that died less than the window ago still gets the Connect. The
//! circuit it never joins is handed to the next daemon that registers
//! (`CircuitLedger::unjoined`), so the client is joined one hop after that
//! Register either way.

use cmux_remote_protocol::RelayRole;

use crate::abuse::{websocket_counts_toward_capacity, websocket_is_open};
use crate::attachment::{SlotAttachment, SlotPhase};

/// How recently a daemon's control socket must have spoken for a Connect to
/// be allocated to it. A daemon pings every `lease_seconds / 3` (10 s for the
/// relay's 30 s lease) and treats a ping unanswered for 3 s as dead, so a
/// live daemon is always heard from within 13 s; 2 s more covers the network.
pub(crate) const DAEMON_LIVENESS_WINDOW_MS: u64 = 15_000;

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
        && heard_within_window(attachment, now_ms)
}

/// Whether this daemon's control socket spoke within
/// [`DAEMON_LIVENESS_WINDOW_MS`] before `now_ms`.
pub(crate) fn heard_within_window(attachment: &SlotAttachment, now_ms: u64) -> bool {
    attachment.last_seen_ms.saturating_add(DAEMON_LIVENESS_WINDOW_MS) > now_ms
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

/// Whether `own`, a daemon registration whose socket is in `ready_state`,
/// is still its slot's current one: open, registered, and not replaced by a
/// newer Register on the slot (`others`: the slot's other control sockets).
/// A registration number of 0 is one written before numbers existed.
pub(crate) fn current_registration(
    own: &SlotAttachment,
    ready_state: u16,
    others: impl IntoIterator<Item = SlotAttachment>,
) -> bool {
    websocket_is_open(ready_state)
        && own.phase == SlotPhase::Registered
        && !others.into_iter().any(|other| {
            replaced_by_register(&other, &own.relay.slot) && other.generation > own.generation
        })
}

#[cfg(test)]
mod tests {
    use cmux_remote_protocol::{LaneToken, RelaySocketAttachment};

    use super::*;
    use crate::abuse::{
        CLIENT_CONTROL_IDLE_TIMEOUT_MS, CircuitLedger, DAEMON_CONTROL_IDLE_TIMEOUT_MS, PendingRoute,
    };
    use crate::park::{ConnectDisposition, ParkedConnect, connect_disposition, parked_and_live};

    const OPEN: u16 = 1;
    const CLOSING: u16 = 2;
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

    /// A daemon pinging on its normal 10 s heartbeat still gets a Connect at
    /// once, at any point between two pings.
    #[test]
    fn live_daemon_still_allocates_at_once() {
        let last_ping_ms = T;
        let heartbeat_ms = 10_000;
        let pong_timeout_ms = 3_000;
        for since_ping_ms in [0, 1, heartbeat_ms, heartbeat_ms + pong_timeout_ms] {
            let now_ms = last_ping_ms + since_ping_ms;
            let target = live_daemon([("live", OPEN, daemon(last_ping_ms))], SLOT, now_ms);
            assert_eq!(target, Some("live"), "{since_ping_ms} ms after a ping");
            assert_eq!(connect_disposition(true, 0, 0), ConnectDisposition::Allocate);
        }
    }

    #[test]
    fn registration_silent_past_the_window_takes_no_connects() {
        let stale = daemon(T);
        assert!(accepts_connects(&stale, OPEN, SLOT, T + DAEMON_LIVENESS_WINDOW_MS - 1));
        assert!(!accepts_connects(&stale, OPEN, SLOT, T + DAEMON_LIVENESS_WINDOW_MS));
        assert!(stale.idle_deadline_ms > T + DAEMON_LIVENESS_WINDOW_MS, "still OPEN at the edge");

        // An attachment written before last_seen_ms existed reads as never
        // heard from: its Connects park until its next Ping or Register.
        let mut legacy = serde_json::to_value(daemon(T)).unwrap();
        legacy.as_object_mut().unwrap().remove("last_seen_ms");
        let legacy: SlotAttachment = serde_json::from_value(legacy).unwrap();
        assert_eq!(legacy.last_seen_ms, 0);
        assert!(!accepts_connects(&legacy, OPEN, SLOT, T));
    }

    /// A second Register on the slot replaces the first: the old control
    /// socket is closed and every later Connect goes to the new daemon.
    #[test]
    fn re_registration_replaces_the_old_registration() {
        let old = daemon(T);
        let new_ms = T + 2_000;
        assert!(replaced_by_register(&old, SLOT));
        assert!(!replaced_by_register(&old, "other-slot"));
        let candidates = [("old", CLOSED, old), ("new", OPEN, daemon(new_ms))];
        assert_eq!(live_daemon(candidates, SLOT, new_ms + 1), Some("new"));
    }

    /// The daemon died 2 s before the Connect, inside the liveness window,
    /// so the Connect is allocated to it. The circuit stays pending (no
    /// daemon joins it), and the fresh Register is handed it, so the client
    /// is still joined one hop after that Register.
    #[test]
    fn circuit_allocated_to_a_daemon_that_just_died_goes_to_the_next_register() {
        let died_ms = T;
        let connect_ms = died_ms + 2_000;
        let dying = daemon(died_ms);
        assert_eq!(live_daemon([("dying", OPEN, dying)], SLOT, connect_ms), Some("dying"));

        let mut ledger = CircuitLedger::default();
        let route = PendingRoute { lane: LaneToken("lane".into()), generation: 1 };
        let join_deadline_ms = connect_ms + 30_000;
        assert!(ledger.reserve_for("c1".into(), join_deadline_ms, connect_ms, Some(route.clone())));

        let register_ms = connect_ms + 1_000;
        let handed_over = ledger.unjoined(register_ms);
        assert_eq!(handed_over.len(), 1);
        assert_eq!(handed_over[0].circuit, "c1");
        assert_eq!(handed_over[0].route, route);
        assert!(register_ms - connect_ms < CLIENT_JOIN_TIMEOUT_MS);
    }

    /// A daemon that was silent past the window and pings again resumed:
    /// circuits allocated to it while it was silent may never have reached
    /// it, so its Ping is handed the unjoined ones, as a Register is. A
    /// daemon pinging on its normal heartbeat is not.
    #[test]
    fn ping_after_silence_past_the_window_hands_over_unjoined_circuits() {
        let resumed = daemon(T);
        let ping_ms = T + DAEMON_LIVENESS_WINDOW_MS + 5_000;
        assert!(!heard_within_window(&resumed, ping_ms), "resumed: hand over");

        let heartbeat = daemon(T);
        assert!(heard_within_window(&heartbeat, T + 10_000), "heartbeat: no hand-over");
    }

    fn registration(number: u64, last_seen_ms: u64) -> SlotAttachment {
        SlotAttachment { generation: number, ..daemon(last_seen_ms) }
    }

    /// The old daemon's Ping was in flight when the new daemon's Register
    /// ran: the old socket is closing and a newer registration holds the
    /// slot, so its Ping must hand over and pair nothing.
    #[test]
    fn replaced_registration_is_not_current() {
        let old = registration(1, T);
        let new = registration(2, T + 1_000);
        assert!(!current_registration(&old, CLOSING, [new.clone()]));
        assert!(!current_registration(&old, OPEN, [new.clone()]), "a newer one exists");
        assert!(current_registration(&new, OPEN, [old.clone()]));
        assert!(current_registration(&new, OPEN, []));
        let other_slot = SlotAttachment {
            relay: RelaySocketAttachment::control("other-slot".into()),
            ..registration(9, T)
        };
        assert!(current_registration(&old, OPEN, [other_slot]));
        // Written before registration numbers: current until replaced.
        assert!(current_registration(&registration(0, T), OPEN, []));
    }
}
