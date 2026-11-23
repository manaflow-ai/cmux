use std::collections::HashMap;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::sync::Arc;

use super::*;
use crate::manifest::{Item, Kind, Manifest};
use crate::{Fetch, FetchError};

struct Files(HashMap<u32, Vec<u8>>);

impl Fetch for Files {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let bytes = self.0.get(&entry).ok_or(FetchError::Failed)?;
        let start = (offset as usize).min(bytes.len());
        let end = (start + len as usize).min(bytes.len());
        Ok(bytes[start..end].to_vec())
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        entries.iter().map(|entry| self.0.get(entry).cloned().ok_or(FetchError::Failed)).collect()
    }
}

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && std::process::Command::new("fusermount3")
            .arg("--version")
            .output()
            .is_ok_and(|output| output.status.success())
}

#[test]
fn a_mounted_projection_reads_writes_and_deletes_with_plain_file_calls() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let files =
        [("README.md", b"hello from the mac".to_vec()), ("src/main.rs", b"fn main() {}".to_vec())];
    let items = files
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
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let bytes = files
        .iter()
        .map(|(path, bytes)| (manifest.resolve(path).unwrap(), bytes.clone()))
        .collect();
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let uid = std::fs::metadata(state.path()).map(|meta| {
        use std::os::unix::fs::MetadataExt as _;
        (meta.uid(), meta.gid())
    });
    let overlay = Arc::new(
        Overlay::open(manifest, state.path(), Arc::new(Files(bytes)), uid.unwrap()).unwrap(),
    );
    let mounted = match mount(overlay.clone(), at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    let root = at.path();
    let mut names: Vec<String> = std::fs::read_dir(root)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["README.md", "src"]);
    assert_eq!(std::fs::read_to_string(root.join("README.md")).unwrap(), "hello from the mac");
    assert_eq!(std::fs::read_to_string(root.join("src/main.rs")).unwrap(), "fn main() {}");
    std::fs::write(root.join("src/new.rs"), "fn new() {}").unwrap();
    assert_eq!(std::fs::read_to_string(root.join("src/new.rs")).unwrap(), "fn new() {}");
    std::fs::write(root.join("README.md"), "edited on the machine").unwrap();
    assert_eq!(std::fs::read_to_string(root.join("README.md")).unwrap(), "edited on the machine");
    std::fs::remove_file(root.join("src/main.rs")).unwrap();
    assert!(!root.join("src/main.rs").exists());
    assert_eq!(overlay.whiteouts(), ["src/main.rs"]);
    mounted.unmount();
    println!("mounted, read, wrote and deleted through FUSE");
}

/// A manifest of `files` (one mtime for all) and an overlay of it on `state`, mounted at `at`.
fn mounted(
    files: &[(&str, &[u8])],
    mtime_ns: i64,
    state: &Path,
    at: &Path,
) -> Option<(Arc<Overlay>, Mounted)> {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return None;
    }
    let items = files
        .iter()
        .map(|(path, bytes)| Item {
            path: (*path).into(),
            kind: Kind::File,
            mode: 0o644,
            size: bytes.len() as u64,
            mtime_ns,
            link: None,
        })
        .collect();
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let bytes = files
        .iter()
        .map(|(path, bytes)| (manifest.resolve(path).unwrap(), bytes.to_vec()))
        .collect();
    let owner = std::fs::metadata(state).map(|meta| {
        use std::os::unix::fs::MetadataExt as _;
        (meta.uid(), meta.gid())
    });
    let overlay =
        Arc::new(Overlay::open(manifest, state, Arc::new(Files(bytes)), owner.unwrap()).unwrap());
    match mount(overlay.clone(), at) {
        Ok(mounted) => Some((overlay, mounted)),
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            None
        }
    }
}

#[test]
fn an_unchanged_file_is_read_from_the_kernel_cache_across_opens() {
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let big = vec![7u8; 6 * 1024 * 1024];
    let Some((overlay, mounted)) =
        mounted(&[("notes/a.md", b"note a"), ("media/big.bin", &big)], 1, state.path(), at.path())
    else {
        return;
    };
    let root = at.path();
    assert_eq!(std::fs::read(root.join("notes/a.md")).unwrap(), b"note a");
    assert_eq!(std::fs::read(root.join("media/big.bin")).unwrap(), big);
    let served = overlay.stats();
    for _ in 0..3 {
        assert_eq!(std::fs::read(root.join("notes/a.md")).unwrap(), b"note a");
        assert_eq!(std::fs::read(root.join("media/big.bin")).unwrap(), big);
    }
    // The later opens kept the pages: no read reached the overlay (not even its disk cache).
    assert_eq!(overlay.stats(), served);
    mounted.unmount();
}

#[test]
fn a_changed_upper_file_is_never_served_stale_from_the_kept_cache() {
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let Some((overlay, mounted)) =
        mounted(&[("src/lower.rs", b"fn lower() {}")], 1, state.path(), at.path())
    else {
        return;
    };
    let root = at.path();
    let upper = overlay.upper_dir().to_path_buf();
    // An upper file, read through the mount twice (kept once its change is a second old).
    std::fs::write(root.join("src/new.rs"), b"version one").unwrap();
    std::thread::sleep(Duration::from_millis(1100));
    for _ in 0..2 {
        assert_eq!(std::fs::read(root.join("src/new.rs")).unwrap(), b"version one");
    }
    // Changed on the machine's disk, outside the mount: same size, then another size.
    std::fs::write(upper.join("src/new.rs"), b"version two").unwrap();
    assert_eq!(std::fs::read(root.join("src/new.rs")).unwrap(), b"version two");
    std::fs::write(upper.join("src/new.rs"), b"version three, longer").unwrap();
    assert_eq!(std::fs::read(root.join("src/new.rs")).unwrap(), b"version three, longer");
    // A lower file with kept pages, then an upper file put over it outside the mount.
    for _ in 0..2 {
        assert_eq!(std::fs::read(root.join("src/lower.rs")).unwrap(), b"fn lower() {}");
    }
    std::fs::write(upper.join("src/lower.rs"), b"fn upper() {}").unwrap();
    assert_eq!(std::fs::read(root.join("src/lower.rs")).unwrap(), b"fn upper() {}");
    // An edit through the mount, read back through it.
    std::fs::write(root.join("src/lower.rs"), b"fn edited() { 1 }").unwrap();
    assert_eq!(std::fs::read(root.join("src/lower.rs")).unwrap(), b"fn edited() { 1 }");
    assert_eq!(std::fs::read(upper.join("src/lower.rs")).unwrap(), b"fn edited() { 1 }");
    mounted.unmount();
}

#[test]
fn a_re_manifested_file_is_never_served_stale() {
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let Some((_, first)) = mounted(&[("doc.md", b"first version")], 1, state.path(), at.path())
    else {
        return;
    };
    for _ in 0..2 {
        assert_eq!(std::fs::read(at.path().join("doc.md")).unwrap(), b"first version");
    }
    first.unmount();
    // The Mac sends a new manifest for the same projection (same state folder): same size, then
    // another size.
    let Some((_, second)) = mounted(&[("doc.md", b"secnd version")], 2, state.path(), at.path())
    else {
        return;
    };
    assert_eq!(std::fs::read(at.path().join("doc.md")).unwrap(), b"secnd version");
    second.unmount();
    let Some((_, third)) =
        mounted(&[("doc.md", b"third version, longer")], 3, state.path(), at.path())
    else {
        return;
    };
    assert_eq!(std::fs::read(at.path().join("doc.md")).unwrap(), b"third version, longer");
    third.unmount();
}

#[test]
fn creates_writes_and_deletes_keep_the_overlay_right() {
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let Some((overlay, mounted)) =
        mounted(&[("a/one.txt", b"one"), ("a/two.txt", b"two")], 1, state.path(), at.path())
    else {
        return;
    };
    let root = at.path();
    // Many creates in new folders (the first create in a folder makes it), each written twice
    // through its create's handle.
    for folder in 0..3 {
        std::fs::create_dir_all(root.join(format!("new/d{folder}"))).unwrap();
        for file in 0..20 {
            use std::io::Write as _;
            let path = root.join(format!("new/d{folder}/f{file}"));
            let mut handle =
                std::fs::OpenOptions::new().write(true).create_new(true).open(&path).unwrap();
            handle.write_all(b"head ").unwrap();
            handle.write_all(format!("{folder}-{file}").as_bytes()).unwrap();
            // As tar does: the time through the handle (`futimens`), then a mode by path.
            handle.set_modified(UNIX_EPOCH + Duration::from_secs(1_600_000_000)).unwrap();
        }
    }
    let upper_meta = std::fs::metadata(overlay.upper_dir().join("new/d2/f3")).unwrap();
    assert_eq!(upper_meta.modified().unwrap(), UNIX_EPOCH + Duration::from_secs(1_600_000_000));
    assert_eq!(
        std::fs::metadata(root.join("new/d2/f3")).unwrap().modified().unwrap(),
        upper_meta.modified().unwrap()
    );
    std::fs::set_permissions(root.join("new/d2/f3"), std::fs::Permissions::from_mode(0o600))
        .unwrap();
    assert_eq!(std::fs::metadata(root.join("new/d2/f3")).unwrap().mode() & 0o777, 0o600);
    std::fs::write(root.join("a/three.txt"), b"three").unwrap();
    assert_eq!(std::fs::read(root.join("new/d2/f19")).unwrap(), b"head 2-19");
    assert_eq!(
        std::fs::read(overlay.upper_dir().join("new/d1/f7")).unwrap(),
        b"head 1-7",
        "the bytes are on the upper folder's disk when the write returns"
    );
    // A create over a lower file is refused, as on any file system.
    let exists =
        std::fs::OpenOptions::new().write(true).create_new(true).open(root.join("a/one.txt"));
    assert_eq!(exists.unwrap_err().kind(), std::io::ErrorKind::AlreadyExists);
    // Deletes: upper files, a lower file, folders; unlink of a folder and rmdir of a full one fail.
    assert!(std::fs::remove_file(root.join("new/d0")).is_err());
    assert!(std::fs::remove_dir(root.join("new/d0")).is_err());
    assert!(std::fs::remove_dir(root.join("a")).is_err());
    std::fs::remove_dir_all(root.join("new")).unwrap();
    std::fs::remove_file(root.join("a/one.txt")).unwrap();
    assert_eq!(
        std::fs::remove_file(root.join("a/one.txt")).unwrap_err().kind(),
        std::io::ErrorKind::NotFound
    );
    assert!(!root.join("new").exists());
    let mut names: Vec<String> = std::fs::read_dir(root.join("a"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["three.txt", "two.txt"]);
    std::fs::remove_file(root.join("a/two.txt")).unwrap();
    std::fs::remove_file(root.join("a/three.txt")).unwrap();
    std::fs::remove_dir(root.join("a")).unwrap();
    assert_eq!(overlay.whiteouts(), ["a", "a/one.txt", "a/two.txt"]);
    mounted.unmount();
    // The appended whiteouts file reads back the same.
    let text = std::fs::read_to_string(state.path().join("whiteouts")).unwrap();
    let mut lines: Vec<&str> = text.split_terminator('\0').collect();
    lines.sort_unstable();
    assert_eq!(lines, ["a", "a/one.txt", "a/two.txt"]);
}

#[test]
fn an_upper_file_changed_under_a_second_ago_is_never_kept() {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() as i64;
    let upper = |ctime_ns| Version::Upper { dev: 1, ino: 2, size: 3, mtime_ns: 4, ctime_ns };
    assert!(racy(&upper(now)));
    assert!(racy(&upper(now - 500_000_000)));
    assert!(!racy(&upper(now - 2_000_000_000)));
    assert!(!racy(&Version::Lower { entry: 1, size: 3, mtime_ns: now }));
}

/// Names an open folder stream reads, from where it is.
fn read_names(stream: *mut libc::DIR) -> Vec<String> {
    let mut names = Vec::new();
    loop {
        // SAFETY: `stream` is open; the entry lives until the next readdir.
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            return names;
        }
        // SAFETY: a non-null entry holds a NUL-terminated name.
        let name = unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()) };
        names.push(name.to_string_lossy().into_owned());
    }
}

#[test]
fn rewinddir_lists_names_made_since_the_folder_was_opened() {
    // xfstests generic/471: the base pages the listing taken at opendir, so the names made after
    // it never show.
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let manifest = Arc::new(Manifest::build(1, Vec::new()).unwrap());
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    // SAFETY: getuid and getgid have no preconditions.
    let owner = unsafe { (libc::getuid(), libc::getgid()) };
    let overlay = Arc::new(
        Overlay::open(manifest, state.path(), Arc::new(Files(HashMap::new())), owner).unwrap(),
    );
    let mounted = match mount(overlay, at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    let dir = at.path().join("d");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join("first"), "").unwrap();
    let c = std::ffi::CString::new(dir.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid C string; the stream is checked and closed below.
    let stream = unsafe { libc::opendir(c.as_ptr()) };
    assert!(!stream.is_null());
    assert!(read_names(stream).contains(&"first".to_owned()));
    std::fs::write(dir.join("second"), "").unwrap();
    // SAFETY: `stream` is open.
    unsafe { libc::rewinddir(stream) };
    let names = read_names(stream);
    // SAFETY: `stream` is open and closed once.
    unsafe { libc::closedir(stream) };
    assert!(names.contains(&"second".to_owned()), "rewinddir sees a name made since: {names:?}");
    mounted.unmount();
}

#[test]
fn a_version_seen_while_racy_never_earns_the_kept_cache() {
    let state = tempfile::tempdir().unwrap();
    let items = vec![Item {
        path: "lower.txt".into(),
        kind: Kind::File,
        mode: 0o644,
        size: 1,
        mtime_ns: 1,
        link: None,
    }];
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let owner = (std::fs::metadata(state.path()).unwrap().uid(), 0);
    let overlay =
        Overlay::open(manifest, state.path(), Arc::new(Files(HashMap::new())), owner).unwrap();
    // An upper file changed just now: its version is racy at this open.
    std::fs::write(overlay.upper_dir().join("lower.txt"), b"x").unwrap();
    let ino = overlay.lookup(overlay.root(), "lower.txt").unwrap().ino;
    let (versions, notifier) = (Mutex::new(HashMap::new()), OnceLock::new());
    assert_eq!(open_flags(&overlay, &versions, &notifier, ino), 0);
    std::thread::sleep(Duration::from_millis(1100));
    // The racy sighting proved nothing: this open is the first that counts.
    assert_eq!(open_flags(&overlay, &versions, &notifier, ino), 0);
    assert_eq!(open_flags(&overlay, &versions, &notifier, ino), FOPEN_KEEP_CACHE);
}

#[test]
fn a_listing_hands_the_kernel_each_entrys_stat_as_a_lookup_would() {
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let mtime_ns = 1_700_000_000_123_456_789;
    let files: &[(&str, &[u8])] =
        &[("a.txt", b"one"), ("b/c.rs", b"fn c() {}"), ("b/d/e.md", b"# e"), ("f", b"")];
    let Some((_overlay, mounted)) = mounted(files, mtime_ns, state.path(), at.path()) else {
        return;
    };
    let root = at.path();
    // An upper file beside the lower ones, listed in the same folder.
    std::fs::write(root.join("b/new.rs"), "fn new() {}").unwrap();
    // Walk first (READDIRPLUS fills the kernel's entries), then stat every name the walk saw.
    let mut seen = Vec::new();
    let mut folders = vec![root.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in std::fs::read_dir(&folder).unwrap() {
            let entry = entry.unwrap();
            let kind = entry.file_type().unwrap();
            if kind.is_dir() {
                folders.push(entry.path());
            }
            seen.push((entry.path(), kind.is_dir()));
        }
    }
    seen.sort();
    let rel: Vec<_> =
        seen.iter().map(|(path, _)| path.strip_prefix(root).unwrap().to_owned()).collect();
    assert_eq!(
        rel,
        ["a.txt", "b", "b/c.rs", "b/d", "b/d/e.md", "b/new.rs", "f"].map(std::path::PathBuf::from)
    );
    let mut inodes = std::collections::HashSet::new();
    for (path, is_dir) in &seen {
        let meta = std::fs::symlink_metadata(path).unwrap();
        assert_eq!(meta.is_dir(), *is_dir, "{path:?}");
        assert!(inodes.insert(meta.ino()), "{path:?} shares an inode");
        let name = path.strip_prefix(root).unwrap().to_str().unwrap();
        if name == "b/new.rs" {
            assert_eq!(meta.len(), 11);
        } else if let Some((_, bytes)) = files.iter().find(|(file, _)| *file == name) {
            assert_eq!(meta.len(), bytes.len() as u64, "{name}");
            assert_eq!(meta.mode() & 0o7777, 0o644, "{name}");
            assert_eq!(meta.mtime_nsec(), mtime_ns % 1_000_000_000, "{name}");
        }
    }
    // A name deleted after a listing is gone for stat, and a fresh listing leaves it out.
    std::fs::remove_file(root.join("b/c.rs")).unwrap();
    assert!(std::fs::symlink_metadata(root.join("b/c.rs")).is_err());
    let mut names: Vec<String> = std::fs::read_dir(root.join("b"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["d", "new.rs"]);
    mounted.unmount();
}

#[test]
fn a_cached_manifest_folder_listing_shows_every_change_made_through_the_mount() {
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let files: &[(&str, &[u8])] = &[("d/a.rs", b"a"), ("d/b.rs", b"b"), ("d/sub/c.rs", b"c")];
    let Some((_overlay, mounted)) =
        mounted(files, 1_700_000_000_000_000_000, state.path(), at.path())
    else {
        return;
    };
    let folder = at.path().join("d");
    let names = || {
        let mut names: Vec<String> = std::fs::read_dir(&folder)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    };
    // Listed twice: the second comes from the kernel's cache of this manifest-only folder.
    assert_eq!(names(), ["a.rs", "b.rs", "sub"]);
    assert_eq!(names(), ["a.rs", "b.rs", "sub"]);
    std::fs::write(folder.join("new.rs"), "n").unwrap();
    assert_eq!(names(), ["a.rs", "b.rs", "new.rs", "sub"]);
    std::fs::rename(folder.join("a.rs"), folder.join("z.rs")).unwrap();
    assert_eq!(names(), ["b.rs", "new.rs", "sub", "z.rs"]);
    std::fs::remove_file(folder.join("b.rs")).unwrap();
    assert_eq!(names(), ["new.rs", "sub", "z.rs"]);
    std::fs::remove_file(folder.join("sub/c.rs")).unwrap();
    std::fs::remove_dir(folder.join("sub")).unwrap();
    assert_eq!(names(), ["new.rs", "z.rs"]);
    // A rename into another manifest-only folder shows in both listings.
    std::fs::create_dir(folder.join("e")).unwrap();
    std::fs::rename(folder.join("z.rs"), folder.join("e/z.rs")).unwrap();
    assert_eq!(names(), ["e", "new.rs"]);
    mounted.unmount();
}
