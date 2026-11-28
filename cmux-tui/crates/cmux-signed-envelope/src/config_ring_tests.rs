use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::*;
use crate::key_id;

const NOW: u64 = 1_795_400_000;

fn key_pair() -> Ed25519KeyPair {
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
    Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
}

fn trust(pair: &Ed25519KeyPair) -> Vec<Key> {
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    vec![(key_id(&raw), raw)]
}

fn envelope(pair: &Ed25519KeyPair, payload: &Value) -> Vec<u8> {
    let bytes = serde_json::to_vec(payload).unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    serde_json::to_vec(&json!({
        "schema": 1,
        "payload": b64.encode(&bytes),
        "signatures": [{"key_id": key_id(&raw), "sig": b64.encode(pair.sign(&bytes).as_ref())}],
    }))
    .unwrap()
}

fn payload(seq: u64) -> Value {
    json!({
        "schema": 1,
        "purpose": "cmux-config-ring",
        "ring": "lane-vms",
        "seq": seq,
        "issued_at": NOW - 60,
        "expires_at": NOW + 86_400,
        "flags": {"chat.fast_resume": false, "update.rollout_pct": 25, "web.banner": "maintenance"},
    })
}

#[test]
fn a_signed_ring_gives_its_flags() {
    let pair = key_pair();
    let ring =
        verify(&envelope(&pair, &payload(7)), &trust(&pair), "lane-vms", NOW, Some(6)).unwrap();
    assert_eq!(ring.seq, 7);
    assert_eq!(ring.bool("chat.fast_resume"), Some(false));
    assert_eq!(ring.number("update.rollout_pct"), Some(25.0));
    assert_eq!(ring.string("web.banner"), Some("maintenance"));
    // Absent or another kind: the caller's built-in default holds.
    assert_eq!(ring.bool("web.banner"), None);
    assert_eq!(ring.bool("not.set"), None);
}

#[test]
fn the_same_seq_again_is_the_same_file_and_opens() {
    let pair = key_pair();
    assert!(verify(&envelope(&pair, &payload(7)), &trust(&pair), "lane-vms", NOW, Some(7)).is_ok());
    assert!(verify(&envelope(&pair, &payload(0)), &trust(&pair), "lane-vms", NOW, None).is_ok());
}

#[test]
fn a_replayed_older_ring_is_refused_though_its_signature_is_good() {
    let pair = key_pair();
    let err =
        verify(&envelope(&pair, &payload(6)), &trust(&pair), "lane-vms", NOW, Some(7)).unwrap_err();
    assert!(err.contains("replayed"), "{err}");
}

#[test]
fn a_ring_signed_by_an_untrusted_key_is_refused() {
    let signer = key_pair();
    let other = key_pair();
    let err =
        verify(&envelope(&signer, &payload(7)), &trust(&other), "lane-vms", NOW, None).unwrap_err();
    assert!(err.contains("no valid signature"), "{err}");
}

#[test]
fn a_tampered_payload_is_refused() {
    let pair = key_pair();
    let mut file: Value = serde_json::from_slice(&envelope(&pair, &payload(7))).unwrap();
    let mut changed = payload(7);
    changed["flags"]["chat.fast_resume"] = json!(true);
    let b64 = base64::engine::general_purpose::STANDARD;
    file["payload"] = json!(b64.encode(serde_json::to_vec(&changed).unwrap()));
    let body = serde_json::to_vec(&file).unwrap();
    assert!(verify(&body, &trust(&pair), "lane-vms", NOW, None).is_err());
}

#[test]
fn another_ring_or_another_purpose_is_refused() {
    let pair = key_pair();
    let err = verify(&envelope(&pair, &payload(7)), &trust(&pair), "cloud", NOW, None).unwrap_err();
    assert!(err.contains("not \"cloud\""), "{err}");
    let mut release = payload(7);
    release["purpose"] = json!("cmux-linux-release");
    let err = verify(&envelope(&pair, &release), &trust(&pair), "lane-vms", NOW, None).unwrap_err();
    assert!(err.contains("purpose"), "{err}");
}

#[test]
fn an_expired_ring_is_refused() {
    let pair = key_pair();
    let err = verify(&envelope(&pair, &payload(7)), &trust(&pair), "lane-vms", NOW + 86_400, None)
        .unwrap_err();
    assert!(err.contains("expired"), "{err}");
}

#[test]
fn a_flag_that_is_not_a_scalar_or_has_a_bad_name_is_refused() {
    let pair = key_pair();
    for (name, value) in [
        ("nested", json!({"a": 1})),
        ("list", json!([true])),
        ("null", Value::Null),
        ("Upper.Case", json!(true)),
        ("", json!(true)),
        ("long", json!("x".repeat(MAX_STRING + 1))),
    ] {
        let mut bad = payload(7);
        bad["flags"] = json!({ name: value });
        assert!(
            verify(&envelope(&pair, &bad), &trust(&pair), "lane-vms", NOW, None).is_err(),
            "{name} should be refused"
        );
    }
}

#[test]
fn an_oversized_file_is_refused_before_it_is_opened() {
    let body = vec![b' '; MAX_RING_BYTES + 1];
    let err = verify(&body, &[], "lane-vms", NOW, None).unwrap_err();
    assert!(err.contains("over"), "{err}");
}

#[test]
fn keys_are_the_web_update_keys() {
    assert_eq!(KEYS, crate::linux_release::KEYS);
    let keys = trusted_keys();
    assert_eq!(keys.len(), KEYS.len());
    for (id, raw) in keys {
        assert_eq!(id, key_id(&raw));
    }
}
