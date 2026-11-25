use super::page_in::*;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn file(dir: &std::path::Path, rel: &str, len: usize) -> PathBuf {
    let path = dir.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, vec![7_u8; len]).unwrap();
    path
}

#[test]
fn the_targets_are_each_harness_once_through_its_links() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    // Claude Code's native installer: a link to the version it runs.
    let claude = file(&home, ".local/share/claude/versions/2.1.331", 64);
    std::fs::create_dir_all(home.join(".local/bin")).unwrap();
    std::os::unix::fs::symlink(&claude, home.join(".local/bin/claude")).unwrap();
    // A second name for the same file, and a link to nothing.
    let system_link = dir.path().join("usr-local-claude");
    std::os::unix::fs::symlink(&claude, &system_link).unwrap();
    std::os::unix::fs::symlink(dir.path().join("gone"), home.join(".local/bin/codex")).unwrap();
    let system = system_link.to_str().unwrap();
    let missing = dir.path().join("no-node");
    let targets =
        targets(&[home.clone(), dir.path().join("no-home")], &[system, missing.to_str().unwrap()]);
    assert_eq!(targets, vec![std::fs::canonicalize(&claude).unwrap()]);
}

#[test]
fn a_read_takes_every_byte_within_its_bounds() {
    let dir = tempfile::tempdir().unwrap();
    let a = file(dir.path(), "a", 3 << 20);
    let b = file(dir.path(), "b", 5);
    let far = Instant::now() + Duration::from_secs(60);
    let files = vec![a.clone(), dir.path().join("missing"), b.clone()];
    assert_eq!(
        page_in(&files, MAX_BYTES, far),
        Paged { files: 2, bytes: (3 << 20) + 5, whole: true }
    );
    // The byte cap stops it mid-file, exactly at the cap.
    assert_eq!(page_in(&files, 1 << 20, far), Paged { files: 1, bytes: 1 << 20, whole: false });
    // A passed deadline reads nothing more.
    assert_eq!(
        page_in(&files, MAX_BYTES, Instant::now()),
        Paged { files: 1, bytes: 0, whole: false }
    );
}
