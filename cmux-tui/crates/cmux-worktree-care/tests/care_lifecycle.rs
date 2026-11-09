//! A worktree's whole life in real repositories: read, decided, archived,
//! removed and put back, with nothing lost.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, LazyLock};

use cmux_worktree_care::inventory::{self, Facts, FinishedMemo, Repo};
use cmux_worktree_care::pass::{self, Options};
use cmux_worktree_care::policy::{Action, Pressure, Settings};
use cmux_worktree_care::procs::{Open, Uses};
use cmux_worktree_care::restore::restore;
use cmux_worktree_care::{Store, archive};

/// Nothing registered as working anywhere.
fn nothing() -> Arc<Uses> {
    Arc::new(|| Ok(Vec::new()))
}

fn closed() -> Arc<Open> {
    Arc::new(|_| Ok(None))
}

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
    write(&main.join("package.json"), "{}\n");
    git(&main, &["add", "."]);
    git(&main, &["commit", "-qm", "first"]);
    git(&main, &["push", "-q", "origin", "HEAD:main"]);
    git(&main, &["remote", "set-head", "origin", "main"]);
    (base, main)
}

/// This test process's finished answers, shared by its scans as the
/// library's own memo is. Their merge-tree lock is in this process's own
/// folder: with the library's in-memory memo it is the host-wide lock in
/// `Store::default_dir()`, and while another test's merge-tree or the
/// person's cleanup daemon held it, a squash check was "busy, unknown" and a
/// finished branch read as unfinished.
static FINISHED: LazyLock<Arc<FinishedMemo>> =
    LazyLock::new(|| Arc::new(FinishedMemo::load(scratch("finished").join("finished.json"))));

fn scan(main: &Path) -> Repo {
    let common =
        PathBuf::from(git(main, &["rev-parse", "--path-format=absolute", "--git-common-dir"]));
    inventory::scan_with_memo(&common, &[], Arc::clone(&FINISHED)).unwrap()
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
    let manifest = archive::reclaim(
        &repo,
        worktree,
        facts,
        Action::Archive,
        "test",
        &store,
        &*nothing(),
        &*closed(),
    )
    .unwrap();
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
    let manifest = archive::reclaim(
        &repo,
        worktree,
        facts,
        Action::Archive,
        "test",
        &store,
        &*nothing(),
        &*closed(),
    )
    .unwrap();
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
    let manifest = archive::reclaim(
        &repo,
        worktree,
        facts,
        Action::Reclaim,
        "test",
        &store,
        &*nothing(),
        &*closed(),
    )
    .unwrap();
    assert!(manifest.archive_ref.is_none() && !wt.exists());
    restore(&store, &manifest, None).unwrap();
    assert_eq!(std::fs::read_to_string(wt.join("src/lib.txt")).unwrap(), "pushed\n");
}

#[test]
fn care_a_worktree_a_program_has_open_stays() {
    let (base, main) = repository("held");
    let wt = base.join("wt-h");
    git(&main, &["worktree", "add", "-q", "-b", "feat/h", wt.to_str().unwrap()]);
    write(&wt.join("src/lib.txt"), "pushed\n");
    git(&wt, &["commit", "-qam", "h"]);
    git(&wt, &["push", "-q", "origin", "feat/h"]);
    write(&wt.join("notes.txt"), "not pushed\n");
    let repo = scan(&main);
    let (worktree, facts) = facts_of(&repo, &wt);
    let store = Store::open(base.join("store")).unwrap();
    let held: Arc<Open> = Arc::new(|_| Ok(Some(4242)));
    let error = archive::reclaim(
        &repo,
        worktree,
        facts,
        Action::Archive,
        "test",
        &store,
        &*nothing(),
        &*held,
    )
    .unwrap_err();
    assert!(error.contains("4242"), "{error}");
    let failing: Arc<Open> = Arc::new(|_| Err("lsof: timed out".into()));
    let error = archive::reclaim(
        &repo,
        worktree,
        facts,
        Action::Archive,
        "test",
        &store,
        &*nothing(),
        &*failing,
    )
    .unwrap_err();
    assert!(error.contains("could not check"), "{error}");
    // The folder, its work and no archive: both checks left it as it was.
    assert_eq!(std::fs::read_to_string(wt.join("notes.txt")).unwrap(), "not pushed\n");
    assert!(store.list().is_empty());
    assert_eq!(git(&main, &["for-each-ref", "refs/cmux/archive"]).trim(), "");
}

/// The host-wide merge-tree lock that scans with no state folder of their
/// own share (`.merge-tree.lock` in `Store::default_dir()`), held until the
/// file is dropped. Waits for a merge-tree another process is running.
fn host_merge_tree_lock() -> std::fs::File {
    let dir = Store::default_dir().expect("a home folder");
    std::fs::create_dir_all(&dir).unwrap();
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(dir.join(".merge-tree.lock"))
        .unwrap();
    file.lock().unwrap();
    file
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
    // A merge-tree elsewhere on this machine (another test process, the
    // person's own cleanup daemon) holds the host-wide lock through the scan:
    // what this test reads must not depend on what else runs on the host.
    let _host_busy = host_merge_tree_lock();
    let repo = scan(&main);
    let (_, facts) = facts_of(&repo, &wt);
    assert_eq!(facts.unpushed, 2);
    assert!(
        facts.finished.as_deref().is_some_and(|f| f.contains("origin/main")),
        "{:?}",
        facts.finished
    );
}

/// Loose objects in the repository's object folder.
fn loose_objects(main: &Path) -> String {
    git(main, &["count-objects", "-v"])
        .lines()
        .find(|line| line.starts_with("count:"))
        .unwrap_or_default()
        .to_string()
}

#[test]
fn care_a_scan_writes_no_object_into_the_repository() {
    let (base, main) = repository("no-objects");
    let wt = base.join("wt-e");
    git(&main, &["worktree", "add", "-q", "-b", "feat/e", wt.to_str().unwrap()]);
    write(&wt.join("src/lib.txt"), "feature\n");
    git(&wt, &["commit", "-qam", "e1"]);
    // main moves on elsewhere: merging feat/e into it makes trees neither has.
    write(&main.join("docs/later.txt"), "later\n");
    git(&main, &["add", "."]);
    git(&main, &["commit", "-qm", "later"]);
    git(&main, &["push", "-q", "origin", "HEAD:main"]);
    git(&main, &["fetch", "-q", "origin"]);
    git(&main, &["repack", "-qad"]);
    let before = loose_objects(&main);
    for _ in 0..2 {
        // The second scan answers from what the first found.
        let repo = scan(&main);
        let (_, facts) = facts_of(&repo, &wt);
        assert_eq!(facts.finished, None, "the work is not on main");
    }
    assert_eq!(loose_objects(&main), before, "merge-tree's trees went to a scratch folder");
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
    let manifest = archive::reclaim(
        &repo,
        worktree,
        facts,
        Action::Archive,
        "test",
        &store,
        &*nothing(),
        &*closed(),
    )
    .unwrap();
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
        uses: nothing(),
        open: closed(),
        apply: true,
        pressure: Some(Pressure::Critical),
        only: Vec::new(),
        measure: true,
    };
    let store = Store::open(base.join("store")).unwrap();
    let report = pass::run(&options, &store).unwrap();
    let action = |path: &Path| report.items.iter().find(|i| i.path == path).unwrap().verdict.action;
    assert_eq!(action(&idle), Action::Archive);
    assert_eq!(action(&open), Action::Keep);
    assert!(!idle.exists() && open.exists());
    assert!(store.find("feat/idle").is_some());
    assert!(report.reclaimable > 0, "the idle worktree was measured before it went");
}

#[test]
fn care_a_restore_over_a_branch_that_moved_on_detaches_at_the_archive() {
    let (base, main) = repository("moved");
    let wt = base.join("wt-g");
    git(&main, &["worktree", "add", "-q", "-b", "feat/g", wt.to_str().unwrap()]);
    write(&wt.join("wip.txt"), "wip\n");
    let head = git(&wt, &["rev-parse", "HEAD"]);
    let repo = scan(&main);
    let (worktree, facts) = facts_of(&repo, &wt);
    let store = Store::open(base.join("store")).unwrap();
    let manifest = archive::reclaim(
        &repo,
        worktree,
        facts,
        Action::Archive,
        "test",
        &store,
        &*nothing(),
        &*closed(),
    )
    .unwrap();
    // Someone commits on the branch while the worktree is archived.
    git(&main, &["branch", "-f", "feat/g", "main"]);
    git(&main, &["switch", "-q", "feat/g"]);
    write(&main.join("later.txt"), "later\n");
    git(&main, &["add", "later.txt"]);
    git(&main, &["commit", "-qm", "later"]);
    git(&main, &["switch", "-q", "main"]);
    let tip = git(&main, &["rev-parse", "feat/g"]);

    let restored = restore(&store, &manifest, None).unwrap();
    assert_eq!(restored.branch, None, "{:?}", restored.notes);
    assert!(restored.notes.iter().any(|n| n.contains("moved")), "{:?}", restored.notes);
    assert_eq!(git(&wt, &["rev-parse", "HEAD"]), head);
    assert_eq!(git(&wt, &["status", "--porcelain"]), "?? wip.txt");
    assert_eq!(git(&main, &["rev-parse", "feat/g"]), tip, "the branch is untouched");
}

#[test]
fn care_a_restore_that_cannot_find_its_archive_adds_nothing() {
    let (base, main) = repository("lost");
    let wt = base.join("wt-h");
    git(&main, &["worktree", "add", "-q", "-b", "feat/h", wt.to_str().unwrap()]);
    write(&wt.join("wip.txt"), "wip\n");
    let repo = scan(&main);
    let (worktree, facts) = facts_of(&repo, &wt);
    let store = Store::open(base.join("store")).unwrap();
    let manifest = archive::reclaim(
        &repo,
        worktree,
        facts,
        Action::Archive,
        "test",
        &store,
        &*nothing(),
        &*closed(),
    )
    .unwrap();
    git(&main, &["update-ref", "-d", manifest.archive_ref.as_deref().unwrap()]);
    git(&main, &["reflog", "expire", "--expire=now", "--all"]);
    git(&main, &["gc", "-q", "--prune=now"]);
    std::fs::remove_file(manifest.bundle.as_ref().unwrap()).unwrap();

    assert!(restore(&store, &manifest, None).is_err());
    assert!(!wt.exists(), "no half-restored folder");
    assert!(!git(&main, &["worktree", "list"]).contains("wt-h"));
    assert!(store.find("feat/h").is_some(), "still there to try again");
}

#[test]
fn care_a_file_marked_assume_unchanged_keeps_its_worktree() {
    let (base, main) = repository("assume");
    let wt = base.join("wt-i");
    git(&main, &["worktree", "add", "-q", "-b", "feat/i", wt.to_str().unwrap()]);
    git(&wt, &["update-index", "--assume-unchanged", "README"]);
    write(&wt.join("README"), "hidden edit\n");
    let repo = scan(&main);
    let (_, facts) = facts_of(&repo, &wt);
    assert!(facts.unarchivable.is_some(), "{facts:?}");
}

#[test]
fn care_an_archive_goes_after_its_keep_time() {
    let (base, main) = repository("expire");
    let wt = base.join("wt-j");
    git(&main, &["worktree", "add", "-q", "-b", "feat/j", wt.to_str().unwrap()]);
    write(&wt.join("wip.txt"), "wip\n");
    let repo = scan(&main);
    let (worktree, facts) = facts_of(&repo, &wt);
    let store = Store::open(base.join("store")).unwrap();
    let manifest = archive::reclaim(
        &repo,
        worktree,
        facts,
        Action::Archive,
        "test",
        &store,
        &*nothing(),
        &*closed(),
    )
    .unwrap();
    let day = 24 * 60 * 60 * 1000;
    assert!(archive::expire(&store, manifest.created_ms + day, 14 * day).unwrap().is_empty());
    let dropped = archive::expire(&store, manifest.created_ms + 15 * day, 14 * day).unwrap();
    assert_eq!(dropped, vec![manifest.id.clone()]);
    assert!(store.list().is_empty());
    assert!(!manifest.bundle.as_ref().unwrap().exists());
    assert!(git(&main, &["for-each-ref", "refs/cmux/archive"]).is_empty());
}

#[test]
fn care_a_worktree_whose_folder_is_missing_keeps_its_git_state() {
    // An unmounted volume, or a folder moved with mv: its HEAD, index and
    // reflog stay until git gc's own 3 months.
    let (base, main) = repository("missing");
    let wt = base.join("wt-k");
    git(&main, &["worktree", "add", "-q", "--detach", wt.to_str().unwrap()]);
    write(&wt.join("README"), "local\n");
    git(&wt, &["commit", "-qam", "detached, local only"]);
    let moved = base.join("moved-k");
    std::fs::rename(&wt, &moved).unwrap();
    let options = Options {
        roots: vec![base.clone()],
        sessions: Vec::new(),
        settings: Settings::default(),
        uses: nothing(),
        open: closed(),
        apply: true,
        pressure: Some(Pressure::Critical),
        only: Vec::new(),
        measure: false,
    };
    let store = Store::open(base.join("store")).unwrap();
    pass::run(&options, &store).unwrap();
    std::fs::rename(&moved, &wt).unwrap();
    assert!(git(&wt, &["log", "-1", "--format=%s"]).contains("detached, local only"));
}

#[test]
fn care_a_claude_session_registered_in_a_worktree_keeps_it() {
    let (base, main) = repository("claude");
    let wt = base.join("wt-l");
    git(&main, &["worktree", "add", "-q", "-b", "feat/l", wt.to_str().unwrap()]);
    write(&wt.join("wip.txt"), "wip\n");
    // Claude Code's own registry, as a terminal agent outside acpmux leaves it.
    let claude = base.join("claude-home");
    std::fs::create_dir_all(claude.join("sessions")).unwrap();
    let cwd = wt.join("src");
    std::fs::write(
        claude.join("sessions/1.json"),
        format!(r#"{{"pid":{},"cwd":{:?}}}"#, std::process::id(), cwd.to_str().unwrap()),
    )
    .unwrap();
    let zero = [0, 0, 0];
    let registry = claude;
    let options = Options {
        roots: vec![base.clone()],
        sessions: Vec::new(),
        uses: Arc::new(move || {
            // This test process stands in for the session's: `inside` skips
            // its own pid, so the record names its parent.
            cmux_worktree_care::procs::claude_sessions(std::slice::from_ref(&registry)).map(
                |found| {
                    found
                        .into_iter()
                        .map(|p| cmux_worktree_care::procs::Process { pid: p.pid + 1_000_000, ..p })
                        .collect()
                },
            )
        }),
        open: closed(),
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
        measure: false,
    };
    let store = Store::open(base.join("store")).unwrap();
    let report = pass::run(&options, &store).unwrap();
    let item = report.items.iter().find(|i| i.path == wt).unwrap();
    assert_eq!(item.verdict.action, Action::Keep, "{}", item.verdict.reason);
    assert!(wt.exists());
}
