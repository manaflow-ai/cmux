//! An `ssh://` peer reads the remote daemon's peer token over ssh before it
//! connects (`peer.rs` `remote_tokens`). A remote daemon that restarts binds
//! its listener a few seconds before it writes `run/peer.token`, and the old
//! one removes its token when it stops. A peer that reconnects inside that
//! window reads no token, and the new daemon then accepts its connection as
//! Web (`servedAs: remote`). That link held every prompt to the Web's rules
//! until the next disconnect: a coordinator's `acpmux send air-blue/LANE`
//! to a Claude chat the Mac started was refused with "This chat runs with
//! your Mac's Claude permissions" (2026-10-22). Served as Web while the
//! remote now has a token, the peer reconnects with it.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
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
    let home = std::env::temp_dir().join(format!("ptr-{tag}-{}", std::process::id()));
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

/// A stand-in `ssh` for one remote daemon at `remote`: `-W 127.0.0.1:PORT`
/// carries stdio to that port; any other call is the token read, answered
/// with the remote's config and, from the second read on, its peer token.
/// The first read finds no token: the window while the remote starts.
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
count = os.path.join({dir}, "reads")
n = int(open(count).read()) if os.path.exists(count) else 0
open(count, "w").write(str(n + 1))
out = open(os.path.join(home, "config.json"), "rb").read() + b"\0"
if n >= 1:
    out += open(os.path.join(home, "run", "peer.token"), "rb").read()
os.write(1, out)
sys.exit(0 if n >= 1 else 1)
"#,
        home = daemon_env::sh_quote(remote.display()).replace('\'', "\""),
        dir = daemon_env::sh_quote(dir.display()).replace('\'', "\""),
    );
    let path = dir.join("ssh");
    std::fs::write(&path, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
fn a_peer_that_read_no_token_reconnects_as_a_peer_once_the_remote_has_one() {
    let remote = start("remote", json!({}), true, None);
    let port = remote.listen.as_deref().unwrap().rsplit(':').next().unwrap().to_owned();
    let dir = std::env::temp_dir().join(format!("ptr-ssh-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    fake_ssh(&dir, &remote.home);
    let local = start(
        "local",
        json!({"peers": {"box": {"url": format!("ssh://box.invalid:{port}")}}}),
        false,
        Some(&dir),
    );
    // The first connect reads no token and is served as Web; the peer must
    // not stay that way while the remote has a token to read.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut last = Value::Null;
    while Instant::now() < deadline {
        last = unix(&local.home, "_acpmux/peers", json!({}));
        let peer = &last["result"]["peers"][0];
        if peer["connected"] == json!(true) && peer["servedAs"] == json!("peer") {
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let _ = std::fs::remove_dir_all(&dir);
    panic!("the peer is still not served as a peer: {last}");
}
