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
    /// The viewer's location hint the circuit was minted with, so a re-sent daemon `Incoming` names the same
    /// region. Absent in a ledger written before it existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
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

fn lease_expired(lease: &CircuitLease, now_ms: u64) -> bool {
    matches!(lease, CircuitLease::Pending { deadline_ms, .. } | CircuitLease::Active { deadline_ms } if *deadline_ms <= now_ms)
}

/// Which slot circuit limit refused an allocation, with the counts that reached it. Sent as the message of the
/// `slot-circuit-capacity` error, so a refused move says whether the slot holds too many circuits (and how many
/// are pending, active or inline) or allocated too many in the window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CapacityRefusal {
    /// The join deadline had already passed.
    Expired,
    /// `MAX_PENDING_CIRCUITS_PER_SLOT` unjoined circuits.
    Pending { pending: usize },
    /// `MAX_CIRCUITS_PER_SLOT` live circuits: `ledger` leases (`pending` of them unjoined) plus `inline` ones.
    Live { ledger: usize, pending: usize, inline: usize },
    /// `MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW` allocations in the window: `ledger` leased plus `inline`.
    Rate { ledger: usize, inline: usize },
}

impl std::fmt::Display for CapacityRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match *self {
            Self::Expired => f.write_str("slot circuit join deadline already passed"),
            Self::Pending { pending } => write!(
                f,
                "slot pending circuit limit reached: {pending} unjoined of {MAX_PENDING_CIRCUITS_PER_SLOT}"
            ),
            Self::Live { ledger, pending, inline } => write!(
                f,
                "slot live circuit limit reached: {ledger} leased ({pending} unjoined, {} active) + {inline} \
                 inline of {MAX_CIRCUITS_PER_SLOT}",
                ledger.saturating_sub(pending)
            ),
            Self::Rate { ledger, inline } => write!(
                f,
                "slot circuit allocation rate limit reached: {ledger} leased + {inline} inline in \
                 {}s of {MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW}",
                CIRCUIT_ALLOCATION_WINDOW_MS / 1_000
            ),
        }
    }
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
        self.try_reserve_beside(circuit, deadline_ms, now_ms, route, inline).is_ok()
    }

    /// `reserve_beside`, naming the limit a refusal hit and the counts that hit it.
    pub fn try_reserve_beside(
        &mut self,
        circuit: String,
        deadline_ms: u64,
        now_ms: u64,
        route: Option<PendingRoute>,
        inline: InlineLoad,
    ) -> Result<(), CapacityRefusal> {
        self.prune(now_ms);
        if deadline_ms <= now_ms {
            return Err(CapacityRefusal::Expired);
        }
        let pending = self
            .entries
            .values()
            .filter(|lease| matches!(lease, CircuitLease::Pending { .. }))
            .count();
        if pending >= MAX_PENDING_CIRCUITS_PER_SLOT {
            return Err(CapacityRefusal::Pending { pending });
        }
        let ledger = self.entries.len();
        if ledger.saturating_add(inline.live) >= MAX_CIRCUITS_PER_SLOT {
            return Err(CapacityRefusal::Live { ledger, pending, inline: inline.live });
        }
        if self.allocations_in_window.saturating_add(inline.allocations_in_window)
            >= MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW
        {
            return Err(CapacityRefusal::Rate {
                ledger: self.allocations_in_window,
                inline: inline.allocations_in_window,
            });
        }
        if self.allocations_in_window == 0 {
            self.allocation_window_started_ms = now_ms;
        }
        self.allocations_in_window += 1;
        self.entries.insert(circuit, CircuitLease::Pending { deadline_ms, route });
        Ok(())
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
        self.inline_refusal(now_ms, inline).is_none()
    }

    /// `admits_inline`'s refusal, if any: the limit hit and the counts that hit it.
    pub fn inline_refusal(&self, now_ms: u64, inline: InlineLoad) -> Option<CapacityRefusal> {
        let live = self.entries.values().filter(|lease| !lease_expired(lease, now_ms));
        let (ledger, pending) = live.fold((0_usize, 0_usize), |(total, pending), lease| {
            (total + 1, pending + usize::from(matches!(lease, CircuitLease::Pending { .. })))
        });
        let in_window = if self.allocations_in_window > 0
            && now_ms
                < self.allocation_window_started_ms.saturating_add(CIRCUIT_ALLOCATION_WINDOW_MS)
        {
            self.allocations_in_window
        } else {
            0
        };
        if ledger.saturating_add(inline.live) >= MAX_CIRCUITS_PER_SLOT {
            return Some(CapacityRefusal::Live { ledger, pending, inline: inline.live });
        }
        if in_window.saturating_add(inline.allocations_in_window)
            >= MAX_CIRCUIT_ALLOCATIONS_PER_WINDOW
        {
            return Some(CapacityRefusal::Rate {
                ledger: in_window,
                inline: inline.allocations_in_window,
            });
        }
        None
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
            SlotSocketCounts {
                daemon_pending: MAX_DAEMON_PENDING_SOCKETS,
                ..SlotSocketCounts::default()
            },
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
    fn closing_websockets_do_not_consume_capacity() {
        assert!(websocket_counts_toward_capacity(1, 200, 100));
        assert!(!websocket_counts_toward_capacity(2, 200, 100));
        assert!(!websocket_counts_toward_capacity(3, 200, 100));
        assert!(!websocket_counts_toward_capacity(1, 100, 100));
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
        assert_eq!(ledger.pending_count(200), 1);
        assert_eq!(ledger.pending_count(300), 0);
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

    fn route(lane: &str) -> Option<PendingRoute> {
        Some(PendingRoute { lane: LaneToken(lane.into()), generation: 7, region: None })
    }

    #[test]
    fn unjoined_lists_pending_circuits_with_routes_until_joined_or_expired() {
        let mut ledger = CircuitLedger::default();
        assert!(ledger.reserve_for("waiting".into(), 300, 100, route("lane-a")));
        assert!(ledger.reserve_for("joined".into(), 300, 100, route("lane-b")));
        assert!(ledger.reserve("no-route".into(), 300, 100));
        assert!(ledger.activate("joined", 150));

        let unjoined = ledger.unjoined(200);
        assert_eq!(
            unjoined,
            vec![UnjoinedCircuit {
                circuit: "waiting".into(),
                route: route("lane-a").unwrap(),
                deadline_ms: 300,
            }]
        );
        assert!(ledger.unjoined(300).is_empty());
    }

    #[test]
    fn ledger_from_before_routes_reads_without_them() {
        let stored = br#"{"entries":{"old":{"phase":"pending","deadline_ms":300}}}"#;
        let ledger: CircuitLedger = serde_json::from_slice(stored).unwrap();
        assert_eq!(ledger.pending_count(200), 1);
        assert!(ledger.unjoined(200).is_empty());

        let mut current = CircuitLedger::default();
        assert!(current.reserve_for("new".into(), 300, 100, route("lane-a")));
        let round_trip: CircuitLedger =
            serde_json::from_slice(&serde_json::to_vec(&current).unwrap()).unwrap();
        assert_eq!(round_trip, current);
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
