//! An `ssh://` peer dials the port the remote daemon's listener record names
//! and proves that listener before it sends a token (`peer.rs`
//! `prove_tunnel`, `listener_record.rs`).
//!
//! Found on a shared Linux host (2026-11-10): `cmux setup machine` added a
//! second account's daemon, whose configured port 47811 was already taken by
//! the first account's daemon, so it moved to a free port. The peer kept
//! dialing 47811 and sent the new account's dashboard and peer tokens to the
//! other account's daemon, which refused them (401); the setup still said
//! `changed`. Any process that holds the URL's port got the tokens.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    listen: Option<String>,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

fn start(tag: &str, config: Value, listen: bool, path: Option<&Path>) -> Daemon {
    let home = std::env::temp_dir().join(format!("plp-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
    let mut cmd = daemon_env::acpmux(&home);
    cmd.args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"]);
    if listen {
        cmd.args(["--listen", "127.0.0.1:0"]);
    }
    if let Some(dir) = path {
        cmd.env("PATH", format!("{}:{}", dir.display(), daemon_env::bare_path(&[])));
    }
    let mut child = cmd
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if line.starts_with('{') {
                let _ = tx.send(line);
            }
        }
    });
    let mut d = Daemon { child: Some(child), home, listen: None };
    let ready: Value =
        serde_json::from_str(&rx.recv_timeout(Duration::from_secs(20)).expect("daemon ready"))
            .unwrap();
    d.listen = ready["listen"].as_str().map(str::to_owned);
    d
}

fn unix(home: &Path, method: &str, params: Value) -> Value {
    let mut s = std::os::unix::net::UnixStream::connect(home.join("s.sock")).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    writeln!(s, "{}", json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
        .unwrap();
    let mut reader = BufReader::new(s);
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v;
        }
    }
}

/// Another process on a loopback port: it keeps every byte it is sent and
/// answers each request head with a 401, as another account's daemon does.
struct Squatter {
    port: u16,
    heard: Arc<Mutex<Vec<u8>>>,
}

impl Squatter {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let heard: Arc<Mutex<Vec<u8>>> = Arc::default();
        let keep = heard.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let keep = keep.clone();
                std::thread::spawn(move || {
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                    let mut seen = Vec::new();
                    let mut buf = [0u8; 4096];
                    while let Ok(n) = stream.read(&mut buf) {
                        if n == 0 {
                            break;
                        }
                        seen.extend_from_slice(&buf[..n]);
                        keep.lock().unwrap().extend_from_slice(&buf[..n]);
                        if seen.windows(4).any(|w| w == b"\r\n\r\n") {
                            let _ = stream.write_all(
                                b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n",
                            );
                            break;
                        }
                    }
                });
            }
        });
        Self { port, heard }
    }

    fn heard(&self) -> String {
        String::from_utf8_lossy(&self.heard.lock().unwrap()).into_owned()
    }
}

/// A stand-in `ssh` for the remote account whose acpmux home is `remote`:
/// `-W 127.0.0.1:PORT` carries stdio to that port; any other call is the
/// token read, answered from `remote` as `read_config_argv`'s command does
/// (config, NUL, peer token, NUL, listener record).
fn fake_ssh(dir: &Path, remote: &Path) {
    let script = format!(
        r#"#!/usr/bin/env python3
import os, socket, sys, threading
args = sys.argv[1:]
if "-W" in args:
    host, port = args[args.index("-W") + 1].rsplit(":", 1)
    s = socket.create_connection((host, int(port)))
    def up():
        while True:
            b = os.read(0, 65536)
            if not b:
                break
            s.sendall(b)
        s.shutdown(socket.SHUT_WR)
    threading.Thread(target=up, daemon=True).start()
    while True:
        b = s.recv(65536)
        if not b:
            break
        os.write(1, b)
    sys.exit(0)
home = {home}
def read(*p):
    try:
        return open(os.path.join(home, *p), "rb").read()
    except OSError:
        return b""
os.write(1, read("config.json") + b"\0" + read("run", "peer.token") + b"\0" + read("listener.json"))
"#,
        home = daemon_env::sh_quote(remote.display()).replace('\'', "\""),
    );
    let path = dir.join("ssh");
    std::fs::write(&path, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn ssh_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("plp-{tag}-ssh-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn peer(local: &Daemon) -> Value {
    unix(&local.home, "_acpmux/peers", json!({}))["result"]["peers"][0].clone()
}

/// The URL names the squatter's port (the default port another account's
/// daemon holds); the remote daemon listens elsewhere and records it. The
/// peer connects to the remote daemon as a peer, and the squatter is sent
/// no token.
#[test]
fn a_peer_dials_the_recorded_listener_and_never_sends_a_token_to_the_urls_port() {
    let squatter = Squatter::start();
    let remote = start("moved-remote", json!({}), true, None);
    let dir = ssh_dir("moved");
    fake_ssh(&dir, &remote.home);
    let local = start(
        "moved-local",
        json!({"peers": {"box": {"url": format!("ssh://box.invalid:{}", squatter.port)}}}),
        false,
        Some(&dir),
    );
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut last = Value::Null;
    while Instant::now() < deadline {
        last = peer(&local);
        if last["state"] == json!("connected") && last["servedAs"] == json!("peer") {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    assert_eq!(last["state"], json!("connected"), "{last}");
    assert_eq!(last["servedAs"], json!("peer"), "{last}");
    let token =
        std::fs::read_to_string(remote.home.join("run/peer.token")).unwrap().trim().to_owned();
    let heard = squatter.heard();
    assert!(!heard.contains(&token), "the peer token went to the URL's port: {heard}");
    assert!(
        !heard.to_ascii_lowercase().contains("upgrade"),
        "an upgrade went to the URL's port: {heard}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// Both tokens are in the peer's config, so no token read is needed: the
/// record is still read, and it decides where the tokens go. The squatter on
/// the URL's port hears neither token (review of #40418, F1).
#[test]
fn configured_tokens_go_only_to_the_recorded_listener() {
    let squatter = Squatter::start();
    let remote = start("conf-remote", json!({}), true, None);
    let dir = ssh_dir("conf");
    fake_ssh(&dir, &remote.home);
    let config: Value =
        serde_json::from_slice(&std::fs::read(remote.home.join("config.json")).unwrap()).unwrap();
    let token = config["websocket"]["token"].as_str().expect("the remote's token").to_owned();
    let peer_token =
        std::fs::read_to_string(remote.home.join("run/peer.token")).unwrap().trim().to_owned();
    let url = format!("ssh://box.invalid:{}", squatter.port);
    let local = start(
        "conf-local",
        json!({"peers": {"box": {"url": url, "token": token, "peerToken": peer_token}}}),
        false,
        Some(&dir),
    );
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut last = Value::Null;
    while Instant::now() < deadline {
        last = peer(&local);
        if last["state"] == json!("connected") && last["servedAs"] == json!("peer") {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    assert_eq!(last["state"], json!("connected"), "{last}");
    assert_eq!(last["servedAs"], json!("peer"), "{last}");
    let heard = squatter.heard();
    assert!(!heard.contains(&token), "the token went to the URL's port: {heard}");
    assert!(!heard.contains(&peer_token), "the peer token went to the URL's port: {heard}");
    assert!(
        !heard.to_ascii_lowercase().contains("upgrade"),
        "an upgrade went to the URL's port: {heard}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The record names a port its daemon no longer holds (it crashed; another
/// process took the port). The peer sends that process one challenge and no
/// token, and says why it did not connect.
#[test]
fn a_listener_that_cannot_prove_the_record_is_sent_no_token() {
    let squatter = Squatter::start();
    let home = std::env::temp_dir().join(format!("plp-stale-remote-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join("run")).unwrap();
    let dashboard = "d".repeat(48);
    let peer_token = "a".repeat(64);
    std::fs::write(
        home.join("config.json"),
        json!({"websocket": {"listen": "127.0.0.1:47811", "token": dashboard}}).to_string(),
    )
    .unwrap();
    std::fs::write(home.join("run/peer.token"), &peer_token).unwrap();
    std::fs::write(
        home.join("listener.json"),
        json!({"version": 2, "listen": format!("127.0.0.1:{}", squatter.port), "pid": 1, "key": "b".repeat(64)})
            .to_string(),
    )
    .unwrap();
    let dir = ssh_dir("stale");
    fake_ssh(&dir, &home);
    let local = start(
        "stale-local",
        json!({"peers": {"box": {"url": format!("ssh://box.invalid:{}", squatter.port)}}}),
        false,
        Some(&dir),
    );
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut last = Value::Null;
    while Instant::now() < deadline {
        last = peer(&local);
        if last["error"].as_str().is_some_and(|e| e.contains("did not prove")) {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    assert!(
        last["error"].as_str().is_some_and(|e| e.contains("no token was sent")),
        "the refusal names why: {last}"
    );
    let heard = squatter.heard();
    assert!(heard.starts_with("ACPMUX-LINK/2 "), "the squatter got the challenge: {heard}");
    assert!(!heard.contains(&peer_token), "the peer token went to the squatter: {heard}");
    assert!(!heard.contains(&dashboard), "the dashboard token went to the squatter: {heard}");
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&home);
}
