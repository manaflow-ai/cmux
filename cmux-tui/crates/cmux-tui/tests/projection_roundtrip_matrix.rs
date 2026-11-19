//! Projected folders, there and back (RFD 0007, "Hard cases, one rule each"): a folder of this
//! "Mac" is projected onto a "Cloud machine" by the real start (`cmux link start-chat copy`, the
//! Mac's `cmux link project serve` behind it), the machine's real daemon mounts it with FUSE, the
//! agent's edits land in the mount, and the real Bring Back (`cmux link sync pull`) takes them home.
//! Each case asserts the Mac's folder afterwards and, in a repository, that `git status` reads the
//! same on both sides.
//!
//! The machine is a headless `cmux-tui` daemon with a home, state folder and git settings of its
//! own (the projection writes its `includeIf` into that home's `.gitconfig`, never the runner's).
//!
//! Leo, 2026-11-19: "likewise the local to cloud and back and whatever should be good as well... i
//! really like that feature".
#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::{FileExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && Command::new("fusermount3").arg("-V").output().is_ok_and(|out| out.status.success())
}

/// A start key of this run's own (the projection's name and its state are named by it).
fn new_key() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos() as u64);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    format!(
        "{:08x}-0c0a-4908-8706-{:012x}",
        std::process::id(),
        (nanos ^ (n << 40)) & 0xffff_ffff_ffff
    )
}

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}

/// One side of the round trip: its home (git reads its `.gitconfig`) and state folder.
struct Side {
    home: PathBuf,
    state: PathBuf,
}

impl Side {
    fn make(at: &Path) -> Self {
        let side = Self { home: at.join("home"), state: at.join("state") };
        fs::create_dir_all(side.home.join("work")).unwrap();
        fs::create_dir_all(&side.state).unwrap();
        side
    }

    fn git_command(&self, dir: &Path, args: &[&str]) -> Command {
        let mut command = Command::new("git");
        command
            .arg("-C")
            .arg(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(["-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"])
            .args(args)
            .env("HOME", &self.home)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env_remove("GIT_CONFIG_GLOBAL")
            .env_remove("GIT_DIR")
            .env_remove("GIT_INDEX_FILE")
            .stdin(Stdio::null());
        command
    }

    fn git(&self, dir: &Path, args: &[&str]) -> String {
        let output = self.git_command(dir, args).output().unwrap();
        assert!(
            output.status.success(),
            "git {args:?} in {}: {}",
            dir.display(),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    /// `git status --porcelain` with untracked files listed one by one.
    fn status(&self, dir: &Path) -> String {
        self.git(dir, &["status", "--porcelain", "--untracked-files=all"])
    }

    /// This side's `cmux-tui`.
    fn cmux(&self) -> Command {
        let mut command = Command::new(bin());
        command
            .env("HOME", &self.home)
            .env("CMUX_TUI_STATE_DIR", &self.state)
            .env("CMUX_TUI_CONFIG", self.state.join("config.json"))
            .env("CMUX_PROJECTED_FOLDERS", "1")
            .env_remove("CMUX_SYNC_COPY_RATE")
            .env_remove("ACPMUX_SOCKET")
            .env_remove("CMUX_TAG")
            .env_remove("CMUX_VM_ID")
            .env_remove("CMUX_TEST_CLOUD_ETC")
            .stdin(Stdio::null());
        command
    }
}

/// The Cloud machine: a headless daemon of its own.
struct Machine {
    side: Side,
    socket: PathBuf,
    session: String,
}

impl Machine {
    fn start(at: &Path) -> Self {
        let side = Side::make(at);
        let acpmux = at.join("acpmux");
        fs::create_dir_all(&acpmux).unwrap();
        fs::set_permissions(&acpmux, fs::Permissions::from_mode(0o700)).unwrap();
        let machine = Self {
            side,
            socket: at.join("m.sock"),
            session: format!("projection-matrix-{}", std::process::id()),
        };
        let ensure = machine.server("ensure").output().unwrap();
        assert!(ensure.status.success(), "ensure: {}", String::from_utf8_lossy(&ensure.stderr));
        machine
    }

    fn server(&self, action: &str) -> Command {
        let mut command = self.side.cmux();
        command
            .env("ACPMUX_HOME", self.side.home.parent().unwrap().join("acpmux"))
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket);
        command
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
    }
}

/// One case's world: the Mac's folder, projected at `folder` on the machine.
struct Trip {
    mac: Side,
    machine: Machine,
    /// The Mac's folder.
    local: PathBuf,
    /// The machine's folder: the mount.
    folder: PathBuf,
    root: PathBuf,
}

impl Drop for Trip {
    fn drop(&mut self) {
        let _ =
            self.mac.cmux().args(["link", "project", "stop", "--at"]).arg(&self.folder).output();
        let _ = Command::new("fusermount3")
            .args(["-u", "-z"])
            .arg(&self.folder)
            .stderr(Stdio::null())
            .status();
        if !std::thread::panicking() {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

/// Why a case cannot run here (no FUSE, or a host that may not mount).
type Skip = String;

/// Makes the Mac's folder with `fill`, then projects it.
fn trip(case: &str, fill: impl FnOnce(&Side, &Path)) -> Result<Trip, Skip> {
    if !fuse_here() {
        return Err("no FUSE here".into());
    }
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("prm-{case}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let mac = Side::make(&root.join("mac"));
    let local = mac.home.join("Projects/app");
    fs::create_dir_all(&local).unwrap();
    fill(&mac, &local);
    let machine = Machine::start(&root.join("vm"));
    let key = new_key();
    let output = mac
        .cmux()
        .args(["link", "start-chat", "copy", "--key", &key, "--account", "leo"])
        .args(["--machine", "vm-a", "--socket"])
        .arg(&machine.socket)
        .arg("--local")
        .arg(&local)
        .arg("--work-root")
        .arg(machine.side.home.join("work"))
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let answer = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line).ok())
        .unwrap_or(Value::Null);
    assert_eq!(answer["ok"], true, "start-chat copy: {stdout}{stderr}");
    let folder = PathBuf::from(answer["folder"].as_str().unwrap());
    let trip = Trip { mac, machine, local, folder, root };
    if answer["mode"] != "projected" {
        if stderr.contains("mount failed") {
            return Err(format!("this host may not mount FUSE: {stderr}"));
        }
        panic!("not projected: {answer} {stderr}");
    }
    Ok(trip)
}

/// Starts the case, or says why it can't run here and ends it.
macro_rules! trip_or_skip {
    ($case:expr, $fill:expr) => {
        match trip($case, $fill) {
            Ok(trip) => trip,
            Err(why) => {
                eprintln!("skipping: {why}");
                return;
            }
        }
    };
}

/// A repository with a commit: `README.md`, `src/a.txt`, `src/b.txt`, `src/deep/c.txt`.
fn repo(side: &Side, at: &Path) {
    side.git(at, &["init", "-q"]);
    plain(side, at);
    side.git(at, &["add", "-A"]);
    side.git(at, &["commit", "-qm", "init"]);
}

/// The same files, no repository.
fn plain(_side: &Side, at: &Path) {
    write(&at.join("README.md"), "# app\n");
    write(&at.join("src/a.txt"), "alpha\n");
    write(&at.join("src/b.txt"), "bravo\n");
    write(&at.join("src/deep/c.txt"), "charlie\n");
}

impl Trip {
    /// Bring Back: `cmux link sync pull` of the machine's folder into the Mac's. Its answer.
    fn bring_back(&self) -> Value {
        let output = self
            .mac
            .cmux()
            .args(["link", "sync", "pull", "--socket"])
            .arg(&self.machine.socket)
            .arg(&self.local)
            .arg(&self.folder)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        stdout
            .lines()
            .rev()
            .find_map(|line| serde_json::from_str::<Value>(line).ok())
            .unwrap_or_else(|| {
                panic!(
                    "sync pull answered no JSON: {stdout}{}",
                    String::from_utf8_lossy(&output.stderr)
                )
            })
    }

    fn brought_back(&self) -> Value {
        let answer = self.bring_back();
        assert_eq!(answer["ok"], true, "Bring Back: {answer}");
        answer
    }

    fn at(&self, relative: &str) -> PathBuf {
        self.folder.join(relative)
    }

    fn mac(&self, relative: &str) -> PathBuf {
        self.local.join(relative)
    }

    /// The machine's shell runs `script` in its folder.
    fn on_machine(&self, script: &str) {
        let output = Command::new("sh")
            .args(["-c", script])
            .current_dir(&self.folder)
            .env("HOME", &self.machine.side.home)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "on the machine: {script}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn machine_status(&self) -> String {
        self.machine.side.status(&self.folder)
    }

    fn mac_status(&self) -> String {
        self.mac.status(&self.local)
    }

    /// `git status` reads the same on both sides.
    fn statuses_agree(&self) {
        assert_eq!(
            self.mac_status(),
            self.machine_status(),
            "git status differs from the machine's"
        );
    }
}

#[test]
fn a_renamed_file_comes_back_as_a_delete_and_a_create() {
    let t = trip_or_skip!("rename-file", repo);
    t.on_machine("mv src/a.txt src/renamed.txt");
    let answer = t.brought_back();
    assert!(!t.mac("src/a.txt").exists(), "{answer}");
    assert_eq!(read(&t.mac("src/renamed.txt")), "alpha\n");
    assert_eq!(t.mac_status(), " D src/a.txt\n?? src/renamed.txt\n");
    t.statuses_agree();
}

#[test]
fn a_renamed_folder_comes_back_whole() {
    let t = trip_or_skip!("rename-dir", repo);
    // A lower folder's rename is refused (EXDEV) so `mv` copies it, as it does across disks.
    t.on_machine("mv src lib");
    let answer = t.brought_back();
    assert!(!t.mac("src").exists(), "{answer}");
    assert_eq!(read(&t.mac("lib/a.txt")), "alpha\n");
    assert_eq!(read(&t.mac("lib/deep/c.txt")), "charlie\n");
    t.statuses_agree();
}

#[test]
fn a_deleted_file_is_deleted_on_the_mac() {
    let t = trip_or_skip!("delete-file", repo);
    t.on_machine("rm src/b.txt");
    t.brought_back();
    assert!(!t.mac("src/b.txt").exists());
    assert_eq!(read(&t.mac("src/a.txt")), "alpha\n");
    t.statuses_agree();
}

#[test]
fn a_deleted_folder_is_deleted_on_the_mac() {
    let t = trip_or_skip!("delete-dir", repo);
    t.on_machine("rm -r src/deep");
    t.brought_back();
    assert!(!t.mac("src/deep/c.txt").exists());
    assert_eq!(read(&t.mac("src/a.txt")), "alpha\n");
    t.statuses_agree();
}

/// A whiteout is a delete only while the Mac's file is as the manifest had it (hard case 4).
#[test]
fn a_delete_of_a_file_the_mac_changed_since_is_a_conflict() {
    let t = trip_or_skip!("delete-changed", repo);
    t.on_machine("rm src/b.txt");
    std::thread::sleep(Duration::from_millis(20));
    write(&t.mac("src/b.txt"), "bravo, edited on the mac\n");
    let answer = t.bring_back();
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    assert_eq!(read(&t.mac("src/b.txt")), "bravo, edited on the mac\n");
}

const BIG: u64 = 80 * 1024 * 1024;

/// The byte at `offset` of the big file.
fn big_byte(offset: u64) -> u8 {
    (offset.wrapping_mul(2_654_435_761) >> 13) as u8
}

fn big_file(path: &Path) {
    let mut bytes = vec![0u8; BIG as usize];
    for (offset, byte) in bytes.iter_mut().enumerate() {
        *byte = big_byte(offset as u64);
    }
    fs::write(path, bytes).unwrap();
}

#[test]
fn a_large_file_reads_by_range_and_its_edit_comes_back() {
    let t = trip_or_skip!("large", |side, at| {
        plain(side, at);
        big_file(&at.join("data/big.bin"));
        big_file(&at.join("data/untouched.bin"));
    });
    // A read past 64 MiB, by range, without the whole file.
    let file = fs::File::open(t.at("data/big.bin")).unwrap();
    assert_eq!(file.metadata().unwrap().len(), BIG);
    let mut range = vec![0u8; 4096];
    let offset = 70 * 1024 * 1024 + 123;
    file.read_exact_at(&mut range, offset).unwrap();
    assert!(range.iter().enumerate().all(|(i, b)| *b == big_byte(offset + i as u64)));
    drop(file);
    // An edit in the middle of it.
    let file = fs::OpenOptions::new().write(true).open(t.at("data/big.bin")).unwrap();
    file.write_all_at(b"EDITED ON THE MACHINE", 65 * 1024 * 1024).unwrap();
    drop(file);
    let started = Instant::now();
    let answer = t.brought_back();
    eprintln!("large Bring Back: {:?} {answer}", started.elapsed());
    let back = fs::read(t.mac("data/big.bin")).unwrap();
    assert_eq!(back.len() as u64, BIG);
    assert_eq!(&back[65 * 1024 * 1024..65 * 1024 * 1024 + 21], b"EDITED ON THE MACHINE");
    assert_eq!(back[0], big_byte(0));
    assert_eq!(back[BIG as usize - 1], big_byte(BIG - 1));
    // The untouched big file was never read back: only the edited one's bytes moved.
    assert_eq!(answer["written"], 1, "{answer}");
    assert!(answer["bytes"].as_u64().unwrap() <= BIG, "{answer}");
}

#[test]
fn symlinks_inside_come_back_and_ones_leaving_the_folder_stay() {
    let t = trip_or_skip!("symlinks", |side, at| {
        repo(side, at);
        std::os::unix::fs::symlink("src/a.txt", at.join("to-a")).unwrap();
        std::os::unix::fs::symlink("/etc/hostname", at.join("leaves")).unwrap();
        side.git(at, &["add", "-A"]);
        side.git(at, &["commit", "-qm", "links"]);
    });
    // The Mac's inside link is there, as a link; the one leaving the folder is not projected.
    assert_eq!(fs::read_link(t.at("to-a")).unwrap(), Path::new("src/a.txt"));
    assert_eq!(read(&t.at("to-a")), "alpha\n");
    t.on_machine("ln -s src/b.txt to-b && ln -s ../../../../outside out");
    let answer = t.brought_back();
    assert_eq!(fs::read_link(t.mac("to-b")).unwrap(), Path::new("src/b.txt"), "{answer}");
    assert!(fs::symlink_metadata(t.mac("out")).is_err(), "a link out of the folder came back");
    assert_eq!(fs::read_link(t.mac("to-a")).unwrap(), Path::new("src/a.txt"));
    let skipped = answer["skipped_files"].to_string();
    assert!(skipped.contains("out"), "{answer}");
}

/// Both sides edited a file: the Mac's stays, and the machine's goes beside it as
/// `NAME.cmux-sync-conflict`, never over it.
#[test]
fn an_edit_on_both_sides_is_a_conflict_file_never_an_overwrite() {
    let t = trip_or_skip!("both-sides", repo);
    write(&t.at("src/a.txt"), "alpha, edited on the machine\n");
    write(&t.at("src/b.txt"), "bravo, edited on the machine\n");
    std::thread::sleep(Duration::from_millis(20));
    write(&t.mac("src/a.txt"), "alpha, edited on the mac\n");
    let answer = t.bring_back();
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    assert_eq!(answer["conflicts"], serde_json::json!(["src/a.txt"]), "{answer}");
    assert_eq!(read(&t.mac("src/a.txt")), "alpha, edited on the mac\n");
    assert_eq!(read(&t.mac("src/a.txt.cmux-sync-conflict")), "alpha, edited on the machine\n");
    // On a conflict nothing else of the Mac's changes.
    assert_eq!(read(&t.mac("src/b.txt")), "bravo\n");
}

#[test]
fn an_edit_made_only_on_the_mac_is_kept() {
    let t = trip_or_skip!("mac-only", repo);
    std::thread::sleep(Duration::from_millis(20));
    write(&t.mac("src/b.txt"), "bravo, edited on the mac\n");
    write(&t.at("src/a.txt"), "alpha, edited on the machine\n");
    t.brought_back();
    assert_eq!(read(&t.mac("src/b.txt")), "bravo, edited on the mac\n");
    assert_eq!(read(&t.mac("src/a.txt")), "alpha, edited on the machine\n");
}

#[test]
fn new_files_of_the_machine_come_back_and_secrets_stay() {
    let t = trip_or_skip!("new-files", repo);
    write(&t.at("src/new.txt"), "new\n");
    write(&t.at("docs/guide/intro.md"), "# intro\n");
    write(&t.at(".env.local"), "TOKEN=x\n");
    let answer = t.brought_back();
    assert_eq!(read(&t.mac("src/new.txt")), "new\n", "{answer}");
    assert_eq!(read(&t.mac("docs/guide/intro.md")), "# intro\n");
    assert!(!t.mac(".env.local").exists(), "{answer}");
    assert_eq!(t.mac_status(), "?? docs/guide/intro.md\n?? src/new.txt\n", "{answer}");
}

#[test]
fn a_folder_that_is_not_a_repository_comes_back() {
    let t = trip_or_skip!("plain", plain);
    write(&t.at("src/a.txt"), "alpha, edited on the machine\n");
    t.on_machine("rm src/b.txt && mkdir -p out && echo built > out/x.txt");
    t.brought_back();
    assert_eq!(read(&t.mac("src/a.txt")), "alpha, edited on the machine\n");
    assert!(!t.mac("src/b.txt").exists());
    assert_eq!(read(&t.mac("out/x.txt")), "built\n");
}

/// `git status` on the machine refreshes `.git/index` into the upper layer; Bring Back never
/// copies it as a file (hard case 13), and both sides read the same status.
#[test]
fn git_status_agrees_after_the_machine_ran_it_and_the_index_is_not_copied() {
    let t = trip_or_skip!("git-status", repo);
    let index_before = fs::read(t.mac(".git/index")).unwrap();
    assert_eq!(t.machine_status(), "");
    write(&t.at("src/a.txt"), "alpha, edited on the machine\n");
    assert_eq!(t.machine_status(), " M src/a.txt\n");
    let answer = t.brought_back();
    assert_eq!(fs::read(t.mac(".git/index")).unwrap(), index_before, "{answer}");
    assert_eq!(t.mac_status(), " M src/a.txt\n");
    t.statuses_agree();
}

/// A commit on the machine comes back as a fast-forward of the Mac's branch.
#[test]
fn a_commit_on_the_machine_fast_forwards_the_macs_branch() {
    let t = trip_or_skip!("commit", repo);
    write(&t.at("src/a.txt"), "alpha, committed on the machine\n");
    t.machine.side.git(&t.folder, &["commit", "-qam", "on the machine"]);
    let answer = t.brought_back();
    assert_eq!(answer["fast_forwarded"], true, "{answer}");
    assert_eq!(
        t.mac.git(&t.local, &["rev-parse", "HEAD"]),
        t.machine.side.git(&t.folder, &["rev-parse", "HEAD"])
    );
    assert_eq!(read(&t.mac("src/a.txt")), "alpha, committed on the machine\n");
    assert_eq!(t.mac_status(), "");
    t.statuses_agree();
}

/// A name the machine made that folds to a Mac name (`Readme.md` beside `README.md`) is a named
/// conflict, never an overwrite (hard case 6): the Mac's disk can't hold both.
#[test]
fn a_new_name_that_folds_to_a_mac_name_is_a_conflict() {
    let t = trip_or_skip!("case-fold", repo);
    write(&t.at("Readme.md"), "# another readme\n");
    write(&t.at("SRC/x.txt"), "into a folder that folds to src\n");
    let answer = t.bring_back();
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    let conflicts = answer["conflicts"].to_string();
    assert!(conflicts.contains("Readme.md") && conflicts.contains("SRC/x.txt"), "{answer}");
    assert!(!t.mac("Readme.md").exists());
    assert!(!t.mac("SRC").exists());
    assert_eq!(read(&t.mac("README.md")), "# app\n");
}

/// A file the Mac changed after the manifest and before the machine read it: the machine reads the
/// new bytes (hard case 7).
#[test]
#[ignore = "hq#14025: no re-manifest yet; the Mac answers CHANGED and the machine's read fails with ESTALE"]
fn a_file_changed_on_the_mac_after_the_manifest_reads_its_new_bytes() {
    let t = trip_or_skip!("remanifest", repo);
    std::thread::sleep(Duration::from_millis(20));
    write(&t.mac("src/a.txt"), "alpha, changed on the mac after the start\n");
    assert_eq!(read(&t.at("src/a.txt")), "alpha, changed on the mac after the start\n");
}

/// Bring Back twice: the second takes only what changed since the first.
#[test]
fn a_second_bring_back_takes_the_later_edits() {
    let t = trip_or_skip!("twice", repo);
    write(&t.at("src/a.txt"), "alpha, first\n");
    t.brought_back();
    assert_eq!(read(&t.mac("src/a.txt")), "alpha, first\n");
    write(&t.at("src/a.txt"), "alpha, second\n");
    t.on_machine("rm src/b.txt");
    let answer = t.brought_back();
    assert_eq!(read(&t.mac("src/a.txt")), "alpha, second\n", "{answer}");
    assert!(!t.mac("src/b.txt").exists(), "{answer}");
    t.statuses_agree();
    // Nothing new: nothing moves.
    let again = t.brought_back();
    assert_eq!(again["written"], 0, "{again}");
    assert_eq!(again["deleted"], 0, "{again}");
}

/// `~/Projects`' shape (hard case 12): a folder of repositories, not one itself. An edit in one of
/// them comes back, and that repository's `git status` reads the same on both sides.
#[test]
fn an_edit_in_a_repository_of_a_parent_folder_comes_back() {
    let t = trip_or_skip!("parent", |side, at| {
        for name in ["api", "web"] {
            let repo_at = at.join(name);
            fs::create_dir_all(&repo_at).unwrap();
            repo(side, &repo_at);
        }
        write(&at.join("notes.md"), "notes\n");
    });
    write(&t.at("api/src/a.txt"), "alpha, edited on the machine\n");
    write(&t.at("notes.md"), "notes, edited on the machine\n");
    let answer = t.brought_back();
    assert_eq!(read(&t.mac("notes.md")), "notes, edited on the machine\n", "{answer}");
    assert_eq!(read(&t.mac("api/src/a.txt")), "alpha, edited on the machine\n", "{answer}");
    assert_eq!(t.mac.status(&t.mac("api")), t.machine.side.status(&t.at("api")));
}
