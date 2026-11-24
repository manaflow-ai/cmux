use super::*;
use cmux_server_core::install_key::InstallKey;
use cmux_server_core::pairing::enrollment::Paired;

#[test]
fn sign_uses_the_registered_es256_public_key() {
    let key = InstallKey::generate(&SystemRandom::new()).unwrap();
    let public = key.public_jwk();
    let identity = EnrolledIdentity {
        api: "https://cloud-api.cmux.dev".into(),
        paired: Paired {
            host: "host_abcdefghijklmnopqrst".into(),
            team: "team_abcdefghijklmnopqrst".into(),
            user: "user_abcdefghijklmnopqrst".into(),
            install: "inst_abcdefghijklmnopqrst".into(),
            machine_join: None,
        },
        wireguard_key: Zeroizing::new([0; 32]),
        signing_key: key,
        native: None,
    };
    let message = b"cmux-turn-attestation-test";
    let signature = identity.sign(message).unwrap();
    assert!(cmux_server_core::install_key::verify(&public, message, &signature));
}

#[test]
fn missing_enrollment_is_refused_without_creating_state() {
    let dir = tempfile::tempdir().unwrap();
    let err = match EnrolledIdentity::load(&dir.path().join("pairing/identity.json")) {
        Ok(_) => panic!("missing enrollment unexpectedly loaded"),
        Err(error) => error,
    };
    assert_eq!(err.message, "server.pair.not_enrolled");
    assert!(!dir.path().join("pairing").exists());
}
