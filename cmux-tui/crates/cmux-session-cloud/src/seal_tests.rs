use super::*;

#[test]
fn a_sealed_blob_opens_with_its_key_only() {
    let key = Key::generate().unwrap();
    let plain = b"{\"seq\":1}\n".repeat(1000);
    let sealed = seal(&key, &plain).unwrap();
    assert!(sealed.len() < plain.len() / 4, "ndjson compresses");
    assert_eq!(open(&key, &sealed, plain.len()).unwrap(), plain);
    assert!(open(&Key::generate().unwrap(), &sealed, plain.len()).is_err());
    let mut flipped = sealed;
    *flipped.last_mut().unwrap() ^= 1;
    assert!(open(&key, &flipped, plain.len()).is_err());
}

#[test]
fn the_same_plaintext_seals_differently_each_time() {
    let key = Key::generate().unwrap();
    assert_ne!(seal(&key, b"same").unwrap(), seal(&key, b"same").unwrap());
}
