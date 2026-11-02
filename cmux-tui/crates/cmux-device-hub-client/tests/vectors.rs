//! The shared cross-language vectors (`schemas/device-hub/test-vectors.json`):
//! the TypeScript hub, Swift `CmuxDeviceHub` and this crate must agree on
//! every canonical string and digest and accept every signature, high-S too.

use base64::Engine as _;
use cmux_device_hub_client::canonical::{canonical_json, canonical_sha256};
use cmux_device_hub_client::signing::{
    body_sha256_hex, canonical_request, low_s, verify, verify_base64,
};
use cmux_device_hub_client::{
    ApprovalRequest, Assurance, Decision, DeviceKeys as _, SoftwareKeys, decision_message,
};
use serde_json::Value;

fn vectors() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/device-hub/test-vectors.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_str(&text).expect("test vectors are JSON")
}

fn str_of<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or_else(|| panic!("{key} is not a string"))
}

fn b64(text: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(text).unwrap()
}

#[test]
fn request_signing_vectors() {
    let vectors = vectors();
    let key = str_of(&vectors["key"], "signingKey");
    let cases = vectors["requestSigning"].as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let body = str_of(case, "body");
        let body = if body.is_empty() { None } else { Some(body.as_bytes()) };
        let ts: i64 = str_of(case, "ts").parse().unwrap();
        assert_eq!(body_sha256_hex(body), str_of(case, "bodySha256"));
        let canonical =
            canonical_request(str_of(case, "method"), str_of(case, "pathAndQuery"), ts, body);
        assert_eq!(canonical, str_of(case, "canonical"));
        for sig in ["sig", "sigHighS"] {
            assert!(
                verify_base64(key, canonical.as_bytes(), str_of(case, sig)),
                "{sig} of {canonical:?}"
            );
        }
        assert_eq!(
            hex::encode(low_s(&b64(str_of(case, "sigHighS"))).unwrap()),
            str_of(case, "lowSHex")
        );
        assert_eq!(hex::encode(low_s(&b64(str_of(case, "sig"))).unwrap()), str_of(case, "lowSHex"));
        assert!(!verify_base64(key, b"other", str_of(case, "sig")));
    }
}

#[test]
fn canonical_json_vectors() {
    let vectors = vectors();
    for case in vectors["canonicalJson"].as_array().unwrap() {
        assert_eq!(canonical_json(&case["value"]).unwrap(), str_of(case, "canonical"));
        assert_eq!(canonical_sha256(&case["value"]).unwrap(), str_of(case, "sha256"));
    }
}

#[test]
fn approval_request_digest_vector() {
    let vectors = vectors();
    let request: ApprovalRequest =
        serde_json::from_value(vectors["approvalRequest"]["request"].clone()).unwrap();
    assert_eq!(request.compute_digest().unwrap(), request.digest);
    assert!(request.digest_is_valid());
    let mut changed = request;
    changed.tool = "type".into();
    assert!(!changed.digest_is_valid());
    assert_eq!(changed.sealed().unwrap().digest.len(), 64);
}

#[test]
fn approval_decision_vectors() {
    let vectors = vectors();
    let key = str_of(&vectors["key"], "signingKey");
    let digest = str_of(&vectors["approvalRequest"]["request"], "digest");
    for case in vectors["approvalDecisions"].as_array().unwrap() {
        let decision = Decision::parse(str_of(case, "decision")).unwrap();
        let message = decision_message(digest, decision);
        assert_eq!(message, str_of(case, "message"));
        for sig in ["sig", "sigHighS"] {
            assert!(
                verify_base64(key, message.as_bytes(), str_of(case, sig)),
                "{sig} of {decision}"
            );
        }
        assert_eq!(
            hex::encode(low_s(&b64(str_of(case, "sigHighS"))).unwrap()),
            str_of(case, "lowSHex")
        );
    }
}

#[test]
fn the_vector_private_key_signs_what_the_hub_verifies() {
    let vectors = vectors();
    let private = hex::decode(str_of(&vectors["key"], "privateKeyHex")).unwrap();
    let public = b64(str_of(&vectors["key"], "signingKey"));
    let other = SoftwareKeys::generate(Assurance::File).unwrap();
    let keys = SoftwareKeys::from_raw(
        &private,
        &public,
        &hex::decode(
            other.to_stored("0b9f4c1e-8d1a-4d7e-9a43-2f0c5e7b1a60").agreement_private.clone(),
        )
        .unwrap(),
        &other.agreement_public_key(),
        Assurance::File,
    )
    .unwrap();
    let canonical = str_of(&vectors["requestSigning"][0], "canonical");
    let signature = keys.sign(canonical.as_bytes()).unwrap();
    assert!(verify(&public, canonical.as_bytes(), &signature));
}
