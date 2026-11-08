use cmux_remote_protocol::RelayControl;
use worker::{Response, WebSocket, WebSocketIncomingMessage};

pub(crate) const MAX_CONTROL_MESSAGE_BYTES: usize = 4 * 1024;

pub(crate) fn decode_control(
    message: WebSocketIncomingMessage,
) -> Result<RelayControl, &'static str> {
    let WebSocketIncomingMessage::String(text) = message else {
        return Err("expected a text control message");
    };
    if text.len() > MAX_CONTROL_MESSAGE_BYTES {
        return Err("control message is too large");
    }
    serde_json::from_str(&text).map_err(|_| "control message is invalid")
}

pub(crate) fn send_control(socket: &WebSocket, message: &RelayControl) -> worker::Result<()> {
    let encoded = serde_json::to_string(message)?;
    if encoded.len() > MAX_CONTROL_MESSAGE_BYTES {
        return Err(worker::Error::RustError("outbound relay control message is too large".into()));
    }
    socket.send_with_str(encoded)
}

pub(crate) fn close(socket: &WebSocket, code: u16, reason: &str) {
    let _ = socket.close(Some(code), Some(reason));
}

pub(crate) fn websocket_upgrade(request: &worker::Request) -> worker::Result<bool> {
    Ok(request
        .headers()
        .get("Upgrade")?
        .is_some_and(|value| value.eq_ignore_ascii_case("websocket")))
}

pub(crate) fn upgrade_required() -> worker::Result<Response> {
    Response::error("WebSocket upgrade required", 426)
}

pub(crate) fn valid_opaque_identifier(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

pub(crate) fn valid_circuit_id(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
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
}
