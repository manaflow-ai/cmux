use super::*;

/// RFC 4231 test cases 1, 2, 3 and 6 (HMAC-SHA-256).
#[test]
fn hmac_sha256_matches_rfc_4231() {
    let cases: [(Vec<u8>, Vec<u8>, &str); 4] = [
        (
            vec![0x0b; 20],
            b"Hi There".to_vec(),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        ),
        (
            b"Jefe".to_vec(),
            b"what do ya want for nothing?".to_vec(),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        ),
        (
            vec![0xaa; 20],
            vec![0xdd; 50],
            "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
        ),
        (
            vec![0xaa; 131],
            b"Test Using Larger Than Block-Size Key - Hash Key First".to_vec(),
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
        ),
    ];
    for (key, message, expected) in cases {
        assert_eq!(hex(&hmac_sha256(&key, &message)), expected);
    }
}

fn key() -> Vec<u8> {
    (0u8..32).collect()
}

const NONCE: [u8; NONCE_LEN] = [0xa5; NONCE_LEN];
/// The same vector the Swift side tests (`FrontendInstallKeyTests`).
const VECTOR: &str = "1878e5949b7e511bb06b3f98939beabd11626e5519834bb0fa371420cecb6793";

#[test]
fn hello_proof_matches_the_shared_vector() {
    assert_eq!(hello_proof(&key(), "inst_test-01", &NONCE), VECTOR);
    assert!(verify_hello_proof(&key(), "inst_test-01", &NONCE, VECTOR));
    assert!(verify_hello_proof(&key(), "inst_test-01", &NONCE, &VECTOR.to_uppercase()));
}

#[test]
fn hello_proof_refuses_any_other_input() {
    let mut other_key = key();
    other_key[0] ^= 1;
    assert!(!verify_hello_proof(&other_key, "inst_test-01", &NONCE, VECTOR));
    assert!(!verify_hello_proof(&key(), "inst_test-02", &NONCE, VECTOR));
    let mut other_nonce = NONCE;
    other_nonce[31] ^= 1;
    assert!(!verify_hello_proof(&key(), "inst_test-01", &other_nonce, VECTOR));
    let malformed = [
        String::new(),
        "zz".to_string(),
        VECTOR[..62].to_string(),
        format!("{VECTOR}00"),
        VECTOR.replace('1', "g"),
    ];
    for proof in &malformed {
        assert!(!verify_hello_proof(&key(), "inst_test-01", &NONCE, proof), "{proof}");
    }
}

#[test]
fn install_ids_are_short_and_plain() {
    assert!(valid_install_id("inst_ABC-123"));
    let too_long = "a".repeat(MAX_INSTALL_ID_LEN + 1);
    for bad in ["", "a b", "a\0b", "a/b", "é", too_long.as_str()] {
        assert!(!valid_install_id(bad), "{bad:?}");
        assert!(!verify_hello_proof(&key(), bad, &NONCE, VECTOR));
    }
}

#[test]
fn hex_round_trips() {
    let bytes: [u8; 4] = [0, 0x7f, 0x80, 0xff];
    assert_eq!(hex(&bytes), "007f80ff");
    assert_eq!(unhex::<4>("007F80ff"), Some(bytes));
    assert_eq!(unhex::<4>("007f80f"), None);
}
