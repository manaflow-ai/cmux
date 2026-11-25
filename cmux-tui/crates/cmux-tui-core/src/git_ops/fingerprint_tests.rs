use super::*;

/// The digits are of one process: its random bytes are in them, so they
/// are not the hash of the parts alone.
#[test]
fn git_fingerprint_digits_hold_the_random_bytes_of_the_process() {
    let process = process_bytes().ok();
    assert!(process.is_some_and(|bytes| *bytes != [0; 32]), "the process has no random bytes");
    let mut digest = Digest::new(process.unwrap_or(&[0; 32]));
    digest.put(b"part");
    let mut parts = Sha256::new();
    parts.update(4_u64.to_le_bytes());
    parts.update(b"part");
    let parts: String = parts.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    assert_ne!(digest.hex(), parts, "the digits are the hash of the parts alone");
}

/// The bytes are the first part, and they stand before the hash of the
/// parts: other bytes give other digits, and the digits are those of the
/// two places.
#[test]
fn git_fingerprint_digits_take_the_bytes_of_the_process_at_two_places() {
    let digits = |process: &'static [u8; 32]| {
        let mut digest = Digest::new(process);
        digest.put(b"part");
        digest.hex()
    };
    let (process, other): (&'static [u8; 32], &'static [u8; 32]) = (&[7; 32], &[8; 32]);
    assert_ne!(digits(process), digits(other), "other bytes gave the same digits");

    let mut parts = Sha256::new();
    parts.update(32_u64.to_le_bytes());
    parts.update(process);
    parts.update(4_u64.to_le_bytes());
    parts.update(b"part");
    let mut whole = Sha256::new();
    whole.update(process);
    whole.update(parts.finalize());
    let whole: String = whole.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    assert_eq!(digits(process), whole, "the bytes are not at the 2 places");
}
