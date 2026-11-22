//! Pairing code, fingerprint words and QR payload (server.md 6.2).

use std::collections::BTreeSet;

use cmux_server_core::pairing::{
    CodeError, PairingCode, QrError, WORDLIST, fingerprint_words, key_fingerprint, qr_payload,
    verify_qr_fp, word_count,
};
use proptest::prelude::*;

/// RFC 8032 test vector 1 public key (no secret of value).
const PK: [u8; 32] = [
    0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7, 0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
    0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25, 0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a,
];

#[test]
fn code_from_random_golden() {
    let code = PairingCode::from_random([0x39, 0xa7, 0x24, 0xa0, 0x5d]);
    assert_eq!(code.as_str(), "76KJ982X");
    assert_eq!(code.display(), "76KJ-982X");
    assert_eq!(code.to_string(), "76KJ-982X");
    assert_eq!(PairingCode::from_random([0; 5]).as_str(), "00000000");
    assert_eq!(PairingCode::from_random([0xff; 5]).as_str(), "ZZZZZZZZ");
}

#[test]
fn normalize_accepts_aliases_and_refuses_bad_input() {
    let code = PairingCode::normalize("7kq4-m2xd").unwrap();
    assert_eq!(code.as_str(), "7KQ4M2XD");
    assert_eq!(PairingCode::normalize(" 7KQ4 M2XD ").unwrap(), code);
    assert_eq!(PairingCode::normalize("oIlL-0000").unwrap().as_str(), "01110000");
    assert_eq!(PairingCode::normalize("7KQ4-M2XU"), Err(CodeError::ReservedU));
    assert_eq!(PairingCode::normalize("7KQ4-M2X!"), Err(CodeError::Invalid('!')));
    assert_eq!(PairingCode::normalize("7KQ4-M2X"), Err(CodeError::Length(7)));
    assert_eq!(PairingCode::normalize("7KQ4-M2XDD"), Err(CodeError::Length(9)));
    assert_eq!(PairingCode::normalize("７KQ4M2XD"), Err(CodeError::Invalid('７')));
}

#[test]
fn wordlist_is_the_full_list() {
    assert_eq!(word_count(), 2048);
    assert_eq!(WORDLIST[0], "abandon");
    assert_eq!(WORDLIST[2047], "zoo");
    let unique: BTreeSet<&str> = WORDLIST.iter().copied().collect();
    assert_eq!(unique.len(), 2048);
    let prefixes: BTreeSet<String> = WORDLIST.iter().map(|w| w.chars().take(4).collect()).collect();
    assert_eq!(prefixes.len(), 2048, "words are unique in their first four letters");
}

#[test]
fn fingerprint_words_and_qr_golden() {
    assert_eq!(fingerprint_words(&PK), ["capable", "various", "jewel", "dress"]);
    assert_eq!(key_fingerprint(&PK), "47Z33QX1AJH62RKB");
    let code = PairingCode::normalize("7KQ4-M2XD").unwrap();
    let payload = qr_payload(&code, &PK);
    assert_eq!(payload, "https://cmux.com/pair?c=7KQ4M2XD#fp=47Z33QX1AJH62RKB");
    assert_eq!(verify_qr_fp(&payload, &PK), Ok(code));
    // Lowercase and aliases in a hand-typed payload still match.
    assert_eq!(verify_qr_fp("https://cmux.com/pair?c=7kq4m2xd#fp=47z33qx1ajh62rkb", &PK), Ok(code));
}

#[test]
fn qr_refuses_swapped_or_malformed_payloads() {
    let code = PairingCode::from_random([1, 2, 3, 4, 5]);
    let mut other = PK;
    other[0] ^= 1;
    let payload = qr_payload(&code, &PK);
    assert_eq!(verify_qr_fp(&payload, &other), Err(QrError::FingerprintMismatch));
    for bad in [
        "https://evil.example/pair?c=7KQ4M2XD#fp=47Z33QX1AJH62RKB",
        "https://cmux.com/pair?c=7KQ4M2XD",
        "https://cmux.com/pair?c=7KQ4M2XD#fp=47Z33QX1AJH62RK",
        "https://cmux.com/pair?c=7KQ4M2XD&x=1#fp=47Z33QX1AJH62RKB",
        "https://cmux.com/pair?c=7KQ4M2XD#fp=47Z33QX1AJH62RKU",
    ] {
        assert_eq!(verify_qr_fp(bad, &PK), Err(QrError::Malformed), "{bad}");
    }
    assert_eq!(
        verify_qr_fp("https://cmux.com/pair?c=7KQ4M2XU#fp=47Z33QX1AJH62RKB", &PK),
        Err(QrError::Code(CodeError::ReservedU))
    );
}

proptest! {
    #[test]
    fn normalize_display_round_trips(bytes in any::<[u8; 5]>()) {
        let code = PairingCode::from_random(bytes);
        prop_assert_eq!(PairingCode::normalize(&code.display()), Ok(code));
        prop_assert_eq!(PairingCode::normalize(&code.display().to_lowercase()), Ok(code));
        prop_assert_eq!(PairingCode::normalize(code.as_str()), Ok(code));
    }

    #[test]
    fn distinct_random_bytes_give_distinct_codes(a in any::<[u8; 5]>(), b in any::<[u8; 5]>()) {
        prop_assert_eq!(a == b, PairingCode::from_random(a) == PairingCode::from_random(b));
    }

    #[test]
    fn qr_round_trips_for_any_key(bytes in any::<[u8; 5]>(), key in proptest::collection::vec(any::<u8>(), 32)) {
        let code = PairingCode::from_random(bytes);
        prop_assert_eq!(verify_qr_fp(&qr_payload(&code, &key), &key), Ok(code));
    }
}
