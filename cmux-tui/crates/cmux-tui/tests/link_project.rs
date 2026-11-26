//! A Cloud chat from a folder past what a copy sends whole is projected (RFD 0007): the start sends
//! a stat-only manifest, the machine mounts it at the chat's folder, and the agent's first turn
//! sees the whole folder at once (histories and the big files included), its bytes read from the
//! Mac on first use over the same link.
//!
//! One harness for the before and after: the same folder, the same start (`cmux link start-chat
//! copy`), the same machine (the real `FsService` and the real `projection-v1` server of
//! `cmux_tui_core`), every byte between them crossing a link that delays it [`RTT`]/2 each way,
//! and the same scripted first turn (`ls`, `git status`, 20 reads, a grep of one folder) on the
//! machine's folder. `a_bench_of_the_first_turn` prints both; it is ignored by default
//! (`CMUX_PROJECT_BENCH_FILES` sets the folder's size).
//!
//! Leo, 2026-11-17: "Big folders: projection is the chosen design; build it next".
#![cfg(target_os = "linux")]

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use cmux_tui_core::fs_ops::{self, FsService, Roots, stream};
use serde_json::{Value, json};

/// The link's round trip: about Leo's to a Cloud machine.
const RTT: Duration = Duration::from_millis(50);

/// A start key of this run's own, one per start. The projection is named by it, and its process
/// table and the edits it keeps in the user's state folder outlive a test: two tests (or two runs)
/// with one key attached to each other's mount, and a later run read the last one's upper layer.
fn new_key() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos() as u64);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    format!(
        "{:08x}-0b0a-4908-8706-{:012x}",
        std::process::id(),
        (nanos ^ (n << 40)) & 0xffff_ffff_ffff
    )
}

/// Every byte that crossed a link of this test binary, either way (what the Mac sent and what the
/// machine asked): a secret kept on the Mac must never be in it.
static CROSSED: std::sync::Mutex<Vec<u8>> = std::sync::Mutex::new(Vec::new());

fn crossed(needle: &[u8]) -> bool {
    CROSSED.lock().unwrap().windows(needle.len()).any(|window| window == needle)
}

/// Copies `from` to `to`, each read arriving `RTT`/2 after it left.
fn delayed(mut from: UnixStream, mut to: UnixStream) {
    let (due, arrivals) = std::sync::mpsc::channel::<(Instant, Vec<u8>)>();
    std::thread::spawn(move || {
        for (at, bytes) in arrivals {
            std::thread::sleep(at.saturating_duration_since(Instant::now()));
            if to.write_all(&bytes).is_err() {
                break;
            }
        }
        let _ = to.shutdown(std::net::Shutdown::Write);
    });
    std::thread::spawn(move || {
        let mut buffer = vec![0u8; 256 * 1024];
        loop {
            match from.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(read) => {
                    CROSSED.lock().unwrap().extend_from_slice(&buffer[..read]);
                    if due.send((Instant::now() + RTT / 2, buffer[..read].to_vec())).is_err() {
                        return;
                    }
                }
            }
        }
    });
}

/// A Cloud machine on `socket` over `home`: every connection crosses the delayed link; a dial
/// whose first line is `projection.serve` is served by the daemon's projection, any other by its
/// `fs-v1` lines.
fn machine(socket: &Path, home: &Path) {
    let listener = UnixListener::bind(socket).unwrap();
    let home = home.to_path_buf();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.clone()]))));
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            let (near, far) = UnixStream::pair().unwrap();
            delayed(connection.try_clone().unwrap(), near.try_clone().unwrap());
            delayed(near, connection);
            let home = home.clone();
            std::thread::spawn(move || serve(far, service, &home));
        }
    });
}

fn serve(connection: UnixStream, service: &FsService, home: &Path) {
    let mut writer = connection.try_clone().unwrap();
    let mut reader = BufReader::new(connection.try_clone().unwrap());
    let mut first = true;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        if first && cmux_tui_core::projection::frame_command(&line).is_some() {
            let leftover = reader.buffer().to_vec();
            cmux_tui_core::projection::serve(
                &connection,
                line.trim_end(),
                leftover,
                &[home.to_path_buf()],
            );
            return;
        }
        first = false;
        let request: Value = serde_json::from_str(&line).unwrap();
        let id = request["id"].clone();
        let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
        let reply = if cmd == "identify" {
            json!({"id": id, "ok": true, "data": {"capabilities": [
                fs_ops::FS_CAPABILITY, fs_ops::FS_SYMLINK_CAPABILITY,
                fs_ops::FS_WRITE_DEFLATE_CAPABILITY, fs_ops::FS_WRITE_NOFOLLOW_CAPABILITY,
                cmux_tui_core::projection::PROJECTION_CAPABILITY,
            ]}})
        } else {
            stream::answer(&id, service.call("local", &cmd, request))
        };
        let mut text = reply.to_string();
        text.push('\n');
        if writer.write_all(text.as_bytes()).is_err() {
            return;
        }
    }
}

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && Command::new("fusermount3").arg("-V").output().is_ok_and(|out| out.status.success())
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(["-c", "core.checkStat=minimal", "-c", "core.trustctime=false"])
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// `~/Projects`' shape: repositories, `files` small notes, and a sparse 21 GiB disk image (no
/// disk spent) that puts it past 20 GB.
fn projects(at: &Path, files: usize) {
    for name in ["FEX", "cmux", "work/api"] {
        let repo = at.join(name);
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q"]);
        for index in 0..20 {
            write(
                &repo.join(format!("src/m{index:02}.rs")),
                &format!("// {name}\nfn f{index}() {{}}\n"),
            );
        }
        write(&repo.join("README.md"), &format!("# {name}\n"));
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-qm", "init"]);
    }
    write(&at.join("cmux-matrix-word.txt"), "pelican\n");
    for index in 0..files {
        write(
            &at.join(format!("notes/d{:03}/f{index:06}.md", index % 200)),
            &format!("note {index}\n"),
        );
    }
    let image = at.join("Downloads/disk.img");
    std::fs::create_dir_all(image.parent().unwrap()).unwrap();
    std::fs::File::create(&image).unwrap().set_len(21 * 1024 * 1024 * 1024).unwrap();
}

struct Start {
    key: String,
    took: Duration,
    answer: Value,
    folder: PathBuf,
    stderr: String,
}

impl Start {
    /// FUSE is here but this host may not mount (a container without the right): the start
    /// copied for that reason alone.
    fn could_not_mount(&self) -> bool {
        self.answer["mode"] != "projected" && self.stderr.contains("mount failed")
    }
}

/// `cmux link start-chat copy` of `local`, projection on or off, with `extra` flags.
fn start_chat(
    state: &Path,
    socket: &Path,
    local: &Path,
    work: &Path,
    projected: bool,
    extra: &[&str],
) -> Start {
    let key = new_key();
    let started = Instant::now();
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state)
        .env("CMUX_PROJECTED_FOLDERS", if projected { "1" } else { "0" })
        .env_remove("CMUX_SYNC_COPY_RATE")
        .args([
            "link",
            "start-chat",
            "copy",
            "--key",
            &key,
            "--account",
            "leo",
            "--machine",
            "vm-a",
        ])
        .arg("--socket")
        .arg(socket)
        .arg("--local")
        .arg(local)
        .arg("--work-root")
        .arg(work)
        .args(extra)
        .output()
        .unwrap();
    let took = started.elapsed();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let answer = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line).ok())
        .unwrap_or(Value::Null);
    assert_eq!(
        answer["ok"],
        true,
        "start-chat copy: {stdout}{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let folder = PathBuf::from(answer["folder"].as_str().unwrap());
    Start { key, took, answer, folder, stderr }
}

/// The scripted first turn (RFD 0007's bench): `ls` of the folder and a repository, `git status`
/// in it, 20 reads, and a grep of one folder. How long it took, and how many of the 20 reads found
/// their file.
fn first_turn(folder: &Path) -> (Duration, usize, bool) {
    let started = Instant::now();
    let _ = std::fs::read_dir(folder).map(Iterator::count);
    let repo = folder.join("cmux");
    let _ = std::fs::read_dir(&repo).map(Iterator::count);
    let status = Command::new("git")
        .arg("-C")
        .arg(&repo)
        .args(["-c", "core.checkStat=minimal", "-c", "core.trustctime=false", "status", "--short"])
        .output()
        .is_ok_and(|output| output.status.success());
    let read = (0..20)
        .filter(|index| std::fs::read(repo.join(format!("src/m{index:02}.rs"))).is_ok())
        .count();
    let _ = Command::new("grep").args(["-rq", "note 7"]).arg(folder.join("notes/d007")).status();
    (started.elapsed(), read, status)
}

fn stop(state: &Path, folder: &Path) {
    let _ = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state)
        .args(["link", "project", "stop", "--at"])
        .arg(folder)
        .output();
    let _ = Command::new("fusermount3").args(["-u", "-z"]).arg(folder).status();
}

struct World {
    _root: tempfile::TempDir,
    _sockets: tempfile::TempDir,
    local: PathBuf,
    home: PathBuf,
    socket: PathBuf,
}

fn world(files: usize) -> World {
    let root = tempfile::tempdir().unwrap();
    let base = std::fs::canonicalize(root.path()).unwrap();
    let local = base.join("Projects");
    projects(&local, files);
    let home = base.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("pj").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("m.sock");
    machine(&socket, &home);
    World { _root: root, _sockets: sockets, local, home, socket }
}

#[test]
fn a_folder_past_the_limits_is_projected_whole_and_reads_come_from_the_mac() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = world(500);
    let state = w.home.parent().unwrap().join("state");
    let start = start_chat(&state, &w.socket, &w.local, &w.home.join("work"), true, &[]);
    let folder = &start.folder;
    if start.could_not_mount() {
        eprintln!("skipping: this host may not mount FUSE: {}", start.stderr);
        return;
    }
    assert_eq!(start.answer["mode"], "projected", "{}", start.answer);
    // One projection per chat, named by its start key: Bring Back finds the chat's edits by it.
    assert_eq!(
        start.answer["projected"]["name"],
        format!("chat-{}", start.key),
        "{}",
        start.answer
    );

    // The whole folder, at once: the 21 GiB image (by its size, no byte of it moved), every
    // repository with its history, every note.
    let image = std::fs::metadata(folder.join("Downloads/disk.img")).unwrap();
    assert_eq!(image.len(), 21 * 1024 * 1024 * 1024);
    assert_eq!(std::fs::read_to_string(folder.join("cmux-matrix-word.txt")).unwrap(), "pelican\n");
    assert_eq!(std::fs::read_dir(folder.join("notes")).unwrap().count(), 200);
    let log = git(&folder.join("work/api"), &["log", "--oneline"]);
    assert!(log.contains("init"), "{log}");
    assert_eq!(git(&folder.join("cmux"), &["status", "--short"]), "");
    // Written on the machine stays on the machine: the Mac's folder is untouched.
    std::fs::write(folder.join("cmux/src/m00.rs"), "// edited on the machine\n").unwrap();
    assert_eq!(
        std::fs::read_to_string(folder.join("cmux/src/m00.rs")).unwrap(),
        "// edited on the machine\n"
    );
    assert_eq!(
        std::fs::read_to_string(w.local.join("cmux/src/m00.rs")).unwrap(),
        "// cmux\nfn f0() {}\n"
    );
    // A start in seconds, where the first pass copied hundreds of files at a round trip each.
    assert!(start.took < Duration::from_secs(10), "took {:?}: {}", start.took, start.answer);
    stop(&state, folder);
}

/// RFD 0007, "Tracked files the skip rules keep home": "the manifest lists such a tracked path
/// with its real stat and no bytes; opening it fails with `EACCES` and a named reason, so `git
/// status` is clean and the boundary holds". A key a repository below `~/Projects` commits stats
/// on the machine as on the Mac, its open is refused, `git status` there is clean, and no byte of
/// it crossed the link. Leo, 2026-11-22: "THE WHOLE POINT OF PROJECTIONFS IS FOR AGENTS TO BE
/// ABLE TO DO THIS".
#[test]
fn a_tracked_secret_kept_on_the_mac_is_listed_refused_and_git_status_is_clean() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = world(20);
    const KEY: &str = "-----BEGIN PRIVATE KEY----- a test key that stays on the Mac\n";
    write(&w.local.join("cmux/test/fixtures/server.key"), KEY);
    // Committed long ago, as a repository's test keys are: a key written in the index's own
    // second is racily clean, and git would read its bytes to check it.
    let old = Command::new("touch")
        .args(["-d", "2026-01-01 00:00:00"])
        .arg(w.local.join("cmux/test/fixtures/server.key"))
        .status()
        .unwrap();
    assert!(old.success());
    git(&w.local.join("cmux"), &["add", "-f", "test/fixtures/server.key"]);
    git(&w.local.join("cmux"), &["commit", "-qm", "a test key"]);
    let state = w.home.parent().unwrap().join("state");
    let start = start_chat(&state, &w.socket, &w.local, &w.home.join("work"), true, &[]);
    let folder = &start.folder;
    if start.could_not_mount() {
        eprintln!("skipping: this host may not mount FUSE: {}", start.stderr);
        return;
    }
    assert_eq!(start.answer["mode"], "projected", "{}", start.answer);

    let mac = std::fs::metadata(w.local.join("cmux/test/fixtures/server.key")).unwrap();
    let here = std::fs::metadata(folder.join("cmux/test/fixtures/server.key")).unwrap();
    assert!(here.is_file());
    assert_eq!(here.len(), mac.len());
    assert_eq!(here.modified().unwrap(), mac.modified().unwrap());
    let error = std::fs::File::open(folder.join("cmux/test/fixtures/server.key")).unwrap_err();
    // EACCES (Linux's 13).
    assert_eq!(error.raw_os_error(), Some(13), "{error}");
    let status = git(&folder.join("cmux"), &["status", "--short"]);
    assert_eq!(status, "", "git status on the machine: {status}");
    // Every other file still reads, from the Mac.
    assert_eq!(std::fs::read_to_string(folder.join("cmux/README.md")).unwrap(), "# cmux\n");
    assert!(!crossed(KEY.as_bytes()), "the key's bytes crossed the link");
    stop(&state, folder);
}

/// The App's first copy asks (`--on-seed-refusal ask`) and ends a start whose folder its
/// machine's disk cannot hold, so that copy has to project too, before any seed or copy.
#[test]
fn the_apps_asking_copy_projects_too() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = world(50);
    let state = w.home.parent().unwrap().join("state");
    let work = w.home.join("work");
    let start = start_chat(&state, &w.socket, &w.local, &work, true, &["--on-seed-refusal", "ask"]);
    if start.could_not_mount() {
        eprintln!("skipping: this host may not mount FUSE: {}", start.stderr);
        return;
    }
    assert_eq!(start.answer["mode"], "projected", "{}", start.answer);
    let image = std::fs::metadata(start.folder.join("Downloads/disk.img")).unwrap();
    assert_eq!(image.len(), 21 * 1024 * 1024 * 1024);
    stop(&state, &start.folder);
}

/// `cmux link seed push` (with `since_last`, `--since-last`) of `local` to `remote`: its answer
/// line and its stderr.
fn seed_push(
    state: &Path,
    socket: &Path,
    local: &Path,
    remote: &Path,
    since_last: bool,
) -> (Value, String) {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_STATE_DIR", state)
        .env("CMUX_PROJECTED_FOLDERS", "1")
        .env("CMUX_PROJECTED_MOVES", "1")
        .args(["link", "seed", "push", "--socket"])
        .arg(socket)
        .arg(local)
        .arg(remote);
    if since_last {
        command.arg("--since-last");
    }
    let output = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let answer = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line).ok())
        .unwrap_or(Value::Null);
    (answer, String::from_utf8_lossy(&output.stderr).into_owned())
}

/// Move to Cloud (Leo, 2026-11-21: "improve the cmux moving/teleporting then. we have projection
/// fs"): its push projects the chat's folder as a new Cloud chat's does, whole and at once, and
/// the push once the chat is frozen (`--since-last`) projects it again, so what the chat changed
/// here up to the freeze (an edit, a new file) is what the machine reads.
#[test]
fn a_moved_chats_folder_is_projected_and_projected_again_once_frozen() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = world(20);
    let state = w.home.parent().unwrap().join("state");
    let remote = w.home.join("work/Projects");
    let (answer, stderr) = seed_push(&state, &w.socket, &w.local, &remote, false);
    if answer["mode"] != "projected" && stderr.contains("mount failed") {
        eprintln!("skipping: this host may not mount FUSE: {stderr}");
        return;
    }
    assert_eq!(answer["ok"], true, "{answer} {stderr}");
    assert_eq!(answer["mode"], "projected", "{answer} {stderr}");
    let image = std::fs::metadata(remote.join("Downloads/disk.img")).unwrap();
    assert_eq!(image.len(), 21 * 1024 * 1024 * 1024);
    assert_eq!(std::fs::read_to_string(remote.join("cmux-matrix-word.txt")).unwrap(), "pelican\n");

    // The chat goes on here until the move freezes it: it edits a file and makes one.
    write(&w.local.join("cmux-matrix-word.txt"), "a great blue heron\n");
    write(&w.local.join("cmux/src/new.rs"), "fn new() {}\n");
    let (again, stderr) = seed_push(&state, &w.socket, &w.local, &remote, true);
    assert_eq!(again["ok"], true, "{again} {stderr}");
    assert_eq!(again["mode"], "projected", "{again} {stderr}");
    assert_eq!(
        std::fs::read_to_string(remote.join("cmux-matrix-word.txt")).unwrap(),
        "a great blue heron\n"
    );
    assert_eq!(std::fs::read_to_string(remote.join("cmux/src/new.rs")).unwrap(), "fn new() {}\n");
    assert_eq!(git(&remote.join("cmux"), &["log", "--oneline"]).lines().count(), 1);
    stop(&state, &remote);
}

#[test]
#[ignore = "a bench: CMUX_PROJECT_BENCH_FILES=200000 cargo test --test it -- link_project:: --ignored --nocapture"]
fn a_bench_of_the_first_turn() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let files = std::env::var("CMUX_PROJECT_BENCH_FILES")
        .ok()
        .and_then(|n| n.parse().ok())
        .unwrap_or(20_000);
    let w = world(files);
    let mut rows = Vec::new();
    for projected in [false, true] {
        let state = w.home.parent().unwrap().join(if projected { "state-p" } else { "state-c" });
        let start = start_chat(&state, &w.socket, &w.local, &w.home.join("work"), projected, &[]);
        let (turn, read, status) = first_turn(&start.folder);
        let row = json!({
            "path": if projected { "projected" } else { "first pass (today)" },
            "start_ms": start.took.as_millis(),
            "first_turn_ms": turn.as_millis(),
            "to_first_turn_done_ms": (start.took + turn).as_millis(),
            "reads_found": read,
            "git_status_ok": status,
            "mode": start.answer["mode"],
        });
        println!("{row}");
        rows.push(row);
        if projected {
            stop(&state, &start.folder);
        }
    }
    println!(
        "| path | start | first turn | total | reads found of 20 | git status |\n|---|---|---|---|---|---|"
    );
    for row in rows {
        println!(
            "| {} | {} ms | {} ms | {} ms | {} | {} |",
            row["path"].as_str().unwrap(),
            row["start_ms"],
            row["first_turn_ms"],
            row["to_first_turn_done_ms"],
            row["reads_found"],
            row["git_status_ok"]
        );
    }
    println!(
        "folder: {files} notes + 3 repositories + a 21 GiB sparse image; link {} ms RTT",
        RTT.as_millis()
    );
}
