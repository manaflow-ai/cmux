//! The signed pointer around a root manifest: the signature, purpose, channel and replay floor.

use base64::Engine as _;
use cmux_cas::{IdScheme, Manifest, MemStore, Params, Pointer, hex};
use cmux_signed_envelope::{Key, key_id};
use ring::rand::SystemRandom;
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};

fn key_pair() -> Ed25519KeyPair {
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
    Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
}

fn trust(pair: &Ed25519KeyPair) -> Vec<Key> {
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    vec![(key_id(&raw), raw)]
}

fn envelope(pair: &Ed25519KeyPair, payload: &[u8]) -> Vec<u8> {
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    serde_json::to_vec(&json!({
        "schema": 1,
        "payload": b64.encode(payload),
        "signatures": [{"key_id": key_id(&raw), "sig": b64.encode(pair.sign(payload).as_ref())}],
    }))
    .unwrap()
}

fn payload(root: &str, floor: u64) -> Value {
    json!({
        "purpose": "cmux-cas-pointer", "schema": 1, "channel": "web-every-merge",
        "root": root, "size": 370_005, "commit": "bfc014745f74c8822b49837a82cd90b7f23b3c47",
        "abi": 1, "floor": floor, "https_base": "https://files.cmux.com/cas/",
    })
}

#[test]
fn manifest_signature_check() {
    let store = MemStore::new();
    let bytes = vec![42u8; 100_000];
    let m = Manifest::build(
        "web-bundle",
        &IdScheme::Public,
        &[("index.js", 0o644, &bytes)],
        Params::CAS_V1,
        &store,
    )
    .unwrap();
    let manifest_bytes = m.to_json().unwrap();
    let root = hex(&m.root().unwrap());
    let signer = key_pair();
    let keys = trust(&signer);
    let body = envelope(&signer, &serde_json::to_vec(&payload(&root, 7)).unwrap());

    // A good pointer opens and names the manifest, which opens only under its root.
    let pointer = Pointer::open(&body, &keys, "web-every-merge", 7).unwrap();
    let opened = Manifest::open(&manifest_bytes, &pointer.root_id().unwrap()).unwrap();
    assert_eq!(opened.assemble(&store, &IdScheme::Public).unwrap(), bytes);

    // A manifest changed after signing does not hash to the signed root.
    let mut tampered = m;
    tampered.kind = "something-else".into();
    assert!(Manifest::open(&tampered.to_json().unwrap(), &pointer.root_id().unwrap()).is_err());

    // Another key's signature is refused.
    let stranger = key_pair();
    assert!(
        Pointer::open(
            &envelope(&stranger, &serde_json::to_vec(&payload(&root, 7)).unwrap()),
            &keys,
            "web-every-merge",
            0
        )
        .is_err()
    );

    // A payload changed after signing is refused.
    let mut env: Value = serde_json::from_slice(&body).unwrap();
    let forged = serde_json::to_vec(&payload(&hex(&[0; 32]), 7)).unwrap();
    env["payload"] = json!(base64::engine::general_purpose::STANDARD.encode(forged));
    assert!(
        Pointer::open(&serde_json::to_vec(&env).unwrap(), &keys, "web-every-merge", 0).is_err()
    );

    // Another channel, another purpose, and an old pointer replayed are refused.
    assert!(Pointer::open(&body, &keys, "app-nightly", 0).is_err());
    let mut other = payload(&root, 7);
    other["purpose"] = json!("cmux-linux-release");
    assert!(
        Pointer::open(
            &envelope(&signer, &serde_json::to_vec(&other).unwrap()),
            &keys,
            "web-every-merge",
            0
        )
        .is_err()
    );
    assert!(Pointer::open(&body, &keys, "web-every-merge", 8).is_err());
}
