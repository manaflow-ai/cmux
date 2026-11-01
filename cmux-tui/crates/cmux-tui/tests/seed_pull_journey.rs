//! Seed pull, end to end on one Linux box with real processes: a project
//! seeded to a daemon shaped like a personal Cloud VM (`git-seed-v1`, its
//! GitHub remote a `file://` bare repository through the debug-only
//! `CMUX_TEST_GIT_SEED_GITHUB` seam) changes there, and `cmux link seed
//! pull` brings the changes back as a diff (`git-seed-export-v1` and
//! `fs-v1`), never a folder copy, merged against this Mac's seed record or
//! the `--base-*` flags.
//!
//! Linux only: a Cloud host is a Linux machine (`cloud_fs::is_cloud_host`).
#![cfg(target_os = "linux")]

mod journey_support;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use journey_support::*;
use serde_json::{Value, json};

/// A Mac daemon, a Cloud VM daemon and the "GitHub" they share.
struct World {
    root: PathBuf,
    mac: Machine,
    vm: Machine,
    _cleanup: Cleanup,
}

/// The seed a pull merges against.
#[derive(Clone)]
struct Base {
    head: String,
    index: String,
    work: String,
}

impl World {
    fn new(label: &str) -> Self {
        let stamp =
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
        let root = PathBuf::from("/tmp").join(format!("csp-{label}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(root.join("remotes/o")).unwrap();
        let root = fs::canonicalize(&root).unwrap();
        let cleanup = Cleanup(root.clone());
        let mac = Machine::start(&root, "mac", Vec::new());
        let vm = Machine::start(
            &root,
            "vm",
            vec![
                ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
                ("CMUX_VM_ID", format!("vm-seed-pull-{label}")),
                ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
                ("CMUX_TEST_GIT_SEED_GITHUB", root.join("remotes").to_string_lossy().into_owned()),
            ],
        );
        Self { root, mac, vm, _cleanup: cleanup }
    }

    /// A working copy on the Mac whose `origin` is
    /// `https://github.com/o/NAME.git` (read from the bare repository under
    /// `remotes/`), its first commit pushed. `.githooks` is its hooks folder.
    fn project(&self, name: &str) -> PathBuf {
        let repo = self.mac.home().join(name);
        fs::create_dir_all(repo.join("d")).unwrap();
        fs::create_dir_all(repo.join(".githooks")).unwrap();
        git(&repo, &["init", "-q", "-b", "main"]);
        for (path, text) in [
            ("a", "a\n"),
            ("b", "b\n"),
            ("d/c", "c\n"),
            ("notes", "notes\n"),
            (".gitignore", "node_modules/\n"),
            (".githooks/pre-commit", "#!/bin/sh\nexit 0\n"),
        ] {
            fs::write(repo.join(path), text).unwrap();
        }
        git(&repo, &["add", "-A"]);
        git(&repo, &["commit", "-q", "-m", "first"]);
        let bare = self.root.join(format!("remotes/o/{name}.git"));
        git(&self.root, &["clone", "-q", "--bare", repo.to_str().unwrap(), bare.to_str().unwrap()]);
        git(&bare, &["config", "uploadpack.allowFilter", "true"]);
        git(&bare, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
        let url = format!("https://github.com/o/{name}.git");
        git(&repo, &["remote", "add", "origin", &url]);
        let rewrite = format!("url.file://{}/.insteadOf", self.root.join("remotes").display());
        git(&repo, &["config", &rewrite, "https://github.com/"]);
        git(&repo, &["fetch", "-q", "origin"]);
        git(&repo, &["branch", "-q", "-u", "origin/main"]);
        git(&repo, &["config", "core.hooksPath", ".githooks"]);
        repo
    }

    /// The VM's folder for `name`.
    fn folder(&self, name: &str) -> PathBuf {
        self.vm.home().join("work").join(name)
    }

    /// Seeds `repo` to the VM as `cmux link seed plan` and `git.seed.start`
    /// do; the seed's commits.
    fn seed(&self, repo: &Path, name: &str) -> Base {
        let bundle = self.root.join(format!("{name}.bundle"));
        let (ok, plan) = run_json(
            Command::new(bin())
                .args(["link", "seed", "plan", "--local"])
                .arg(repo)
                .arg("--bundle")
                .arg(&bundle),
        );
        assert!(ok, "seed plan: {plan}");
        let upload = self.vm.home().join(format!("work/{name}.seed.bundle"));
        let bytes = fs::read(&bundle).unwrap();
        let written = self.vm.rpc(json!({
            "id": 1, "cmd": "fs.write", "path": upload, "mode": "create",
            "bytes_base64": base64::engine::general_purpose::STANDARD.encode(bytes),
        }));
        assert_eq!(written["ok"], true, "{written}");
        let mut params = plan["params"].clone();
        params["id"] = json!(2);
        params["cmd"] = json!("git.seed.start");
        params["folder"] = json!(self.folder(name));
        params["bundle"] = json!(upload);
        let started = self.vm.rpc(params);
        assert_eq!(started["ok"], true, "{started}");
        let job = started["data"]["job"].as_str().unwrap().to_owned();
        let status = wait_until(120, "the seed", || {
            let status = self.vm.rpc(json!({"id": 3, "cmd": "git.seed.status", "job": job}));
            (status["data"]["state"] != "running").then_some(status)
        });
        assert_eq!(status["data"]["state"], "done", "{status}");
        let sha = |key: &str| plan["params"][key].as_str().unwrap().to_owned();
        Base { head: sha("head"), index: sha("index"), work: sha("work") }
    }

    /// `cmux link seed pull` on the Mac, against `base` or (None) the
    /// Mac's record.
    fn pull(&self, repo: &Path, name: &str, base: Option<&Base>) -> (bool, Value) {
        let mut command = self.mac.command();
        command.args(["link", "seed", "pull", "--socket"]);
        command.arg(&self.vm.socket).arg(repo).arg(self.folder(name));
        if let Some(base) = base {
            command.args(["--base-head", &base.head, "--base-index", &base.index]);
            command.args(["--base-work", &base.work]);
        }
        run_json(&mut command)
    }

    /// `cmux link seed push` on the Mac (it keeps the record).
    fn push(&self, repo: &Path, name: &str, since_last: bool) -> (bool, Value) {
        let mut command = self.mac.command();
        command.args(["link", "seed", "push", "--socket"]);
        command.arg(&self.vm.socket).arg(repo).arg(self.folder(name));
        if since_last {
            command.arg("--since-last");
        }
        run_json(&mut command)
    }

    /// Bundles the export left on the VM.
    fn leftover_bundles(&self) -> Vec<String> {
        fs::read_dir(self.vm.home().join("work"))
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.ends_with(".bundle"))
            .collect()
    }
}

fn write(path: &Path, text: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(path, text).unwrap();
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap()
}

/// Everything a pull could change on the Mac: status, HEAD, the index (its
/// entries and bytes) and every file's bytes outside `.git`.
fn everything(repo: &Path) -> (String, String, String, Vec<u8>, BTreeMap<String, Vec<u8>>) {
    fn walk(top: &Path, dir: &Path, files: &mut BTreeMap<String, Vec<u8>>) {
        for entry in fs::read_dir(dir).unwrap().filter_map(Result::ok) {
            let path = entry.path();
            if entry.file_name() == ".git" {
                continue;
            }
            if entry.file_type().unwrap().is_dir() {
                walk(top, &path, files);
            } else {
                let relative = path.strip_prefix(top).unwrap().to_string_lossy().into_owned();
                files.insert(relative, fs::read(&path).unwrap());
            }
        }
    }
    let mut files = BTreeMap::new();
    walk(repo, repo, &mut files);
    (
        git(repo, &["status", "--porcelain", "--untracked-files=all"]),
        git(repo, &["rev-parse", "HEAD"]),
        git(repo, &["ls-files", "-s"]),
        fs::read(repo.join(".git/index")).unwrap(),
        files,
    )
}

fn conflicted(answer: &Value) -> Vec<&str> {
    answer["conflicts"].as_array().unwrap().iter().filter_map(Value::as_str).collect()
}

#[test]
fn a_pull_brings_back_commits_edits_adds_deletes_and_staged_changes_not_ignored_files() {
    let world = World::new("all");
    let repo = world.project("app");
    // No seed yet: no record to merge against.
    let (ok, none) = world.pull(&repo, "app", None);
    assert!(!ok && none["error_code"] == "seed.no_previous", "{none}");
    // `cmux link seed push` seeds it and keeps the record each pull reads.
    let (ok, pushed) = world.push(&repo, "app", false);
    assert!(ok && pushed["mode"] == "seed", "{pushed}");
    let vm = world.folder("app");
    // Nothing changed yet: nothing is downloaded.
    let (ok, same) = world.pull(&repo, "app", None);
    assert!(ok && same["unchanged"] == json!(true), "{same}");
    assert_eq!(same["bundle_bytes"], 0);
    assert!(world.leftover_bundles().is_empty(), "{:?}", world.leftover_bundles());

    write(&vm.join("b"), "b\ncommitted on the vm\n");
    git(&vm, &["commit", "-q", "-am", "on the vm"]);
    write(&vm.join("a"), "a\nedited on the vm\n");
    write(&vm.join("made.txt"), "made on the vm\n");
    fs::remove_file(vm.join("d/c")).unwrap();
    write(&vm.join("notes"), "notes\nstaged on the vm\n");
    git(&vm, &["add", "notes"]);
    write(&vm.join("node_modules/dep/index.js"), "ignored\n");
    write(&vm.join(".env"), "SECRET=1\n");

    let (ok, pulled) = world.pull(&repo, "app", None);
    assert!(ok, "seed pull: {pulled}");
    assert_eq!(pulled["fast_forwarded"], true, "{pulled}");
    assert_eq!(pulled["staged"], true, "{pulled}");
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), git(&vm, &["rev-parse", "HEAD"]));
    assert_eq!(git(&repo, &["symbolic-ref", "HEAD"]).trim(), "refs/heads/main");
    assert_eq!(git(&repo, &["write-tree"]), git(&vm, &["write-tree"]), "the staged tree");
    assert_eq!(read(&repo.join("a")), "a\nedited on the vm\n");
    assert_eq!(read(&repo.join("b")), "b\ncommitted on the vm\n");
    assert_eq!(read(&repo.join("made.txt")), "made on the vm\n");
    assert!(!repo.join("d/c").exists(), "the delete");
    assert!(!repo.join("node_modules").exists(), "ignored files stay on the VM");
    assert!(!repo.join(".env").exists(), "secrets stay on the VM");
    let status = |dir: &Path| {
        git(dir, &["status", "--porcelain", "--untracked-files=all"])
            .lines()
            .filter(|line| !line.ends_with(".env"))
            .map(str::to_owned)
            .collect::<Vec<_>>()
    };
    assert_eq!(status(&repo), status(&vm), "git status differs from the VM's");
    assert!(world.leftover_bundles().is_empty(), "{:?}", world.leftover_bundles());

    // The record moved to the pull's base: a second pull finds nothing new,
    let (ok, again) = world.pull(&repo, "app", None);
    assert!(ok && again["unchanged"] == json!(true), "{again}");
    assert_eq!(again["base"], pulled["base"], "{again}");
    // and the next delta push builds on it.
    write(&repo.join("a"), "a\nedited on the vm\nthen on the mac\n");
    let (ok, delta) = world.push(&repo, "app", true);
    assert!(ok && delta["mode"] == "delta", "{delta}");
    assert_eq!(read(&vm.join("a")), "a\nedited on the vm\nthen on the mac\n");
    let (ok, after) = world.pull(&repo, "app", None);
    assert!(ok && after["unchanged"] == json!(true), "{after}");
}

#[test]
fn a_pull_keeps_both_sides_and_refuses_what_changed_on_both() {
    let world = World::new("both");
    let repo = world.project("app");
    let base = world.seed(&repo, "app");
    let vm = world.folder("app");

    // Different files: both kept.
    write(&repo.join("a"), "a\nedited on the mac\n");
    write(&vm.join("b"), "b\nedited on the vm\n");
    let (ok, pulled) = world.pull(&repo, "app", Some(&base));
    assert!(ok, "{pulled}");
    assert_eq!(read(&repo.join("a")), "a\nedited on the mac\n");
    assert_eq!(read(&repo.join("b")), "b\nedited on the vm\n");
    let base = Base {
        head: pulled["base"]["head"].as_str().unwrap().to_owned(),
        index: pulled["base"]["index"].as_str().unwrap().to_owned(),
        work: pulled["base"]["work"].as_str().unwrap().to_owned(),
    };

    // The same file, differently: nothing changes here.
    write(&repo.join("notes"), "notes\nfrom the mac\n");
    write(&vm.join("notes"), "notes\nfrom the vm\n");
    write(&vm.join("other"), "would come back\n");
    let before = everything(&repo);
    let (ok, refused) = world.pull(&repo, "app", Some(&base));
    assert!(!ok, "{refused}");
    assert_eq!(refused["error_code"], "sync_conflict", "{refused}");
    assert_eq!(conflicted(&refused), vec!["notes"], "{refused}");
    assert_eq!(everything(&repo), before, "a conflict changed something here");
    assert!(world.leftover_bundles().is_empty());

    // The VM rewrote history: a conflict, nothing changes.
    write(&repo.join("notes"), "notes\nfrom the vm\n");
    git(&vm, &["commit", "-q", "--amend", "-am", "rewritten on the vm"]);
    let before = everything(&repo);
    let (ok, refused) = world.pull(&repo, "app", Some(&base));
    assert!(!ok, "{refused}");
    assert_eq!(refused["error_code"], "sync_conflict", "{refused}");
    assert!(conflicted(&refused).contains(&".git/HEAD"), "{refused}");
    assert!(refused["error"].as_str().unwrap().contains("rewrote"), "{refused}");
    assert_eq!(everything(&repo), before, "a conflict changed something here");
}

#[test]
fn a_pull_never_brings_back_hooks_or_repositories() {
    let world = World::new("hooks");
    let repo = world.project("app");
    let base = world.seed(&repo, "app");
    let vm = world.folder("app");

    // A hook in the VM's own `.git` and a nested repository: neither is part
    // of the working tree a pull brings back.
    write(&vm.join(".git/hooks/post-checkout"), "#!/bin/sh\ntouch /tmp/pwned\n");
    let inner = vm.join("vendor/inner");
    write(&inner.join("x.txt"), "inner\n");
    git(&inner, &["init", "-q"]);
    git(&inner, &["add", "-A"]);
    git(&inner, &["commit", "-q", "-m", "inner"]);
    write(&vm.join("a"), "a\nfrom the vm\n");
    let (ok, pulled) = world.pull(&repo, "app", Some(&base));
    assert!(ok, "{pulled}");
    assert_eq!(read(&repo.join("a")), "a\nfrom the vm\n");
    assert!(!repo.join("vendor").exists(), "a nested repository came back");
    assert!(!repo.join(".git/hooks/post-checkout").exists(), "a hook came back");
    let left: Vec<&str> =
        pulled["left_out"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
    assert!(left.contains(&"vendor/inner/"), "{pulled}");
    let base = Base {
        head: pulled["base"]["head"].as_str().unwrap().to_owned(),
        index: pulled["base"]["index"].as_str().unwrap().to_owned(),
        work: pulled["base"]["work"].as_str().unwrap().to_owned(),
    };

    // A file in this Mac's hooks folder (`core.hooksPath`): refused.
    write(&vm.join(".githooks/pre-commit"), "#!/bin/sh\ntouch /tmp/pwned\n");
    let before = everything(&repo);
    let (ok, refused) = world.pull(&repo, "app", Some(&base));
    assert!(!ok, "{refused}");
    assert_eq!(refused["error_code"], "sync_conflict", "{refused}");
    assert_eq!(conflicted(&refused), vec![".githooks/pre-commit"], "{refused}");
    assert_eq!(everything(&repo), before, "a refused hook changed something here");
}
