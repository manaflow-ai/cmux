use cmux_remote_protocol::{CircuitId, LaneToken, RelayRole};

use super::*;

const RELAY_CONTROL_CONFORMANCE: &str =
    include_str!("../../../crates/cmux-remote-protocol/tests/fixtures/relay-control-v1.jsonl");

#[test]
fn relay_control_matches_shared_wire_fixture() {
    for encoded in RELAY_CONTROL_CONFORMANCE.lines() {
        let decoded = decode_control(WebSocketIncomingMessage::String(encoded.into())).unwrap();
        assert_eq!(serde_json::to_string(&decoded).unwrap(), encoded);
    }
}

#[test]
fn accepts_url_safe_opaque_ids_only() {
    assert!(valid_opaque_identifier("aZ-09_token", 64));
    assert!(!valid_opaque_identifier("", 64));
    assert!(!valid_opaque_identifier("has/slash", 64));
    assert!(!valid_opaque_identifier("has space", 64));
    assert!(!valid_opaque_identifier(&"a".repeat(65), 64));
}

#[test]
fn circuit_ids_are_cloudflare_object_ids() {
    assert!(valid_circuit_id(&"ab".repeat(32)));
    assert!(!valid_circuit_id("opaque-circuit"));
    assert!(!valid_circuit_id(&"gg".repeat(32)));
}

#[test]
fn v2_allocation_join_and_ready_messages_bind_the_same_route() {
    let circuit = CircuitId("ab".repeat(32));
    let lane = LaneToken("interactive-capability".into());
    let generation = 11;
    let messages = [
        RelayControl::Allocated {
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            join_ticket: "client-join-ticket".into(),
        },
        RelayControl::Incoming {
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            join_ticket: "daemon-join-ticket".into(),
        },
        RelayControl::Join {
            protocol: cmux_remote_protocol::REMOTE_PROTOCOL_VERSION,
            slot: "opaque-slot".into(),
            circuit: circuit.clone(),
            lane: lane.clone(),
            generation,
            ticket: "client-join-ticket".into(),
            role: RelayRole::Client,
        },
        RelayControl::Ready { circuit, lane, generation },
    ];

    for message in messages {
        let encoded = serde_json::to_vec(&message).unwrap();
        assert!(encoded.len() <= MAX_CONTROL_MESSAGE_BYTES);
        let decoded: RelayControl = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded, message);
    }
}
