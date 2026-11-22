use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::AtomicUsize;

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

#[test]
fn whiteouts_are_appended_and_a_torn_last_line_is_ignored() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let src = path_ino(&overlay, "src");
    overlay.unlink(src, "a.rs").unwrap();
    overlay.unlink(src, "b.rs").unwrap();
    let file = state.path().join("whiteouts");
    assert_eq!(fs::read_to_string(&file).unwrap(), "src/a.rs\0src/b.rs\0");
    // Making one again takes it out: the file is rewritten from what is left.
    overlay.create(src, "a.rs", 0o644, me()).unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), "src/b.rs\0");
    drop(overlay);
    // A crash inside an append left half an entry: it is not a whiteout (it would hide `src`).
    fs::write(&file, "src/b.rs\0sr").unwrap();
    let overlay = open(state.path(), &manifest, &fake);
    assert_eq!(overlay.whiteouts(), ["src/b.rs"]);
    assert_eq!(names(&overlay, path_ino(&overlay, "src")), ["a.rs", "c.rs", "deep"]);
    // The torn tail is cut at the open, so the next append starts an entry of its own.
    assert_eq!(fs::read_to_string(&file).unwrap(), "src/b.rs\0");
    overlay.unlink(path_ino(&overlay, "src"), "c.rs").unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), "src/b.rs\0src/c.rs\0");
    drop(overlay);
    let overlay = open(state.path(), &manifest, &fake);
    assert_eq!(overlay.whiteouts(), ["src/b.rs", "src/c.rs"]);
    drop(overlay);
    // An older file of newline-ended lines (a torn last one too) reads, and is written again in
    // NUL-ended entries before anything is appended to it.
    fs::write(&file, "src/b.rs\nsrc/c.rs\nsr").unwrap();
    let overlay = open(state.path(), &manifest, &fake);
    assert_eq!(overlay.whiteouts(), ["src/b.rs", "src/c.rs"]);
    assert_eq!(fs::read_to_string(&file).unwrap(), "src/b.rs\0src/c.rs\0");
}

#[test]
fn a_cached_big_file_reads_back_any_range_without_the_mac() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let big = path_ino(&overlay, "big.bin");
    let expected = big_bytes();
    let mut at = 0u64;
    while at < BIG {
        let bytes = overlay.read(big, at, 128 * 1024).unwrap();
        assert_eq!(bytes, expected[at as usize..(at as usize + bytes.len())]);
        at += bytes.len() as u64;
    }
    let calls = fake.calls.load(Ordering::Relaxed);
    // Ranges inside one cached chunk and across a chunk boundary, all from the disk cache.
    let edge = CHUNK - 10;
    assert_eq!(overlay.read(big, edge, 20).unwrap(), expected[edge as usize..edge as usize + 20]);
    assert_eq!(overlay.read(big, BIG - 5, 100).unwrap(), expected[(BIG - 5) as usize..]);
    let readme = path_ino(&overlay, "README.md");
    assert_eq!(overlay.read(readme, 2, 3).unwrap(), b"adm");
    assert_eq!(overlay.read(readme, 2, 3).unwrap(), b"adm");
    assert_eq!(fake.calls.load(Ordering::Relaxed), calls + 1, "only README.md's first read asks");
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

#[test]
fn a_torn_append_inside_a_multi_byte_name_keeps_the_other_whiteouts() {
    let (state, manifest, fake) = setup(false);
    let file = state.path().join("whiteouts");
    // The crash cut `src/é.rs` between the two bytes of `é`: the file is not valid UTF-8.
    fs::write(&file, b"src/b.rs\0src/c.rs\0src/\xc3").unwrap();
    let overlay = open(state.path(), &manifest, &fake);
    assert_eq!(overlay.whiteouts(), ["src/b.rs", "src/c.rs"]);
    assert_eq!(fs::read(&file).unwrap(), b"src/b.rs\0src/c.rs\0");
    drop(overlay);
    // A whole entry that is not UTF-8 is skipped alone, not the file with it.
    fs::write(&file, b"src/b.rs\0src/\xff.rs\0src/c.rs\0").unwrap();
    let overlay = open(state.path(), &manifest, &fake);
    assert_eq!(overlay.whiteouts(), ["src/b.rs", "src/c.rs"]);
}

#[test]
fn a_whiteouts_file_that_cannot_be_read_fails_the_open() {
    let (state, manifest, fake) = setup(false);
    // Not there: no whiteouts. There and unreadable: no open, never an empty set.
    fs::create_dir(state.path().join("whiteouts")).unwrap();
    let opened = Overlay::open(manifest, state.path(), fake, (me().uid, me().gid));
    assert!(opened.is_err());
}

#[test]
fn a_failed_append_leaves_no_torn_entry() {
    let state = tempfile::tempdir().unwrap();
    let path = state.path().join("whiteouts");
    fs::write(&path, b"src/a.rs\0").unwrap();
    // A write that lands half its bytes, then fails (a full disk).
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    let half = |file: &mut fs::File, bytes: &[u8]| -> std::io::Result<()> {
        file.write_all(&bytes[..bytes.len() / 2])?;
        Err(std::io::Error::from_raw_os_error(libc::ENOSPC))
    };
    assert!(append_entry(&mut file, b"src/b.rs\0", half).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"src/a.rs\0");
    append_entry(&mut file, b"src/c.rs\0", |file, bytes| file.write_all(bytes)).unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"src/a.rs\0src/c.rs\0");
}

#[test]
fn a_create_whose_whiteout_cannot_go_leaves_nothing_behind() {
    let (state, manifest, fake) = setup(false);
    let overlay = open(state.path(), &manifest, &fake);
    let src = path_ino(&overlay, "src");
    overlay.unlink(src, "a.rs").unwrap();
    // The whiteouts file can no longer be written again (a folder in its place).
    let file = state.path().join("whiteouts");
    fs::remove_file(&file).unwrap();
    fs::create_dir(&file).unwrap();
    assert!(overlay.create(src, "a.rs", 0o644, me()).is_err());
    assert!(!overlay.upper_dir().join("src/a.rs").exists(), "the new upper file is gone");
    // The lower file stays deleted, as the file on disk still says.
    assert_eq!(overlay.lookup(src, "a.rs"), Err(ENOENT));
    assert_eq!(overlay.whiteouts(), ["src/a.rs"]);
}
