use super::*;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};

const KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const OTHER_KEY: &str = "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd";

fn keyed() -> PersonGate {
    let gate = PersonGate::default();
    gate.install_spawn_key(KEY).unwrap();
    gate
}

fn nonce_of(challenge: &Value) -> String {
    challenge["nonce"].as_str().unwrap().to_owned()
}

fn proved(gate: &PersonGate, key: &str, session: &str, policy: &str, nonce: &str) -> Value {
    let proof = policy_proof(key, gate.instance(), session, policy, nonce).unwrap();
    json!({NONCE_FIELD: nonce, PROOF_FIELD: proof})
}

#[test]
fn the_wire_payload_is_fixed() {
    // HMAC-SHA256(KEY, "acpmux-person-policy-v1" 0 "inst" 0 "s1" 0 "approve-edits" 0 "n1"),
    // computed apart from this code: the app makes the same bytes.
    assert_eq!(
        policy_proof(KEY, "inst", "s1", "approve-edits", "n1").unwrap(),
        "fdd2f4135b8eb902f4adadf82d2d3664a8265b1957af5fab52fb89f17e7ca527"
    );
    assert_ne!(
        policy_proof(KEY, "inst", "s1", "approve-edits", "n1"),
        policy_proof(KEY, "inst", "s1\0approve-edits", "", "n1"),
        "parts are NUL separated"
    );
    assert!(policy_proof("short", "inst", "s1", "approve-edits", "n1").is_none());
}

#[test]
fn a_person_key_proof_counts_once_for_its_own_challenge() {
    let gate = keyed();
    let challenge = gate.policy_challenge("s1");
    assert_eq!(challenge["sessionId"], "s1");
    assert_eq!(challenge["personInstance"], gate.instance());
    let nonce = nonce_of(&challenge);
    let meta = proved(&gate, KEY, "s1", "approve-edits", &nonce);
    assert!(gate.take_policy_grant("s1", "approve-edits", &meta));
    assert!(!gate.take_policy_grant("s1", "approve-edits", &meta), "a replay counts for nothing");
}

#[test]
fn a_forged_or_misbound_proof_counts_for_nothing_and_leaves_the_challenge_open() {
    let gate = keyed();
    let nonce = nonce_of(&gate.policy_challenge("s1"));
    let refused = [
        // Another key: the forwarding daemon's own, or one a peer-token client chose.
        proved(&gate, OTHER_KEY, "s1", "approve-edits", &nonce),
        // Made for another policy than the one sent.
        proved(&gate, KEY, "s1", "approve-reads", &nonce),
        // Made for another chat.
        proved(&gate, KEY, "s2", "approve-edits", &nonce),
        // Another daemon run.
        json!({NONCE_FIELD: nonce, PROOF_FIELD:
            policy_proof(KEY, "another-run", "s1", "approve-edits", &nonce).unwrap()}),
        // A relayed allow's decision proof over the same ids.
        json!({NONCE_FIELD: nonce, PROOF_FIELD:
            super::super::decision_proof(KEY, gate.instance(), "s1", "approve-edits", "allow", &nonce).unwrap()}),
        // A proof with no nonce, or garbage.
        json!({PROOF_FIELD: policy_proof(KEY, gate.instance(), "s1", "approve-edits", "").unwrap()}),
        json!({NONCE_FIELD: nonce, PROOF_FIELD: "00"}),
        json!({NONCE_FIELD: nonce}),
    ];
    for meta in refused {
        assert!(!gate.take_policy_grant("s1", "approve-edits", &meta), "{meta}");
    }
    // None of them spent the challenge: the person's own proof still counts.
    let meta = proved(&gate, KEY, "s1", "approve-edits", &nonce);
    assert!(gate.take_policy_grant("s1", "approve-edits", &meta));
}

#[test]
fn a_nonce_this_run_never_issued_or_issued_for_another_chat_counts_for_nothing() {
    let gate = keyed();
    let made_up = "7a".repeat(32);
    assert!(!gate.take_policy_grant(
        "s1",
        "approve-all",
        &proved(&gate, KEY, "s1", "approve-all", &made_up)
    ));
    // A challenge issued for s2, proved for s1.
    let nonce = nonce_of(&gate.policy_challenge("s2"));
    assert!(!gate.take_policy_grant(
        "s1",
        "approve-all",
        &proved(&gate, KEY, "s1", "approve-all", &nonce)
    ));
    // It is still open for s2.
    assert!(gate.take_policy_grant(
        "s2",
        "approve-all",
        &proved(&gate, KEY, "s2", "approve-all", &nonce)
    ));
}

#[test]
fn a_daemon_without_a_person_key_counts_no_person_key_proof() {
    let gate = PersonGate::default();
    let nonce = nonce_of(&gate.policy_challenge("s1"));
    assert!(!gate.take_policy_grant(
        "s1",
        "approve-all",
        &proved(&gate, KEY, "s1", "approve-all", &nonce)
    ));
}

#[test]
fn an_expired_challenge_counts_for_nothing() {
    let gate = keyed();
    let nonce = nonce_of(&gate.policy_challenge("s1"));
    for c in gate.open_policy_challenges().iter_mut() {
        c.at = Instant::now().checked_sub(CHALLENGE_TTL + Duration::from_secs(1)).unwrap();
    }
    assert!(!gate.take_policy_grant(
        "s1",
        "approve-all",
        &proved(&gate, KEY, "s1", "approve-all", &nonce)
    ));
}

#[test]
fn a_flood_of_challenges_keeps_at_most_the_limit_open() {
    let gate = keyed();
    let first = nonce_of(&gate.policy_challenge("s1"));
    for _ in 0..CHALLENGE_LIMIT {
        gate.policy_challenge("s1");
    }
    assert_eq!(gate.open_policy_challenges().len(), CHALLENGE_LIMIT);
    // The oldest was dropped: its proof asks again.
    assert!(!gate.take_policy_grant(
        "s1",
        "approve-all",
        &proved(&gate, KEY, "s1", "approve-all", &first)
    ));
}

fn mac_key() -> EcdsaKeyPair {
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap()
}

fn enroll(gate: &PersonGate, k: &EcdsaKeyPair, tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("policy-grant-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(crate::hub::mac_approvers::FILE);
    let key = crate::hub::approvers::hex(k.public_key().as_ref());
    let file = json!({"macs": [{"id": "mac-1", "publicKey": key, "name": "Mac"}]});
    crate::config::write_atomic(&path, file.to_string().as_bytes()).unwrap();
    gate.macs.open(path.clone());
    path
}

fn mac_signed(k: &EcdsaKeyPair, message: &[u8], nonce: &str) -> Value {
    let signature = k.sign(&ring::rand::SystemRandom::new(), message).unwrap();
    json!({NONCE_FIELD: nonce, APPROVER_FIELD: {
        "approver": "mac-1", "signature": crate::hub::approvers::hex(signature.as_ref()),
    }})
}

#[test]
fn an_enrolled_macs_signature_counts_once_and_nothing_else_does() {
    use crate::hub::mac_approvers::policy_message;
    let gate = PersonGate::default();
    let k = mac_key();
    let path = enroll(&gate, &k, "mac");
    let nonce = nonce_of(&gate.policy_challenge("s1"));
    let instance = gate.instance().to_owned();
    let unenrolled = mac_key();
    let refused = [
        // A key nobody enrolled here.
        mac_signed(
            &unenrolled,
            &policy_message(&instance, "mac-1", "s1", "approve-all", &nonce),
            &nonce,
        ),
        // Another policy, chat, run or Mac id in the signed bytes.
        mac_signed(&k, &policy_message(&instance, "mac-1", "s1", "approve-edits", &nonce), &nonce),
        mac_signed(&k, &policy_message(&instance, "mac-1", "s2", "approve-all", &nonce), &nonce),
        mac_signed(
            &k,
            &policy_message("another-run", "mac-1", "s1", "approve-all", &nonce),
            &nonce,
        ),
        mac_signed(&k, &policy_message(&instance, "mac-2", "s1", "approve-all", &nonce), &nonce),
        // A one-time allow's decision signature over the same ids.
        mac_signed(
            &k,
            &crate::hub::mac_approvers::message(&crate::hub::mac_approvers::Parts {
                instance: &instance,
                mac: "mac-1",
                session: "s1",
                permission: "approve-all",
                tool_call: "",
                option: "approve-all",
                nonce: &nonce,
                expires_at: 0,
                answers: "",
            }),
            &nonce,
        ),
    ];
    for meta in refused {
        assert!(!gate.take_policy_grant("s1", "approve-all", &meta), "{meta}");
    }
    let good =
        mac_signed(&k, &policy_message(&instance, "mac-1", "s1", "approve-all", &nonce), &nonce);
    assert!(gate.take_policy_grant("s1", "approve-all", &good));
    assert!(!gate.take_policy_grant("s1", "approve-all", &good), "a replay counts for nothing");

    // Removing the Mac from the file stops its signatures.
    let nonce = nonce_of(&gate.policy_challenge("s1"));
    crate::config::write_atomic(&path, json!({"macs": []}).to_string().as_bytes()).unwrap();
    let after =
        mac_signed(&k, &policy_message(&instance, "mac-1", "s1", "approve-all", &nonce), &nonce);
    assert!(!gate.take_policy_grant("s1", "approve-all", &after));
}
