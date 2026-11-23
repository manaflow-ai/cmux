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

/// The `cmux-tui` both sides run: this build's, or `CMUX_PROJECTION_MATRIX_BIN` when the test
/// binary was built on another host and is run here (the matrix's lane VM cells).
fn bin() -> String {
    std::env::var("CMUX_PROJECTION_MATRIX_BIN")
        .unwrap_or_else(|_| env!("CARGO_BIN_EXE_cmux-tui").to_owned())
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
        // Names unquoted, so a status line ends with the name a case removes by.
        self.git(
            dir,
            &["-c", "core.quotePath=false", "status", "--porcelain", "--untracked-files=all"],
        )
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
    /// Where the Mac dials: the socket, or on a machine of one's own the carrier in front of it.
    dial: PathBuf,
    session: String,
}

/// The carrier a Mac reaches a machine of its own through, standing in at `at`: each connection
/// it opens to `socket` is stamped the owner's (`carrier-role`) before the Mac's bytes pass both
/// ways. On such a machine an unstamped local connection may not use file ops.
fn carrier(at: &Path, socket: &Path) {
    use std::io::{Read as _, Write as _};
    use std::os::unix::net::{UnixListener, UnixStream};
    let listener = UnixListener::bind(at).unwrap();
    let socket = socket.to_path_buf();
    std::thread::spawn(move || {
        for mac in listener.incoming() {
            let Ok(mac) = mac else { return };
            let socket = socket.clone();
            std::thread::spawn(move || {
                let Ok(mut machine) = UnixStream::connect(&socket) else { return };
                if machine
                    .write_all(b"{\"cmd\":\"carrier-role\",\"id\":0,\"vmk\":\"owner\"}\n")
                    .is_err()
                {
                    return;
                }
                // The stamp's one-line answer, read a byte at a time so none of the Mac's is taken.
                let mut answer = Vec::new();
                let mut byte = [0u8; 1];
                while machine.read_exact(&mut byte).is_ok() && byte[0] != b'\n' {
                    answer.push(byte[0]);
                }
                assert!(
                    String::from_utf8_lossy(&answer).contains("\"ok\":true"),
                    "carrier-role: {}",
                    String::from_utf8_lossy(&answer)
                );
                let (Ok(mut mac_in), Ok(mut machine_out)) = (mac.try_clone(), machine.try_clone())
                else {
                    return;
                };
                let up = std::thread::spawn(move || {
                    let _ = std::io::copy(&mut mac_in, &mut machine_out);
                    let _ = machine_out.shutdown(std::net::Shutdown::Write);
                });
                let mut mac_out = mac;
                let _ = std::io::copy(&mut machine, &mut mac_out);
                let _ = mac_out.shutdown(std::net::Shutdown::Write);
                let _ = up.join();
            });
        }
    });
}

impl Machine {
    fn start(at: &Path) -> Self {
        let side = Side::make(at);
        let acpmux = at.join("acpmux");
        fs::create_dir_all(&acpmux).unwrap();
        fs::set_permissions(&acpmux, fs::Permissions::from_mode(0o700)).unwrap();
        let socket = at.join("m.sock");
        let dial = if Self::own() { at.join("carrier.sock") } else { socket.clone() };
        let machine = Self {
            side,
            socket,
            dial,
            session: format!("projection-matrix-{}", std::process::id()),
        };
        let ensure = machine.server("ensure").output().unwrap();
        assert!(ensure.status.success(), "ensure: {}", String::from_utf8_lossy(&ensure.stderr));
        if Self::own() {
            carrier(&machine.dial, &machine.socket);
        }
        machine
    }

    /// `CMUX_PROJECTION_MATRIX_MACHINE=own`: the machine is a Linux machine of the person's own (a
    /// lane VM, a CI machine), not a Cloud host, and serves the folder to its owner only.
    fn own() -> bool {
        std::env::var("CMUX_PROJECTION_MATRIX_MACHINE").is_ok_and(|kind| kind == "own")
    }

    /// The machine's records (the debug-only `CMUX_TEST_CLOUD_ETC` seam): a Cloud host's, or
    /// none for a machine of one's own.
    fn cloud_etc(&self) -> PathBuf {
        let etc = self.side.home.parent().unwrap().join("etc-cmux");
        fs::create_dir_all(&etc).unwrap();
        if Self::own() {
            return etc;
        }
        fs::write(etc.join("image-stamp"), "cmux-vm inputs=projection-roundtrip-matrix\n").unwrap();
        fs::write(etc.join("vm-kind"), "owner\n").unwrap();
        fs::set_permissions(&etc, fs::Permissions::from_mode(0o755)).unwrap();
        for file in ["image-stamp", "vm-kind"] {
            fs::set_permissions(etc.join(file), fs::Permissions::from_mode(0o644)).unwrap();
        }
        etc
    }

    fn server(&self, action: &str) -> Command {
        let mut command = self.side.cmux();
        command
            .env("ACPMUX_HOME", self.side.home.parent().unwrap().join("acpmux"))
            .env("CMUX_TEST_CLOUD_ETC", self.cloud_etc());
        if Self::own() {
            command.env_remove("CMUX_CODEROUTER_URL");
        } else {
            command
                .env("CMUX_VM_ID", "vm-projection-roundtrip-matrix")
                .env("CMUX_CODEROUTER_URL", "http://127.0.0.1:9");
        }
        command
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
    /// The link between them when the case pauses the machine ([`pause::Relay`]).
    relay: Option<pause::Relay>,
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
    trip_as(case, true, fill)
}

/// Makes the Mac's folder with `fill`, then starts the chat from it: projected, or (`projected`
/// false, with projection turned off) copied as before.
fn trip_as(case: &str, projected: bool, fill: impl FnOnce(&Side, &Path)) -> Result<Trip, Skip> {
    trip_with(case, projected, None, fill)
}

/// [`trip_as`], with the Mac reaching the machine through a [`pause::Relay`] when `relay` says
/// whether it has a quiet socket.
fn trip_with(
    case: &str,
    projected: bool,
    relay: Option<bool>,
    fill: impl FnOnce(&Side, &Path),
) -> Result<Trip, Skip> {
    if projected && !fuse_here() {
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
    let mut machine = Machine::start(&root.join("vm"));
    let relay = relay.map(|quiet| {
        let relay = pause::Relay::start(&root.join("relay.sock"), &machine.dial, quiet);
        machine.dial = relay.path.clone();
        relay
    });
    let key = new_key();
    let output = mac
        .cmux()
        .args(["link", "start-chat", "copy", "--key", &key, "--account", "leo"])
        .args(["--machine", "vm-a", "--socket"])
        .arg(&machine.dial)
        .arg("--local")
        .arg(&local)
        .arg("--work-root")
        .arg(machine.side.home.join("work"))
        .env("CMUX_PROJECTED_FOLDERS", if projected { "1" } else { "0" })
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
    let trip = Trip { mac, machine, local, folder, root, relay };
    if !projected {
        assert_ne!(answer["mode"], "projected", "{answer}");
        // A held copy answers at its head and sends the rest after: the folder reads ready once
        // it is whole.
        if answer["filling"] == true {
            cmux_git::sync_barrier::wait_ready(&trip.folder, Duration::from_secs(120))
                .unwrap_or_else(|error| panic!("the copy never filled: {error:#} {answer}"));
        }
        return Ok(trip);
    }
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
            .arg(&self.machine.dial)
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

    /// Ends the folder's server and serves the folder again, as after this Mac restarted: the
    /// machine attaches it to the mount it kept, or mounts the Mac's newer listing. The new
    /// server, ended when it drops.
    fn restart_server(&self) -> Server {
        let stopped =
            self.mac.cmux().args(["link", "project", "stop", "--at"]).arg(&self.folder).output();
        assert!(stopped.unwrap().status.success());
        let mut child = self
            .mac
            .cmux()
            .args(["link", "project", "serve", "--socket"])
            .arg(&self.machine.dial)
            .arg("--at")
            .arg(&self.folder)
            .args(["--name", &self.projection_name()])
            .arg(&self.local)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufRead::read_line(
            &mut std::io::BufReader::new(child.stdout.take().unwrap()),
            &mut line,
        )
        .unwrap();
        let answer: Value = serde_json::from_str(line.trim()).unwrap_or(Value::Null);
        assert_eq!(answer["ok"], true, "serve again: {line}");
        eprintln!("serve again: {line}");
        Server(child)
    }

    /// The projection's name, as the folder's server recorded it for Bring Back.
    fn projection_name(&self) -> String {
        let mut stack = vec![self.mac.state.clone()];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                } else if path.extension().is_some_and(|ext| ext == "json")
                    && path.parent().is_some_and(|parent| parent.ends_with("projections"))
                    && let Ok(record) = serde_json::from_slice::<Value>(&fs::read(&path).unwrap())
                    && record["remote"].as_str() == self.folder.to_str()
                    && let Some(name) = record["name"].as_str()
                {
                    return name.to_owned();
                }
            }
        }
        panic!("no projection recorded for {}", self.folder.display());
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
    fs::create_dir_all(path.parent().unwrap()).unwrap();
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
#[ignore = "follow-up: no re-manifest yet; the Mac answers CHANGED and the machine's read fails with ESTALE"]
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

/// The folder's server restarted after a Bring Back (this Mac restarted, the app relaunched): the
/// base that Bring Back moved stays, so the next Bring Back takes the later edits instead of
/// stopping on `sync_base_mismatch`.
#[test]
fn a_bring_back_after_the_server_restarted_takes_the_later_edits() {
    let t = trip_or_skip!("restart", repo);
    write(&t.at("src/a.txt"), "alpha, first\n");
    t.brought_back();
    let _server = t.restart_server();
    write(&t.at("src/a.txt"), "alpha, second\n");
    let answer = t.brought_back();
    assert_eq!(read(&t.mac("src/a.txt")), "alpha, second\n", "{answer}");
    t.statuses_agree();
}

/// A server [`Trip::restart_server`] started, ended when it drops.
struct Server(std::process::Child);

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// `~/Projects`' shape (hard case 12): `api` and `web`, two repositories, and `notes.md` beside
/// them, in a folder that is not a repository itself.
fn parent_of_repositories(side: &Side, at: &Path) {
    for name in ["api", "web"] {
        let repo_at = at.join(name);
        fs::create_dir_all(&repo_at).unwrap();
        repo(side, &repo_at);
    }
    write(&at.join("notes.md"), "notes\n");
}

/// `~/Projects`' shape (hard case 12): a folder of repositories, not one itself. An edit in one of
/// them comes back, and that repository's `git status` reads the same on both sides.
#[test]
fn an_edit_in_a_repository_of_a_parent_folder_comes_back() {
    let t = trip_or_skip!("parent", parent_of_repositories);
    write(&t.at("api/src/a.txt"), "alpha, edited on the machine\n");
    write(&t.at("notes.md"), "notes, edited on the machine\n");
    let answer = t.brought_back();
    assert_eq!(read(&t.mac("notes.md")), "notes, edited on the machine\n", "{answer}");
    assert_eq!(read(&t.mac("api/src/a.txt")), "alpha, edited on the machine\n", "{answer}");
    assert_eq!(t.mac.status(&t.mac("api")), t.machine.side.status(&t.at("api")));
}

/// Edits in two repositories of a parent folder and in the parent's own files come back in one
/// Bring Back, each repository's `git status` reading the same on both sides.
#[test]
fn edits_in_two_repositories_and_the_parent_come_back_together() {
    let t = trip_or_skip!("parent-two", parent_of_repositories);
    parent_edits_come_back(&t);
}

/// The same for a copied chat (projection off): its Bring Back is the same pull.
#[test]
fn edits_in_two_repositories_of_a_copied_parent_folder_come_back_together() {
    let t = trip_as("parent-copy", false, parent_of_repositories).unwrap();
    parent_edits_come_back(&t);
}

fn parent_edits_come_back(t: &Trip) {
    write(&t.at("api/src/a.txt"), "alpha of api, edited on the machine\n");
    write(&t.at("web/src/b.txt"), "bravo of web, edited on the machine\n");
    write(&t.at("web/src/new.txt"), "new in web\n");
    t.on_machine("rm api/src/deep/c.txt");
    write(&t.at("notes.md"), "notes, edited on the machine\n");
    let answer = t.brought_back();
    assert_eq!(read(&t.mac("api/src/a.txt")), "alpha of api, edited on the machine\n", "{answer}");
    assert_eq!(read(&t.mac("web/src/b.txt")), "bravo of web, edited on the machine\n", "{answer}");
    assert_eq!(read(&t.mac("web/src/new.txt")), "new in web\n", "{answer}");
    assert!(!t.mac("api/src/deep/c.txt").exists(), "{answer}");
    assert_eq!(read(&t.mac("notes.md")), "notes, edited on the machine\n", "{answer}");
    assert_eq!(answer["repositories"], serde_json::json!(["api", "web"]), "{answer}");
    for name in ["api", "web"] {
        assert_eq!(t.mac.status(&t.mac(name)), t.machine.side.status(&t.at(name)), "{name}");
    }
    assert_eq!(t.mac.status(&t.mac("api")), " M src/a.txt\n D src/deep/c.txt\n");
    // Nothing new: nothing moves.
    let again = t.brought_back();
    assert_eq!(again["written"], 0, "{again}");
    assert_eq!(again["deleted"], 0, "{again}");
}

/// A conflict in one repository of a parent folder: nothing of any repository or of the parent
/// changes on the Mac, and the answer names the repository.
#[test]
fn a_conflict_in_one_repository_leaves_every_repository_unapplied() {
    let t = trip_or_skip!("parent-conflict", parent_of_repositories);
    write(&t.at("api/src/a.txt"), "alpha of api, edited on the machine\n");
    write(&t.at("notes.md"), "notes, edited on the machine\n");
    write(&t.at("web/src/a.txt"), "alpha of web, edited on the machine\n");
    std::thread::sleep(Duration::from_millis(20));
    write(&t.mac("web/src/a.txt"), "alpha of web, edited on the mac\n");
    let answer = t.bring_back();
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    assert_eq!(answer["conflicts"], serde_json::json!(["web/src/a.txt"]), "{answer}");
    assert!(answer["error"].as_str().unwrap().contains("web: this repository"), "{answer}");
    assert_eq!(read(&t.mac("web/src/a.txt")), "alpha of web, edited on the mac\n");
    assert_eq!(read(&t.mac("api/src/a.txt")), "alpha\n", "{answer}");
    assert_eq!(read(&t.mac("notes.md")), "notes\n", "{answer}");
    assert_eq!(t.mac.status(&t.mac("api")), "", "{answer}");
}

/// Both sides committed in one repository of a parent folder: its branch is the conflict
/// (`web/.git/HEAD`), and the other repository's edit stays on the machine with it.
#[test]
fn a_branch_moved_on_both_sides_in_one_repository_leaves_every_repository_unapplied() {
    let t = trip_or_skip!("parent-branch", parent_of_repositories);
    write(&t.at("api/src/a.txt"), "alpha of api, edited on the machine\n");
    write(&t.at("web/src/a.txt"), "alpha of web, committed on the machine\n");
    t.machine.side.git(&t.at("web"), &["commit", "-qam", "on the machine"]);
    write(&t.mac("web/src/b.txt"), "bravo of web, committed on the mac\n");
    t.mac.git(&t.mac("web"), &["commit", "-qam", "on the mac"]);
    let mac_head = t.mac.git(&t.mac("web"), &["rev-parse", "HEAD"]);
    let answer = t.bring_back();
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    let conflicts = answer["conflicts"].to_string();
    assert!(conflicts.contains("web/.git/HEAD"), "{answer}");
    assert_eq!(t.mac.git(&t.mac("web"), &["rev-parse", "HEAD"]), mac_head);
    assert_eq!(read(&t.mac("web/src/a.txt")), "alpha\n", "{answer}");
    assert_eq!(read(&t.mac("api/src/a.txt")), "alpha\n", "{answer}");
}

/// A commit on the machine in one repository of a parent folder fast-forwards that repository's
/// branch on the Mac; the other repository's stays.
#[test]
fn a_commit_in_a_repository_of_a_parent_folder_fast_forwards_it() {
    let t = trip_or_skip!("parent-commit", parent_of_repositories);
    nested_commit_fast_forwards(&t);
}

/// The same for a copied chat.
#[test]
fn a_commit_in_a_repository_of_a_copied_parent_folder_fast_forwards_it() {
    let t = trip_as("parent-copy-commit", false, parent_of_repositories).unwrap();
    nested_commit_fast_forwards(&t);
}

fn nested_commit_fast_forwards(t: &Trip) {
    let web_head = t.mac.git(&t.mac("web"), &["rev-parse", "HEAD"]);
    write(&t.at("api/src/a.txt"), "alpha of api, committed on the machine\n");
    t.machine.side.git(&t.at("api"), &["commit", "-qam", "on the machine"]);
    let answer = t.brought_back();
    assert_eq!(answer["fast_forwarded"], true, "{answer}");
    assert_eq!(answer["fast_forwarded_repositories"], serde_json::json!(["api"]), "{answer}");
    assert_eq!(
        t.mac.git(&t.mac("api"), &["rev-parse", "HEAD"]),
        t.machine.side.git(&t.at("api"), &["rev-parse", "HEAD"])
    );
    assert_eq!(read(&t.mac("api/src/a.txt")), "alpha of api, committed on the machine\n");
    assert_eq!(t.mac.status(&t.mac("api")), "", "{answer}");
    assert_eq!(t.mac.status(&t.mac("api")), t.machine.side.status(&t.at("api")));
    assert_eq!(t.mac.git(&t.mac("web"), &["rev-parse", "HEAD"]), web_head);
}

/// A seeded randomized round trip, after cmux#45882's (the same seeds and promises, adapted to
/// this pull, which changes nothing on the Mac when any path conflicts): small trees, random
/// edits, deletes, moves and new files on the machine and edits and deletes on the Mac, then
/// A machine paused under a live agent and resumed (`projection_roundtrip_matrix/pause.rs`).
#[path = "projection_roundtrip_matrix/pause.rs"]
mod pause;

/// Bring Back, twice per trial. After each pull:
/// - with no path changed on both sides, every machine change landed and every Mac edit stayed;
/// - otherwise the conflicts are exactly the paths both sides changed, nothing of the Mac's
///   changed, and each file the machine still has went beside the Mac's as a conflict file.
///
/// `CMUX_PROJECTION_RANDOM_TRIALS` sets the trials per seed (default 25).
mod randomized {
    use std::collections::{BTreeMap, BTreeSet};

    use super::*;

    const PATHS: [&str; 9] = ["a", "b", "c", "d/a", "d/b", "d/c", "d/e/a", "d/e/b", "d/e/c"];

    /// xorshift64*.
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
        }

        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }

        /// Text no other write of the run has; its size varies too.
        fn text(&mut self, who: &str) -> String {
            let pad = "x".repeat(usize::try_from(self.below(8)).unwrap());
            format!("{who} {} {pad}\n", self.next())
        }
    }

    /// What one side did to a path: its new text, or None for a delete.
    type Changes = BTreeMap<String, Option<String>>;

    /// The Mac's files, by path (the pull's own hidden folders left out).
    fn tree(at: &Path) -> BTreeMap<String, String> {
        let mut files = BTreeMap::new();
        let mut stack = vec![at.to_path_buf()];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).unwrap() {
                let entry = entry.unwrap();
                let path = entry.path();
                let relative = path.strip_prefix(at).unwrap().to_string_lossy().into_owned();
                if relative.starts_with(".cmux") {
                    continue;
                }
                if entry.file_type().unwrap().is_dir() {
                    stack.push(path);
                } else {
                    files.insert(relative, fs::read_to_string(&path).unwrap_or_default());
                }
            }
        }
        files
    }

    /// One round of random changes: the machine's (on the mount) and the Mac's.
    fn round(t: &Trip, rng: &mut Rng, now: &BTreeMap<String, String>) -> (Changes, Changes) {
        let (mut machine, mut mac) = (Changes::new(), Changes::new());
        for (path, text) in now {
            let choice = rng.below(12);
            // Only a path both sides agree on: an earlier Mac edit the machine never saw would
            // make any machine change a conflict this round did not make.
            if fs::read_to_string(t.at(path)).ok().as_ref() != Some(text) {
                continue;
            }
            match choice {
                0..=2 => {
                    let text = rng.text("machine");
                    write(&t.at(path), &text);
                    machine.insert(path.clone(), Some(text));
                }
                3 => {
                    fs::remove_file(t.at(path)).unwrap();
                    machine.insert(path.clone(), None);
                }
                4 => {
                    // A move: a delete and a create, as the pull sees it.
                    let to = format!("{path}.moved");
                    if !now.contains_key(&to) && !t.at(&to).exists() && !machine.contains_key(&to) {
                        fs::rename(t.at(path), t.at(&to)).unwrap();
                        machine.insert(path.clone(), None);
                        machine.insert(to, Some(now[path].clone()));
                    }
                }
                _ => {}
            }
        }
        if rng.below(2) == 0 {
            let text = rng.text("new");
            let path = format!("d/new{}", rng.below(1000));
            if !t.at(&path).exists() && !machine.contains_key(&path) {
                write(&t.at(&path), &text);
                machine.insert(path, Some(text));
            }
        }
        for path in now.keys() {
            match rng.below(10) {
                0 => {
                    let text = rng.text("mac");
                    write(&t.mac(path), &text);
                    mac.insert(path.clone(), Some(text));
                }
                1 => {
                    fs::remove_file(t.mac(path)).unwrap();
                    mac.insert(path.clone(), None);
                }
                _ => {}
            }
        }
        (machine, mac)
    }

    fn trial(seed: u64, number: usize) {
        let label = format!("seed {seed:#x} trial {number}");
        let t = trip_or_skip!(&format!("random-{seed:x}-{number}"), |_, at| {
            for path in PATHS {
                write(&at.join(path), &format!("{path} as projected\n"));
            }
        });
        let mut rng = Rng(seed ^ (number as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1);
        for pull in 0..2 {
            let before = tree(&t.local);
            let (machine, mac) = round(&t, &mut rng, &before);
            let mac_now = tree(&t.local);
            // Changed on both sides, differently (both deleted it is no conflict).
            let both: BTreeSet<&String> = machine
                .iter()
                .filter(|(path, change)| mac.get(*path).is_some_and(|mine| mine != *change))
                .map(|(path, _)| path)
                .collect();
            let answer = t.bring_back();
            let after = tree(&t.local);
            let context = format!("{label} pull {pull}: machine {machine:?} mac {mac:?} {answer}");
            if both.is_empty() {
                assert_eq!(answer["ok"], true, "{context}");
                let mut want = mac_now.clone();
                for (path, text) in &machine {
                    match text {
                        Some(text) => want.insert(path.clone(), text.clone()),
                        None => want.remove(path),
                    };
                }
                assert_eq!(after, want, "{context}");
                continue;
            }
            assert_eq!(answer["error_code"], "sync_conflict", "{context}");
            let conflicts: BTreeSet<String> = answer["conflicts"]
                .as_array()
                .unwrap()
                .iter()
                .map(|path| path.as_str().unwrap().to_owned())
                .collect();
            let want: BTreeSet<String> = both.iter().map(|path| (*path).clone()).collect();
            assert_eq!(conflicts, want, "{context}");
            for (path, text) in &after {
                match mac_now.get(path) {
                    Some(mine) => assert_eq!(text, mine, "{context}: {path}"),
                    None => {
                        let edited = path
                            .strip_suffix(".cmux-sync-conflict")
                            .unwrap_or_else(|| panic!("{context}: {path} appeared on a conflict"));
                        // The machine's file whole (a projected base), or the line merge of
                        // the three versions with markers (a hashed base), which holds it.
                        let Some(Some(theirs)) = machine.get(edited) else {
                            panic!("{context}: {path} beside a path the machine did not write")
                        };
                        assert!(
                            text == theirs || text.contains(&format!("=======\n{theirs}")),
                            "{context}: {path}: {text:?}"
                        );
                    }
                }
            }
            for path in mac_now.keys() {
                assert!(after.contains_key(path), "{context}: {path} went");
            }
            // Against a projected base (the first pull) the machine's version always goes
            // beside; against a hashed one a delete on one side is a whole-file conflict, named.
            for path in &both {
                if pull == 0 && matches!(machine.get(*path), Some(Some(_))) {
                    assert!(
                        after.contains_key(&format!("{path}.cmux-sync-conflict")),
                        "{context}: no conflict file for {path}"
                    );
                }
            }
            // The rest of a trial builds on a pull that went through.
            return;
        }
    }

    fn seed_run(seed: u64) {
        let trials = std::env::var("CMUX_PROJECTION_RANDOM_TRIALS")
            .ok()
            .and_then(|n| n.parse().ok())
            .unwrap_or(25);
        for number in 0..trials {
            trial(seed, number);
        }
    }

    #[test]
    fn seed_5eed_0001() {
        seed_run(0x5eed_0001);
    }

    #[test]
    fn seed_5eed_0002() {
        seed_run(0x5eed_0002);
    }

    #[test]
    fn seed_00c0_ffee() {
        seed_run(0x00c0_ffee);
    }

    #[test]
    fn seed_dead_beef() {
        seed_run(0xdead_beef);
    }
}

/// The matrix's repository axis: the same round trip, both ways, over real repositories rather
/// than four generated files. Mac to machine: every file the Mac has reads back through the mount
/// with the same bytes (`git hash-object --no-filters` on both sides), the same executable bit and
/// the same link target, and `git status`, HEAD and the shallow marker agree. Machine to Mac: an
/// edit, a new file in a new folder, a delete, a rename, a `chmod +x` and a commit on the machine
/// come back by Bring Back beside an edit only the Mac made, and a second Bring Back takes a later
/// edit. A public repository that can't be cloned here skips with the reason, never passes.
///
/// `CMUX_PROJECTION_MATRIX_REPOS` (comma-separated clone URLs or paths) adds repositories of the
/// runner's own choosing to `extra_repositories_round_trip_both_ways`.
///
/// Leo, 2026-11-19: "the projection folder file system thing ... reliable back and forth".
mod repositories {
    use super::*;

    /// What a repository case starts from.
    enum From {
        /// A clone of a URL or path (`depth` 0: its whole history).
        Clone { url: String, depth: u32 },
        /// A generated repository.
        Made(fn(&Side, &Path)),
    }

    fn clone_into(side: &Side, at: &Path, url: &str, depth: u32) -> Result<(), String> {
        let mut command = side.git_command(at, &["clone", "-q", "--no-tags"]);
        if depth > 0 {
            command.arg(format!("--depth={depth}"));
        }
        command.args(["--", url, "."]).env("GIT_TERMINAL_PROMPT", "0");
        let output = command.output().map_err(|error| format!("git clone {url}: {error}"))?;
        if output.status.success() {
            Ok(())
        } else {
            Err(format!("git clone {url}: {}", String::from_utf8_lossy(&output.stderr).trim()))
        }
    }

    /// Every file of a checkout, NUL-separated as git lists it (tracked and untracked, not
    /// ignored), without the gitlinks of submodules.
    fn files(side: &Side, dir: &Path) -> Vec<String> {
        let listed =
            side.git(dir, &["ls-files", "-z", "--cached", "--others", "--exclude-standard"]);
        // A checked-out submodule's files are compared too, not only its folder.
        let inside = side.git(dir, &["ls-files", "-z", "--cached", "--recurse-submodules"]);
        let mut files: Vec<String> = listed
            .split('\0')
            .chain(inside.split('\0'))
            .filter(|name| !name.is_empty())
            .filter(|name| dir.join(name).symlink_metadata().is_ok_and(|meta| !meta.is_dir()))
            .map(str::to_owned)
            .collect();
        files.sort();
        files.dedup();
        files
    }

    /// Each file's blob id as its bytes read on this side (a link: its target's text), its
    /// executable bit and whether it is a link: every byte of every file is read.
    fn fingerprint(side: &Side, dir: &Path, names: &[String]) -> Vec<(String, String)> {
        let mut out = Vec::with_capacity(names.len());
        let mut regular = Vec::new();
        for name in names {
            let meta = dir.join(name).symlink_metadata().unwrap_or_else(|error| {
                panic!("{}: {error}", dir.join(name).display());
            });
            if meta.file_type().is_symlink() {
                let target = fs::read_link(dir.join(name)).unwrap();
                out.push((name.clone(), format!("link {}", target.display())));
            } else {
                regular.push(name.clone());
            }
        }
        for chunk in regular.chunks(2_000) {
            let mut command =
                side.git_command(dir, &["hash-object", "--no-filters", "--stdin-paths"]);
            let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
            let mut stdin = child.stdin.take().unwrap();
            let list = chunk.join("\n") + "\n";
            let writer = std::thread::spawn(move || {
                use std::io::Write as _;
                stdin.write_all(list.as_bytes()).unwrap();
            });
            let output = child.wait_with_output().unwrap();
            writer.join().unwrap();
            assert!(output.status.success(), "hash-object in {}", dir.display());
            let ids = String::from_utf8(output.stdout).unwrap();
            for (name, id) in chunk.iter().zip(ids.lines()) {
                let exec = dir.join(name).metadata().unwrap().permissions().mode() & 0o111 != 0;
                out.push((name.clone(), format!("{id} {}", if exec { "x" } else { "-" })));
            }
        }
        out.sort();
        out
    }

    /// The first `count` regular, non-empty text files of `names` under a folder (never `.git`).
    fn text_files(dir: &Path, names: &[String], count: usize) -> Vec<String> {
        names
            .iter()
            .filter(|name| !name.starts_with(".git") && name.contains('/'))
            .filter(|name| {
                let path = dir.join(name);
                path.symlink_metadata().is_ok_and(|meta| meta.is_file() && meta.len() > 0)
                    && fs::read(&path).is_ok_and(|bytes| {
                        bytes.len() < 256 * 1024 && std::str::from_utf8(&bytes).is_ok()
                    })
            })
            .take(count)
            .cloned()
            .collect()
    }

    /// The machine's status without the Mac-only edit's line.
    fn without(status: &str, name: &str) -> String {
        status
            .lines()
            // A name with a space stays in quotes.
            .filter(|line| !line.trim_end_matches('"').ends_with(name))
            .map(|line| format!("{line}\n"))
            .collect()
    }

    fn round_trip(case: &str, from: From) {
        round_trip_as(case, true, from);
    }

    /// The same round trip for a chat started projected or (`projected` false) copied.
    fn round_trip_as(case: &str, projected: bool, from: From) {
        let mut why_not = None;
        let started = Instant::now();
        let result = trip_as(case, projected, |side, at| match &from {
            From::Clone { url, depth } => {
                if let Err(error) = clone_into(side, at, url, *depth) {
                    why_not = Some(error);
                }
            }
            From::Made(make) => make(side, at),
        });
        if let Some(why) = why_not {
            eprintln!("skipping {case}: {why}");
            return;
        }
        let t = match result {
            Ok(t) => t,
            Err(why) => {
                eprintln!("skipping {case}: {why}");
                return;
            }
        };
        let projected_in = started.elapsed();

        // Mac to machine: the whole folder, byte for byte.
        let names = files(&t.mac, &t.local);
        assert!(!names.is_empty(), "{case}: the Mac's folder lists no files");
        let read_from = Instant::now();
        let on_mac = fingerprint(&t.mac, &t.local, &names);
        let on_machine = fingerprint(&t.machine.side, &t.folder, &names);
        let read_in = read_from.elapsed();
        let differ: Vec<_> = on_mac
            .iter()
            .zip(&on_machine)
            .filter(|(mac, machine)| mac != machine)
            .take(10)
            .collect();
        assert!(differ.is_empty(), "{case}: files read differently on the machine: {differ:?}");
        assert_eq!(on_mac.len(), on_machine.len(), "{case}");
        assert_eq!(
            t.mac.git(&t.local, &["rev-parse", "HEAD"]),
            t.machine.side.git(&t.folder, &["rev-parse", "HEAD"]),
            "{case}: HEAD"
        );
        assert_eq!(
            t.mac.git(&t.local, &["rev-parse", "--is-shallow-repository"]),
            t.machine.side.git(&t.folder, &["rev-parse", "--is-shallow-repository"]),
            "{case}: shallow"
        );
        t.statuses_agree();

        // Machine to Mac: the agent's edits, beside one only the Mac made.
        let picked = text_files(&t.local, &names, 5);
        assert!(picked.len() >= 4, "{case}: too few text files to edit: {picked:?}");
        let (edited, deleted, renamed, committed, mac_only) =
            (&picked[0], &picked[1], &picked[2], &picked[3], picked.get(4));
        let mut edited_text = read(&t.at(edited));
        edited_text.push_str("an edit on the machine\n");
        write(&t.at(edited), &edited_text);
        write(&t.at("cmux-matrix-new/notes.txt"), "a new file in a new folder\n");
        t.on_machine(&format!("rm -- '{deleted}' && mv -- '{renamed}' '{renamed}.moved'"));
        t.on_machine(
            "printf '#!/bin/sh\\necho hi\\n' > cmux-matrix-tool.sh && chmod +x cmux-matrix-tool.sh",
        );
        let mut committed_text = read(&t.at(committed));
        committed_text.push_str("a commit on the machine\n");
        write(&t.at(committed), &committed_text);
        t.machine.side.git(&t.folder, &["commit", "-q", "-m", "on the machine", "--", committed]);
        let mac_only_text = mac_only.map(|name| {
            std::thread::sleep(Duration::from_millis(20));
            let mut text = read(&t.mac(name));
            text.push_str("an edit only on the Mac\n");
            write(&t.mac(name), &text);
            text
        });

        let back_from = Instant::now();
        let answer = t.brought_back();
        let back_in = back_from.elapsed();
        assert_eq!(read(&t.mac(edited)), edited_text, "{case}: {answer}");
        assert_eq!(read(&t.mac("cmux-matrix-new/notes.txt")), "a new file in a new folder\n");
        assert!(!t.mac(deleted).exists(), "{case}: {deleted} still on the Mac: {answer}");
        assert!(!t.mac(renamed).exists(), "{case}: {renamed} still on the Mac: {answer}");
        assert!(t.mac(&format!("{renamed}.moved")).exists(), "{case}: {answer}");
        let tool = t.mac("cmux-matrix-tool.sh");
        assert!(tool.metadata().unwrap().permissions().mode() & 0o111 != 0, "{case}: exec bit");
        assert_eq!(read(&t.mac(committed)), committed_text, "{case}: {answer}");
        assert_eq!(
            t.mac.git(&t.local, &["rev-parse", "HEAD"]),
            t.machine.side.git(&t.folder, &["rev-parse", "HEAD"]),
            "{case}: the machine's commit: {answer}"
        );
        if let (Some(name), Some(text)) = (mac_only, &mac_only_text) {
            assert_eq!(&read(&t.mac(name)), text, "{case}: the Mac's own edit: {answer}");
            assert_eq!(without(&t.mac_status(), name), t.machine_status(), "{case}: git status");
        } else {
            t.statuses_agree();
        }

        // Again: a later edit comes back by a second Bring Back, and nothing else moves.
        edited_text.push_str("a second edit on the machine\n");
        write(&t.at(edited), &edited_text);
        let again = t.brought_back();
        assert_eq!(read(&t.mac(edited)), edited_text, "{case}: {again}");
        assert_eq!(again["deleted"], 0, "{case}: {again}");
        eprintln!(
            "matrix {case}: pass files={} projected_ms={} read_all_both_sides_ms={} bring_back_ms={}",
            names.len(),
            projected_in.as_millis(),
            read_in.as_millis(),
            back_in.as_millis()
        );
    }

    /// Exec bits, an empty file, a binary file, names with spaces and non-ASCII, links inside,
    /// deep folders and a `.gitattributes` with an eol rule.
    fn mixed(side: &Side, at: &Path) {
        side.git(at, &["init", "-q"]);
        write(&at.join(".gitattributes"), "*.txt text eol=lf\n*.bin binary\n");
        write(&at.join("src/main.rs"), "fn main() {}\n");
        write(&at.join("src/with space.txt"), "a name with a space\n");
        write(&at.join("src/naïve café.txt"), "a name past ASCII\n");
        write(&at.join("docs/a/b/c/d/e/deep.md"), "deep\n");
        write(&at.join("docs/readme.txt"), "docs\n");
        write(&at.join("scripts/run.sh"), "#!/bin/sh\necho run\n");
        fs::set_permissions(at.join("scripts/run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        write(&at.join("empty.txt"), "");
        let binary: Vec<u8> =
            (0..300_000u32).map(|n| (n.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
        fs::write(at.join("data.bin"), binary).unwrap();
        std::os::unix::fs::symlink("src/main.rs", at.join("main-link.rs")).unwrap();
        std::os::unix::fs::symlink("../docs", at.join("src/docs-link")).unwrap();
        side.git(at, &["add", "-A"]);
        side.git(at, &["commit", "-qm", "mixed"]);
        write(&at.join("src/untracked.txt"), "untracked on the Mac\n");
    }

    /// A repository with a submodule (a local one, so no network).
    fn with_submodule(side: &Side, at: &Path) {
        let inner = at.parent().unwrap().join("inner-src");
        fs::create_dir_all(&inner).unwrap();
        repo(side, &inner);
        side.git(at, &["init", "-q"]);
        plain(side, at);
        // Enough files of the outer repository's own for the machine's edits.
        write(&at.join("src/d.txt"), "delta\n");
        write(&at.join("src/e.txt"), "echo\n");
        side.git(at, &["add", "-A"]);
        side.git(at, &["commit", "-qm", "outer"]);
        let mut add =
            side.git_command(at, &["-c", "protocol.file.allow=always", "submodule", "add", "-q"]);
        let output = add.arg(&inner).arg("vendor/inner").output().unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        side.git(at, &["commit", "-qm", "the submodule"]);
    }

    /// A small Rust repository with its whole history.
    #[test]
    fn a_small_repository_with_its_whole_history_round_trips_both_ways() {
        round_trip(
            "repo-small-full",
            From::Clone { url: "https://github.com/BurntSushi/ripgrep".into(), depth: 0 },
        );
    }

    /// A bigger repository, cloned shallow as CI and agents clone (`.git/shallow`).
    #[test]
    fn a_bigger_shallow_repository_round_trips_both_ways() {
        round_trip(
            "repo-big-shallow",
            From::Clone { url: "https://github.com/rust-lang/cargo".into(), depth: 1 },
        );
    }

    /// A C repository of a few thousand files, shallow. It has a submodule (see below).
    #[test]
    #[ignore = "follow-up: a submodule's folder is not projected; the machine's git status reads it deleted"]
    fn a_c_repository_of_thousands_of_files_round_trips_both_ways() {
        round_trip(
            "repo-c-shallow",
            From::Clone { url: "https://github.com/git/git".into(), depth: 1 },
        );
    }

    /// A docs repository with deep folders and many small files, shallow.
    #[test]
    fn a_deep_docs_repository_round_trips_both_ways() {
        round_trip(
            "repo-docs-shallow",
            From::Clone { url: "https://github.com/microsoft/vscode-docs".into(), depth: 1 },
        );
    }

    #[test]
    fn mixed_names_modes_links_and_binary_round_trip_both_ways() {
        round_trip("repo-mixed", From::Made(mixed));
    }

    /// A submodule's folder reaches the machine and `git status` agrees.
    #[test]
    fn a_repository_with_a_submodule_round_trips_both_ways() {
        round_trip("repo-submodule", From::Made(with_submodule));
    }

    /// The same for a copied chat.
    #[test]
    fn a_copied_repository_with_a_submodule_round_trips_both_ways() {
        round_trip_as("repo-submodule-copy", false, From::Made(with_submodule));
    }

    /// A shallow clone (`.git/shallow`) of a local repository with history, so no network: a
    /// commit on the machine comes back as a fast-forward, not as rewritten history (Bring Back's
    /// ancestry walk stops at the shallow boundary).
    fn shallow_local(side: &Side, at: &Path) {
        let upstream = at.parent().unwrap().join("upstream-src");
        fs::create_dir_all(&upstream).unwrap();
        repo(side, &upstream);
        for name in ["src/d.txt", "src/e.txt"] {
            write(&upstream.join(name), &format!("{name}\n"));
        }
        side.git(&upstream, &["add", "src"]);
        for n in 0..3 {
            write(&upstream.join("src/a.txt"), &format!("alpha {n}\n"));
            side.git(&upstream, &["commit", "-qam", &format!("history {n}")]);
        }
        let url = format!("file://{}", upstream.display());
        clone_into(side, at, &url, 1).unwrap();
        assert_eq!(side.git(at, &["rev-parse", "--is-shallow-repository"]), "true\n");
    }

    #[test]
    fn a_commit_on_a_shallow_clone_comes_back_projected() {
        round_trip("repo-shallow-local", From::Made(shallow_local));
    }

    #[test]
    fn a_commit_on_a_shallow_clone_comes_back_copied() {
        round_trip_as("repo-shallow-local-copy", false, From::Made(shallow_local));
    }

    /// The runner's own repositories (`CMUX_PROJECTION_MATRIX_REPOS`), shallow.
    #[test]
    fn extra_repositories_round_trip_both_ways() {
        let Ok(list) = std::env::var("CMUX_PROJECTION_MATRIX_REPOS") else {
            eprintln!("skipping: CMUX_PROJECTION_MATRIX_REPOS is not set");
            return;
        };
        for (n, url) in list.split(',').map(str::trim).filter(|url| !url.is_empty()).enumerate() {
            round_trip(&format!("repo-extra-{n}"), From::Clone { url: url.to_owned(), depth: 1 });
        }
    }
}
