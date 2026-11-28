use cmux_remote_protocol::{CircuitId, LaneToken};

use super::*;

fn claims(permission: RelayPermission, role: RelayRole) -> RelayTicketClaims {
    RelayTicketClaims {
        version: RelayTicketClaims::VERSION,
        issuer: "issuer".into(),
        permission,
        role,
        slot: "slot-a".into(),
        circuit: None,
        lane: None,
        generation: None,
        issued_at_unix: 50,
        expires_at_unix: 100,
        grant: None,
        region: None,
    }
}

#[test]
fn version_reports_only_a_full_commit_sha() {
    let sha = "0123456789abcdef0123456789abcdef01234567";
    assert_eq!(version_body(Some(sha))["source_revision"], sha);
    assert_eq!(version_body(None)["source_revision"], "unknown");
    assert_eq!(version_body(Some("main"))["source_revision"], "unknown");
    assert_eq!(version_body(Some(&sha.to_uppercase()))["source_revision"], "unknown");
}

#[test]
fn provider_tickets_cannot_materialize_other_slot_objects() {
    let register = claims(RelayPermission::Register, RelayRole::Daemon);
    assert!(claims_authorize_route(&register, AdmissionRoute::DaemonControl { slot: "slot-a" },));
    assert!(!claims_authorize_route(&register, AdmissionRoute::DaemonControl { slot: "slot-b" },));
    assert!(!claims_authorize_route(&register, AdmissionRoute::ClientControl { slot: "slot-a" },));
}

#[test]
fn join_ticket_only_materializes_its_bound_circuit_object() {
    let mut join = claims(RelayPermission::Join, RelayRole::Client);
    join.circuit = Some(CircuitId("ab".repeat(32)));
    join.lane = Some(LaneToken("lane".into()));
    join.generation = Some(3);
    assert!(claims_authorize_route(&join, AdmissionRoute::Circuit { circuit: &"ab".repeat(32) },));
    assert!(!claims_authorize_route(&join, AdmissionRoute::Circuit { circuit: &"cd".repeat(32) },));
}
