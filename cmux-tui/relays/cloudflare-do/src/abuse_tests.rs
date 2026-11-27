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
    assert!(ledger.reserve("next-window".into(), 2_000_000, 100 + CIRCUIT_ALLOCATION_WINDOW_MS,));
}
