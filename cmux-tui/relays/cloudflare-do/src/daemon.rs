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

/// The candidate a Connect on `slot` may be allocated to at `now_ms`: the
/// slot's current registration (`current_registration`), if it accepts
/// Connects. Each candidate is a handle, its socket's ready state and its
/// attachment; the candidates are all the slot's control sockets.
pub(crate) fn live_daemon<T>(
    candidates: impl IntoIterator<Item = (T, u16, SlotAttachment)>,
    slot: &str,
    now_ms: u64,
) -> Option<T> {
    let candidates: Vec<_> = candidates.into_iter().collect();
    let sockets: Vec<_> = candidates
        .iter()
        .map(|(_, ready_state, attachment)| (*ready_state, attachment.clone()))
        .collect();
    candidates.into_iter().enumerate().find_map(|(index, (handle, ready_state, attachment))| {
        let others = sockets
            .iter()
            .enumerate()
            .filter(|(other, _)| *other != index)
            .map(|(_, (ready_state, other))| (*ready_state, other.clone()));
        (accepts_connects(&attachment, ready_state, slot, now_ms)
            && current_registration(&attachment, ready_state, others))
        .then_some(handle)
    })
}

/// Whether a new daemon `Register` on `slot` closes this existing control
/// socket: one slot has one daemon registration at a time.
pub(crate) fn replaced_by_register(attachment: &SlotAttachment, slot: &str) -> bool {
    attachment.phase == SlotPhase::Registered && attachment.relay.slot == slot
}

/// The registration number a daemon `Register` on `slot` gets: one more than
/// the highest on the slot's control sockets (`existing`, including the one
/// registering). Every registration it replaces is closed.
pub(crate) fn next_registration_number(
    existing: impl IntoIterator<Item = SlotAttachment>,
    slot: &str,
) -> u64 {
    existing
        .into_iter()
        .filter(|attachment| replaced_by_register(attachment, slot))
        .map(|attachment| attachment.generation)
        .max()
        .unwrap_or(0)
        .saturating_add(1)
}

/// Whether `own`, a daemon registration whose socket is in `ready_state`,
/// is still its slot's current one: open, registered, and not replaced by a
/// newer Register on the slot (`others`: the slot's other control sockets,
/// each with its ready state). A socket that is closing or closed is gone:
/// it never makes another registration non-current.
///
/// A registration number of 0 is one written before numbers existed. Two of
/// those carry no order, so a legacy registration is current only while it
/// is the slot's only registration: with another one on the slot, its Ping
/// takes over nothing until that socket closes or a numbered Register
/// replaces both.
pub(crate) fn current_registration(
    own: &SlotAttachment,
    ready_state: u16,
    others: impl IntoIterator<Item = (u16, SlotAttachment)>,
) -> bool {
    websocket_is_open(ready_state)
        && own.phase == SlotPhase::Registered
        && !others.into_iter().any(|(ready_state, other)| {
            websocket_is_open(ready_state)
                && replaced_by_register(&other, &own.relay.slot)
                && (other.generation > own.generation || own.generation == 0)
        })
}

/// What a registered daemon's Ping hands it: the slot's unjoined circuits
/// (`CircuitLedger::unjoined`) and its parked Connects.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PingHandover {
    pub unjoined: bool,
    pub parked: bool,
}

/// Records on `attachment` a Ping its daemon sent at `now_ms`, and says what
/// the Ping hands over. `current` is `current_registration` for the socket.
/// A daemon silent past the window resumed: circuits sent to it meanwhile
/// may never have arrived, so it is handed the unjoined ones. A Ping from a
/// registration that isn't current hands over nothing, and a resumed one
/// leaves `pending_handover` set, so the first Ping after it becomes current
/// is handed them instead.
pub(crate) fn record_ping(
    attachment: &mut SlotAttachment,
    current: bool,
    now_ms: u64,
) -> PingHandover {
    let resumed = !heard_within_window(attachment, now_ms) || attachment.pending_handover;
    attachment.last_seen_ms = now_ms;
    attachment.pending_handover = resumed && !current;
    if !current {
        return PingHandover { unjoined: false, parked: false };
    }
    PingHandover { unjoined: resumed, parked: true }
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
            pending_handover: false,
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
            pending_handover: false,
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
        assert!(!current_registration(&old, CLOSING, [(OPEN, new.clone())]));
        assert!(!current_registration(&old, OPEN, [(OPEN, new.clone())]), "a newer one exists");
        assert!(current_registration(&new, OPEN, [(OPEN, old.clone())]));
        assert!(current_registration(&new, OPEN, []));
        let other_slot = SlotAttachment {
            relay: RelaySocketAttachment::control("other-slot".into()),
            ..registration(9, T)
        };
        assert!(current_registration(&old, OPEN, [(OPEN, other_slot)]));
        // Written before registration numbers: current until replaced.
        assert!(current_registration(&registration(0, T), OPEN, []));
    }

    /// Two daemons registered by the relay before registration numbers both
    /// keep number 0, so the number cannot say which one is newer. After the
    /// upgrade, a late Ping from the older socket must not make it current
    /// (it would take over the slot's parked Connects and unjoined circuits).
    #[test]
    fn late_ping_from_the_older_of_two_legacy_registrations_is_not_current() {
        let older = registration(0, T);
        let newer = registration(0, T + 1_000);
        let late_ping_ms = T + 2_000;
        let older_after_ping = SlotAttachment { last_seen_ms: late_ping_ms, ..older };
        assert!(
            !current_registration(&older_after_ping, OPEN, [(OPEN, newer.clone())]),
            "the older legacy registration's late Ping made it current"
        );
        // A numbered Register replaces every legacy registration.
        assert!(current_registration(
            &registration(1, T + 3_000),
            OPEN,
            [(OPEN, older_after_ping), (OPEN, newer)]
        ));
    }

    /// Two legacy registrations are open on the slot, so neither is current
    /// (`current_registration`), and both daemons are pinging. A Connect is
    /// still allocated, to the first live one, instead of parking until a
    /// numbered Register or a socket close and timing out.
    #[test]
    fn two_live_legacy_registrations_still_serve_a_connect() {
        let first = registration(0, T);
        let second = registration(0, T + 1_000);
        let connect_ms = T + 2_000;
        assert!(!current_registration(&first, OPEN, [(OPEN, second.clone())]));
        assert!(!current_registration(&second, OPEN, [(OPEN, first.clone())]));
        let candidates = [("first", OPEN, first.clone()), ("second", OPEN, second.clone())];
        assert_eq!(
            live_daemon(candidates, SLOT, connect_ms),
            Some("first"),
            "two live legacy registrations left the Connect parked"
        );

        // The first one went quiet past the window: the second one serves.
        let later_ms = T + DAEMON_LIVENESS_WINDOW_MS + 500;
        let second_pinged = SlotAttachment { last_seen_ms: later_ms - 1_000, ..second };
        let candidates = [("first", OPEN, first.clone()), ("second", OPEN, second_pinged)];
        assert_eq!(live_daemon(candidates, SLOT, later_ms), Some("second"));

        // Neither is live: the Connect parks.
        let candidates = [("first", OPEN, first), ("second", OPEN, registration(0, T))];
        assert_eq!(live_daemon(candidates, SLOT, later_ms), None);
    }

    /// A numbered registration is current, so a Connect goes only to it:
    /// while it is silent past the window the Connect parks, even if a
    /// closing socket's daemon is still pinging.
    #[test]
    fn a_current_registration_takes_every_connect() {
        let replaced = registration(0, T + 10_000);
        let current = registration(1, T);
        let connect_ms = T + DAEMON_LIVENESS_WINDOW_MS + 500;
        let candidates = [("replaced", CLOSING, replaced), ("current", OPEN, current)];
        assert_eq!(live_daemon(candidates, SLOT, connect_ms), None);
    }

    /// A legacy registration that resumed while another one was on the slot
    /// is not current, so its Ping hands over nothing. When the other one
    /// closes before its next heartbeat, that heartbeat makes it current and
    /// must still hand it the circuits it missed while silent: otherwise those
    /// clients never get a replacement Incoming and time out.
    #[test]
    fn suppressed_resumed_ping_hands_over_on_the_first_current_ping() {
        let mut survivor = registration(0, T);
        let resumed_ms = T + DAEMON_LIVENESS_WINDOW_MS + 5_000;
        let other = registration(0, T + 1_000);
        let current = current_registration(&survivor, OPEN, [(OPEN, other)]);
        assert!(!current, "another legacy registration is on the slot");
        let suppressed = record_ping(&mut survivor, current, resumed_ms);
        assert_eq!(suppressed, PingHandover { unjoined: false, parked: false });

        // The other registration closed; the next heartbeat is current.
        let heartbeat_ms = resumed_ms + 10_000;
        let current = current_registration(&survivor, OPEN, []);
        assert!(current);
        let first = record_ping(&mut survivor, current, heartbeat_ms);
        assert_eq!(
            first,
            PingHandover { unjoined: true, parked: true },
            "the circuits missed while silent were never handed over"
        );

        // Handed over once: the heartbeat after that is a plain heartbeat.
        let next = record_ping(&mut survivor, true, heartbeat_ms + 10_000);
        assert_eq!(next, PingHandover { unjoined: false, parked: true });
    }
}
