//! `git-seed-v1` end to end, with no network: a `file://` bare repository
//! stands in for GitHub (the test-only config rewrites the request's
//! `https://github.com/o/n.git` to it), and a "Mac" checkout makes the
//! bundle the way the Mac side does (HEAD, INDEX and WORK commits built with
//! a temporary index, `refs/cmux-seed/*`, `^base`).

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::git::{Credential, Git};
use super::job::Config;
use super::*;
use crate::fs_ops::Roots;

const URL: &str = "https://github.com/o/n.git";

/// A temporary home (the `fs-v1` root), removed on drop.
struct Home {
    path: PathBuf,
}

impl Home {
    fn new(label: &str) -> Self {
        let mut random = [0u8; 6];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-gitseed-{label}-{suffix}"));
        std::fs::create_dir_all(&path).unwrap();
        Self { path: std::fs::canonicalize(path).unwrap() }
    }

    fn join(&self, name: &str) -> PathBuf {
        self.path.join(name)
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// `git ARGS` in `dir` with no user or system config; its trimmed stdout.
fn git(dir: &Path, args: &[&str]) -> String {
    git_env(dir, args, &[])
}

fn git_env(dir: &Path, args: &[&str], env: &[(&str, &Path)]) -> String {
    let mut command = Command::new("git");
    command
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false"])
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_INDEX_FILE");
    for (name, value) in env {
        command.env(name, value);
    }
    let output = command.output().unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

/// A commit as the Mac's seed plan makes its INDEX and WORK commits: the
/// fixed identity and date, so the machine's export of the same state is
/// the same commit.
fn seed_commit(dir: &Path, tree: &str, parent: &str, message: &str) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["commit-tree", "--no-gpg-sign", "-p", parent, "-m", message, tree])
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "cmux seed")
        .env("GIT_AUTHOR_EMAIL", "seed@cmux.invalid")
        .env("GIT_AUTHOR_DATE", "946684800 +0000")
        .env("GIT_COMMITTER_NAME", "cmux seed")
        .env("GIT_COMMITTER_EMAIL", "seed@cmux.invalid")
        .env("GIT_COMMITTER_DATE", "946684800 +0000")
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

fn write(path: &Path, text: &str) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, text).unwrap();
}

/// The "GitHub" remote and the Mac's checkout of it.
struct World {
    home: Home,
    remote: PathBuf,
    mac: PathBuf,
    base: String,
}

impl World {
    /// A pushed base commit (`a`, `b`, `d/c`, `gone`) on `main`.
    fn new(label: &str) -> Self {
        let home = Home::new(label);
        let mac = home.join("mac");
        std::fs::create_dir_all(&mac).unwrap();
        git(&mac, &["init", "-q", "-b", "main"]);
        write(&mac.join("a"), "a\n");
        write(&mac.join("b"), "b\n");
        write(&mac.join("d/c"), "c\n");
        write(&mac.join("gone"), "gone\n");
        write(&mac.join(".gitignore"), "ignored/\n");
        git(&mac, &["add", "-A"]);
        git(&mac, &["commit", "-q", "-m", "base"]);
        let base = git(&mac, &["rev-parse", "HEAD"]);
        let remote = home.join("remote.git");
        git(
            &home.path,
            &["clone", "-q", "--bare", mac.to_str().unwrap(), remote.to_str().unwrap()],
        );
        git(&remote, &["config", "uploadpack.allowFilter", "true"]);
        git(&remote, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
        git(&mac, &["remote", "add", "origin", remote.to_str().unwrap()]);
        git(&mac, &["fetch", "-q", "origin"]);
        Self { home, remote, mac, base }
    }

    fn service(&self) -> GitSeedService {
        let remote = format!("file://{}", self.remote.display());
        let config = Config {
            git: Git {
                extra_config: vec![
                    format!("url.{remote}.insteadOf={URL}"),
                    "protocol.file.allow=always".into(),
                ],
            },
            credentials: Some(vec![Credential::Anonymous]),
        };
        GitSeedService::with_config(Roots::new([self.home.path.clone()]), config)
    }

    /// The Mac side: HEAD, INDEX and WORK commits and the stash, in a bundle
    /// at `<home>/<name>.bundle` whose prerequisites are `exclude`.
    fn snapshot(&self, name: &str, exclude: &[&str]) -> Snapshot {
        let mac = &self.mac;
        let head = git(mac, &["rev-parse", "HEAD"]);
        let index_tree = git(mac, &["write-tree"]);
        let index = seed_commit(mac, &index_tree, &head, "cmux seed index");
        let temp = self.home.path.join(format!("{name}.index"));
        let git_dir = PathBuf::from(git(mac, &["rev-parse", "--absolute-git-dir"]));
        std::fs::copy(git_dir.join("index"), &temp).unwrap();
        git_env(mac, &["add", "-A", "--sparse"], &[("GIT_INDEX_FILE", &temp)]);
        let work_tree = git_env(mac, &["write-tree"], &[("GIT_INDEX_FILE", &temp)]);
        std::fs::remove_file(&temp).unwrap();
        let work = seed_commit(mac, &work_tree, &index, "cmux seed work");
        let stash = Command::new("git")
            .arg("-C")
            .arg(mac)
            .args(["rev-parse", "--verify", "--quiet", "refs/stash"])
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned());
        git(mac, &["update-ref", "refs/cmux-seed/head", &head]);
        git(mac, &["update-ref", "refs/cmux-seed/index", &index]);
        git(mac, &["update-ref", "refs/cmux-seed/work", &work]);
        let mut refs = vec!["refs/cmux-seed/head", "refs/cmux-seed/index", "refs/cmux-seed/work"];
        if let Some(stash) = &stash {
            git(mac, &["update-ref", "refs/cmux-seed/stash", stash]);
            refs.push("refs/cmux-seed/stash");
        }
        let bundle = self.home.path.join(format!("{name}.bundle"));
        let mut args = vec!["bundle", "create", "-q", bundle.to_str().unwrap()];
        args.extend(refs);
        let excluded: Vec<String> = exclude.iter().map(|sha| format!("^{sha}")).collect();
        args.extend(excluded.iter().map(String::as_str));
        git(mac, &args);
        let head_ref = Command::new("git")
            .arg("-C")
            .arg(mac)
            .args(["symbolic-ref", "-q", "HEAD"])
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned());
        Snapshot { bundle, head_ref, head, index, work, stash }
    }

    fn start_params(&self, folder: &Path, snapshot: &Snapshot) -> Value {
        json!({
            "folder": folder,
            "url": URL,
            "repo": "o/n",
            "base": self.base,
            "bundle": snapshot.bundle,
            "head_ref": snapshot.head_ref,
            "head": snapshot.head,
            "index": snapshot.index,
            "work": snapshot.work,
            "stash": snapshot.stash,
            "sparse": Value::Null,
            "lfs": false,
        })
    }
}

struct Snapshot {
    bundle: PathBuf,
    head_ref: Option<String>,
    head: String,
    index: String,
    work: String,
    stash: Option<String>,
}

fn start(service: &GitSeedService, params: &Value) -> Result<String, SeedRefusal> {
    let answer = service.call("git.seed.start", params)?;
    Ok(answer["job"].as_str().unwrap().to_owned())
}

/// Waits (bounded) for the job to leave `running`; its last status.
fn wait(service: &GitSeedService, job: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        let status = service.call("git.seed.status", &json!({ "job": job })).unwrap();
        if status["state"] != "running" {
            return status;
        }
        assert!(Instant::now() < deadline, "the seed did not finish: {status}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn seed(world: &World, params: &Value) -> Value {
    let service = world.service();
    let job = start(&service, params).unwrap();
    wait(&service, &job)
}

/// What must match between the Mac and the machine.
fn state(dir: &Path) -> Vec<String> {
    vec![
        git(dir, &["status", "--porcelain", "--untracked-files=all"]),
        git(dir, &["rev-parse", "HEAD"]),
        git(dir, &["write-tree"]),
        git(dir, &["diff"]),
        git(dir, &["diff", "--cached"]),
        Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["symbolic-ref", "-q", "HEAD"])
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
            .unwrap(),
        Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(["rev-parse", "--verify", "--quiet", "refs/stash"])
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
            .unwrap(),
    ]
}

/// The Mac's branch with an unpushed commit, a stash, staged and unstaged
/// edits of one file, a staged add, a deletion, an untracked file and an
/// ignored one.
fn dirty_branch(world: &World) {
    let mac = &world.mac;
    git(mac, &["checkout", "-q", "-b", "feature"]);
    write(&mac.join("b"), "b\nunpushed\n");
    git(mac, &["commit", "-q", "-a", "-m", "unpushed"]);
    write(&mac.join("a"), "a\nstashed\n");
    git(mac, &["stash", "-q"]);
    write(&mac.join("a"), "a\nstaged\n");
    git(mac, &["add", "a"]);
    write(&mac.join("a"), "a\nstaged\nunstaged\n");
    write(&mac.join("d/new"), "new\n");
    git(mac, &["add", "d/new"]);
    std::fs::remove_file(mac.join("gone")).unwrap();
    write(&mac.join("untracked/u.txt"), "untracked\n");
    write(&mac.join("ignored/big"), "ignored\n");
}

#[test]
fn a_seed_reproduces_branch_head_index_worktree_untracked_and_stash() {
    let world = World::new("full");
    dirty_branch(&world);
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("work/project");
    let status = seed(&world, &world.start_params(&folder, &snapshot));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&folder), state(&world.mac));
    assert_eq!(git(&folder, &["symbolic-ref", "HEAD"]), "refs/heads/feature");
    assert!(!folder.join("ignored").exists(), "ignored files are never sent");
    assert!(!snapshot.bundle.exists(), "the applied bundle is deleted");
    assert_eq!(git(&folder, &["remote", "get-url", "origin"]), URL);
}

#[test]
fn a_detached_head_is_seeded_detached() {
    let world = World::new("detached");
    write(&world.mac.join("a"), "a\ncommitted\n");
    git(&world.mac, &["commit", "-q", "-a", "-m", "local"]);
    git(&world.mac, &["checkout", "-q", "--detach"]);
    write(&world.mac.join("b"), "b\nedited\n");
    let snapshot = world.snapshot("one", &[&world.base]);
    assert_eq!(snapshot.head_ref, None);
    let folder = world.home.join("project");
    let status = seed(&world, &world.start_params(&folder, &snapshot));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&folder), state(&world.mac));
}

#[test]
fn a_main_branch_tracks_its_upstream() {
    let world = World::new("upstream");
    write(&world.mac.join("a"), "a\nedited\n");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let status = seed(&world, &world.start_params(&folder, &snapshot));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&folder), state(&world.mac));
    assert_eq!(git(&folder, &["rev-parse", "--abbrev-ref", "main@{upstream}"]), "origin/main");
}

#[test]
fn a_sparse_checkout_keeps_its_patterns_and_untracked_files() {
    let world = World::new("sparse");
    let mac = &world.mac;
    git(mac, &["sparse-checkout", "set", "--no-cone", "/a", "/d/"]);
    write(&mac.join("d/c"), "c\nedited\n");
    write(&mac.join("outside/untracked"), "u\n");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    params["sparse"] = "/a\n/d/\n".into();
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert!(!folder.join("b").exists(), "outside the patterns");
    assert_eq!(std::fs::read_to_string(folder.join("outside/untracked")).unwrap(), "u\n");
    assert_eq!(state(&folder), state(mac));
}

#[test]
fn a_base_the_remote_lacks_fails_base_missing() {
    let world = World::new("base");
    write(&world.mac.join("a"), "a\nnever pushed\n");
    git(&world.mac, &["commit", "-q", "-a", "-m", "local"]);
    let local = git(&world.mac, &["rev-parse", "HEAD"]);
    let snapshot = world.snapshot("one", &[&local]);
    let folder = world.home.join("project");
    let mut params = world.start_params(&folder, &snapshot);
    params["base"] = local.into();
    let status = seed(&world, &params);
    assert_eq!(status["state"], "failed");
    assert_eq!(status["error_code"], "seed.base_missing", "{status}");
}

#[test]
fn a_non_empty_folder_is_refused_and_kept() {
    let world = World::new("nonempty");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    write(&folder.join("mine.txt"), "mine\n");
    let status = seed(&world, &world.start_params(&folder, &snapshot));
    assert_eq!(status["state"], "failed");
    assert_eq!(status["error_code"], "seed.folder_not_empty", "{status}");
    assert_eq!(std::fs::read_to_string(folder.join("mine.txt")).unwrap(), "mine\n");
}

#[test]
fn paths_outside_the_roots_are_refused() {
    let world = World::new("outside");
    let snapshot = world.snapshot("one", &[&world.base]);
    let service = world.service();
    let elsewhere = Home::new("elsewhere");
    std::os::unix::fs::symlink(&elsewhere.path, world.home.join("link")).unwrap();
    for folder in [
        elsewhere.join("project"),
        world.home.join("link/project"),
        PathBuf::from(format!("{}/x/../../project", world.home.path.display())),
        world.home.path.clone(),
    ] {
        let params = world.start_params(&folder, &snapshot);
        let refusal = start(&service, &params).unwrap_err();
        assert_eq!(refusal.code, "seed.bad_request", "{}", folder.display());
    }
    let outside_bundle = elsewhere.join("x.bundle");
    std::fs::copy(&snapshot.bundle, &outside_bundle).unwrap();
    let mut params = world.start_params(&world.home.join("project"), &snapshot);
    params["bundle"] = outside_bundle.display().to_string().into();
    assert_eq!(start(&service, &params).unwrap_err().code, "seed.bad_request");
    assert!(!world.home.join("project").exists());
}

#[test]
fn bad_urls_shas_and_refs_are_bad_requests() {
    let world = World::new("bad");
    let snapshot = world.snapshot("one", &[&world.base]);
    let service = world.service();
    let folder = world.home.join("project");
    let good = world.start_params(&folder, &snapshot);
    for (key, value) in [
        ("url", json!("https://gitlab.com/o/n.git")),
        ("url", json!("https://github.com/o/n")),
        ("url", json!(format!("file://{}", world.remote.display()))),
        ("repo", json!("o/other")),
        ("base", json!("main")),
        ("head", json!("abc")),
        ("work", json!("--upload-pack=x")),
        ("stash", json!("Z".repeat(40))),
        ("head_ref", json!("refs/tags/v1")),
        ("head_ref", json!("refs/heads/a..b")),
        ("folder", json!("relative/path")),
    ] {
        let mut params = good.clone();
        params[key] = value.clone();
        let refusal = start(&service, &params).unwrap_err();
        assert_eq!(refusal.code, "seed.bad_request", "{key}={value}");
    }
    let answer = answer_line(Some(&service), true, r#"{"id":3,"cmd":"git.seed.start"}"#);
    assert_eq!(answer["id"], 3);
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["error_code"], "seed.bad_request");
}

#[test]
fn a_retried_start_returns_the_same_job() {
    let world = World::new("retry");
    write(&world.mac.join("a"), "a\nedited\n");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let service = world.service();
    let params = world.start_params(&folder, &snapshot);
    let first = start(&service, &params).unwrap();
    let second = start(&service, &params).unwrap();
    assert_eq!(first, second);
    assert_eq!(wait(&service, &first)["state"], "done");
    assert_eq!(start(&service, &params).unwrap(), first, "a done job too");
    let unknown = service.call("git.seed.status", &json!({ "job": "seed_nope" })).unwrap_err();
    assert_eq!(unknown.code, "seed.unknown_job");
}

#[test]
fn hooks_in_the_repository_never_run() {
    let world = World::new("hooks");
    write(&world.mac.join("a"), "a\none\n");
    let first = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    assert_eq!(seed(&world, &world.start_params(&folder, &first))["state"], "done");
    let marker = world.home.join("hook-ran");
    let hook = format!("#!/bin/sh\ntouch '{}'\n", marker.display());
    for name in ["post-checkout", "post-merge", "reference-transaction", "post-index-change"] {
        let path = folder.join(".git/hooks").join(name);
        write(&path, &hook);
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    git(&folder, &["config", "core.hooksPath", folder.join(".git/hooks").to_str().unwrap()]);
    // A second full seed of the same folder (fetch, checkout, read-tree).
    write(&world.mac.join("a"), "a\ntwo\n");
    let second = world.snapshot("two", &[&world.base]);
    let status = seed(&world, &world.start_params(&folder, &second));
    assert_eq!(status["state"], "done", "{status}");
    // Checked before this test runs git there itself (its own `git status`
    // runs the hooks: only the seed turns them off).
    assert!(!marker.exists(), "a repository hook ran during the seed");
    git(&folder, &["config", "core.hooksPath", "/dev/null"]);
    assert_eq!(state(&folder), state(&world.mac));
}

#[test]
fn a_delta_seed_applies_edits_adds_and_deletes_without_the_network() {
    let world = World::new("delta");
    dirty_branch(&world);
    let first = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    assert_eq!(seed(&world, &world.start_params(&folder, &first))["state"], "done");
    // The remote is gone: a delta that needs the network fails.
    std::fs::remove_dir_all(&world.remote).unwrap();
    let mac = &world.mac;
    write(&mac.join("a"), "a\nstaged\nunstaged\nmore\n");
    write(&mac.join("added"), "added\n");
    std::fs::remove_file(mac.join("b")).unwrap();
    std::fs::remove_file(mac.join("untracked/u.txt")).unwrap();
    write(&mac.join("untracked/v.txt"), "v\n");
    write(&mac.join("d/c"), "c\nnext\n");
    git(mac, &["commit", "-q", "-m", "second", "--", "d/c"]);
    let second = world.snapshot("two", &[&first.work, &first.head]);
    let mut params = world.start_params(&folder, &second);
    params["since"] = first.work.clone().into();
    params["base"] = first.work.into();
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&folder), state(mac));
    assert!(!folder.join("b").exists());
    assert!(!folder.join("untracked/u.txt").exists(), "the previous seed's untracked file goes");
    assert_eq!(std::fs::read_to_string(folder.join("added")).unwrap(), "added\n");
}

#[test]
fn a_delta_on_another_seed_fails_since_mismatch() {
    let world = World::new("since");
    write(&world.mac.join("a"), "a\none\n");
    let first = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    assert_eq!(seed(&world, &world.start_params(&folder, &first))["state"], "done");
    write(&world.mac.join("a"), "a\ntwo\n");
    let second = world.snapshot("two", &[&first.work, &first.head]);
    let mut params = world.start_params(&folder, &second);
    params["since"] = world.base.clone().into();
    let status = seed(&world, &params);
    assert_eq!(status["error_code"], "seed.since_mismatch", "{status}");
    let fresh = world.home.join("fresh");
    params["folder"] = fresh.display().to_string().into();
    params["since"] = first.work.into();
    let status = seed(&world, &params);
    assert_eq!(status["error_code"], "seed.since_mismatch", "{status}");
}

#[test]
fn a_delta_after_the_machine_changed_fails_and_changes_nothing() {
    let world = World::new("changed");
    write(&world.mac.join("a"), "a\none\n");
    let first = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    assert_eq!(seed(&world, &world.start_params(&folder, &first))["state"], "done");
    write(&world.mac.join("a"), "a\ntwo\n");
    let second = world.snapshot("two", &[&first.work, &first.head]);
    let mut params = world.start_params(&folder, &second);
    params["since"] = first.work.into();
    for change in ["edit", "untracked", "stage"] {
        match change {
            "edit" => write(&folder.join("b"), "b\nmachine\n"),
            "untracked" => write(&folder.join("machine.txt"), "m\n"),
            _ => {
                write(&folder.join("d/c"), "c\nstaged on the machine\n");
                git(&folder, &["add", "d/c"]);
            }
        }
        let before = state(&folder);
        let status = seed(&world, &params);
        assert_eq!(status["error_code"], "seed.machine_changed", "{change}: {status}");
        assert_eq!(state(&folder), before, "{change}: nothing changed");
        assert!(second.bundle.exists());
    }
}

#[test]
fn the_wire_answers_in_the_daemon_envelope() {
    let answer = answer_line(None, true, r#"{"id":1,"cmd":"git.seed.status","job":"x"}"#);
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["error_code"], "seed.unavailable");
    let world = World::new("wire");
    let service = world.service();
    let answer =
        answer_line(Some(&service), false, r#"{"id":2,"cmd":"git.seed.status","job":"x"}"#);
    assert_eq!(answer["error_code"], "seed.permission_denied");
    assert!(frame_command(r#"{"id":1,"cmd":"git.seed.start"}"#).is_some());
    assert!(frame_command(r#"{"id":1,"cmd":"git.seed.start","protocol":"p"}"#).is_none());
    assert!(frame_command(r#"{"id":1,"cmd":"git.seed.cancel"}"#).is_none());
    assert!(frame_command(r#"{"id":1,"cmd":"git.seed.export"}"#).is_some());
    assert!(advertised().is_empty(), "tests never install the fs owner");
}

fn clone_params(folder: &Path, git_ref: Option<&str>) -> Value {
    json!({ "folder": folder, "url": URL, "repo": "o/n", "ref": git_ref, "lfs": false })
}

#[test]
fn a_clone_only_start_checks_out_the_default_branch_or_a_tag() {
    let world = World::new("clone");
    git(&world.mac, &["tag", "v1"]);
    write(&world.mac.join("a"), "a\nafter the tag\n");
    git(&world.mac, &["commit", "-q", "-a", "-m", "after"]);
    git(&world.mac, &["push", "-q", "origin", "main", "v1"]);
    let tip = git(&world.mac, &["rev-parse", "HEAD"]);
    let folder = world.home.join("default");
    let status = seed(&world, &clone_params(&folder, None));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["head"], tip.as_str());
    assert_eq!(status["head_ref"], "refs/heads/main");
    assert_eq!(std::fs::read_to_string(folder.join("a")).unwrap(), "a\nafter the tag\n");
    assert_eq!(git(&folder, &["status", "--porcelain"]), "");
    let tagged = world.home.join("tagged");
    let status = seed(&world, &clone_params(&tagged, Some("v1")));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(status["head"], world.base.as_str());
    assert_eq!(status["head_ref"], Value::Null, "a tag is detached");
    assert_eq!(std::fs::read_to_string(tagged.join("a")).unwrap(), "a\n");
    let missing = world.home.join("missing");
    let status = seed(&world, &clone_params(&missing, Some("no-such-branch")));
    assert_eq!(status["error_code"], "seed.checkout_failed", "{status}");
    let status = seed(&world, &clone_params(&folder, None));
    assert_eq!(status["error_code"], "seed.folder_not_empty", "{status}");
}

/// git bundle leaves out a seed ref already behind a prerequisite: with
/// nothing unpushed, `refs/cmux-seed/head` is not in the bundle. The
/// machine takes the shas from the params.
#[test]
fn a_seed_with_nothing_unpushed_has_no_head_ref_in_its_bundle() {
    let world = World::new("nounpushed");
    write(&world.mac.join("a"), "a\nonly the work tree\n");
    write(&world.mac.join("new"), "untracked\n");
    let snapshot = world.snapshot("one", &[&world.base]);
    assert_eq!(snapshot.head, world.base);
    let heads = git(&world.home.path, &["bundle", "list-heads", snapshot.bundle.to_str().unwrap()]);
    assert!(!heads.contains("refs/cmux-seed/head"), "{heads}");
    let folder = world.home.join("project");
    let status = seed(&world, &world.start_params(&folder, &snapshot));
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&folder), state(&world.mac));
    assert_eq!(git(&folder, &["rev-parse", "refs/cmux-seed/head"]), world.base);
}

/// A delta where only the work tree changed: the bundle carries no head and
/// no index ref (both are prerequisites).
#[test]
fn a_delta_of_only_the_work_tree_applies() {
    let world = World::new("worktreedelta");
    write(&world.mac.join("a"), "a\nstaged\n");
    git(&world.mac, &["add", "a"]);
    let first = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    assert_eq!(seed(&world, &world.start_params(&folder, &first))["state"], "done");
    write(&world.mac.join("b"), "b\nwork only\n");
    let mac = &world.mac;
    // Same HEAD and same index: reuse the first INDEX commit, as the Mac
    // side does when the staged tree is unchanged.
    let temp = world.home.path.join("two.index");
    let git_dir = PathBuf::from(git(mac, &["rev-parse", "--absolute-git-dir"]));
    std::fs::copy(git_dir.join("index"), &temp).unwrap();
    git_env(mac, &["add", "-A"], &[("GIT_INDEX_FILE", &temp)]);
    let tree = git_env(mac, &["write-tree"], &[("GIT_INDEX_FILE", &temp)]);
    let work = git(mac, &["commit-tree", &tree, "-p", &first.index, "-m", "work"]);
    git(mac, &["update-ref", "refs/cmux-seed/work", &work]);
    let bundle = world.home.path.join("two.bundle");
    let not_first_work = format!("^{}", first.work);
    let not_index = format!("^{}", first.index);
    git(
        mac,
        &[
            "bundle",
            "create",
            "-q",
            bundle.to_str().unwrap(),
            "refs/cmux-seed/head",
            "refs/cmux-seed/index",
            "refs/cmux-seed/work",
            &not_first_work,
            &not_index,
        ],
    );
    let heads = git(&world.home.path, &["bundle", "list-heads", bundle.to_str().unwrap()]);
    assert!(heads.contains("refs/cmux-seed/work"), "{heads}");
    assert!(!heads.contains("refs/cmux-seed/index"), "{heads}");
    let second = Snapshot {
        bundle,
        head_ref: first.head_ref,
        head: first.head,
        index: first.index,
        work,
        stash: None,
    };
    let mut params = world.start_params(&folder, &second);
    params["since"] = first.work.clone().into();
    params["base"] = first.work.into();
    std::fs::remove_dir_all(&world.remote).unwrap();
    let status = seed(&world, &params);
    assert_eq!(status["state"], "done", "{status}");
    assert_eq!(state(&folder), state(mac));
}

/// A seed never nests: not inside another repository (a seed's checkout
/// could swap a directory above it for a symlink out of the home), and not
/// inside or around another seed's folder.
#[test]
fn a_seed_folder_never_nests() {
    let world = World::new("nested");
    let snapshot = world.snapshot("one", &[&world.base]);
    let service = world.service();
    let outer = world.home.join("group/outer");
    let job = start(&service, &world.start_params(&outer, &snapshot)).unwrap();
    assert_eq!(wait(&service, &job)["state"], "done");
    for folder in [outer.join("inner"), world.home.join("mac/inside")] {
        let second = world.snapshot("two", &[&world.base]);
        let refusal = start(&service, &world.start_params(&folder, &second)).unwrap_err();
        assert_eq!(refusal.code, "seed.bad_request", "{}", folder.display());
        assert!(second.bundle.exists(), "a refused start keeps the upload");
    }
    let around = world.home.join("group");
    let third = world.snapshot("three", &[&world.base]);
    let refusal = start(&service, &world.start_params(&around, &third)).unwrap_err();
    assert_eq!(refusal.code, "seed.bad_request");
}

/// The bundle copy lives in a fresh 0700 folder of the daemon's own, named
/// for the job, and both are gone when the job ends.
#[test]
fn the_bundle_copy_is_private_and_removed() {
    use std::os::unix::fs::PermissionsExt as _;
    let world = World::new("copy");
    write(&world.mac.join("a"), "a\nedited\n");
    let snapshot = world.snapshot("one", &[&world.base]);
    let folder = world.home.join("project");
    let service = world.service();
    let job = start(&service, &world.start_params(&folder, &snapshot)).unwrap();
    let dir = std::env::temp_dir().join(format!("cmux-git-seed-{job}"));
    if let Ok(meta) = std::fs::symlink_metadata(&dir) {
        assert!(meta.is_dir());
        assert_eq!(meta.permissions().mode() & 0o777, 0o700);
    }
    assert_eq!(wait(&service, &job)["state"], "done");
    assert!(!dir.exists(), "the copy's folder is removed");
    assert!(!snapshot.bundle.exists(), "the upload is removed");
}

mod export;
