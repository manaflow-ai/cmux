//! How uninstall removes a unit file it wrote (Codex R-002): the file it
//! checks is the file it removes, checked where no other account can reach
//! it, and only a plain file of this account's that no one else can write.

#![cfg(unix)]

use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};

use cmux_server::fsx::remove_if_unchanged;

const BODY: &[u8] = b"[Unit]\nDescription=cmux\n";

/// A private folder with the unit file `cmux-server.service` in it.
fn unit_in(tmp: &Path) -> PathBuf {
    let dir = tmp.join("units");
    std::fs::create_dir(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = dir.join("cmux-server.service");
    std::fs::write(&path, BODY).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    path
}

fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

/// The file is checked inside a new folder only this account can enter,
/// not under a sibling name in the unit folder: there another account
/// that can write the unit folder could swap the claimed name between the
/// check and the removal. Nothing is left behind.
#[test]
fn the_unit_is_checked_inside_a_private_folder_and_nothing_is_left() {
    let tmp = tempfile::tempdir().unwrap();
    let path = unit_in(tmp.path());
    let dir = path.parent().unwrap().to_path_buf();
    let seen = std::sync::Mutex::new(Vec::new());
    let removed = remove_if_unchanged(&path, |bytes| {
        for name in names(&dir) {
            let meta = std::fs::symlink_metadata(dir.join(&name)).unwrap();
            seen.lock().unwrap().push((name, meta.is_dir(), meta.mode() & 0o7777));
        }
        bytes == BODY
    })
    .unwrap();
    assert!(removed);
    let seen = seen.into_inner().unwrap();
    assert_eq!(seen.len(), 1, "while checking, the unit folder held {seen:?}");
    let (name, is_dir, mode) = &seen[0];
    assert!(*is_dir && mode & 0o077 == 0, "the claimed file is not in a private folder: {seen:?}");
    assert_ne!(name, "cmux-server.service");
    assert_eq!(names(&dir), Vec::<String>::new(), "left behind");
}

/// A unit file other accounts can write (mode 0666) is not cmux's to
/// trust, even with cmux's bytes: one of them could change it after the
/// check. Uninstall keeps it and fails.
#[test]
fn a_unit_others_can_write_is_kept() {
    let tmp = tempfile::tempdir().unwrap();
    let path = unit_in(tmp.path());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();
    assert!(remove_if_unchanged(&path, |bytes| bytes == BODY).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), BODY);
    assert_eq!(names(path.parent().unwrap()), vec!["cmux-server.service".to_owned()]);
}

/// A unit file with a second name (a hard link) is reachable through that
/// name too, which cmux never checked. Uninstall keeps it and fails.
#[test]
fn a_unit_with_a_second_hard_link_is_kept() {
    let tmp = tempfile::tempdir().unwrap();
    let path = unit_in(tmp.path());
    std::fs::hard_link(&path, tmp.path().join("other-name")).unwrap();
    assert!(remove_if_unchanged(&path, |bytes| bytes == BODY).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), BODY);
    assert_eq!(names(path.parent().unwrap()), vec!["cmux-server.service".to_owned()]);
}

/// A changed file goes back to its name and the call fails, with no
/// claim folder left.
#[test]
fn a_changed_unit_goes_back_to_its_name() {
    let tmp = tempfile::tempdir().unwrap();
    let path = unit_in(tmp.path());
    assert!(remove_if_unchanged(&path, |_| false).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), BODY);
    assert_eq!(names(path.parent().unwrap()), vec!["cmux-server.service".to_owned()]);
}

/// No file: nothing to remove, and no claim folder is left.
#[test]
fn a_missing_unit_is_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let path = unit_in(tmp.path());
    std::fs::remove_file(&path).unwrap();
    assert!(!remove_if_unchanged(&path, |_| true).unwrap());
    assert_eq!(names(path.parent().unwrap()), Vec::<String>::new());
}

/// Something else took the unit's name (a folder): it is refused and goes
/// back to its name, with no claim folder left.
#[test]
fn a_folder_at_the_units_name_goes_back() {
    let tmp = tempfile::tempdir().unwrap();
    let path = unit_in(tmp.path());
    std::fs::remove_file(&path).unwrap();
    std::fs::create_dir(&path).unwrap();
    std::fs::write(path.join("inside"), b"keep").unwrap();
    assert!(remove_if_unchanged(&path, |_| true).is_err());
    assert_eq!(std::fs::read(path.join("inside")).unwrap(), b"keep");
    assert_eq!(names(path.parent().unwrap()), vec!["cmux-server.service".to_owned()]);
}

/// macOS: an ACL entry can let another account write a 0644 file. Such a
/// unit is not cmux's to trust; uninstall keeps it and fails.
#[cfg(target_os = "macos")]
#[test]
fn a_unit_others_can_write_through_an_acl_is_kept() {
    let tmp = tempfile::tempdir().unwrap();
    let path = unit_in(tmp.path());
    let status = std::process::Command::new("/bin/chmod")
        .args(["+a", "group:everyone allow write,append"])
        .arg(&path)
        .status()
        .unwrap();
    assert!(status.success());
    assert!(remove_if_unchanged(&path, |bytes| bytes == BODY).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), BODY);
    assert_eq!(names(path.parent().unwrap()), vec!["cmux-server.service".to_owned()]);
}
