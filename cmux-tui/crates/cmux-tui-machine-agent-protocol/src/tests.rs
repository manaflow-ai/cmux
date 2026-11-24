use serde_json::json;

use super::*;

fn id(value: &str) -> OpaqueId {
    OpaqueId::new(value).unwrap()
}

fn secret() -> MachineSecret {
    MachineSecret::new("0123456789abcdef0123456789abcdef").unwrap()
}

#[test]
fn hello_and_migration_frames_match_the_v1_wire_shape() {
    let hello = Envelope::new(Message::Hello(Hello {
        machine_id: id("machine-1"),
        secret: secret(),
        connection_nonce: id("connection-1"),
        session: SessionName::new("agents").unwrap(),
        agent_version: AgentVersion::new("0.1.0").unwrap(),
        minimum_generation: 7,
        migration: Some(MigrationProof {
            generation: 8,
            token: MigrationToken::new("migration-token-1234").unwrap(),
        }),
    }));
    assert_eq!(
        serde_json::to_value(&hello).unwrap(),
        json!({
            "protocol": "cmux.machine-agent",
            "version": 1,
            "message": {
                "type": "hello",
                "body": {
                    "machine_id": "machine-1",
                    "secret": "0123456789abcdef0123456789abcdef",
                    "connection_nonce": "connection-1",
                    "session": "agents",
                    "agent_version": "0.1.0",
                    "minimum_generation": 7,
                    "migration": {
                        "generation": 8,
                        "token": "migration-token-1234"
                    }
                }
            }
        })
    );
    let debug = format!("{hello:?}");
    assert!(!debug.contains("0123456789abcdef"));
    assert!(!debug.contains("migration-token"));
}

#[test]
fn data_is_base64_bounded_and_redacted_from_debug() {
    let frame = Envelope::new(Message::Data(StreamData {
        stream_id: 9,
        payload: DataPayload::new(b"\0secret\n".to_vec()).unwrap(),
    }));
    let encoded = serde_json::to_value(&frame).unwrap();
    assert_eq!(encoded["message"]["body"]["payload"], "AHNlY3JldAo");
    assert_eq!(serde_json::from_value::<Envelope>(encoded).unwrap(), frame);
    assert!(!format!("{frame:?}").contains("secret"));
    assert!(DataPayload::new(vec![0; MAX_DATA_BYTES + 1]).is_err());
}

#[test]
fn strict_decode_rejects_downgraded_oversized_and_ambiguous_values() {
    let wrong_version = json!({
        "protocol": "cmux.machine-agent",
        "version": 0,
        "message": {"type": "ping", "body": {"nonce": 1}}
    });
    assert!(serde_json::from_value::<Envelope>(wrong_version).is_err());

    let unknown = json!({
        "protocol": "cmux.machine-agent",
        "version": 1,
        "message": {
            "type": "open",
            "body": {
                "stream_id": 1,
                "open_id": "open-1",
                "initial_window": 1024,
                "command": "sh"
            }
        }
    });
    assert!(serde_json::from_value::<Envelope>(unknown).is_err());

    let unknown_wrapper_field = json!({
        "protocol": "cmux.machine-agent",
        "version": 1,
        "message": {
            "type": "ping",
            "body": {"nonce": 1},
            "extra": "future-semantics"
        }
    });
    assert!(serde_json::from_value::<Envelope>(unknown_wrapper_field).is_err());
    assert!(PairingCode::new(" code").is_err());
    assert!(PairingCode::new("CODE\n123").is_err());
    assert!(OpaqueId::new("x".repeat(MAX_ID_BYTES + 1)).is_err());
    assert!(SessionName::new("../agents").is_err());
    assert!(HeartbeatIntervalMs::new(MIN_HEARTBEAT_INTERVAL_MS - 1).is_err());
    assert!(HeartbeatIntervalMs::new(MAX_HEARTBEAT_INTERVAL_MS + 1).is_err());

    let busy_loop_heartbeat = json!({
        "protocol": "cmux.machine-agent",
        "version": 1,
        "message": {
            "type": "registered",
            "body": {
                "machine_id": "machine-1",
                "generation": 1,
                "heartbeat_interval_ms": 0
            }
        }
    });
    assert!(serde_json::from_value::<Envelope>(busy_loop_heartbeat).is_err());

    let oversized_payload = json!({
        "protocol": "cmux.machine-agent",
        "version": 1,
        "message": {
            "type": "data",
            "body": {
                "stream_id": 1,
                "payload": "A".repeat(MAX_DATA_BYTES.div_ceil(3) * 4 + 1)
            }
        }
    });
    assert!(serde_json::from_value::<Envelope>(oversized_payload).is_err());
}

#[test]
fn credential_wrappers_compare_without_exposing_values() {
    assert_eq!(secret(), secret());
    assert_ne!(secret(), MachineSecret::new("fedcba9876543210fedcba9876543210").unwrap());
    assert_eq!(
        MigrationToken::new("migration-token-1234").unwrap(),
        MigrationToken::new("migration-token-1234").unwrap()
    );
    assert_ne!(PairingCode::new("ABCD-EFGH").unwrap(), PairingCode::new("WXYZ-1234").unwrap());
}

#[test]
fn every_message_round_trips() {
    let messages = vec![
        Message::Registered(Registered {
            machine_id: id("machine-1"),
            generation: 4,
            pairing_code: Some(PairingCode::new("ABCD-EFGH").unwrap()),
            heartbeat_interval_ms: HeartbeatIntervalMs::new(1_000).unwrap(),
        }),
        Message::ReconnectGeneration(ReconnectGeneration {
            generation: 5,
            token: MigrationToken::new("migration-token-1234").unwrap(),
        }),
        Message::GenerationReady(GenerationReady { from_generation: 4, to_generation: 5 }),
        Message::GenerationRejected(GenerationRejected {
            generation: 5,
            code: ErrorCode::new("replay").unwrap(),
        }),
        Message::DrainComplete(DrainComplete { generation: 4 }),
        Message::Open(OpenStream { stream_id: 1, open_id: id("open-1"), initial_window: 4096 }),
        Message::Opened(StreamOpened { stream_id: 1, receive_window: 4096 }),
        Message::Reject(StreamRejected { stream_id: 1, code: ErrorCode::new("replay").unwrap() }),
        Message::Data(StreamData {
            stream_id: 1,
            payload: DataPayload::new(vec![1, 2, 3]).unwrap(),
        }),
        Message::Window(StreamWindow { stream_id: 1, bytes: 3 }),
        Message::Close(StreamClosed { stream_id: 1, code: ErrorCode::new("eof").unwrap() }),
        Message::Ping(Heartbeat { nonce: 1 }),
        Message::Pong(Heartbeat { nonce: 1 }),
    ];
    for message in messages {
        let frame = Envelope::new(message);
        let encoded = serde_json::to_vec(&frame).unwrap();
        assert!(encoded.len() <= MAX_FRAME_BYTES);
        assert_eq!(serde_json::from_slice::<Envelope>(&encoded).unwrap(), frame);
    }
}
