use cmux_cloud_wire::{
    Host, OpRequest, ServerNetworkConfirmOp, ServerNetworkConfirmParams,
    ServerNetworkConfirmResult, ServerNetworkState,
};
use serde_json::{Value, json};

fn host() -> Value {
    json!({
        "id": "hst_server", "name": "server", "platform": "linux",
        "owner_user": "usr_owner", "enrolled_by": "ins_daemon", "enrolled_at": 100,
        "kind": "server"
    })
}

fn reservation() -> Value {
    json!({
        "state": "reserved", "tenant": "tenant_team",
        "mesh": "mesh_00000000000000000000000001",
        "device": "dev_00000000000000000000000002"
    })
}

#[test]
fn legacy_hosts_without_network_still_round_trip() {
    let wire = host();
    let decoded: Host = serde_json::from_value(wire.clone()).expect("legacy host");
    assert!(decoded.network.is_none());
    assert_eq!(serde_json::to_value(decoded).expect("encode"), wire);
}

#[test]
fn reserved_and_confirmed_hosts_keep_their_typed_network_identity() {
    for confirmed in [false, true] {
        let mut wire = host();
        let mut network = reservation();
        if confirmed {
            network["state"] = json!("confirmed");
            network["confirmed_at"] = json!(200);
        }
        wire["network"] = network;
        let decoded: Host = serde_json::from_value(wire.clone()).expect("network host");
        match (&decoded.network, confirmed) {
            (Some(ServerNetworkState::ServerNetworkReservation(_)), false)
            | (Some(ServerNetworkState::ServerNetworkBinding(_)), true) => {}
            other => panic!("network fell through to the wrong variant: {other:?}"),
        }
        assert_eq!(serde_json::to_value(decoded).expect("encode"), wire);
    }
}

#[test]
fn confirmation_request_preserves_native_proof_names_and_typed_result() {
    let network = reservation();
    let params = json!({
        "host": "hst_server", "mesh": network["mesh"], "device": network["device"],
        "proof": {"signedAt": 200, "nonce": "A".repeat(22), "signature": "A".repeat(86) + "=="}
    });
    let decoded: ServerNetworkConfirmParams =
        serde_json::from_value(params.clone()).expect("confirmation params");
    assert_eq!(decoded.proof.signed_at, 200);
    let request = OpRequest::new::<ServerNetworkConfirmOp>(decoded).with_idempotency_key("confirm");
    assert_eq!(
        serde_json::to_value(request).expect("encode request"),
        json!({"op": "server.network.confirm", "params": params, "idempotency_key": "confirm"})
    );
    let mut confirmed = network;
    confirmed["state"] = json!("confirmed");
    confirmed["confirmed_at"] = json!(200);
    let wire = json!({"host": "hst_server", "network": confirmed});
    let result: ServerNetworkConfirmResult = serde_json::from_value(wire.clone()).expect("result");
    assert_eq!(result.network.confirmed_at, 200);
    assert_eq!(serde_json::to_value(result).expect("encode result"), wire);
}

#[test]
fn newer_network_states_remain_lossless() {
    let mut wire = host();
    wire["network"] = json!({"state": "newer_state", "future": [1, "two"]});
    let decoded: Host = serde_json::from_value(wire.clone()).expect("newer host");
    assert!(matches!(decoded.network, Some(ServerNetworkState::Unknown(_))));
    assert_eq!(serde_json::to_value(decoded).expect("encode"), wire);
}
