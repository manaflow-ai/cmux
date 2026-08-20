//! Slot-scoped process-local machine keys.
//!
//! One client aggregates machines from several providers. A key must therefore
//! identify the owning provider as well as the machine, so an action can never
//! reach a provider that does not own its row.
//!
//! A key splits into a provider slot in the high [`SLOT_BITS`] bits and a
//! per-provider ordinal in the low [`ORDINAL_BITS`] bits. Slot [`LOCAL_SLOT`]
//! belongs to the built-in current-session entry, so the local machine keeps
//! the first position in the column. Registry order assigns the later slots.
//!
//! Keys route UI actions only. They are process-local and must never be
//! persisted or sent to a provider. Reconciliation across snapshots uses the
//! slot together with the provider-stable id, because two providers may return
//! the same opaque id.

// The aggregator that consumes these keys lands in the next slice. The
// namespace ships first so the key layout is fixed and tested before any
// caller depends on it.
#![allow(dead_code)]

use std::collections::HashMap;

use crate::machine::MachineKey;

/// Width of the provider slot field.
pub const SLOT_BITS: u32 = 16;
/// Width of the per-provider ordinal field.
pub const ORDINAL_BITS: u32 = 64 - SLOT_BITS;
/// Largest ordinal one provider can address.
pub const MAX_ORDINAL: u64 = (1u64 << ORDINAL_BITS) - 1;
/// Slot of the built-in current-session entry.
pub const LOCAL_SLOT: ProviderSlot = ProviderSlot(0);

/// Position of one provider in the resolved registry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ProviderSlot(u16);

impl ProviderSlot {
    /// Builds the slot for a registry position. Returns `None` when the
    /// registry holds more entries than the field can address.
    pub fn from_index(index: usize) -> Option<Self> {
        u16::try_from(index).ok().map(Self)
    }

    pub fn index(self) -> usize {
        usize::from(self.0)
    }

    pub fn is_local(self) -> bool {
        self == LOCAL_SLOT
    }
}

impl MachineKey {
    /// Builds a key from a slot and an ordinal. Returns `None` when the
    /// ordinal does not fit, so exhaustion fails closed instead of aliasing
    /// another provider's rows.
    pub fn from_parts(slot: ProviderSlot, ordinal: u64) -> Option<Self> {
        if ordinal > MAX_ORDINAL {
            return None;
        }
        Some(Self((u64::from(slot.0) << ORDINAL_BITS) | ordinal))
    }

    pub fn slot(self) -> ProviderSlot {
        ProviderSlot((self.0 >> ORDINAL_BITS) as u16)
    }

    pub fn ordinal(self) -> u64 {
        self.0 & MAX_ORDINAL
    }
}

/// Hands out stable keys for one provider.
///
/// The same provider-stable id keeps the same key for the life of the
/// allocator, so a snapshot refresh does not move a row or invalidate a
/// pending action. [`Self::retain`] drops the ids a provider no longer
/// reports. An id that returns after removal receives a fresh key, and an
/// action that still carries the removed key fails closed.
#[derive(Debug)]
pub struct SlotKeyAllocator {
    slot: ProviderSlot,
    next_ordinal: u64,
    assigned: HashMap<String, MachineKey>,
}

impl SlotKeyAllocator {
    pub fn new(slot: ProviderSlot) -> Self {
        Self { slot, next_ordinal: 0, assigned: HashMap::new() }
    }

    pub fn slot(&self) -> ProviderSlot {
        self.slot
    }

    /// Returns the key for a provider-stable id, and assigns one when the id
    /// is new. Returns `None` only when this provider exhausted its ordinals.
    pub fn key_for(&mut self, provider_id: &str) -> Option<MachineKey> {
        if let Some(key) = self.assigned.get(provider_id) {
            return Some(*key);
        }
        let key = MachineKey::from_parts(self.slot, self.next_ordinal)?;
        self.next_ordinal += 1;
        self.assigned.insert(provider_id.to_string(), key);
        Some(key)
    }

    /// Looks a key up without assigning one.
    pub fn peek(&self, provider_id: &str) -> Option<MachineKey> {
        self.assigned.get(provider_id).copied()
    }

    /// Drops every id the provider no longer reports, so a long session with
    /// machine churn cannot grow the map without bound.
    pub fn retain<F>(&mut self, mut live: F)
    where
        F: FnMut(&str) -> bool,
    {
        self.assigned.retain(|id, _| live(id.as_str()));
    }

    #[cfg(test)]
    pub fn tracked(&self) -> usize {
        self.assigned.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn machine_key_round_trips_slot_and_ordinal() {
        let slot = ProviderSlot::from_index(3).expect("slot");
        let key = MachineKey::from_parts(slot, 42).expect("key");
        assert_eq!(key.slot(), slot);
        assert_eq!(key.ordinal(), 42);
    }

    #[test]
    fn machine_key_separates_equal_ordinals_in_different_slots() {
        let first = ProviderSlot::from_index(1).expect("slot");
        let second = ProviderSlot::from_index(2).expect("slot");
        let left = MachineKey::from_parts(first, 7).expect("key");
        let right = MachineKey::from_parts(second, 7).expect("key");
        assert_ne!(left, right);
        assert_eq!(left.ordinal(), right.ordinal());
        assert_ne!(left.slot(), right.slot());
    }

    #[test]
    fn machine_key_rejects_an_ordinal_that_would_reach_the_next_slot() {
        let slot = ProviderSlot::from_index(1).expect("slot");
        assert!(MachineKey::from_parts(slot, MAX_ORDINAL).is_some());
        assert!(MachineKey::from_parts(slot, MAX_ORDINAL + 1).is_none());
    }

    #[test]
    fn local_slot_holds_the_first_position() {
        assert!(LOCAL_SLOT.is_local());
        assert_eq!(ProviderSlot::from_index(0), Some(LOCAL_SLOT));
        assert!(!ProviderSlot::from_index(1).expect("slot").is_local());
    }

    #[test]
    fn provider_slot_rejects_an_index_beyond_the_field() {
        assert!(ProviderSlot::from_index(usize::from(u16::MAX)).is_some());
        assert!(ProviderSlot::from_index(usize::from(u16::MAX) + 1).is_none());
    }

    #[test]
    fn allocator_keeps_one_key_for_one_provider_id() {
        let mut allocator = SlotKeyAllocator::new(ProviderSlot::from_index(2).expect("slot"));
        let first = allocator.key_for("sandbox-a").expect("key");
        let again = allocator.key_for("sandbox-a").expect("key");
        assert_eq!(first, again);
        assert_eq!(allocator.tracked(), 1);
    }

    #[test]
    fn allocator_gives_every_id_its_own_key_inside_one_slot() {
        let mut allocator = SlotKeyAllocator::new(ProviderSlot::from_index(2).expect("slot"));
        let first = allocator.key_for("sandbox-a").expect("key");
        let second = allocator.key_for("sandbox-b").expect("key");
        assert_ne!(first, second);
        assert_eq!(first.slot(), second.slot());
    }

    #[test]
    fn allocator_stamps_every_key_with_its_own_slot() {
        let slot = ProviderSlot::from_index(5).expect("slot");
        let mut allocator = SlotKeyAllocator::new(slot);
        let key = allocator.key_for("sandbox-a").expect("key");
        assert_eq!(key.slot(), slot);
        assert_eq!(allocator.slot(), slot);
    }

    #[test]
    fn two_providers_may_share_a_stable_id_without_colliding() {
        let mut left = SlotKeyAllocator::new(ProviderSlot::from_index(1).expect("slot"));
        let mut right = SlotKeyAllocator::new(ProviderSlot::from_index(2).expect("slot"));
        let from_left = left.key_for("default").expect("key");
        let from_right = right.key_for("default").expect("key");
        assert_ne!(from_left, from_right);
    }

    #[test]
    fn peek_does_not_assign_a_key() {
        let mut allocator = SlotKeyAllocator::new(ProviderSlot::from_index(1).expect("slot"));
        assert_eq!(allocator.peek("sandbox-a"), None);
        assert_eq!(allocator.tracked(), 0);
        let key = allocator.key_for("sandbox-a").expect("key");
        assert_eq!(allocator.peek("sandbox-a"), Some(key));
    }

    #[test]
    fn retain_drops_ids_the_provider_stopped_reporting() {
        let mut allocator = SlotKeyAllocator::new(ProviderSlot::from_index(1).expect("slot"));
        let kept = allocator.key_for("kept").expect("key");
        allocator.key_for("removed").expect("key");
        assert_eq!(allocator.tracked(), 2);
        allocator.retain(|id| id == "kept");
        assert_eq!(allocator.tracked(), 1);
        assert_eq!(allocator.peek("kept"), Some(kept));
        assert_eq!(allocator.peek("removed"), None);
    }

    #[test]
    fn a_returning_id_does_not_reuse_the_removed_key() {
        let mut allocator = SlotKeyAllocator::new(ProviderSlot::from_index(1).expect("slot"));
        let original = allocator.key_for("flaky").expect("key");
        allocator.retain(|_| false);
        let replacement = allocator.key_for("flaky").expect("key");
        assert_ne!(original, replacement);
    }

    #[test]
    fn allocator_fails_closed_when_one_provider_exhausts_its_ordinals() {
        let mut allocator = SlotKeyAllocator::new(ProviderSlot::from_index(1).expect("slot"));
        allocator.next_ordinal = MAX_ORDINAL;
        assert!(allocator.key_for("last").is_some());
        assert!(allocator.key_for("overflow").is_none());
    }
}
