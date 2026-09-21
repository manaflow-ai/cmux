use cmux_v3_control_server::{proof::Proof, Authorization, Enrollment, Signed};
use ed25519_dalek::{Signer, SigningKey};
use libp2p_identity::{ed25519, PublicKey};
use uuid::Uuid;

#[test]
fn proof_binds_user_region_deployment_operation_and_payload() {
    let key = SigningKey::from_bytes(&[3; 32]);
    let body = Enrollment {
        team: "team-a".into(),
        device_id: Uuid::new_v4(),
        addresses: vec![],
        metadata: None,
    };
    let mut proof = Proof {
        public_key: hex::encode(key.verifying_key().as_bytes()),
        nonce: Uuid::new_v4(),
        issued_at: 100,
        signature: String::new(),
    };
    proof.signature = hex::encode(
        key.sign(
            &proof
                .message("staging", "alice", "/v3/enroll", &body)
                .unwrap(),
        )
        .to_bytes(),
    );
    let expected = PublicKey::from(
        ed25519::PublicKey::try_from_bytes(key.verifying_key().as_bytes()).unwrap(),
    )
    .to_peer_id();
    assert_eq!(
        proof
            .verify("staging", "alice", "/v3/enroll", &body, 100)
            .unwrap(),
        expected
    );
    assert!(proof
        .verify("production", "alice", "/v3/enroll", &body, 100)
        .is_err());
    assert!(proof
        .verify("staging", "bob", "/v3/enroll", &body, 100)
        .is_err());
    assert!(proof
        .verify("staging", "alice", "/v3/authorize", &body, 100)
        .is_err());
    assert!(proof
        .verify(
            "staging",
            "alice",
            "/v3/enroll",
            &Enrollment {
                team: "team-b".into(),
                device_id: body.device_id,
                addresses: vec![],
                metadata: None,
            },
            100
        )
        .is_err());
    assert!(proof
        .verify("staging", "alice", "/v3/enroll", &body, 99)
        .is_err());
    assert!(proof
        .verify("staging", "alice", "/v3/enroll", &body, 161)
        .is_err());
    proof.nonce = Uuid::new_v4();
    assert!(proof
        .verify("staging", "alice", "/v3/enroll", &body, 100)
        .is_err());
}
#[test]
fn enrollment_cannot_assign_privileges_and_no_claimed_source_identity() {
    let proof = serde_json::json!({"public_key":"00".repeat(32),"nonce":Uuid::new_v4(),"issued_at":100,"signature":"00".repeat(64)});
    let valid = serde_json::json!({"request":{"team":"a","device_id":Uuid::new_v4(),"addresses":[]},"proof":proof});
    assert!(serde_json::from_value::<Signed<Enrollment>>(valid.clone()).is_ok());
    for (field, value) in [
        ("tags", serde_json::json!(["admin"])),
        ("offline", serde_json::json!({"mode":"until_revoked"})),
        ("owner", serde_json::json!("alice")),
    ] {
        let mut input = valid.clone();
        input["request"][field] = value;
        assert!(serde_json::from_value::<Signed<Enrollment>>(input).is_err());
    }
    assert!(serde_json::from_value::<Authorization>(
        serde_json::json!({"team":"a","destination":"p","action":"connect","source":"forged"})
    )
    .is_err());
}

#[test]
fn enrollment_metadata_is_bounded_and_cannot_claim_authority() {
    let valid = serde_json::json!({"platform":"mac","instance_tag":"v3dog","display_name":"Office Mac","pairing_enabled":true,"client_namespace":"mac:com.cmuxterm.app.debug.v3dog"});
    let metadata: cmux_v3_control_server::DeviceMetadata =
        serde_json::from_value(valid.clone()).unwrap();
    assert!(metadata.valid());
    for (field, value) in [
        ("instance_tag", serde_json::json!("")),
        ("instance_tag", serde_json::json!("a".repeat(129))),
        ("display_name", serde_json::json!("a".repeat(257))),
        ("display_name", serde_json::json!("name\nforged")),
        ("client_namespace", serde_json::json!("")),
        (
            "client_namespace",
            serde_json::json!("ios:com.cmuxterm.app"),
        ),
        ("platform", serde_json::json!("ios")),
    ] {
        let mut input = valid.clone();
        input[field] = value;
        let metadata: cmux_v3_control_server::DeviceMetadata =
            serde_json::from_value(input).unwrap();
        assert!(!metadata.valid(), "accepted invalid {field}");
    }
    let mut forged = valid;
    forged["tags"] = serde_json::json!(["admin"]);
    assert!(serde_json::from_value::<cmux_v3_control_server::DeviceMetadata>(forged).is_err());
}

#[test]
fn device_proof_binds_discovery_metadata() {
    let key = SigningKey::from_bytes(&[7; 32]);
    let mut body = Enrollment {
        team: "team-a".into(),
        device_id: Uuid::new_v4(),
        addresses: vec![],
        metadata: Some(cmux_v3_control_server::DeviceMetadata {
            platform: cmux_v3_control_server::DevicePlatform::Mac,
            instance_tag: "v3dog".into(),
            display_name: "Mac".into(),
            pairing_enabled: true,
            client_namespace: "mac:com.cmuxterm.app.debug.v3dog".into(),
        }),
    };
    let mut proof = Proof {
        public_key: hex::encode(key.verifying_key().as_bytes()),
        nonce: Uuid::new_v4(),
        issued_at: 100,
        signature: String::new(),
    };
    proof.signature = hex::encode(
        key.sign(
            &proof
                .message("staging", "alice", "/v3/enroll", &body)
                .unwrap(),
        )
        .to_bytes(),
    );
    assert!(proof
        .verify("staging", "alice", "/v3/enroll", &body, 100)
        .is_ok());
    body.metadata.as_mut().unwrap().instance_tag = "default".into();
    assert!(proof
        .verify("staging", "alice", "/v3/enroll", &body, 100)
        .is_err());
}
