//! CMUX-572: the host serves a consent-gated session on a viewer's Touch ID
//! grant only when the viewer's registered Secure Enclave key signed this
//! host's fresh challenge for this session and scope. A forged, copied or
//! replayed grant is refused.

use base64::Engine as _;
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};
use serde_json::Value;

use super::*;

const HOST: &str = "6f1c2a7e-0b1d-4c55-9a63-2f1e7d9b8a10";
const VIEWER: &str = "0d4b9e21-77aa-4f0e-8c3b-5a6d1e2f3c40";
const OTHER: &str = "a1b2c3d4-0000-4000-8000-000000000001";
const ACCOUNT: &str = "user_2abc";
const SESSION: &str = "sess_1";
const NOW: u64 = 1_794_700_000;

/// A viewer's key, as its Secure Enclave holds it (software here).
struct ViewerKey {
    pair: EcdsaKeyPair,
    rng: SystemRandom,
}

impl ViewerKey {
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

    /// What the app does once Touch ID allows the signature.
    fn sign(&self, mut proof: Proof) -> Proof {
        let signature = self.pair.sign(&self.rng, proof.canonical().as_bytes()).unwrap();
        proof.signature = base64::engine::general_purpose::STANDARD.encode(signature.as_ref());
        proof
    }
}

fn registration(viewer: &str, scope: Scope, key: &ViewerKey) -> Registration {
    Registration { host: HOST.into(), viewer: viewer.into(), scope, key: key.public() }
}

/// A host book holding `VIEWER`'s grant for `scope` with `key`.
fn book_with(scope: Scope, key: &ViewerKey) -> GrantBook {
    let mut book = GrantBook { account: ACCOUNT.into(), grants: Vec::new() };
    register(&mut book, &registration(VIEWER, scope, key), VIEWER, HOST, NOW).unwrap();
    book
}

fn ticket(viewer: &str, scope: Scope) -> Ticket<'_> {
    Ticket { session: SESSION, viewer, scope }
}

fn unsigned(viewer: &str, scope: Scope, challenge: &str) -> Proof {
    Proof {
        v: PROOF_VERSION.into(),
        host: HOST.into(),
        viewer: viewer.into(),
        scope,
        session: SESSION.into(),
        challenge: challenge.into(),
        signature: String::new(),
    }
}

/// The host issues a challenge for the ticket, the viewer signs it, the host verifies.
fn serve(
    book: &GrantBook,
    ticket: &Ticket<'_>,
    sign: impl FnOnce(&str) -> Proof,
) -> Result<(), Refused> {
    let mut challenges = Challenges::default();
    let challenge = challenges.issue(ticket.session, ticket.viewer, NOW).unwrap();
    let proof = sign(&challenge);
    verify(book, &mut challenges, HOST, ticket, &proof, NOW + 2)
}

#[test]
fn a_registered_key_signing_the_hosts_challenge_is_served() {
    let key = ViewerKey::new();
    let book = book_with(Scope::View, &key);
    let served =
        serve(&book, &ticket(VIEWER, Scope::View), |c| key.sign(unsigned(VIEWER, Scope::View, c)));
    assert_eq!(served, Ok(()));
}

/// A forged grant: a proof signed by any key but the one the viewer registered.
#[test]
fn the_host_refuses_a_forged_grant() {
    let key = ViewerKey::new();
    let book = book_with(Scope::View, &key);
    let forger = ViewerKey::new();
    let refused = serve(&book, &ticket(VIEWER, Scope::View), |c| {
        forger.sign(unsigned(VIEWER, Scope::View, c))
    });
    assert_eq!(refused.unwrap_err().code, "grant.bad_signature");
    let unsigned_proof =
        serve(&book, &ticket(VIEWER, Scope::View), |c| unsigned(VIEWER, Scope::View, c));
    assert_eq!(unsigned_proof.unwrap_err().code, "grant.bad_signature");
}

/// A copied grant: another device presents the viewer's grant (or a proof
/// naming the viewer). The hub authenticated the other device, so it is refused,
/// and a proof of its own finds no grant.
#[test]
fn the_host_refuses_a_copied_grant() {
    let key = ViewerKey::new();
    let book = book_with(Scope::View, &key);
    let naming_the_viewer =
        serve(&book, &ticket(OTHER, Scope::View), |c| key.sign(unsigned(VIEWER, Scope::View, c)));
    assert_eq!(naming_the_viewer.unwrap_err().code, "grant.wrong_viewer");
    let own_key = ViewerKey::new();
    let as_itself = serve(&book, &ticket(OTHER, Scope::View), |c| {
        own_key.sign(unsigned(OTHER, Scope::View, c))
    });
    assert_eq!(as_itself.unwrap_err().code, "grant.none");
}

/// Only the viewer device itself may register its key, over the hub's authenticated channel.
#[test]
fn another_device_cannot_register_a_key_for_the_viewer() {
    let mut book = GrantBook { account: ACCOUNT.into(), grants: Vec::new() };
    let attacker = ViewerKey::new();
    let refused =
        register(&mut book, &registration(VIEWER, Scope::Control, &attacker), OTHER, HOST, NOW);
    assert_eq!(refused.unwrap_err().code, "grant.not_the_viewer");
    assert!(book.grants.is_empty());
    let wrong_host =
        Registration { host: OTHER.into(), ..registration(VIEWER, Scope::View, &attacker) };
    assert_eq!(
        register(&mut book, &wrong_host, VIEWER, HOST, NOW).unwrap_err().code,
        "grant.wrong_host"
    );
    let bad_key =
        Registration { key: "bm90LWEta2V5".into(), ..registration(VIEWER, Scope::View, &attacker) };
    assert_eq!(register(&mut book, &bad_key, VIEWER, HOST, NOW).unwrap_err().code, "grant.bad_key");
    let signed_out = &mut GrantBook::default();
    let refused =
        register(signed_out, &registration(VIEWER, Scope::View, &attacker), VIEWER, HOST, NOW);
    assert_eq!(refused.unwrap_err().code, "grant.signed_out");
}

/// A challenge answers once, for its own session and viewer, while fresh.
#[test]
fn the_host_refuses_a_replayed_or_stale_proof() {
    let key = ViewerKey::new();
    let book = book_with(Scope::View, &key);
    let mut challenges = Challenges::default();
    let challenge = challenges.issue(SESSION, VIEWER, NOW).unwrap();
    let proof = key.sign(unsigned(VIEWER, Scope::View, &challenge));
    let ticket = ticket(VIEWER, Scope::View);
    assert_eq!(verify(&book, &mut challenges, HOST, &ticket, &proof, NOW + 1), Ok(()));
    let replayed = verify(&book, &mut challenges, HOST, &ticket, &proof, NOW + 1);
    assert_eq!(replayed.unwrap_err().code, "grant.bad_challenge");

    let challenge = challenges.issue(SESSION, VIEWER, NOW).unwrap();
    let late = key.sign(unsigned(VIEWER, Scope::View, &challenge));
    let stale = verify(&book, &mut challenges, HOST, &ticket, &late, NOW + CHALLENGE_TTL_SECS + 1);
    assert_eq!(stale.unwrap_err().code, "grant.bad_challenge");

    let invented = key.sign(unsigned(VIEWER, Scope::View, "never-issued"));
    let refused = verify(&book, &mut challenges, HOST, &ticket, &invented, NOW + 1);
    assert_eq!(refused.unwrap_err().code, "grant.bad_challenge");

    let challenge = challenges.issue("sess_other", VIEWER, NOW).unwrap();
    let elsewhere =
        key.sign(Proof { session: SESSION.into(), ..unsigned(VIEWER, Scope::View, &challenge) });
    let refused = verify(&book, &mut challenges, HOST, &ticket, &elsewhere, NOW + 1);
    assert_eq!(refused.unwrap_err().code, "grant.bad_challenge");
}

/// The proof's host, session and scope are the ticket's.
#[test]
fn a_proof_for_another_host_session_or_scope_is_refused() {
    let key = ViewerKey::new();
    let book = book_with(Scope::Control, &key);
    let cases: [(&str, fn(Proof) -> Proof); 3] = [
        ("grant.wrong_host", |p| Proof { host: OTHER.into(), ..p }),
        ("grant.wrong_session", |p| Proof { session: "sess_2".into(), ..p }),
        ("grant.wrong_scope", |p| Proof { scope: Scope::View, ..p }),
    ];
    for (code, change) in cases {
        let refused = serve(&book, &ticket(VIEWER, Scope::Control), |c| {
            key.sign(change(unsigned(VIEWER, Scope::Control, c)))
        });
        assert_eq!(refused.unwrap_err().code, code);
    }
}

/// View and control are separate grants: view never admits control.
#[test]
fn a_view_grant_never_admits_control() {
    let key = ViewerKey::new();
    let view = book_with(Scope::View, &key);
    let refused = serve(&view, &ticket(VIEWER, Scope::Control), |c| {
        key.sign(unsigned(VIEWER, Scope::Control, c))
    });
    assert_eq!(refused.unwrap_err().code, "grant.none");
    let control = book_with(Scope::Control, &key);
    let served = serve(&control, &ticket(VIEWER, Scope::View), |c| {
        key.sign(unsigned(VIEWER, Scope::View, c))
    });
    assert_eq!(served, Ok(()), "control includes seeing the screen");
}

/// What ends a grant: revoking it, the host's sign-out or account change, the viewer leaving the account.
#[test]
fn a_grant_ends_on_revoke_sign_out_account_change_or_the_viewer_leaving() {
    let key = ViewerKey::new();
    let view = |book: &GrantBook| {
        serve(book, &ticket(VIEWER, Scope::View), |c| key.sign(unsigned(VIEWER, Scope::View, c)))
    };
    let mut book = book_with(Scope::View, &key);
    assert!(book.revoke(VIEWER, Some(Scope::View)));
    assert_eq!(view(&book).unwrap_err().code, "grant.none");

    let book = book_with(Scope::View, &key).for_account("");
    assert_eq!(view(&book).unwrap_err().code, "grant.none");
    let book = book_with(Scope::View, &key).for_account("user_other");
    assert_eq!(view(&book).unwrap_err().code, "grant.none");
    let book = book_with(Scope::View, &key).for_account(ACCOUNT);
    assert_eq!(view(&book), Ok(()));

    let mut book = book_with(Scope::View, &key);
    book.retain_devices(&[HOST, OTHER]);
    assert_eq!(view(&book).unwrap_err().code, "grant.none");
}

/// A new registration replaces the viewer's old key for that scope: the old key no longer signs.
#[test]
fn re_registering_replaces_the_old_key() {
    let old = ViewerKey::new();
    let mut book = book_with(Scope::View, &old);
    let new = ViewerKey::new();
    register(&mut book, &registration(VIEWER, Scope::View, &new), VIEWER, HOST, NOW).unwrap();
    assert_eq!(book.grants.len(), 1);
    let refused =
        serve(&book, &ticket(VIEWER, Scope::View), |c| old.sign(unsigned(VIEWER, Scope::View, c)));
    assert_eq!(refused.unwrap_err().code, "grant.bad_signature");
}

/// The app's canonical string is the same bytes (`viewer_grant_vectors.json`, read by both sides).
#[test]
fn canonical_matches_the_shared_vectors() {
    let vectors: Vec<Value> =
        serde_json::from_str(include_str!("viewer_grant_vectors.json")).unwrap();
    assert!(!vectors.is_empty());
    for vector in vectors {
        let proof: Proof = serde_json::from_value(vector["proof"].clone()).unwrap();
        assert_eq!(proof.canonical(), vector["canonical"].as_str().unwrap());
    }
}
