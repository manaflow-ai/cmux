use super::*;

#[test]
fn ids_differ_across_pairs_and_match_within_one() {
    let a = PairKey::derive(&[1; 32]);
    let b = PairKey::derive(&[2; 32]);
    assert_eq!(a.chunk_id(b"screenshot"), a.chunk_id(b"screenshot"));
    assert_ne!(a.chunk_id(b"screenshot"), b.chunk_id(b"screenshot"));
    assert_ne!(a.id, a.seal);
}

#[test]
fn hex_round_trips() {
    let id = PairKey::derive(&[9; 32]).chunk_id(b"x");
    assert_eq!(unhex(&hex(&id)).unwrap(), id);
    assert!(unhex("zz").is_err());
    assert!(unhex(&"G".repeat(64)).is_err());
}
