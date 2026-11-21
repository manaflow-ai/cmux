use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::AtomicUsize;

use super::errno::ENOSPC;
use super::*;
use crate::manifest::Item;

fn me() -> Who {
    // SAFETY: getuid and getgid have no preconditions.
    unsafe { Who { uid: libc::getuid(), gid: libc::getgid() } }
}

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
    Overlay::open(manifest.clone(), state, fake.clone(), (me().uid, me().gid)).unwrap()
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
    assert_eq!(deep.kind, Type::Dir);
    let big = overlay.getattr(path_ino(&overlay, "big.bin")).unwrap();
    assert_eq!((big.size, big.mode, big.uid), (BIG, 0o644, me().uid));
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
    let attr = overlay.setattr(readme, None, Set { size: Some(2), ..Set::default() }).unwrap();
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
    let made = overlay.create(src, "b.rs", 0o644, me()).unwrap().0;
    assert_eq!(overlay.read(made.ino, 0, 10).unwrap(), b"");
    assert!(overlay.whiteouts().is_empty());
}

#[test]
fn create_rename_and_rmdir_of_a_full_folder() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let src = path_ino(&overlay, "src");
    let new = overlay.create(src, "new.rs", 0o644, me()).unwrap().0;
    overlay.write(new.ino, 0, b"new").unwrap();
    overlay.rename(src, "new.rs", overlay.root(), "moved.rs", 0).unwrap();
    assert_eq!(overlay.lookup(src, "new.rs"), Err(ENOENT));
    let moved = overlay.lookup(overlay.root(), "moved.rs").unwrap();
    assert_eq!(moved.ino, new.ino);
    assert_eq!(overlay.read(moved.ino, 0, 10).unwrap(), b"new");
    // A lower file renamed: its bytes move, its old name is gone.
    overlay.rename(src, "a.rs", src, "z.rs", 0).unwrap();
    assert_eq!(overlay.read(path_ino(&overlay, "src/z.rs"), 0, 100).unwrap(), b"fn a() {}");
    assert_eq!(overlay.lookup(src, "a.rs"), Err(ENOENT));
    // A lower folder cannot move in this slice.
    assert_eq!(overlay.rename(src, "deep", overlay.root(), "deep2", 0), Err(EXDEV));
    assert_eq!(overlay.rmdir(overlay.root(), "src"), Err(ENOTEMPTY));
    let deep = path_ino(&overlay, "src/deep");
    overlay.unlink(deep, "d.rs").unwrap();
    overlay.rmdir(src, "deep").unwrap();
    assert_eq!(overlay.lookup(src, "deep"), Err(ENOENT));
    let made = overlay.mkdir(src, "deep", 0o755, me()).unwrap();
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
    let made = overlay.create(overlay.root(), "object", 0o444, me()).unwrap().0;
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

// Conformance (RFD 0007, 2026-11-20): each test below failed on the base (pjdfstest or fsx found
// the class) and passes with the fix.

#[test]
fn a_new_path_keeps_its_mode_bits_set_id_and_sticky_included() {
    // pjdfstest chmod/00, chmod/11, chmod/12: chmod 04777/02777/01777 read back as 0777.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let (made, _) = overlay.create(overlay.root(), "f", 0o644, me()).unwrap();
    for mode in [0o4755, 0o2755, 0o1755, 0o0111, 0o7777] {
        let set = Set { mode: Some(mode), ..Set::default() };
        assert_eq!(overlay.setattr(made.ino, None, set).unwrap().mode, mode);
    }
    let dir = overlay.mkdir(overlay.root(), "d", 0o1777, me()).unwrap();
    assert_eq!(dir.mode, 0o1777);
}

#[test]
fn times_are_their_own_and_atime_is_kept() {
    // pjdfstest utimensat/*: atime read back as mtime, ctime never moved.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let (made, _) = overlay.create(overlay.root(), "f", 0o644, me()).unwrap();
    let set = Set {
        atime: Some(SetTime::At(1_000_000_123)),
        mtime: Some(SetTime::At(2_000_000_456)),
        ..Set::default()
    };
    let attr = overlay.setattr(made.ino, None, set).unwrap();
    assert_eq!((attr.atime_ns, attr.mtime_ns), (1_000_000_123, 2_000_000_456));
    assert!(attr.ctime_ns > 2_000_000_456);
    // Before 1970 too.
    let set = Set { mtime: Some(SetTime::At(-1_500_000_000)), ..Set::default() };
    assert_eq!(overlay.setattr(made.ino, None, set).unwrap().mtime_ns, -1_500_000_000);
}

#[test]
fn fifos_sockets_and_hard_links_are_made() {
    // pjdfstest mkfifo/*, mknod/*, link/*: ENOSYS / EPERM on the base.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let fifo = overlay.mknod(overlay.root(), "p", libc::S_IFIFO | 0o640, 0, me()).unwrap();
    assert_eq!((fifo.kind, fifo.mode), (Type::Fifo, 0o640));
    let sock = overlay.mknod(overlay.root(), "s", libc::S_IFSOCK | 0o600, 0, me()).unwrap();
    assert_eq!(sock.kind, Type::Socket);
    let plain = overlay.mknod(overlay.root(), "r", libc::S_IFREG | 0o600, 0, me()).unwrap();
    assert_eq!(plain.kind, Type::File);
    // A hard link of a lower file copies it up once; both names are one file, one number.
    let readme = path_ino(&overlay, "README.md");
    let linked = overlay.link(readme, overlay.root(), "again").unwrap();
    assert_eq!(linked.nlink, 2);
    assert_eq!(overlay.getattr(readme).unwrap().ino, linked.ino);
    overlay.write(linked.ino, 0, b"R").unwrap();
    assert_eq!(overlay.read(path_ino(&overlay, "README.md"), 0, 10).unwrap(), b"Readme");
    overlay.unlink(overlay.root(), "README.md").unwrap();
    let again = overlay.lookup(overlay.root(), "again").unwrap();
    assert_eq!((again.ino, again.nlink), (linked.ino, 1));
    assert_eq!(overlay.read(again.ino, 0, 10).unwrap(), b"Readme");
}

#[test]
fn an_open_file_reads_and_writes_after_its_name_goes() {
    // pjdfstest unlink/14, fsx: a file deleted (or renamed) while open kept no bytes.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let (made, handle) = overlay.create(overlay.root(), "f", 0o644, me()).unwrap();
    overlay.write_handle(handle, made.ino, 0, b"hello").unwrap();
    overlay.unlink(overlay.root(), "f").unwrap();
    assert_eq!(overlay.read_handle(handle, made.ino, 0, 10).unwrap(), b"hello");
    overlay.write_handle(handle, made.ino, 5, b"!").unwrap();
    assert_eq!(overlay.read_handle(handle, made.ino, 0, 10).unwrap(), b"hello!");
    assert_eq!(overlay.getattr(made.ino).unwrap().nlink, 0);
    let set = Set { size: Some(2), ..Set::default() };
    assert_eq!(overlay.setattr(made.ino, Some(handle), set).unwrap().size, 2);
    overlay.release(handle);
    assert_eq!(overlay.getattr(made.ino), Err(ENOENT));
    // A lower file opened read only keeps its bytes after its name goes.
    let readme = path_ino(&overlay, "README.md");
    let handle = overlay.open_handle(readme, libc::O_RDONLY).unwrap();
    overlay.unlink(overlay.root(), "README.md").unwrap();
    assert_eq!(overlay.read_handle(handle, readme, 0, 10).unwrap(), b"readme");
    assert_eq!(overlay.getattr(readme).unwrap().nlink, 0);
    // A new file under the old name never takes the old number.
    let (again, _) = overlay.create(overlay.root(), "README.md", 0o644, me()).unwrap();
    assert_ne!(again.ino, readme);
}

#[test]
fn rename_flags_noreplace_and_exchange() {
    // pjdfstest rename/*, xfstests generic/023-025: flags refused with EINVAL on the base.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let src = path_ino(&overlay, "src");
    let noreplace = libc::RENAME_NOREPLACE;
    assert_eq!(overlay.rename(src, "a.rs", src, "b.rs", noreplace), Err(EEXIST));
    overlay.rename(src, "a.rs", src, "n.rs", noreplace).unwrap();
    let (a, b) = (path_ino(&overlay, "src/n.rs"), path_ino(&overlay, "src/b.rs"));
    overlay.rename(src, "n.rs", src, "b.rs", libc::RENAME_EXCHANGE).unwrap();
    assert_eq!(overlay.read(path_ino(&overlay, "src/b.rs"), 0, 100).unwrap(), b"fn a() {}");
    assert_eq!(overlay.read(path_ino(&overlay, "src/n.rs"), 0, 100).unwrap(), b"fn b() {}");
    assert_eq!((path_ino(&overlay, "src/b.rs"), path_ino(&overlay, "src/n.rs")), (a, b));
    assert_eq!(overlay.rename(src, "c.rs", src, "none", libc::RENAME_EXCHANGE), Err(ENOENT));
    // A folder never moves below itself.
    let made = overlay.mkdir(overlay.root(), "x", 0o755, me()).unwrap();
    overlay.mkdir(made.ino, "y", 0o755, me()).unwrap();
    assert_eq!(overlay.rename(overlay.root(), "x", path_ino(&overlay, "x/y"), "z", 0), Err(EINVAL));
}

#[test]
fn a_lower_folder_deleted_and_made_again_is_empty() {
    // pjdfstest rmdir/mkdir: the Mac's files came back under a new folder of the same name.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let src = path_ino(&overlay, "src");
    let deep = path_ino(&overlay, "src/deep");
    overlay.unlink(deep, "d.rs").unwrap();
    overlay.rmdir(src, "deep").unwrap();
    let made = overlay.mkdir(src, "deep", 0o755, me()).unwrap();
    assert!(overlay.readdir(made.ino).unwrap().is_empty());
    assert_eq!(overlay.lookup(made.ino, "d.rs"), Err(ENOENT));
    drop(overlay);
    let overlay = open(state.path(), &manifest, &fake);
    let deep = path_ino(&overlay, "src/deep");
    assert!(overlay.readdir(deep).unwrap().is_empty());
}

#[test]
fn a_name_longer_than_255_bytes_is_enametoolong() {
    // pjdfstest */02: ENOENT on the base.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let long = "x".repeat(256);
    assert_eq!(overlay.lookup(overlay.root(), &long), Err(ENAMETOOLONG));
    assert_eq!(overlay.create(overlay.root(), &long, 0o644, me()), Err(ENAMETOOLONG));
    let fits = "x".repeat(255);
    overlay.create(overlay.root(), &fits, 0o644, me()).unwrap();
}

#[test]
fn a_deep_path_longer_than_path_max_works() {
    // pjdfstest open/02-style deep trees: the upper path with the state folder in front passed
    // PATH_MAX and every call on it failed with ENAMETOOLONG on the base.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let mut at = overlay.root();
    let name = "d".repeat(200);
    for _ in 0..30 {
        at = overlay.mkdir(at, &name, 0o755, me()).unwrap().ino;
    }
    let (made, handle) = overlay.create(at, "f", 0o644, me()).unwrap();
    overlay.write_handle(handle, made.ino, 0, b"deep").unwrap();
    assert_eq!(overlay.read(made.ino, 0, 10).unwrap(), b"deep");
}

#[test]
fn a_deleted_name_with_a_newline_stays_deleted_after_a_reopen() {
    let items = vec![Item {
        path: "a\nb".into(),
        kind: Kind::File,
        mode: 0o644,
        size: 1,
        mtime_ns: 1,
        link: None,
    }];
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let fake = Arc::new(Fake::default());
    let state = tempfile::tempdir().unwrap();
    let overlay = open(state.path(), &manifest, &fake);
    overlay.unlink(overlay.root(), "a\nb").unwrap();
    drop(overlay);
    let overlay = open(state.path(), &manifest, &fake);
    assert_eq!(overlay.lookup(overlay.root(), "a\nb"), Err(ENOENT));
}

#[test]
fn an_open_folder_keeps_its_attributes_after_it_is_renamed_over() {
    // xfstests generic/035: fstat of an open folder another rename replaced answered ENOENT.
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let root = overlay.root();
    overlay.mkdir(root, "from", 0o755, me()).unwrap();
    let to = overlay.mkdir(root, "to", 0o755, me()).unwrap();
    let handle = overlay.open_handle(to.ino, libc::O_RDONLY | libc::O_DIRECTORY).unwrap();
    overlay.rename(root, "from", root, "to", 0).unwrap();
    let gone = overlay.getattr(to.ino).unwrap();
    assert_eq!((gone.kind, gone.nlink), (Type::Dir, 0));
    overlay.release(handle);
}

#[test]
fn reads_leave_access_times_alone_as_the_mount_says_noatime() {
    // xfstests generic/120: the base's reads moved atime on the disk under it (its relatime).
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let (made, handle) = overlay.create(overlay.root(), "f", 0o644, me()).unwrap();
    overlay.write_handle(handle, made.ino, 0, b"bytes").unwrap();
    overlay.release(handle);
    let old = Set { atime: Some(SetTime::At(1_000_000_000)), ..Set::default() };
    overlay.setattr(made.ino, None, old).unwrap();
    let handle = overlay.open_handle(made.ino, libc::O_RDONLY).unwrap();
    assert_eq!(overlay.read_handle(handle, made.ino, 0, 10).unwrap(), b"bytes");
    overlay.release(handle);
    assert_eq!(overlay.read(made.ino, 0, 10).unwrap(), b"bytes");
    overlay.readdir(overlay.root()).unwrap();
    assert_eq!(overlay.getattr(made.ino).unwrap().atime_ns, 1_000_000_000);
    let root_atime = overlay.getattr(overlay.root()).unwrap().atime_ns;
    overlay.readdir(overlay.root()).unwrap();
    assert_eq!(overlay.getattr(overlay.root()).unwrap().atime_ns, root_atime);
}
