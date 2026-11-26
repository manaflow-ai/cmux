//! Cloud start, by folder kind (ask c-63e6b80807; Leo, 2026-11-25: "there's various other
//! situations you guys need to be testing esp with projectionfs and intended read behaviour ...
//! and then like on an empty folder cloud"): the same start (`cmux link start-chat copy`) and the
//! same machine as `link_project.rs` (the real `FsService` and `projection-v1` server behind a link
//! that delays every byte [`RTT`]/2 each way), over four folder kinds: empty, a git repository,
//! a huge one (past the copy's limits, so projected), and one full of symlinks (inside, outside,
//! dangling, a loop). Each prints one row (`folder-kind:` JSON: mode, start ms, first read ms) and
//! asserts what the agent's first reads should see. The huge folder also reads a file the Mac
//! changed after the start: the read is whole (the old bytes or the new, never a torn mix).
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

fn stop(state: &Path, folder: &Path) {
    let _ = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state)
        .args(["link", "project", "stop", "--at"])
        .arg(folder)
        .output();
    let _ = Command::new("fusermount3").args(["-u", "-z"]).arg(folder).status();
}

/// A machine and a Mac folder `local` (made by `make`), in their own temp folders.
struct World {
    _root: tempfile::TempDir,
    _sockets: tempfile::TempDir,
    base: PathBuf,
    local: PathBuf,
    home: PathBuf,
    socket: PathBuf,
}

fn world(make: impl FnOnce(&Path, &Path)) -> World {
    let root = tempfile::tempdir().unwrap();
    let base = std::fs::canonicalize(root.path()).unwrap();
    let local = base.join("Projects");
    std::fs::create_dir_all(&local).unwrap();
    make(&local, &base);
    let home = base.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("fk").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("m.sock");
    machine(&socket, &home);
    World { _root: root, _sockets: sockets, base, local, home, socket }
}

fn repo(at: &Path, name: &str) {
    std::fs::create_dir_all(at).unwrap();
    git(at, &["init", "-q"]);
    for index in 0..20 {
        write(&at.join(format!("src/m{index:02}.rs")), &format!("// {name}\nfn f{index}() {{}}\n"));
    }
    write(&at.join("README.md"), &format!("# {name}\n"));
    git(at, &["add", "."]);
    git(at, &["commit", "-qm", "init"]);
}

/// Starts a chat of `w.local` (projection on, as shipped), reads `first_read` once and prints its row.
fn run(kind: &str, w: &World, first_read: &str) -> Start {
    let state = w.base.join("state");
    let start = start_chat(&state, &w.socket, &w.local, &w.home.join("work"), true, &[]);
    let started = Instant::now();
    let read = std::fs::read(start.folder.join(first_read)).map(|bytes| bytes.len());
    let row = json!({
        "kind": kind,
        "mode": start.answer["mode"],
        "start_ms": start.took.as_millis(),
        "first_read_ms": started.elapsed().as_millis(),
        "first_read": first_read,
        "first_read_ok": read.is_ok(),
        "fuse": fuse_here(),
    });
    println!("folder-kind: {row}");
    start
}

#[test]
fn an_empty_folder_starts_and_the_agent_sees_it_empty() {
    let w = world(|_, _| {});
    let state = w.base.join("state");
    let start = start_chat(&state, &w.socket, &w.local, &w.home.join("work"), true, &[]);
    let entries = std::fs::read_dir(&start.folder).map(Iterator::count);
    println!(
        "folder-kind: {}",
        json!({"kind": "empty", "mode": start.answer["mode"], "start_ms": start.took.as_millis(),
               "entries": entries.as_ref().ok(), "fuse": fuse_here()})
    );
    assert_eq!(entries.unwrap(), 0, "{}", start.answer);
    // A start of nothing is quick: no manifest walk, no bytes.
    assert!(start.took < Duration::from_secs(10), "took {:?}: {}", start.took, start.answer);
    // The agent can write its first file there.
    std::fs::write(start.folder.join("hello.txt"), "hi\n").unwrap();
    if start.answer["mode"] == "projected" {
        stop(&state, &start.folder);
    }
}

#[test]
fn a_git_folder_reads_whole_and_git_status_is_clean() {
    let w = world(|local, _| repo(local, "app"));
    let start = run("git", &w, "src/m07.rs");
    assert_eq!(
        std::fs::read_to_string(start.folder.join("src/m07.rs")).unwrap(),
        "// app\nfn f7() {}\n"
    );
    assert_eq!(git(&start.folder, &["status", "--short"]), "", "{}", start.answer);
    assert!(git(&start.folder, &["log", "--oneline"]).contains("init"));
    if start.answer["mode"] == "projected" {
        stop(&w.base.join("state"), &start.folder);
    }
}

/// Past the copy's limits (thousands of notes and a 21 GiB sparse image): projected, whole at
/// once, its bytes read from the Mac on first use. A file the Mac changes after the start reads
/// whole on the machine: the old bytes or the new, never a mix and never an error.
#[test]
fn a_huge_folder_is_projected_and_a_file_changed_on_the_mac_reads_whole() {
    if !fuse_here() {
        println!("folder-kind: {}", json!({"kind": "huge", "skipped": "no FUSE here"}));
        return;
    }
    let w = world(|local, _| {
        repo(&local.join("cmux"), "cmux");
        for index in 0..2_000 {
            write(
                &local.join(format!("notes/d{:03}/f{index:06}.md", index % 200)),
                &format!("note {index}\n"),
            );
        }
        write(&local.join("word.txt"), "pelican\n");
        let image = local.join("Downloads/disk.img");
        std::fs::create_dir_all(image.parent().unwrap()).unwrap();
        std::fs::File::create(&image).unwrap().set_len(21 * 1024 * 1024 * 1024).unwrap();
    });
    let start = run("huge", &w, "cmux/src/m03.rs");
    if start.could_not_mount() {
        println!("folder-kind: {}", json!({"kind": "huge", "skipped": "may not mount FUSE"}));
        return;
    }
    assert_eq!(start.answer["mode"], "projected", "{}", start.answer);
    assert_eq!(
        std::fs::metadata(start.folder.join("Downloads/disk.img")).unwrap().len(),
        21 * 1024 * 1024 * 1024
    );
    assert_eq!(git(&start.folder.join("cmux"), &["status", "--short"]), "");
    // The Mac changes a file the machine has not read yet, to a longer text.
    write(&w.local.join("word.txt"), "a great blue heron\n");
    let started = Instant::now();
    let seen = std::fs::read(start.folder.join("word.txt"));
    let stat = std::fs::metadata(start.folder.join("word.txt")).map(|m| m.len());
    let row = json!({
        "kind": "huge-mac-changed-after-start",
        "read_ms": started.elapsed().as_millis(),
        "read": seen.as_ref().map(|b| String::from_utf8_lossy(b).into_owned()).map_err(|e| e.to_string()),
        "stat_len": stat.as_ref().ok(),
    });
    println!("folder-kind: {row}");
    let seen = seen.unwrap_or_else(|error| panic!("read failed: {error}: {row}"));
    assert!(seen == b"pelican\n" || seen == b"a great blue heron\n", "a torn read: {row}");
    stop(&w.base.join("state"), &start.folder);
}

/// Symlinks: one to a file inside the folder, one to a folder inside, one to a file outside it,
/// one dangling, and a loop. The start finishes, the inside ones resolve, and the outside file's
/// bytes never cross the link.
#[test]
fn a_folder_of_symlinks_starts_and_nothing_outside_it_crosses() {
    const OUTSIDE: &str = "outside the folder: never on the machine\n";
    let w = world(|local, base| {
        repo(local, "links");
        write(&base.join("secret.txt"), OUTSIDE);
        std::os::unix::fs::symlink("src/m01.rs", local.join("inside-file")).unwrap();
        std::os::unix::fs::symlink("src", local.join("inside-dir")).unwrap();
        std::os::unix::fs::symlink(base.join("secret.txt"), local.join("outside-file")).unwrap();
        std::os::unix::fs::symlink("nowhere/at/all", local.join("dangling")).unwrap();
        std::os::unix::fs::symlink("loop-b", local.join("loop-a")).unwrap();
        std::os::unix::fs::symlink("loop-a", local.join("loop-b")).unwrap();
    });
    let start = run("symlinks", &w, "inside-file");
    let folder = &start.folder;
    let inside = std::fs::read_to_string(folder.join("inside-file"));
    let inside_dir = std::fs::read_dir(folder.join("inside-dir")).map(Iterator::count);
    let outside = std::fs::read_to_string(folder.join("outside-file"));
    let dangling =
        std::fs::symlink_metadata(folder.join("dangling")).map(|m| m.file_type().is_symlink());
    let looped = std::fs::read(folder.join("loop-a")).map_err(|e| e.raw_os_error());
    let row = json!({
        "kind": "symlinks-detail",
        "mode": start.answer["mode"],
        "inside_file": inside.as_ref().ok(),
        "inside_dir_entries": inside_dir.as_ref().ok(),
        "outside_file_reads": outside.as_ref().is_ok(),
        "outside_crossed": crossed(OUTSIDE.as_bytes()),
        "dangling_kept_as_link": dangling.as_ref().ok(),
        "loop_read_errno": looped.as_ref().err(),
    });
    println!("folder-kind: {row}");
    assert_eq!(inside.as_deref().ok(), Some("// links\nfn f1() {}\n"), "{row}");
    assert_eq!(inside_dir.as_ref().ok(), Some(&20), "{row}");
    assert!(!crossed(OUTSIDE.as_bytes()), "a file outside the folder crossed the link: {row}");
    assert!(looped.is_err(), "{row}");
    if start.answer["mode"] == "projected" {
        stop(&w.base.join("state"), folder);
    }
}
