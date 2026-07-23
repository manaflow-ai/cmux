use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub(crate) const MAX_SLOT_SOCKETS: usize = 8;
pub(crate) const MAX_SLOT_PENDING_SOCKETS: usize = 4;
pub(crate) const MAX_CLIENT_CONTROL_SOCKETS: usize = 6;
pub(crate) const MAX_DAEMON_PENDING_SOCKETS: usize = 1;
pub(crate) const MAX_CIRCUIT_SOCKETS: usize = 4;
pub(crate) const MAX_CIRCUIT_PENDING_SOCKETS: usize = 2;
pub(crate) const MAX_PENDING_CIRCUITS_PER_SLOT: usize = 16;
pub(crate) const MAX_CIRCUITS_PER_SLOT: usize = 32;
pub(crate) const MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW: usize = 64;
pub(crate) const CIRCUIT_ALLOCATION_WINDOW_MS: u64 = 60_000;
pub(crate) const ACTIVE_CIRCUIT_LEASE_MS: u64 = 15 * 60_000;
pub(crate) const ACTIVE_CIRCUIT_RENEW_MS: u64 = 5 * 60_000;

pub(crate) const SLOT_HANDSHAKE_TIMEOUT_MS: u64 = 15_000;
pub(crate) const DAEMON_CONTROL_IDLE_TIMEOUT_MS: u64 = 45_000;
pub(crate) const CLIENT_CONTROL_IDLE_TIMEOUT_MS: u64 = 5 * 60_000;
pub(crate) const CIRCUIT_HANDSHAKE_TIMEOUT_MS: u64 = 15_000;
pub(crate) const CIRCUIT_IDLE_TIMEOUT_MS: u64 = 10 * 60_000;

pub(crate) const CIRCUITS_STORAGE_KEY: &str = "circuits-v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SlotEndpoint {
    Daemon,
    Client,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct SlotSocketCounts {
    pub total: usize,
    pub pending: usize,
    pub client: usize,
    pub daemon_pending: usize,
}

pub(crate) fn admit_slot_socket(counts: SlotSocketCounts, endpoint: SlotEndpoint) -> bool {
    if counts.total >= MAX_SLOT_SOCKETS || counts.pending >= MAX_SLOT_PENDING_SOCKETS {
        return false;
    }
    match endpoint {
        SlotEndpoint::Daemon => counts.daemon_pending < MAX_DAEMON_PENDING_SOCKETS,
        SlotEndpoint::Client => counts.client < MAX_CLIENT_CONTROL_SOCKETS,
    }
}

pub(crate) fn admit_circuit_socket(total: usize, pending: usize) -> bool {
    total < MAX_CIRCUIT_SOCKETS && pending < MAX_CIRCUIT_PENDING_SOCKETS
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "kebab-case")]
enum CircuitLease {
    Pending { deadline_ms: u64 },
    Active { deadline_ms: u64 },
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct CircuitLedger {
    entries: BTreeMap<String, CircuitLease>,
    #[serde(default)]
    allocation_window_started_ms: u64,
    #[serde(default)]
    allocations_in_window: usize,
}

impl CircuitLedger {
    pub fn prune(&mut self, now_ms: u64) {
        self.entries.retain(
            |_, lease| !matches!(lease, CircuitLease::Pending { deadline_ms } | CircuitLease::Active { deadline_ms } if *deadline_ms <= now_ms),
        );
        if self.allocations_in_window > 0
            && now_ms
                >= self.allocation_window_started_ms.saturating_add(CIRCUIT_ALLOCATION_WINDOW_MS)
        {
            self.allocation_window_started_ms = 0;
            self.allocations_in_window = 0;
        }
    }

    pub fn reserve(&mut self, circuit: String, deadline_ms: u64, now_ms: u64) -> bool {
        self.prune(now_ms);
        let pending = self
            .entries
            .values()
            .filter(|lease| matches!(lease, CircuitLease::Pending { .. }))
            .count();
        if deadline_ms <= now_ms
            || pending >= MAX_PENDING_CIRCUITS_PER_SLOT
            || self.entries.len() >= MAX_CIRCUITS_PER_SLOT
            || self.allocations_in_window >= MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW
        {
            return false;
        }
        if self.allocations_in_window == 0 {
            self.allocation_window_started_ms = now_ms;
        }
        self.allocations_in_window += 1;
        self.entries.insert(circuit, CircuitLease::Pending { deadline_ms });
        true
    }

    pub fn activate(&mut self, circuit: &str, now_ms: u64) -> bool {
        self.prune(now_ms);
        let Some(lease) = self.entries.get_mut(circuit) else {
            return false;
        };
        if !matches!(lease, CircuitLease::Pending { .. }) {
            return false;
        }
        *lease =
            CircuitLease::Active { deadline_ms: now_ms.saturating_add(ACTIVE_CIRCUIT_LEASE_MS) };
        true
    }

    pub fn renew(&mut self, circuit: &str, now_ms: u64) -> bool {
        self.prune(now_ms);
        let Some(CircuitLease::Active { deadline_ms }) = self.entries.get_mut(circuit) else {
            return false;
        };
        *deadline_ms = now_ms.saturating_add(ACTIVE_CIRCUIT_LEASE_MS);
        true
    }

    pub fn release(&mut self, circuit: &str) -> bool {
        self.entries.remove(circuit).is_some()
    }

    pub fn next_deadline_ms(&self) -> Option<u64> {
        let circuit_deadline =
            self.entries
                .values()
                .map(|lease| match lease {
                    CircuitLease::Pending { deadline_ms }
                    | CircuitLease::Active { deadline_ms } => *deadline_ms,
                })
                .min();
        let allocation_deadline = (self.allocations_in_window > 0).then(|| {
            self.allocation_window_started_ms.saturating_add(CIRCUIT_ALLOCATION_WINDOW_MS)
        });
        circuit_deadline.into_iter().chain(allocation_deadline).min()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty() && self.allocations_in_window == 0
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }

    #[cfg(test)]
    fn active(&self) -> usize {
        self.entries.values().filter(|lease| matches!(lease, CircuitLease::Active { .. })).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slot_admission_reserves_daemon_and_bounds_pending_clients() {
        assert!(admit_slot_socket(SlotSocketCounts::default(), SlotEndpoint::Daemon));
        assert!(!admit_slot_socket(
            SlotSocketCounts { daemon_pending: 1, ..SlotSocketCounts::default() },
            SlotEndpoint::Daemon,
        ));
        assert!(!admit_slot_socket(
            SlotSocketCounts { pending: MAX_SLOT_PENDING_SOCKETS, ..SlotSocketCounts::default() },
            SlotEndpoint::Client,
        ));
        assert!(!admit_slot_socket(
            SlotSocketCounts { client: MAX_CLIENT_CONTROL_SOCKETS, ..SlotSocketCounts::default() },
            SlotEndpoint::Client,
        ));
    }

    #[test]
    fn circuit_admission_allows_two_peers_but_bounds_pending_upgrades() {
        assert!(admit_circuit_socket(0, 0));
        assert!(admit_circuit_socket(1, 1));
        assert!(!admit_circuit_socket(2, MAX_CIRCUIT_PENDING_SOCKETS));
        assert!(!admit_circuit_socket(MAX_CIRCUIT_SOCKETS, 0));
    }

    #[test]
    fn pending_circuit_ledger_is_bounded_and_recovers_after_expiry() {
        let mut ledger = CircuitLedger::default();
        for index in 0..MAX_PENDING_CIRCUITS_PER_SLOT {
            assert!(ledger.reserve(format!("circuit-{index}"), 200, 100));
        }
        assert!(!ledger.reserve("overflow".into(), 200, 100));
        assert_eq!(ledger.len(), MAX_PENDING_CIRCUITS_PER_SLOT);
        assert!(ledger.reserve("after-expiry".into(), 300, 200));
        assert_eq!(ledger.len(), 1);
        assert_eq!(ledger.next_deadline_ms(), Some(300));
        assert!(ledger.release("after-expiry"));
        assert_eq!(ledger.next_deadline_ms(), Some(100 + CIRCUIT_ALLOCATION_WINDOW_MS));
    }

    #[test]
    fn active_circuits_remain_counted_until_explicit_release() {
        let mut ledger = CircuitLedger::default();
        assert!(ledger.reserve("active".into(), 200, 100));
        assert!(ledger.activate("active", 100));
        ledger.prune(100 + CIRCUIT_ALLOCATION_WINDOW_MS);
        assert_eq!(ledger.len(), 1);
        assert_eq!(ledger.active(), 1);
        assert_eq!(ledger.next_deadline_ms(), Some(100 + ACTIVE_CIRCUIT_LEASE_MS));
        assert!(ledger.renew("active", 200));
        assert_eq!(ledger.next_deadline_ms(), Some(200 + ACTIVE_CIRCUIT_LEASE_MS));
        ledger.prune(200 + ACTIVE_CIRCUIT_LEASE_MS);
        assert_eq!(ledger.len(), 0);
        assert!(!ledger.release("active"));
    }

    #[test]
    fn active_circuit_release_removes_lease_before_expiry() {
        let mut ledger = CircuitLedger::default();
        assert!(ledger.reserve("active".into(), 200, 100));
        assert!(ledger.activate("active", 100));
        assert!(ledger.release("active"));
        assert_eq!(ledger.len(), 0);
    }

    #[test]
    fn active_circuits_enforce_the_total_per_slot_limit() {
        let mut ledger = CircuitLedger::default();
        for index in 0..MAX_CIRCUITS_PER_SLOT {
            let circuit = format!("circuit-{index}");
            assert!(ledger.reserve(circuit.clone(), 200, 100));
            assert!(ledger.activate(&circuit, 100));
        }
        assert!(!ledger.reserve("overflow".into(), 200, 100));
    }

    #[test]
    fn allocation_window_bounds_sequential_create_and_release_churn() {
        let mut ledger = CircuitLedger::default();
        for index in 0..MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW {
            let circuit = format!("circuit-{index}");
            assert!(ledger.reserve(circuit.clone(), 1_000_000, 100));
            assert!(ledger.release(&circuit));
        }
        assert!(!ledger.reserve("rate-limited".into(), 1_000_000, 100));
        assert!(ledger.reserve(
            "next-window".into(),
            2_000_000,
            100 + CIRCUIT_ALLOCATION_WINDOW_MS,
        ));
    }
}
