//! A take-over hands the old daemon's listening socket to the new one by descriptor
//! (`daemon/listener_handover.rs`, RFD 0082 make-before-break; Leo 2026-11-23: "we ought to have
//! more graceful handoffs... similar to network drains"). A client that dials the whole time sees
//! no refused connect and no request dropped without an answer: a connect during the swap waits in
//! the kernel's queue and the new daemon accepts it. Before, the old daemon removed the socket and
//! the new one bound it again, and connects in between failed. The real binary, on Unix.
#![cfg(unix)]

use crate::daemon_env;

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Take-overs in a row, each from the daemon the last one started.
const TAKE_OVERS: usize = 3;

fn daemon(scratch: &Path, home: &Path, socket: &Path) -> std::process::Command {
    let mut cmd = daemon_env::acpmux(scratch);
    cmd.args(["daemon", "run", "--memory", "--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", socket)
        .stdin(Stdio::null());
    cmd
}

/// A daemon as a client starts one, reporting readiness on a pipe.
fn start(scratch: &Path, home: &Path, socket: &Path) -> Child {
    let mut child = daemon(scratch, home, socket)
        .args(["--ready-fd", "1"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    for line in BufReader::new(stdout).lines() {
        if serde_json::from_str::<Value>(&line.unwrap()).is_ok_and(|v| v["ready"] == true) {
            return child;
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    panic!("daemon exited without a readiness line");
}

/// What one dial came to.
enum Dial {
    /// Connected and answered (a result, or a typed error such as `daemon.restarting`).
    Answered { pid: Option<u64>, restarting: bool },
    /// The connect itself failed: the gap this change closes.
    Refused(std::io::Error),
    /// Connected, sent, and the connection ended (or timed out) with no answer.
    Dropped(String),
}

fn dial(socket: &Path) -> Dial {
    let mut s = match UnixStream::connect(socket) {
        Ok(s) => s,
        Err(e) => return Dial::Refused(e),
    };
    // A connect queued during the swap is answered once the new daemon serves.
    let _ = s.set_read_timeout(Some(Duration::from_secs(60)));
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status", "params": {}});
    if let Err(e) = s.write_all(format!("{line}\n").as_bytes()) {
        return Dial::Dropped(format!("write: {e}"));
    }
    let mut reader = BufReader::new(s);
    loop {
        let mut text = String::new();
        match reader.read_line(&mut text) {
            Ok(0) => return Dial::Dropped("closed with no answer".into()),
            Err(e) => return Dial::Dropped(format!("read: {e}")),
            Ok(_) => {}
        }
        let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
        if v["id"] == 1 {
            let restarting = v["error"]["data"]["errorKind"] == "daemon.restarting";
            return Dial::Answered { pid: v["result"]["pid"].as_u64(), restarting };
        }
    }
}

#[derive(Default)]
struct Tally {
    dials: AtomicU64,
    answered: AtomicU64,
    restarting: AtomicU64,
    refused: AtomicU64,
    dropped: AtomicU64,
    serving: AtomicU64,
    slowest_ms: AtomicU64,
}

fn exited_within(child: &mut Child, budget: Duration) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + budget;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return Some(status);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_take_over_refuses_no_connect_and_drops_no_request() {
    let dir = daemon_env::Scratch::new("amx-lho");
    // The home and the socket sit in a short directory whatever $TMPDIR is: the side socket the
    // handover uses is made in the home, and a home too long for a socket path binds instead.
    let short = cmux_unix_socket::short_test_dir("amx-lho");
    let home = short.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let socket = short.path().join("a.sock");
    let mut current = start(&dir, &home, &socket);

    let tally = Arc::new(Tally::default());
    let stop = Arc::new(AtomicBool::new(false));
    let errors = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    // Four dialers, each back to back, for the whole run.
    let dialers: Vec<_> = (0..4)
        .map(|_| {
            let (tally, stop, errors, socket) =
                (tally.clone(), stop.clone(), errors.clone(), socket.clone());
            std::thread::spawn(move || {
                while !stop.load(Ordering::SeqCst) {
                    tally.dials.fetch_add(1, Ordering::SeqCst);
                    let began = Instant::now();
                    let dial = dial(&socket);
                    let ms = began.elapsed().as_millis() as u64;
                    tally.slowest_ms.fetch_max(ms, Ordering::SeqCst);
                    match dial {
                        Dial::Answered { pid, restarting } => {
                            tally.answered.fetch_add(1, Ordering::SeqCst);
                            if restarting {
                                tally.restarting.fetch_add(1, Ordering::SeqCst);
                            }
                            if let Some(pid) = pid {
                                tally.serving.store(pid, Ordering::SeqCst);
                            }
                        }
                        Dial::Refused(e) => {
                            tally.refused.fetch_add(1, Ordering::SeqCst);
                            errors.lock().unwrap().push(format!("refused: {e}"));
                        }
                        Dial::Dropped(why) => {
                            tally.dropped.fetch_add(1, Ordering::SeqCst);
                            errors.lock().unwrap().push(format!("dropped: {why}"));
                        }
                    }
                }
            })
        })
        .collect();

    let mut swaps = Vec::new();
    for round in 0..TAKE_OVERS {
        std::thread::sleep(Duration::from_millis(300));
        let began = Instant::now();
        let mut next = daemon(&dir, &home, &socket)
            .arg("--take-over")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let next_pid = u64::from(next.id());
        let deadline = Instant::now() + Duration::from_secs(60);
        while tally.serving.load(Ordering::SeqCst) != next_pid {
            if let Some(status) = next.try_wait().unwrap() {
                panic!("round {round}: the take-over daemon exited ({status})");
            }
            assert!(Instant::now() < deadline, "round {round}: the new daemon never answered");
            std::thread::sleep(Duration::from_millis(20));
        }
        swaps.push(began.elapsed());
        let gone = exited_within(&mut current, Duration::from_secs(30));
        assert!(gone.is_some_and(|s| s.success()), "round {round}: old daemon: {gone:?}");
        current = next;
    }
    std::thread::sleep(Duration::from_millis(300));
    stop.store(true, Ordering::SeqCst);
    for d in dialers {
        d.join().unwrap();
    }
    // SAFETY: the pid is this test's own child.
    unsafe { libc::kill(current.id() as i32, libc::SIGTERM) };
    let _ = current.wait();

    let t = |a: &AtomicU64| a.load(Ordering::SeqCst);
    eprintln!(
        "handoff-duress: {TAKE_OVERS} take-overs, {} dials, answered={} (restarting={}), refused={}, dropped={}, slowest dial {} ms, swaps {:?}",
        t(&tally.dials),
        t(&tally.answered),
        t(&tally.restarting),
        t(&tally.refused),
        t(&tally.dropped),
        t(&tally.slowest_ms),
        swaps,
    );
    let errors = errors.lock().unwrap();
    assert_eq!(t(&tally.refused), 0, "refused connects: {:?}", &errors[..errors.len().min(10)]);
    assert_eq!(t(&tally.dropped), 0, "dropped requests: {:?}", &errors[..errors.len().min(10)]);
}
