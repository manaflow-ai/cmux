//! A machine whose peer link is down, reached over a plain ssh login instead (`src/server/
//! ssh_carry.rs`, `src/cli/ls_ssh.rs`), against two real daemons: machine A has machine B as the
//! `ssh://` peer `box`, and a stand-in `ssh` on A's PATH refuses every tunnel (the link stays
//! down) while it runs any other login's command on "B" (its `$HOME/.local/bin/acpmux` is B's
//! CLI). A send to `box/lane-x` is delivered over ssh once and not again when the link comes
//! back; `acpmux ls` lists B's sessions read over ssh; an ssh that cannot log in leaves the
//! delivery queued, as before, until it can. Leo, 2026-11-20: "bolstering connectivity and
//! being able to move between machines".
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Output, Stdio};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-sf-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

fn write_exe(path: &Path, text: &str) {
    fs::write(path, text).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A daemon in `home` with `config`, listening on loopback when `listen`, with `path` first on
/// its PATH. Ended (and its home removed) when dropped.
struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    port: Option<String>,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = fs::remove_dir_all(&self.home);
    }
}

fn start(home: PathBuf, config: Value, listen: bool, path: Option<&Path>) -> Daemon {
    fs::write(home.join("config.json"), config.to_string()).unwrap();
    fs::set_permissions(home.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
    let mut cmd = daemon_env::command(&home, daemon_env::Agents::StandIn, &[]);
    cmd.args(["daemon", "run", "--ready-fd", "1", "--log", "info", "--memory"]);
    if listen {
        cmd.args(["--listen", "127.0.0.1:0"]);
    }
    if let Some(dir) = path {
        cmd.env("PATH", format!("{}:{}", dir.display(), daemon_env::bare_path(&[])));
    }
    let log = fs::File::create(home.join("daemon.log")).unwrap();
    let mut child = cmd
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(home.join("p"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(log)
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    // The daemon logs to its stdout (`log_sink.rs`): every line goes to `daemon.log` too, where
    // `Pair::log` reads it.
    let mut kept = fs::OpenOptions::new().append(true).open(home.join("daemon.log")).unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = writeln!(kept, "{line}");
            if line.starts_with('{') {
                let _ = tx.send(line);
            }
        }
    });
    let ready: Value =
        serde_json::from_str(&rx.recv_timeout(Duration::from_secs(30)).expect("daemon ready"))
            .unwrap();
    let port = ready["listen"].as_str().and_then(|l| l.rsplit(':').next()).map(str::to_owned);
    Daemon { child: Some(child), home, port }
}

fn cli(home: &Path, args: &[&str]) -> Output {
    cli_on(home, None, args)
}

/// `cli` with `path` first on its PATH: `acpmux ls` reads a down peer over ssh itself
/// (`cli/ls_ssh.rs`), so it needs the stand-in `ssh` the daemon has.
fn cli_on(home: &Path, path: Option<&Path>, args: &[&str]) -> Output {
    let mut cmd = daemon_env::command(home, daemon_env::Agents::StandIn, &[]);
    if let Some(dir) = path {
        cmd.env("PATH", format!("{}:{}", dir.display(), daemon_env::bare_path(&[])));
    }
    cmd.args(args)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("ACPMUX_FROM")
        .env_remove("ACPMUX_SESSION_ID")
        .current_dir(home.join("p"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    cmd.output().unwrap()
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

fn json_of(o: &Output) -> Value {
    serde_json::from_slice(&o.stdout).unwrap_or(Value::Null)
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

/// Polls `f` every 200 ms until it answers Some, or panics with `what` after `secs`.
fn within<T>(secs: u64, what: &str, mut f: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(Instant::now() < deadline, "{what}: not within {secs} s");
        std::thread::sleep(Duration::from_millis(200));
    }
}

/// The stand-in `ssh`: a tunnel (`-W`) is refused until `dir/up` exists, then carried to B's
/// port; a login whose command looks for acpmux is counted in `dir/calls` (`carry` or `ls`) and
/// run by `/bin/sh` with `HOME` = `dir/remote-home`, unless `dir/fail` exists (refused as a host
/// that does not answer); any other login is the peer's token read, answered with B's config
/// and peer token.
fn fake_ssh(dir: &Path, remote: &Path) {
    let q = |p: &Path| daemon_env::sh_quote(p.display()).replace('\'', "\"");
    let script = format!(
        r#"#!/usr/bin/env python3
import os, socket, sys, threading
d = {dir}
args = sys.argv[1:]
def refuse():
    sys.stderr.write("ssh: connect to host box.invalid port 22: Connection refused\n")
    sys.exit(255)
if "-W" in args:
    if not os.path.exists(os.path.join(d, "up")):
        refuse()
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
command = args[-1]
if ".local/bin/acpmux" in command:
    kind = "carry" if " send " in command else "ls"
    with open(os.path.join(d, "calls"), "a") as f:
        f.write(kind + "\n")
    if os.path.exists(os.path.join(d, "fail")):
        refuse()
    env = dict(os.environ, HOME=os.path.join(d, "remote-home"))
    os.execve("/bin/sh", ["/bin/sh", "-c", command], env)
home = {home}
out = open(os.path.join(home, "config.json"), "rb").read() + b"\0"
out += open(os.path.join(home, "run", "peer.token"), "rb").read()
os.write(1, out)
"#,
        dir = q(dir),
        home = q(remote),
    );
    write_exe(&dir.join("ssh"), &script);
    // B's CLI, where the far login looks for acpmux first.
    let bin = dir.join("remote-home/.local/bin");
    fs::create_dir_all(&bin).unwrap();
    write_exe(
        &bin.join("acpmux"),
        &format!(
            "#!/bin/sh\nexec env -u ACPMUX_FROM -u ACPMUX_SESSION_ID ACPMUX_HOME={b} ACPMUX_SOCKET={sock} ACPMUX_LOGIN_ENV=0 {exe} \"$@\"\n",
            b = daemon_env::sh_quote(remote.display()),
            sock = daemon_env::sh_quote(remote.join("s.sock").display()),
            exe = daemon_env::sh_quote(daemon_env::bin().display()),
        ),
    );
}

/// Machine B (listening, with the stand-in agent's session `lane-x`) and machine A, whose peer
/// `box` is B over the stand-in ssh, its link down.
struct Pair {
    a: Daemon,
    b: Daemon,
    dir: PathBuf,
}

impl Drop for Pair {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

impl Pair {
    fn start(tag: &str) -> Self {
        let _ = &HERMETIC;
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let b = start(
            scratch(&format!("{tag}b")),
            json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
                   "permissionPolicy": "approve-all"}),
            true,
            None,
        );
        let made = cli(&b.home, &["run", "-n", "lane-x", "warm up"]);
        assert!(made.status.success(), "machine B's session: {}", text(&made));
        let dir = scratch(&format!("{tag}s"));
        fake_ssh(&dir, &b.home);
        let url = format!("ssh://box.invalid:{}", b.port.as_deref().expect("B listens"));
        let a = start(
            scratch(&format!("{tag}a")),
            json!({"peers": {"box": {"url": url}}}),
            false,
            Some(&dir),
        );
        let pair = Self { a, b, dir };
        // The peer is added and dialed after the daemon is ready: wait until its first connect
        // attempt failed, so the link is known down before the test sends or lists.
        within(60, "peer box listed and its first dial refused", || {
            let peer = unix(&pair.a.home, "_acpmux/peers", json!({}))["result"]["peers"][0].clone();
            (peer["name"] == "box"
                && !matches!(peer["state"].as_str(), Some("connected" | "connecting") | None))
            .then_some(())
        });
        pair
    }

    fn calls(&self, kind: &str) -> usize {
        fs::read_to_string(self.dir.join("calls"))
            .unwrap_or_default()
            .lines()
            .filter(|l| *l == kind)
            .count()
    }

    fn turns(&self) -> u64 {
        json_of(&cli(&self.b.home, &["--json", "info", "lane-x"]))["turnCount"]
            .as_u64()
            .unwrap_or(0)
    }

    fn status(&self, id: &str) -> Value {
        json_of(&cli(&self.a.home, &["--json", "send", "--status", id]))
    }

    fn send(&self, message: &str) -> String {
        let sent = cli(&self.a.home, &["--json", "send", "--no-wait", "box/lane-x", message]);
        assert!(sent.status.success(), "{}", text(&sent));
        json_of(&sent)["deliveryId"].as_str().expect("a delivery id").to_owned()
    }

    fn peer_state(&self) -> Value {
        unix(&self.a.home, "_acpmux/peers", json!({}))["result"]["peers"][0]["state"].clone()
    }

    fn log(&self) -> String {
        fs::read_to_string(self.a.home.join("daemon.log")).unwrap_or_default()
    }
}

#[test]
fn a_send_to_a_down_ssh_peer_is_delivered_once_over_ssh_and_not_again_on_reconnect() {
    let pair = Pair::start("once");
    let before = within(30, "B's warm-up turn", || Some(pair.turns()).filter(|n| *n >= 1));
    assert_ne!(pair.peer_state(), json!("connected"));
    let id = pair.send("hello over ssh");
    let delivered = within(40, "delivered over ssh", || {
        let v = pair.status(&id);
        (v["status"] == "delivered").then_some(v)
    });
    assert_eq!(delivered["accepted"]["via"], "ssh", "{delivered}");
    assert_eq!(delivered["accepted"]["host"], "box", "{delivered}");
    assert!(delivered["accepted"]["sshDeliveryId"].is_string(), "{delivered}");
    within(30, "B ran the message", || Some(()).filter(|_| pair.turns() > before));
    assert_eq!(pair.calls("carry"), 1);
    let log = pair.log();
    assert!(log.contains("ssh carry") && log.contains(&id), "{log}");

    // The link comes back: nothing is sent to B again.
    fs::write(pair.dir.join("up"), "").unwrap();
    within(60, "the link is back", || Some(()).filter(|_| pair.peer_state() == "connected"));
    std::thread::sleep(Duration::from_secs(5));
    assert_eq!(pair.turns(), before + 1, "B ran it once");
    assert_eq!(pair.calls("carry"), 1);
    assert_eq!(pair.status(&id)["status"], "delivered");
}

#[test]
fn ls_lists_a_down_ssh_peers_sessions_read_over_ssh() {
    let pair = Pair::start("ls");
    assert_ne!(pair.peer_state(), json!("connected"));
    let listed = cli_on(&pair.a.home, Some(&pair.dir), &["--json", "ls"]);
    assert!(listed.status.success(), "{}", text(&listed));
    let rows = json_of(&listed);
    let row = rows["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["peer"] == "box" && r["name"] == "box/lane-x")
        .unwrap_or_else(|| panic!("no box/lane-x: {rows}"))
        .clone();
    assert_eq!(row["via"], "ssh", "{row}");
    assert_eq!(pair.calls("ls"), 1);
    let table = cli_on(&pair.a.home, Some(&pair.dir), &["ls"]);
    assert!(String::from_utf8_lossy(&table.stdout).contains("lane-x"), "{}", text(&table));
}

#[test]
fn an_ssh_that_cannot_log_in_leaves_the_delivery_queued_until_it_can() {
    let pair = Pair::start("fail");
    let before = within(30, "B's warm-up turn", || Some(pair.turns()).filter(|n| *n >= 1));
    fs::write(pair.dir.join("fail"), "").unwrap();
    let id = pair.send("hello when ssh works");
    let queued = within(30, "an ssh carry tried and refused", || {
        let v = pair.status(&id);
        (pair.calls("carry") >= 1 && v["error"].as_str().is_some_and(|e| e.contains("ssh carry")))
            .then_some(v)
    });
    assert!(matches!(queued["status"].as_str(), Some("queued" | "delivering")), "{queued}");
    assert_eq!(pair.turns(), before, "nothing reached B");
    // ssh works again: the next attempt carries it.
    fs::remove_file(pair.dir.join("fail")).unwrap();
    let delivered = within(60, "delivered once ssh works", || {
        let v = pair.status(&id);
        (v["status"] == "delivered").then_some(v)
    });
    assert_eq!(delivered["accepted"]["via"], "ssh", "{delivered}");
    within(30, "B ran the message", || Some(()).filter(|_| pair.turns() > before));
}
