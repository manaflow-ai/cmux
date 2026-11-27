use super::*;
use crate::store::MemStore;

#[test]
fn round_trips_and_assembles() {
    let key = PairKey::derive(&[7; 32]);
    let data: Vec<u8> = (0..300_000u32).flat_map(|i| (i * 7919).to_le_bytes()).collect();
    let mut store = MemStore::default();
    let m = Manifest::build(&key, Kind::Attachment, &data, &mut store).unwrap();
    assert!(m.chunks.len() > 4);
    let decoded = Manifest::decode(&m.encode()).unwrap();
    assert_eq!(decoded, m);
    assert_eq!(decoded.root(&key), m.root(&key));
    assert_eq!(m.assemble(&key, &store).unwrap(), data);
    assert!(m.lacking(&store).is_empty());
    assert_eq!(m.lacking(&MemStore::default()).len(), m.chunks.len());
}

#[test]
fn refuses_bad_forms() {
    assert_eq!(Manifest::decode(&[9]), Err(Error::Version(9)));
    assert!(Manifest::decode(&[1, 1]).is_err());
    let key = PairKey::derive(&[7; 32]);
    let mut store = MemStore::default();
    let m = Manifest::build(&key, Kind::HistoryPage, b"page", &mut store).unwrap();
    let mut bad = m.encode();
    bad[9] ^= 1; // total no longer matches
    assert!(Manifest::decode(&bad).is_err());
    let mut other = m.encode();
    other[1] = 200;
    assert_eq!(Manifest::decode(&other).unwrap().kind, Kind::Other(200));
}
