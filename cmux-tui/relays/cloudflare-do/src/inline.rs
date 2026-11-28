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

/// Live inline circuits: open `Inline` client sockets, one per circuit, whose circuit is still inside its idle
/// deadline (the later of its two sockets', `latest_inline_deadline`). A circuit past that deadline is closed by
/// the next alarm; until then it does not hold capacity, the same rule `websocket_counts_toward_capacity` applies
/// to every other socket the slot counts.
pub(crate) fn live_inline_circuits(
    sockets: impl IntoIterator<Item = (u16, SlotAttachment)>,
    now_ms: u64,
) -> usize {
    let open: Vec<SlotAttachment> = sockets
        .into_iter()
        .filter(|(ready_state, attachment)| {
            attachment.phase == SlotPhase::Inline && websocket_is_open(*ready_state)
        })
        .map(|(_, attachment)| attachment)
        .collect();
    open.iter()
        .filter(|attachment| {
            attachment.relay.role == RelayRole::Client
                && latest_inline_deadline(attachment.relay.circuit.as_ref(), open.iter()) > now_ms
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
#[path = "inline_tests.rs"]
mod tests;
