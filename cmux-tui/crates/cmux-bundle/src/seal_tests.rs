use super::*;

#[test]
fn seals_open_and_dedupe() {
    let key = PairKey::derive(&[3; 32]);
    let text = b"hello hello hello hello ".repeat(400);
    let (id, sealed) = seal(&key, &text);
    assert!(sealed.len() < text.len() / 4, "text compresses: {}", sealed.len());
    assert_eq!(open(&key, &id, &sealed).unwrap(), text);
    // Deterministic: the same content seals to the same bytes (ciphertext dedupe in a cache).
    assert_eq!(seal(&key, &text).1, sealed);
}

#[test]
fn a_wrong_key_id_or_byte_is_caught() {
    let key = PairKey::derive(&[3; 32]);
    let other = PairKey::derive(&[4; 32]);
    let (id, sealed) = seal(&key, b"attachment bytes");
    assert_eq!(open(&other, &id, &sealed), Err(Error::Seal));
    let (id2, _) = seal(&key, b"another chunk");
    assert_eq!(open(&key, &id2, &sealed), Err(Error::Seal));
    let mut flipped = sealed.clone();
    *flipped.last_mut().unwrap() ^= 1;
    assert_eq!(open(&key, &id, &flipped), Err(Error::Seal));
    let mut future = sealed;
    future[0] = 2;
    assert_eq!(open(&key, &id, &future), Err(Error::Version(2)));
}

#[test]
fn incompressible_chunks_stay_raw() {
    let key = PairKey::derive(&[5; 32]);
    let noise: Vec<u8> =
        (0u32..70_000).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
    let (id, sealed) = seal(&key, &noise);
    assert!(sealed.len() <= noise.len() + OVERHEAD);
    assert_eq!(open(&key, &id, &sealed).unwrap(), noise);
}
