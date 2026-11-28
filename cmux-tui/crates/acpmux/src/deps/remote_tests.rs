use super::*;

fn sha(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

#[test]
fn a_timing_record_has_a_key_of_its_own() {
    let key = format!("bun-{}", "a".repeat(64));
    let meta = meta_key(&key).unwrap();
    assert!(meta.starts_with("bun-"));
    assert_eq!(meta.len(), key.len());
    assert_ne!(meta, key);
    assert!(meta[4..].bytes().all(|b| b.is_ascii_hexdigit()));
    assert_eq!(meta_key(&key), Some(meta));
    assert_eq!(meta_key("nodash"), None);
}

#[test]
fn tree_digest_is_the_hash_of_part_hashes_however_it_is_fed() {
    let data: Vec<u8> = (0..2500u32).map(|i| (i % 251) as u8).collect();
    let mut expected = Sha256::new();
    for part in data.chunks(1000) {
        expected.update(sha(part));
    }
    let expected = hex(&expected.finalize());
    for step in [1, 7, 1000, 2500] {
        let mut h = TreeHasher::new(1000);
        for piece in data.chunks(step) {
            h.update(piece);
        }
        assert_eq!(h.finish(), (expected.clone(), 3), "step {step}");
    }
    // Exactly one full part: no empty trailing part.
    let mut h = TreeHasher::new(1000);
    h.update(&data[..1000]);
    let mut one = Sha256::new();
    one.update(sha(&data[..1000]));
    assert_eq!(h.finish(), (hex(&one.finalize()), 1));
}
