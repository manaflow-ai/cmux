use super::*;

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
