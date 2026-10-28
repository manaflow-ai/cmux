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

#[test]
fn a_totp_code_is_masked_only_as_a_whole_number() {
    let mask = "<secret:otp>";
    let replaced = |text: &str, code: &str| replace_number(text, code, mask);
    assert_eq!(replaced("code 123456.", "123456").as_deref(), Some("code <secret:otp>."));
    assert_eq!(replaced("123456", "123456").as_deref(), Some(mask));
    assert_eq!(replaced("123456,123456", "123456").as_deref(), Some("<secret:otp>,<secret:otp>"));
    // Inside a longer number, or right after a kept occurrence, it is another number.
    assert_eq!(replaced("91234567", "123456"), None);
    assert_eq!(replaced("123456123456", "123456"), None);
    assert_eq!(replaced("111111111 111111", "111111").as_deref(), Some("111111111 <secret:otp>"));
    assert_eq!(replaced("é123456ü", "123456").as_deref(), Some("é<secret:otp>ü"));
    assert_eq!(replaced("no digits", "123456"), None);
    assert_eq!(replaced("anything", ""), None);
}

#[test]
fn json_text_masking_keeps_the_rest_byte_for_byte() {
    let masker = vault().masker();
    assert_eq!(
        masker.mask_json_text(r#"{"b":1.50,"s3cr&t value":"x","q":"say \"hi\""}"#),
        r#"{"b":1.50,"<secret:api_key>":"x","q":"say \"hi\""}"#
    );
    // A value behind a JSON escape is masked; a non-ASCII string is kept.
    assert_eq!(masker.mask_json_text(r#"["s3cr&t value","é"]"#), r#"["<secret:api_key>","é"]"#);
    // A string left open, or one that is not valid JSON, is kept as it is.
    assert_eq!(masker.mask_json_text(r#"{"a":"s3cr&t va"#), r#"{"a":"s3cr&t va"#);
    assert_eq!(masker.mask_json_text(r#"["\x", "s3cr&t value"]"#), r#"["\x", "<secret:api_key>"]"#);
    assert_eq!(masker.mask_json_text("\"tail\\"), "\"tail\\");
}

#[test]
fn stream_masking_cuts_only_at_character_boundaries() {
    let masker = vault().masker();
    let mut stream = masker.stream();
    let mut out = String::new();
    for chunk in ["ééééééééééééé", "s3cr&t value", "ü", "ééééééééééééé"]
    {
        let emitted = stream.write(chunk);
        assert!(!emitted.contains("s3cr"), "{emitted:?}");
        out.push_str(&emitted);
    }
    out.push_str(&stream.finish());
    assert_eq!(out, "ééééééééééééé<secret:api_key>üééééééééééééé");
}

#[test]
fn binary_masking_replaces_every_occurrence() {
    let masker = vault().masker();
    let mut bytes = vec![0xff, b's'];
    bytes.extend_from_slice(b"s3cr&t value");
    bytes.push(0xfe);
    bytes.extend_from_slice(b"s3cr&t value");
    let mut expected = vec![0xff, b's'];
    expected.extend_from_slice(b"<secret:api_key>");
    expected.push(0xfe);
    expected.extend_from_slice(b"<secret:api_key>");
    assert_eq!(masker.mask_bytes(&bytes), expected);
}
