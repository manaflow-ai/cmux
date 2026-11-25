use std::collections::BTreeMap;

use cmux_remote_protocol::LaneToken;
use serde::{Deserialize, Serialize};

/// Sockets on one slot that are not inline circuit sockets: a registration, `MAX_STANDBY_SOCKETS_PER_SLOT`
/// standbys and up to `MAX_CLIENT_CONTROL_SOCKETS` clients mid-Connect. An inline circuit's two sockets are bounded
/// by `MAX_CIRCUITS_PER_SLOT` instead and are not counted here (`RelaySlot::socket_counts`).
pub(crate) const MAX_SLOT_SOCKETS: usize = 12;
pub(crate) const MAX_SLOT_PENDING_SOCKETS: usize = 4;
pub(crate) const MAX_CLIENT_CONTROL_SOCKETS: usize = 6;
/// A daemon upgrade is Pending until its first message: a registration and a standby it opens beside it can overlap.
pub(crate) const MAX_DAEMON_PENDING_SOCKETS: usize = 2;
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

/// Cloudflare can briefly return WebSockets in the CLOSING state from
/// `get_websockets()`. Only an open, unexpired socket consumes admission
/// capacity; otherwise a deployment cut can reject its own replacement.
pub(crate) fn websocket_counts_toward_capacity(
    ready_state: u16,
    idle_deadline_ms: u64,
    now_ms: u64,
) -> bool {
    websocket_is_open(ready_state) && idle_deadline_ms > now_ms
}

pub(crate) fn websocket_is_open(ready_state: u16) -> bool {
    const OPEN: u16 = 1;
    ready_state == OPEN
}

/// The lane a pending circuit was allocated for, kept so a daemon that
/// registers before the circuit is joined can be sent its `Incoming` again
/// (`RelaySlot::hand_over_unjoined`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PendingRoute {
    pub lane: LaneToken,
    pub generation: u64,
}

/// A pending circuit a newly registered daemon is sent `Incoming` for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct UnjoinedCircuit {
    pub circuit: String,
    pub route: PendingRoute,
    pub deadline_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "kebab-case")]
enum CircuitLease {
    Pending {
        deadline_ms: u64,
        /// Absent on an entry written before routes were kept.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        route: Option<PendingRoute>,
    },
    Active {
        deadline_ms: u64,
    },
}

/// What the slot's inline circuits (`crate::inline`) already take of the ledger's limits: the live ones, and
/// those allocated inside the current allocation window.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct InlineLoad {
    pub live: usize,
    pub allocations_in_window: usize,
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
            |_, lease| !matches!(lease, CircuitLease::Pending { deadline_ms, .. } | CircuitLease::Active { deadline_ms } if *deadline_ms <= now_ms),
        );
        if self.allocations_in_window > 0
            && now_ms
                >= self.allocation_window_started_ms.saturating_add(CIRCUIT_ALLOCATION_WINDOW_MS)
        {
            self.allocation_window_started_ms = 0;
            self.allocations_in_window = 0;
        }
    }

    #[cfg(test)]
    pub fn reserve(&mut self, circuit: String, deadline_ms: u64, now_ms: u64) -> bool {
        self.reserve_for(circuit, deadline_ms, now_ms, None)
    }

    /// Reserves a pending circuit allocated for `route`.
    #[cfg(test)]
    pub fn reserve_for(
        &mut self,
        circuit: String,
        deadline_ms: u64,
        now_ms: u64,
        route: Option<PendingRoute>,
    ) -> bool {
        self.reserve_beside(circuit, deadline_ms, now_ms, route, InlineLoad::default())
    }

    /// `reserve_for` with the slot's inline circuits (`crate::inline`) counted against the same total and
    /// allocation-rate limits as the ledger's own.
    pub fn reserve_beside(
        &mut self,
        circuit: String,
        deadline_ms: u64,
        now_ms: u64,
        route: Option<PendingRoute>,
        inline: InlineLoad,
    ) -> bool {
        self.prune(now_ms);
        let pending = self
            .entries
            .values()
            .filter(|lease| matches!(lease, CircuitLease::Pending { .. }))
            .count();
        if deadline_ms <= now_ms
            || pending >= MAX_PENDING_CIRCUITS_PER_SLOT
            || self.entries.len().saturating_add(inline.live) >= MAX_CIRCUITS_PER_SLOT
            || self.allocations_in_window.saturating_add(inline.allocations_in_window)
                >= MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW
        {
            return false;
        }
        if self.allocations_in_window == 0 {
            self.allocation_window_started_ms = now_ms;
        }
        self.allocations_in_window += 1;
        self.entries.insert(circuit, CircuitLease::Pending { deadline_ms, route });
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
        let circuit_deadline = self
            .entries
            .values()
            .map(|lease| match lease {
                CircuitLease::Pending { deadline_ms, .. }
                | CircuitLease::Active { deadline_ms } => *deadline_ms,
            })
            .min();
        let allocation_deadline = (self.allocations_in_window > 0).then(|| {
            self.allocation_window_started_ms.saturating_add(CIRCUIT_ALLOCATION_WINDOW_MS)
        });
        circuit_deadline.into_iter().chain(allocation_deadline).min()
    }

    /// Pending allocations still inside their join deadline.
    pub fn pending_count(&self, now_ms: u64) -> usize {
        self.entries
            .values()
            .filter(|lease| matches!(lease, CircuitLease::Pending { deadline_ms, .. } if *deadline_ms > now_ms))
            .count()
    }

    /// Pending circuits inside their join deadline that kept their route:
    /// allocated, but no daemon has joined them yet.
    pub fn unjoined(&self, now_ms: u64) -> Vec<UnjoinedCircuit> {
        self.entries
            .iter()
            .filter_map(|(circuit, lease)| match lease {
                CircuitLease::Pending { deadline_ms, route: Some(route) }
                    if *deadline_ms > now_ms =>
                {
                    Some(UnjoinedCircuit {
                        circuit: circuit.clone(),
                        route: route.clone(),
                        deadline_ms: *deadline_ms,
                    })
                }
                _ => None,
            })
            .collect()
    }

    /// Whether one more inline circuit fits beside the ledger's: the same total and allocation-rate limits
    /// `reserve_beside` applies, read without writing the ledger.
    pub fn admits_inline(&self, now_ms: u64, inline: InlineLoad) -> bool {
        let live = self
            .entries
            .values()
            .filter(|lease| {
                !matches!(lease, CircuitLease::Pending { deadline_ms, .. } | CircuitLease::Active { deadline_ms } if *deadline_ms <= now_ms)
            })
            .count();
        let in_window = if self.allocations_in_window > 0
            && now_ms
                < self.allocation_window_started_ms.saturating_add(CIRCUIT_ALLOCATION_WINDOW_MS)
        {
            self.allocations_in_window
        } else {
            0
        };
        live.saturating_add(inline.live) < MAX_CIRCUITS_PER_SLOT
            && in_window.saturating_add(inline.allocations_in_window)
                < MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW
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
#[path = "abuse_tests.rs"]
mod tests;
