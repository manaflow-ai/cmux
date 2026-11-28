//! Snapshots of real folders: the person's repository reads byte for byte the same after one,
//! and the bundle, fetched into an empty repository, checks out to the folder's files less what
//! the snapshot leaves out.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::snapshot::{NESTED_PREFIX, WORK_REF, snapshot};

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.invalid"])
        .args(["-c", "commit.gpgSign=false", "-c", "init.defaultBranch=main"])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        // `status` never refreshes the index it is comparing.
        .env("GIT_OPTIONAL_LOCKS", "0")
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

fn write(path: &Path, text: impl AsRef<[u8]>) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, text).unwrap();
}

/// Every file under `dir` (`.git` aside) by path, with its contents.
fn files(dir: &Path) -> BTreeMap<String, Vec<u8>> {
    fn walk(top: &Path, dir: &Path, out: &mut BTreeMap<String, Vec<u8>>) {
        for entry in std::fs::read_dir(dir).unwrap().flatten() {
            if entry.file_name() == ".git" {
                continue;
            }
            let path = entry.path();
            if entry.file_type().unwrap().is_dir() {
                walk(top, &path, out);
            } else {
                let name = path.strip_prefix(top).unwrap().to_string_lossy().into_owned();
                out.insert(name, std::fs::read(&path).unwrap());
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(dir, dir, &mut out);
    out
}

/// Everything about the person's repository a snapshot must leave as it was.
fn person_state(work: &Path) -> Vec<Vec<u8>> {
    let dot = work.join(".git");
    let mut objects = Vec::new();
    for entry in walkdir(&dot.join("objects")) {
        objects.extend_from_slice(entry.as_bytes());
        objects.push(b'\n');
    }
    vec![
        git(work, &["status", "--porcelain=v2", "--branch", "-uall", "--ignored"]).into_bytes(),
        std::fs::read(dot.join("index")).unwrap(),
        std::fs::read(dot.join("HEAD")).unwrap(),
        git(work, &["for-each-ref", "--format=%(refname) %(objectname)"]).into_bytes(),
        git(work, &["stash", "list"]).into_bytes(),
        objects,
    ]
}

fn walkdir(dir: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else { return out };
    for entry in entries.flatten() {
        let path = entry.path();
        out.push(path.display().to_string());
        if entry.file_type().unwrap().is_dir() {
            out.extend(walkdir(&path));
        }
    }
    out.sort();
    out
}

/// A repository that fetched `bundle`'s snapshot (and its nested ones) and checked it out.
fn receive(into: &Path, bundle: &Path) -> String {
    if !into.join(".git").exists() {
        std::fs::create_dir_all(into).unwrap();
        git(into, &["init", "-q"]);
    }
    let bundle = bundle.to_str().unwrap();
    git(into, &["bundle", "verify", "-q", bundle]);
    git(into, &["fetch", "-q", "-f", bundle, &format!("{WORK_REF}:refs/heads/snap")]);
    git(into, &["checkout", "-q", "-f", "snap"]);
    git(into, &["rev-parse", "HEAD"])
}

struct Folder {
    dir: tempfile::TempDir,
}

impl Folder {
    fn new() -> Self {
        Self { dir: tempfile::tempdir().unwrap() }
    }
    fn work(&self) -> PathBuf {
        self.dir.path().join("work")
    }
    fn store(&self) -> PathBuf {
        self.dir.path().join("state/store.git")
    }
    fn bundle(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }
}

#[test]
fn a_git_folder_snapshots_with_its_index_head_refs_and_objects_untouched() {
    let folder = Folder::new();
    let work = folder.work();
    std::fs::create_dir_all(&work).unwrap();
    git(&work, &["init", "-q"]);
    write(&work.join(".gitignore"), "build/\n");
    write(&work.join("a.txt"), "one\n");
    write(&work.join("staged.txt"), "staged\n");
    git(&work, &["add", ".gitignore", "a.txt"]);
    git(&work, &["commit", "-q", "-m", "first"]);
    git(&work, &["add", "staged.txt"]);
    write(&work.join("a.txt"), "one, edited\n");
    write(&work.join("new.txt"), "untracked\n");
    write(&work.join(".env"), "SECRET=1\n");
    write(&work.join("sub/id_ed25519"), "key\n");
    write(&work.join("build/out.o"), "ignored\n");
    std::fs::create_dir_all(work.join("empty/inner")).unwrap();
    write(&work.join(".git/info/exclude"), "local-only.txt\n");
    write(&work.join("local-only.txt"), "excluded by the person\n");
    let head = git(&work, &["rev-parse", "HEAD"]);
    let before = person_state(&work);

    let made = snapshot(&work, &folder.store(), &folder.bundle("one.bundle"), None).unwrap();

    assert_eq!(person_state(&work), before, "the person's repository changed");
    assert!(made.git);
    assert_eq!(made.parent.as_deref(), Some(head.as_str()));
    let skipped: Vec<&str> = made.skipped.iter().map(|item| item.path.as_str()).collect();
    assert_eq!(skipped, vec![".env", "sub/id_ed25519"]);
    assert_eq!(made.empty_folders, vec!["empty/inner".to_string()]);

    let receiver = folder.dir.path().join("receiver");
    assert_eq!(receive(&receiver, &folder.bundle("one.bundle")), made.commit);
    assert_eq!(git(&receiver, &["rev-parse", "HEAD^"]), head, "HEAD's history travels");
    let mut expected = files(&work);
    for gone in [".env", "sub/id_ed25519", "build/out.o", "local-only.txt"] {
        expected.remove(gone);
    }
    assert_eq!(files(&receiver), expected);
    let message = git(&receiver, &["log", "-1", "--format=%B"]);
    assert!(message.contains("empty: empty/inner"), "{message}");

    // The same state again is the same commit.
    let again = snapshot(&work, &folder.store(), &folder.bundle("again.bundle"), None).unwrap();
    assert_eq!(again.commit, made.commit);
    assert_eq!(person_state(&work), before);
}

#[test]
fn a_folder_that_is_not_git_gives_a_bundle_that_clones_to_its_files() {
    let folder = Folder::new();
    let work = folder.work();
    write(&work.join("README.md"), "hello\n");
    write(&work.join("src/main.rs"), "fn main() {}\n");
    write(&work.join(".gitignore"), "*.log\n");
    write(&work.join("debug.log"), "noise\n");
    write(&work.join(".env.local"), "TOKEN=x\n");
    write(&work.join("node_modules/pkg/index.js"), "dep\n");
    std::fs::create_dir_all(work.join("assets")).unwrap();

    let made = snapshot(&work, &folder.store(), &folder.bundle("one.bundle"), None).unwrap();
    assert!(!made.git);
    assert_eq!(made.parent, None);
    assert!(!work.join(".git").exists(), "a not-git folder stays not git");
    let skipped: Vec<&str> = made.skipped.iter().map(|item| item.path.as_str()).collect();
    assert!(skipped.contains(&".env.local"), "{skipped:?}");
    assert!(skipped.contains(&"node_modules/"), "{skipped:?}");
    assert_eq!(made.empty_folders, vec!["assets".to_string()]);

    let clone = folder.dir.path().join("clone");
    receive(&clone, &folder.bundle("one.bundle"));
    let mut expected = files(&work);
    for gone in ["debug.log", ".env.local", "node_modules/pkg/index.js"] {
        expected.remove(gone);
    }
    assert_eq!(files(&clone), expected);

    // An edit since: a thin bundle the clone takes on top of the first.
    write(&work.join("src/main.rs"), "fn main() { println!(\"hi\"); }\n");
    let next =
        snapshot(&work, &folder.store(), &folder.bundle("two.bundle"), Some(&made.commit)).unwrap();
    assert_eq!(next.since.as_deref(), Some(made.commit.as_str()));
    assert_eq!(next.parent.as_deref(), Some(made.commit.as_str()));
    assert!(
        next.bundle_bytes < made.bundle_bytes,
        "{} >= {}",
        next.bundle_bytes,
        made.bundle_bytes
    );
    receive(&clone, &folder.bundle("two.bundle"));
    assert_eq!(files(&clone).get("src/main.rs"), files(&work).get("src/main.rs"));

    // Nothing changed since: nothing to send.
    let same = snapshot(&work, &folder.store(), &folder.bundle("three.bundle"), Some(&next.commit))
        .unwrap();
    assert!(same.unchanged);
    assert_eq!(same.commit, next.commit);
    assert_eq!(same.bundle_bytes, 0);
}

#[test]
fn a_nested_repository_is_snapshotted_as_its_own_commit() {
    let folder = Folder::new();
    let work = folder.work();
    write(&work.join("top.txt"), "top\n");
    let inner = work.join("vendor/lib");
    std::fs::create_dir_all(&inner).unwrap();
    git(&inner, &["init", "-q"]);
    write(&inner.join("lib.rs"), "pub fn f() {}\n");
    git(&inner, &["add", "lib.rs"]);
    git(&inner, &["commit", "-q", "-m", "lib"]);
    write(&inner.join("wip.rs"), "// uncommitted\n");
    write(&inner.join(".env"), "K=V\n");
    let inner_head = git(&inner, &["rev-parse", "HEAD"]);
    let before = person_state(&inner);

    let made = snapshot(&work, &folder.store(), &folder.bundle("one.bundle"), None).unwrap();
    assert_eq!(person_state(&inner), before, "the nested repository changed");
    assert_eq!(made.nested.len(), 1);
    let nested = &made.nested[0];
    assert_eq!(nested.path, "vendor/lib");
    assert_eq!(nested.reference, format!("{NESTED_PREFIX}0"));
    assert!(made.skipped.iter().any(|item| item.path == "vendor/lib/.env"), "{:?}", made.skipped);

    let receiver = folder.dir.path().join("receiver");
    receive(&receiver, &folder.bundle("one.bundle"));
    let link = git(&receiver, &["ls-tree", "HEAD", "vendor/lib"]);
    assert!(link.starts_with(&format!("160000 commit {}", nested.commit)), "{link}");
    let bundle = folder.bundle("one.bundle");
    git(
        &receiver,
        &["fetch", "-q", bundle.to_str().unwrap(), &format!("{}:refs/heads/lib", nested.reference)],
    );
    assert_eq!(git(&receiver, &["rev-parse", "lib^"]), inner_head);
    let names = git(&receiver, &["ls-tree", "--name-only", "lib"]);
    assert_eq!(names, "lib.rs\nwip.rs");
}
