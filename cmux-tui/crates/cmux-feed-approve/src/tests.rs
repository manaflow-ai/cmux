//! Pins the Mac's Swift behaviour (`FeedApproveProofCheck`,
//! `FeedApproveShownText`, `FeedApproveProofMessage`) as it was moved.

use super::*;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use p256::ecdsa::SigningKey;
use p256::ecdsa::signature::Signer as _;
use serde_json::json;

const NOW: f64 = 1_800_000_000_000.0;

fn signing_key() -> SigningKey {
    SigningKey::from_slice(&[7u8; 32]).expect("a valid scalar")
}

fn jwk(key: &SigningKey) -> Value {
    let point = key.verifying_key().to_encoded_point(false);
    json!({
        "kty": "EC", "crv": "P-256",
        "x": URL_SAFE_NO_PAD.encode(point.x().expect("x")),
        "y": URL_SAFE_NO_PAD.encode(point.y().expect("y")),
    })
}

fn context() -> Context {
    Context { environment: "production".into(), user: "user-1".into(), mac_install: "mac-1".into() }
}

fn presence(entry: Value) -> HashMap<String, Key> {
    keys(&json!({ "keys": [entry] }))
}

fn good_entry() -> Value {
    json!({
        "install": "phone-1", "platform": "ios", "jwk": jwk(&signing_key()),
        "attested": true, "usable_from": NOW - 1000.0, "revoked_at": null,
        "install_active": true,
    })
}

fn signed(ts: i64, scope: Option<&str>, item: &str, shown: &str) -> Decision {
    let message = ProofMessage {
        environment: "production".into(),
        user: "user-1".into(),
        phone_install: "phone-1".into(),
        mac_install: "mac-1".into(),
        item: item.into(),
        shown_sha256: shown.into(),
        decision: "allow".into(),
        scope: scope.unwrap_or("once").into(),
        timestamp_ms: ts,
    };
    let signature: Signature = signing_key().sign(&message.bytes());
    Decision {
        outcome: "allow".into(),
        scope: scope.map(str::to_owned),
        proof: Some(Proof {
            install: "phone-1".into(),
            timestamp_ms: ts,
            signature: URL_SAFE_NO_PAD.encode(signature.to_bytes()),
        }),
    }
}

fn ts(offset_ms: f64) -> i64 {
    (NOW + offset_ms) as i64
}

fn run(decision: &Decision, keys: &HashMap<String, Key>) -> Result<(), Failure> {
    check(decision, "phone-1", "item-1", "abc", &context(), keys, NOW)
}

#[test]
fn shown_text_canonical_is_the_swift_v2_form() {
    let shown = ShownText::from_action(&json!({
        "tool": "Bash", "summary": "List files", "command": "ls -la\nrm x",
        "input": { "pattern": "*.rs", "path": "/tmp/é", "depth": 3 },
        "truncated": true,
    }));
    assert_eq!(
        shown.canonical(),
        "cmux-feed-shown-v2\ntool:4:Bash\nsummary:10:List files\ncommand:11:ls -la\nrm x\n\
         input:4:path:7:/tmp/é\ninput:7:pattern:4:*.rs\ntruncated:1\n"
    );
    assert_eq!(shown.sha256(), hex_lower(&Sha256::digest(shown.canonical().as_bytes())));
}

#[test]
fn shown_text_of_an_empty_action() {
    let shown = ShownText::from_action(&json!({}));
    assert_eq!(
        shown.canonical(),
        "cmux-feed-shown-v2\ntool:0:\nsummary:0:\ncommand:0:\ntruncated:0\n"
    );
    // sha256 of the line above, as the Swift computed it.
    assert_eq!(
        shown.sha256(),
        hex_lower(&Sha256::digest(
            b"cmux-feed-shown-v2\ntool:0:\nsummary:0:\ncommand:0:\ntruncated:0\n"
        ))
    );
}

#[test]
fn shown_text_is_truncated_only_by_the_json_boolean_true() {
    let truncated = |action: Value| ShownText::from_action(&action).truncated;
    assert!(truncated(json!({ "truncated": true })));
    assert!(!truncated(json!({ "truncated": false })));
    assert!(!truncated(json!({ "truncated": 1 })));
    assert!(!truncated(json!({ "truncated": "true" })));
    assert!(!truncated(json!({})));
}

#[test]
fn proof_message_bytes() {
    let message = ProofMessage {
        environment: "e".into(),
        user: "u".into(),
        phone_install: "p".into(),
        mac_install: "m".into(),
        item: "i".into(),
        shown_sha256: "s".into(),
        decision: "allow".into(),
        scope: "once".into(),
        timestamp_ms: 42,
    };
    assert_eq!(
        message.bytes(),
        b"cmux-feed-approve-v1\ne\nu\np\nm\ni\ns\nallow\nonce\n42".to_vec()
    );
}

#[test]
fn a_good_proof_passes_for_every_scope() {
    let keys = presence(good_entry());
    assert_eq!(run(&signed(ts(-1000.0), None, "item-1", "abc"), &keys), Ok(()));
    for scope in ["once", "session", "always"] {
        assert_eq!(run(&signed(ts(0.0), Some(scope), "item-1", "abc"), &keys), Ok(()));
    }
}

#[test]
fn the_signature_covers_the_item_and_the_shown_text() {
    let keys = presence(good_entry());
    assert_eq!(run(&signed(ts(0.0), None, "item-2", "abc"), &keys), Err(Failure::BadSignature));
    assert_eq!(run(&signed(ts(0.0), None, "item-1", "abd"), &keys), Err(Failure::BadSignature));
    let mut decision = signed(ts(0.0), Some("once"), "item-1", "abc");
    decision.scope = Some("session".into());
    assert_eq!(run(&decision, &keys), Err(Failure::BadSignature));
    let mut decision = signed(ts(0.0), None, "item-1", "abc");
    decision.outcome = "deny".into();
    assert_eq!(run(&decision, &keys), Err(Failure::BadSignature));
    let mut decision = signed(ts(0.0), None, "item-1", "abc");
    decision.proof.as_mut().expect("proof").signature = "!!".into();
    assert_eq!(run(&decision, &keys), Err(Failure::BadSignature));
}

#[test]
fn refusals_in_the_swift_order() {
    let keys = presence(good_entry());
    let mut none = signed(ts(0.0), None, "item-1", "abc");
    none.proof = None;
    assert_eq!(run(&none, &keys), Err(Failure::NoProof));

    let decision = signed(ts(0.0), None, "item-1", "abc");
    assert_eq!(
        check(&decision, "phone-2", "item-1", "abc", &context(), &keys, NOW),
        Err(Failure::OtherInstall)
    );
    // The time before the key: no key, but stale is what is named.
    assert_eq!(
        run(&signed(ts(-300_001.0), None, "item-1", "abc"), &HashMap::new()),
        Err(Failure::Stale)
    );
    assert_eq!(run(&signed(ts(60_001.0), None, "item-1", "abc"), &keys), Err(Failure::Stale));
    assert_eq!(run(&signed(ts(-300_000.0), None, "item-1", "abc"), &keys), Ok(()));
    assert_eq!(run(&signed(ts(60_000.0), None, "item-1", "abc"), &keys), Ok(()));
    assert_eq!(run(&decision, &HashMap::new()), Err(Failure::NoKey));

    let with = |patch: Value| {
        let mut entry = good_entry();
        for (k, v) in patch.as_object().expect("object") {
            entry[k] = v.clone();
        }
        run(&decision, &presence(entry))
    };
    assert_eq!(with(json!({ "platform": "android" })), Err(Failure::NotPhone));
    assert_eq!(with(json!({ "attested": false })), Err(Failure::NotAttested));
    assert_eq!(with(json!({ "attested": 1 })), Err(Failure::NotAttested));
    assert_eq!(with(json!({ "revoked_at": 5 })), Err(Failure::Revoked));
    assert_eq!(with(json!({ "install_active": false })), Err(Failure::Revoked));
    assert_eq!(with(json!({ "usable_from": NOW + 1.0 })), Err(Failure::CoolingDown));
    // A point not on the curve.
    assert_eq!(
        with(
            json!({ "jwk": { "x": URL_SAFE_NO_PAD.encode([1u8; 32]), "y": URL_SAFE_NO_PAD.encode([2u8; 32]) } })
        ),
        Err(Failure::BadKey)
    );
}

#[test]
fn keys_fail_closed() {
    let dropped = |patch: Value| {
        let mut entry = good_entry();
        let object = entry.as_object_mut().expect("object");
        for (k, v) in patch.as_object().expect("object") {
            if v.is_null() {
                object.remove(k);
            } else {
                object.insert(k.clone(), v.clone());
            }
        }
        presence(entry).is_empty()
    };
    assert!(!dropped(json!({})));
    assert!(dropped(json!({ "install": null })));
    assert!(dropped(json!({ "jwk": null })));
    assert!(dropped(json!({ "usable_from": null })));
    assert!(dropped(json!({ "usable_from": true })));
    assert!(dropped(json!({ "usable_from": "1" })));
    assert!(dropped(json!({ "jwk": { "x": "AAAA", "y": "AAAA" } })));
    // A missing revoked_at counts as revoked; a missing platform is "".
    let mut entry = good_entry();
    entry.as_object_mut().expect("object").remove("revoked_at");
    entry.as_object_mut().expect("object").remove("platform");
    let key = &presence(entry)["phone-1"];
    assert!(key.revoked);
    assert_eq!(key.platform, "");
    assert!(keys(&json!({})).is_empty());
    assert!(keys(&json!({ "keys": "x" })).is_empty());
}

#[test]
fn context_of_a_token() {
    let token = |claims: Value| {
        format!("h.{}.s", URL_SAFE_NO_PAD.encode(serde_json::to_vec(&claims).expect("json")))
    };
    assert_eq!(
        context_of_token(&token(
            json!({ "iss": "https://cmux-api/production", "sub": "u", "inst": "m" })
        )),
        Some(Context {
            environment: "production".into(),
            user: "u".into(),
            mac_install: "m".into()
        })
    );
    for claims in [
        json!({ "iss": "https://cmux-api/", "sub": "u", "inst": "m" }),
        json!({ "iss": "https://other/production", "sub": "u", "inst": "m" }),
        json!({ "iss": "https://cmux-api/production", "sub": "", "inst": "m" }),
        json!({ "iss": "https://cmux-api/production", "sub": "u" }),
        json!({ "iss": "https://cmux-api/production", "sub": 1, "inst": "m" }),
    ] {
        assert_eq!(context_of_token(&token(claims)), None);
    }
    assert_eq!(context_of_token("a.b"), None);
    assert_eq!(context_of_token("a.!!.c"), None);
}

#[test]
fn base64url_reads_both_alphabets_with_or_without_padding() {
    assert_eq!(base64url("-_8"), Some(vec![0xfb, 0xff]));
    assert_eq!(base64url("+/8="), Some(vec![0xfb, 0xff]));
    assert_eq!(base64url("A"), None);
    assert_eq!(base64url("!!!!"), None);
}

#[test]
fn failure_names_are_the_swift_case_names() {
    assert_eq!(serde_json::to_value(Failure::CoolingDown).expect("json"), json!("coolingDown"));
    assert_eq!(serde_json::to_value(Failure::BadSignature).expect("json"), json!("badSignature"));
}
