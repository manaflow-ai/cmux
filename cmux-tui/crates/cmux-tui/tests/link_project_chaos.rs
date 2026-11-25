//! Two-device chaos for projected folders (Leo, c-8bfc406eb8, paraphrased: think of Dropbox, Google
//! Drive, iCloud and OneDrive, and how to be better than them, and keep going).
//! What a consumer drive is judged on: it never loses your stuff, and says clearly what is synced.
//!
//! The two ends are real: this Mac's folder is a slice of a real cmux checkout (this repository's
//! own `cmux-tui/crates/cmux-projection` and `link/` sources at HEAD, or any checkout named by
//! `CMUX_CHAOS_WORKSPACE`), projected by the real `cmux link start-chat copy` onto a machine that is
//! `cmux_tui_core`'s real `FsService` and `projection-v1` server (FUSE) behind a link that delays
//! every byte and that the test can cut ([`Switch`]): every open stream is shut down at once and
//! new dials are refused until it is resumed. Bring Back is the real `cmux link seed pull
//! --or-copy`.
//!
//! Each scenario writes on both sides, cuts and resumes the link, brings back until it succeeds,
//! then diffs this Mac's tree against what each side wrote ([`Tally`]):
//!
//! - **lost bytes**: the last version a side wrote of a path that is neither the file nor a
//!   conflict copy beside it;
//! - **silent overwrites**: a path both sides wrote where one side's version is gone and no
//!   conflict copy holds it;
//! - **torn files**: a file that is none of the base, this Mac's or the machine's version (half a
//!   write applied);
//! - **conflict copies**: `*.cmux-sync-conflict*` files made.
//!
//! Each scenario prints one `CHAOS {json}` row and fails on any lost byte, silent overwrite or torn
//! file (`CMUX_CHAOS_REPORT_ONLY=1` prints the rows without failing, for the table).
//!
//! ```text
//! cargo test -p cmux-tui --test link_project_chaos -- --nocapture --test-threads 1
//! ```
#![cfg(target_os = "linux")]

use std::collections::BTreeMap;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_tui_core::fs_ops::{self, FsService, Roots, stream};
use serde_json::{Value, json};

/// The link's round trip.
const RTT: Duration = Duration::from_millis(10);
/// The conflict copy's suffix Bring Back writes beside this Mac's file.
const CONFLICT: &str = ".cmux-sync-conflict";

/// The link: every stream it carries, and whether it is cut.
#[derive(Default)]
struct Switch {
    cut: AtomicBool,
    live: Mutex<Vec<UnixStream>>,
}

impl Switch {
    /// Kills the network: every open stream is shut down both ways, and new dials are dropped.
    fn cut(&self) {
        self.cut.store(true, Ordering::SeqCst);
        let live = std::mem::take(&mut *self.live.lock().unwrap());
        for stream in live {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }

    fn resume(&self) {
        self.cut.store(false, Ordering::SeqCst);
    }

    fn keep(&self, stream: &UnixStream) {
        if let Ok(copy) = stream.try_clone() {
            self.live.lock().unwrap().push(copy);
        }
    }
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
                    let Some(bytes) = buffer.get(..read) else { return };
                    if due.send((Instant::now() + RTT / 2, bytes.to_vec())).is_err() {
                        return;
                    }
                }
            }
        }
    });
}

/// A Cloud machine on `socket` over `home`, behind `switch`.
fn machine(socket: &Path, home: &Path, switch: Arc<Switch>) {
    let listener = UnixListener::bind(socket).unwrap();
    let home = home.to_path_buf();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.clone()]))));
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            if switch.cut.load(Ordering::SeqCst) {
                let _ = connection.shutdown(std::net::Shutdown::Both);
                continue;
            }
            let (near, far) = UnixStream::pair().unwrap();
            switch.keep(&connection);
            switch.keep(&near);
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
        let Ok(request) = serde_json::from_str::<Value>(&line) else { return };
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

fn write(path: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
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

/// The real workspace this Mac's folder starts as: `cmux/` holds this repository's projection and
/// link sources at HEAD (or a clone of `CMUX_CHAOS_WORKSPACE`), committed, plus `notes/`, which no
/// git owns (so a both-sides edit there is a plain file conflict, not a three-way merge).
fn workspace(at: &Path) {
    let repo = at.join("cmux");
    if let Ok(source) = std::env::var("CMUX_CHAOS_WORKSPACE") {
        let cloned = Command::new("git")
            .args(["clone", "-q", "--local", "--no-hardlinks"])
            .arg(&source)
            .arg(&repo)
            .status()
            .unwrap();
        assert!(cloned.success(), "cloning {source}");
    } else {
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "main"]);
        let here = env!("CARGO_MANIFEST_DIR");
        let top = git(Path::new(here), &["rev-parse", "--show-toplevel"]);
        let archive = Command::new("git")
            .arg("-C")
            .arg(top.trim())
            .args(["archive", "HEAD", "cmux-tui/crates/cmux-projection"])
            .arg("cmux-tui/crates/cmux-tui/src/link")
            .output()
            .unwrap();
        assert!(archive.status.success(), "git archive");
        let mut tar = Command::new("tar")
            .arg("-x")
            .arg("-C")
            .arg(&repo)
            .stdin(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        tar.stdin.take().unwrap().write_all(&archive.stdout).unwrap();
        assert!(tar.wait().unwrap().success());
        write(&repo.join(".gitignore"), b"target/\n");
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-qm", "workspace"]);
    }
    for index in 0..50 {
        write(&at.join(format!("notes/n{index:03}.md")), format!("note {index}\n").as_bytes());
    }
    // A sparse 21 GiB disk image (no disk spent) puts the folder past the copy's limits, so a start
    // projects it.
    let image = at.join("Downloads/disk.img");
    std::fs::create_dir_all(image.parent().unwrap()).unwrap();
    std::fs::File::create(&image).unwrap().set_len(21 * 1024 * 1024 * 1024).unwrap();
}

fn last_json(text: &str) -> Value {
    text.lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line).ok())
        .unwrap_or(Value::Null)
}

/// The machine's projection state folder for projection `name`.
fn projection_state(name: &str) -> PathBuf {
    cmux_tui_core::platform::workspace_state_dir().unwrap().join("projections").join(name)
}

struct World {
    _root: tempfile::TempDir,
    _sockets: tempfile::TempDir,
    state: PathBuf,
    local: PathBuf,
    remote: PathBuf,
    socket: PathBuf,
    switch: Arc<Switch>,
}

impl World {
    /// A projected start of a fresh workspace, chat `key`.
    fn new(key: &str) -> Self {
        let root = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(root.path()).unwrap();
        let local = base.join("Folder");
        workspace(&local);
        let home = base.join("home");
        std::fs::create_dir_all(home.join("work")).unwrap();
        let sockets = tempfile::Builder::new().prefix("chaos").tempdir_in("/tmp").unwrap();
        let socket = sockets.path().join("m.sock");
        let switch = Arc::new(Switch::default());
        machine(&socket, &home, Arc::clone(&switch));
        let state = base.join("state");
        let _ = std::fs::remove_dir_all(projection_state(&format!("chat-{key}")));
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .env("CMUX_TUI_STATE_DIR", &state)
            .env("CMUX_PROJECTED_FOLDERS", "1")
            .env_remove("CMUX_SYNC_COPY_RATE")
            .args(["link", "start-chat", "copy", "--key", key, "--account", "leo"])
            .args(["--machine", "vm-a", "--socket"])
            .arg(&socket)
            .arg("--local")
            .arg(&local)
            .arg("--work-root")
            .arg(home.join("work"))
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let answer = last_json(&stdout);
        assert_eq!(
            answer["mode"],
            "projected",
            "start-chat: {stdout}{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let remote = PathBuf::from(answer["folder"].as_str().unwrap());
        World { _root: root, _sockets: sockets, state, local, remote, socket, switch }
    }

    /// One Bring Back: its answer.
    fn bring_back(&self) -> Value {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .env("CMUX_TUI_STATE_DIR", &self.state)
            .args(["link", "seed", "pull", "--or-copy", "--socket"])
            .arg(&self.socket)
            .arg(&self.local)
            .arg(&self.remote)
            .output()
            .unwrap();
        let answer = last_json(&String::from_utf8_lossy(&output.stdout));
        if answer.is_null() {
            json!({"ok": false, "error": String::from_utf8_lossy(&output.stderr).trim().to_owned()})
        } else {
            answer
        }
    }

    /// Bring Back until it applies (at most `tries`): how many tries it took and the last answer.
    fn bring_back_until_ok(&self, tries: usize) -> (usize, Value) {
        let mut last = Value::Null;
        for attempt in 1..=tries {
            last = self.bring_back();
            if last["ok"] == true {
                return (attempt, last);
            }
            std::thread::sleep(Duration::from_millis(300));
        }
        (tries, last)
    }
}

impl Drop for World {
    fn drop(&mut self) {
        self.switch.resume();
        let _ = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .env("CMUX_TUI_STATE_DIR", &self.state)
            .args(["link", "project", "stop", "--at"])
            .arg(&self.remote)
            .output();
        let _ = Command::new("fusermount3").args(["-u", "-z"]).arg(&self.remote).status();
    }
}

/// What each side last wrote to one path (`None`: that side did not write it).
#[derive(Default)]
struct Touch {
    base: Option<Vec<u8>>,
    mac: Option<Vec<u8>>,
    machine: Option<Vec<u8>>,
}

/// One scenario's diff of this Mac's tree after the last Bring Back.
#[derive(Default, Debug)]
struct Tally {
    lost_bytes: u64,
    silent_overwrites: usize,
    torn: usize,
    conflict_copies: usize,
    paths: Vec<String>,
}

/// The conflict copies beside `path` (`NAME.cmux-sync-conflict`, and any numbered one).
fn conflict_copies(folder: &Path, path: &str) -> Vec<Vec<u8>> {
    let file = folder.join(path);
    let (Some(dir), Some(name)) = (file.parent(), file.file_name()) else { return Vec::new() };
    let stem = format!("{}{CONFLICT}", name.to_string_lossy());
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_string_lossy().starts_with(&stem))
        .filter_map(|entry| std::fs::read(entry.path()).ok())
        .collect()
}

fn count_conflicts(folder: &Path) -> usize {
    let mut count = 0;
    let mut stack = vec![folder.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.filter_map(Result::ok) {
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                stack.push(entry.path());
            } else if entry.file_name().to_string_lossy().contains(CONFLICT) {
                count += 1;
            }
        }
    }
    count
}

fn tally(folder: &Path, touched: &BTreeMap<String, Touch>) -> Tally {
    let mut out = Tally { conflict_copies: count_conflicts(folder), ..Tally::default() };
    for (path, touch) in touched {
        let now = std::fs::read(folder.join(path)).ok();
        let copies = conflict_copies(folder, path);
        let kept = |version: &Vec<u8>| now.as_ref() == Some(version) || copies.contains(version);
        let mut lost_here = false;
        for version in [&touch.mac, &touch.machine].into_iter().flatten() {
            if !kept(version) {
                out.lost_bytes += version.len() as u64;
                lost_here = true;
            }
        }
        if touch.mac.is_some() && touch.machine.is_some() && lost_here {
            out.silent_overwrites += 1;
        }
        let known = [&touch.base, &touch.mac, &touch.machine];
        if let Some(bytes) = &now
            && !known.iter().any(|version| version.as_ref() == Some(bytes))
        {
            out.torn += 1;
        }
        if lost_here || now.is_none() {
            out.paths.push(path.clone());
        }
    }
    out
}

fn report(scenario: &str, tally: &Tally, tries: usize, answer: &Value) {
    let row = json!({
        "scenario": scenario,
        "lost_bytes": tally.lost_bytes,
        "silent_overwrites": tally.silent_overwrites,
        "torn": tally.torn,
        "conflict_copies": tally.conflict_copies,
        "bring_back_tries": tries,
        "ok": answer["ok"],
        "error_code": answer["error_code"],
        "paths": tally.paths,
    });
    println!("CHAOS {row}");
    if std::env::var("CMUX_CHAOS_REPORT_ONLY").is_ok_and(|value| value == "1") {
        return;
    }
    assert_eq!(answer["ok"], true, "{scenario}: Bring Back never applied: {answer}");
    assert_eq!(tally.lost_bytes, 0, "{scenario}: {row}");
    assert_eq!(tally.silent_overwrites, 0, "{scenario}: {row}");
    assert_eq!(tally.torn, 0, "{scenario}: {row}");
}

/// `len` bytes no two versions share.
fn payload(tag: &str, len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(len);
    let mut n = 0u64;
    while out.len() < len {
        out.extend_from_slice(format!("{tag} {n:012}\n").as_bytes());
        n += 1;
    }
    out.truncate(len);
    out
}

/// The network dies while Bring Back carries a 48 MiB file the agent wrote; the link comes back and
/// Bring Back runs again. Nothing may be half applied here, and nothing may be lost.
#[test]
fn chaos_cut_mid_bring_back() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = World::new("c4a05001-0b0a-4908-8706-050403020100");
    let mut touched = BTreeMap::new();
    let big = payload("machine big", 48 * 1024 * 1024);
    write(&w.remote.join("cmux/out/big.bin"), &big);
    touched.insert("cmux/out/big.bin".to_owned(), Touch { machine: Some(big), ..Touch::default() });
    for index in 0..20 {
        let path = format!("notes/n{index:03}.md");
        let bytes = payload(&format!("machine {index}"), 4096);
        write(&w.remote.join(&path), &bytes);
        touched.insert(
            path,
            Touch {
                base: Some(format!("note {index}\n").into_bytes()),
                machine: Some(bytes),
                ..Touch::default()
            },
        );
    }
    let switch = Arc::clone(&w.switch);
    let cutter = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(400));
        switch.cut();
        std::thread::sleep(Duration::from_secs(2));
        switch.resume();
    });
    let first = w.bring_back();
    cutter.join().unwrap();
    // Between the cut and the retry: a half applied Bring Back shows here.
    let between = tally(&w.local, &touched);
    let (tries, answer) = w.bring_back_until_ok(5);
    let mut out = tally(&w.local, &touched);
    out.torn += between.torn;
    println!("CHAOS-FIRST {}", json!({"ok": first["ok"], "error": first["error_code"]}));
    report("cut mid Bring Back, resume", &out, tries, &answer);
}

/// Both sides write the same files at the same moment, then Bring Back: this Mac's version stays,
/// the machine's lands beside it, and nothing is overwritten.
#[test]
fn chaos_same_file_both_sides_at_once() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = World::new("c4a05002-0b0a-4908-8706-050403020101");
    let paths =
        ["notes/n001.md", "notes/n002.md", "cmux/cmux-tui/crates/cmux-projection/src/lib.rs"];
    let base: Vec<Option<Vec<u8>>> =
        paths.iter().map(|path| std::fs::read(w.local.join(path)).ok()).collect();
    let (mac_root, machine_root) = (w.local.clone(), w.remote.clone());
    let mac = std::thread::spawn(move || {
        let mut last = Vec::new();
        for round in 0..20 {
            for path in paths {
                let bytes = payload(&format!("mac {round}"), 8192);
                write(&mac_root.join(path), &bytes);
                last = bytes;
            }
        }
        last
    });
    let machine = std::thread::spawn(move || {
        let mut last = Vec::new();
        for round in 0..20 {
            for path in paths {
                let bytes = payload(&format!("machine {round}"), 8192);
                write(&machine_root.join(path), &bytes);
                last = bytes;
            }
        }
        last
    });
    let (mac_last, machine_last) = (mac.join().unwrap(), machine.join().unwrap());
    let mut touched = BTreeMap::new();
    for (path, base) in paths.iter().zip(base) {
        touched.insert(
            (*path).to_owned(),
            Touch { base, mac: Some(mac_last.clone()), machine: Some(machine_last.clone()) },
        );
    }
    let (tries, answer) = w.bring_back_until_ok(3);
    report("same file both sides at once", &tally(&w.local, &touched), tries, &answer);
}

/// This Mac keeps writing a file while Bring Back runs, and the machine wrote it too: whichever
/// way the race falls, neither side's version may vanish.
#[test]
fn chaos_mac_writes_during_bring_back() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = World::new("c4a05003-0b0a-4908-8706-050403020102");
    let path = "notes/n010.md";
    let machine_bytes = payload("machine during", 16 * 1024);
    write(&w.remote.join(path), &machine_bytes);
    // Many machine files so the plan-to-place window is long enough to race.
    for index in 20..50 {
        write(
            &w.remote.join(format!("notes/n{index:03}.md")),
            &payload(&format!("m{index}"), 64 * 1024),
        );
    }
    let stop = Arc::new(AtomicBool::new(false));
    let (flag, root) = (Arc::clone(&stop), w.local.clone());
    let mac = std::thread::spawn(move || {
        let mut last = Vec::new();
        let mut round = 0;
        while !flag.load(Ordering::SeqCst) {
            let bytes = payload(&format!("mac during {round}"), 16 * 1024);
            write(&root.join(path), &bytes);
            last = bytes;
            round += 1;
            std::thread::sleep(Duration::from_millis(2));
        }
        last
    });
    std::thread::sleep(Duration::from_millis(50));
    let first = w.bring_back();
    stop.store(true, Ordering::SeqCst);
    let mac_last = mac.join().unwrap();
    let (tries, answer) = if first["ok"] == true {
        (1, first)
    } else {
        let (t, a) = w.bring_back_until_ok(3);
        (t + 1, a)
    };
    let mut touched = BTreeMap::new();
    touched.insert(
        path.to_owned(),
        Touch {
            base: Some(b"note 10\n".to_vec()),
            mac: Some(mac_last),
            machine: Some(machine_bytes),
        },
    );
    report("Mac writes during Bring Back", &tally(&w.local, &touched), tries, &answer);
}

/// The network dies while the machine reads files it has not fetched yet, and while it writes; the
/// link comes back. Every byte the machine read must be this Mac's, and every write must come back.
#[test]
fn chaos_cut_mid_lazy_read_and_write() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = World::new("c4a05004-0b0a-4908-8706-050403020103");
    let sources: Vec<String> = git(&w.local.join("cmux"), &["ls-files"])
        .lines()
        .filter(|line| line.ends_with(".rs"))
        .take(60)
        .map(|line| format!("cmux/{line}"))
        .collect();
    let switch = Arc::clone(&w.switch);
    let cutter = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        switch.cut();
        std::thread::sleep(Duration::from_secs(3));
        switch.resume();
    });
    // The agent: read each source and write it back with a line added, retrying a failed read as
    // an agent's tool would.
    let mut wrong_reads = 0usize;
    let mut failed_reads = 0usize;
    let mut touched = BTreeMap::new();
    for path in &sources {
        let mac = std::fs::read(w.local.join(path)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        let read = loop {
            match std::fs::read(w.remote.join(path)) {
                Ok(bytes) => break Some(bytes),
                Err(_) if Instant::now() < deadline => {
                    failed_reads += 1;
                    std::thread::sleep(Duration::from_millis(200));
                }
                Err(_) => break None,
            }
        };
        let Some(read) = read else { continue };
        if read != mac {
            wrong_reads += 1;
        }
        let mut edited = read;
        edited.extend_from_slice(b"// chaos\n");
        write(&w.remote.join(path), &edited);
        touched.insert(
            path.clone(),
            Touch { base: Some(mac), machine: Some(edited), ..Touch::default() },
        );
    }
    cutter.join().unwrap();
    let (tries, answer) = w.bring_back_until_ok(5);
    let mut out = tally(&w.local, &touched);
    out.torn += wrong_reads;
    println!(
        "CHAOS-READS {}",
        json!({"files": sources.len(), "failed_reads_retried": failed_reads, "wrong_reads": wrong_reads, "written": touched.len()})
    );
    report("cut mid lazy read + write, resume", &out, tries, &answer);
}
