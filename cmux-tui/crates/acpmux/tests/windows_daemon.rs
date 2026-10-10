//! acpmux on Windows, through its CLI and its socket only: the daemon binds
//! its `cmux::local_socket` socket and answers `acpmux status`, a second
//! daemon on the same home stops at the start lock, the first start saves a
//! random WebSocket token, `acpmux shutdown` stops it and removes the socket,
//! and a peer of another user is refused by the daemon and by the CLI.
#![cfg(windows)]

use serde_json::Value;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amxw-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn acpmux(exe: &Path, home: &Path) -> Command {
    let mut cmd = Command::new(exe);
    cmd.env("ACPMUX_HOME", home)
        .env("ACPMUX_CATALOG_FETCH", "0")
        .env("ACPMUX_REGISTRY_FETCH", "0")
        .env_remove("ACPMUX_SOCKET")
        .env_remove("ACPMUX_LOCAL_ROUTER")
        .stdin(Stdio::null());
    cmd
}

fn exe() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_acpmux"))
}

/// A daemon this test started; killed if the test ends early.
struct Daemon {
    child: Child,
    log: PathBuf,
}

impl Daemon {
    fn start(exe: &Path, home: &Path, log: PathBuf) -> Self {
        // Its log lines go to stdout, its errors to stderr: both to `log`.
        let out = std::fs::File::create(&log).unwrap();
        let err = out.try_clone().unwrap();
        let child = acpmux(exe, home)
            .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--log", "info"])
            .stdout(out)
            .stderr(err)
            .spawn()
            .expect("spawn acpmux daemon run");
        Self { child, log }
    }

    fn log(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn status(exe: &Path, home: &Path) -> Value {
    let out = acpmux(exe, home).args(["--json", "status"]).output().expect("run acpmux status");
    assert!(out.status.success(), "acpmux status failed: {}", text(&out));
    serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("status JSON: {e}: {}", text(&out)))
}

fn text(out: &Output) -> String {
    format!(
        "exit {:?}\nstdout: {}\nstderr: {}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

/// `acpmux status` until the daemon with `pid` answers it over the socket.
fn wait_ready(exe: &Path, home: &Path, daemon: &mut Daemon) -> Value {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        if let Some(code) = daemon.child.try_wait().unwrap() {
            panic!("the daemon exited ({code}) before it was ready:\n{}", daemon.log());
        }
        let v = status(exe, home);
        if v.get("pid").and_then(Value::as_u64) == Some(u64::from(daemon.child.id())) {
            return v;
        }
        assert!(
            Instant::now() < deadline,
            "the daemon never answered status: {v}\n{}",
            daemon.log()
        );
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[test]
fn the_daemon_serves_its_socket_holds_its_lock_and_stops() {
    let exe = exe();
    let home = scratch("life");
    // No daemon yet: status says so and starts none.
    let v = status(&exe, &home);
    assert_eq!(v.get("running"), Some(&Value::Bool(false)), "{v}");

    let log = std::env::temp_dir().join(format!("amxw-life-{}.log", std::process::id()));
    let mut daemon = Daemon::start(&exe, &home, log);
    let v = wait_ready(&exe, &home, &mut daemon);
    let socket = home.join("acpmux.sock");
    assert_eq!(v.get("socket").and_then(Value::as_str), Some(socket.to_str().unwrap()), "{v}");
    assert!(std::fs::symlink_metadata(&socket).is_ok(), "no socket file at {}", socket.display());

    // The first start saved a random 48-hex WebSocket token.
    let config: Value =
        serde_json::from_str(&std::fs::read_to_string(home.join("config.json")).unwrap()).unwrap();
    let token = config.pointer("/websocket/token").and_then(Value::as_str).unwrap_or_default();
    assert!(
        token.len() == 48 && token.bytes().all(|b| b.is_ascii_hexdigit()),
        "saved token is not 48 hex characters: {token:?}"
    );

    // The raw socket speaks newline-delimited JSON-RPC.
    let mut stream = cmux::local_socket::connect_same_user(&socket).expect("connect");
    stream
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"_acpmux/status\",\"params\":{}}\n")
        .unwrap();
    let line = read_line(&mut stream, Duration::from_secs(30));
    let reply: Value = serde_json::from_str(&line).unwrap_or_else(|e| panic!("{e}: {line}"));
    assert_eq!(reply.get("id"), Some(&Value::from(7)), "{reply}");
    assert_eq!(
        reply.pointer("/result/pid").and_then(Value::as_u64),
        Some(u64::from(daemon.child.id())),
        "{reply}"
    );
    drop(stream);

    // A second daemon on the same home stops at the start lock.
    let second = acpmux(&exe, &home)
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0"])
        .output()
        .expect("run a second daemon");
    assert!(!second.status.success(), "a second daemon started: {}", text(&second));
    assert!(
        String::from_utf8_lossy(&second.stderr).contains("another acpmux daemon holds"),
        "the second daemon did not stop at the lock: {}",
        text(&second)
    );
    // The first one still serves.
    let v = status(&exe, &home);
    assert_eq!(v.get("pid").and_then(Value::as_u64), Some(u64::from(daemon.child.id())), "{v}");

    // `acpmux shutdown` stops it and removes the socket.
    let out = acpmux(&exe, &home).arg("shutdown").output().expect("run acpmux shutdown");
    assert!(out.status.success(), "acpmux shutdown failed: {}", text(&out));
    let deadline = Instant::now() + Duration::from_secs(30);
    let code = loop {
        if let Some(code) = daemon.child.try_wait().unwrap() {
            break code;
        }
        assert!(Instant::now() < deadline, "the daemon did not stop:\n{}", daemon.log());
        std::thread::sleep(Duration::from_millis(100));
    };
    assert!(code.success(), "the daemon exited with {code}:\n{}", daemon.log());
    assert!(std::fs::symlink_metadata(&socket).is_err(), "the socket file stayed");
    let v = status(&exe, &home);
    assert_eq!(v.get("running"), Some(&Value::Bool(false)), "{v}");
    let _ = std::fs::remove_dir_all(&home);
}

/// One line from `stream`, within `timeout`.
fn read_line(stream: &mut cmux::local_socket::Stream, timeout: Duration) -> String {
    stream.set_read_timeout(Some(timeout)).unwrap();
    let mut bytes = Vec::new();
    let mut byte = [0u8; 1];
    while stream.read(&mut byte).expect("read a reply line") == 1 && byte[0] != b'\n' {
        bytes.push(byte[0]);
    }
    String::from_utf8(bytes).unwrap()
}

/// Shared with the LocalService peer: a folder both users may enter (the
/// hosted step makes it and grants Everyone access).
const OTHER_USER_DIR: &str = r"C:\amx-peer";

/// The daemon runs as this user; a peer of another user (LocalService, from
/// a scheduled task the hosted step starts) connects twice: `acpmux status`
/// refuses the socket because another user owns it, and a raw connect that
/// skips that check is closed by the daemon before any reply.
#[test]
#[ignore = "hosted Windows runner only: the step starts the LocalService peer"]
fn other_user_peer_is_refused() {
    let dir = Path::new(OTHER_USER_DIR);
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    // The peer runs this copy: the build folder may be closed to it.
    let peer_exe = dir.join("acpmux.exe");
    std::fs::copy(exe(), &peer_exe).unwrap();
    let mut daemon = Daemon::start(&exe(), &home, dir.join("daemon.log"));
    wait_ready(&exe(), &home, &mut daemon);
    std::fs::write(dir.join("ready"), b"1").unwrap();
    let done = dir.join("child-done");
    let deadline = Instant::now() + Duration::from_secs(90);
    while !done.exists() {
        assert!(
            Instant::now() < deadline,
            "the LocalService peer never finished:\n{}",
            daemon.log()
        );
        std::thread::sleep(Duration::from_millis(200));
    }
    let child = std::fs::read_to_string(&done).unwrap();
    assert!(child.contains("cli: refused"), "the CLI used another user's socket: {child}");
    assert!(child.contains("raw: closed"), "the daemon answered another user: {child}");
    let log = daemon.log();
    assert!(
        log.contains("refused: owned by or running as another user"),
        "the daemon did not log the refusal:\n{log}"
    );
}

/// The LocalService peer's body (run by the hosted step's scheduled task).
#[test]
#[ignore = "run by the hosted runner's LocalService scheduled task"]
fn other_user_child() {
    let dir = Path::new(OTHER_USER_DIR);
    let home = dir.join("home");
    let socket = home.join("acpmux.sock");
    let identity = cmux::local_socket::win::current_identity().unwrap();
    let mut report = format!("user: {}\n", identity.user_sid);
    let out = Command::new(dir.join("acpmux.exe"))
        .args(["--json", "status"])
        .env("ACPMUX_HOME", &home)
        .env_remove("ACPMUX_SOCKET")
        .output();
    match out {
        // The daemon runs, so "not running" is the CLI's refusal of a
        // socket file another user owns.
        Ok(out) => match serde_json::from_slice::<Value>(&out.stdout) {
            Ok(v) if v.get("running") == Some(&Value::Bool(false)) => {
                report.push_str(&format!("cli: refused ({})\n", v["error"]));
            }
            _ => report.push_str(&format!("cli: unexpected: {}\n", text(&out))),
        },
        Err(e) => report.push_str(&format!("cli: did not run: {e}\n")),
    }
    match cmux::local_socket::connect(&socket) {
        Ok(mut stream) => {
            let _ = stream.write_all(
                b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"_acpmux/status\",\"params\":{}}\n",
            );
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let mut buf = [0u8; 256];
            match stream.read(&mut buf) {
                Ok(0) | Err(_) => report.push_str("raw: closed\n"),
                Ok(n) => report
                    .push_str(&format!("raw: answered: {}\n", String::from_utf8_lossy(&buf[..n]))),
            }
        }
        Err(e) => report.push_str(&format!("raw: connect failed: {e}\n")),
    }
    std::fs::write(dir.join("child-done"), report).unwrap();
}
