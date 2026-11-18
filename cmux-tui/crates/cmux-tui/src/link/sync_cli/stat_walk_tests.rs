//! The stat-only listing lists exactly what the copy lists, opens no file, and withholds a
//! secret file; `open_beneath` never crosses a symlink.

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use super::*;

fn write(top: &Path, relative: &str, bytes: &[u8]) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

/// A plain folder (no git) with what each skip rule leaves out, nested folders, symlinks, an
/// empty file and a file nobody may open.
fn fixture() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(dir.path()).unwrap().join("project");
    write(&top, "a.txt", b"hello");
    write(&top, "empty.txt", b"");
    write(&top, "nested/deep/b.txt", b"b");
    write(&top, "nested/.env", b"TOKEN=1");
    write(&top, ".ssh/config", b"Host x");
    write(&top, "node_modules/x.js", b"x");
    write(&top, "locked.bin", b"zzz");
    std::os::unix::fs::symlink("a.txt", top.join("link")).unwrap();
    std::os::unix::fs::symlink("/etc", top.join("out")).unwrap();
    let locked = top.join("locked.bin");
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
    (dir, top)
}

#[test]
fn the_listing_is_the_copys_and_reads_no_file() {
    let (_dir, top) = fixture();
    let (copy, _) = super::super::local::listed(&top, Rules::Copy, None).unwrap();
    let mut copied: Vec<String> = copy.files.keys().chain(copy.links.keys()).cloned().collect();
    copied.sort();
    let listed = listing(&top).unwrap();
    let served: Vec<String> = listed
        .entries
        .iter()
        .filter(|entry| entry.kind != Kind::Withheld)
        .map(|entry| entry.path.clone())
        .collect();
    assert_eq!(served, copied);
    assert_eq!(
        served,
        ["a.txt", "empty.txt", "link", "locked.bin", "nested/deep/b.txt"].map(String::from)
    );
    let entry = |path: &str| listed.entries.iter().find(|e| e.path == path).unwrap().clone();
    // A file no one may open is listed with its real size: nothing was opened.
    let locked = entry("locked.bin");
    assert_eq!((locked.kind, locked.times.size, locked.times.mode), (Kind::File, 3, 0));
    assert_eq!(entry("empty.txt").times.size, 0);
    assert_eq!(entry("link").kind, Kind::Link("a.txt".into()));
    let secret = entry("nested/.env");
    assert_eq!((secret.kind, secret.times.size), (Kind::Withheld, 7));
    // `.ssh/`, `node_modules/`, `out` and the withheld `.env`, which is listed.
    assert_eq!(copy.skips.total() + copy.skipped, 4);
    assert_eq!(listed.skipped, 3);
    let real = std::fs::symlink_metadata(top.join("a.txt")).unwrap();
    assert_eq!(entry("a.txt").times, times_of(&real));
}

#[test]
fn open_beneath_never_crosses_a_symlink() {
    let (_dir, top) = fixture();
    let outside = top.parent().unwrap().join("outside");
    write(&outside, "deep/b.txt", b"outside");
    assert!(matches!(open_beneath(&top, "nested/deep/b.txt").unwrap(), Opened::File(_)));
    std::fs::rename(top.join("nested/deep"), top.join("nested/deep-old")).unwrap();
    std::os::unix::fs::symlink(outside.join("deep"), top.join("nested/deep")).unwrap();
    assert!(matches!(open_beneath(&top, "nested/deep/b.txt").unwrap(), Opened::Gone));
    std::fs::remove_file(top.join("a.txt")).unwrap();
    std::os::unix::fs::symlink(outside.join("deep/b.txt"), top.join("a.txt")).unwrap();
    assert!(matches!(open_beneath(&top, "a.txt").unwrap(), Opened::Gone));
    assert!(matches!(open_beneath(&top, "missing/x").unwrap(), Opened::Gone));
    assert!(matches!(open_beneath(&top, "nested").unwrap(), Opened::Gone));
}
