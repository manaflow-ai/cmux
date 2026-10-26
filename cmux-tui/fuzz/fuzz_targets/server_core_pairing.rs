//! Pairing codes and QR payloads (cmux-server-core `pairing`): Crockford
//! base32 `decode_symbol` / `encode_bits`, `PairingCode::normalize` of typed
//! text and `verify_qr_fp` of a scanned payload.
//!
//! Checked: a normalized code is canonical and survives display and a second
//! normalize; a payload built from a code and key verifies to that code, and
//! never against another key's fingerprint.
//!
//! Input: one selector byte, then text (code, payload) or bytes (key).
#![no_main]

use cmux_server_core::pairing::{
    ALPHABET, CODE_LEN, PairingCode, QrError, decode_symbol, encode_bits, key_fingerprint,
    qr_payload, verify_qr_fp,
};
use libfuzzer_sys::fuzz_target;

fn check_code(code: PairingCode) {
    let canonical = code.as_str();
    assert_eq!(canonical.len(), CODE_LEN);
    assert!(canonical.bytes().all(|b| ALPHABET.contains(&b)), "a code holds a non-symbol");
    assert_eq!(PairingCode::normalize(canonical), Ok(code));
    assert_eq!(PairingCode::normalize(&code.display()), Ok(code));
    assert_eq!(PairingCode::normalize(&canonical.to_ascii_lowercase()), Ok(code));
}

fuzz_target!(|data: &[u8]| {
    let Some((&selector, rest)) = data.split_first() else {
        return;
    };
    for c in String::from_utf8_lossy(rest).chars().take(64) {
        if let Some(value) = decode_symbol(c) {
            assert!(value < 32, "a symbol decoded past 5 bits");
        }
    }
    match selector % 4 {
        0 => {
            if let Ok(text) = std::str::from_utf8(rest)
                && let Ok(code) = PairingCode::normalize(text)
            {
                check_code(code);
            }
        }
        1 => {
            // A scanned payload against the key the record holds.
            let (key, payload) = rest.split_at(rest.len().min(32));
            if let Ok(payload) = std::str::from_utf8(payload)
                && let Ok(code) = verify_qr_fp(payload, key)
            {
                check_code(code);
            }
        }
        2 => {
            // The issuer's side: random bytes give a code, a payload verifies.
            let (random, key) = rest.split_at(rest.len().min(5));
            let Ok(random) = <[u8; 5]>::try_from(random) else {
                return;
            };
            let code = PairingCode::from_random(random);
            check_code(code);
            let payload = qr_payload(&code, key);
            assert_eq!(verify_qr_fp(&payload, key), Ok(code));
            let mut other = key.to_vec();
            other.push(0);
            if key_fingerprint(&other) != key_fingerprint(key) {
                assert_eq!(verify_qr_fp(&payload, &other), Err(QrError::FingerprintMismatch));
            }
        }
        _ => {
            let symbols = usize::from(selector >> 2) % 64;
            if rest.len() * 8 >= symbols * 5 {
                let encoded = encode_bits(rest, symbols);
                assert_eq!(encoded.len(), symbols);
                assert!(encoded.bytes().all(|b| ALPHABET.contains(&b)));
            }
        }
    }
});
