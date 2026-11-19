use std::collections::HashMap;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::sync::Arc;

use super::*;
use crate::manifest::{Item, Manifest};
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
    // An upper file, read through the mount twice so its pages are kept.
    std::fs::write(root.join("src/new.rs"), b"version one").unwrap();
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
    let mut lines: Vec<&str> = text.lines().collect();
    lines.sort_unstable();
    assert_eq!(lines, ["a", "a/one.txt", "a/two.txt"]);
}
