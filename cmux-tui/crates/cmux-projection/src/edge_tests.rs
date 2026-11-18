//! Edge cases of a projected folder on the machine (RFD 0007, "Hard cases"): symlinks answered from
//! the manifest, names that differ only by case (an APFS Mac's folder on a case-sensitive Linux
//! machine), and single files past 4 GiB, read by chunk at any offset.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::manifest::{Item, Kind, Manifest};
use crate::overlay::{CHUNK, Overlay, errno};
use crate::{Fetch, FetchError};

/// A Mac whose every file's byte at `offset` is `(entry + offset) % 251`, made on demand.
#[derive(Default)]
struct Made {
    asked: AtomicU64,
}

fn byte_at(entry: u32, offset: u64) -> u8 {
    ((u64::from(entry) + offset) % 251) as u8
}

impl Fetch for Made {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        self.asked.fetch_add(u64::from(len), Ordering::Relaxed);
        Ok((0..u64::from(len)).map(|at| byte_at(entry, offset + at)).collect())
    }

    fn batch(&self, _entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        unreachable!("no small file is read here")
    }
}

fn item(path: &str, kind: Kind, size: u64, link: Option<&str>) -> Item {
    Item { path: path.into(), kind, mode: 0o644, size, mtime_ns: 1, link: link.map(Into::into) }
}

fn ino(overlay: &Overlay, path: &str) -> u64 {
    path.split('/').fold(overlay.root(), |at, name| overlay.lookup(at, name).unwrap().ino)
}

fn open(items: Vec<Item>) -> (tempfile::TempDir, Overlay, Arc<Made>) {
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let made = Arc::new(Made::default());
    let state = tempfile::tempdir().unwrap();
    let overlay = Overlay::open(manifest, state.path(), made.clone(), (1000, 1000)).unwrap();
    (state, overlay, made)
}

#[test]
fn links_are_answered_from_the_manifest_dangling_ones_too() {
    let (_state, overlay, made) = open(vec![
        item("src/main.rs", Kind::File, 3, None),
        item("current", Kind::Link, 0, Some("src")),
        item("src/alias.rs", Kind::Link, 0, Some("main.rs")),
        item("gone", Kind::Link, 0, Some("not-there.txt")),
    ]);
    assert_eq!(overlay.readlink(ino(&overlay, "current")).unwrap(), b"src");
    assert_eq!(overlay.readlink(ino(&overlay, "src/alias.rs")).unwrap(), b"main.rs");
    let gone = ino(&overlay, "gone");
    assert_eq!(overlay.getattr(gone).unwrap().kind, Kind::Link);
    assert_eq!(overlay.getattr(gone).unwrap().size, "not-there.txt".len() as u64);
    assert_eq!(overlay.readlink(gone).unwrap(), b"not-there.txt");
    // The kernel follows a link itself; reading a link's own node is refused, never fetched.
    assert_eq!(overlay.read(gone, 0, 16), Err(errno::EINVAL));
    assert_eq!(made.asked.load(Ordering::Relaxed), 0, "no link ever asked the Mac");
    // A link the agent makes lands in the upper layer, the Mac's untouched.
    let made_link = overlay.symlink(overlay.root(), "mine", std::path::Path::new("/etc")).unwrap();
    assert_eq!(overlay.readlink(made_link.ino).unwrap(), b"/etc");
}

#[test]
fn names_that_differ_only_by_case_are_two_names_on_the_machine() {
    // An APFS Mac holds one of `README.md` and `readme.md`; the machine's disk tells them apart.
    let (_state, overlay, _made) = open(vec![item("README.md", Kind::File, 3, None)]);
    let root = overlay.root();
    assert_eq!(overlay.lookup(root, "readme.md"), Err(errno::ENOENT), "a wrong-case open fails");
    let made = overlay.create(root, "Readme.md", 0o644).unwrap();
    overlay.write(made.ino, 0, b"mine").unwrap();
    let names: Vec<String> =
        overlay.readdir(root).unwrap().into_iter().map(|(_, _, name)| name).collect();
    assert_eq!(names, ["README.md", "Readme.md"]);
    assert_eq!(overlay.getattr(ino(&overlay, "README.md")).unwrap().size, 3, "the Mac's is kept");
    assert_eq!(overlay.read(made.ino, 0, 16).unwrap(), b"mine");
    // Making the Mac's own name again is refused, never an overwrite.
    assert_eq!(overlay.create(root, "README.md", 0o644).err(), Some(errno::EEXIST));
}

#[test]
fn a_file_past_4_gib_reads_by_chunk_at_any_offset() {
    let size = 5 * 1024 * 1024 * 1024 + 123;
    let (_state, overlay, made) = open(vec![item("disk.img", Kind::File, size, None)]);
    let image = ino(&overlay, "disk.img");
    assert_eq!(overlay.getattr(image).unwrap().size, size);
    let entry = 1;
    // Across the chunk boundary just past 4 GiB.
    let at = 4 * 1024 * 1024 * 1024 + CHUNK - 10;
    let bytes = overlay.read(image, at, 20).unwrap();
    let want: Vec<u8> = (0..20).map(|offset| byte_at(entry, at + offset)).collect();
    assert_eq!(bytes, want);
    assert_eq!(made.asked.load(Ordering::Relaxed), 2 * CHUNK, "two chunks, never the file");
    // The tail: a short last chunk, and a read past the end is empty.
    let tail = overlay.read(image, size - 5, 64).unwrap();
    assert_eq!(tail, (0..5).map(|offset| byte_at(entry, size - 5 + offset)).collect::<Vec<u8>>());
    assert!(overlay.read(image, size + 10, 64).unwrap().is_empty());
    // A read again comes from the machine's cache.
    let asked = made.asked.load(Ordering::Relaxed);
    assert_eq!(overlay.read(image, at, 20).unwrap(), want);
    assert_eq!(made.asked.load(Ordering::Relaxed), asked);
}
