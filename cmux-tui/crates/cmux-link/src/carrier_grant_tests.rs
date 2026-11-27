use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use ring::signature::{Ed25519KeyPair, KeyPair as _};
use serde_json::{Value, json};

use super::*;

const ISSUER: &str = "cmux:cloud:test";
const MACHINE: &str = "vm_00000000000000000001";
const NOW: u64 = 1_800_000_000;
const TEAM: &str = "team_00000000000000000001";
const ATTEMPT: [u8; 32] = [1; 32];

/// A freshly generated signing key; no key material is checked in.
struct Signer {
    kid: &'static str,
    pair: Ed25519KeyPair,
}

impl Signer {
    fn generate(kid: &'static str) -> Self {
        let rng = ring::rand::SystemRandom::new();
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).unwrap();
        Self { kid, pair: Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap() }
    }

    fn keyset(&self) -> Keyset {
        let public: [u8; 32] = self.pair.public_key().as_ref().try_into().unwrap();
        Keyset {
            version: "0123456789abcdef".into(),
            keys: [(self.kid.to_string(), public)].into_iter().collect(),
        }
    }

    fn sign(&self, typ: &str, claims: &Value) -> String {
        let header = json!({"alg": "EdDSA", "kid": self.kid, "typ": typ});
        let message = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap()),
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap())
        );
        let signature = self.pair.sign(message.as_bytes());
        format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref()))
    }
}

fn claims(noise_key: &[u8; 32]) -> Value {
    json!({
        "iss": ISSUER,
        "aud": MACHINE,
        "team": TEAM,
        "sub": "user_00000000000000000001",
        "svc": ["mux-control", "workspace-rpc"],
        "nk": noise_key_digest(noise_key),
        "jti": URL_SAFE_NO_PAD.encode([7_u8; 16]),
        "iat": NOW - 10,
        "exp": NOW + 200,
    })
}

fn verifier(signer: &Signer) -> (CarrierGrantVerifier, Arc<AtomicU64>) {
    let now = Arc::new(AtomicU64::new(NOW));
    let clock = now.clone();
    let verifier = CarrierGrantVerifier::new(
        ISSUER,
        MACHINE,
        TEAM,
        signer.keyset(),
        move || Some(clock.load(Ordering::SeqCst)),
        64,
    )
    .unwrap();
    (verifier, now)
}

#[test]
fn a_valid_grant_admits_with_its_signed_services() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let grant = verifier.verify(&signer.sign(GRANT_TYP, &claims(&key)), &key, ATTEMPT).unwrap();
    assert_eq!(grant.subject, "user_00000000000000000001");
    assert_eq!(grant.team, "team_00000000000000000001");
    assert_eq!(grant.services, ["mux-control", "workspace-rpc"]);
    assert_eq!(grant.expires_at, NOW + 200);
    assert_eq!(grant.vm_kind, None);
    assert!(!grant.owner(), "a grant without vmk is never the owner's");
    assert_eq!((grant.chats, grant.name), (None, None));
}

#[test]
fn chats_and_name_are_read_as_signed() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let mut c = claims(&key);
    c["vmk"] = json!("team");
    c["chats"] = json!(["ses_a", "0f8e2c1a-7b0d-4c55-9a43-2b1d7d7f5e10"]);
    c["name"] = json!("Ana Lí");
    let grant = verifier.verify(&signer.sign(GRANT_TYP, &c), &key, ATTEMPT).unwrap();
    assert_eq!(
        grant.chats.as_deref(),
        Some(&["ses_a".to_owned(), "0f8e2c1a-7b0d-4c55-9a43-2b1d7d7f5e10".to_owned()][..])
    );
    assert_eq!(grant.name.as_deref(), Some("Ana Lí"));
}

/// #38420 review F1: a grant at the chats and name limits (the most chats, each
/// 128 bytes, and the longest name in 4-byte characters) fits the token
/// cap and is admitted; the old 4096-byte cap refused it as `token_size`.
#[test]
fn a_grant_at_the_chats_and_name_limits_is_admitted() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let mut c = claims(&key);
    c["vmk"] = json!("team");
    c["chats"] = json!((0..MAX_GRANT_CHATS).map(|i| format!("{i:0>128}")).collect::<Vec<_>>());
    c["name"] = json!("\u{1F600}".repeat(MAX_NAME_CHARS));
    let token = signer.sign(GRANT_TYP, &c);
    assert!(token.len() > 4096 && token.len() <= MAX_GRANT_BYTES, "{}", token.len());
    let grant = verifier.verify(&token, &key, ATTEMPT).unwrap();
    assert_eq!(grant.chats.map(|chats| chats.len()), Some(MAX_GRANT_CHATS));
}

#[test]
fn a_malformed_chats_or_name_claim_is_refused_and_spends_nothing() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let too_many: Vec<String> = (0..=MAX_GRANT_CHATS).map(|i| format!("ses_{i}")).collect();
    let cases: Vec<(&str, Value, &str)> = vec![
        ("chats", json!([]), "chats"),
        ("chats", json!(too_many), "chats"),
        ("chats", json!(["ses a"]), "chats"),
        ("chats", json!(["ses:a"]), "chats"),
        ("chats", json!(["x".repeat(129)]), "chats"),
        ("chats", json!(["ses_a", ""]), "chats"),
        ("chats", json!(null), "claims_malformed"),
        ("chats", json!("ses_a"), "claims_malformed"),
        ("chats", json!([1]), "claims_malformed"),
        ("name", json!(""), "name"),
        ("name", json!("   "), "name"),
        ("name", json!("Ana\nBob"), "name"),
        ("name", json!("Ana\u{202e}"), "name"),
        ("name", json!("x".repeat(MAX_NAME_CHARS + 1)), "name"),
        ("name", json!(null), "claims_malformed"),
        ("name", json!(7), "claims_malformed"),
    ];
    for (field, value, reason) in cases {
        let mut c = claims(&key);
        c[field] = value.clone();
        let refusal = verifier.verify(&signer.sign(GRANT_TYP, &c), &key, ATTEMPT).unwrap_err();
        assert_eq!(refusal.reason, reason, "{field} {value}");
    }
    // The longest name and the most chats are fine, and nothing above spent the jti.
    let mut c = claims(&key);
    c["chats"] = json!((0..MAX_GRANT_CHATS).map(|i| format!("ses_{i}")).collect::<Vec<_>>());
    c["name"] = json!("é".repeat(MAX_NAME_CHARS));
    verifier.verify(&signer.sign(GRANT_TYP, &c), &key, ATTEMPT).unwrap();
}

#[test]
fn vmk_owner_marks_the_owner_and_any_other_value_does_not() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    for (jti, vmk, owner) in [(1_u8, "owner", true), (2, "team", false)] {
        let key = [jti; 32];
        let mut c = claims(&key);
        c["vmk"] = json!(vmk);
        c["jti"] = json!(URL_SAFE_NO_PAD.encode([jti; 16]));
        let grant = verifier.verify(&signer.sign(GRANT_TYP, &c), &key, ATTEMPT).unwrap();
        assert_eq!(grant.owner(), owner, "{vmk}");
    }
    // A null or unknown role is malformed, never a non-owner grant.
    for vmk in [json!(null), json!("root"), json!(true)] {
        let key = [3_u8; 32];
        let mut c = claims(&key);
        c["vmk"] = vmk.clone();
        let refusal = verifier.verify(&signer.sign(GRANT_TYP, &c), &key, ATTEMPT).unwrap_err();
        assert_eq!(refusal.reason, "claims_malformed", "{vmk}");
    }
}

#[test]
fn every_wrong_claim_is_refused_and_spends_nothing() {
    let signer = Signer::generate("k1");
    let key = [3_u8; 32];
    let cases: Vec<(&str, Value, &str)> = vec![
        ("iss", json!("cmux:cloud:other"), "issuer"),
        ("aud", json!("vm_00000000000000000002"), "audience"),
        ("team", json!(""), "team"),
        ("team", json!("team_00000000000000000002"), "team"),
        ("sub", json!("user:with:colons"), "subject"),
        ("nk", json!(noise_key_digest(&[4; 32])), "noise_key"),
        ("iat", json!(0), "claims_range"),
        ("iat", json!(NOW + 5), "iat_in_future"),
        ("exp", json!(NOW - 10), "lifetime"),
        ("exp", json!(NOW + 291), "lifetime"),
        ("exp", json!(NOW - 1), "token_expired"),
        ("jti", json!("short"), "jti"),
        ("svc", json!([]), "services"),
        ("svc", json!(["bad name"]), "services"),
    ];
    let (verifier, _) = verifier(&signer);
    for (field, value, reason) in cases {
        let mut c = claims(&key);
        c[field] = value;
        let refusal = verifier.verify(&signer.sign(GRANT_TYP, &c), &key, ATTEMPT).unwrap_err();
        assert_eq!(refusal.reason, reason, "{field}");
    }
    // An unknown claim (a link token's `network`, say) is malformed.
    let mut c = claims(&key);
    c["epoch"] = json!(1);
    let refusal = verifier.verify(&signer.sign(GRANT_TYP, &c), &key, ATTEMPT).unwrap_err();
    assert_eq!(refusal.reason, "claims_malformed");
    // None of the refusals spent the jti.
    verifier.verify(&signer.sign(GRANT_TYP, &claims(&key)), &key, ATTEMPT).unwrap();
}

#[test]
fn the_grant_must_name_the_handshake_key() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let token = signer.sign(GRANT_TYP, &claims(&[3; 32]));
    let refusal = verifier.verify(&token, &[4; 32], ATTEMPT).unwrap_err();
    assert_eq!(refusal.reason, "noise_key");
}

#[test]
fn an_expired_grant_is_refused() {
    let signer = Signer::generate("k1");
    let (verifier, now) = verifier(&signer);
    let key = [3_u8; 32];
    let token = signer.sign(GRANT_TYP, &claims(&key));
    now.store(NOW + 200, Ordering::SeqCst);
    let refusal = verifier.verify(&token, &key, ATTEMPT).unwrap_err();
    assert_eq!(refusal.kind, TokenRefused::Expired);
}

#[test]
fn a_spent_jti_is_refused_outside_its_own_link_group_and_lane_count() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let token = signer.sign(GRANT_TYP, &claims(&key));
    verifier.verify(&token, &key, ATTEMPT).unwrap();
    // The other physical links of the same new session present it again,
    // up to one per lane.
    for _ in 1..MAX_PRESENTATIONS {
        verifier.verify(&token, &key, ATTEMPT).unwrap();
    }
    assert_eq!(verifier.verify(&token, &key, ATTEMPT).unwrap_err().kind, TokenRefused::Replayed);
    // A new link group (another session, generation or attempt) is a replay.
    let refusal = verifier.verify(&token, &key, [2; 32]).unwrap_err();
    assert_eq!(refusal.kind, TokenRefused::Replayed);
    // A different grant with the same jti, bound to another key, too.
    let other = [5_u8; 32];
    let refusal =
        verifier.verify(&signer.sign(GRANT_TYP, &claims(&other)), &other, ATTEMPT).unwrap_err();
    assert_eq!(refusal.kind, TokenRefused::Replayed);
}

#[test]
fn a_replaced_keyset_keeps_spent_grants_spent() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let token = signer.sign(GRANT_TYP, &claims(&key));
    verifier.verify(&token, &key, ATTEMPT).unwrap();
    verifier.replace_keys(signer.keyset()).unwrap();
    assert_eq!(verifier.verify(&token, &key, [2; 32]).unwrap_err().kind, TokenRefused::Replayed);
}

#[test]
fn an_unknown_kid_is_refused_as_unknown_key() {
    let signer = Signer::generate("k1");
    let stranger = Signer::generate("k2");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let refusal =
        verifier.verify(&stranger.sign(GRANT_TYP, &claims(&key)), &key, ATTEMPT).unwrap_err();
    assert_eq!(refusal.kind, TokenRefused::UnknownKey);
    assert_eq!(refusal.reason, "unknown_kid");
}

#[test]
fn a_grant_signed_by_another_key_under_a_known_kid_is_refused() {
    let signer = Signer::generate("k1");
    let forger = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let refusal =
        verifier.verify(&forger.sign(GRANT_TYP, &claims(&key)), &key, ATTEMPT).unwrap_err();
    assert_eq!(refusal.reason, "signature");
}

#[test]
fn a_wrong_typ_is_refused() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    for typ in ["JWT", "cmux-link+jwt", "cmux-native-link-v2+jwt"] {
        let refusal = verifier.verify(&signer.sign(typ, &claims(&key)), &key, ATTEMPT).unwrap_err();
        assert_eq!(refusal.reason, "header_typ", "{typ}");
    }
}

/// A Native link token, signed by the same keyset, is never a grant: its
/// `typ` differs, and even re-typed its claims are not a grant's.
#[test]
fn a_native_link_token_is_not_a_grant() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let link_claims = json!({
        "iss": ISSUER,
        "aud": MACHINE,
        "sub": "inst_00000000000000000001",
        "svc": ["daemon"],
        "epoch": 1,
        "iat": NOW - 10,
        "exp": NOW + 200,
        "jti": URL_SAFE_NO_PAD.encode([8_u8; 16]),
        "team": TEAM,
        "network": {},
    });
    let refusal =
        verifier.verify(&signer.sign("cmux-link+jwt", &link_claims), &key, ATTEMPT).unwrap_err();
    assert_eq!(refusal.reason, "header_typ");
    let refusal =
        verifier.verify(&signer.sign(GRANT_TYP, &link_claims), &key, ATTEMPT).unwrap_err();
    assert_eq!(refusal.reason, "claims_malformed");
}

#[test]
fn malformed_tokens_are_refused() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let token = signer.sign(GRANT_TYP, &claims(&key));
    for bad in ["", "a.b", "a.b.c.d", &format!("{token}="), &"a".repeat(MAX_GRANT_BYTES + 1)] {
        assert!(verifier.verify(bad, &key, ATTEMPT).is_err(), "{bad:.16}");
    }
}

#[test]
fn replay_capacity_never_evicts_a_live_grant() {
    let signer = Signer::generate("k1");
    let now = Arc::new(AtomicU64::new(NOW));
    let clock = now.clone();
    let verifier = CarrierGrantVerifier::new(
        ISSUER,
        MACHINE,
        TEAM,
        signer.keyset(),
        move || Some(clock.load(Ordering::SeqCst)),
        1,
    )
    .unwrap();
    let key = [3_u8; 32];
    let grant = |jti: u8| {
        let mut c = claims(&key);
        c["jti"] = json!(URL_SAFE_NO_PAD.encode([jti; 16]));
        signer.sign(GRANT_TYP, &c)
    };
    verifier.verify(&grant(1), &key, ATTEMPT).unwrap();
    assert_eq!(
        verifier.verify(&grant(2), &key, ATTEMPT).unwrap_err().kind,
        TokenRefused::ReplayCapacity
    );
    // Once the first grant expires its slot frees, but it stays unusable.
    now.store(NOW + 200, Ordering::SeqCst);
    assert!(verifier.verify(&grant(1), &key, ATTEMPT).is_err());
}

/// next-review BLOCK at ee143b79: a spent grant whose record was dropped at
/// expiry came back when the clock was stepped backwards.
#[test]
fn a_clock_stepped_back_revives_no_spent_grant() {
    let signer = Signer::generate("k1");
    let (verifier, now) = verifier(&signer);
    let key = [3_u8; 32];
    let first = signer.sign(GRANT_TYP, &claims(&key));
    verifier.verify(&first, &key, ATTEMPT).unwrap();
    // Past the first grant's exp, another grant's admission drops its record.
    now.store(NOW + 200, Ordering::SeqCst);
    let mut later = claims(&key);
    later["jti"] = json!(URL_SAFE_NO_PAD.encode([8_u8; 16]));
    later["iat"] = json!(NOW + 150);
    later["exp"] = json!(NOW + 400);
    verifier.verify(&signer.sign(GRANT_TYP, &later), &key, [2; 32]).unwrap();
    // The clock steps back to before that exp: the first grant stays spent.
    now.store(NOW, Ordering::SeqCst);
    let refusal = verifier.verify(&first, &key, [3; 32]).unwrap_err();
    assert_eq!(refusal.kind, TokenRefused::Expired);
    // So does a grant that is new but expired by the latest time seen.
    let mut fresh = claims(&key);
    fresh["jti"] = json!(URL_SAFE_NO_PAD.encode([9_u8; 16]));
    assert_eq!(
        verifier.verify(&signer.sign(GRANT_TYP, &fresh), &key, [4; 32]).unwrap_err().kind,
        TokenRefused::Expired
    );
}

#[test]
fn a_sealed_link_group_admits_no_further_link() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let token = signer.sign(GRANT_TYP, &claims(&key));
    verifier.verify(&token, &key, ATTEMPT).unwrap();
    // Another group's seal changes nothing.
    verifier.seal([2; 32]);
    verifier.verify(&token, &key, ATTEMPT).unwrap();
    verifier.seal(ATTEMPT);
    assert_eq!(verifier.verify(&token, &key, ATTEMPT).unwrap_err().kind, TokenRefused::Replayed);
}

#[test]
fn construction_refuses_an_empty_issuer_machine_or_team() {
    let signer = Signer::generate("k1");
    assert!(CarrierGrantVerifier::with_system_clock("", MACHINE, TEAM, signer.keyset()).is_err());
    assert!(CarrierGrantVerifier::with_system_clock(ISSUER, "", TEAM, signer.keyset()).is_err());
    assert!(CarrierGrantVerifier::with_system_clock(ISSUER, MACHINE, "", signer.keyset()).is_err());
}

/// The caller's own refusal (`verify_with`) comes before the `jti` is
/// spent: the same grant, accepted later from another link group, is
/// admitted once and then replayed.
#[test]
fn a_grant_the_caller_refuses_spends_nothing() {
    let signer = Signer::generate("k1");
    let (verifier, _) = verifier(&signer);
    let key = [3_u8; 32];
    let token = signer.sign(GRANT_TYP, &claims(&key));
    let refusal = verifier.verify_with(&token, &key, ATTEMPT, |_| false).unwrap_err();
    assert_eq!((refusal.kind, refusal.reason), (TokenRefused::Invalid, "no_known_service"));
    let other = [2_u8; 32];
    assert!(verifier.verify_with(&token, &key, other, |_| true).is_ok());
    assert_eq!(verifier.verify(&token, &key, ATTEMPT).unwrap_err().kind, TokenRefused::Replayed);
}
