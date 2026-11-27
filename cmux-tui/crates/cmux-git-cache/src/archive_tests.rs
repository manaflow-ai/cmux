use super::*;

#[test]
fn ranges() {
    assert_eq!(byte_range(None, 10), Ok(None));
    assert_eq!(byte_range(Some("bytes=0-0"), 10), Ok(Some((0, 0))));
    assert_eq!(byte_range(Some("bytes=2-"), 10), Ok(Some((2, 9))));
    assert_eq!(byte_range(Some("bytes=5-99"), 10), Ok(Some((5, 9))));
    assert_eq!(byte_range(Some("bytes=-3"), 10), Ok(Some((7, 9))));
    assert_eq!(byte_range(Some("bytes=0-1,3-4"), 10), Ok(None));
    assert_eq!(byte_range(Some("bytes=10-"), 10), Err(()));
    assert_eq!(byte_range(Some("bytes=4-2"), 10), Err(()));
}

#[test]
fn evicts_oldest_first_but_never_the_new_entry() {
    let dir = tempfile::tempdir().unwrap();
    let now = SystemTime::now();
    let mut paths = Vec::new();
    for (i, age) in [30u64, 20, 10].iter().enumerate() {
        let p = dir.path().join(format!("e{i}"));
        std::fs::write(&p, vec![0u8; 100]).unwrap();
        std::fs::write(meta_path(&p), "{}").unwrap();
        let f = std::fs::File::options().append(true).open(&p).unwrap();
        f.set_modified(now - Duration::from_secs(*age)).unwrap();
        paths.push(p);
    }
    evict(dir.path(), 250, &paths[0]);
    assert!(paths[0].exists(), "the entry just filled stays");
    assert!(!paths[1].exists() && !meta_path(&paths[1]).exists());
    assert!(paths[2].exists());
}
