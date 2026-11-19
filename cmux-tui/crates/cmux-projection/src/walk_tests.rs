use std::collections::BTreeMap;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

use super::*;

/// Leaves out `skip/` and any `*.secret`; keeps the rest.
struct Picky;

impl Rules for Picky {
    type Skip = &'static str;
    fn folder(&self, _relative: &str, parent: &Path, name: &str) -> Option<&'static str> {
        assert!(parent.is_dir(), "{} is the folder holding {name}", parent.display());
        (name == "skip").then_some("folder")
    }
    fn entry(&self, relative: &str) -> Option<&'static str> {
        relative.ends_with(".secret").then_some("secret")
    }
}

fn walked(top: &Path, threads: usize) -> BTreeMap<String, Found<&'static str>> {
    walk(top, &Picky, threads).unwrap().into_iter().collect()
}

/// Every entry is found once, with the stat a path `lstat` gives, on one thread or many; a
/// skipped folder is never entered, a symlink goes as its text, never followed.
#[test]
fn a_walk_finds_every_entry_once_with_its_stat() {
    let root = tempfile::tempdir().unwrap();
    let top = root.path();
    let mut files = Vec::new();
    for dir in 0..20 {
        for sub in 0..5 {
            let folder = top.join(format!("d{dir}/s{sub}"));
            std::fs::create_dir_all(&folder).unwrap();
            for file in 0..7 {
                let path = folder.join(format!("f{file}"));
                std::fs::write(&path, vec![b'x'; file]).unwrap();
                files.push(format!("d{dir}/s{sub}/f{file}"));
            }
        }
    }
    std::fs::create_dir_all(top.join("skip/deep")).unwrap();
    std::fs::write(top.join("skip/deep/a"), "a").unwrap();
    std::fs::write(top.join("key.secret"), "k").unwrap();
    std::fs::set_permissions(top.join("d0/s0/f1"), std::fs::Permissions::from_mode(0o750)).unwrap();
    std::os::unix::fs::symlink("../../d1", top.join("d0/s0/up")).unwrap();
    std::os::unix::fs::symlink("/etc", top.join("out")).unwrap();
    for threads in [1, 4, 16] {
        let found = walked(top, threads);
        assert_eq!(found.len(), files.len() + 4, "{threads} threads");
        for relative in &files {
            let meta = std::fs::symlink_metadata(top.join(relative)).unwrap();
            let Some(Found::File(stat)) = found.get(relative) else {
                panic!("{relative} missing");
            };
            assert_eq!(stat.size, meta.len());
            assert_eq!(stat.mode, meta.mode() & 0o7777);
            assert_eq!((stat.dev, stat.ino), (meta.dev(), meta.ino()));
            assert_eq!(stat.mtime_ns, meta.mtime() * 1_000_000_000 + meta.mtime_nsec());
        }
        assert_eq!(found.get("skip"), Some(&Found::Skipped("folder")));
        assert_eq!(found.get("key.secret"), Some(&Found::Skipped("secret")));
        assert!(matches!(
            found.get("d0/s0/up"),
            Some(Found::Link { text: Some(text), .. }) if text == "../../d1"
        ));
        assert!(
            matches!(found.get("out"), Some(Found::Link { text: Some(text), .. }) if text == "/etc")
        );
    }
}

/// A folder that cannot be listed fails the walk, on any thread; the walk ends, never hangs.
#[test]
fn a_folder_that_cannot_be_listed_fails_the_walk() {
    // root reads every folder, whatever its mode.
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } == 0 {
        return;
    }
    let root = tempfile::tempdir().unwrap();
    for dir in 0..50 {
        std::fs::create_dir_all(root.path().join(format!("d{dir}/x"))).unwrap();
    }
    let locked = root.path().join("d25/x");
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
    let outcome = walk(root.path(), &Picky, 8);
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(outcome.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
}

/// A special file is found as one; the top being a symlink is refused.
#[test]
fn a_fifo_is_special_and_a_symlinked_top_is_refused() {
    let root = tempfile::tempdir().unwrap();
    let fifo = CString::new(root.path().join("pipe").as_os_str().as_bytes()).unwrap();
    // SAFETY: a valid C string.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o644) }, 0);
    assert_eq!(walked(root.path(), 2).get("pipe"), Some(&Found::Special));
    let link = root.path().join("link");
    std::os::unix::fs::symlink(root.path(), &link).unwrap();
    assert!(walk(&link, &Picky, 2).is_err());
}
