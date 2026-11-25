use super::*;

/// A fresh directory of this test's own, removed by the test.
fn scratch(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-host-exe-{label}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn a_file_key_changes_when_the_file_is_replaced() {
    let dir = scratch("key");
    let path = dir.join(SIBLING_NAME);
    fs::write(&path, b"one").unwrap();
    let first = FileKey::of(&path).unwrap();
    assert_eq!(FileKey::of(&path).unwrap(), first, "an unchanged file keeps its key");
    let next = dir.join("next");
    fs::write(&next, b"two").unwrap();
    fs::rename(&next, &path).unwrap();
    assert_ne!(FileKey::of(&path).unwrap(), first, "a rename over it is another file");
    assert!(FileKey::of(&dir).is_err(), "a directory is no host");
    fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn only_a_sibling_that_reports_this_build_is_used() {
    use std::os::unix::fs::PermissionsExt;
    let dir = scratch("identity");
    let path = dir.join(SIBLING_NAME);
    fs::write(&path, "#!/bin/sh\necho \"cmux-tui-host build-a\"\n").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    check_identity(&path, "build-a").unwrap();
    assert!(check_identity(&path, "build-b").is_err(), "another build is refused");
    fs::remove_dir_all(&dir).unwrap();
}
