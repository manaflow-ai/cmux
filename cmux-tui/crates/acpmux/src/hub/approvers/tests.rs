use super::*;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};

fn key() -> EcdsaKeyPair {
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap()
}

fn sign(k: &EcdsaKeyPair, p: &Parts<'_>) -> String {
    let rng = ring::rand::SystemRandom::new();
    hex(k.sign(&rng, &message(p)).unwrap().as_ref())
}

fn parts<'a>(expires: u64, answers: &'a str) -> Parts<'a> {
    Parts {
        instance: "inst",
        mac: "mac-1",
        approver: "phone-1",
        session: "s1",
        permission: "p1",
        option: "allow",
        nonce: "n1",
        expires_at: expires,
        answers,
    }
}

fn enrolled(k: &EcdsaKeyPair) -> ApproverSet {
    let set = ApproverSet::default();
    set.set(&json!({"macDevice": "mac-1", "approvers": [
            {"id": "phone-1", "publicKey": hex(k.public_key().as_ref()), "name": "iPhone"}]}))
        .unwrap();
    set
}

fn check(set: &ApproverSet, sig: &str, expires: u64, answers: Option<&Value>, now: u64) -> bool {
    let decision = json!({"approver": "phone-1", "expiresAt": expires, "signature": sig});
    set.verifies("inst", "s1", "p1", "allow", "n1", answers, &decision, now)
}

#[test]
fn the_wire_payload_is_fixed() {
    // The same vector is in the phone's ApprovalPayloadTests.
    use sha2::Digest;
    let nonce = "ab".repeat(32);
    let answers = json!({"Which?": "B", "a\"b": ["x\ny", "\u{1}"], "codex": {"answers": ["é"]}});
    let mut text = String::new();
    canonical_json(&answers, &mut text);
    assert_eq!(text, r#"{"Which?":"B","a\"b":["x\ny","\u0001"],"codex":{"answers":["é"]}}"#);
    let digest = answers_digest(Some(&answers));
    assert_eq!(digest, "44ba30ad88bf4d244b42c361e7ba2a97441780fce0cdfd2a175df95d6e2d6fc8");
    for (answers, expected) in [
        ("", "3093d49d440c85bb9f357d0940a5bbd0e822c944fdfe650e9faae0b58afb6c2c"),
        (digest.as_str(), "764300d7c596ec827c3d7ffb2b8b5819816151589c5edce1feecd0937b125fe8"),
    ] {
        let m = message(&Parts {
            instance: "0123abcd",
            mac: "9f1c2d3e-0000-4000-8000-000000000001",
            approver: "6a7b8c9d-0000-4000-8000-000000000002",
            session: "sess-1",
            permission: "perm-7",
            option: "allow_once",
            nonce: &nonce,
            expires_at: 1_760_000_000,
            answers,
        });
        assert_eq!(hex(&sha2::Sha256::digest(&m)), expected);
    }
}

#[test]
fn a_valid_signature_counts_and_every_change_fails() {
    let k = key();
    let set = enrolled(&k);
    let now = 1_000;
    let good = sign(&k, &parts(now + 120, ""));
    assert!(check(&set, &good, now + 120, None, now));
    // Expired, too far ahead, a changed expiry, another key, an unknown approver.
    assert!(!check(&set, &good, now + 120, None, now + 121));
    let far = sign(&k, &parts(now + MAX_LIFETIME + 1, ""));
    assert!(!check(&set, &far, now + MAX_LIFETIME + 1, None, now));
    assert!(!check(&set, &good, now + 119, None, now));
    let other = sign(&key(), &parts(now + 120, ""));
    assert!(!check(&set, &other, now + 120, None, now));
    let decision = json!({"approver": "phone-2", "expiresAt": now + 120, "signature": good});
    assert!(!set.verifies("inst", "s1", "p1", "allow", "n1", None, &decision, now));
    // Another option, nonce, session or daemon run.
    let decision = json!({"approver": "phone-1", "expiresAt": now + 120, "signature": good});
    assert!(!set.verifies("inst", "s1", "p1", "deny", "n1", None, &decision, now));
    assert!(!set.verifies("inst", "s1", "p1", "allow", "n2", None, &decision, now));
    assert!(!set.verifies("inst", "s2", "p1", "allow", "n1", None, &decision, now));
    assert!(!set.verifies("other", "s1", "p1", "allow", "n1", None, &decision, now));
    // Signed with answers: only those answers count.
    let answers = json!({"q": "A"});
    let digest = answers_digest(Some(&answers));
    let signed = sign(&k, &parts(now + 60, &digest));
    assert!(check(&set, &signed, now + 60, Some(&answers), now));
    assert!(!check(&set, &signed, now + 60, Some(&json!({"q": "B"})), now));
    assert!(!check(&set, &signed, now + 60, None, now));
    assert!(!check(&set, &good, now + 120, Some(&answers), now));
}

#[test]
fn revoking_is_replacing_the_set() {
    let k = key();
    let set = enrolled(&k);
    let good = sign(&k, &parts(200, ""));
    assert!(check(&set, &good, 200, None, 100));
    set.set(&json!({"macDevice": "mac-1", "approvers": []})).unwrap();
    assert!(!check(&set, &good, 200, None, 100));
    // A signature for another Mac never counts here.
    set.set(&json!({"macDevice": "mac-2", "approvers": [
            {"id": "phone-1", "publicKey": hex(k.public_key().as_ref()), "name": "iPhone"}]}))
        .unwrap();
    assert!(!check(&set, &good, 200, None, 100));
}

/// Landing term 4 of #24233: revoking the phone stops even a signature made before. A
/// revocation sent while a signed answer is being committed returns only after that commit,
/// and from then on the same signature counts nothing.
#[test]
fn a_revocation_during_a_commit_waits_for_it_and_then_the_signature_counts_nothing() {
    use std::time::Duration;
    let k = key();
    let set = std::sync::Arc::new(enrolled(&k));
    let good = sign(&k, &parts(200, ""));
    let decision = json!({"approver": "phone-1", "expiresAt": 200, "signature": good});
    let (revoked, returned) = std::sync::mpsc::channel();
    let revoker = set.clone();
    let committed =
        set.verifies_then("inst", "s1", "p1", "allow", "n1", None, &decision, 100, || {
            std::thread::spawn(move || {
                revoker.set(&json!({"macDevice": "mac-1", "approvers": []})).unwrap();
                let _ = revoked.send(());
            });
            // The commit is in flight: the revocation has not returned.
            returned.recv_timeout(Duration::from_millis(300)).is_err()
        });
    assert!(committed, "the revocation returned while the answer was being committed");
    returned.recv_timeout(Duration::from_secs(10)).expect("the revocation returns");
    assert!(!check(&set, &good, 200, None, 100), "the old signature counts after revocation");
}

#[test]
fn bad_sets_are_refused_whole() {
    let set = ApproverSet::default();
    let k = hex(key().public_key().as_ref());
    for bad in [
        json!({"approvers": []}),
        json!({"macDevice": "m", "approvers": [{"id": "a b", "publicKey": k}]}),
        json!({"macDevice": "m", "approvers": [{"id": "a", "publicKey": "04"}]}),
        json!({"macDevice": "m", "approvers": [{"id": "a", "publicKey": k}, {"id": "a", "publicKey": k}]}),
        json!({"macDevice": "m", "approvers": (0..=MAX_APPROVERS).map(|i| json!({"id": format!("p{i}"), "publicKey": k})).collect::<Vec<_>>()}),
    ] {
        assert!(set.set(&bad).is_err(), "{bad}");
    }
    assert_eq!(set.list()["approvers"], json!([]));
}

#[test]
fn a_paired_phones_peer_id_is_under_its_macs_prefix_only() {
    let one = peer_phone_id("mac-device-1", "iphone-1").unwrap();
    assert!(one.starts_with(&peer_phone_prefix("mac-device-1")));
    assert!(!one.starts_with(&peer_phone_prefix("mac-device-2")));
    assert_eq!(peer_phone_prefix("mac-device-1").len(), "phone:".len() + 12 + 1);
    assert!(valid_id(&one));
    // The same vector is in the app's ApprovalPayloadTests (`PeerApprovalPayload.peerID`).
    assert_eq!(one, "phone:db7667e21fe9:iphone-1");
    // An id that would not be valid there is none.
    assert_eq!(peer_phone_id("mac-device-1", &"x".repeat(128)), None);
}
