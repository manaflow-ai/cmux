use super::*;

#[test]
fn same_bytes_store_once() {
    let mut store = BlobStore::new(4);
    let a = store.insert(Mime::Png, b"icon");
    let b = store.insert(Mime::Png, b"icon");
    assert_eq!(a, b);
    assert_eq!(a, BlobHash::of(b"icon"));
    let stats = store.stats();
    assert_eq!(stats.blobs, 1);
    assert_eq!(stats.stored_bytes, 4);
    assert_eq!(stats.dedupe_hits, 1);
    assert_eq!(stats.dedupe_saved_bytes, 4);
}

#[test]
fn referenced_blobs_stay_and_dropped_ones_are_bounded() {
    let mut store = BlobStore::new(2);
    let live = store.insert(Mime::Jpeg, b"live");
    let mut dropped = Vec::new();
    for i in 0..4u8 {
        let h = store.insert(Mime::Jpeg, &[i; 8]);
        store.release(h);
        dropped.push(h);
    }
    assert!(store.contains(&live));
    assert!(!store.contains(&dropped[0]));
    assert!(!store.contains(&dropped[1]));
    assert!(store.contains(&dropped[2]));
    assert!(store.contains(&dropped[3]));
    assert_eq!(store.stats().recent, 2);
    assert_eq!(store.stats().stored_bytes, 4 + 16);
}

#[test]
fn a_recent_blob_taken_again_leaves_the_recent_set() {
    let mut store = BlobStore::new(1);
    let a = store.insert(Mime::Jpeg, b"a");
    store.release(a);
    assert_eq!(store.stats().recent, 1);
    let again = store.insert(Mime::Jpeg, b"a");
    assert_eq!(again, a);
    assert_eq!(store.stats().recent, 0);
    let b = store.insert(Mime::Jpeg, b"b");
    store.release(b);
    let c = store.insert(Mime::Jpeg, b"c");
    store.release(c);
    assert!(store.contains(&a));
    assert!(!store.contains(&b));
}

#[test]
fn shared_blob_survives_one_release() {
    let mut store = BlobStore::new(0);
    let icon = store.insert(Mime::Png, b"icon");
    store.insert(Mime::Png, b"icon");
    store.release(icon);
    assert!(store.contains(&icon));
    store.release(icon);
    assert!(!store.contains(&icon));
    store.release(icon);
    assert!(!store.acquire(icon));
}
