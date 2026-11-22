//! Detector: a code layer whose change is in the app by content, not by its
//! own commits (a squash merge, a re-land, cherry-picks), folds as "now built
//! in" (RFD 0038 phase 1 step 3). Merge containment alone kept such a layer
//! on after the update that carried it. Each case is a synthetic repo: a
//! layer branch off `base`, and an app commit on main.

use std::path::Path;
use std::process::Command;

use cmux_customize::library::fold::{FOLDED, How, local_folded};
use cmux_customize::{Customize, Roots};

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("HOME", dir)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn write(dir: &Path, path: &str, text: &str) {
    std::fs::write(dir.join(path), text).unwrap();
}

fn commit(dir: &Path, message: &str) -> String {
    git(dir, &["add", "-A"]);
    git(dir, &["commit", "-q", "-m", message]);
    git(dir, &["rev-parse", "HEAD"])
}

/// A repo whose `main` has a, z; branch `layer` changes a (c1) and adds b
/// (c2). Returns the repo, the layer's head and its two commits.
struct Repo {
    dir: tempfile::TempDir,
    head: String,
    c1: String,
    c2: String,
}

impl Repo {
    fn new() -> Repo {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path();
        git(path, &["init", "-q", "-b", "main"]);
        write(path, "a.ts", "one\ntwo\nthree\n");
        write(path, "z.ts", "zed\n");
        commit(path, "base");
        git(path, &["checkout", "-q", "-b", "layer"]);
        write(path, "a.ts", "one\nTWO\nthree\n");
        let c1 = commit(path, "c1");
        write(path, "b.ts", "bee\n");
        let c2 = commit(path, "c2");
        git(path, &["checkout", "-q", "main"]);
        Repo { head: c2.clone(), dir, c1, c2 }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    /// An unrelated change on main.
    fn unrelated(&self) -> String {
        write(self.path(), "z.ts", "zed\nzed\n");
        commit(self.path(), "unrelated")
    }

    fn folded(&self, app: &str) -> Option<How> {
        local_folded(self.path(), &self.head, app)
    }
}

#[test]
fn a_squash_merge_folds() {
    let repo = Repo::new();
    repo.unrelated();
    git(repo.path(), &["merge", "-q", "--squash", "layer"]);
    let app = commit(repo.path(), "squash");
    assert_eq!(repo.folded(&app), Some(How::Tree));
}

#[test]
fn a_squash_merge_edited_later_folds_by_patch_id() {
    let repo = Repo::new();
    git(repo.path(), &["merge", "-q", "--squash", "layer"]);
    commit(repo.path(), "squash");
    // The app moved the same file on: the tree test cannot see it now.
    write(repo.path(), "b.ts", "bee\nand more\n");
    let app = commit(repo.path(), "later");
    assert_eq!(repo.folded(&app), Some(How::Patch));
}

#[test]
fn cherry_picks_fold() {
    let repo = Repo::new();
    repo.unrelated();
    git(repo.path(), &["cherry-pick", &repo.c1]);
    git(repo.path(), &["cherry-pick", &repo.c2]);
    write(repo.path(), "a.ts", "zero\none\nTWO\nthree\n");
    let app = commit(repo.path(), "later");
    assert_eq!(repo.folded(&app), Some(How::Cherry));
}

#[test]
fn a_merged_head_is_contained() {
    let repo = Repo::new();
    repo.unrelated();
    git(repo.path(), &["merge", "-q", "--no-ff", "-m", "merge", "layer"]);
    let app = git(repo.path(), &["rev-parse", "HEAD"]);
    assert_eq!(repo.folded(&app), Some(How::Contained));
}

#[test]
fn a_partial_fold_does_not_fold() {
    let repo = Repo::new();
    git(repo.path(), &["cherry-pick", &repo.c1]);
    let app = repo.unrelated();
    assert_eq!(repo.folded(&app), None);
}

#[test]
fn an_unrelated_change_does_not_fold() {
    let repo = Repo::new();
    let app = repo.unrelated();
    assert_eq!(repo.folded(&app), None);
}

#[test]
fn the_same_paths_changed_another_way_do_not_fold() {
    let repo = Repo::new();
    write(repo.path(), "a.ts", "one\nTwo!\nthree\n");
    write(repo.path(), "b.ts", "bee\n");
    let app = commit(repo.path(), "different");
    assert_eq!(repo.folded(&app), None);
}

#[test]
fn a_checkout_without_the_commit_cannot_say() {
    let repo = Repo::new();
    let missing = "0123456789abcdef0123456789abcdef01234567";
    assert_eq!(repo.folded(missing), None);
    assert_eq!(local_folded(repo.path(), missing, &repo.c1), None);
}

#[test]
fn answers_are_cached_by_head_and_app() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    assert_eq!(customize.folded_cached("h", "a"), None);
    customize.remember_folded("h", "a", Some(How::Tree));
    customize.remember_folded("h", "b", None);
    assert_eq!(customize.folded_cached("h", "a"), Some(Some(How::Tree)));
    assert_eq!(customize.folded_cached("h", "b"), Some(None));
}

#[test]
fn a_folded_layer_stays_in_the_weeks_history() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    customize.record_off("pr-7", FOLDED, 1_000).unwrap();
    let shown = customize.expired(2_000);
    assert_eq!(shown.len(), 1);
    assert_eq!(shown[0].name, "pr-7");
    assert_eq!(shown[0].why, "now built in");
    let week = 7 * 24 * 3_600_000;
    assert!(customize.expired(1_000 + week).is_empty());
}
