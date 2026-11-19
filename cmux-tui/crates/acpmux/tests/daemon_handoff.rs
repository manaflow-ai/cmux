//! A restart nobody notices (`acpmux.v2` `start`, `daemon/handoff.rs`): `_acpmux/shutdown
//! {restart: true}` execs the installed build in place. The same pid serves again with the same
//! listening socket (its inode unchanged) and the same WebSocket listener, a dial during the
//! restart waits in the kept socket's backlog instead of being refused, and the status counts the
//! restarts. A build at the installed path that fails its check leaves the daemon serving and the
//! request answered with why. Without `start` the request exits the process as before. The real
//! binary, on Unix.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

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

/// `daemon run` of `cmd` in `home`, ready: its stdout (the ready line, then its log) drained on
/// a thread so a full pipe never holds it.
fn start(mut cmd: Command, home: &Path, socket: &Path) -> (Child, Value) {
    cmd.args([
        "daemon",
        "run",
        "--memory",
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
        let mut sink = String::new();
        while stdout.read_line(&mut sink).is_ok_and(|n| n > 0) {
            sink.clear();
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
        let answer = call(dial(&socket), "_acpmux/shutdown", restart_request())
            .expect("the restart request was answered")
            .unwrap_or_else(|e| panic!("restart {n} refused: {e}"));
        assert_eq!(answer["handoff"], true, "restart {n}: {answer}");
        // Dialed during the handoff: never refused; answered by the new image (or ended by the
        // old one in its last moment, and then answered on the next dial).
        std::thread::sleep(Duration::from_millis(100));
        let during = dial(&socket);
        if let Some(reply) = call(during, "_acpmux/status", json!({})) {
            let status = reply.unwrap_or_else(|e| panic!("restart {n}: status refused: {e}"));
            assert_eq!(status["handoffs"], n, "restart {n}: answered by the old image: {status}");
        }
        let status = status_after(&socket, Duration::from_secs(30), |s| s["handoffs"] == n);
        assert_eq!(status["pid"].as_u64(), Some(pid), "restart {n}: {status}");
        assert_eq!(status["listen"], listen, "restart {n}: {status}");
        assert_eq!(inode(&socket), socket_id, "restart {n}: the socket was bound again");
        assert!(child.try_wait().unwrap().is_none(), "restart {n}: the daemon process exited");
    }
    stop(child);
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
