//! The host gate: a first proof registers its key only when that key signed it, the book is
//! kept per joined account in acpmux's home, and the person-line answers say why on a refusal.

use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::*;
use crate::viewer_grant::PROOF_VERSION;

const HOST: &str = "6f1c2a7e-0b1d-4c55-9a63-2f1e7d9b8a10";
const VIEWER: &str = "0d4b9e21-77aa-4f0e-8c3b-5a6d1e2f3c40";
const ACCOUNT: &str = "user_2abc";

struct Key {
    pair: EcdsaKeyPair,
    rng: SystemRandom,
}

impl Key {
    fn new() -> Self {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng)
            .unwrap();
        Self { pair, rng }
    }

    fn public(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.pair.public_key().as_ref())
    }

    fn proof(&self, session: &str, challenge: &str) -> Value {
        let mut proof = Proof {
            v: PROOF_VERSION.into(),
            host: HOST.into(),
            viewer: VIEWER.into(),
            scope: Scope::View,
            session: session.into(),
            challenge: challenge.into(),
            signature: String::new(),
        };
        let signature = self.pair.sign(&self.rng, proof.canonical().as_bytes()).unwrap();
        proof.signature = base64::engine::general_purpose::STANDARD.encode(signature.as_ref());
        serde_json::to_value(proof).unwrap()
    }

    fn registration(&self) -> Value {
        json!({"host": HOST, "viewer": VIEWER, "scope": "view", "key": self.public()})
    }
}

fn ticket(session: &str) -> Value {
    json!({"host": HOST, "session": session, "viewer": VIEWER, "scope": "view"})
}

fn with(mut base: Value, extra: Value) -> Value {
    for (key, value) in extra.as_object().unwrap() {
        base[key] = value.clone();
    }
    base
}

fn challenge_for(home: &Path, session: &str) -> String {
    let answer = challenge(home, Some(ACCOUNT), &ticket(session)).unwrap();
    answer["challenge"].as_str().unwrap().to_owned()
}

/// Touch ID once: the first proof carries its key's registration, later sessions need only a proof.
#[test]
fn a_first_proof_registers_and_later_sessions_need_only_a_proof() {
    let home = tempfile::tempdir().unwrap();
    let key = Key::new();
    let c = challenge_for(home.path(), "s1");
    assert_eq!(challenge(home.path(), Some(ACCOUNT), &ticket("s2")).unwrap()["granted"], false);
    let first = admit(
        home.path(),
        Some(ACCOUNT),
        &with(
            ticket("s1"),
            json!({"proof": key.proof("s1", &c), "registration": key.registration()}),
        ),
    )
    .unwrap();
    assert_eq!(first, json!({"admitted": true, "registered": true}));
    assert_eq!(challenge(home.path(), Some(ACCOUNT), &ticket("s3")).unwrap()["granted"], true);

    let c = challenge_for(home.path(), "s4");
    let later = admit(
        home.path(),
        Some(ACCOUNT),
        &with(ticket("s4"), json!({"proof": key.proof("s4", &c)})),
    )
    .unwrap();
    assert_eq!(later, json!({"admitted": true, "registered": false}));
}

/// A registration whose key did not sign the proof (no Touch ID on that key) keeps nothing.
#[test]
fn a_registration_the_key_did_not_sign_keeps_nothing() {
    let home = tempfile::tempdir().unwrap();
    let registered = Key::new();
    let signer = Key::new();
    let c = challenge_for(home.path(), "s1");
    let refused = admit(
        home.path(),
        Some(ACCOUNT),
        &with(
            ticket("s1"),
            json!({"proof": signer.proof("s1", &c), "registration": registered.registration()}),
        ),
    )
    .unwrap_err();
    assert_eq!(refused.code, "grant.bad_signature");
    assert!(load(home.path(), Some(ACCOUNT)).grants.is_empty());
}

/// The book belongs to the joined account: another account or a signed-out machine reads none.
#[test]
fn the_book_holds_only_for_the_joined_account() {
    let home = tempfile::tempdir().unwrap();
    let key = Key::new();
    let c = challenge_for(home.path(), "s1");
    admit(
        home.path(),
        Some(ACCOUNT),
        &with(
            ticket("s1"),
            json!({"proof": key.proof("s1", &c), "registration": key.registration()}),
        ),
    )
    .unwrap();
    assert_eq!(load(home.path(), Some(ACCOUNT)).grants.len(), 1);
    assert!(load(home.path(), Some("user_other")).grants.is_empty());
    assert!(load(home.path(), None).grants.is_empty());
    assert_eq!(challenge(home.path(), None, &ticket("s2")).unwrap_err().code, "grant.signed_out");
}

#[test]
fn revoke_deletes_the_key_here() {
    let home = tempfile::tempdir().unwrap();
    let key = Key::new();
    let c = challenge_for(home.path(), "s1");
    admit(
        home.path(),
        Some(ACCOUNT),
        &with(
            ticket("s1"),
            json!({"proof": key.proof("s1", &c), "registration": key.registration()}),
        ),
    )
    .unwrap();
    assert_eq!(
        revoke(home.path(), Some(ACCOUNT), &json!({"viewer": VIEWER})).unwrap()["revoked"],
        true
    );
    let c = challenge_for(home.path(), "s2");
    let refused = admit(
        home.path(),
        Some(ACCOUNT),
        &with(ticket("s2"), json!({"proof": key.proof("s2", &c)})),
    )
    .unwrap_err();
    assert_eq!(refused.code, "grant.none");
}

#[test]
fn a_call_without_the_ticket_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let refused = challenge(home.path(), Some(ACCOUNT), &json!({"host": HOST})).unwrap_err();
    assert_eq!(refused.code, "grant.bad_request");
    let refused =
        challenge(home.path(), Some(ACCOUNT), &with(ticket("s"), json!({"scope": "admin"})))
            .unwrap_err();
    assert_eq!(refused.code, "grant.bad_request");
}

/// End to end over the person-line calls the Mac Screen host makes for a ticket its consent refused
/// (`_acpmux/viewer_grant_challenge`, then `_admit` with the viewer's `grant-proof` frame fields): a
/// forged grant (another key, with or without a registration) and a copied one (a genuine proof
/// replayed, moved to another session or presented on another viewer's ticket) are never admitted,
/// and none of them changes the book. The genuine viewer is admitted after each refusal.
#[test]
fn the_host_refuses_a_forged_or_copied_grant_end_to_end() {
    let home = tempfile::tempdir().unwrap();
    let genuine = Key::new();
    let forger = Key::new();
    let c = challenge_for(home.path(), "e2e-1");
    let frame =
        json!({"proof": genuine.proof("e2e-1", &c), "registration": genuine.registration()});
    assert_eq!(
        admit(home.path(), Some(ACCOUNT), &with(ticket("e2e-1"), frame.clone())).unwrap()["admitted"],
        true
    );
    let book = load(home.path(), Some(ACCOUNT));
    let refused = |params: Value| admit(home.path(), Some(ACCOUNT), &params).unwrap_err().code;

    // Forged: another key signs; with its own registration it cannot replace the registered key.
    let c = challenge_for(home.path(), "e2e-2");
    assert_eq!(
        refused(with(ticket("e2e-2"), json!({"proof": forger.proof("e2e-2", &c)}))),
        "grant.bad_signature"
    );
    let c = challenge_for(home.path(), "e2e-2");
    let forged =
        json!({"proof": forger.proof("e2e-2", &c), "registration": genuine.registration()});
    assert_eq!(refused(with(ticket("e2e-2"), forged)), "grant.bad_signature");

    // Copied: the s1 frame again (its challenge is spent), in another session, on another viewer.
    assert_eq!(refused(with(ticket("e2e-1"), frame.clone())), "grant.bad_challenge");
    challenge_for(home.path(), "e2e-3");
    assert_eq!(refused(with(ticket("e2e-3"), frame.clone())), "grant.wrong_session");
    // On another device's ticket: with the registration it names, and its proof alone.
    let other = json!({"host": HOST, "session": "e2e-1", "viewer": "9e1d0c4b-1111-4a2b-8c3d-000000000000", "scope": "view"});
    assert_eq!(refused(with(other.clone(), frame.clone())), "grant.not_the_viewer");
    assert_eq!(refused(with(other, json!({"proof": frame["proof"]}))), "grant.wrong_viewer");
    assert_eq!(load(home.path(), Some(ACCOUNT)).grants, book.grants);

    let c = challenge_for(home.path(), "e2e-4");
    let later = admit(
        home.path(),
        Some(ACCOUNT),
        &with(ticket("e2e-4"), json!({"proof": genuine.proof("e2e-4", &c)})),
    )
    .unwrap();
    assert_eq!(later["admitted"], true);
}
