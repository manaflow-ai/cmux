//! The mount helper end to end on a real Linux machine: a fake session daemon answers
//! `projfs.fetch` from a temporary "Mac" folder, `projfs mount` puts the FUSE lower and the
//! overlay up, and the test works through the merged directory as an agent would.

#![cfg(target_os = "linux")]

mod common;

use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_projfs::{Builder, Stat, helper};
use common::{TempDir, bytes};
use serde_json::{Value, json};

/// Why this host cannot run the test, if it cannot.
fn cannot_mount() -> Option<String> {
    if !Path::new("/dev/fuse").exists() {
        return Some("no /dev/fuse".into());
    }
    let on_path = |name: &str| {
        std::env::var_os("PATH")
            .is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(name).is_file()))
    };
    if !on_path("fusermount3") {
        return Some("no fusermount3 on PATH".into());
    }
    let sudo = Command::new("sudo")
        .args(["-n", "true"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if !sudo.is_ok_and(|s| s.success()) {
        return Some("sudo -n is not allowed".into());
    }
    None
}

fn ns(secs: i64, nsec: i64) -> i64 {
    secs * 1_000_000_000 + nsec
}

/// The manifest of `root` as the Mac would send it.
fn manifest_of(root: &Path) -> Vec<u8> {
    fn walk(dir: &Path, rel: &str, b: &mut Builder) {
        for e in std::fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            let name = e.file_name().into_string().unwrap();
            let path = if rel.is_empty() { name } else { format!("{rel}/{name}") };
            let md = e.metadata().unwrap();
            let (m, c) = (ns(md.mtime(), md.mtime_nsec()), ns(md.ctime(), md.ctime_nsec()));
            if md.is_dir() {
                b.add(&path, Stat::dir(md.mode() & 0o7777, m, c)).unwrap();
                walk(&e.path(), &path, b);
            } else {
                b.add(&path, Stat::file(md.mode() & 0o7777, md.len(), m, c)).unwrap();
            }
        }
    }
    let mut b = Builder::new(root.to_str().unwrap());
    walk(root, "", &mut b);
    b.build().unwrap().encode().unwrap()
}

/// A session daemon that answers `projfs.fetch` from `mac`, as if the Mac were polling it.
struct FakeDaemon {
    socket: PathBuf,
    served: Arc<Mutex<BTreeSet<String>>>,
    bytes: Arc<AtomicU64>,
    quit: Arc<AtomicBool>,
    conns: Arc<Mutex<Vec<UnixStream>>>,
    accept: Option<std::thread::JoinHandle<()>>,
}

impl FakeDaemon {
    fn start(socket: PathBuf, mac: PathBuf) -> FakeDaemon {
        let listener = UnixListener::bind(&socket).unwrap();
        let served = Arc::new(Mutex::new(BTreeSet::new()));
        let bytes = Arc::new(AtomicU64::new(0));
        let quit = Arc::new(AtomicBool::new(false));
        let conns = Arc::new(Mutex::new(Vec::new()));
        let (s, b, q, c) = (served.clone(), bytes.clone(), quit.clone(), conns.clone());
        let accept = std::thread::spawn(move || {
            for conn in listener.incoming() {
                if q.load(Ordering::SeqCst) {
                    return;
                }
                let conn = conn.unwrap();
                c.lock().unwrap().push(conn.try_clone().unwrap());
                let (mac, s, b) = (mac.clone(), s.clone(), b.clone());
                std::thread::spawn(move || serve_conn(conn, &mac, &s, &b));
            }
        });
        FakeDaemon { socket, served, bytes, quit, conns, accept: Some(accept) }
    }

    /// Goes away as a restarting daemon does: no listener, no socket file, every connection
    /// closed.
    fn close(&mut self) {
        let Some(accept) = self.accept.take() else { return };
        self.quit.store(true, Ordering::SeqCst);
        let _ = UnixStream::connect(&self.socket);
        let _ = accept.join();
        let _ = std::fs::remove_file(&self.socket);
        for conn in self.conns.lock().unwrap().drain(..) {
            let _ = conn.shutdown(std::net::Shutdown::Both);
        }
    }
}

impl Drop for FakeDaemon {
    fn drop(&mut self) {
        self.close();
    }
}

fn serve_conn(conn: UnixStream, mac: &Path, served: &Mutex<BTreeSet<String>>, total: &AtomicU64) {
    let mut out = conn.try_clone().unwrap();
    for line in BufReader::new(conn).lines() {
        let Ok(line) = line else { return };
        let req: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(req["cmd"], "projfs.fetch");
        assert_eq!(req["mount"], "t1");
        let results: Vec<Value> = req["wants"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| {
                let path = w["path"].as_str().unwrap();
                served.lock().unwrap().insert(path.to_owned());
                let Ok(data) = std::fs::read(mac.join(path)) else {
                    return json!({"status": "gone"});
                };
                let md = std::fs::metadata(mac.join(path)).unwrap();
                if w["size"].as_u64() != Some(md.len())
                    || w["mtime_ns"].as_i64() != Some(ns(md.mtime(), md.mtime_nsec()))
                {
                    return json!({"status": "changed", "size": md.len(),
                        "mtime_ns": ns(md.mtime(), md.mtime_nsec()),
                        "ctime_ns": ns(md.ctime(), md.ctime_nsec()), "mode": md.mode()});
                }
                let off = (w["offset"].as_u64().unwrap() as usize).min(data.len());
                let end = (off + w["len"].as_u64().unwrap() as usize).min(data.len());
                total.fetch_add((end - off) as u64, Ordering::SeqCst);
                let b64 = base64::engine::general_purpose::STANDARD.encode(&data[off..end]);
                json!({"status": "bytes", "data_b64": b64})
            })
            .collect();
        let answer = json!({"id": req["id"], "ok": true, "data": {"results": results}});
        if writeln!(out, "{answer}").is_err() {
            return;
        }
    }
}

/// A writer that sends each line it is given to a channel.
struct Lines(mpsc::Sender<String>, Vec<u8>);

impl Write for Lines {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.1.extend_from_slice(buf);
        while let Some(at) = self.1.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.1.drain(..=at).collect();
            let _ = self.0.send(String::from_utf8_lossy(&line).trim().to_owned());
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Runs a helper command to the end; its exit code and JSON line.
fn helper_json(args: &[&str]) -> (i32, Value) {
    let args: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
    let mut out = Vec::new();
    let code = helper::run_with(&args, None, &mut out);
    let text = String::from_utf8(out).unwrap();
    (code, serde_json::from_str(text.trim()).unwrap_or_else(|_| panic!("not JSON: {text}")))
}

fn mounted(point: &Path) -> bool {
    let table = std::fs::read_to_string("/proc/self/mountinfo").unwrap();
    let point = point.to_str().unwrap();
    table.lines().any(|l| l.split(' ').nth(4) == Some(point))
}

#[test]
fn the_helper_mounts_reads_writes_and_unmounts() {
    if let Some(why) = cannot_mount() {
        eprintln!("SKIPPED the_helper_mounts_reads_writes_and_unmounts: {why}");
        return;
    }
    let tmp = TempDir::new("helper");
    let mac = tmp.path().join("mac");
    std::fs::create_dir_all(mac.join("sub")).unwrap();
    let big = bytes(7, 9 << 20);
    std::fs::write(mac.join("small.txt"), b"small file\n").unwrap();
    std::fs::write(mac.join("big.bin"), &big).unwrap();
    std::fs::write(mac.join("edit.txt"), b"before\n").unwrap();
    std::fs::write(mac.join("gone.txt"), b"delete me\n").unwrap();
    for (name, len) in [("x.txt", 100), ("y.txt", 200), ("z.bin", 3 << 20)] {
        std::fs::write(mac.join("sub").join(name), bytes(1, len)).unwrap();
    }
    let manifest = tmp.path().join("manifest.bin");
    std::fs::write(&manifest, manifest_of(&mac)).unwrap();
    let daemon = FakeDaemon::start(tmp.path().join("d.sock"), mac.clone());
    let (at, state) = (tmp.path().join("merged"), tmp.path().join("state"));
    std::fs::create_dir(&at).unwrap();
    let s = |p: &Path| p.to_str().unwrap().to_owned();

    let (tx, rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    let args: Vec<String> = [
        "mount",
        "--mount",
        "t1",
        "--manifest",
        &s(&manifest),
        "--at",
        &s(&at),
        "--state",
        &s(&state),
        "--socket",
        &s(&daemon.socket),
    ]
    .iter()
    .map(|a| (*a).to_owned())
    .collect();
    std::thread::spawn(move || {
        let code = helper::run_with(&args, None, &mut Lines(tx, Vec::new()));
        let _ = done_tx.send(code);
    });
    let ready: Value =
        serde_json::from_str(&rx.recv_timeout(Duration::from_secs(60)).unwrap()).unwrap();
    eprintln!("mount: {ready}");
    assert_eq!(ready["ok"], true, "{ready}");
    assert_eq!(ready["entries"], 9, "root, 4 files, sub and its 3 files");
    assert!(matches!(ready["git"].as_str(), Some("set" | "kept" | "unavailable")), "{ready}");
    assert!(mounted(&at) && mounted(&state.join("lower")));

    // Metadata needs no fetch at all.
    let mut names: Vec<String> = std::fs::read_dir(&at)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names, ["big.bin", "edit.txt", "gone.txt", "small.txt", "sub"]);
    assert_eq!(std::fs::metadata(at.join("sub/z.bin")).unwrap().len(), 3 << 20);
    assert!(daemon.served.lock().unwrap().is_empty(), "listing and stat fetched nothing");

    assert_eq!(std::fs::read(at.join("small.txt")).unwrap(), b"small file\n");
    assert_eq!(std::fs::read(at.join("big.bin")).unwrap(), big, "a three-chunk file");
    std::fs::write(at.join("new.txt"), b"made on the machine\n").unwrap();
    let mut f = std::fs::OpenOptions::new().append(true).open(at.join("edit.txt")).unwrap();
    f.write_all(b"after\n").unwrap();
    drop(f);
    assert_eq!(std::fs::read(at.join("edit.txt")).unwrap(), b"before\nafter\n");
    std::fs::remove_file(at.join("gone.txt")).unwrap();
    assert!(!at.join("gone.txt").exists());
    assert_eq!(std::fs::read(mac.join("edit.txt")).unwrap(), b"before\n", "the Mac is untouched");

    let (code, upper) = helper_json(&["upper", "--state", &s(&state)]);
    assert_eq!(code, 0, "{upper}");
    assert_eq!(
        upper["changes"],
        json!([
            {"path": "edit.txt", "kind": "file"},
            {"path": "gone.txt", "kind": "delete"},
            {"path": "new.txt", "kind": "file"},
        ])
    );
    let served = daemon.served.lock().unwrap().clone();
    eprintln!("served: {served:?}, {} bytes", daemon.bytes.load(Ordering::SeqCst));
    assert!(served.iter().all(|p| !p.starts_with("sub/")), "sub/ was never read: {served:?}");
    assert!(served.contains("big.bin") && served.contains("edit.txt"));

    let (code, gone) = helper_json(&["unmount", "--at", &s(&at), "--state", &s(&state)]);
    eprintln!("unmount: {gone}");
    assert_eq!(code, 0, "{gone}");
    assert_eq!(gone["overlay"], "unmounted");
    assert_eq!(done_rx.recv_timeout(Duration::from_secs(20)), Ok(0), "the helper ended");
    assert!(!mounted(&at) && !mounted(&state.join("lower")), "no mounts left");

    let (code, status) = helper_json(&["status", "--state", &s(&state)]);
    eprintln!("status: {status}");
    assert_eq!(code, 0, "{status}");
    assert_eq!(status["running"], false);
    assert!(status["remote_reads"].as_u64() >= Some(2), "{status}");
    let total: u64 = 11 + big.len() as u64 + 7 + 10 + 300 + (3 << 20);
    assert!(status["bytes_fetched"].as_u64() < Some(total), "not every byte was fetched");
    assert_eq!(std::fs::read(state.join("upper/new.txt")).unwrap(), b"made on the machine\n");

    let (code, again) = helper_json(&["unmount", "--at", &s(&at), "--state", &s(&state)]);
    assert_eq!(
        (code, &again["overlay"], &again["lower"]),
        (0, &json!("not_mounted"), &json!("not_mounted"))
    );
    remove_work(&state);
}

/// A small "Mac" folder with three files and its manifest, under `tmp`.
fn small_mac(tmp: &TempDir) -> (PathBuf, PathBuf) {
    let mac = tmp.path().join("mac");
    std::fs::create_dir_all(mac.join("sub")).unwrap();
    for name in ["a.txt", "b.txt", "sub/c.txt"] {
        std::fs::write(mac.join(name), format!("this is {name}\n")).unwrap();
    }
    let manifest = tmp.path().join("manifest.bin");
    std::fs::write(&manifest, manifest_of(&mac)).unwrap();
    (mac, manifest)
}

/// `projfs mount` on a thread of this process: its ready line and a channel with its exit code.
fn mount_in_process(args: Vec<String>) -> (Value, mpsc::Receiver<i32>) {
    let (tx, rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    std::thread::spawn(move || {
        let code = helper::run_with(&args, None, &mut Lines(tx, Vec::new()));
        let _ = done_tx.send(code);
    });
    let line = rx.recv_timeout(Duration::from_secs(60)).unwrap();
    (serde_json::from_str(&line).unwrap(), done_rx)
}

/// Removes the overlay's work directory, which holds a root-owned entry.
fn remove_work(state: &Path) {
    let work = state.join("work");
    let _ = Command::new("sudo").args(["-n", "rm", "-rf", "--"]).arg(&work).status();
}

#[test]
fn the_mount_survives_a_daemon_restart() {
    if let Some(why) = cannot_mount() {
        eprintln!("SKIPPED the_mount_survives_a_daemon_restart: {why}");
        return;
    }
    let tmp = TempDir::new("helper-restart");
    let (mac, manifest) = small_mac(&tmp);
    let socket = tmp.path().join("d.sock");
    let mut daemon = FakeDaemon::start(socket.clone(), mac.clone());
    let (at, state) = (tmp.path().join("merged"), tmp.path().join("state"));
    std::fs::create_dir(&at).unwrap();
    let s = |p: &Path| p.to_str().unwrap().to_owned();
    let args = [
        "mount",
        "--mount",
        "t1",
        "--manifest",
        &s(&manifest),
        "--at",
        &s(&at),
        "--state",
        &s(&state),
        "--socket",
        &s(&socket),
    ];
    let (ready, done) = mount_in_process(args.iter().map(|a| (*a).to_owned()).collect());
    assert_eq!(ready["ok"], true, "{ready}");
    assert_eq!(std::fs::read(at.join("a.txt")).unwrap(), b"this is a.txt\n");

    // The daemon restarts: its socket and the helper's connection to it are gone.
    daemon.close();
    assert_eq!(std::fs::metadata(at.join("sub/c.txt")).unwrap().len(), 18, "stat needs no daemon");
    // (Not b.txt: reading a.txt fetched the small files of its folder with it.)
    let t = Instant::now();
    let down = std::fs::read(at.join("sub/c.txt"));
    eprintln!("read while the daemon is down: {down:?} after {:?}", t.elapsed());
    assert!(down.is_err(), "nothing can answer a read with no daemon");
    assert!(t.elapsed() < Duration::from_secs(30), "the read gave up within its bound");

    // It comes back on the same path: the next read dials it afresh.
    let daemon = FakeDaemon::start(socket, mac);
    assert_eq!(std::fs::read(at.join("sub/c.txt")).unwrap(), b"this is sub/c.txt\n");
    assert!(daemon.served.lock().unwrap().contains("sub/c.txt"));

    let (code, gone) = helper_json(&["unmount", "--at", &s(&at), "--state", &s(&state)]);
    assert_eq!(code, 0, "{gone}");
    assert_eq!(done.recv_timeout(Duration::from_secs(20)), Ok(0), "the helper ended");
    let (code, status) = helper_json(&["status", "--state", &s(&state)]);
    eprintln!("status: {status}");
    assert_eq!(code, 0, "{status}");
    assert!(status["away"].as_u64() >= Some(1), "the down read counted as away: {status}");
    assert!(!mounted(&at) && !mounted(&state.join("lower")), "no mounts left");
    remove_work(&state);
}

#[test]
fn sigterm_ends_the_helper_while_a_process_sits_in_the_mount() {
    if let Some(why) = cannot_mount() {
        eprintln!("SKIPPED sigterm_ends_the_helper_while_a_process_sits_in_the_mount: {why}");
        return;
    }
    let tmp = TempDir::new("helper-sigterm");
    let (mac, manifest) = small_mac(&tmp);
    let daemon = FakeDaemon::start(tmp.path().join("d.sock"), mac);
    let (at, state) = (tmp.path().join("merged"), tmp.path().join("state"));
    std::fs::create_dir(&at).unwrap();
    // On the real machine the binary is pushed beside the test; on the builder Cargo built it.
    let bin = std::env::var_os("CMUX_PROJFS_BIN")
        .map_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_cmux-projfs")), PathBuf::from);
    let mut helper = Command::new(&bin)
        .args(["mount", "--mount", "t1", "--manifest"])
        .arg(&manifest)
        .arg("--at")
        .arg(&at)
        .arg("--state")
        .arg(&state)
        .arg("--socket")
        .arg(&daemon.socket)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap_or_else(|e| panic!("cannot start {}: {e}", bin.display()));
    let mut line = String::new();
    BufReader::new(helper.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let ready: Value = serde_json::from_str(&line).unwrap_or_else(|_| panic!("not JSON: {line}"));
    assert_eq!(ready["ok"], true, "{ready}");

    // Another process keeps its working directory inside the merged directory, with a file
    // read through it, so neither layer can be unmounted cleanly.
    assert_eq!(std::fs::read(at.join("sub/c.txt")).unwrap(), b"this is sub/c.txt\n");
    let mut sitter = Command::new("sleep").arg("600").current_dir(at.join("sub")).spawn().unwrap();

    // SAFETY: a plain kill of the helper child this test started.
    assert_eq!(unsafe { libc::kill(helper.id() as i32, libc::SIGTERM) }, 0);
    let t = Instant::now();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(helper.wait());
    });
    let exit = rx.recv_timeout(Duration::from_secs(20));
    let took = t.elapsed();
    let mounted_after = (mounted(&at), mounted(&state.join("lower")));
    let _ = sitter.kill();
    let _ = sitter.wait();
    eprintln!(
        "helper exit {exit:?} after {took:?}; still mounted (merged, lower): {mounted_after:?}"
    );
    let exit = exit.expect("the helper exited within 20 s").unwrap();
    assert!(exit.success(), "{exit}");
    assert!(took < cmux_projfs::fuse::UNMOUNT_WAIT + Duration::from_secs(10), "{took:?}");
    assert_eq!(mounted_after, (false, false), "both layers left the mount table");

    let (at, state_text) = (at.to_str().unwrap(), state.to_str().unwrap());
    let (code, again) = helper_json(&["unmount", "--at", at, "--state", state_text]);
    assert_eq!(code, 0, "{again}");
    assert_eq!(
        (&again["overlay"], &again["lower"]),
        (&json!("not_mounted"), &json!("not_mounted"))
    );
    remove_work(&state);
}

#[test]
fn refusals_name_their_code() {
    let (code, v) = helper_json(&[
        "mount",
        "--mount",
        "bad id!",
        "--manifest",
        "/m",
        "--at",
        "/a",
        "--state",
        "/s",
    ]);
    assert_eq!((code, &v["code"]), (helper::EXIT_USAGE, &json!("usage")));
    let (code, v) = helper_json(&[
        "mount",
        "--mount",
        "m",
        "--manifest",
        "/m",
        "--at",
        "/a",
        "--state",
        "/s,x",
    ]);
    assert_eq!((code, &v["code"]), (helper::EXIT_USAGE, &json!("usage")), "{v}");
    let tmp = TempDir::new("helper-refuse");
    let at = tmp.path().join("at");
    std::fs::create_dir(&at).unwrap();
    std::fs::write(tmp.path().join("m"), b"not a manifest").unwrap();
    let s = |p: PathBuf| p.to_str().unwrap().to_owned();
    let (code, v) = helper_json(&[
        "mount",
        "--mount",
        "m",
        "--manifest",
        &s(tmp.path().join("m")),
        "--at",
        &s(at.clone()),
        "--state",
        &s(tmp.path().join("state")),
    ]);
    assert_eq!(code, helper::EXIT_FAILED, "{v}");
    let expected = if cannot_mount().is_some() {
        ["no_fuse", "no_sudo"].as_slice()
    } else {
        &["bad_manifest"]
    };
    assert!(expected.contains(&v["code"].as_str().unwrap()), "{v}");
    assert!(!mounted(&at));
    let (code, v) = helper_json(&["status", "--state", &s(tmp.path().join("nothing"))]);
    assert_eq!((code, &v["code"]), (helper::EXIT_FAILED, &json!("no_stats")));
}
