use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::AtomicUsize;

use super::*;
use crate::manifest::Item;

/// Serves bytes by entry from memory and counts every call.
#[derive(Default)]
pub(crate) struct Fake {
    pub bytes: HashMap<u32, Vec<u8>>,
    pub calls: AtomicUsize,
    pub batches: Mutex<Vec<Vec<u32>>>,
    pub away: bool,
    /// Reads at or past this offset fail (a link that drops in the middle of a big file).
    pub fail_from: Option<u64>,
}

impl Fetch for Fake {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        if self.away {
            return Err(FetchError::Away);
        }
        if self.fail_from.is_some_and(|from| offset >= from) {
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
                if self.away {
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
    let mut fake = Fake { away, ..Fake::default() };
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
fn a_file_made_read_only_is_still_written_through_its_create() {
    // git makes each loose object 0444 and writes it through the descriptor create returned.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let made = overlay.create(overlay.root(), "object", 0o444).unwrap();
    overlay.write(made.ino, 0, b"blob").unwrap();
    assert_eq!(overlay.read(made.ino, 0, 10).unwrap(), b"blob");
    assert_eq!(overlay.getattr(made.ino).unwrap().mode, 0o444);
}

fn scratch_bytes(state: &Path) -> u64 {
    fs::read_dir(state.join("scratch"))
        .unwrap()
        .flatten()
        .map(|entry| entry.metadata().unwrap().len())
        .sum()
}

/// A copy-up that fails half way (the link dropped after the first chunk of a big file; a full
/// disk fails the same way) leaves nothing in the scratch folder: a partial copy there held its
/// space until the next mount, so a disk that filled once stayed full after the agent freed it.
#[test]
fn a_copy_up_that_fails_half_way_leaves_no_partial_file() {
    let (state, manifest, _) = setup(false);
    let mut fake = Fake { fail_from: Some(CHUNK), ..Fake::default() };
    fake.bytes.insert(manifest.resolve("big.bin").unwrap(), big_bytes());
    let fake = Arc::new(fake);
    let overlay = open(state.path(), &manifest, &fake);
    let big = path_ino(&overlay, "big.bin");
    assert_eq!(overlay.write(big, BIG - 1, b"!"), Err(FetchError::Away.errno()));
    assert_eq!(scratch_bytes(state.path()), 0, "a failed copy-up left a partial file behind");
    assert!(!overlay.upper_dir().join("big.bin").exists());
    // The first chunk it fetched stays cached, whole.
    assert_eq!(overlay.read(big, 0, 16).unwrap(), big_bytes()[..16]);
}

/// A delete whose record cannot be saved (a full disk) fails and changes nothing: the file is still
/// there now, as it is after a reopen. It was hidden in memory only, so it came back on a remount.
#[test]
fn a_delete_whose_record_cannot_be_saved_changes_nothing() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let src = path_ino(&overlay, "src");
    // The record's place is taken by a folder: saving it fails as a full disk would.
    fs::create_dir(state.path().join("whiteouts")).unwrap();
    assert!(overlay.unlink(src, "b.rs").is_err());
    assert!(overlay.lookup(src, "b.rs").is_ok(), "a failed delete hid the file anyway");
    assert!(overlay.whiteouts().is_empty());
    assert_eq!(scratch_bytes(state.path()), 0);
    fs::remove_dir(state.path().join("whiteouts")).unwrap();
    overlay.unlink(src, "b.rs").unwrap();
    assert_eq!(overlay.lookup(src, "b.rs"), Err(ENOENT));
}

/// A cache that cannot keep what it fetched (a full disk) turns directory readahead off: each read
/// fetched its whole folder again, so reading a folder of N files cost N batches of N files
/// (1.7 GB fetched for 2,000 reads of a 48 MiB machine disk in the fault matrix).
#[test]
fn a_cache_that_cannot_keep_bytes_fetches_one_file_per_read() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    // Nothing can be kept: the cache's folder is gone and a file holds its name.
    fs::remove_dir_all(state.path().join("cache")).unwrap();
    fs::write(state.path().join("cache"), b"").unwrap();
    let src = path_ino(&overlay, "src");
    let a = overlay.lookup(src, "a.rs").unwrap().ino;
    let b = overlay.lookup(src, "b.rs").unwrap().ino;
    assert_eq!(overlay.read(a, 0, 100).unwrap(), b"fn a() {}");
    assert_eq!(overlay.read(b, 0, 100).unwrap(), b"fn b() {}");
    let batches = fake.batches.lock().unwrap().clone();
    assert_eq!(batches.len(), 2);
    assert_eq!(batches[1].len(), 1, "a read with a failing cache fetched its folder again");
    assert_eq!(scratch_bytes(state.path()), 0);
}

/// A write that runs out of disk empties the cache and goes again: the cache holds only bytes the
/// Mac still has, and on a full machine it had taken the room the agent's own writes needed (the
/// fault matrix's 48 MiB disk: 44 MB of cache, and every write after the agent freed its own files
/// failed with "No space left on device").
#[test]
fn a_write_out_of_disk_empties_the_cache_and_goes_again() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let readme = path_ino(&overlay, "README.md");
    assert_eq!(overlay.read(readme, 0, 100).unwrap(), b"readme");
    let cached = |state: &Path| {
        fs::read_dir(state.join("cache"))
            .unwrap()
            .flatten()
            .filter(|entry| entry.file_name() != "manifest-id")
            .count()
    };
    assert!(cached(state.path()) > 0);
    let tries = AtomicUsize::new(0);
    let wrote = overlay
        .with_room(|| if tries.fetch_add(1, Ordering::Relaxed) == 0 { Err(ENOSPC) } else { Ok(7) });
    assert_eq!(wrote, Ok(7));
    assert_eq!(cached(state.path()), 0);
    assert!(state.path().join("cache/manifest-id").exists());
    // The bytes come back from the Mac on the next read.
    assert_eq!(overlay.read(readme, 0, 100).unwrap(), b"readme");
    // With nothing left to free, a full disk is the agent's answer.
    let overlay_empty = open(state.path(), &manifest, &fake);
    overlay_empty.free_cache();
    assert_eq!(overlay_empty.with_room(|| Err::<(), _>(ENOSPC)), Err(ENOSPC));
}

/// The cache never takes the disk's last room: bytes that would leave less than the reserve free
/// are served but not kept.
#[test]
fn the_cache_keeps_nothing_into_the_disks_reserve() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    assert!(overlay.cache_has_room(1));
    assert!(!overlay.cache_has_room(u64::MAX / 2));
}
