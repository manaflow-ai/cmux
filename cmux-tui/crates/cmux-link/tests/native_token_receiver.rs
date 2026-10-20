//! Backend-signed Native tokens must authenticate real receiver identities.
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use cmux_link::dial::Service;
use cmux_link::token::{DenyAllTokens, Expected, TokenRefused, TokenVerifier};
use serde_json::Value;

fn fixture() -> Value {
    serde_json::from_str(include_str!("../../../../schemas/link-token/native.json")).unwrap()
}

fn receiver() -> Box<dyn TokenVerifier> {
    Box::new(DenyAllTokens)
}

fn expected(service: Service) -> Expected<'static> {
    Expected { host: "host_00000000000000000002", epoch: 4, service, peer_key: &[b'a'; 32] }
}

#[test]
fn native_token_receiver_accepts_backend_signature_and_preserves_signed_time() {
    let f = fixture();
    let receiver = receiver();
    let verified =
        receiver.verify(f["token"].as_str().unwrap(), &expected(Service::Daemon)).unwrap();
    assert_eq!(verified.peer.install, f["claims"]["sub"].as_str().unwrap());
    assert_eq!(verified.peer.user, f["claims"]["network"]["user"].as_str().unwrap());
    assert_eq!(verified.peer.team, f["claims"]["team"].as_str().unwrap());
    assert_eq!(verified.issued_at_ms, 1_792_000_000_000);
}

#[test]
fn native_token_receiver_is_single_use_across_services() {
    let f = fixture();
    let receiver = receiver();
    let token = f["token"].as_str().unwrap();
    receiver.verify(token, &expected(Service::Ssh)).unwrap();
    assert_eq!(receiver.verify(token, &expected(Service::Daemon)), Err(TokenRefused::Replayed));
}

#[test]
fn native_token_receiver_does_not_spend_on_wrong_wireguard_peer() {
    let f = fixture();
    let receiver = receiver();
    let token = f["token"].as_str().unwrap();
    let wrong = Expected { peer_key: &[7; 32], ..expected(Service::Daemon) };
    assert!(receiver.verify(token, &wrong).is_err());
    assert!(receiver.verify(token, &expected(Service::Daemon)).is_ok());
}

#[test]
fn native_token_receiver_default_stays_closed_and_legacy_tokens_stay_unbound() {
    let f = fixture();
    assert!(
        DenyAllTokens.verify(f["token"].as_str().unwrap(), &expected(Service::Daemon)).is_err()
    );
    let legacy: Value =
        serde_json::from_str(include_str!("../../../../schemas/link-token/vectors.json")).unwrap();
    assert!(
        receiver()
            .verify(legacy["cases"][0]["token"].as_str().unwrap(), &expected(Service::Daemon))
            .is_err()
    );
    assert_eq!(URL_SAFE_NO_PAD.decode(f["public_key"].as_str().unwrap()).unwrap().len(), 32);
}
