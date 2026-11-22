use super::*;
use serde_json::json;

fn vault() -> Vault {
    let mut vault = Vault::default();
    vault.set("api_key", "s3cr&t value", &["example.com".into()], false, false).unwrap();
    vault
}

#[test]
fn secrets_need_names_values_and_domains() {
    let mut vault = Vault::default();
    assert!(vault.set("bad name", "v", &["a.test".into()], false, true).is_err());
    assert!(vault.set("ok", "", &["a.test".into()], false, true).is_err());
    assert!(vault.set("ok", "v", &[], false, true).is_err());
    assert!(vault.set("otp", "not base32!", &["a.test".into()], true, true).is_err());
    assert!(
        vault.set("x_bu_2fa_code", "not base32!", &["a.test".into()], false, true).is_err(),
        "browser-use names imply TOTP"
    );
    vault.set("ok", "v", &["a.test".into()], false, true).unwrap();
    assert_eq!(
        vault.list(),
        vec![SecretInfo {
            name: "ok".into(),
            domains: vec!["a.test".into()],
            totp: false,
            agent_known: true
        }]
    );
    assert!(vault.delete("ok"));
    assert!(!vault.delete("ok"));
}

#[test]
fn debug_output_never_contains_values() {
    let text = format!("{:?}", vault());
    assert!(!text.contains("s3cr"), "{text}");
}

#[test]
fn values_are_typed_only_into_matching_secure_frames() {
    let vault = vault();
    assert_eq!(
        vault.text_for_frame("api_key", "https://www.example.com/login", 0).unwrap(),
        "s3cr&t value"
    );
    let refused = vault.text_for_frame("api_key", "https://evil.test/login?next=1", 0).unwrap_err();
    assert!(refused.0.contains("may not be typed into https://evil.test/login;"), "{refused}");
    assert!(!refused.0.contains("s3cr"));
    assert!(
        vault.text_for_frame("api_key", "http://example.com/", 0).is_err(),
        "plain http is refused"
    );
    assert!(vault.text_for_frame("missing", "https://example.com/", 0).is_err());
}

#[test]
fn totp_matches_rfc_6238_vectors() {
    // RFC 6238 appendix B, SHA-1 key "12345678901234567890", 8 digits.
    let key = b"12345678901234567890";
    assert_eq!(totp(key, 59_000, 8, 30), "94287082");
    assert_eq!(totp(key, 1_111_111_109_000, 8, 30), "07081804");
    assert_eq!(totp(key, 20_000_000_000_000, 8, 30), "65353130");
    assert_eq!(base32_decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ").unwrap(), key.to_vec());
    let mut vault = Vault::default();
    vault.set("otp", "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", &["a.test".into()], true, false).unwrap();
    assert_eq!(vault.text_for_frame("otp", "https://a.test/", 59_000).unwrap(), "287082");
}

#[test]
fn masking_covers_encoded_variants_and_json() {
    let masker = vault().masker();
    assert_eq!(masker.mask("key=s3cr&t value!"), "key=<secret:api_key>!");
    assert_eq!(masker.mask("q=s3cr%26t%20value"), "q=<secret:api_key>");
    assert_eq!(masker.mask("q=s3cr%26t+value"), "q=<secret:api_key>");
    assert_eq!(masker.mask("<b>s3cr&amp;t value</b>"), "<b><secret:api_key></b>");
    let value = json!({"s3cr&t value": ["x s3cr&t value"], "n": 1});
    assert_eq!(
        masker.mask_value(&value),
        json!({"<secret:api_key>": ["x <secret:api_key>"], "n": 1})
    );
    assert!(Vault::default().masker().is_empty());
}

#[test]
fn stream_masking_catches_values_split_across_writes() {
    let masker = vault().masker();
    let mut stream = masker.stream();
    let mut out = String::new();
    for chunk in ["token: s3c", "r&t va", "lue done ", "and more text after it"] {
        out.push_str(&stream.write(chunk));
    }
    out.push_str(&stream.finish());
    assert_eq!(out, "token: <secret:api_key> done and more text after it");

    let mut plain = Vault::default().masker().stream();
    assert_eq!(plain.write("abc"), "abc");
    assert_eq!(plain.finish(), "");
}
