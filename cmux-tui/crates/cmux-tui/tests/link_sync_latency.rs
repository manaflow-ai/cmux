//! `cmux link sync push` over a link with a round trip, the way a Cloud machine's link is: the
//! daemon side is the real `FsService`, and each answer leaves `RTT` after its request came, the
//! connection's lines still read and answered in order (`server::fs_wire`), so requests sent
//! together cross the link together.
//!
//! The bench (`a_bench_of_folders_shaped_like_leos`, ignored; `CMUX_SYNC_BENCH_RTT_MS`,
//! `CMUX_SYNC_BENCH_ROUNDS`, `CMUX_SYNC_BENCH_SCALE`) copies folders shaped like the ones Leo's
//! NIGHTLY copied slowly on 2026-11-15 and prints each push's stage times.
#![cfg(unix)]

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use cmux_tui_core::fs_ops::{self, FsService, Roots, stream};
use serde_json::{Value, json};

/// The most requests the server held at once on one connection with their answers not sent.
struct Served {
    most_in_flight: AtomicUsize,
    /// Requests of each `cmd`, all connections together.
    asked: std::sync::Mutex<std::collections::BTreeMap<String, usize>>,
}

/// Serves `fs.*` lines on `socket` over `home`, each answer `rtt` after its request came.
fn serve_with_rtt(socket: &Path, home: &Path, rtt: Duration) -> Arc<Served> {
    let listener = UnixListener::bind(socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    let served =
        Arc::new(Served { most_in_flight: AtomicUsize::new(0), asked: Default::default() });
    let shared = served.clone();
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            let served = shared.clone();
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                let in_flight = Arc::new(AtomicUsize::new(0));
                let (answers, due) = mpsc::channel::<(Instant, String)>();
                let sending = in_flight.clone();
                std::thread::spawn(move || {
                    for (at, text) in due {
                        std::thread::sleep(at.saturating_duration_since(Instant::now()));
                        sending.fetch_sub(1, Ordering::SeqCst);
                        if writer.write_all(text.as_bytes()).is_err() {
                            return;
                        }
                    }
                });
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    let came = Instant::now();
                    let now = in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                    served.most_in_flight.fetch_max(now, Ordering::SeqCst);
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    *served.asked.lock().unwrap().entry(cmd.clone()).or_default() += 1;
                    let reply = if cmd == "identify" {
                        json!({"id": id, "ok": true, "data": {"capabilities": [
                            fs_ops::FS_CAPABILITY, fs_ops::FS_SYMLINK_CAPABILITY,
                            fs_ops::FS_WRITE_DEFLATE_CAPABILITY, fs_ops::FS_WRITE_NOFOLLOW_CAPABILITY,
                        ]}})
                    } else {
                        stream::answer(&id, service.call("local", &cmd, request))
                    };
                    let mut text = reply.to_string();
                    text.push('\n');
                    if answers.send((came + rtt, text)).is_err() {
                        return;
                    }
                }
            });
        }
    });
    served
}

/// Pushes `local` to `remote` and answers the summary and the push's stage times.
fn push(socket: &Path, local: &Path, remote: &Path) -> (Value, Value) {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", socket.parent().unwrap().join("state"))
        .env("CMUX_SYNC_PUSH_TIMINGS", "1")
        .args(["link", "sync", "push", "--socket"])
        .arg(socket)
        .arg(local)
        .arg(remote)
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "sync push failed: {}{stderr}",
        String::from_utf8_lossy(&output.stdout)
    );
    let timings = stderr
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find_map(|line| line.get("timings").cloned())
        .unwrap_or(Value::Null);
    (serde_json::from_slice(&output.stdout).expect("one JSON summary on stdout"), timings)
}

/// A machine home with `~/work`, a short socket path and the folder to copy's parent.
fn machine(root: &Path) -> (tempfile::TempDir, PathBuf, PathBuf) {
    let home = root.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("cq").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("m.sock");
    (sockets, socket, home)
}

/// `files` small files over `folders` folders, and `large` files of `large_bytes` each.
fn plain_folder(at: &Path, files: usize, folders: usize, large: usize, large_bytes: usize) {
    for index in 0..files {
        let dir = at.join(format!("d{:04}", index % folders.max(1)));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join(format!("f{index:06}.txt")),
            format!("{index}\n").repeat(1 + index % 64),
        )
        .unwrap();
    }
    for index in 0..large {
        let dir = at.join("large");
        std::fs::create_dir_all(&dir).unwrap();
        // Incompressible, as media and archives are.
        let mut state = index as u64 + 1;
        let bytes: Vec<u8> = (0..large_bytes)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state as u8
            })
            .collect();
        std::fs::write(dir.join(format!("blob{index}.bin")), bytes).unwrap();
    }
}

/// Every file of `dir`, relative, with its bytes.
fn files_below(dir: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(next) = stack.pop() {
        for entry in std::fs::read_dir(&next).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if !path
                .file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with(".cmux"))
            {
                found.push((
                    path.strip_prefix(dir).unwrap().to_path_buf(),
                    std::fs::read(&path).unwrap(),
                ));
            }
        }
    }
    found.sort();
    found
}

/// Leo's NIGHTLY, 2026-11-15: a 20,000-file folder took 346 s to a reply where a small repository
/// took 54 s, at about 100 ms a round trip, one small file a round trip on each of 8 connections.
/// A connection now sends its small files several at a time: more than one request is in flight
/// on a connection, and 400 files at 200 ms take far fewer than the 400 / 8 = 50 round trips.
#[test]
fn small_files_cross_a_slow_link_several_to_a_round_trip_and_all_arrive() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let local = root.join("folder");
    plain_folder(&local, 400, 4, 0, 0);
    let (_sockets, socket, home) = machine(&root);
    let rtt = Duration::from_millis(200);
    let served = serve_with_rtt(&socket, &home, rtt);
    let remote = home.join("work/folder");

    let started = Instant::now();
    let (summary, _) = push(&socket, &local, &remote);
    let took = started.elapsed();

    assert_eq!(summary["written"], 400, "{summary}");
    assert_eq!(files_below(&local), files_below(&remote));
    assert!(
        served.most_in_flight.load(Ordering::SeqCst) > 1,
        "each connection waited for every answer before its next file"
    );
    // The writes alone were 50 round trips (10 s); the folders' own requests stay as they were.
    assert!(took < rtt * 40, "took {took:?}");
}

/// What a bench row prints: the push's wall time and its stages.
fn bench_row(name: &str, local: &Path, rtt: Duration, rounds: usize) {
    let mut walls = Vec::new();
    for round in 0..rounds {
        let root = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(root.path()).unwrap();
        let (_sockets, socket, home) = machine(&root);
        serve_with_rtt(&socket, &home, rtt);
        let started = Instant::now();
        let (summary, timings) = push(&socket, local, &home.join("work/copy"));
        let wall = started.elapsed().as_millis();
        walls.push(wall);
        println!(
            "bench {name} round {round}: wall_ms {wall} written {} bytes {} timings {timings}",
            summary["written"], summary["bytes"]
        );
    }
    walls.sort_unstable();
    let at = |q: f64| walls[((walls.len() as f64 - 1.0) * q).round() as usize];
    println!(
        "bench {name}: rtt_ms {} rounds {rounds} p50_ms {} p95_ms {}",
        rtt.as_millis(),
        at(0.5),
        at(0.95)
    );
}

/// Folders shaped like the ones of Leo's NIGHTLY run, scaled by `CMUX_SYNC_BENCH_SCALE` (1.0:
/// full size): the matrix's big plain folder (20,000 files in 200 folders and 4 x 32 MB), and a
/// plain folder of 11,800 files with large files (`~/Projects/briefs`: 3.1 GB, here 4 x 32 MB
/// at scale 1 to keep the run short; bytes cost the same before and after).
#[test]
#[ignore = "a bench: run with --ignored --nocapture"]
fn a_bench_of_folders_shaped_like_leos() {
    let number = |name: &str, default: f64| {
        std::env::var(name).ok().and_then(|value| value.parse::<f64>().ok()).unwrap_or(default)
    };
    let rtt = Duration::from_millis(number("CMUX_SYNC_BENCH_RTT_MS", 100.0) as u64);
    let rounds = number("CMUX_SYNC_BENCH_ROUNDS", 3.0) as usize;
    let scale = number("CMUX_SYNC_BENCH_SCALE", 1.0);
    let scaled = |n: usize| ((n as f64 * scale) as usize).max(1);
    let root = tempfile::tempdir().unwrap();
    let big_plain = root.path().join("big-plain");
    plain_folder(&big_plain, scaled(20_000), scaled(200), 4, 32 << 20);
    bench_row("big-plain", &big_plain, rtt, rounds);
    let briefs = root.path().join("briefs");
    plain_folder(&briefs, scaled(11_800), scaled(600), 4, 32 << 20);
    bench_row("briefs-shape", &briefs, rtt, rounds);
}

/// The bench of 2026-11-15 at 100 ms a round trip: making the folders took 26 of a 20,000-file
/// folder's 32 s at a quarter of its size, five requests one after another for each new folder
/// (is it a symlink, its listing, is it there, is its parent there, make it). A chat's copy
/// goes to a new folder, so nothing in it is the machine's: each folder is one `fs.mkdir`, and
/// nothing is asked of a folder or a file before it is written.
#[test]
fn a_copy_into_a_new_folder_makes_each_folder_with_one_request_and_asks_nothing_else() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let local = root.join("folder");
    // 40 folders of 2 files, and 10 of them with a folder below.
    plain_folder(&local, 80, 40, 0, 0);
    for index in 0..10 {
        let deeper = local.join(format!("d{index:04}/inner"));
        std::fs::create_dir_all(&deeper).unwrap();
        std::fs::write(deeper.join("x.txt"), "x\n").unwrap();
    }
    let (_sockets, socket, home) = machine(&root);
    let served = serve_with_rtt(&socket, &home, Duration::from_millis(1));
    let remote = home.join("work/folder");

    let (summary, _) = push(&socket, &local, &remote);

    assert_eq!(summary["written"], 90, "{summary}");
    assert_eq!(files_below(&local), files_below(&remote));
    let asked = served.asked.lock().unwrap().clone();
    let count = |cmd: &str| asked.get(cmd).copied().unwrap_or(0);
    assert_eq!(count("fs.mkdir"), 50 + 1, "{asked:?}");
    // The root's own checks and the manifest's read only, none per folder or file.
    assert!(count("fs.stat") + count("fs.list") <= 8, "{asked:?}");
}

/// After the change above each new folder was still one `fs.mkdir` round trip, one after
/// another: 6 of the bench's 12 s for the 20,000-file folder (at a quarter of its size). They
/// now go together once the push knows every folder, so 60 folders at 200 ms a round trip are
/// made in a few round trips, not 60.
#[test]
fn new_folders_cross_a_slow_link_together() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let local = root.join("folder");
    plain_folder(&local, 60, 60, 0, 0);
    let (_sockets, socket, home) = machine(&root);
    let rtt = Duration::from_millis(200);
    serve_with_rtt(&socket, &home, rtt);
    let remote = home.join("work/folder");

    let (summary, timings) = push(&socket, &local, &remote);

    assert_eq!(summary["written"], 60, "{summary}");
    assert_eq!(files_below(&local), files_below(&remote));
    let prepare =
        Duration::from_millis(timings["prepare"].as_u64().expect("the push's stage times"));
    assert!(prepare < rtt * 20, "making 60 folders took {prepare:?}");
}
