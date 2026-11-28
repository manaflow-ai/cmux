use cmux_remote_protocol::{LaneToken, RelayRole};

use super::*;

#[test]
fn circuit_attachment_round_trips_for_hibernation() {
    let attachment = CircuitAttachment {
        circuit: CircuitId("circuit".into()),
        relay: Some(RelaySocketAttachment::circuit(
            RelayRole::Client,
            "slot".into(),
            CircuitId("circuit".into()),
            LaneToken("opaque-lane".into()),
        )),
        phase: CircuitPhase::Ready,
        generation: 7,
        expires_at: 1_000,
        idle_deadline_ms: 2_000,
        outbound: OutboundQueue::default(),
    };

    let encoded = serde_json::to_vec(&attachment).unwrap();
    let decoded: CircuitAttachment = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(decoded, attachment);
    assert!(encoded.len() < 16_384);
}

#[test]
fn legacy_circuit_attachment_defaults_outbound_accounting() {
    let encoded = br#"{
            "circuit":"circuit",
            "relay":null,
            "phase":"pending",
            "generation":0,
            "expires_at":0,
            "idle_deadline_ms":2000
        }"#;
    let decoded: CircuitAttachment = serde_json::from_slice(encoded).unwrap();
    assert_eq!(decoded.outbound, OutboundQueue::default());
}

#[test]
fn reusable_client_control_round_trips_without_one_lane_binding() {
    let attachment = SlotAttachment {
        relay: RelaySocketAttachment {
            role: RelayRole::Client,
            slot: "slot".into(),
            circuit: None,
            lane: None,
        },
        phase: SlotPhase::ClientControl,
        generation: 9,
        expires_at: 1_000,
        idle_deadline_ms: 2_000,
        parked: None,
        last_seen_ms: 0,
        pending_handover: false,
        inline: InlineState::default(),
    };

    let encoded = serde_json::to_vec(&attachment).unwrap();
    let decoded: SlotAttachment = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(decoded, attachment);
    assert!(decoded.relay.circuit.is_none());
    assert!(decoded.relay.lane.is_none());
}
