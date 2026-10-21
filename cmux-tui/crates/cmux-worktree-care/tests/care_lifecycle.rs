//! A worktree's whole life in real repositories: read, decided, archived,
//! removed and put back, with nothing lost.

use std::path::{Path, PathBuf};
use std::process::Command;

use cmux_worktree_care::inventory::{self, Facts, Repo};
use cmux_worktree_care::pass::{self, Options};
use cmux_worktree_care::policy::{Action, Pressure, Settings};
use cmux_worktree_care::restore::restore;
use cmux_worktree_care::{Store, archive};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "care-lifecycle-{name}-{}-{}",
        std::process::id(),
        inventory::now_ms()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// A main checkout pushed to a bare origin, with `.gitignore` naming build
/// output and a secrets file.
fn repository(name: &str) -> (PathBuf, PathBuf) {
    let base = scratch(name);
    let origin = base.join("origin.git");
    git(&base, &["init", "-q", "--bare", origin.to_str().unwrap()]);
    let main = base.join("main");
    git(&base, &["clone", "-q", origin.to_str().unwrap(), "main"]);
    write(&main.join(".gitignore"), "node_modules/\n.env\n");
    write(&main.join("src/lib.txt"), "one\n");
    write(&main.join("README"), "readme\n");
    git(&main, &["add", "."]);
    git(&main, &["commit", "-qm", "first"]);
    git(&main, &["push", "-q", "origin", "HEAD:main"]);
    git(&main, &["remote", "set-head", "origin", "main"]);
    (base, main)
}

fn scan(main: &Path) -> Repo {
    let common =
        PathBuf::from(git(main, &["rev-parse", "--path-format=absolute", "--git-common-dir"]));
    inventory::scan(&common, &[]).unwrap()
}

fn facts_of<'a>(repo: &'a Repo, path: &Path) -> (&'a inventory::Worktree, &'a Facts) {
    let worktree = repo.worktrees.iter().find(|w| w.path == path).expect("listed");
    (worktree, worktree.facts.as_ref().expect("readable"))
}

#[test]
fn care_unpushed_and_uncommitted_work_survives_reclaim_and_restore() {
    let (base, main) = repository("archive");
    let wt = base.join("wt-a");
    git(&main, &["worktree", "add", "-q", "-b", "feat/a", wt.to_str().unwrap()]);
    write(&wt.join("src/lib.txt"), "two\n");
    git(&wt, &["commit", "-qam", "local only"]);
    write(&wt.join("src/lib.txt"), "three\n");
    write(&wt.join("README"), "staged\n");
    git(&wt, &["add", "README"]);
    std::fs::remove_file(wt.join("src/lib.txt")).unwrap();
    write(&wt.join("notes/todo.md"), "untracked\n");
    write(&wt.join(".env"), "SECRET=1\n");
    write(&wt.join("node_modules/pkg/index.js"), "x");
    let head = git(&wt, &["rev-parse", "HEAD"]);
    let status_before = git(&wt, &["status", "--porcelain"]);

    let repo = scan(&main);
    let (worktree, facts) = facts_of(&repo, &wt);
    assert_eq!(worktree.branch.as_deref(), Some("feat/a"));
    assert_eq!(facts.unpushed, 1);
    assert_eq!(facts.changed, 2);
    assert_eq!(facts.untracked, vec!["notes/todo.md".to_string()]);
    assert_eq!(facts.build_output, vec!["node_modules/".to_string()]);
    assert_eq!(facts.ignored_data, vec![".env".to_string()]);
    assert!(facts.unarchivable.is_none(), "{:?}", facts.unarchivable);
    assert!(!facts.is_clean_and_pushed());

    let store = Store::open(base.join("store")).unwrap();
    let manifest =
        archive::reclaim(&repo, worktree, facts, Action::Archive, "test", &store).unwrap();
    assert!(!wt.exists(), "the folder is gone");
    let reference = manifest.archive_ref.clone().unwrap();
    assert_eq!(git(&main, &["rev-parse", &reference]), manifest.archive_commit.clone().unwrap());
    assert!(manifest.bundle.as_ref().is_some_and(|b| b.exists()));
    assert_eq!(git(&main, &["rev-parse", "feat/a"]), head, "the branch stays");

    let restored = restore(&store, &store.find("feat/a").unwrap(), None).unwrap();
    assert!(restored.archive && restored.notes.is_empty(), "{:?}", restored.notes);
    assert_eq!(restored.branch.as_deref(), Some("feat/a"));
    assert_eq!(git(&wt, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&wt, &["status", "--porcelain"]), status_before);
    assert_eq!(std::fs::read_to_string(wt.join(".env")).unwrap(), "SECRET=1\n");
    assert_eq!(std::fs::read_to_string(wt.join("notes/todo.md")).unwrap(), "untracked\n");
    assert!(!wt.join("node_modules").exists(), "build output is not archived");
    assert!(store.find("feat/a").is_none(), "the manifest is marked restored");
}

#[test]
fn care_a_restore_takes_the_archive_from_its_bundle_when_the_ref_is_gone() {
    let (base, main) = repository("bundle");
    let wt = base.join("wt-b");
    git(&main, &["worktree", "add", "-q", "-b", "feat/b", wt.to_str().unwrap()]);
    write(&wt.join("new.txt"), "only here\n");
    let repo = scan(&main);
    let (worktree, facts) = facts_of(&repo, &wt);
    let store = Store::open(base.join("store")).unwrap();
    let manifest =
        archive::reclaim(&repo, worktree, facts, Action::Archive, "test", &store).unwrap();
    let reference = manifest.archive_ref.clone().unwrap();
    git(&main, &["update-ref", "-d", &reference]);
    git(&main, &["reflog", "expire", "--expire=now", "--all"]);
    git(&main, &["gc", "-q", "--prune=now"]);

    restore(&store, &manifest, None).unwrap();
    assert_eq!(std::fs::read_to_string(wt.join("new.txt")).unwrap(), "only here\n");
}

#[test]
fn care_a_pushed_clean_worktree_goes_without_an_archive() {
    let (base, main) = repository("pushed");
    let wt = base.join("wt-c");
    git(&main, &["worktree", "add", "-q", "-b", "feat/c", wt.to_str().unwrap()]);
    write(&wt.join("src/lib.txt"), "pushed\n");
    git(&wt, &["commit", "-qam", "c"]);
    git(&wt, &["push", "-q", "origin", "feat/c"]);
    write(&wt.join("node_modules/x"), "build");
    let repo = scan(&main);
    let (worktree, facts) = facts_of(&repo, &wt);
    assert!(facts.is_clean_and_pushed());
    let store = Store::open(base.join("store")).unwrap();
    let manifest =
        archive::reclaim(&repo, worktree, facts, Action::Reclaim, "test", &store).unwrap();
    assert!(manifest.archive_ref.is_none() && !wt.exists());
    restore(&store, &manifest, None).unwrap();
    assert_eq!(std::fs::read_to_string(wt.join("src/lib.txt")).unwrap(), "pushed\n");
}

#[test]
fn care_a_squash_merged_branch_is_finished() {
    let (base, main) = repository("squash");
    let wt = base.join("wt-d");
    git(&main, &["worktree", "add", "-q", "-b", "feat/d", wt.to_str().unwrap()]);
    write(&wt.join("src/lib.txt"), "feature\n");
    git(&wt, &["commit", "-qam", "d1"]);
    write(&wt.join("extra.txt"), "more\n");
    git(&wt, &["add", "extra.txt"]);
    git(&wt, &["commit", "-qm", "d2"]);
    // The PR lands as one squashed commit on main, and main moves on.
    git(&main, &["merge", "-q", "--squash", "feat/d"]);
    git(&main, &["commit", "-qm", "squash d"]);
    write(&main.join("README"), "later\n");
    git(&main, &["commit", "-qam", "later"]);
    git(&main, &["push", "-q", "origin", "HEAD:main"]);
    git(&main, &["fetch", "-q", "origin"]);
    let repo = scan(&main);
    let (_, facts) = facts_of(&repo, &wt);
    assert_eq!(facts.unpushed, 2);
    assert!(
        facts.finished.as_deref().is_some_and(|f| f.contains("origin/main")),
        "{:?}",
        facts.finished
    );
}

#[test]
fn care_a_nested_repository_is_never_archived() {
    let (base, main) = repository("nested");
    let wt = base.join("wt-e");
    git(&main, &["worktree", "add", "-q", "-b", "feat/e", wt.to_str().unwrap()]);
    git(&wt, &["init", "-q", "vendor/inner"]);
    write(&wt.join("vendor/inner/file"), "inner work\n");
    let repo = scan(&main);
    let (_, facts) = facts_of(&repo, &wt);
    assert!(
        facts.unarchivable.as_deref().is_some_and(|w| w.contains("nested repository")),
        "{facts:?}"
    );
}

#[test]
fn care_a_sparse_worktree_comes_back_sparse() {
    let (base, main) = repository("sparse");
    let wt = base.join("wt-f");
    git(&main, &["worktree", "add", "-q", "-b", "feat/f", wt.to_str().unwrap()]);
    git(&wt, &["sparse-checkout", "set", "src"]);
    write(&wt.join("src/new.txt"), "n\n");
    let repo = scan(&main);
    let (worktree, facts) = facts_of(&repo, &wt);
    assert!(facts.sparse.as_ref().is_some_and(|s| s.cone));
    let store = Store::open(base.join("store")).unwrap();
    let manifest =
        archive::reclaim(&repo, worktree, facts, Action::Archive, "test", &store).unwrap();
    restore(&store, &manifest, None).unwrap();
    assert_eq!(git(&wt, &["sparse-checkout", "list"]), "src");
    assert_eq!(git(&wt, &["status", "--porcelain"]), "?? src/new.txt");
}

#[test]
fn care_a_pass_reclaims_idle_work_and_keeps_an_open_session_s() {
    let (base, main) = repository("pass");
    let idle = base.join("wt-idle");
    let open = base.join("wt-open");
    git(&main, &["worktree", "add", "-q", "-b", "feat/idle", idle.to_str().unwrap()]);
    git(&main, &["worktree", "add", "-q", "-b", "feat/open", open.to_str().unwrap()]);
    write(&idle.join("wip.txt"), "wip\n");
    let zero = [0, 0, 0];
    let options = Options {
        roots: vec![base.clone()],
        sessions: vec![cmux_worktree_care::policy::Session {
            name: "lane".into(),
            cwd: open.clone(),
            open: true,
            updated_ms: 0,
        }],
        settings: Settings {
            recent_hours: zero,
            idle_pushed_hours: zero,
            idle_unpushed_hours: zero,
            trim_hours: zero,
            ..Settings::default()
        },
        apply: true,
        pressure: Some(Pressure::Critical),
        only: Vec::new(),
    };
    let store = Store::open(base.join("store")).unwrap();
    let report = pass::run(&options, &store).unwrap();
    let action = |path: &Path| report.items.iter().find(|i| i.path == path).unwrap().verdict.action;
    assert_eq!(action(&idle), Action::Archive);
    assert_eq!(action(&open), Action::Keep);
    assert!(!idle.exists() && open.exists());
    assert!(store.find("feat/idle").is_some());
}
