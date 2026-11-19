use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize};
use std::sync::{Arc, Mutex};
use std::thread;

use super::*;
use crate::manifest::Item;

/// Serves bytes by entry from memory and counts every call.
#[derive(Default)]
pub(crate) struct Fake {
    pub bytes: HashMap<u32, Vec<u8>>,
    pub calls: AtomicUsize,
    pub batches: Mutex<Vec<Vec<u32>>>,
    pub away: AtomicBool,
}

impl Fetch for Fake {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        if self.away.load(Ordering::Relaxed) {
            return Err(FetchError::Away);
        }
        let bytes = self.bytes.get(&entry).ok_or(FetchError::Failed)?;
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Ok(bytes[start..end].to_vec())
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        self.batches.lock().unwrap().push(entries.to_vec());
        entries
            .iter()
            .map(|entry| {
                if self.away.load(Ordering::Relaxed) {
                    Err(FetchError::Away)
                } else {
                    self.bytes.get(entry).cloned().ok_or(FetchError::Failed)
                }
            })
            .collect()
    }
}

const BIG: u64 = 9 * 1024 * 1024;

fn big_bytes() -> Vec<u8> {
    (0..BIG).map(|at| (at % 251) as u8).collect()
}

/// A three-level folder: `README.md`, `src/{a.rs,b.rs,c.rs}`, `src/deep/d.rs`, `big.bin`, and a link.
fn setup(away: bool) -> (tempfile::TempDir, Arc<Manifest>, Arc<Fake>) {
    let files: [(&str, Vec<u8>); 6] = [
        ("README.md", b"readme".to_vec()),
        ("src/a.rs", b"fn a() {}".to_vec()),
        ("src/b.rs", b"fn b() {}".to_vec()),
        ("src/c.rs", b"fn c() {}".to_vec()),
        ("src/deep/d.rs", b"fn d() {}".to_vec()),
        ("big.bin", big_bytes()),
    ];
    let mut items: Vec<Item> = files
        .iter()
        .map(|(path, bytes)| Item {
            path: (*path).into(),
            kind: Kind::File,
            mode: 0o644,
            size: bytes.len() as u64,
            mtime_ns: 1_700_000_000_000_000_000,
            link: None,
        })
        .collect();
    items.push(Item {
        path: "link".into(),
        kind: Kind::Link,
        mode: 0o777,
        size: 0,
        mtime_ns: 1,
        link: Some("README.md".into()),
    });
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let mut fake = Fake { away: AtomicBool::new(away), ..Fake::default() };
    for (path, bytes) in files {
        fake.bytes.insert(manifest.resolve(path).unwrap(), bytes);
    }
    (tempfile::tempdir().unwrap(), manifest, Arc::new(fake))
}

fn open(state: &Path, manifest: &Arc<Manifest>, fake: &Arc<Fake>) -> Overlay {
    Overlay::open(manifest.clone(), state, fake.clone(), (1000, 1000)).unwrap()
}

fn path_ino(overlay: &Overlay, path: &str) -> u64 {
    let mut ino = overlay.root();
    for name in path.split('/') {
        ino = overlay.lookup(ino, name).unwrap().ino;
    }
    ino
}

fn names(overlay: &Overlay, ino: u64) -> Vec<String> {
    overlay.readdir(ino).unwrap().into_iter().map(|(_, _, name)| name).collect()
}

#[test]
fn stat_and_listing_never_ask_the_mac() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    assert_eq!(names(&overlay, overlay.root()), ["README.md", "big.bin", "link", "src"]);
    let src = path_ino(&overlay, "src");
    assert_eq!(names(&overlay, src), ["a.rs", "b.rs", "c.rs", "deep"]);
    let deep = overlay.lookup(src, "deep").unwrap();
    assert_eq!(deep.kind, Kind::Dir);
    let big = overlay.getattr(path_ino(&overlay, "big.bin")).unwrap();
    assert_eq!((big.size, big.mode, big.uid), (BIG, 0o644, 1000));
    assert_eq!(overlay.readlink(path_ino(&overlay, "link")).unwrap(), b"README.md");
    assert_eq!(overlay.lookup(src, "nope"), Err(ENOENT));
    assert_eq!(fake.calls.load(Ordering::Relaxed), 0);
}

#[test]
fn one_read_fetches_the_folders_small_files_in_one_batch() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let a = path_ino(&overlay, "src/a.rs");
    assert_eq!(overlay.read(a, 3, 100).unwrap(), b"a() {}");
    assert_eq!(fake.calls.load(Ordering::Relaxed), 1);
    assert_eq!(fake.batches.lock().unwrap()[0].len(), 3);
    let b = path_ino(&overlay, "src/b.rs");
    assert_eq!(overlay.read(b, 0, 100).unwrap(), b"fn b() {}");
    assert_eq!(fake.calls.load(Ordering::Relaxed), 1);
    assert!(overlay.stats().cache_hits >= 1);
    assert_eq!(overlay.stats().remote_reads, 3);
}

#[test]
fn a_big_file_reads_by_chunk_across_a_boundary() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let big = path_ino(&overlay, "big.bin");
    let at = CHUNK - 10;
    let got = overlay.read(big, at, 20).unwrap();
    assert_eq!(got, big_bytes()[at as usize..at as usize + 20]);
    assert_eq!(fake.calls.load(Ordering::Relaxed), 2);
    let tail = overlay.read(big, BIG - 5, 100).unwrap();
    assert_eq!(tail, big_bytes()[(BIG - 5) as usize..]);
}

#[test]
fn a_write_copies_up_and_leaves_the_mac_alone() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let readme = path_ino(&overlay, "README.md");
    overlay.write(readme, 0, b"README").unwrap();
    assert_eq!(overlay.read(readme, 0, 100).unwrap(), b"README");
    assert_eq!(fs::read(overlay.upper_dir().join("README.md")).unwrap(), b"README");
    assert_eq!(fake.bytes[&manifest.resolve("README.md").unwrap()], b"readme");
    let attr = overlay.setattr(readme, Some(2), None, None).unwrap();
    assert_eq!(attr.size, 2);
    // A big file copies up whole.
    let big = path_ino(&overlay, "big.bin");
    overlay.write(big, BIG - 1, b"!").unwrap();
    let mut expected = big_bytes();
    *expected.last_mut().unwrap() = b'!';
    assert_eq!(fs::read(overlay.upper_dir().join("big.bin")).unwrap(), expected);
}

#[test]
fn a_deleted_lower_file_stays_deleted_after_a_reopen() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let src = path_ino(&overlay, "src");
    overlay.unlink(src, "b.rs").unwrap();
    assert_eq!(overlay.lookup(src, "b.rs"), Err(ENOENT));
    assert_eq!(names(&overlay, src), ["a.rs", "c.rs", "deep"]);
    assert_eq!(overlay.whiteouts(), ["src/b.rs"]);
    drop(overlay);
    let overlay = open(state.path(), &manifest, &fake);
    let src = path_ino(&overlay, "src");
    assert_eq!(overlay.lookup(src, "b.rs"), Err(ENOENT));
    // Making it again brings a new file, not the Mac's.
    let made = overlay.create(src, "b.rs", 0o644).unwrap();
    assert_eq!(overlay.read(made.ino, 0, 10).unwrap(), b"");
    assert!(overlay.whiteouts().is_empty());
}

#[test]
fn create_rename_and_rmdir_of_a_full_folder() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let src = path_ino(&overlay, "src");
    let new = overlay.create(src, "new.rs", 0o644).unwrap();
    overlay.write(new.ino, 0, b"new").unwrap();
    overlay.rename(src, "new.rs", overlay.root(), "moved.rs").unwrap();
    assert_eq!(overlay.lookup(src, "new.rs"), Err(ENOENT));
    let moved = overlay.lookup(overlay.root(), "moved.rs").unwrap();
    assert_eq!(moved.ino, new.ino);
    assert_eq!(overlay.read(moved.ino, 0, 10).unwrap(), b"new");
    // A lower file renamed: its bytes move, its old name is gone.
    overlay.rename(src, "a.rs", src, "z.rs").unwrap();
    assert_eq!(overlay.read(path_ino(&overlay, "src/z.rs"), 0, 100).unwrap(), b"fn a() {}");
    assert_eq!(overlay.lookup(src, "a.rs"), Err(ENOENT));
    // A lower folder cannot move in this slice.
    assert_eq!(overlay.rename(src, "deep", overlay.root(), "deep2"), Err(EXDEV));
    assert_eq!(overlay.rmdir(overlay.root(), "src"), Err(ENOTEMPTY));
    let deep = path_ino(&overlay, "src/deep");
    overlay.unlink(deep, "d.rs").unwrap();
    overlay.rmdir(src, "deep").unwrap();
    assert_eq!(overlay.lookup(src, "deep"), Err(ENOENT));
    let made = overlay.mkdir(src, "deep", 0o755).unwrap();
    assert!(overlay.readdir(made.ino).unwrap().is_empty());
}

#[test]
fn a_read_while_the_mac_is_away_fails_with_ehostdown() {
    let (state, manifest, fake) = setup(true);
    let overlay = open(state.path(), &manifest, &fake);
    let readme = path_ino(&overlay, "README.md");
    assert_eq!(overlay.read(readme, 0, 10), Err(112));
    assert_eq!(overlay.read(path_ino(&overlay, "big.bin"), 0, 10), Err(112));
}

#[test]
fn a_cached_read_survives_the_mac_going_away() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let readme = path_ino(&overlay, "README.md");
    assert_eq!(overlay.read(readme, 0, 10).unwrap(), b"readme");
    fake.away.store(true, Ordering::Relaxed);
    assert_eq!(overlay.read(readme, 0, 10).unwrap(), b"readme");
    assert!(overlay.stats().cache_hits >= 1);
    assert_eq!(overlay.read(path_ino(&overlay, "big.bin"), 0, 10), Err(112));
}

#[test]
fn a_file_made_read_only_is_still_written_through_its_create() {
    // git makes each loose object 0444 and writes it through the descriptor create returned.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let made = overlay.create(overlay.root(), "object", 0o444).unwrap();
    overlay.write(made.ino, 0, b"blob").unwrap();
    assert_eq!(overlay.read(made.ino, 0, 10).unwrap(), b"blob");
    assert_eq!(overlay.getattr(made.ino).unwrap().mode, 0o444);
}

#[test]
fn the_lower_cache_evicts_oldest_entries_before_its_budget() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("cache");
    fs::create_dir_all(&cache).unwrap();
    fs::write(cache.join("manifest-id"), b"id\n").unwrap();
    fs::write(cache.join("000-old"), b"123").unwrap();
    fs::write(cache.join("999-new"), b"567").unwrap();
    let target = cache.join("incoming");
    let mut index = CacheIndex::load(&cache).unwrap();
    assert!(index.admit(4, &target, 7));
    assert!(!cache.join("000-old").exists());
    assert!(cache.join("999-new").exists());
    assert!(cache.join("manifest-id").exists());
}

#[test]
fn cache_admission_refuses_when_an_eviction_cannot_be_completed() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("cache");
    fs::create_dir_all(&cache).unwrap();
    let blocked = cache.join("blocked");
    fs::create_dir(&blocked).unwrap();
    let target = cache.join("incoming");
    let mut index = CacheIndex::default();
    index.insert(blocked.clone(), UNIX_EPOCH, 4);
    assert!(!index.admit(4, &target, 7));
    assert!(blocked.is_dir());
    assert!(!target.exists());
}

#[test]
fn reopened_cache_index_accounts_for_admitted_bytes_and_keeps_upper_edits() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("cache");
    let upper = dir.path().join("upper");
    fs::create_dir_all(&cache).unwrap();
    fs::create_dir_all(&upper).unwrap();
    fs::write(cache.join("manifest-id"), b"id\n").unwrap();
    fs::write(cache.join("000-old"), b"123").unwrap();
    fs::write(cache.join("999-new"), b"567").unwrap();
    fs::write(upper.join("edited"), b"keep").unwrap();

    let target = cache.join("incoming");
    let mut first = CacheIndex::load(&cache).unwrap();
    assert!(first.admit(4, &target, 7));
    fs::write(&target, b"four").unwrap();
    first.insert(target.clone(), SystemTime::now(), 4);

    let mut reopened = CacheIndex::load(&cache).unwrap();
    reopened.trim(7).unwrap();
    assert_eq!(reopened.bytes, 7);
    assert!(upper.join("edited").exists());
    assert!(cache.join("manifest-id").exists());
}

#[test]
fn cache_index_trims_an_oversize_reopened_cache() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("cache");
    fs::create_dir_all(&cache).unwrap();
    fs::write(cache.join("manifest-id"), b"id\n").unwrap();
    fs::write(cache.join("000-old"), b"123").unwrap();
    fs::write(cache.join("999-new"), b"5678").unwrap();

    let mut reopened = CacheIndex::load(&cache).unwrap();
    assert_eq!(reopened.bytes, 7);
    reopened.trim(4).unwrap();
    assert_eq!(reopened.bytes, 4);
    assert!(!cache.join("000-old").exists());
    assert!(cache.join("999-new").exists());
}

#[test]
fn cache_index_trims_zero_byte_oldest_entries_before_oversize_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("cache");
    fs::create_dir_all(&cache).unwrap();
    fs::write(cache.join("manifest-id"), b"id\n").unwrap();
    fs::write(cache.join("000-zero"), b"").unwrap();
    fs::write(cache.join("001-old"), b"123").unwrap();
    fs::write(cache.join("999-new"), b"5678").unwrap();

    let mut reopened = CacheIndex::load(&cache).unwrap();
    assert_eq!(reopened.bytes, 7);
    reopened.trim(4).unwrap();
    assert_eq!(reopened.bytes, 4);
    assert!(!cache.join("000-zero").exists());
    assert!(!cache.join("001-old").exists());
    assert!(cache.join("999-new").exists());
}

#[test]
fn cache_index_load_fails_closed_when_the_cache_is_not_readable() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("cache-file");
    fs::write(&file, b"not a directory").unwrap();
    assert!(CacheIndex::load(&file).is_err());
}

#[test]
fn concurrent_cache_admissions_keep_the_index_and_files_within_budget() {
    let dir = tempfile::tempdir().unwrap();
    let cache = dir.path().join("cache");
    fs::create_dir_all(&cache).unwrap();
    fs::write(cache.join("manifest-id"), b"id\n").unwrap();
    let index = Arc::new(Mutex::new(CacheIndex::load(&cache).unwrap()));
    let threads: Vec<_> = (0..32)
        .map(|at| {
            let cache = cache.clone();
            let index = Arc::clone(&index);
            thread::spawn(move || {
                let target = cache.join(format!("{at:02}"));
                let temp = cache.join(format!("tmp-{at:02}"));
                fs::write(&temp, [at as u8]).unwrap();
                let mut index = index.lock().unwrap();
                assert!(index.admit(1, &target, 7));
                fs::rename(&temp, &target).unwrap();
                index.insert(target, SystemTime::now(), 1);
            })
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
    let index = index.lock().unwrap();
    assert!(index.bytes <= 7);
    let bytes: u64 = fs::read_dir(&cache)
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .sum();
    assert!(bytes <= 7 + fs::metadata(cache.join("manifest-id")).unwrap().len());
}
