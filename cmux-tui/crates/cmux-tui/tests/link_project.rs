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
use std::os::unix::fs::FileExt as _;
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

/// What crossed the link both ways since the machine started, and its live connections, so a
/// test can count an action's bytes (CMUX-674: "bytes per action ... and a projected folder")
/// and cut the link to make the Mac dial again.
#[derive(Default)]
struct Wire {
    up: std::sync::atomic::AtomicU64,
    down: std::sync::atomic::AtomicU64,
    live: std::sync::Mutex<Vec<UnixStream>>,
}

impl Wire {
    /// Bytes Mac to machine, and machine to Mac.
    fn read(&self) -> (u64, u64) {
        use std::sync::atomic::Ordering::Relaxed;
        (self.up.load(Relaxed), self.down.load(Relaxed))
    }

    /// Cuts every connection, as a dropped network does.
    fn cut(&self) {
        for connection in self.live.lock().unwrap().drain(..) {
            let _ = connection.shutdown(std::net::Shutdown::Both);
        }
    }
}

/// Copies `from` to `to`, each read arriving `RTT`/2 after it left, counted in `count`.
fn delayed(mut from: UnixStream, mut to: UnixStream, wire: std::sync::Arc<Wire>, up: bool) {
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
                    let counter = if up { &wire.up } else { &wire.down };
                    counter.fetch_add(read as u64, std::sync::atomic::Ordering::Relaxed);
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
fn machine(socket: &Path, home: &Path) -> std::sync::Arc<Wire> {
    let listener = UnixListener::bind(socket).unwrap();
    let home = home.to_path_buf();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.clone()]))));
    let wire = std::sync::Arc::new(Wire::default());
    let counted = wire.clone();
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            counted.live.lock().unwrap().push(connection.try_clone().unwrap());
            let (near, far) = UnixStream::pair().unwrap();
            delayed(
                connection.try_clone().unwrap(),
                near.try_clone().unwrap(),
                counted.clone(),
                true,
            );
            delayed(near, connection, counted.clone(), false);
            let home = home.clone();
            std::thread::spawn(move || serve(far, service, &home));
        }
    });
    wire
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
    wire: std::sync::Arc<Wire>,
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
    let wire = machine(&socket, &home);
    World { _root: root, _sockets: sockets, local, home, socket, wire }
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

#[test]
#[ignore = "a bench: CMUX_PROJECT_BENCH_FILES=200000 cargo test --test link_project -- --ignored --nocapture"]
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

/// A 9 MiB file whose every 4 KiB block names itself: three chunks, the last one partial.
fn big_bytes() -> Vec<u8> {
    (0..9 * 1024 * 1024 / 16).flat_map(|n: u32| format!("block {n:09}\n").into_bytes()).collect()
}

/// The suite's own fixtures in the `cmux` repository, committed: a 9 MiB file, a folder to
/// rename, a link inside the folder and one leaving it.
fn suite_fixtures(local: &Path) {
    let repo = local.join("cmux");
    std::fs::write(repo.join("big.bin"), big_bytes()).unwrap();
    write(&repo.join("docs/a.md"), "a\n");
    write(&repo.join("docs/b.md"), "b\n");
    std::os::unix::fs::symlink("README.md", repo.join("readme-link")).unwrap();
    std::os::unix::fs::symlink("/etc/hostname", repo.join("leaves")).unwrap();
    git(&repo, &["add", "big.bin", "docs", "readme-link"]);
    git(&repo, &["commit", "-qm", "suite"]);
}

/// Waits up to `limit` for `check`, so a step that needs the Mac's next dial is not a race.
fn within(limit: Duration, mut check: impl FnMut() -> bool) -> bool {
    let started = Instant::now();
    while started.elapsed() < limit {
        if check() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

/// RFD 0007's hard cases as a person sees them on the machine (CMUX-674 item 5: "a correctness
/// suite (renames, deletes, large files, symlinks, two-sided edits, git status)"), on a projected
/// `~/Projects` through the real start: every step names what the Mac must still hold.
#[test]
fn a_projected_folder_behaves_like_the_folder_on_every_hard_case() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = world(50);
    suite_fixtures(&w.local);
    let state = w.home.parent().unwrap().join("state");
    let start = start_chat(&state, &w.socket, &w.local, &w.home.join("work"), true, &[]);
    if start.could_not_mount() {
        eprintln!("skipping: this host may not mount FUSE: {}", start.stderr);
        return;
    }
    assert_eq!(start.answer["mode"], "projected", "{}", start.answer);
    let (folder, mac) = (start.folder.clone(), w.local.join("cmux"));
    let repo = folder.join("cmux");

    // git status: clean at the start, without reading the tree.
    assert_eq!(git(&repo, &["status", "--short"]), "");

    // A large file: whole, and a read inside its second chunk, byte for byte.
    let big = big_bytes();
    assert_eq!(std::fs::read(repo.join("big.bin")).unwrap(), big);
    let mut part = vec![0u8; 64];
    std::fs::File::open(repo.join("big.bin"))
        .unwrap()
        .read_exact_at(&mut part, 5 * 1024 * 1024 + 7)
        .unwrap();
    assert_eq!(part, big[5 * 1024 * 1024 + 7..][..64]);

    // Symlinks: one inside the folder is a link with its text; one leaving it is not there.
    assert_eq!(std::fs::read_link(repo.join("readme-link")).unwrap(), Path::new("README.md"));
    assert_eq!(std::fs::read_to_string(repo.join("readme-link")).unwrap(), "# cmux\n");
    assert!(std::fs::symlink_metadata(repo.join("leaves")).is_err(), "a link leaving the folder");

    // Rename and delete of Mac files, and a folder rename: done on the machine, the Mac untouched.
    std::fs::rename(repo.join("src/m01.rs"), repo.join("src/renamed.rs")).unwrap();
    assert_eq!(
        std::fs::read_to_string(repo.join("src/renamed.rs")).unwrap(),
        "// cmux\nfn f1() {}\n"
    );
    assert!(!repo.join("src/m01.rs").exists());
    std::fs::remove_file(repo.join("src/m02.rs")).unwrap();
    std::fs::rename(repo.join("docs"), repo.join("notes-moved")).unwrap();
    assert_eq!(std::fs::read_to_string(repo.join("notes-moved/b.md")).unwrap(), "b\n");
    for kept in ["src/m01.rs", "src/m02.rs", "docs/a.md"] {
        assert!(mac.join(kept).exists(), "the Mac lost {kept}");
    }
    let status = git(&repo, &["status", "--short", "--untracked-files=all"]);
    for line in [" D src/m01.rs", " D src/m02.rs", " D docs/a.md", "?? src/renamed.rs"] {
        assert!(status.lines().any(|got| got == line), "missing {line:?} in:\n{status}");
    }

    // Two-sided edits. The machine edits one file; the Mac edits another after the listing (hard
    // case 7) and the machine reads the Mac's new bytes; both edit a third: the machine keeps its
    // own, the Mac keeps its own (bringing it back is a named conflict, not an overwrite).
    std::fs::write(repo.join("src/m03.rs"), "// machine\n").unwrap();
    std::fs::write(mac.join("src/m04.rs"), "// the mac, later and longer\n").unwrap();
    assert_eq!(
        std::fs::read_to_string(repo.join("src/m04.rs")).unwrap(),
        "// the mac, later and longer\n"
    );
    std::fs::write(repo.join("src/m05.rs"), "// machine side\n").unwrap();
    std::fs::write(mac.join("src/m05.rs"), "// mac side\n").unwrap();
    assert_eq!(std::fs::read_to_string(repo.join("src/m05.rs")).unwrap(), "// machine side\n");
    assert_eq!(std::fs::read_to_string(mac.join("src/m03.rs")).unwrap(), "// cmux\nfn f3() {}\n");
    let status = git(&repo, &["status", "--short"]);
    assert!(status.lines().any(|line| line == " M src/m03.rs"), "{status}");

    // A file deleted on the Mac after the listing: a read fails at once, never hangs.
    std::fs::remove_file(mac.join("src/m06.rs")).unwrap();
    let started = Instant::now();
    assert!(std::fs::read(repo.join("src/m06.rs")).is_err());
    assert!(started.elapsed() < Duration::from_secs(10), "took {:?}", started.elapsed());

    // The link drops: what was read stays readable, and the Mac dials again with no manifest.
    w.wire.cut();
    assert_eq!(std::fs::read(repo.join("big.bin")).unwrap().len(), big.len());
    assert!(
        within(Duration::from_secs(30), || std::fs::read_to_string(repo.join("src/m07.rs"))
            .is_ok_and(|text| text == "// cmux\nfn f7() {}\n")),
        "an unread file after the Mac dialed again"
    );
    stop(&state, &folder);
}

/// CMUX-674 item 2, the projected folder: bytes on the link for the start (the manifest), the
/// first turn, the same turn again (all cached), an idle minute's worth, and a dropped link,
/// for folders of 100, 1,000 and 10,000 notes. Prints `PROJECTION-BYTES` lines; asserts that
/// a repeat turn, idle and the re-dial cost no more as the folder grows.
#[test]
fn a_projected_folders_bytes_per_action_stay_flat_where_they_should() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let sizes: Vec<usize> = std::env::var("CMUX_PROJECT_BYTES_SIZES")
        .ok()
        .map(|text| text.split(',').filter_map(|n| n.trim().parse().ok()).collect())
        .unwrap_or_else(|| vec![100, 1_000, 10_000]);
    let mut flat = Vec::new();
    for files in sizes {
        let w = world(files);
        let state = w.home.parent().unwrap().join("state");
        let before = w.wire.read();
        let start = start_chat(&state, &w.socket, &w.local, &w.home.join("work"), true, &[]);
        if start.could_not_mount() {
            eprintln!("skipping: this host may not mount FUSE: {}", start.stderr);
            return;
        }
        assert_eq!(start.answer["mode"], "projected", "{}", start.answer);
        let mut last = w.wire.read();
        let mut row = |case: &str, took: Duration, last: &mut (u64, u64)| {
            let now = w.wire.read();
            let (up, down) = (now.0 - last.0, now.1 - last.1);
            println!(
                "PROJECTION-BYTES {}",
                json!({"case": case, "files": files, "up": up, "down": down,
                       "ms": took.as_millis(), "manifest_bytes": start.answer["projected"]["manifest_bytes"]})
            );
            *last = now;
            up + down
        };
        let _ = row("start", start.took, &mut (before.0, before.1));
        let (took, read, status) = first_turn(&start.folder);
        assert!(status && read == 20, "first turn: {read} reads, git status {status}");
        let first = row("first_turn", took, &mut last);
        let (took, _, _) = first_turn(&start.folder);
        let again = row("repeat_turn", took, &mut last);
        std::thread::sleep(Duration::from_secs(10));
        let idle = row("idle_10s", Duration::from_secs(10), &mut last);
        let started = Instant::now();
        w.wire.cut();
        let back = within(Duration::from_secs(30), || {
            std::fs::read_to_string(start.folder.join("cmux/src/m19.rs")).is_ok()
                && std::fs::read_to_string(start.folder.join("work/api/src/m19.rs")).is_ok()
        });
        assert!(back, "no read after the link dropped");
        let redial = row("redial_and_two_reads", started.elapsed(), &mut last);
        flat.push((files, first, again, idle, redial));
        stop(&state, &start.folder);
    }
    let (Some(small), Some(large)) = (flat.first(), flat.last()) else { return };
    let grows = |a: u64, b: u64| b > a * 3 / 2 + 4096;
    assert!(!grows(small.2, large.2), "a cached repeat turn grows with the folder: {flat:?}");
    assert!(!grows(small.3, large.3), "idle grows with the folder: {flat:?}");
    assert!(!grows(small.4, large.4), "a re-dial grows with the folder: {flat:?}");
}
