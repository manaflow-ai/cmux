//! Projected folders by where they are used (RFD 0007): each test runs one of the app's own
//! remote paths end to end with the verbs the app calls, against a "Mac" folder and real
//! headless daemons shaped like Cloud machines (the debug-only `CMUX_TEST_CLOUD_ETC` seam):
//!
//! - a Cloud chat started on a local folder (`cmux link start-chat copy`: projected), brought
//!   back by Bring Back Local's own verb (`cmux link seed pull --or-copy`), in both directions,
//!   with a conflict, and back and forth many times;
//! - Move to Cloud and a New Workspace on Cloud (`cmux link seed push`, then the frozen chat's
//!   `--since-last` and Bring Back Local), timed beside the projection of the same folder.
//!
//! Move to Another Machine of a projected chat runs the real chat move: `projection_move_journey.rs`.
//!
//! Each case prints one `CELL {json}` line on stderr (correctness and timings) and appends it to
//! `CMUX_PROJECTION_CELLS` when set.
//!
//! Leo, 2026-11-19: "the projection folder file system thing, like among all areas, among all like
//! use cases, repositories, among all variations, we need to make sure that like is reliable back
//! and forth. And especially for remote".
#![cfg(target_os = "linux")]

use std::fs;
use std::io::Write as _;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

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

fn ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

fn p95(samples: &[u64]) -> u64 {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    sorted.get((sorted.len() * 95).div_ceil(100).saturating_sub(1)).copied().unwrap_or(0)
}

/// The cell's line: on stderr, and appended to `CMUX_PROJECTION_CELLS` when set.
fn cell(fields: Value) {
    let mut line = json!({"axis": "where-used"});
    for (key, value) in fields.as_object().unwrap() {
        line[key] = value.clone();
    }
    eprintln!("CELL {line}");
    if let Some(path) = std::env::var_os("CMUX_PROJECTION_CELLS")
        && let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path)
    {
        let _ = writeln!(file, "{line}");
    }
}

/// The last JSON line of a CLI's stdout.
fn answer_of(output: &std::process::Output) -> Value {
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line).ok()).unwrap_or_else(
        || json!({"ok": false, "stdout": stdout, "stderr": String::from_utf8_lossy(&output.stderr)}),
    )
}

/// One side: its home (git reads its `.gitconfig`) and state folder.
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

    fn git(&self, dir: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
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
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?} in {}: {}",
            dir.display(),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    fn status(&self, dir: &Path) -> String {
        self.git(dir, &["status", "--porcelain", "--untracked-files=all"])
    }

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
            .env_remove("CMUX_TEST_GIT_SEED_GITHUB")
            .stdin(Stdio::null());
        command
    }

    /// `cmux-tui ARGS` on this side; its last JSON line.
    fn run(&self, args: &[&str]) -> Value {
        answer_of(&self.cmux().args(args).output().unwrap())
    }
}

/// A Cloud machine: a headless daemon of its own.
struct Machine {
    side: Side,
    socket: PathBuf,
    session: String,
}

impl Machine {
    fn start(at: &Path, id: &str) -> Self {
        let side = Side::make(at);
        let acpmux = at.join("acpmux");
        fs::create_dir_all(&acpmux).unwrap();
        fs::set_permissions(&acpmux, fs::Permissions::from_mode(0o700)).unwrap();
        let machine = Self {
            side,
            socket: at.join("m.sock"),
            session: format!("projection-uses-{id}-{}", std::process::id()),
        };
        let ensure = machine.server("ensure", id).output().unwrap();
        assert!(ensure.status.success(), "ensure: {}", String::from_utf8_lossy(&ensure.stderr));
        machine
    }

    fn cloud_etc(&self) -> PathBuf {
        let etc = self.side.home.parent().unwrap().join("etc-cmux");
        fs::create_dir_all(&etc).unwrap();
        fs::write(etc.join("image-stamp"), "cmux-vm inputs=projection-remote-uses\n").unwrap();
        fs::write(etc.join("vm-kind"), "owner\n").unwrap();
        fs::set_permissions(&etc, fs::Permissions::from_mode(0o755)).unwrap();
        for file in ["image-stamp", "vm-kind"] {
            fs::set_permissions(etc.join(file), fs::Permissions::from_mode(0o644)).unwrap();
        }
        etc
    }

    fn server(&self, action: &str, id: &str) -> Command {
        let mut command = self.side.cmux();
        command
            .env("ACPMUX_HOME", self.side.home.parent().unwrap().join("acpmux"))
            .env("CMUX_TEST_CLOUD_ETC", self.cloud_etc())
            .env("CMUX_VM_ID", format!("vm-projection-uses-{id}"))
            .env("CMUX_CODEROUTER_URL", "http://127.0.0.1:9")
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket);
        command
    }

    fn work(&self) -> PathBuf {
        self.side.home.join("work")
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        let _ = self.server("stop", "gone").arg("--end-terminals").output();
    }
}

/// One case's world: the Mac's folder and a first machine.
struct World {
    mac: Side,
    local: PathBuf,
    machine: Machine,
    /// Folders mounted on a machine, unmounted at the end.
    mounted: Vec<PathBuf>,
    root: PathBuf,
}

impl Drop for World {
    fn drop(&mut self) {
        for at in &self.mounted {
            let _ = self.mac.cmux().args(["link", "project", "stop", "--at"]).arg(at).output();
            let _ = Command::new("fusermount3")
                .args(["-u", "-z"])
                .arg(at)
                .stderr(Stdio::null())
                .status();
        }
        if !std::thread::panicking() {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

/// A repository with a commit: `README.md`, `notes.txt`, `mac.txt`, `src/` with `files` files
/// of about 1 KiB each, and no remote (so a seed push copies).
fn repo_of(side: &Side, at: &Path, files: usize) {
    side.git(at, &["init", "-q"]);
    write(&at.join("README.md"), "# app\n");
    write(&at.join("notes.txt"), "notes\n");
    write(&at.join("mac.txt"), "mac\n");
    for n in 0..files {
        write(&at.join(format!("src/{:02}/f{n}.txt", n % 40)), &format!("{n}\n").repeat(200));
    }
    side.git(at, &["add", "-A"]);
    side.git(at, &["commit", "-qm", "init"]);
}

fn world(case: &str, files: usize) -> Option<World> {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return None;
    }
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("pru-{case}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let mac = Side::make(&root.join("mac"));
    let local = mac.home.join("Projects/app");
    fs::create_dir_all(&local).unwrap();
    repo_of(&mac, &local, files);
    let machine = Machine::start(&root.join("vm-a"), "a");
    Some(World { mac, local, machine, mounted: Vec::new(), root })
}

impl World {
    /// A Cloud chat on the Mac's folder: `start-chat copy`, projected. The machine's folder and
    /// how long the start took.
    fn start_projected(&mut self) -> Option<(PathBuf, u64)> {
        let key = new_key();
        let started = Instant::now();
        let output = self
            .mac
            .cmux()
            .args(["link", "start-chat", "copy", "--key", &key, "--account", "leo"])
            .args(["--machine", "vm-a", "--socket"])
            .arg(&self.machine.socket)
            .arg("--local")
            .arg(&self.local)
            .arg("--work-root")
            .arg(self.machine.work())
            .output()
            .unwrap();
        let took = ms(started);
        let answer = answer_of(&output);
        assert_eq!(answer["ok"], true, "start-chat copy: {answer}");
        let folder = PathBuf::from(answer["folder"].as_str().unwrap());
        self.mounted.push(folder.clone());
        if answer["mode"] != "projected" {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if stderr.contains("mount failed") {
                eprintln!("skipping: this host may not mount FUSE: {stderr}");
                return None;
            }
            panic!("not projected: {answer} {stderr}");
        }
        Some((folder, took))
    }

    /// Bring Back Local's verb (`cmux link seed pull --or-copy`) from `machine`'s `folder`.
    fn bring_back_local(&self, machine: &Machine, folder: &Path) -> (Value, u64) {
        let started = Instant::now();
        let output = self
            .mac
            .cmux()
            .args(["link", "seed", "pull", "--socket"])
            .arg(&machine.socket)
            .arg(&self.local)
            .arg(folder)
            .arg("--or-copy")
            .output()
            .unwrap();
        (answer_of(&output), ms(started))
    }

    /// Move to Cloud's and a New Workspace's first copy (`cmux link seed push`) to `remote`.
    fn seed_push(&self, machine: &Machine, remote: &Path, since_last: bool) -> (Value, u64) {
        let started = Instant::now();
        let mut command = self.mac.cmux();
        command.args(["link", "seed", "push", "--socket"]).arg(&machine.socket);
        command.arg(&self.local).arg(remote);
        if since_last {
            command.arg("--since-last");
        }
        let output = command.output().unwrap();
        (answer_of(&output), ms(started))
    }

    fn mac(&self, relative: &str) -> PathBuf {
        self.local.join(relative)
    }

    fn mac_status(&self) -> String {
        self.mac.status(&self.local)
    }
}

/// A shell on `machine` runs `script` in `folder`.
fn on_machine(machine: &Machine, folder: &Path, script: &str) {
    let output = Command::new("sh")
        .args(["-c", script])
        .current_dir(folder)
        .env("HOME", &machine.side.home)
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

/// First read and p95 open of `count` files of the machine's folder, cold.
fn opens(folder: &Path, count: usize) -> (u64, u64) {
    let mut samples = Vec::new();
    for n in 0..count {
        let started = Instant::now();
        let _ = fs::read(folder.join(format!("src/{:02}/f{n}.txt", n % 40))).unwrap();
        samples.push(ms(started));
    }
    (samples.first().copied().unwrap_or(0), p95(&samples))
}

fn git_status_ms(machine: &Machine, folder: &Path) -> u64 {
    let started = Instant::now();
    let _ = machine.side.status(folder);
    ms(started)
}

/// Cloud chat start, remote to local: the machine's edit, new file and delete come home by Bring
/// Back Local's own verb, and `git status` reads the same on both sides.
#[test]
fn a_projected_chat_comes_back_by_bring_back_locals_verb() {
    let Some(mut w) = world("back", 400) else { return };
    let Some((folder, start_ms)) = w.start_projected() else { return };
    let (first_read_ms, p95_open_ms) = opens(&folder, 50);
    let git_ms = git_status_ms(&w.machine, &folder);
    write(&folder.join("notes.txt"), "notes, from the machine\n");
    write(&folder.join("new/made.txt"), "made on the machine\n");
    on_machine(&w.machine, &folder, "rm src/00/f0.txt");
    let (answer, pull_ms) = w.bring_back_local(&w.machine, &folder);
    let correct = answer["ok"] == true
        && read(&w.mac("notes.txt")) == "notes, from the machine\n"
        && w.mac("new/made.txt").exists()
        && !w.mac("src/00/f0.txt").exists()
        && w.mac_status() == w.machine.side.status(&folder);
    cell(json!({"use": "cloud-chat-start", "repo": "git", "direction": "remote->local",
        "fault": "none", "correct": correct, "first_read_ms": first_read_ms,
        "p95_open_ms": p95_open_ms, "git_status_ms": git_ms, "recovery_ms": null,
        "start_ms": start_ms, "bring_back_ms": pull_ms, "note": answer.to_string()}));
    assert!(correct, "Bring Back Local: {answer}");
}

/// Cloud chat start, both sides edit one file: Bring Back Local's verb names the conflict and
/// the Mac's file keeps its bytes.
#[test]
fn a_projected_chat_edited_on_both_sides_is_a_named_conflict() {
    let Some(mut w) = world("conflict", 40) else { return };
    let Some((folder, _)) = w.start_projected() else { return };
    write(&folder.join("notes.txt"), "notes, from the machine\n");
    write(&w.mac("notes.txt"), "notes, from the Mac\n");
    let (answer, pull_ms) = w.bring_back_local(&w.machine, &folder);
    let named = answer.to_string().contains("notes.txt");
    let kept = read(&w.mac("notes.txt")) == "notes, from the Mac\n";
    let correct = answer["ok"] != true && named && kept;
    cell(json!({"use": "cloud-chat-start", "repo": "git", "direction": "conflict",
        "fault": "none", "correct": correct, "bring_back_ms": pull_ms,
        "note": answer.to_string()}));
    assert!(correct, "a both-sides edit: {answer}");
}

/// Cloud chat start, local to remote: a file the Mac changed after the folder was projected and
/// before the machine read it is read at its new bytes (RFD 0007 hard case 7).
#[test]
#[ignore = "follow-up: no re-manifest yet (cmux#47156): the machine's read of a file the Mac changed since fails"]
fn a_mac_edit_after_the_projection_is_read_on_the_machine() {
    let Some(mut w) = world("mac-edit", 40) else { return };
    let Some((folder, _)) = w.start_projected() else { return };
    write(&w.mac("mac.txt"), "mac, edited after the start\n");
    let started = Instant::now();
    let read_back = fs::read_to_string(folder.join("mac.txt"));
    let correct = read_back.as_deref().ok() == Some("mac, edited after the start\n");
    cell(json!({"use": "cloud-chat-start", "repo": "git", "direction": "local->remote",
        "fault": "mac-edit-after-manifest", "correct": correct, "first_read_ms": ms(started),
        "note": format!("{read_back:?}"), "pr": "47156"}));
    assert!(correct, "{read_back:?}");
}

/// Cloud chat start, rapid back and forth: 12 rounds of a machine edit, Bring Back Local, and a
/// Mac edit to a file the machine leaves alone. No edit of either side is lost.
#[test]
fn rapid_bring_backs_of_a_projected_chat_lose_no_edit() {
    let Some(mut w) = world("rapid", 40) else { return };
    let Some((folder, _)) = w.start_projected() else { return };
    let mut pulls = Vec::new();
    let mut failed = None;
    for round in 0..12 {
        on_machine(&w.machine, &folder, &format!("echo machine {round} >> notes.txt"));
        write(&folder.join(format!("made/{round}.txt")), &format!("{round}\n"));
        let (answer, pull_ms) = w.bring_back_local(&w.machine, &folder);
        pulls.push(pull_ms);
        if answer["ok"] != true {
            failed = Some(format!("round {round}: {answer}"));
            break;
        }
        let mac_text = read(&w.mac("mac.txt"));
        write(&w.mac("mac.txt"), &format!("{mac_text}mac {round}\n"));
    }
    let notes = read(&w.mac("notes.txt"));
    let mac_text = read(&w.mac("mac.txt"));
    let correct = failed.is_none()
        && (0..12).all(|round| {
            notes.contains(&format!("machine {round}\n"))
                && mac_text.contains(&format!("mac {round}\n"))
                && w.mac(&format!("made/{round}.txt")).exists()
        });
    cell(json!({"use": "cloud-chat-start", "repo": "git", "direction": "rapid",
        "fault": "none", "correct": correct, "bring_back_ms": pulls.first(),
        "bring_back_p95_ms": p95(&pulls), "rounds": pulls.len(),
        "note": failed.clone().unwrap_or_default()}));
    assert!(correct, "{failed:?}\nnotes: {notes}\nmac.txt: {mac_text}");
}

/// Move to Cloud and a New Workspace on Cloud (`cmux link seed push`): what reaches the machine
/// today, and how long it takes beside the projection of the same folder; then the frozen chat's
/// `--since-last` and Bring Back Local, both ways.
#[test]
fn move_to_cloud_round_trips_and_is_timed_beside_the_projection() {
    let Some(mut w) = world("move", 2000) else { return };
    let Some((_, projected_ms)) = w.start_projected() else { return };
    let remote = w.machine.work().join("app-move");
    let (pushed, push_ms) = w.seed_push(&w.machine, &remote, false);
    assert_eq!(pushed["ok"], true, "seed push: {pushed}");
    let projected = fs::symlink_metadata(&remote).is_ok()
        && fs::read_to_string("/proc/self/mounts")
            .unwrap_or_default()
            .contains(&remote.to_string_lossy().into_owned());
    let (first_read_ms, p95_open_ms) = opens(&remote, 50);
    let git_ms = git_status_ms(&w.machine, &remote);
    // The frozen chat's last changes, then the machine's edit comes home.
    write(&w.mac("mac.txt"), "mac, before the move froze\n");
    let (delta, delta_ms) = w.seed_push(&w.machine, &remote, true);
    let delta_seen = read(&remote.join("mac.txt")) == "mac, before the move froze\n";
    write(&remote.join("notes.txt"), "notes, from the machine\n");
    let (back, back_ms) = w.bring_back_local(&w.machine, &remote);
    let correct = delta["ok"] == true
        && delta_seen
        && back["ok"] == true
        && read(&w.mac("notes.txt")) == "notes, from the machine\n"
        && w.mac_status() == w.machine.side.status(&remote);
    cell(json!({"use": "move-to-cloud", "repo": "git", "direction": "local->remote->local",
        "fault": "none", "correct": correct, "projected": projected,
        "mode": pushed["mode"], "first_read_ms": first_read_ms, "p95_open_ms": p95_open_ms,
        "git_status_ms": git_ms, "seed_push_ms": push_ms, "projection_start_ms": projected_ms,
        "since_last_ms": delta_ms, "bring_back_ms": back_ms,
        "note": format!("push {pushed} delta {delta} back {back}")}));
    assert!(correct, "push {pushed}\ndelta {delta}\nback {back}");
}
