//! An `ssh://` peer reads the remote daemon's peer token over ssh before it
//! connects (`peer.rs` `remote_tokens`). A remote daemon that restarts binds
//! its listener a few seconds before it writes `run/peer.token`, and the old
//! one removes its token when it stops. A peer that reconnects inside that
//! window reads no token, and the new daemon then accepts its connection as
//! Web (`servedAs: remote`). That link held every prompt to the Web's rules
//! until the next disconnect: a coordinator's `acpmux send air-blue/LANE`
//! to a Claude chat the Mac started was refused with "This chat runs with
//! your Mac's Claude permissions" (2026-10-22). The peer reads again while
//! the remote has no token, and a connection served as Web reconnects once
//! the remote has a token it did not present (it restarted in between).
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

/// What the stand-in `ssh`'s token reads find on the remote.
#[derive(Clone, Copy)]
enum Reads {
    /// No token on the first read, the real one after: the remote starting.
    Late,
    /// The previous run's token on the first read, the real one after: the
    /// remote restarted between the read and the handshake.
    Stale,
    /// The previous run's token on the first read, none on the second, the
    /// real one after: the remote restarted between the read and the
    /// handshake and had not written its new token when it was read again.
    Gap,
    /// No token on the first read or its three rereads, the real one
    /// after: the remote wrote it after the peer's last read before the
    /// connect.
    AfterHandshake,
    /// Never a token: a remote too old to make one.
    Never,
}

/// A stand-in `ssh` for one remote daemon at `remote`: `-W 127.0.0.1:PORT`
/// carries stdio to that port; any other call is the token read, answered
/// with the remote's config and a token as `reads` says. Each read is
/// counted in `dir/reads`.
fn fake_ssh(dir: &Path, remote: &Path, reads: Reads) {
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
mode = {mode}
out = open(os.path.join(home, "config.json"), "rb").read() + b"\0"
if mode == "never" or (mode == "late" and n == 0) or (mode == "gap" and n == 1) or (mode == "after" and n < 5):
    os.write(1, out)
    sys.exit(1)
if mode in ("stale", "gap") and n == 0:
    out += b"0" * 64
else:
    out += open(os.path.join(home, "run", "peer.token"), "rb").read()
os.write(1, out)
"#,
        home = daemon_env::sh_quote(remote.display()).replace('\'', "\""),
        dir = daemon_env::sh_quote(dir.display()).replace('\'', "\""),
        mode = match reads {
            Reads::Late => "\"late\"",
            Reads::Stale => "\"stale\"",
            Reads::Gap => "\"gap\"",
            Reads::AfterHandshake => "\"after\"",
            Reads::Never => "\"never\"",
        },
    );
    let path = dir.join("ssh");
    std::fs::write(&path, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A remote daemon, a peer of it through the stand-in `ssh`, and the
/// stand-in's directory (its `reads` count).
struct Pair {
    local: Daemon,
    _remote: Daemon,
    dir: PathBuf,
}

impl Drop for Pair {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Pair {
    fn start(tag: &str, reads: Reads) -> Self {
        let remote = start(&format!("{tag}-remote"), json!({}), true, None);
        let port = remote.listen.as_deref().unwrap().rsplit(':').next().unwrap().to_owned();
        let dir = std::env::temp_dir().join(format!("ptr-{tag}-ssh-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        fake_ssh(&dir, &remote.home, reads);
        let local = start(
            &format!("{tag}-local"),
            json!({"peers": {"box": {"url": format!("ssh://box.invalid:{port}")}}}),
            false,
            Some(&dir),
        );
        Self { local, _remote: remote, dir }
    }

    fn peer(&self) -> Value {
        unix(&self.local.home, "_acpmux/peers", json!({}))["result"]["peers"][0].clone()
    }

    fn reads(&self) -> u32 {
        std::fs::read_to_string(self.dir.join("reads"))
            .ok()
            .and_then(|n| n.trim().parse().ok())
            .unwrap_or(0)
    }

    /// The peer's summary once it is connected and its sessions arrived,
    /// served as `served_as`; panics after 60 s with the last one.
    fn wait_served_as(&self, served_as: &str) -> Value {
        let deadline = Instant::now() + Duration::from_secs(60);
        let mut last = Value::Null;
        while Instant::now() < deadline {
            last = self.peer();
            if last["state"] == json!("connected") && last["servedAs"] == json!(served_as) {
                return last;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        panic!("the peer is not served as {served_as}: {last}");
    }
}

#[test]
fn a_peer_that_read_no_token_connects_as_a_peer_once_the_remote_has_one() {
    let pair = Pair::start("late", Reads::Late);
    pair.wait_served_as("peer");
}

#[test]
fn a_peer_that_presented_a_stale_token_reconnects_as_a_peer() {
    let pair = Pair::start("stale", Reads::Stale);
    pair.wait_served_as("peer");
}

#[test]
fn a_peer_whose_stale_token_vanished_reconnects_once_the_new_one_is_written() {
    let pair = Pair::start("gap", Reads::Gap);
    pair.wait_served_as("peer");
}

#[test]
fn a_peer_whose_remote_writes_its_token_after_the_handshake_reconnects_as_a_peer() {
    let pair = Pair::start("after", Reads::AfterHandshake);
    pair.wait_served_as("peer");
}

#[test]
fn a_remote_with_no_token_stays_remote_after_a_bounded_number_of_reads() {
    let pair = Pair::start("never", Reads::Never);
    let first = pair.wait_served_as("remote");
    // The first read and three rereads before the connect, one after the
    // handshake and three more (1 + 2 + 4 s) before the link is admitted;
    // then the link stays up with no more reads.
    assert_eq!(pair.reads(), 8, "reads before the link is admitted");
    std::thread::sleep(Duration::from_secs(5));
    let later = pair.peer();
    assert_eq!(later["state"], json!("connected"), "{later}");
    assert_eq!(later["attempts"], first["attempts"], "the link did not reconnect: {later}");
    assert_eq!(pair.reads(), 8, "reads of a remote with no token");
}

/// Both the config read and a configured-token tunnel preserve the SSH failure class.
#[test]
fn ssh_failures_reach_host_ls_without_remote_output_or_credentials() {
    for (index, (diagnostic, expected)) in [
        ("ssh: Could not resolve hostname example.invalid: Name or service not known", "DNS"),
        ("user@example.invalid: Permission denied (publickey).", "Permission denied"),
        ("Host key verification failed.", "Host key verification failed"),
        ("ssh: connect to host example.invalid port 22: Connection timed out", "timed out"),
    ]
    .into_iter()
    .enumerate()
    {
        for configured in [false, true] {
            let tag = format!("ssh-reason-{index}-{configured}");
            let dir = cmux_unix_socket::short_test_dir("acpmux-ssh-reason");
            let script = dir.path().join("ssh");
            std::fs::write(&script, format!(
                "#!/usr/bin/env python3\nimport sys\nsys.stderr.write({diagnostic:?} + '\\nsecret-do-not-publish\\n')\nsys.exit(255)\n"
            )).unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
            let daemon = start(&tag, json!({}), false, Some(dir.path()));
            let mut params = json!({"name":"box", "url":"ssh://box.invalid", "wait":true});
            if configured {
                params["token"] = json!("dummy");
                params["peerToken"] = json!("a".repeat(64));
            }
            let added = unix(&daemon.home, "_acpmux/peer_add", params);
            assert!(added.get("error").is_none(), "{added}");
            let listing = daemon_env::acpmux(&daemon.home)
                .env("ACPMUX_HOME", &daemon.home)
                .env("ACPMUX_SOCKET", daemon.home.join("s.sock"))
                .args(["host", "ls"])
                .output()
                .unwrap();
            assert!(listing.status.success(), "host ls failed");
            let text = String::from_utf8_lossy(&listing.stdout);
            assert!(text.contains(expected), "missing {expected}: {text}");
            assert!(!text.contains("secret-do-not-publish"), "untrusted stderr leaked");
        }
    }
}

/// Cached parking applies on boot, but an explicit reconnect of a never-reached host
/// (lastSeen=null) still runs now. Both wait=true calls settle without waiting an hour.
#[tokio::test(start_paused = true)]
async fn cached_hourly_retry_survives_boot_and_manual_reconnect_is_immediate() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-park-boot");
    let mut config = acpmux::config::Config::default();
    config.store.mode = acpmux::config::StoreMode::Local;
    let store = acpmux::store::open(&config.store, dir.path()).unwrap();
    let hub = acpmux::hub::Hub::new(config, store);
    let now = acpmux::store::now_ms();
    std::fs::create_dir_all(dir.path().join("peers")).unwrap();
    std::fs::write(
        dir.path().join("peers/absent.json"),
        json!({
            "lastSeen": null, "downSince": now - 86_400_001,
            "nextRetryAt": now + 3_600_000, "sessions": []
        })
        .to_string(),
    )
    .unwrap();
    tokio::time::timeout(Duration::from_secs(1), hub.add_peer("absent", "ws://", None, None, true))
        .await
        .expect("parked boot settles now")
        .unwrap();
    let boot_attempts = hub.peers()[0]["attempts"].as_u64().unwrap();
    tokio::time::timeout(Duration::from_secs(1), hub.reconnect_peer("absent", true))
        .await
        .expect("explicit reconnect settles now")
        .unwrap();
    let manual_attempts = hub.peers()[0]["attempts"].as_u64().unwrap();
    hub.remove_peer("absent").await.unwrap();
    assert_eq!(boot_attempts, 0, "automatic boot must honor the cached hourly retry");
    assert_eq!(
        manual_attempts, 1,
        "manual reconnect bypasses the saved wait, even without lastSeen"
    );
}
