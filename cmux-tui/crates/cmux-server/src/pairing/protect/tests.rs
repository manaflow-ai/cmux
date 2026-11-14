use super::*;

#[test]
fn server_pairing_key_protection_roundtrips_and_refuses_another_protection_kind() {
    let plaintext = b"owned fixture private material";
    let (kind, bytes) = seal(plaintext).unwrap();
    assert_eq!(open(kind, &bytes).unwrap(), plaintext);
    assert!(open("unknown-protection", &bytes).is_err());
    #[cfg(windows)]
    assert_ne!(bytes, plaintext);
}
