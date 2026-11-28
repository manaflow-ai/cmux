use cmux_remote_protocol::{LaneToken, RelaySocketAttachment};

use super::*;
use crate::abuse::{CircuitLedger, MAX_CIRCUITS_PER_SLOT};
use crate::attachment::InlineState;

const OPEN: u16 = 1;
const CLOSING: u16 = 2;
const SLOT: &str = "slot";
const T: u64 = 1_000_000_000;

fn standby(last_seen_ms: u64, expires_at: u64) -> SlotAttachment {
    SlotAttachment {
        relay: RelaySocketAttachment::control(SLOT.into()),
        phase: SlotPhase::Standby,
        generation: 0,
        expires_at,
        idle_deadline_ms: expires_at * 1_000,
        parked: None,
        last_seen_ms,
        pending_handover: false,
        inline: InlineState::default(),
    }
}

fn inline_side(role: RelayRole, circuit: &str, generation: u64) -> SlotAttachment {
    let mut attachment = standby(0, T / 1_000 + 600);
    attachment.phase = SlotPhase::Inline;
    attachment.generation = generation;
    attachment.relay = RelaySocketAttachment::circuit(
        role,
        SLOT.into(),
        CircuitId(circuit.into()),
        LaneToken("lane".into()),
    );
    attachment
}

#[test]
fn a_connect_takes_only_a_live_unexpired_open_standby() {
    let good = standby(T, T / 1_000 + 120);
    assert!(takeable_standby(&good, OPEN, SLOT, T));
    assert!(!takeable_standby(&good, CLOSING, SLOT, T), "a closing socket is gone");
    assert!(!takeable_standby(&good, OPEN, "other", T), "another slot's standby");
    assert!(!takeable_standby(&good, OPEN, SLOT, T + 120_000), "a standby past its ticket expiry");
    assert!(
        !takeable_standby(&good, OPEN, SLOT, T + 120_000 - STANDBY_MIN_REMAINING_MS),
        "a standby too close to its ticket expiry to outlive the dial"
    );
    let mut registration = good.clone();
    registration.phase = SlotPhase::Registered;
    assert!(!takeable_standby(&registration, OPEN, SLOT, T), "a registration is not a standby");
    let mut pending = good.clone();
    pending.phase = SlotPhase::Pending;
    assert!(!takeable_standby(&pending, OPEN, SLOT, T));
    let mut paired = good;
    paired.phase = SlotPhase::Inline;
    assert!(!takeable_standby(&paired, OPEN, SLOT, T), "a standby is taken once");
}

#[test]
fn live_standby_prefers_the_one_heard_last_and_skips_dead_ones() {
    let candidates = vec![
        ("old", OPEN, standby(T - 9_000, T / 1_000 + 120)),
        ("fresh", OPEN, standby(T - 1_000, T / 1_000 + 120)),
        ("closing", CLOSING, standby(T, T / 1_000 + 120)),
        ("expiring", OPEN, standby(T, T / 1_000 + 2)),
    ];
    assert_eq!(live_standby(candidates.clone(), SLOT, T), Some("fresh"));
    assert_eq!(live_standby(candidates.into_iter().take(0), SLOT, T), None);
    assert_eq!(
        live_standby([("none", OPEN, inline_side(RelayRole::Daemon, "c", 1))], SLOT, T),
        None
    );
}

#[test]
fn standby_capacity_is_bounded_per_slot() {
    let held: Vec<_> =
        (0..MAX_STANDBY_SOCKETS_PER_SLOT).map(|_| (OPEN, standby(T, T / 1_000 + 120))).collect();
    assert!(standby_has_room(standby_count(held[..held.len() - 1].iter().cloned(), SLOT, T)));
    assert!(!standby_has_room(standby_count(held.iter().cloned(), SLOT, T)));
    // A closing socket, or one past its deadline, frees its place.
    let mut with_dead = held.clone();
    with_dead[0].0 = CLOSING;
    assert!(standby_has_room(standby_count(with_dead, SLOT, T)));
    assert_eq!(standby_count(held, SLOT, T + 121_000), 0);
}

#[test]
fn a_standby_is_not_a_registration() {
    use crate::daemon::{
        accepts_connects, current_registration, live_daemon, next_registration_number,
        replaced_by_register,
    };
    let spare = standby(T, T / 1_000 + 120);
    assert!(!replaced_by_register(&spare, SLOT), "a Register must not close a standby");
    assert_eq!(next_registration_number([spare.clone()], SLOT), 1);
    assert!(!accepts_connects(&spare, OPEN, SLOT, T), "no classic Connect goes to a standby");
    assert_eq!(live_daemon([("standby", OPEN, spare.clone())], SLOT, T), None);
    assert!(!current_registration(&spare, OPEN, []));
    // A standby beside a registration changes nothing about which is current.
    let mut registered = spare.clone();
    registered.phase = SlotPhase::Registered;
    registered.generation = 3;
    assert!(current_registration(&registered, OPEN, [(OPEN, spare.clone())]));
    assert_eq!(next_registration_number([registered.clone(), spare.clone()], SLOT), 4);
    assert_eq!(
        live_daemon([("standby", OPEN, spare), ("registered", OPEN, registered)], SLOT, T),
        Some("registered")
    );
}

#[test]
fn inline_peer_is_the_other_side_of_the_same_circuit_only() {
    let client = inline_side(RelayRole::Client, "circuit-a", 7);
    let candidates = vec![
        ("same-role", OPEN, inline_side(RelayRole::Client, "circuit-a", 7)),
        ("other-circuit", OPEN, inline_side(RelayRole::Daemon, "circuit-b", 7)),
        ("other-generation", OPEN, inline_side(RelayRole::Daemon, "circuit-a", 8)),
        ("closing", CLOSING, inline_side(RelayRole::Daemon, "circuit-a", 7)),
        ("peer", OPEN, inline_side(RelayRole::Daemon, "circuit-a", 7)),
    ];
    assert_eq!(inline_peer(&client, candidates.clone()), Some("peer"));
    let mut not_inline = client;
    not_inline.phase = SlotPhase::ClientControl;
    assert_eq!(inline_peer(&not_inline, candidates), None);
}

#[test]
fn inline_circuits_share_the_ledgers_total_limit() {
    let mut ledger = CircuitLedger::default();
    let inline = InlineLoad { live: MAX_CIRCUITS_PER_SLOT - 2, allocations_in_window: 0 };
    assert!(ledger.admits_inline(100, inline));
    assert!(ledger.reserve_beside("a".into(), 1_000, 100, None, inline));
    assert!(ledger.admits_inline(100, inline));
    assert!(ledger.reserve_beside("b".into(), 1_000, 100, None, inline));
    assert!(!ledger.admits_inline(100, inline), "ledger entries and inline circuits add up");
    assert!(!ledger.reserve_beside("c".into(), 1_000, 100, None, inline));
    // The entries expire; the inline ones are still counted.
    assert!(!ledger.admits_inline(1_000, InlineLoad { live: MAX_CIRCUITS_PER_SLOT, ..inline }));
    assert!(ledger.admits_inline(1_000, inline));
}

#[test]
fn inline_and_classic_allocations_share_one_rate_limit() {
    use crate::abuse::MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW;
    let mut window = InlineWindow::default();
    let mut ledger = CircuitLedger::default();
    let classic = MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW / 2;
    for index in 0..classic {
        assert!(ledger.reserve_beside(
            format!("classic-{index}"),
            1_000_000,
            100,
            None,
            window.load(0, 100)
        ));
        assert!(ledger.release(&format!("classic-{index}")));
    }
    for _ in 0..MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW - classic {
        assert!(ledger.admits_inline(100, window.load(0, 100)));
        window.note(100);
    }
    assert!(!ledger.admits_inline(100, window.load(0, 100)), "the combined rate is bounded");
    assert!(!ledger.reserve_beside("next".into(), 1_000_000, 100, None, window.load(0, 100)));
    // A new window frees both.
    let later = 100 + CIRCUIT_ALLOCATION_WINDOW_MS;
    assert!(ledger.admits_inline(later, window.load(0, later)));
    window.note(later);
    assert_eq!(window.in_window(later), 1);
}

#[test]
fn live_inline_circuits_count_open_client_sides_once() {
    let sockets = [
        (OPEN, inline_side(RelayRole::Client, "a", 1)),
        (OPEN, inline_side(RelayRole::Daemon, "a", 1)),
        (CLOSING, inline_side(RelayRole::Client, "b", 1)),
        (OPEN, standby(T, T / 1_000 + 120)),
    ];
    assert_eq!(live_inline_circuits(sockets), 1);
}

#[test]
fn inline_deadline_is_the_latest_of_the_circuit_pair() {
    let mut client = inline_side(RelayRole::Client, "a", 1);
    let mut daemon = inline_side(RelayRole::Daemon, "a", 1);
    let mut other = inline_side(RelayRole::Daemon, "b", 1);
    client.idle_deadline_ms = 10;
    daemon.idle_deadline_ms = 30;
    other.idle_deadline_ms = 99;
    let circuit = CircuitId("a".into());
    assert_eq!(latest_inline_deadline(Some(&circuit), [&client, &daemon, &other]), 30);
}
