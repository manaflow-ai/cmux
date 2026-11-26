use super::*;

#[test]
fn dir_store_round_trips() {
    let dir = std::env::temp_dir().join(format!("cmux-bundle-store-{}", std::process::id()));
    let mut s = DirStore::new(&dir);
    let id = [0xab; 32];
    assert!(!s.has(&id));
    assert_eq!(s.get(&id).unwrap(), None);
    s.put(&id, b"sealed").unwrap();
    s.put(&id, b"ignored").unwrap();
    assert_eq!(s.get(&id).unwrap().as_deref(), Some(&b"sealed"[..]));
    std::fs::remove_dir_all(&dir).ok();
}
