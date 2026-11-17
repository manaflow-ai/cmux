//! A Cloud start's folder check before any machine: every absolute folder goes on, whatever its
//! size; a parent of repositories past the copy's limits (`~/Projects`) above all.

use std::path::Path;

use super::super::super::sync_cli::size_cap;
use super::{needed_size, run};

fn write(top: &Path, relative: &str, bytes: usize) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, vec![b'x'; bytes]).unwrap();
}

fn canonical() -> (tempfile::TempDir, std::path::PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(root.path()).unwrap();
    (root, top)
}

#[test]
fn a_small_plain_folder_goes_on() {
    let (_root, top) = canonical();
    write(&top, "notes/a.txt", 10);
    assert_eq!(
        run(top.to_str().unwrap()),
        serde_json::json!({"ok": true, "estimate_bytes": 10, "needed_size": "sm"})
    );
}

/// Leo's `~/Projects`, refused before with the repositories inside it: it goes on now.
#[test]
fn a_parent_of_repositories_past_the_limit_goes_on() {
    let (_root, top) = canonical();
    for name in ["cmux", "web", "work/api"] {
        std::fs::create_dir_all(top.join(name).join(".git")).unwrap();
        write(&top, &format!("{name}/src/main.rs"), 64);
    }
    write(&top, "downloads/disk.img", 4096);
    let answer = size_cap::with_test_limits(1024, 3, || run(top.to_str().unwrap()));
    assert_eq!(answer["ok"], true);
    // Past the limits only a first pass goes, at most its own bytes.
    let sent = answer["estimate_bytes"].as_u64().unwrap();
    assert!(sent <= size_cap::FIRST_BYTES, "{answer}");
    assert_eq!(answer["needed_size"], "sm");
}

#[test]
fn a_big_plain_folder_with_no_repositories_goes_on() {
    let (_root, top) = canonical();
    for index in 0..8 {
        write(&top, &format!("photos/{index}.jpg"), 10);
    }
    let answer = size_cap::with_test_limits(1, 1, || run(top.to_str().unwrap()));
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["needed_size"], "sm");
}

#[test]
fn a_relative_folder_is_a_usage_error() {
    assert_eq!(run("Projects")["error_code"], "usage.invalid");
}

/// A folder sent whole counts its repository history too: the machine holds it.
#[test]
fn a_whole_copy_counts_its_git_history() {
    let (_root, top) = canonical();
    std::fs::create_dir_all(top.join(".git")).unwrap();
    let init = std::process::Command::new("git").arg("init").arg("-q").arg(&top).status().unwrap();
    assert!(init.success());
    write(&top, "src/main.rs", 100);
    let answer = run(top.to_str().unwrap());
    assert!(answer["estimate_bytes"].as_u64().unwrap() > 100, "{answer}");
}

#[test]
fn the_needed_size_is_the_smallest_disk_with_room_for_the_copy_and_the_reserve() {
    const GIB: u64 = 1024 * 1024 * 1024;
    assert_eq!(needed_size(0), Some("sm"));
    assert_eq!(needed_size(4 * GIB), Some("sm"));
    assert_eq!(needed_size(4 * GIB + 1), Some("md"));
    assert_eq!(needed_size(20 * GIB), Some("md"));
    assert_eq!(needed_size(52 * GIB), Some("lg"));
    assert_eq!(needed_size(116 * GIB), Some("xl"));
    assert_eq!(needed_size(116 * GIB + 1), None);
    assert_eq!(needed_size(u64::MAX), None);
}

/// A folder that can't be read answers no size: the copy counts it again.
#[test]
fn a_missing_folder_goes_on_with_no_size() {
    let (_root, top) = canonical();
    assert_eq!(run(top.join("gone").to_str().unwrap()), serde_json::json!({"ok": true}));
}
