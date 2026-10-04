//! Real temporary repositories for the cmux-git tests.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// A temporary folder, removed on drop.
pub struct Folder(pub PathBuf);

impl Folder {
    pub fn new(name: &str) -> Self {
        let index = NEXT.fetch_add(1, Ordering::Relaxed);
        let folder = std::env::temp_dir().join(format!(
            "cmux-git-test-{name}-{}-{index}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&folder).unwrap();
        Self(fs::canonicalize(folder).unwrap())
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Runs the setup's git without the machine's own git config. `date`, when
/// given, is the author and committer date in seconds since the epoch.
pub fn git_at(directory: &Path, date: Option<u64>, args: &[&str]) -> String {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    let home = std::env::temp_dir().join("cmux-git-test-home");
    fs::create_dir_all(&home).unwrap();
    command.env("HOME", home).env("GIT_CONFIG_NOSYSTEM", "1");
    if let Some(date) = date {
        let date = format!("@{date} +0000");
        command.env("GIT_AUTHOR_DATE", &date).env("GIT_COMMITTER_DATE", &date);
    }
    let output = command
        .args([
            "-c",
            "user.name=cmux test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "init.defaultBranch=main",
        ])
        .args(args)
        .current_dir(directory)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

pub fn git(directory: &Path, args: &[&str]) -> String {
    git_at(directory, None, args)
}

/// An empty commit dated `date`, returning its id.
pub fn commit(directory: &Path, message: &str, date: u64) -> String {
    git_at(directory, Some(date), &["commit", "-q", "--allow-empty", "-m", message]);
    git(directory, &["rev-parse", "HEAD"])
}

/// A fresh repository on `main` in `folder`.
pub fn init(folder: &Path) {
    git(folder, &["init", "-q", "-b", "main"]);
}

/// `origin` (with one commit on `main`) and `work`, a clone of it, inside
/// `folder`. Returns the clone's path.
pub fn clone_of_origin(folder: &Path) -> PathBuf {
    let origin = folder.join("origin");
    fs::create_dir_all(&origin).unwrap();
    init(&origin);
    commit(&origin, "root", 1_000);
    git(folder, &["clone", "-q", "origin", "work"]);
    folder.join("work")
}
