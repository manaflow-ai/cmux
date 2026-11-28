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
        inline: Default::default(),
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
        parked: Some(ParkedConnect { lane: LaneToken("lane".into()), generation: 1, parked_at_ms }),
        last_seen_ms: 0,
        pending_handover: false,
        inline: Default::default(),
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
    let route = PendingRoute { lane: LaneToken("lane".into()), generation: 1, region: None };
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

/// Two legacy registrations are open; the fallback gives a Connect to the
/// first, whose daemon is dead and never joins. When it closes, the
/// second becomes current, and its next heartbeat must hand it that
/// unjoined circuit, or the client waits out its join deadline.
#[test]
fn fallback_allocation_owes_the_other_legacy_registration_a_handover() {
    let dead = registration(0, T);
    let mut survivor = registration(0, T + 1_000);
    let connect_ms = T + 2_000;
    let candidates = [("dead", OPEN, dead.clone()), ("survivor", OPEN, survivor.clone())];
    assert_eq!(live_daemon(candidates, SLOT, connect_ms), Some("dead"));
    assert!(!current_registration(&dead, OPEN, [(OPEN, survivor.clone())]));
    assert!(owed_handover_after_fallback(&survivor, OPEN, SLOT));
    assert!(!owed_handover_after_fallback(&survivor, CLOSING, SLOT));
    survivor.pending_handover = true;

    // A heartbeat while the dead one is still open: not current.
    let current = current_registration(&survivor, OPEN, [(OPEN, dead.clone())]);
    let ping = record_ping(&mut survivor, current, connect_ms + 5_000);
    assert_eq!(ping, PingHandover { unjoined: false, parked: false });

    // The dead one closed: the next heartbeat is current and hands over.
    let current = current_registration(&survivor, OPEN, [(CLOSED, dead)]);
    let ping = record_ping(&mut survivor, current, connect_ms + 15_000);
    assert_eq!(ping, PingHandover { unjoined: true, parked: true });
}

/// The relay was upgraded while a legacy daemon that had just died (still
/// inside the liveness window) held an unjoined circuit, and another
/// legacy registration survives. No Connect fell back after the upgrade,
/// so nothing owed the survivor a hand-over: its Pings are heartbeats
/// while the dead one's socket is open. When that socket closes, the
/// survivor is owed one, and its first current heartbeat hands over the
/// inherited circuit.
#[test]
fn a_closed_legacy_registration_owes_the_survivor_its_inherited_circuits() {
    let dead = registration(0, T - 5_000);
    let mut survivor = registration(0, T - 2_000);
    assert!(!survivor.pending_handover);

    // A heartbeat while the dead one is still open: not current, and
    // not resumed, so nothing is owed yet.
    let current = current_registration(&survivor, OPEN, [(OPEN, dead.clone())]);
    let ping = record_ping(&mut survivor, current, T + 6_000);
    assert_eq!(ping, PingHandover { unjoined: false, parked: false });
    assert!(!survivor.pending_handover);

    // The dead one's socket closes: the survivor is owed a hand-over.
    assert!(owed_handover_after_close(&dead, &survivor, OPEN, SLOT));
    survivor.pending_handover = true;
    let current = current_registration(&survivor, OPEN, [(CLOSED, dead.clone())]);
    let ping = record_ping(&mut survivor, current, T + 16_000);
    assert_eq!(
        ping,
        PingHandover { unjoined: true, parked: true },
        "the circuit inherited from before the upgrade was never handed over"
    );

    // Only open legacy registrations are owed, and only for a legacy close.
    assert!(!owed_handover_after_close(&dead, &survivor, CLOSING, SLOT));
    assert!(!owed_handover_after_close(&dead, &registration(1, T), OPEN, SLOT));
    assert!(!owed_handover_after_close(&registration(1, T), &survivor, OPEN, SLOT));
    let pending = SlotAttachment { phase: SlotPhase::Pending, ..registration(0, T) };
    assert!(!owed_handover_after_close(&pending, &survivor, OPEN, SLOT));
}

/// A Connect chose the current registration, then waited on storage. A
/// Register that replaced it meanwhile (the old socket closing, a new
/// number on the slot) or a close means the Incoming must not be sent
/// to the chosen socket; the same socket and number means it may.
#[test]
fn allocation_rechecks_its_daemon_after_the_await() {
    let chosen = registration(1, T);
    let connect_ms = T + 1_000;
    assert_eq!(live_daemon([("old", OPEN, chosen.clone())], SLOT, connect_ms), Some("old"));
    assert!(still_allocated_to([("old", OPEN, chosen.clone())], SLOT, connect_ms, &"old", 1));

    let replaced = [("old", CLOSING, chosen.clone()), ("new", OPEN, registration(2, T + 1_500))];
    assert!(!still_allocated_to(replaced, SLOT, connect_ms + 1_000, &"old", 1));

    assert!(!still_allocated_to([("old", CLOSED, chosen)], SLOT, connect_ms, &"old", 1));

    // The same socket registered again: a different registration.
    let again = [("old", OPEN, registration(2, T + 1_500))];
    assert!(!still_allocated_to(again, SLOT, connect_ms + 1_000, &"old", 1));
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
