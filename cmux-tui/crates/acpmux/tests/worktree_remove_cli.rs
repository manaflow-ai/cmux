//! `acpmux worktree remove` checks that need no session (W7-F review
//! findings 4 and 5): the command speaks the person's language in its help
//! and its errors, and an absolute TARGET works from a folder that is gone
//! (the shell often sits in a worktree removed before).
//!
//! No test here changes this process's environment: each `acpmux` gets its
//! own with `.env(...)`.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts in this process.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// `acpmux <args>` with the hermetic environment, `home` as HOME, in the locale `lang`.
fn acpmux_in(scratch: &Path, home: &Path, lang: &str, args: &[&str]) -> Output {
    daemon_env::acpmux(scratch)
        .env("HOME", home)
        .env("LC_ALL", lang)
        .env("LANG", lang)
        .args(args)
        .output()
        .unwrap()
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// A new folder for one test: (root, scratch, home).
fn folders(tag: &str) -> (PathBuf, PathBuf, PathBuf) {
    let root = std::env::temp_dir().join(format!("acpmux-w7f-{tag}-{}", uuid::Uuid::now_v7()));
    let scratch = root.join("cli");
    let home = root.join("home");
    std::fs::create_dir_all(&scratch).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    (root, scratch, home)
}

/// Review finding 4: in a Japanese locale `worktree remove --help` describes
/// the command and its arguments in Japanese, and a folder outside git says so.
#[test]
fn w7f_worktree_remove_help_and_errors_follow_the_locale() {
    let (root, scratch, home) = folders("remove-ja");
    let ja = "ja_JP.UTF-8";
    let help = acpmux_in(&scratch, &home, ja, &["worktree", "remove", "--help"]);
    assert!(help.status.success(), "{}", said(&help));
    for english in ["Remove one worktree now", "The worktree's folder", "Remove it even with"] {
        assert!(!said(&help).contains(english), "{english} is still English: {}", said(&help));
    }
    assert!(said(&help).contains("ワークツリーを 1 つ"), "{}", said(&help));
    assert!(said(&help).contains("セッション名"), "{}", said(&help));
    let help_en = acpmux_in(&scratch, &home, "C", &["worktree", "remove", "--help"]);
    assert!(said(&help_en).contains("Remove one worktree now"), "{}", said(&help_en));
    let outside = scratch.to_str().unwrap();
    let not_git = acpmux_in(&scratch, &home, ja, &["worktree", "remove", outside]);
    assert!(!not_git.status.success(), "{}", said(&not_git));
    assert!(said(&not_git).contains("git リポジトリ"), "{}", said(&not_git));
    let not_git_en = acpmux_in(&scratch, &home, "C", &["worktree", "remove", outside]);
    assert!(said(&not_git_en).contains("not in a git repository"), "{}", said(&not_git_en));
    let _ = std::fs::remove_dir_all(&root);
}

/// Review finding 5: an absolute TARGET does not need the current folder, so
/// `acpmux worktree remove /abs/path` works from a folder that was removed.
#[test]
fn w7f_worktree_remove_of_an_absolute_path_works_from_a_removed_current_folder() {
    let (root, scratch, home) = folders("remove-gone-cwd");
    let repo = root.join("proj");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);
    let worktree = root.join("wt/dead");
    git(&repo, &["worktree", "add", "-q", "-b", "w7f-dead", worktree.to_str().unwrap()]);
    let gone = root.join("gone");
    std::fs::create_dir_all(&gone).unwrap();

    // The shell enters the folder, the folder is removed, then acpmux runs there.
    let hermetic = daemon_env::acpmux(&scratch);
    let env = hermetic.get_envs().filter_map(|(key, value)| value.map(|value| (key, value)));
    let removed = Command::new("/bin/sh")
        .env_clear()
        .envs(env)
        .env("HOME", &home)
        .env("PWD", &gone)
        .current_dir(&gone)
        .args(["-c", r#"rmdir "$1" && shift && exec "$@""#, "sh"])
        .arg(&gone)
        .arg(hermetic.get_program())
        .args(["worktree", "remove", worktree.to_str().unwrap(), "--json"])
        .output()
        .unwrap();
    assert!(!gone.exists());
    assert!(removed.status.success(), "{}", said(&removed));
    let value: Value = serde_json::from_slice(&removed.stdout).unwrap();
    assert_eq!(value["root"], worktree.to_str().unwrap(), "{value}");
    assert!(!worktree.exists());
    // A branch cmux did not make stays.
    assert_eq!(value["branchDeleted"], false, "{value}");
    assert_eq!(git(&repo, &["branch", "--list", "w7f-dead"]), "w7f-dead");
    let _ = std::fs::remove_dir_all(&root);
}
