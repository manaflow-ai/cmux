//! Canonical terminal activity and durable per-reader read receipts.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::SurfaceUuid;

/// Stable reader reserved for the in-process TUI and legacy protocol clients.
///
/// Registered protocol-v9 clients always use their negotiated `client_uuid`
/// instead, so viewing one frontend never clears another frontend's unread
/// state.
pub const LEGACY_TERMINAL_ACTIVITY_READER_UUID: Uuid =
    Uuid::from_u128(0x434d_5558_0000_4000_8000_0000_0000_0001);

pub(crate) const MAX_TERMINAL_ACTIVITY_FACTS: usize = 16_384;
pub(crate) const MAX_TERMINAL_ACTIVITY_READERS: usize = 1_024;
pub(crate) const MAX_TERMINAL_ACTIVITY_STABLE_RECEIPTS: usize = 65_536;

/// Notification severity retained without notification title or body content.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum NotificationLevel {
    Info,
    Warning,
    Error,
}

impl NotificationLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }
}

/// The kind of canonical activity recorded for one terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TerminalActivityKind {
    Notification,
}

/// The latest canonical activity fact for one terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalActivityFact {
    pub surface_uuid: SurfaceUuid,
    pub sequence: u64,
    pub kind: TerminalActivityKind,
    pub notification: u64,
    pub level: NotificationLevel,
}

/// One durable reader's highest acknowledged activity sequence for a terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalActivityReadReceipt {
    pub reader_uuid: Uuid,
    pub surface_uuid: SurfaceUuid,
    pub seen_sequence: u64,
}

/// Complete activity projection for one stable reader.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalActivitySnapshot {
    pub reader_uuid: Uuid,
    pub latest_sequence: u64,
    pub facts: Vec<TerminalActivityFact>,
    pub receipts: Vec<TerminalActivityReadReceipt>,
}

impl TerminalActivitySnapshot {
    pub fn is_unread(&self, surface_uuid: SurfaceUuid) -> bool {
        let Some(fact) = self.facts.iter().find(|fact| fact.surface_uuid == surface_uuid) else {
            return false;
        };
        let seen = self
            .receipts
            .iter()
            .find(|receipt| receipt.surface_uuid == surface_uuid)
            .map_or(0, |receipt| receipt.seen_sequence);
        fact.sequence > seen
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct ReceiptKey {
    reader_uuid: Uuid,
    surface_uuid: SurfaceUuid,
}

pub(crate) struct TerminalActivityState {
    latest_sequence: u64,
    facts: BTreeMap<SurfaceUuid, TerminalActivityFact>,
    receipts: BTreeMap<ReceiptKey, TerminalActivityReadReceipt>,
    max_facts: usize,
    max_readers: usize,
    max_stable_receipts: usize,
}

impl Default for TerminalActivityState {
    fn default() -> Self {
        Self {
            latest_sequence: 0,
            facts: BTreeMap::new(),
            receipts: BTreeMap::new(),
            max_facts: MAX_TERMINAL_ACTIVITY_FACTS,
            max_readers: MAX_TERMINAL_ACTIVITY_READERS,
            max_stable_receipts: MAX_TERMINAL_ACTIVITY_STABLE_RECEIPTS,
        }
    }
}

impl TerminalActivityState {
    pub(crate) fn restore(
        latest_sequence: u64,
        facts: Vec<TerminalActivityFact>,
        receipts: Vec<TerminalActivityReadReceipt>,
    ) -> anyhow::Result<Self> {
        let mut state = Self::default();
        state.latest_sequence = latest_sequence;
        for fact in facts {
            if state.facts.insert(fact.surface_uuid, fact).is_some() {
                anyhow::bail!("duplicate persisted terminal activity fact");
            }
        }
        for receipt in receipts {
            let key =
                ReceiptKey { reader_uuid: receipt.reader_uuid, surface_uuid: receipt.surface_uuid };
            if state.receipts.insert(key, receipt).is_some() {
                anyhow::bail!("duplicate persisted terminal activity receipt");
            }
        }
        state.validate_limits()?;
        Ok(state)
    }

    pub(crate) fn record_notification(
        &mut self,
        surface_uuid: SurfaceUuid,
        notification: u64,
        level: NotificationLevel,
    ) -> anyhow::Result<TerminalActivityFact> {
        if notification == 0 {
            anyhow::bail!("terminal activity notification id must be nonzero");
        }
        if !self.facts.contains_key(&surface_uuid) && self.facts.len() >= self.max_facts {
            anyhow::bail!("terminal activity fact capacity exhausted");
        }
        let sequence = self
            .latest_sequence
            .checked_add(1)
            .filter(|sequence| *sequence != 0)
            .ok_or_else(|| anyhow::anyhow!("terminal activity sequence exhausted"))?;
        let fact = TerminalActivityFact {
            surface_uuid,
            sequence,
            kind: TerminalActivityKind::Notification,
            notification,
            level,
        };
        self.latest_sequence = sequence;
        self.facts.insert(surface_uuid, fact);
        Ok(fact)
    }

    pub(crate) fn mark_seen(
        &mut self,
        reader_uuid: Uuid,
        surface_uuid: SurfaceUuid,
        seen_sequence: u64,
    ) -> anyhow::Result<(TerminalActivityReadReceipt, bool)> {
        if reader_uuid.is_nil() || seen_sequence == 0 {
            anyhow::bail!("terminal activity reader and seen sequence must be nonzero");
        }
        let fact = self
            .facts
            .get(&surface_uuid)
            .ok_or_else(|| anyhow::anyhow!("terminal has no activity fact"))?;
        if seen_sequence > fact.sequence {
            anyhow::bail!(
                "terminal activity receipt cannot advance beyond current sequence {}",
                fact.sequence
            );
        }
        let key = ReceiptKey { reader_uuid, surface_uuid };
        if let Some(existing) = self.receipts.get(&key).copied()
            && seen_sequence <= existing.seen_sequence
        {
            return Ok((existing, false));
        }
        if !self.receipts.contains_key(&key) && reader_uuid != LEGACY_TERMINAL_ACTIVITY_READER_UUID
        {
            let stable_receipts = self
                .receipts
                .keys()
                .filter(|key| key.reader_uuid != LEGACY_TERMINAL_ACTIVITY_READER_UUID)
                .count();
            if stable_receipts >= self.max_stable_receipts {
                anyhow::bail!("terminal activity receipt capacity exhausted");
            }
            let readers = self.receipts.keys().map(|key| key.reader_uuid).collect::<BTreeSet<_>>();
            if !readers.contains(&reader_uuid) && readers.len() >= self.max_readers {
                anyhow::bail!("terminal activity reader capacity exhausted");
            }
        }
        let receipt = TerminalActivityReadReceipt { reader_uuid, surface_uuid, seen_sequence };
        self.receipts.insert(key, receipt);
        Ok((receipt, true))
    }

    pub(crate) fn mark_latest_seen(
        &mut self,
        reader_uuid: Uuid,
        surface_uuid: SurfaceUuid,
    ) -> anyhow::Result<Option<(TerminalActivityReadReceipt, bool)>> {
        let Some(sequence) = self.facts.get(&surface_uuid).map(|fact| fact.sequence) else {
            return Ok(None);
        };
        self.mark_seen(reader_uuid, surface_uuid, sequence).map(Some)
    }

    pub(crate) fn remove_surface(&mut self, surface_uuid: SurfaceUuid) {
        self.facts.remove(&surface_uuid);
        self.receipts.retain(|key, _| key.surface_uuid != surface_uuid);
    }

    pub(crate) fn snapshot(&self, reader_uuid: Uuid) -> TerminalActivitySnapshot {
        TerminalActivitySnapshot {
            reader_uuid,
            latest_sequence: self.latest_sequence,
            facts: self.facts.values().copied().collect(),
            receipts: self
                .receipts
                .values()
                .filter(|receipt| receipt.reader_uuid == reader_uuid)
                .copied()
                .collect(),
        }
    }

    pub(crate) fn fact(&self, surface_uuid: SurfaceUuid) -> Option<TerminalActivityFact> {
        self.facts.get(&surface_uuid).copied()
    }

    pub(crate) fn is_unread(&self, reader_uuid: Uuid, surface_uuid: SurfaceUuid) -> bool {
        let Some(fact) = self.facts.get(&surface_uuid) else { return false };
        let seen = self
            .receipts
            .get(&ReceiptKey { reader_uuid, surface_uuid })
            .map_or(0, |receipt| receipt.seen_sequence);
        fact.sequence > seen
    }

    pub(crate) fn latest_sequence(&self) -> u64 {
        self.latest_sequence
    }

    pub(crate) fn persisted_facts(&self) -> Vec<TerminalActivityFact> {
        self.facts.values().copied().collect()
    }

    pub(crate) fn persisted_receipts(&self) -> Vec<TerminalActivityReadReceipt> {
        self.receipts.values().copied().collect()
    }

    fn validate_limits(&self) -> anyhow::Result<()> {
        if self.facts.len() > self.max_facts {
            anyhow::bail!("terminal activity fact capacity exceeded");
        }
        let readers = self.receipts.keys().map(|key| key.reader_uuid).collect::<BTreeSet<_>>();
        if readers.len() > self.max_readers {
            anyhow::bail!("terminal activity reader capacity exceeded");
        }
        let stable_receipts = self
            .receipts
            .keys()
            .filter(|key| key.reader_uuid != LEGACY_TERMINAL_ACTIVITY_READER_UUID)
            .count();
        if stable_receipts > self.max_stable_receipts {
            anyhow::bail!("terminal activity receipt capacity exceeded");
        }
        Ok(())
    }

    #[cfg(test)]
    fn with_limits(max_facts: usize, max_readers: usize, max_stable_receipts: usize) -> Self {
        Self { max_facts, max_readers, max_stable_receipts, ..Self::default() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn surface(value: u128) -> SurfaceUuid {
        Uuid::from_u128(value).to_string().parse().unwrap()
    }

    #[test]
    fn capacity_exhaustion_rejects_without_eviction() {
        let mut state = TerminalActivityState::with_limits(1, 2, 1);
        let first = surface(1);
        let second = surface(2);
        let reader_a = Uuid::from_u128(3);
        let reader_b = Uuid::from_u128(4);
        let fact = state.record_notification(first, 1, NotificationLevel::Info).unwrap();

        assert!(state.record_notification(second, 2, NotificationLevel::Info).is_err());
        state.mark_seen(reader_a, first, fact.sequence).unwrap();
        assert!(state.mark_seen(reader_b, first, fact.sequence).is_err());
        assert_eq!(state.snapshot(reader_a).facts, vec![fact]);
        assert_eq!(state.snapshot(reader_a).receipts.len(), 1);
    }

    #[test]
    fn legacy_receipts_have_bounded_fact_cardinality_without_using_stable_capacity() {
        let mut state = TerminalActivityState::with_limits(2, 1, 0);
        for value in [1, 2] {
            let surface = surface(value);
            let fact = state
                .record_notification(surface, value as u64, NotificationLevel::Warning)
                .unwrap();
            state.mark_seen(LEGACY_TERMINAL_ACTIVITY_READER_UUID, surface, fact.sequence).unwrap();
        }
        assert_eq!(state.snapshot(LEGACY_TERMINAL_ACTIVITY_READER_UUID).receipts.len(), 2);
    }

    #[test]
    fn readers_acknowledge_independently_and_new_activity_becomes_unread_again() {
        let mut state = TerminalActivityState::default();
        let surface = surface(1);
        let reader_a = Uuid::from_u128(2);
        let reader_b = Uuid::from_u128(3);
        let first = state.record_notification(surface, 1, NotificationLevel::Info).unwrap();

        assert!(state.snapshot(reader_a).is_unread(surface));
        assert!(state.snapshot(reader_b).is_unread(surface));
        let (receipt, changed) = state.mark_seen(reader_a, surface, first.sequence).unwrap();
        assert!(changed);
        assert_eq!(receipt.seen_sequence, first.sequence);
        assert!(!state.snapshot(reader_a).is_unread(surface));
        assert!(state.snapshot(reader_b).is_unread(surface));

        let (duplicate, changed) = state.mark_seen(reader_a, surface, first.sequence).unwrap();
        assert!(!changed);
        assert_eq!(duplicate, receipt);

        let second = state.record_notification(surface, 2, NotificationLevel::Error).unwrap();
        assert_eq!(second.sequence, first.sequence + 1);
        assert!(state.snapshot(reader_a).is_unread(surface));
        assert!(state.snapshot(reader_b).is_unread(surface));
        assert!(state.mark_seen(reader_a, surface, second.sequence + 1).is_err());
    }

    #[test]
    fn stale_receipt_is_idempotent_and_surface_delete_removes_fact_and_receipts() {
        let mut state = TerminalActivityState::default();
        let surface = surface(10);
        let reader = Uuid::from_u128(11);
        let first = state.record_notification(surface, 1, NotificationLevel::Info).unwrap();
        let second = state.record_notification(surface, 2, NotificationLevel::Warning).unwrap();
        let intermediate = state.mark_seen(reader, surface, first.sequence).unwrap().0;
        assert_eq!(intermediate.seen_sequence, first.sequence);
        assert!(state.snapshot(reader).is_unread(surface));
        let latest = state.mark_seen(reader, surface, second.sequence).unwrap().0;
        let (stale, changed) = state.mark_seen(reader, surface, first.sequence).unwrap();
        assert!(!changed);
        assert_eq!(stale, latest);

        state.remove_surface(surface);
        let snapshot = state.snapshot(reader);
        assert_eq!(snapshot.latest_sequence, second.sequence);
        assert!(snapshot.facts.is_empty());
        assert!(snapshot.receipts.is_empty());
    }

    #[test]
    fn sequence_exhaustion_fails_without_mutating_state() {
        let surface = surface(20);
        let mut state = TerminalActivityState::restore(u64::MAX, Vec::new(), Vec::new()).unwrap();
        assert!(state.record_notification(surface, 1, NotificationLevel::Info).is_err());
        assert_eq!(state.latest_sequence(), u64::MAX);
        assert!(state.persisted_facts().is_empty());
    }
}
