//! One-hop cold dial (RFD 0039 cut 5): the slot pairs a client's inline `Connect` with a daemon `Standby` socket
//! and forwards binary frames between the two itself, with no circuit hop.
//!
//! A daemon keeps up to [`MAX_STANDBY_SOCKETS_PER_SLOT`] spare sockets on `/v1/slots/{slot}/control`, each
//! authenticated with the Register ticket (`RelayControl::Standby`). A standby is not the slot's registration: it
//! never counts for `registered_daemon`, `current_registration`, registration numbers, hand-overs or
//! `pair_parked`, and it is never sent `Incoming`. A Connect with `inline: true` that finds the slot's daemon
//! registered and a live standby free takes it: both sockets go to [`SlotPhase::Inline`], the client gets `Ready`
//! and then the standby gets `Ready`. Any other Connect, and one that finds no live standby, is answered
//! `Allocated`/`Incoming` as before ("Fallbacks stay").
//!
//! The decisions here are pure so the interleaving and unit tests drive the same code `RelaySlot` runs.
//!
//! Quota. An inline circuit takes no ledger entry: that costs a storage write (and the output gate that holds
//! the answer until it commits) on the dial path. Instead it counts against the same limits the ledger enforces:
//! the live inline circuits (the slot's open `Inline` client sockets, read from memory) add to the ledger's
//! entries toward `MAX_CIRCUITS_PER_SLOT`, and a window of inline allocations ([`InlineWindow`], in memory) adds
//! to the ledger's allocation window toward `MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW`; classic allocations count the
//! inline ones the same way (`CircuitLedger::reserve_beside`). The live count is exact, since every inline
//! socket's attachment survives hibernation. The rate window is lost when the object is evicted: an evicted
//! object has no live inline circuit, and the limit still bounds a burst within one run, so the cost of the
//! loss is one more window of inline dials.

use cmux_remote_protocol::{CircuitId, RelayRole};

use crate::abuse::{
    CIRCUIT_ALLOCATION_WINDOW_MS, InlineLoad, websocket_counts_toward_capacity, websocket_is_open,
};
use crate::attachment::{SlotAttachment, SlotPhase};

/// Standby sockets one slot holds at once; a further one is refused with a retryable capacity error.
pub(crate) const MAX_STANDBY_SOCKETS_PER_SLOT: usize = 4;
/// A standby must outlive its pairing by this long: a ticket that expires mid-dial would drop the circuit.
pub(crate) const STANDBY_MIN_REMAINING_MS: u64 = 5_000;
pub(crate) const STANDBY_CAPACITY_CODE: &str = "standby-capacity";
pub(crate) const STANDBY_CAPACITY_MESSAGE: &str = "slot standby limit was reached";

/// Whether `attachment` is a standby on `slot` that a Connect may take at `now_ms`: open, unexpired, and its
/// ticket good for [`STANDBY_MIN_REMAINING_MS`] more.
pub(crate) fn takeable_standby(
    attachment: &SlotAttachment,
    ready_state: u16,
    slot: &str,
    now_ms: u64,
) -> bool {
    attachment.phase == SlotPhase::Standby
        && attachment.relay.role == RelayRole::Daemon
        && attachment.relay.slot == slot
        && websocket_counts_toward_capacity(ready_state, attachment.idle_deadline_ms, now_ms)
        && attachment.expires_at.saturating_mul(1_000)
            > now_ms.saturating_add(STANDBY_MIN_REMAINING_MS)
}

/// The standby a Connect on `slot` takes: of the takeable ones, the one its daemon spoke on last.
pub(crate) fn live_standby<T>(
    candidates: impl IntoIterator<Item = (T, u16, SlotAttachment)>,
    slot: &str,
    now_ms: u64,
) -> Option<T> {
    candidates
        .into_iter()
        .filter(|(_, ready_state, attachment)| {
            takeable_standby(attachment, *ready_state, slot, now_ms)
        })
        .max_by_key(|(_, _, attachment)| attachment.last_seen_ms)
        .map(|(handle, _, _)| handle)
}

/// Standbys `slot` holds at `now_ms` (`others`: its control sockets but the one asking).
pub(crate) fn standby_count(
    others: impl IntoIterator<Item = (u16, SlotAttachment)>,
    slot: &str,
    now_ms: u64,
) -> usize {
    others
        .into_iter()
        .filter(|(ready_state, attachment)| {
            attachment.phase == SlotPhase::Standby
                && attachment.relay.slot == slot
                && websocket_counts_toward_capacity(
                    *ready_state,
                    attachment.idle_deadline_ms,
                    now_ms,
                )
        })
        .count()
}

pub(crate) fn standby_has_room(others_holding: usize) -> bool {
    others_holding < MAX_STANDBY_SOCKETS_PER_SLOT
}

/// The other socket of `own`'s inline circuit: open, `Inline`, same slot, circuit and generation, opposite role.
pub(crate) fn inline_peer<T>(
    own: &SlotAttachment,
    candidates: impl IntoIterator<Item = (T, u16, SlotAttachment)>,
) -> Option<T> {
    let relay = &own.relay;
    candidates.into_iter().find_map(|(handle, ready_state, attachment)| {
        (own.phase == SlotPhase::Inline
            && attachment.phase == SlotPhase::Inline
            && websocket_is_open(ready_state)
            && attachment.relay.role != relay.role
            && attachment.relay.slot == relay.slot
            && attachment.relay.circuit == relay.circuit
            && attachment.relay.lane == relay.lane
            && attachment.generation == own.generation)
            .then_some(handle)
    })
}

/// Live inline circuits: open `Inline` client sockets, one per circuit.
pub(crate) fn live_inline_circuits(
    sockets: impl IntoIterator<Item = (u16, SlotAttachment)>,
) -> usize {
    sockets
        .into_iter()
        .filter(|(ready_state, attachment)| {
            attachment.phase == SlotPhase::Inline
                && attachment.relay.role == RelayRole::Client
                && websocket_is_open(*ready_state)
        })
        .count()
}

/// The deadline an inline circuit's alarm uses for each circuit: the latest of its sockets', as a ready circuit
/// shares one idle deadline (forwarding refreshes the destination only).
pub(crate) fn latest_inline_deadline<'a>(
    circuit: Option<&CircuitId>,
    sockets: impl IntoIterator<Item = &'a SlotAttachment>,
) -> u64 {
    sockets
        .into_iter()
        .filter(|attachment| {
            attachment.phase == SlotPhase::Inline && attachment.relay.circuit.as_ref() == circuit
        })
        .map(|attachment| attachment.idle_deadline_ms)
        .max()
        .unwrap_or(0)
}

/// Inline allocations in the current allocation window, kept in memory (see the module's note on quota).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct InlineWindow {
    started_ms: u64,
    count: usize,
}

impl InlineWindow {
    pub fn in_window(&self, now_ms: u64) -> usize {
        if self.count > 0 && now_ms < self.started_ms.saturating_add(CIRCUIT_ALLOCATION_WINDOW_MS) {
            self.count
        } else {
            0
        }
    }

    /// Counts one inline allocation.
    pub fn note(&mut self, now_ms: u64) {
        let current = self.in_window(now_ms);
        if current == 0 {
            self.started_ms = now_ms;
        }
        self.count = current + 1;
    }

    pub fn load(&self, live: usize, now_ms: u64) -> InlineLoad {
        InlineLoad { live, allocations_in_window: self.in_window(now_ms) }
    }
}

#[cfg(test)]
mod tests {
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
        assert!(
            !takeable_standby(&good, OPEN, SLOT, T + 120_000),
            "a standby past its ticket expiry"
        );
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
        let held: Vec<_> = (0..MAX_STANDBY_SOCKETS_PER_SLOT)
            .map(|_| (OPEN, standby(T, T / 1_000 + 120)))
            .collect();
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
}
