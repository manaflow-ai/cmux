//! A Cloud start's folder check before any machine: a repository goes on, a small plain folder
//! goes on, a plain folder past the copy's limits is refused with the repositories inside it.

use std::path::Path;

use super::super::super::sync_cli::size_cap::{self, MAX_REPOS, child_repos};
use super::run;

fn write(top: &Path, relative: &str, bytes: usize) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, vec![b'x'; bytes]).unwrap();
}

fn repo(top: &Path, relative: &str) {
    std::fs::create_dir_all(top.join(relative).join(".git")).unwrap();
    write(top, &format!("{relative}/src/main.rs"), 64);
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

#[test]
fn a_folder_in_git_goes_on_without_counting() {
    let (_root, top) = canonical();
    write(&top, "app/big.bin", 4096);
    let init = std::process::Command::new("git").args(["init", "-q"]).current_dir(top.join("app")).status().unwrap();
    assert!(init.success());
    // Limits a single file passes: a repository is never counted here (its seed is).
    let answer = size_cap::with_test_limits(16, 1, || run(top.join("app").to_str().unwrap()));
    assert_eq!(answer, serde_json::json!({"ok": true}));
}

#[test]
fn a_parent_of_repositories_past_the_limit_is_refused_naming_them() {
    let (_root, top) = canonical();
    repo(&top, "cmux");
    repo(&top, "web");
    repo(&top, "work/api");
    write(&top, "downloads/disk.img", 4096);
    write(&top, ".hidden/repo/.git/HEAD", 4);
    let answer = size_cap::with_test_limits(1024, 1_000, || run(top.to_str().unwrap()));
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["error_code"], size_cap::CODE);
    let names: Vec<&str> =
        answer["repos"].as_array().unwrap().iter().map(|repo| repo["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["cmux", "web", "work/api"]);
    assert_eq!(answer["repos"][0]["path"], top.join("cmux").to_str().unwrap());
    assert_eq!(answer["repos_more"], false);
    assert!(answer["error"].as_str().unwrap().contains("too big to copy"));
}

#[test]
fn a_big_plain_folder_with_no_repositories_is_refused_with_none() {
    let (_root, top) = canonical();
    for index in 0..8 {
        write(&top, &format!("photos/{index}.jpg"), 10);
    }
    let answer = size_cap::with_test_limits(1 << 30, 4, || run(top.to_str().unwrap()));
    assert_eq!(answer["error_code"], size_cap::CODE);
    assert_eq!(answer["repos"], serde_json::json!([]));
}

#[test]
fn the_repository_list_is_bounded_and_never_reads_below_a_repository() {
    let (_root, top) = canonical();
    for index in 0..(MAX_REPOS + 6) {
        repo(&top, &format!("r{index:03}"));
    }
    // A repository inside a repository is part of it, never listed apart.
    repo(&top, "r000/vendor/inner");
    let (repos, more) = child_repos(&top, MAX_REPOS);
    assert_eq!(repos.len(), MAX_REPOS);
    assert!(more);
    assert!(repos.iter().all(|repo| !repo.name.contains('/')));
}

#[test]
fn three_levels_down_is_never_looked_at() {
    let (_root, top) = canonical();
    repo(&top, "a/b/c");
    let (repos, more) = child_repos(&top, MAX_REPOS);
    assert!(repos.is_empty());
    assert!(!more);
}

#[cfg(unix)]
#[test]
fn a_symlinked_folder_is_never_followed() {
    let (_root, top) = canonical();
    let (_other, elsewhere) = canonical();
    repo(&elsewhere, "secret");
    std::os::unix::fs::symlink(&elsewhere, top.join("link")).unwrap();
    let (repos, _) = child_repos(&top, MAX_REPOS);
    assert!(repos.is_empty());
}

#[test]
fn a_relative_folder_is_a_usage_error() {
    assert_eq!(run("Projects")["error_code"], "usage.invalid");
}

#[test]
fn a_terminal_refusal_names_the_repositories_to_start_in() {
    let (_root, top) = canonical();
    assert_eq!(size_cap::repos_hint(&top), "");
    repo(&top, "web");
    repo(&top, "cmux");
    let hint = size_cap::repos_hint(&top);
    assert!(hint.starts_with("; the repositories inside it: cmux, web (start in one: --from-folder "), "{hint}");
    assert!(hint.ends_with("/cmux)"), "{hint}");
}
