use std::collections::HashMap;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::sync::Arc;
use std::time::{Duration, Instant};

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

/// A Mac that does not answer (a stalled link) until released.
struct Stalled {
    released: Mutex<bool>,
    changed: std::sync::Condvar,
}

impl Stalled {
    fn wait(&self) {
        let mut released = self.released.lock().unwrap();
        while !*released {
            released = self.changed.wait(released).unwrap();
        }
    }

    fn release(&self) {
        *self.released.lock().unwrap() = true;
        self.changed.notify_all();
    }
}

impl Fetch for Stalled {
    fn read(&self, _entry: u32, _offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        self.wait();
        Ok(vec![b'x'; len as usize])
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        self.wait();
        entries.iter().map(|_| Ok(b"x".to_vec())).collect()
    }
}

/// Every fetch thread held by a stalled link (more cold reads at once than threads) does not
/// hold the agent's own files: writing and reading back a file it made answers at once. It
/// waited for the link (up to its stall wait, two minutes before that existed).
#[test]
fn a_stalled_link_holding_every_fetch_does_not_hold_the_agents_own_writes() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let cold = 3 * WORKERS;
    let items = (0..cold)
        .map(|at| Item {
            path: format!("d{at}/cold.txt"),
            kind: Kind::File,
            mode: 0o644,
            size: 1,
            mtime_ns: 1_700_000_000_000_000_000,
            link: None,
        })
        .collect();
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let owner = {
        use std::os::unix::fs::MetadataExt as _;
        let meta = std::fs::metadata(state.path()).unwrap();
        (meta.uid(), meta.gid())
    };
    let stalled = Arc::new(Stalled { released: Mutex::new(false), changed: Default::default() });
    let overlay = Arc::new(Overlay::open(manifest, state.path(), stalled.clone(), owner).unwrap());
    let mounted = match mount(overlay, at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    let root = at.path().to_path_buf();
    std::fs::write(root.join("mine.txt"), "draft").unwrap();
    // Let the link go after a while whatever happens, so a failing run ends.
    let watchdog = {
        let stalled = stalled.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(5));
            stalled.release();
        })
    };
    let readers: Vec<_> = (0..cold)
        .map(|at| {
            let path = root.join(format!("d{at}/cold.txt"));
            std::thread::spawn(move || std::fs::read(path).map(|bytes| bytes.len()))
        })
        .collect();
    std::thread::sleep(Duration::from_millis(300));
    let started = Instant::now();
    std::fs::write(root.join("mine.txt"), "saved while the link is stalled").unwrap();
    assert_eq!(
        std::fs::read_to_string(root.join("mine.txt")).unwrap(),
        "saved while the link is stalled"
    );
    let took = started.elapsed();
    stalled.release();
    for reader in readers {
        assert_eq!(reader.join().unwrap().unwrap(), 1);
    }
    watchdog.join().unwrap();
    mounted.unmount();
    assert!(took < Duration::from_secs(2), "the agent's own write waited {took:?} for the link");
}

#[test]
fn idle_since_counts_whole_seconds_from_the_last_request() {
    let idle = Duration::from_secs(30);
    assert!(!idle_since(100, 129, idle));
    assert!(idle_since(100, 130, idle));
    assert!(!idle_since(200, 100, idle), "a clock that went back is not idle");
}

#[test]
fn an_idle_mount_unmounts_itself_but_never_while_a_file_is_open() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let items = vec![Item {
        path: "README.md".into(),
        kind: Kind::File,
        mode: 0o644,
        size: 5,
        mtime_ns: 1_700_000_000_000_000_000,
        link: None,
    }];
    let manifest = Arc::new(Manifest::build(1, items).unwrap());
    let bytes = HashMap::from([(manifest.resolve("README.md").unwrap(), b"hello".to_vec())]);
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let meta = std::fs::metadata(state.path()).unwrap();
    let overlay = Arc::new(
        Overlay::open(manifest, state.path(), Arc::new(Files(bytes)), (meta.uid(), meta.gid()))
            .unwrap(),
    );
    let options = Options { idle_exit: Some(Duration::from_secs(2)), ..Options::default() };
    let (up, is_up) = channel();
    let path = at.path().to_owned();
    let server = std::thread::spawn(move || {
        serve_with(overlay, &path, options, move || up.send(()).unwrap())
    });
    if is_up.recv_timeout(Duration::from_secs(10)).is_err() {
        println!("skipping: the mount never came up here");
        return;
    }
    let file = at.path().join("README.md");

    // An open file holds it well past the idle time.
    let held = std::fs::File::open(&file).unwrap();
    std::thread::sleep(Duration::from_secs(6));
    assert!(!server.is_finished(), "a mount with an open file stays");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "hello");
    drop(held);

    // Nothing holds it: the server unmounts and returns.
    let deadline = Instant::now() + Duration::from_secs(20);
    while !server.is_finished() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    assert!(server.is_finished(), "an idle mount nobody holds unmounts itself");
    server.join().unwrap().unwrap();
    assert!(!file.exists(), "the folder is empty again once unmounted");
}

fn git(dir: &Path, home: &Path, args: &[&str]) -> std::process::Output {
    std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("HOME", home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .output()
        .unwrap()
}

/// RFD 0007, hard case 7, as Leo's `~/Projects` showed it: the repository's `.git/index` is
/// rewritten on the Mac (by rename, a new inode) after the manifest. Before, the Mac answered
/// CHANGED, the read failed, and `git status` on the machine died of SIGBUS on its mapped index.
/// Now the open re-lists the index, the kernel takes its new size, and `git status` reads the new
/// index: the Mac's unstaging shows.
#[test]
fn git_status_succeeds_over_an_index_rewritten_on_the_mac_after_the_manifest() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let mac = tempfile::tempdir().unwrap();
    let repo = mac.path();
    assert!(git(repo, home.path(), &["init", "-q", "-b", "main"]).status.success());
    std::fs::write(repo.join("a.txt"), "alpha\n").unwrap();
    std::fs::write(repo.join("b.txt"), "beta\n").unwrap();
    assert!(git(repo, home.path(), &["add", "a.txt", "b.txt"]).status.success());
    assert!(git(repo, home.path(), &["commit", "-q", "-m", "one"]).status.success());
    let (manifest, source) = crate::test_mac::FolderMac::list(repo);
    let listed_index = std::fs::read(repo.join(".git/index")).unwrap();

    // On the Mac, after the manifest: git rewrites its index (unstages b.txt).
    std::thread::sleep(Duration::from_millis(20));
    assert!(git(repo, home.path(), &["rm", "--cached", "-q", "b.txt"]).status.success());
    let rewritten = std::fs::read(repo.join(".git/index")).unwrap();
    assert_ne!(rewritten.len(), listed_index.len());

    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let owner = {
        use std::os::unix::fs::MetadataExt as _;
        let meta = std::fs::metadata(state.path()).unwrap();
        (meta.uid(), meta.gid())
    };
    let overlay = Arc::new(Overlay::open(manifest, state.path(), source.linked(), owner).unwrap());
    let mounted = match mount(overlay, at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    let status = git(at.path(), home.path(), &["status", "--porcelain"]);
    let out = String::from_utf8_lossy(&status.stdout).into_owned();
    let err = String::from_utf8_lossy(&status.stderr).into_owned();
    assert!(status.status.success(), "git status failed ({:?}): {out}{err}", status.status);
    assert!(out.contains("D  b.txt") && out.contains("?? b.txt"), "the Mac's new index: {out}");
    // The index's bytes and size through the mount are the Mac's new ones.
    assert_eq!(
        std::fs::metadata(at.path().join(".git/index")).unwrap().len(),
        rewritten.len() as u64
    );

    // The Mac rewrites it again; the machine read it already, so its copy stays the session's
    // base, and git keeps working.
    std::thread::sleep(Duration::from_millis(20));
    assert!(git(repo, home.path(), &["add", "b.txt"]).status.success());
    let again = git(at.path(), home.path(), &["status", "--porcelain"]);
    assert!(again.status.success(), "{}", String::from_utf8_lossy(&again.stderr));
    mounted.unmount();
}

/// The kernel never keeps a re-listed file's old size or pages: a plain read through the mount of
/// a file changed on the Mac returns all of its new bytes, longer or shorter, whether it was
/// written in place (the round-trip matrix's "remanifest" case) or replaced by a rename.
#[test]
fn a_file_changed_on_the_mac_after_the_manifest_reads_its_new_bytes_through_the_mount() {
    if !fuse_here() {
        println!("skipping: no FUSE here (no /dev/fuse or no fusermount3)");
        return;
    }
    let mac = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(mac.path().join("src")).unwrap();
    std::fs::write(mac.path().join("src/a.txt"), "alpha\n").unwrap();
    std::fs::write(mac.path().join("src/b.txt"), "a longer file, before\n").unwrap();
    let (manifest, source) = crate::test_mac::FolderMac::list(mac.path());
    // In place, as the matrix writes it: the same inode, a new size and mtime.
    std::thread::sleep(Duration::from_millis(20));
    std::fs::write(mac.path().join("src/a.txt"), "alpha, changed on the mac after the start\n")
        .unwrap();
    crate::test_mac::rewrite(&mac.path().join("src/b.txt"), b"short\n");
    let state = tempfile::tempdir().unwrap();
    let at = tempfile::tempdir().unwrap();
    let owner = {
        use std::os::unix::fs::MetadataExt as _;
        let meta = std::fs::metadata(state.path()).unwrap();
        (meta.uid(), meta.gid())
    };
    let overlay = Arc::new(Overlay::open(manifest, state.path(), source.linked(), owner).unwrap());
    let mounted = match mount(overlay, at.path()) {
        Ok(mounted) => mounted,
        Err(error) => {
            println!("skipping: no FUSE here (mount failed: {error:#})");
            return;
        }
    };
    // Stat before any read: the manifest's size (no fault yet).
    assert_eq!(std::fs::metadata(at.path().join("src/a.txt")).unwrap().len(), 6);
    assert_eq!(
        std::fs::read_to_string(at.path().join("src/a.txt")).unwrap(),
        "alpha, changed on the mac after the start\n"
    );
    assert_eq!(std::fs::metadata(at.path().join("src/a.txt")).unwrap().len(), 42);
    assert_eq!(std::fs::read_to_string(at.path().join("src/b.txt")).unwrap(), "short\n");
    mounted.unmount();
}
