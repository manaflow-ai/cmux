//! A Cloud start's folder check before any machine: every absolute folder goes on, whatever its
//! size; a parent of repositories past the copy's limits (`~/Projects`) above all.

use std::path::Path;

use super::super::super::sync_cli::size_cap;
use super::run;

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
    assert_eq!(run(top.to_str().unwrap()), serde_json::json!({"ok": true}));
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
    assert_eq!(answer, serde_json::json!({"ok": true}));
}

#[test]
fn a_big_plain_folder_with_no_repositories_goes_on() {
    let (_root, top) = canonical();
    for index in 0..8 {
        write(&top, &format!("photos/{index}.jpg"), 10);
    }
    let answer = size_cap::with_test_limits(1, 1, || run(top.to_str().unwrap()));
    assert_eq!(answer, serde_json::json!({"ok": true}));
}

#[test]
fn a_relative_folder_is_a_usage_error() {
    assert_eq!(run("Projects")["error_code"], "usage.invalid");
}
