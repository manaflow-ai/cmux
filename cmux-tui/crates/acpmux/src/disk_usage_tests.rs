use super::*;
use serde_json::json;

#[test]
fn the_split_is_camel_case() {
    let split = DiskSplit {
        at: 5,
        system_bytes: 1,
        project_bytes: 2,
        caches_bytes: 3,
        complete: true,
        top: vec![TopDir { path: "/home/u/src/app".into(), bytes: 2 }],
    };
    assert_eq!(
        serde_json::to_value(&split).unwrap(),
        json!({"at": 5, "systemBytes": 1, "projectBytes": 2, "cachesBytes": 3,
               "complete": true, "top": [{"path": "/home/u/src/app", "bytes": 2}]})
    );
}

#[test]
fn system_is_what_home_does_not_hold() {
    let root = Root { total: 100, used: 60, free: 40 };
    let walked = Walked {
        project: 20,
        caches: 10,
        complete: true,
        buckets: vec![
            (PathBuf::from("src"), 20),
            (PathBuf::from("src/app"), 19),
            (PathBuf::from(".cache"), 10),
            (PathBuf::from(".zshrc"), 1),
        ],
    };
    let split = split_of(Path::new("/h"), root, true, walked.clone(), 9);
    assert_eq!((split.system_bytes, split.project_bytes, split.caches_bytes), (30, 20, 10));
    let paths: Vec<&str> = split.top.iter().map(|t| t.path.as_str()).collect();
    assert_eq!(paths, ["/h/src/app", "/h/.cache", "/h/.zshrc"], "the deepest, largest first");
    assert_eq!(split_of(Path::new("/h"), root, false, walked, 9).system_bytes, 60);
}

#[test]
fn a_split_is_due_when_missing_or_old() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("disk-split.json");
    assert_eq!(read_cached(&path, 1_000), (None, true));
    let split =
        split_of(dir.path(), Root { total: 1, used: 1, free: 0 }, true, Walked::default(), 1_000);
    std::fs::write(&path, serde_json::to_vec(&split).unwrap()).unwrap();
    assert!(!read_cached(&path, 1_000 + 60_000).1);
    assert!(read_cached(&path, 1_000 + WALK_EVERY.as_millis() as u64).1);
}

#[cfg(unix)]
#[test]
fn the_walk_sorts_caches_from_the_project() {
    let home = tempfile::tempdir().unwrap();
    let h = home.path();
    let write = |rel: &str, len: usize| {
        let p = h.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, vec![7u8; len]).unwrap();
    };
    write("src/app/main.rs", 64 * 1024);
    write("src/app/node_modules/x/index.js", 128 * 1024);
    write("src/app/target/CACHEDIR.TAG", 10);
    write("src/app/target/debug/big", 256 * 1024);
    write(".cache/bun/blob", 32 * 1024);
    let walked = walk(h, Duration::from_secs(30), 1_000_000);
    assert!(walked.complete);
    assert!(walked.caches >= (128 + 256 + 32) * 1024, "{walked:?}");
    assert!(walked.project >= 64 * 1024 && walked.project < 128 * 1024, "{walked:?}");
    let cut = walk(h, Duration::from_secs(30), 3);
    assert!(!cut.complete, "the entry budget stops the walk");
}

#[test]
fn one_walk_holds_the_lock() {
    let dir = tempfile::tempdir().unwrap();
    let lock = dir.path().join("disk-split.walking");
    assert!(take_lock(&lock));
    assert!(!take_lock(&lock), "a live walk holds it");
}
