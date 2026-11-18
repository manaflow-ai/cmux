//! Reading an overlay upper directory into a change set.

mod common;

use std::os::unix::fs::symlink;
use std::path::Path;
use std::process::Command;

use cmux_projfs::upper::{Change, ChangeKind, read_upper};
use common::TempDir;

fn change(path: &str, kind: ChangeKind) -> Change {
    Change { path: path.into(), kind }
}

/// Creates a whiteout (character device 0/0). Needs privilege; returns why it could not.
fn whiteout(path: &Path) -> Result<(), String> {
    let out = Command::new("mknod")
        .arg(path)
        .args(["c", "0", "0"])
        .output()
        .map_err(|e| format!("mknod not runnable: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_owned())
    }
}

/// Sets a `user.` extended attribute (through Python, which every builder has), if the
/// filesystem allows it; returns why it could not.
fn set_mark(path: &Path, name: &str, value: &str) -> Result<(), String> {
    let out = Command::new("python3")
        .args([
            "-I",
            "-c",
            "import os, sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode(), follow_symlinks=False)",
        ])
        .arg(path)
        .args([name, value])
        .output()
        .map_err(|e| format!("python3 not runnable: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_owned())
    }
}

#[test]
fn files_symlinks_and_directories_are_reported_sorted() {
    let dir = TempDir::new("upper-basic");
    let up = dir.path();
    std::fs::create_dir_all(up.join("src/new")).unwrap();
    std::fs::write(up.join("src/main.rs"), b"fn main() {}").unwrap();
    std::fs::write(up.join("src/new/a.txt"), b"a").unwrap();
    std::fs::write(up.join("README.md"), b"hi").unwrap();
    symlink("src/main.rs", up.join("link")).unwrap();
    let got = read_upper(up).unwrap();
    assert_eq!(
        got,
        vec![
            change("README.md", ChangeKind::File),
            change("link", ChangeKind::Symlink("src/main.rs".into())),
            change("src", ChangeKind::Dir),
            change("src/main.rs", ChangeKind::File),
            change("src/new", ChangeKind::Dir),
            change("src/new/a.txt", ChangeKind::File),
        ]
    );
    assert_eq!(read_upper(up).unwrap(), got, "deterministic");
}

#[test]
fn whiteouts_are_deletes() {
    let dir = TempDir::new("upper-whiteout");
    let up = dir.path();
    std::fs::create_dir(up.join("d")).unwrap();
    if let Err(why) = whiteout(&up.join("d/removed.txt")) {
        eprintln!(
            "SKIPPED whiteouts_are_deletes: cannot create a 0/0 character device here ({why})"
        );
        return;
    }
    std::fs::write(up.join("d/kept.txt"), b"x").unwrap();
    assert_eq!(
        read_upper(up).unwrap(),
        vec![
            change("d", ChangeKind::Dir),
            change("d/kept.txt", ChangeKind::File),
            change("d/removed.txt", ChangeKind::Delete),
        ]
    );
}

#[test]
fn opaque_redirect_and_metacopy_marks() {
    if !cfg!(target_os = "linux") {
        eprintln!("SKIPPED opaque_redirect_and_metacopy_marks: overlay marks are Linux xattrs");
        return;
    }
    let dir = TempDir::new("upper-marks");
    let up = dir.path();
    std::fs::create_dir_all(up.join("replaced/inner")).unwrap();
    std::fs::create_dir(up.join("moved")).unwrap();
    std::fs::write(up.join("chmodded"), b"").unwrap();
    std::fs::write(up.join("replaced/inner/f"), b"f").unwrap();
    let marks = [
        (up.join("replaced"), "user.overlay.opaque", "y"),
        (up.join("moved"), "user.overlay.redirect", "/old/place"),
        (up.join("chmodded"), "user.overlay.metacopy", "y"),
    ];
    for (path, name, value) in &marks {
        if let Err(why) = set_mark(path, name, value) {
            eprintln!("SKIPPED opaque_redirect_and_metacopy_marks: cannot set {name} here ({why})");
            return;
        }
    }
    assert_eq!(
        read_upper(up).unwrap(),
        vec![
            change("chmodded", ChangeKind::MetadataOnly),
            change("moved", ChangeKind::Redirect("/old/place".into())),
            change("replaced", ChangeKind::OpaqueDir),
            change("replaced/inner", ChangeKind::Dir),
            change("replaced/inner/f", ChangeKind::File),
        ]
    );
}

#[test]
fn an_opaque_mark_other_than_y_is_a_plain_directory() {
    if !cfg!(target_os = "linux") {
        return;
    }
    let dir = TempDir::new("upper-opaque-x");
    let up = dir.path();
    std::fs::create_dir(up.join("d")).unwrap();
    if let Err(why) = set_mark(&up.join("d"), "user.overlay.opaque", "x") {
        eprintln!("SKIPPED an_opaque_mark_other_than_y_is_a_plain_directory: {why}");
        return;
    }
    assert_eq!(read_upper(up).unwrap(), vec![change("d", ChangeKind::Dir)]);
}

#[test]
fn a_missing_upper_is_an_error() {
    let dir = TempDir::new("upper-missing");
    assert!(read_upper(&dir.path().join("nope")).is_err());
}
