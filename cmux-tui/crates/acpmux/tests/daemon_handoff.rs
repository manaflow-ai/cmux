//! A restart nobody notices (`acpmux.v2` `start`, `daemon/handoff.rs`): `_acpmux/shutdown
//! {restart: true}` execs the installed build in place. The same pid serves again with the same
//! listening socket (its inode unchanged) and the same WebSocket listener, a dial during the
//! restart waits in the kept socket's backlog instead of being refused, and the status counts the
//! restarts. A build at the installed path that fails its check leaves the daemon serving and the
//! request answered with why. Without `start` the request exits the process as before. The real
//! binary, on Unix.
//!
//! The pause over a god home and a small one, in one harness (an `#[ignore]` bench, for the PR's
//! numbers): `ACPMUX_HANDOFF_RUNS` restarts on each (default 5), the god home at
//! `ACPMUX_HANDOFF_GOD_SCALE` of `Shape::god` (default 0.02). The measured run, on Linux CI:
//! `ACPMUX_HANDOFF_RUNS=20 ACPMUX_HANDOFF_GOD_SCALE=1 cargo test -p acpmux --release --test
//! daemon_handoff -- --ignored --nocapture`.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The bench's sizes hold no credential.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().keep(&["ACPMUX_HANDOFF_RUNS", "ACPMUX_HANDOFF_GOD_SCALE"]);

use acpmux::god_fixture::{self, Shape};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// `config.json` in `home`, with `acpmux.v2` set to `surfaces`.
fn config(home: &Path, surfaces: &[&str]) {
    let path = home.join("config.json");
    std::fs::write(&path, json!({"acpmux.v2": surfaces}).to_string()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// `daemon run --memory` of `cmd` in `home`, ready: its stdout (the ready line, then its log)
/// drained on a thread so a full pipe never holds it.
fn start(cmd: Command, home: &Path, socket: &Path) -> (Child, Value) {
    start_with(cmd, home, socket, true)
}

/// [`start`], its store in memory or, without `memory`, the home's own on disk.
fn start_with(mut cmd: Command, home: &Path, socket: &Path, memory: bool) -> (Child, Value) {
    cmd.args(["daemon", "run"]);
    if memory {
        cmd.arg("--memory");
    }
    cmd.args([
        "--log",
        "warn",
        "--listen",
        "127.0.0.1:0",
        "--token",
        "test-token",
        "--ready-fd",
        "1",
    ])
    .env("ACPMUX_HOME", home)
    .env("ACPMUX_SOCKET", socket)
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::inherit());
    let mut child = cmd.spawn().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let ready = loop {
        let mut line = String::new();
        if stdout.read_line(&mut line).unwrap() == 0 {
            let _ = child.kill();
            let _ = child.wait();
            panic!("the daemon exited before it was ready");
        }
        if let Ok(value) = serde_json::from_str::<Value>(&line)
            && value["ready"] == true
        {
            break value;
        }
    };
    std::thread::spawn(move || {
        // Its log (warnings and up), shown with the test's own output: a handoff that fell back
        // says why there.
        let mut line = String::new();
        while stdout.read_line(&mut line).is_ok_and(|n| n > 0) {
            eprint!("daemon: {line}");
            line.clear();
        }
    });
    (child, ready)
}

/// What the daemon at `socket` answers to `method`: Ok(result), Err(error), or None when the
/// connection could be made but ended without an answer (the old image's last moment).
fn call(stream: UnixStream, method: &str, params: Value) -> Option<Result<Value, Value>> {
    stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
    let mut writer = stream.try_clone().unwrap();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
    writer.write_all(format!("{line}\n").as_bytes()).ok()?;
    let mut reader = BufReader::new(stream);
    loop {
        let mut text = String::new();
        if reader.read_line(&mut text).ok()? == 0 {
            return None;
        }
        let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
        if v["id"] == 1 {
            return Some(match v.get("error") {
                Some(error) => Err(error.clone()),
                None => Ok(v["result"].clone()),
            });
        }
    }
}

/// A dial of `socket` that must not be refused: the listener stays open through a handoff.
fn dial(socket: &Path) -> UnixStream {
    UnixStream::connect(socket)
        .unwrap_or_else(|e| panic!("a dial of {} refused: {e}", socket.display()))
}

/// The daemon's status, dialed again while the old image ends a connection it took (at most
/// `within`); every dial must connect.
fn status_after(socket: &Path, within: Duration, want: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + within;
    loop {
        if let Some(Ok(status)) = call(dial(socket), "_acpmux/status", json!({}))
            && want(&status)
        {
            return status;
        }
        assert!(Instant::now() < deadline, "the daemon did not serve again within {within:?}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn restart_request() -> Value {
    json!({"restart": true, "reason": "test: daemon_handoff"})
}

fn inode(path: &Path) -> (u64, u64) {
    let meta = std::fs::metadata(path).unwrap();
    (meta.dev(), meta.ino())
}

fn stop(mut child: Child) {
    // SAFETY: the pid is this test's own child.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let _ = child.wait();
}

#[test]
fn three_restarts_in_a_row_are_each_an_exec_in_place() {
    let _ = HERMETIC;
    let dir = cmux_unix_socket::short_test_dir("amx-hof");
    let home = dir.path();
    let socket = home.join("s.sock");
    config(home, &["start"]);
    let (mut child, ready) = start(daemon_env::acpmux(home), home, &socket);
    let pid = u64::from(child.id());
    assert_eq!(ready["pid"].as_u64(), Some(pid));
    let first = status_after(&socket, Duration::from_secs(30), |_| true);
    assert_eq!(first["handoffs"], 0, "{first}");
    let listen = first["listen"].clone();
    let socket_id = inode(&socket);

    for n in 1..=3u64 {
        let asked = Instant::now();
        let answer = call(dial(&socket), "_acpmux/shutdown", restart_request())
            .expect("the restart request was answered")
            .unwrap_or_else(|e| panic!("restart {n} refused: {e}"));
        assert_eq!(answer["handoff"], true, "restart {n}: {answer}");
        // Dialed during the handoff: never refused; answered by the new image, or by the old one
        // in its last moment (answered, or ended and then answered on the next dial).
        std::thread::sleep(Duration::from_millis(100));
        // The WebSocket listener too: the stop leaves it listening for the next image, so a
        // connect during the handoff waits in its queue and is never refused.
        let web = listen.as_str().expect("the daemon reports its WebSocket listener");
        if let Err(e) = std::net::TcpStream::connect(web) {
            panic!("restart {n}: a connect to {web} during the handoff was refused: {e}");
        }
        let during = dial(&socket);
        if let Some(reply) = call(during, "_acpmux/status", json!({})) {
            let status = reply.unwrap_or_else(|e| panic!("restart {n}: status refused: {e}"));
            let count = status["handoffs"].as_u64();
            assert!(count == Some(n) || count == Some(n - 1), "restart {n}: {status}");
        }
        let status = status_after(&socket, Duration::from_secs(30), |s| s["handoffs"] == n);
        // The pause a client saw, for the PR's numbers (not a bound): the request sent to the
        // new image's first answer.
        println!("HANDOFF-PAUSE restart={n} ms={}", asked.elapsed().as_millis());
        #[cfg(target_os = "linux")]
        if let Ok(argv) = std::fs::read(format!("/proc/{pid}/cmdline")) {
            println!(
                "HANDOFF-ARGS restart={n} {}",
                String::from_utf8_lossy(&argv).replace('\0', " ")
            );
        }
        assert_eq!(status["pid"].as_u64(), Some(pid), "restart {n}: {status}");
        assert_eq!(status["listen"], listen, "restart {n}: {status}");
        assert_eq!(inode(&socket), socket_id, "restart {n}: the socket was bound again");
        assert!(child.try_wait().unwrap().is_none(), "restart {n}: the daemon process exited");
    }
    stop(child);
}

/// How long the bench waits for a daemon over a god home to serve (its first status, or again
/// after a restart) before it fails.
const BENCH_WITHIN: Duration = Duration::from_secs(120);

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// The small shape, and `Shape::god` at `scale`, neither with peers (a restart does not dial
/// them).
fn shapes(scale: f64) -> [Shape; 2] {
    let god = Shape::god();
    let by = |n: usize| ((n as f64 * scale).ceil() as usize).max(1);
    let god = Shape {
        chats: by(god.chats),
        god_messages: by(god.god_messages),
        god_bytes: (god.god_bytes as f64 * scale) as u64,
        peers: 0,
        ..god
    };
    [Shape { peers: 0, ..Shape::small() }, god]
}

/// p50, p95 and max of `samples`.
fn spread(samples: &[f64]) -> (f64, f64, f64) {
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    let at = |q: f64| sorted[((sorted.len() - 1) as f64 * q).round() as usize];
    (at(0.5), at(0.95), sorted[sorted.len() - 1])
}

/// The bench's `config.json`: `start` on, as [`config`] writes it, and the fixture home's
/// harness (`tests/stop_under_load.rs`), which never starts here: agent launches stay denied.
fn bench_config(home: &Path) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({
        "acpmux.v2": ["start"],
        "harnesses": {"claude": {"argv": ["python3", fake]}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
    });
    let path = home.join("config.json");
    std::fs::write(&path, config.to_string()).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// `shape`'s home, its store on disk, restarted in place `runs` times: each pause in ms, timed as
/// `three_restarts_in_a_row_are_each_an_exec_in_place` times it (the request sent to the new
/// image's first status).
fn pauses(shape: &Shape, runs: u64) -> Vec<f64> {
    let scratch = daemon_env::Scratch::new(&format!("hof-{}", shape.name));
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    god_fixture::write_home(&home, &claude, &scratch.join("work"), shape).unwrap();
    bench_config(&home);
    // The socket in a short folder: the scratch folder's path may be too long for one.
    let dir = cmux_unix_socket::short_test_dir("amx-hofb");
    let socket = dir.path().join("s.sock");
    let mut cmd = daemon_env::acpmux(&scratch);
    cmd.env("ACPMUX_CATALOG_FETCH", "0").env("ACPMUX_LOGIN_ENV", "0");
    let (mut child, ready) = start_with(cmd, &home, &socket, false);
    let pid = u64::from(child.id());
    assert_eq!(ready["pid"].as_u64(), Some(pid));
    let first = status_after(&socket, BENCH_WITHIN, |_| true);
    assert_eq!(first["handoffs"], 0, "{}: {first}", shape.name);
    let mut ms = Vec::new();
    for n in 1..=runs {
        let asked = Instant::now();
        let answer = call(dial(&socket), "_acpmux/shutdown", restart_request())
            .expect("the restart request was answered")
            .unwrap_or_else(|e| panic!("{} restart {n} refused: {e}", shape.name));
        assert_eq!(answer["handoff"], true, "{} restart {n}: {answer}", shape.name);
        let status = status_after(&socket, BENCH_WITHIN, |s| s["handoffs"] == n);
        ms.push(asked.elapsed().as_secs_f64() * 1000.0);
        assert_eq!(status["pid"].as_u64(), Some(pid), "{} restart {n}: {status}", shape.name);
        assert!(
            child.try_wait().unwrap().is_none(),
            "{} restart {n}: the daemon exited",
            shape.name
        );
    }
    stop(child);
    ms
}

#[test]
#[ignore = "a bench: run with --ignored on Linux CI"]
fn a_restart_in_place_pauses_a_god_home_no_longer_than_a_small_one() {
    let _ = HERMETIC;
    let runs = env_or("ACPMUX_HANDOFF_RUNS", 5u64).max(1);
    let scale = env_or("ACPMUX_HANDOFF_GOD_SCALE", 0.02f64).clamp(0.001, 1.0);
    let mut p95s = Vec::new();
    for shape in shapes(scale) {
        let (p50, p95, max) = spread(&pauses(&shape, runs));
        println!(
            "HANDOFF-PAUSE-SPREAD home={} n={runs} p50={p50:.0} p95={p95:.0} max={max:.0}",
            shape.name
        );
        p95s.push(p95);
    }
    let god = &shapes(scale)[1];
    println!(
        "HANDOFF-PAUSE-GOD scale={scale} chats={} messages={} bytes={}",
        god.chats, god.god_messages, god.god_bytes
    );
    let (small_p95, god_p95) = (p95s[0], p95s[1]);
    // The 25 ms floor: under it a ratio of two pauses of a few milliseconds is the scheduler's
    // jitter, not the home.
    assert!(
        god_p95 <= (small_p95 * 1.2).max(small_p95 + 25.0),
        "the god home's restart p95 {god_p95:.0} ms is over 1.2x the small one's {small_p95:.0} ms \
         (or it + 25 ms)"
    );
}

#[test]
fn a_failed_check_leaves_the_daemon_serving_and_answers_the_request() {
    let _ = HERMETIC;
    let dir = cmux_unix_socket::short_test_dir("amx-hofc");
    let home = dir.path();
    let socket = home.join("s.sock");
    config(home, &["start"]);
    // The daemon runs from its own copy, which this test then replaces at the installed path.
    let copy = home.join("acpmux");
    std::fs::copy(daemon_env::bin(), &copy).unwrap();
    std::fs::set_permissions(&copy, std::fs::Permissions::from_mode(0o755)).unwrap();
    let cmd = daemon_env::command_at(&copy, home, daemon_env::Agents::Deny, &[]);
    let (child, _) = start(cmd, home, &socket);
    let pid = u64::from(child.id());

    // A program that takes no handoff, put in place by a rename: the running copy is busy. It
    // stays executable; the update watch's own readiness check fails on it too and keeps this one.
    let script = home.join("acpmux.next");
    std::fs::write(&script, "#!/bin/sh\nexit 1\n").unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::rename(&script, &copy).unwrap();

    let refused = call(dial(&socket), "_acpmux/shutdown", restart_request())
        .expect("the restart request was answered")
        .expect_err("a restart past a failed check");
    assert_eq!(refused["data"]["reason"], "restart.handoff_check_failed", "{refused}");
    let status = status_after(&socket, Duration::from_secs(10), |_| true);
    assert_eq!(status["pid"].as_u64(), Some(pid), "{status}");
    assert_eq!(status["handoffs"], 0, "{status}");
    stop(child);
}

#[test]
fn without_start_a_restart_request_exits_as_before() {
    let _ = HERMETIC;
    let dir = cmux_unix_socket::short_test_dir("amx-hofv");
    let home = dir.path();
    let socket = home.join("s.sock");
    config(home, &["list"]);
    let (mut child, _) = start(daemon_env::acpmux(home), home, &socket);
    let answer = call(dial(&socket), "_acpmux/shutdown", restart_request())
        .expect("the restart request was answered")
        .unwrap_or_else(|e| panic!("refused: {e}"));
    assert!(answer.get("handoff").is_none(), "{answer}");
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "the daemon did not exit after the restart request");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(status.success(), "{status:?}");
    assert!(!socket.exists(), "the stop left its socket");
}
