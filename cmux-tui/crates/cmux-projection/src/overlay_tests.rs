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
}

impl Fetch for Fake {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        if self.away {
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

/// Reads every lower file of `overlay` whole, 128 KiB at a time.
fn read_everything(overlay: &Overlay, manifest: &Manifest) {
    for index in 0..manifest.len() as u32 {
        let entry = manifest.entry(index).unwrap();
        if entry.kind != Kind::File {
            continue;
        }
        let mut at = 0;
        while at < entry.size {
            at += overlay.read(u64::from(index) + 1, at, 128 * 1024).unwrap().len() as u64;
        }
    }
}

/// `setup`'s files at a new version: `src/b.rs` changed on the Mac (new bytes and mtime), and a
/// new file `AA.md` sorts first at the top, so every later entry has another number.
fn setup_changed(old: &Fake) -> (Arc<Manifest>, Arc<Fake>) {
    let (_, manifest, _) = setup(false);
    let mut items = Vec::new();
    let mut files = Vec::new();
    for index in 0..manifest.len() as u32 {
        let entry = manifest.entry(index).unwrap();
        let path = manifest.path_of(index);
        if entry.kind == Kind::Dir {
            continue;
        }
        let mut item = Item {
            path: path.clone(),
            kind: entry.kind,
            mode: entry.mode,
            size: entry.size,
            mtime_ns: entry.mtime_ns,
            link: entry.link.clone(),
        };
        let mut bytes = old.bytes.get(&index).cloned();
        if path == "src/b.rs" {
            bytes = Some(b"fn b() { changed }".to_vec());
            item.size = 18;
            item.mtime_ns += 1;
        }
        items.push(item);
        if let Some(bytes) = bytes {
            files.push((path, bytes));
        }
    }
    items.push(Item {
        path: "AA.md".into(),
        kind: Kind::File,
        mode: 0o644,
        size: 3,
        mtime_ns: 5,
        link: None,
    });
    files.push(("AA.md".into(), b"new".to_vec()));
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let mut fake = Fake::default();
    for (path, bytes) in files {
        fake.bytes.insert(manifest.resolve(&path).unwrap(), bytes);
    }
    (manifest, Arc::new(fake))
}

#[test]
fn a_remount_with_a_new_manifest_fetches_only_what_changed() {
    let (state, manifest, fake) = setup(false);
    read_everything(&open(state.path(), &manifest, &fake), &manifest);
    let (changed, mac) = setup_changed(&fake);
    assert_ne!(changed.resolve("big.bin"), manifest.resolve("big.bin"), "entry numbers moved");
    let overlay = open(state.path(), &changed, &mac);
    read_everything(&overlay, &changed);
    // Only `src/b.rs` (changed) and `AA.md` (new) came from the Mac.
    let batches = mac.batches.lock().unwrap().clone();
    let fetched: Vec<String> = batches.concat().iter().map(|at| changed.path_of(*at)).collect();
    assert_eq!(fetched, ["AA.md", "src/b.rs"]);
    assert_eq!(overlay.stats().remote_bytes, 3 + 18);
    let b = path_ino(&overlay, "src/b.rs");
    assert_eq!(overlay.read(b, 0, 100).unwrap(), b"fn b() { changed }");
    let big = path_ino(&overlay, "big.bin");
    assert_eq!(overlay.read(big, BIG - 5, 100).unwrap(), big_bytes()[(BIG - 5) as usize..]);
}

#[test]
fn the_cache_stays_within_its_bound_when_everything_is_read() {
    let (state, manifest, fake) = setup(false);
    // Room for two big chunks, not the whole 9 MiB file.
    let bound = 2 * CHUNK + 1024;
    let overlay =
        Overlay::open_bounded(manifest.clone(), state.path(), fake, (1000, 1000), bound).unwrap();
    for _ in 0..2 {
        read_everything(&overlay, &manifest);
        assert!(overlay.cache_usage().bytes <= bound);
        let mut on_disk = 0;
        for sub in fs::read_dir(state.path().join("chunks")).unwrap() {
            for file in fs::read_dir(sub.unwrap().path()).unwrap() {
                on_disk += file.unwrap().metadata().unwrap().len();
            }
        }
        assert_eq!(on_disk, overlay.cache_usage().bytes);
    }
    // What the agent wrote is never evicted.
    let readme = path_ino(&overlay, "README.md");
    overlay.write(readme, 0, b"README").unwrap();
    read_everything(&overlay, &manifest);
    assert_eq!(fs::read(overlay.upper_dir().join("README.md")).unwrap(), b"README");
}

#[test]
fn a_corrupt_chunk_is_fetched_again() {
    let (state, manifest, fake) = setup(false);
    read_everything(&open(state.path(), &manifest, &fake), &manifest);
    let before = fake.calls.load(Ordering::Relaxed);
    // Flip the last byte of every cached chunk.
    for sub in fs::read_dir(state.path().join("chunks")).unwrap() {
        for file in fs::read_dir(sub.unwrap().path()).unwrap() {
            let path = file.unwrap().path();
            let mut raw = fs::read(&path).unwrap();
            *raw.last_mut().unwrap() ^= 0xff;
            fs::write(&path, raw).unwrap();
        }
    }
    let overlay = open(state.path(), &manifest, &fake);
    let a = path_ino(&overlay, "src/a.rs");
    assert_eq!(overlay.read(a, 0, 100).unwrap(), b"fn a() {}");
    let big = path_ino(&overlay, "big.bin");
    assert_eq!(overlay.read(big, BIG - 5, 100).unwrap(), big_bytes()[(BIG - 5) as usize..]);
    assert!(fake.calls.load(Ordering::Relaxed) > before, "the bad chunks came from the Mac again");
    // And the refetched bytes are cached again, sound.
    let calls = fake.calls.load(Ordering::Relaxed);
    let overlay = open(state.path(), &manifest, &fake);
    assert_eq!(overlay.read(path_ino(&overlay, "src/a.rs"), 0, 100).unwrap(), b"fn a() {}");
    assert_eq!(fake.calls.load(Ordering::Relaxed), calls);
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
