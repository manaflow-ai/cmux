use super::*;
use cmux_link::native_token::{NativeTokenVerifier, ReceiverTime};
use serde_json::json;

const V2: &str = r#"{"alg":"EdDSA","kid":"test-k1","typ":"cmux-native-link-v2+jwt"}"#;

fn pinned(generation: &str) -> NativeTokenVerifier {
    let time = ReceiverTime { unix_ms: 1_792_000_010_000, monotonic: std::time::Instant::now() };
    let receiver =
        NativeTokenVerifier::new_for_receiver(keys(), generation.into(), move || Some(time), 2)
            .unwrap();
    receiver.replace_authority(policy(&fixture(), time)).unwrap();
    receiver
}

fn claims(generation: &str) -> Value {
    let mut claims = fixture()["claims"].clone();
    claims["receiver"] = json!({"version":2,"generation":generation});
    claims
}

fn sign_v2(claims: &Value) -> String {
    sign_bytes(&serde_json::to_vec(claims).unwrap(), V2)
}

#[test]
fn native_receiver_generation_refuses_a_saved_token_across_fresh_replay_owners() {
    let old = pinned(&"a".repeat(64));
    let saved = sign_v2(&claims(&"a".repeat(64)));
    assert!(old.verify(&saved, &expected(Service::Daemon)).is_ok());
    let replacement = pinned(&"b".repeat(64));
    assert!(replacement.verify(&saved, &expected(Service::Daemon)).is_err());
    // Same original keys, peer and jti. The old-generation refusal must not
    // spend the new token or require retaining the previous process's map.
    let fresh = sign_v2(&claims(&"b".repeat(64)));
    assert!(replacement.verify(&fresh, &expected(Service::Daemon)).is_ok());
    assert_eq!(replacement.verify(&fresh, &expected(Service::Daemon)), Err(TokenRefused::Replayed));
}

#[test]
fn native_receiver_generation_never_falls_back_to_a_legacy_contract() {
    let generation = "a".repeat(64);
    let receiver = pinned(&generation);
    assert!(
        receiver.verify(fixture()["token"].as_str().unwrap(), &expected(Service::Daemon)).is_err()
    );
    assert!(receiver.verify(&signed(&claims(&generation)), &expected(Service::Daemon)).is_err());
    assert!(receiver.verify(&sign_v2(&fixture()["claims"]), &expected(Service::Daemon)).is_err());
    assert!(receiver.verify(&sign_v2(&claims(&generation)), &expected(Service::Daemon)).is_ok());
    assert!(
        super::receiver()
            .verify(&sign_v2(&claims(&generation)), &expected(Service::Daemon))
            .is_err()
    );
}

#[test]
fn native_receiver_generation_requires_exact_signed_version_and_shape() {
    let generation = "a".repeat(64);
    for value in [
        json!(null),
        json!({"version":1,"generation":generation}),
        json!({"version":2,"generation":generation,"extra":true}),
        json!({"version":2,"generation":"A".repeat(64)}),
    ] {
        let receiver = pinned(&generation);
        let mut invalid = claims(&generation);
        invalid["receiver"] = value;
        assert!(receiver.verify(&sign_v2(&invalid), &expected(Service::Daemon)).is_err());
        assert!(
            receiver.verify(&sign_v2(&claims(&generation)), &expected(Service::Daemon)).is_ok()
        );
    }
}

#[test]
fn native_receiver_generation_refuses_an_invalid_private_pin() {
    for generation in [String::new(), "a".repeat(63), "A".repeat(64), "g".repeat(64)] {
        assert!(NativeTokenVerifier::new_for_receiver(keys(), generation, || None, 2).is_err());
    }
}

#[test]
fn native_receiver_generation_accepts_worker_machine_roles_and_preserves_the_signed_answer() {
    use cmux_link::token::VmKind;
    let generation = "a".repeat(64);
    for (value, expected_kind) in [("owner", VmKind::Owner), ("team", VmKind::Team)] {
        let receiver = pinned(&generation);
        let mut current_worker_claims = claims(&generation);
        current_worker_claims["vmk"] = json!(value);
        let token = sign_v2(&current_worker_claims);
        let verified = receiver.verify(&token, &expected(Service::Daemon)).unwrap();
        assert_eq!(verified.vm_kind, Some(expected_kind));
        assert_eq!(
            receiver.verify(&token, &expected(Service::Daemon)),
            Err(TokenRefused::Replayed)
        );
    }
    let old = pinned(&generation)
        .verify(&sign_v2(&claims(&generation)), &expected(Service::Daemon))
        .unwrap();
    assert_eq!(old.vm_kind, None, "an absent old claim must not grant owner authority");
}

#[test]
fn native_receiver_generation_rejects_malformed_worker_machine_roles_without_spending_token() {
    let generation = "a".repeat(64);
    for value in [json!("admin"), json!("Owner"), json!(null), json!(false), json!(1), json!({})] {
        let receiver = pinned(&generation);
        let mut invalid = claims(&generation);
        invalid["vmk"] = value;
        assert_eq!(
            receiver.verify(&sign_v2(&invalid), &expected(Service::Daemon)),
            Err(TokenRefused::Invalid)
        );
        invalid["vmk"] = json!("owner");
        assert!(receiver.verify(&sign_v2(&invalid), &expected(Service::Daemon)).is_ok());
    }
}
