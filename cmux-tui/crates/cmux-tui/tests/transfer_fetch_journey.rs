//! Transfer to This Mac's folder copy, end to end on one Linux box with real
//! processes: `cmux link seed fetch` fills a new folder on a Mac that never
//! had the Cloud machine's folder, from each kind of folder a Cloud chat runs
//! in: a seed (a partial clone of its "GitHub", a `file://` bare repository
//! through the debug-only `CMUX_TEST_GIT_SEED_GITHUB` seam), a repository the
//! machine has whole, and plain files. The branch, commits, staged and
//! working changes come over; ignored files and secrets stay there; a folder
//! that is not empty, or a machine folder that is not there, changes nothing.
//!
//! Linux only: a Cloud host is a Linux machine (`cloud_fs::is_cloud_host`).
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::Value;

struct World {
    root: PathBuf,
    mac: Machine,
    vm: Machine,
    _cleanup: Cleanup,
}

impl World {
    fn new(label: &str) -> Self {
        let stamp =
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
        let root =
            PathBuf::from("/tmp").join(format!("ctf-{label}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(root.join("remotes/o")).unwrap();
        let root = fs::canonicalize(&root).unwrap();
        let cleanup = Cleanup(root.clone());
        let mac = Machine::start(&root, "mac", Vec::new());
        let vm = Machine::start(
            &root,
            "vm",
            vec![
                ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
                ("CMUX_VM_ID", format!("vm-transfer-{label}")),
                ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
                ("CMUX_TEST_GIT_SEED_GITHUB", root.join("remotes").to_string_lossy().into_owned()),
            ],
        );
        // This Mac's own git reaches "GitHub" (the bare repositories) the way its credentials would.
        fs::create_dir_all(mac.home()).unwrap();
        let rewrite = format!(
            "[url \"file://{}/\"]\n\tinsteadOf = https://github.com/\n[protocol \"file\"]\n\tallow = always\n",
            root.join("remotes").display()
        );
        fs::write(mac.home().join(".gitconfig"), rewrite).unwrap();
        Self { root, mac, vm, _cleanup: cleanup }
    }

    /// A project on another Mac (the owner's), seeded to the VM: the VM's folder is a partial clone.
    fn seeded(&self, name: &str) -> PathBuf {
        let repo = self.root.join("owner").join(name);
        fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "main"]);
        for (path, text) in
            [("a", "a\n"), ("b", "b\n"), ("d/c", "c\n"), (".gitignore", "node_modules/\n")]
        {
            write(&repo.join(path), text);
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
        let mut push = self.mac.command();
        push.args(["link", "seed", "push", "--socket"])
            .arg(&self.vm.socket)
            .arg(&repo)
            .arg(self.folder(name));
        let (ok, pushed) = run_json(&mut push);
        assert!(ok && pushed["mode"] == "seed", "{pushed}");
        self.folder(name)
    }

    fn folder(&self, name: &str) -> PathBuf {
        self.vm.home().join("work").join(name)
    }

    fn fetch(&self, local: &Path, name: &str, adopt: bool) -> (bool, Value) {
        self.fetch_with(local, &self.folder(name), if adopt { &["--adopt"] } else { &[] })
    }

    fn fetch_with(&self, local: &Path, remote: &Path, flags: &[&str]) -> (bool, Value) {
        let mut command = self.mac.command();
        command
            .args(["link", "seed", "fetch", "--socket"])
            .arg(&self.vm.socket)
            .arg(local)
            .arg(remote)
            .args(flags);
        run_json(&mut command)
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

fn status(dir: &Path) -> Vec<String> {
    git(dir, &["status", "--porcelain", "--untracked-files=all"])
        .lines()
        .filter(|line| !line.ends_with(".env") && !line.contains("id_ed25519"))
        .map(str::to_owned)
        .collect()
}

/// The VM's work since the seed: a commit, an edit, a delete, a staged change,
/// a new file, an ignored folder and two secrets.
fn work_on(vm: &Path) {
    write(&vm.join("b"), "b\ncommitted on the vm\n");
    git(vm, &["commit", "-q", "-am", "on the vm"]);
    write(&vm.join("a"), "a\nedited on the vm\n");
    fs::remove_file(vm.join("d/c")).unwrap();
    write(&vm.join("staged.txt"), "staged on the vm\n");
    git(vm, &["add", "staged.txt"]);
    write(&vm.join("made.txt"), "made on the vm\n");
    write(&vm.join("node_modules/dep/index.js"), "ignored\n");
    write(&vm.join(".env"), "SECRET=1\n");
    write(&vm.join("keys/id_ed25519"), "PRIVATE\n");
}

fn same_as_vm(local: &Path, vm: &Path) {
    assert_eq!(git(local, &["rev-parse", "HEAD"]), git(vm, &["rev-parse", "HEAD"]), "HEAD");
    assert_eq!(git(local, &["symbolic-ref", "HEAD"]).trim(), "refs/heads/main");
    assert_eq!(git(local, &["write-tree"]), git(vm, &["write-tree"]), "the staged tree");
    assert_eq!(read(&local.join("a")), "a\nedited on the vm\n");
    assert_eq!(read(&local.join("b")), "b\ncommitted on the vm\n");
    assert_eq!(read(&local.join("made.txt")), "made on the vm\n");
    assert!(!local.join("d/c").exists(), "the delete");
    assert!(!local.join("node_modules").exists(), "ignored files stay on the VM");
    assert!(!local.join(".env").exists(), "secrets stay on the VM");
    assert!(!local.join("keys/id_ed25519").exists(), "keys stay on the VM");
    assert_eq!(status(local), status(vm), "git status differs from the VM's");
}

#[test]
fn a_seeded_folder_comes_over_from_its_remote_with_the_machines_changes() {
    let world = World::new("seed");
    let vm = world.seeded("app");
    work_on(&vm);
    let local = world.mac.home().join("transferred/app");
    let (ok, fetched) = world.fetch(&local, "app", true);
    assert!(ok, "fetch: {fetched}");
    assert_eq!(fetched["mode"], "seed", "{fetched}");
    same_as_vm(&local, &vm);
    // Adopted: the move's last pull (Bring Back's) builds on it, and finds what changed since.
    write(&vm.join("a"), "a\nedited on the vm\nagain\n");
    let mut back = world.mac.command();
    back.args(["link", "seed", "pull", "--socket"])
        .arg(&world.vm.socket)
        .arg(&local)
        .arg(world.folder("app"))
        .arg("--or-copy");
    let (ok, pulled) = run_json(&mut back);
    assert!(ok && pulled["mode"] == "seed", "{pulled}");
    assert_eq!(read(&local.join("a")), "a\nedited on the vm\nagain\n");
}

#[test]
fn a_whole_repository_the_machine_made_comes_over_with_its_history() {
    let world = World::new("git");
    let vm = world.folder("made");
    fs::create_dir_all(&vm).unwrap();
    git(&vm, &["init", "-q", "-b", "main"]);
    git(&vm, &["config", "user.email", "vm@example.com"]);
    git(&vm, &["config", "user.name", "vm"]);
    for (path, text) in [
        ("a", "a\n"),
        ("b", "b\n"),
        ("d/c", "c\n"),
        ("src/main.rs", "fn main() {}\n"),
        (".gitignore", "node_modules/\n"),
    ] {
        write(&vm.join(path), text);
    }
    git(&vm, &["add", "-A"]);
    git(&vm, &["commit", "-q", "-m", "first"]);
    work_on(&vm);
    let local = world.mac.home().join("transferred/made");
    let (ok, fetched) = world.fetch(&local, "made", false);
    assert!(ok, "fetch: {fetched}");
    assert_eq!(fetched["mode"], "git", "{fetched}");
    same_as_vm(&local, &vm);
    assert_eq!(git(&local, &["rev-list", "--count", "HEAD"]).trim(), "2", "the whole history");
    // A copy: the machine's own sync record is not touched.
    assert!(!vm.join(".git/cmux-sync.json").exists());
    assert_eq!(fetched["remote_root"], vm.display().to_string());

    // A chat in a subfolder of the project: --find-root takes the whole repository.
    let other = world.mac.home().join("transferred/made-from-src");
    let (ok, rooted) = world.fetch_with(&other, &vm.join("src"), &["--find-root"]);
    assert!(ok, "fetch --find-root: {rooted}");
    assert_eq!(rooted["mode"], "git", "{rooted}");
    assert_eq!(rooted["remote_root"], vm.display().to_string());
    same_as_vm(&other, &vm);
    assert_eq!(read(&other.join("src/main.rs")), "fn main() {}\n");
}

#[test]
fn a_plain_folder_comes_over_without_its_secrets() {
    let world = World::new("plain");
    let vm = world.folder("notes");
    write(&vm.join("notes.txt"), "notes\n");
    write(&vm.join("sub/more.md"), "more\n");
    write(&vm.join(".env.local"), "SECRET=1\n");
    write(&vm.join(".netrc"), "machine x password y\n");
    let local = world.mac.home().join("transferred/notes");
    let (ok, fetched) = world.fetch(&local, "notes", false);
    assert!(ok, "fetch: {fetched}");
    assert_eq!(fetched["mode"], "copy", "{fetched}");
    assert_eq!(read(&local.join("notes.txt")), "notes\n");
    assert_eq!(read(&local.join("sub/more.md")), "more\n");
    assert!(!local.join(".env.local").exists());
    assert!(!local.join(".netrc").exists());
}

#[test]
fn a_folder_that_is_not_new_or_a_machine_folder_that_is_not_there_changes_nothing() {
    let world = World::new("refuse");
    let vm = world.folder("notes");
    write(&vm.join("notes.txt"), "notes\n");
    let busy = world.mac.home().join("busy");
    write(&busy.join("mine.txt"), "mine\n");
    let (ok, refused) = world.fetch(&busy, "notes", false);
    assert!(!ok && refused["error_code"] == "fetch.folder_not_empty", "{refused}");
    assert_eq!(read(&busy.join("mine.txt")), "mine\n");
    assert!(!busy.join("notes.txt").exists());

    let fresh = world.mac.home().join("never");
    let (ok, missing) = world.fetch(&fresh, "gone", false);
    assert!(!ok && missing["error_code"] == "fetch.no_folder", "{missing}");
    assert!(!fresh.exists(), "a failed fetch leaves no folder behind");
    // A retry into the same (still missing) folder works once the machine folder is there.
    write(&world.folder("gone").join("x.txt"), "x\n");
    let (ok, again) = world.fetch(&fresh, "gone", false);
    assert!(ok, "{again}");
    assert_eq!(read(&fresh.join("x.txt")), "x\n");
}
