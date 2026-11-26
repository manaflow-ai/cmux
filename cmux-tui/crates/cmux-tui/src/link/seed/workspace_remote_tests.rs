//! The per-workspace remote against real repositories: a working copy plays the VM, a folder
//! plays the store ([`DirStore`]) and a bare clone at the base plays the laptop's repository.

use std::cell::Cell;
use std::path::Path;
use std::process::Command;

use super::super::plan::FallbackCode;
use super::{
    BACK_REF, DirStore, NOT_WIRED, Name, Record, Store, TurnEnd, Unwired, WIP_REF, fetch, load,
    needs_workspace_remote, read_tip, save, turn_end,
};

/// git for fixtures, with a fixed identity and no person's settings.
fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.invalid"])
        .args(["-c", "commit.gpgSign=false", "-c", "init.defaultBranch=main"])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .expect("git runs");
    assert!(
        out.status.success(),
        "git {args:?} in {}: {}",
        dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim_end().to_string()
}

fn write(path: &Path, text: &str) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, text).unwrap();
}

/// A VM working copy with one commit (the base), and a store folder.
struct Fixture {
    dir: tempfile::TempDir,
    base: String,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let vm = dir.path().join("vm");
        std::fs::create_dir_all(&vm).unwrap();
        git(&vm, &["init", "-q"]);
        write(&vm.join("README.md"), "hello\n");
        write(&vm.join(".gitignore"), "target/\n");
        git(&vm, &["add", "-A"]);
        git(&vm, &["commit", "-q", "-m", "base"]);
        let base = git(&vm, &["rev-parse", "HEAD"]);
        Self { dir, base }
    }

    fn vm(&self) -> std::path::PathBuf {
        self.dir.path().join("vm")
    }

    fn store(&self) -> DirStore {
        DirStore(self.dir.path().join("store"))
    }

    /// The laptop's repository: a bare clone that has the base.
    fn laptop(&self) -> std::path::PathBuf {
        let laptop = self.dir.path().join("laptop.git");
        if !laptop.exists() {
            git(self.dir.path(), &["clone", "-q", "--bare", "vm", "laptop.git"]);
        }
        laptop
    }
}

fn name() -> Name {
    Name::new("ws-123").unwrap()
}

fn files_of(repo: &Path, commit: &str) -> Vec<String> {
    let listed = git(repo, &["ls-tree", "-r", "--name-only", commit]);
    listed.lines().map(str::to_string).collect()
}

#[test]
fn a_workspace_remote_is_a_prefix_under_workspaces() {
    let name = name();
    assert_eq!(name.prefix(), "workspaces/ws-123/git/");
    assert_eq!(name.tip_key(), "workspaces/ws-123/git/tip.json");
    assert_eq!(name.bundle_key(3, "abc"), "workspaces/ws-123/git/bundles/00000003-abc.bundle");
    for bad in ["", ".", "..", "../x", "a/b", "a b", ".hidden", &"x".repeat(129)] {
        assert!(Name::new(bad).is_err(), "{bad:?} taken");
    }
    assert!(Name::new("A.b_c-9").is_ok());
}

#[test]
fn only_a_folder_with_no_remote_takes_a_workspace_remote() {
    for code in
        [FallbackCode::NotGit, FallbackCode::NotTop, FallbackCode::NoCommit, FallbackCode::NoRemote]
    {
        assert!(needs_workspace_remote(code), "{code:?}");
    }
    for code in [
        FallbackCode::NotGithub,
        FallbackCode::NoBase,
        FallbackCode::Unmerged,
        FallbackCode::GitFailed,
    ] {
        assert!(!needs_workspace_remote(code), "{code:?}");
    }
}

#[test]
fn the_push_is_off_by_default_and_touches_nothing() {
    let fixture = Fixture::new();
    write(&fixture.vm().join("new.txt"), "new\n");
    let store = fixture.store();
    let done = turn_end(&fixture.vm(), &name(), &fixture.base, &store, false).unwrap();
    assert_eq!(done, TurnEnd::Off);
    assert!(!store.0.exists());
    // The switch itself defaults off.
    if std::env::var_os(super::ENV).is_none() {
        assert!(!super::enabled());
    }
}

#[test]
fn turns_go_up_as_thin_bundles_and_come_back_on_a_ref_of_ours() {
    let fixture = Fixture::new();
    let vm = fixture.vm();
    let store = fixture.store();
    let laptop = fixture.laptop();
    write(&vm.join("README.md"), "hello, edited\n");
    write(&vm.join("src/new.rs"), "fn main() {}\n");
    write(&vm.join(".env"), "TOKEN=secret\n");
    write(&vm.join("target/out.bin"), "built\n");
    std::fs::create_dir_all(vm.join("nested")).unwrap();
    git(&vm.join("nested"), &["init", "-q"]);
    write(&vm.join("nested/inner.txt"), "inner\n");
    let status_before = git(&vm, &["status", "--porcelain=v2", "--branch"]);
    let head_before = git(&vm, &["rev-parse", "HEAD"]);

    let TurnEnd::Sent { seq, tip, since, left_out, .. } =
        turn_end(&vm, &name(), &fixture.base, &store, true).unwrap()
    else {
        panic!("first turn not sent");
    };
    assert_eq!((seq, since.as_str()), (1, fixture.base.as_str()));
    assert_eq!(left_out, vec![".env".to_string(), "nested".to_string()]);
    // The VM's own index, HEAD and branch are untouched; the commit is kept outside refs/heads.
    assert_eq!(git(&vm, &["status", "--porcelain=v2", "--branch"]), status_before);
    assert_eq!(git(&vm, &["rev-parse", "HEAD"]), head_before);
    assert_eq!(git(&vm, &["rev-parse", WIP_REF]), tip);
    assert_eq!(git(&vm, &["for-each-ref", "refs/cmux-wip/pending"]), "");
    let files = files_of(&vm, &tip);
    assert_eq!(files, vec![".gitignore", "README.md", "src/new.rs"]);

    let fetched = fetch(&laptop, &name(), None, &store).unwrap();
    assert_eq!((fetched.tip.as_deref(), fetched.fetched), (Some(tip.as_str()), 1));
    assert_eq!(git(&laptop, &["rev-parse", BACK_REF]), tip);
    assert_eq!(git(&laptop, &["show", &format!("{tip}:README.md")]), "hello, edited");

    // Nothing changed: nothing goes up.
    assert_eq!(
        turn_end(&vm, &name(), &fixture.base, &store, true).unwrap(),
        TurnEnd::Unchanged { tip: tip.clone() }
    );

    write(&vm.join("src/new.rs"), "fn main() { println!(\"hi\"); }\n");
    let TurnEnd::Sent { seq, tip: second, since, .. } =
        turn_end(&vm, &name(), &fixture.base, &store, true).unwrap()
    else {
        panic!("second turn not sent");
    };
    assert_eq!((seq, since.as_str()), (2, tip.as_str()));
    let kept = read_tip(&store, &name()).unwrap().unwrap();
    assert_eq!(kept.head(), second);
    assert_eq!(kept.bundles.len(), 2);

    // The laptop fetches only what is past its record.
    let fetched = fetch(&laptop, &name(), Some(&tip), &store).unwrap();
    assert_eq!((fetched.tip.as_deref(), fetched.fetched), (Some(second.as_str()), 1));
    assert_eq!(git(&laptop, &["rev-parse", BACK_REF]), second);
    // A fresh laptop repository at the base takes both, in order.
    let fresh = fixture.dir.path().join("fresh.git");
    git(fixture.dir.path(), &["init", "-q", "--bare", "fresh.git"]);
    git(&fresh, &["fetch", "-q", "../vm", &format!("{}:refs/base", fixture.base)]);
    let fetched = fetch(&fresh, &name(), None, &store).unwrap();
    assert_eq!(fetched.fetched, 2);
    assert_eq!(git(&fresh, &["rev-parse", BACK_REF]), second);
}

/// A store whose first `put` fails, as an upload cut off mid-turn.
struct Flaky {
    inner: DirStore,
    failed: Cell<bool>,
}

impl Store for Flaky {
    fn get(&self, key: &str, dest: &Path) -> anyhow::Result<bool> {
        self.inner.get(key, dest)
    }

    fn put(&self, key: &str, from: &Path) -> anyhow::Result<()> {
        if !self.failed.replace(true) {
            anyhow::bail!("upload cut off");
        }
        self.inner.put(key, from)
    }
}

#[test]
fn a_failed_upload_is_sent_again_by_the_next_turn() {
    let fixture = Fixture::new();
    let vm = fixture.vm();
    let store = Flaky { inner: fixture.store(), failed: Cell::new(false) };
    write(&vm.join("a.txt"), "a\n");
    assert!(turn_end(&vm, &name(), &fixture.base, &store, true).is_err());
    assert_eq!(git(&vm, &["for-each-ref", WIP_REF, "refs/cmux-wip/pending"]), "");
    assert_eq!(read_tip(&store, &name()).unwrap(), None);
    let TurnEnd::Sent { seq, since, .. } =
        turn_end(&vm, &name(), &fixture.base, &store, true).unwrap()
    else {
        panic!("retry not sent");
    };
    assert_eq!((seq, since), (1, fixture.base.clone()));
}

#[test]
fn the_unbuilt_store_names_what_it_needs() {
    let fixture = Fixture::new();
    write(&fixture.vm().join("a.txt"), "a\n");
    let error = turn_end(&fixture.vm(), &name(), &fixture.base, &Unwired, true).unwrap_err();
    assert_eq!(error.to_string(), NOT_WIRED);
    let error = fetch(&fixture.laptop(), &name(), None, &Unwired).unwrap_err();
    assert_eq!(error.to_string(), NOT_WIRED);
}

#[test]
fn a_push_on_another_base_is_refused() {
    let fixture = Fixture::new();
    let vm = fixture.vm();
    let store = fixture.store();
    write(&vm.join("a.txt"), "a\n");
    turn_end(&vm, &name(), &fixture.base, &store, true).unwrap();
    git(&vm, &["commit", "-q", "--allow-empty", "-m", "other"]);
    let other = git(&vm, &["rev-parse", "HEAD"]);
    let error = turn_end(&vm, &name(), &other, &store, true).unwrap_err();
    assert!(error.to_string().contains("builds on"), "{error}");
}

#[test]
fn the_record_round_trips_per_folder() {
    let state = tempfile::tempdir().unwrap();
    let local = Path::new("/Users/someone/project");
    assert_eq!(load(state.path(), local).unwrap(), None);
    let record =
        Record { workspace: "ws-123".into(), base: "abc".into(), fetched: Some("def".into()) };
    save(state.path(), local, &record).unwrap();
    assert_eq!(load(state.path(), local).unwrap(), Some(record));
    assert_eq!(load(state.path(), Path::new("/Users/someone/other")).unwrap(), None);
}
