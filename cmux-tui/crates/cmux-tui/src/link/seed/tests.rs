//! The seed plan against real repositories: a bare repository stands in
//! for GitHub (a `url.*.insteadOf` rewrite sends the GitHub URL there), a
//! working copy is cloned from it, and a second clone at the base plays
//! the machine, unbundling and checking out what the plan sent.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use super::plan::{FallbackCode, Planned, PreviousSeed, plan, plan_since, plan_with_base};

const URL: &str = "https://github.com/acme/widget.git";

/// git for fixtures, with a fixed identity and no person's settings.
fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.invalid"])
        .args(["-c", "commit.gpgSign=false", "-c", "init.defaultBranch=main"])
        .args(["-c", "protocol.file.allow=always", "-c", "advice.detachedHead=false"])
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

fn write(path: &Path, text: impl AsRef<[u8]>) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, text).unwrap();
}

struct Fixture {
    dir: tempfile::TempDir,
    remote: PathBuf,
    work: PathBuf,
}

impl Fixture {
    /// A remote with one pushed commit and a working copy cloned from it
    /// whose `origin` is the GitHub URL.
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let remote = dir.path().join("remote.git");
        git(dir.path(), &["init", "-q", "--bare", "remote.git"]);
        let work = dir.path().join("work");
        git(dir.path(), &["clone", "-q", &file_url(&remote), "work"]);
        write(&work.join("README.md"), "widget\n");
        write(&work.join("src/lib.rs"), "pub fn one() {}\n");
        write(&work.join("gone.txt"), "deleted later\n");
        write(&work.join(".gitignore"), "node_modules/\n*.log\n");
        git(&work, &["add", "-A"]);
        git(&work, &["commit", "-q", "-m", "first"]);
        git(&work, &["push", "-q", "origin", "HEAD:main"]);
        git(&work, &["remote", "set-head", "origin", "main"]);
        git(&work, &["branch", "-q", "--set-upstream-to=origin/main"]);
        point_at_github(&work, &remote);
        Self { dir, remote, work }
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }

    /// The machine: a clone of the remote at `base` that fetches the
    /// bundle's refs.
    fn machine(&self, planned: &Planned, bundle: &Path, name: &str) -> PathBuf {
        let machine = self.path(name);
        git(self.dir.path(), &["clone", "-q", &file_url(&self.remote), name]);
        git(&machine, &["checkout", "-q", "--detach", &planned.params.base]);
        apply(&machine, bundle);
        machine
    }
}

/// Verifies `bundle` against the machine's clone and fetches its refs.
fn apply(machine: &Path, bundle: &Path) {
    git(machine, &["bundle", "verify", "-q", bundle.to_str().unwrap()]);
    git(machine, &["fetch", "-q", bundle.to_str().unwrap(), "+refs/cmux-seed/*:refs/cmux-seed/*"]);
}

fn previous_of(planned: &Planned) -> PreviousSeed {
    PreviousSeed {
        head: planned.params.head.clone(),
        index: planned.params.index.clone(),
        work: planned.params.work.clone(),
    }
}

fn file_url(path: &Path) -> String {
    format!("file://{}", path.display())
}

/// `origin` is the GitHub URL; fetches go to the bare repository.
fn point_at_github(work: &Path, remote: &Path) {
    git(work, &["remote", "set-url", "origin", URL]);
    git(work, &["config", &format!("url.{}.insteadOf", file_url(remote)), URL]);
}

/// The person's view of the repository, to show the plan changed nothing.
fn snapshot(work: &Path) -> (String, String, String) {
    (
        git(work, &["status", "--porcelain=v2", "--branch", "--untracked-files=all", "--ignored"]),
        git(work, &["for-each-ref", "--format=%(refname) %(objectname)"]),
        git(work, &["stash", "list"]),
    )
}

/// Every regular file under `root` except `.git`, by relative path.
fn files(root: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut found = BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            if entry.file_name() == ".git" {
                continue;
            }
            if entry.file_type().unwrap().is_dir() {
                stack.push(path);
            } else {
                let relative = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
                found.insert(relative, std::fs::read(path).unwrap());
            }
        }
    }
    found
}

fn bundle_prerequisites(bundle: &Path) -> Vec<String> {
    let bytes = std::fs::read(bundle).unwrap();
    let end = bytes.windows(2).position(|pair| pair == b"\n\n").unwrap();
    String::from_utf8_lossy(&bytes[..end])
        .lines()
        .filter_map(|line| line.strip_prefix('-'))
        .map(|line| line.split(' ').next().unwrap().to_string())
        .collect()
}

#[test]
fn seeds_unpushed_commits_and_the_working_state() {
    let f = Fixture::new();
    let work = &f.work;
    let pushed = git(work, &["rev-parse", "HEAD"]);
    write(&work.join("src/lib.rs"), "pub fn one() {}\npub fn two() {}\n");
    git(work, &["commit", "-q", "-am", "unpushed"]);
    let unpushed = git(work, &["rev-parse", "HEAD"]);
    // Staged, then changed again unstaged; a staged new file; a deletion.
    write(&work.join("README.md"), "widget, staged\n");
    write(&work.join("staged-new.txt"), "new and staged\n");
    git(work, &["add", "README.md", "staged-new.txt"]);
    write(&work.join("README.md"), "widget, staged, then edited\n");
    std::fs::remove_file(work.join("gone.txt")).unwrap();
    // Untracked: plain, big, ignored, secrets.
    write(&work.join("notes/todo.md"), "untracked\n");
    let big: Vec<u8> = (0..3_000_000u32).map(|n| (n % 251) as u8).collect();
    write(&work.join("data/big.bin"), big);
    write(&work.join("node_modules/left-pad/index.js"), "module.exports = 1;\n");
    write(&work.join("debug.log"), "ignored\n");
    write(&work.join(".env"), "TOKEN=secret\n");
    write(&work.join("config/.env.local"), "TOKEN=secret\n");
    write(&work.join("id_rsa"), "-----BEGIN OPENSSH PRIVATE KEY-----\n");
    let before = snapshot(work);

    let bundle = f.path("seed.bundle");
    let planned = plan(work, &bundle).unwrap_or_else(|fallback| panic!("{fallback:?}"));
    assert_eq!(snapshot(work), before, "the plan changed the working copy");

    let params = &planned.params;
    assert_eq!(params.url, URL);
    assert_eq!(params.repo, "acme/widget");
    assert_eq!(params.base, pushed);
    assert_eq!(params.head, unpushed);
    assert_eq!(params.head_ref.as_deref(), Some("refs/heads/main"));
    assert_eq!(params.stash, None);
    assert_eq!(params.sparse, None);
    assert!(!params.lfs);
    assert_eq!(planned.bases, vec![pushed.clone()]);
    assert_eq!(bundle_prerequisites(&bundle), vec![pushed]);
    assert_eq!(planned.bundle_bytes, std::fs::metadata(&bundle).unwrap().len());
    let mut skipped: Vec<_> = planned.skipped.iter().map(|item| item.path.as_str()).collect();
    skipped.sort_unstable();
    assert_eq!(skipped, vec![".env", "config/.env.local", "id_rsa"]);
    assert!(planned.skipped.iter().all(|item| !item.why.is_empty()));

    let machine = f.machine(&planned, &bundle, "machine");
    assert_eq!(git(&machine, &["rev-parse", "refs/cmux-seed/head"]), unpushed);
    assert_eq!(git(&machine, &["rev-parse", "refs/cmux-seed/index"]), params.index);
    assert_eq!(git(&machine, &["rev-parse", "refs/cmux-seed/work"]), params.work);
    assert_eq!(git(&machine, &["rev-parse", "refs/cmux-seed/index^"]), unpushed);
    assert_eq!(git(&machine, &["rev-parse", "refs/cmux-seed/work^"]), params.index);
    // INDEX is exactly what is staged.
    let staged = git(work, &["diff", "--cached", "--name-status"]);
    let index_diff = git(&machine, &["diff", "--name-status", &unpushed, &params.index]);
    assert_eq!(index_diff, staged);
    assert_eq!(git(&machine, &["show", &format!("{}:README.md", params.index)]), "widget, staged");
    // WORK is the working tree, less ignored files and secrets.
    git(&machine, &["checkout", "-q", "--detach", &params.work]);
    let mut expected = files(work);
    expected.retain(|path, _| {
        !path.starts_with("node_modules/")
            && path != "debug.log"
            && !skipped.contains(&path.as_str())
    });
    assert_eq!(files(&machine), expected);
}

#[test]
fn the_same_tree_gives_the_same_commits() {
    let f = Fixture::new();
    write(&f.work.join("notes.txt"), "untracked\n");
    write(&f.work.join("README.md"), "changed\n");
    let one = plan(&f.work, &f.path("one.bundle")).unwrap();
    let two = plan(&f.work, &f.path("two.bundle")).unwrap();
    assert_eq!(one.params, two.params);
    // HEAD is the base: the bundle has no head ref, the params still say it.
    assert_eq!(one.params.head, one.params.base);
    let machine = f.machine(&one, &f.path("one.bundle"), "machine");
    git(&machine, &["checkout", "-q", "--detach", &one.params.work]);
    assert_eq!(std::fs::read_to_string(machine.join("notes.txt")).unwrap(), "untracked\n");
}

#[test]
fn detached_head_has_no_head_ref() {
    let f = Fixture::new();
    git(&f.work, &["checkout", "-q", "--detach", "HEAD"]);
    write(&f.work.join("a.txt"), "a\n");
    git(&f.work, &["add", "a.txt"]);
    git(&f.work, &["commit", "-q", "-m", "detached work"]);
    let planned = plan(&f.work, &f.path("seed.bundle")).unwrap();
    assert_eq!(planned.params.head_ref, None);
    assert_eq!(planned.params.head, git(&f.work, &["rev-parse", "HEAD"]));
    // No upstream: the remote's default branch gives the base.
    assert_eq!(planned.params.base, git(&f.work, &["rev-parse", "origin/main"]));
    f.machine(&planned, &f.path("seed.bundle"), "machine");
}

#[test]
fn the_stash_is_carried() {
    let f = Fixture::new();
    write(&f.work.join("README.md"), "stashed change\n");
    git(&f.work, &["stash", "push", "-q"]);
    let stash = git(&f.work, &["rev-parse", "refs/stash"]);
    let planned = plan(&f.work, &f.path("seed.bundle")).unwrap();
    assert_eq!(planned.params.stash.as_deref(), Some(stash.as_str()));
    let machine = f.machine(&planned, &f.path("seed.bundle"), "machine");
    assert_eq!(git(&machine, &["rev-parse", "refs/cmux-seed/stash"]), stash);
    assert_eq!(git(&machine, &["show", "refs/cmux-seed/stash:README.md"]), "stashed change");
}

#[test]
fn a_linked_worktree_is_planned_from_its_own_state() {
    let f = Fixture::new();
    let linked = f.path("linked");
    git(&f.work, &["worktree", "add", "-q", "-b", "feature", linked.to_str().unwrap()]);
    write(&linked.join("feature.txt"), "feature\n");
    git(&linked, &["add", "feature.txt"]);
    git(&linked, &["commit", "-q", "-m", "feature"]);
    write(&linked.join("scratch.txt"), "untracked in the linked worktree\n");
    let before = snapshot(&linked);
    let planned = plan(&linked, &f.path("seed.bundle")).unwrap();
    assert_eq!(snapshot(&linked), before);
    assert_eq!(planned.params.head_ref.as_deref(), Some("refs/heads/feature"));
    assert_eq!(planned.params.head, git(&linked, &["rev-parse", "HEAD"]));
    let machine = f.machine(&planned, &f.path("seed.bundle"), "machine");
    git(&machine, &["checkout", "-q", "--detach", &planned.params.work]);
    assert_eq!(files(&machine), files(&linked));
}

#[test]
fn sparse_patterns_are_sent() {
    let f = Fixture::new();
    git(&f.work, &["sparse-checkout", "set", "--no-cone", "/README.md", "/src/"]);
    assert!(!f.work.join("gone.txt").exists());
    write(&f.work.join("src/new.rs"), "new\n");
    write(&f.work.join("outside.txt"), "untracked outside the patterns\n");
    let before = snapshot(&f.work);
    let planned = plan(&f.work, &f.path("seed.bundle")).unwrap();
    let sparse = planned.params.sparse.clone().expect("sparse patterns");
    assert!(sparse.contains("/README.md") && sparse.contains("/src/"), "{sparse}");
    let machine = f.machine(&planned, &f.path("seed.bundle"), "machine");
    // Files outside the sparse patterns are kept, not deleted, in WORK.
    let tree = git(&machine, &["ls-tree", "-r", "--name-only", &planned.params.work]);
    assert!(tree.lines().any(|path| path == "gone.txt"), "{tree}");
    assert!(tree.lines().any(|path| path == "src/new.rs"), "{tree}");
    assert!(tree.lines().any(|path| path == "outside.txt"), "{tree}");
    assert_eq!(snapshot(&f.work), before);
}

#[test]
fn lfs_attributes_are_noticed() {
    let f = Fixture::new();
    write(&f.work.join(".gitattributes"), "*.psd filter=lfs diff=lfs merge=lfs -text\n");
    let planned = plan(&f.work, &f.path("seed.bundle")).unwrap();
    assert!(planned.params.lfs);
}

#[test]
fn a_shallow_clone_seeds_while_the_base_is_local() {
    let f = Fixture::new();
    let shallow = f.path("shallow");
    git(f.dir.path(), &["clone", "-q", "--depth", "1", &file_url(&f.remote), "shallow"]);
    point_at_github(&shallow, &f.remote);
    write(&shallow.join("more.txt"), "more\n");
    git(&shallow, &["add", "more.txt"]);
    git(&shallow, &["commit", "-q", "-m", "on a shallow clone"]);
    let planned = plan(&shallow, &f.path("seed.bundle")).unwrap();
    assert_eq!(planned.params.base, git(&shallow, &["rev-parse", "origin/main"]));
    f.machine(&planned, &f.path("seed.bundle"), "machine");
}

#[test]
fn a_base_this_mac_lacks_falls_back() {
    let f = Fixture::new();
    let missing = "0123456789abcdef0123456789abcdef01234567";
    let fallback = plan_with_base(&f.work, &f.path("seed.bundle"), missing).unwrap_err();
    assert_eq!(fallback.code, FallbackCode::NoBase);
    // A base it has works, and the candidates still come back.
    let base = git(&f.work, &["rev-parse", "HEAD"]);
    let planned = plan_with_base(&f.work, &f.path("seed.bundle"), &base).unwrap();
    assert_eq!(planned.params.base, base);
    assert_eq!(planned.bases, vec![base]);
}

#[test]
fn bases_fall_back_to_the_default_tip() {
    let f = Fixture::new();
    // The remote's main moves on; a local branch with no upstream.
    let other = f.path("other");
    git(f.dir.path(), &["clone", "-q", &file_url(&f.remote), "other"]);
    write(&other.join("upstream.txt"), "upstream\n");
    git(&other, &["add", "upstream.txt"]);
    git(&other, &["commit", "-q", "-m", "upstream moves"]);
    git(&other, &["push", "-q", "origin", "HEAD:main"]);
    let fork_point = git(&f.work, &["rev-parse", "HEAD"]);
    git(&f.work, &["checkout", "-q", "-b", "topic", "--no-track"]);
    git(&f.work, &["fetch", "-q", "origin"]);
    let tip = git(&f.work, &["rev-parse", "origin/main"]);
    let planned = plan(&f.work, &f.path("seed.bundle")).unwrap();
    assert_eq!(planned.bases, vec![fork_point, tip.clone()]);
    let retried = plan_with_base(&f.work, &f.path("retry.bundle"), &tip).unwrap();
    assert_eq!(retried.params.base, tip);
    let machine = f.machine(&retried, &f.path("retry.bundle"), "machine");
    git(&machine, &["checkout", "-q", "--detach", &retried.params.work]);
    assert!(!machine.join("upstream.txt").exists());
}

#[test]
fn submodule_local_work_falls_back() {
    let f = Fixture::new();
    let lib_remote = f.path("lib.git");
    git(f.dir.path(), &["init", "-q", "--bare", "lib.git"]);
    let lib = f.path("lib");
    git(f.dir.path(), &["clone", "-q", &file_url(&lib_remote), "lib"]);
    write(&lib.join("lib.txt"), "lib\n");
    git(&lib, &["add", "lib.txt"]);
    git(&lib, &["commit", "-q", "-m", "lib"]);
    git(&lib, &["push", "-q", "origin", "HEAD:main"]);
    git(&f.work, &["submodule", "add", "-q", &file_url(&lib_remote), "vendor/lib"]);
    git(&f.work, &["commit", "-q", "-m", "add lib"]);
    let planned = plan(&f.work, &f.path("seed.bundle")).unwrap();
    let lib_head = git(&lib, &["rev-parse", "HEAD"]);
    assert_eq!(planned.submodules.len(), 1);
    assert_eq!(planned.submodules[0].path, "vendor/lib");
    assert_eq!(planned.submodules[0].commit, lib_head);

    let checkout = f.work.join("vendor/lib");
    write(&checkout.join("lib.txt"), "dirty\n");
    let dirty = plan(&f.work, &f.path("seed.bundle")).unwrap_err();
    assert_eq!(dirty.code, FallbackCode::SubmoduleLocalWork, "{}", dirty.why);
    git(&checkout, &["commit", "-q", "-am", "local only"]);
    let unpushed = plan(&f.work, &f.path("seed.bundle")).unwrap_err();
    assert_eq!(unpushed.code, FallbackCode::SubmoduleLocalWork, "{}", unpushed.why);
}

#[test]
fn folders_that_cannot_be_seeded_say_why() {
    let f = Fixture::new();
    let bundle = f.path("seed.bundle");
    let code = |folder: &Path| plan(folder, &bundle).unwrap_err().code;

    let plain = f.path("plain");
    std::fs::create_dir(&plain).unwrap();
    assert_eq!(code(&plain), FallbackCode::NotGit);
    assert_eq!(code(&f.work.join("src")), FallbackCode::NotTop);

    let fresh = f.path("fresh");
    git(f.dir.path(), &["init", "-q", "fresh"]);
    git(&fresh, &["remote", "add", "origin", URL]);
    assert_eq!(code(&fresh), FallbackCode::NoCommit);

    let lonely = f.path("lonely");
    git(f.dir.path(), &["init", "-q", "lonely"]);
    write(&lonely.join("a.txt"), "a\n");
    git(&lonely, &["add", "a.txt"]);
    git(&lonely, &["commit", "-q", "-m", "a"]);
    assert_eq!(code(&lonely), FallbackCode::NoRemote);
    git(&lonely, &["remote", "add", "upstream", URL]);
    git(&lonely, &["remote", "add", "mirror", URL]);
    assert_eq!(code(&lonely), FallbackCode::AmbiguousRemote);
    // One remote is chosen even when it is not origin; it has no base yet.
    git(&lonely, &["remote", "remove", "mirror"]);
    assert_eq!(code(&lonely), FallbackCode::NoBase);

    git(&f.work, &["remote", "set-url", "origin", "https://user:token@gitlab.com/acme/widget.git"]);
    let fallback = plan(&f.work, &bundle).unwrap_err();
    assert_eq!(fallback.code, FallbackCode::NotGithub);
    assert!(!fallback.why.contains("token"), "{}", fallback.why);
}

#[test]
fn unmerged_index_falls_back() {
    let f = Fixture::new();
    git(&f.work, &["checkout", "-q", "-b", "side"]);
    write(&f.work.join("README.md"), "side\n");
    git(&f.work, &["commit", "-q", "-am", "side"]);
    git(&f.work, &["checkout", "-q", "main"]);
    write(&f.work.join("README.md"), "main\n");
    git(&f.work, &["commit", "-q", "-am", "main"]);
    let merge = Command::new("git")
        .arg("-C")
        .arg(&f.work)
        .args(["-c", "user.name=T", "-c", "user.email=t@t.invalid", "merge", "-q", "side"])
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(!merge.status.success());
    let fallback = plan(&f.work, &f.path("seed.bundle")).unwrap_err();
    assert_eq!(fallback.code, FallbackCode::Unmerged, "{}", fallback.why);
}

#[test]
fn a_delta_seed_sends_only_what_changed() {
    let f = Fixture::new();
    let work = &f.work;
    let big: Vec<u8> =
        (0..2_000_000u32).map(|n| (n.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
    write(&work.join("data/big.bin"), big);
    write(&work.join("README.md"), "first edit\n");
    let full_bundle = f.path("full.bundle");
    let full = plan(work, &full_bundle).unwrap();
    assert_eq!(full.params.since, None);
    assert!(!full.unchanged);
    let machine = f.machine(&full, &full_bundle, "machine");

    // Nothing changed: the same commits, nothing to send.
    let previous = previous_of(&full);
    let same_bundle = f.path("same.bundle");
    let same = plan_since(work, &same_bundle, &previous).unwrap();
    assert!(same.unchanged);
    assert_eq!(same.bundle_bytes, 0);
    assert!(!same_bundle.exists());
    assert_eq!(same.params.work, full.params.work);

    write(&work.join("README.md"), "second edit\n");
    write(&work.join("notes/new.txt"), "new untracked\n");
    let before = snapshot(work);
    let delta_bundle = f.path("delta.bundle");
    let delta = plan_since(work, &delta_bundle, &previous).unwrap();
    assert_eq!(snapshot(work), before);
    assert!(!delta.unchanged);
    assert_eq!(delta.params.base, full.params.work);
    assert_eq!(delta.params.since.as_deref(), Some(full.params.work.as_str()));
    assert!(delta.bases.is_empty());
    // Every prerequisite is a commit the machine has from the first seed;
    // the unchanged index commit is one (the new work commit's parent).
    assert_eq!(delta.params.index, full.params.index);
    let known = [&full.params.work, &full.params.index, &full.params.head];
    let prerequisites = bundle_prerequisites(&delta_bundle);
    assert!(!prerequisites.is_empty());
    assert!(prerequisites.iter().all(|id| known.contains(&id)), "{prerequisites:?}");
    assert!(
        delta.bundle_bytes * 20 < full.bundle_bytes,
        "delta {} vs full {}",
        delta.bundle_bytes,
        full.bundle_bytes
    );

    apply(&machine, &delta_bundle);
    git(&machine, &["checkout", "-q", "--detach", &delta.params.work]);
    assert_eq!(files(&machine), files(work));
}

#[test]
fn a_delta_seed_needs_the_previous_commits() {
    let f = Fixture::new();
    let head = git(&f.work, &["rev-parse", "HEAD"]);
    let missing = "0123456789abcdef0123456789abcdef01234567".to_string();
    let previous = PreviousSeed { head: head.clone(), index: missing.clone(), work: missing };
    let fallback = plan_since(&f.work, &f.path("seed.bundle"), &previous).unwrap_err();
    assert_eq!(fallback.code, FallbackCode::NoPrevious, "{}", fallback.why);
    let short = PreviousSeed { head: head[..7].to_string(), index: head.clone(), work: head };
    let fallback = plan_since(&f.work, &f.path("seed.bundle"), &short).unwrap_err();
    assert_eq!(fallback.code, FallbackCode::NoPrevious);
}
