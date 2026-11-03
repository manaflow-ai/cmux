//! R-LIFECYCLE stage 1 (handoff/rewrites/R-LIFECYCLE/DESIGN.md section 7):
//! an app session's owner stops the moment its app has left and nothing else
//! keeps it, and never while a client or a live terminal does.
//!
//! The app connects with a role-main `client-hello`; this test plays that
//! client. Before the stage, the owner of `cmux-app-*` ran until reboot after
//! its app quit (STATUS 1370, 8519).

#![cfg(any(target_vendor = "apple", target_os = "linux"))]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// How long an owner may take to stop once nothing keeps it. The stop is an
/// event (the last client's departure or the last terminal's exit), so it
/// takes milliseconds; the rest is room for a loaded runner.
const STOP_BOUND: Duration = Duration::from_secs(10);

/// How long a kept owner is watched to prove it stays.
const KEPT_FOR: Duration = Duration::from_secs(3);

/// An app session owner this test started with `server ensure`, under its own
/// scratch root, with the stage's switch on.
struct Owner {
    root: PathBuf,
    session: String,
    socket: PathBuf,
    identity: Option<(u32, u64)>,
}

impl Owner {
    fn ensure(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() % 1_000_000;
        let root = PathBuf::from(format!("/tmp/okp-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(root.join("home")).unwrap();
        fs::create_dir_all(root.join("state")).unwrap();
        let mut owner = Self {
            root,
            session: format!("cmux-app-okp-{name}"),
            socket: PathBuf::new(),
            identity: None,
        };
        let output = owner
            .command()
            .args(["server", "ensure", "--terminal-reap-grace-seconds", "1"])
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout.lines().rev().find(|line| line.trim_start().starts_with('{'));
        let endpoint: serde_json::Value =
            line.and_then(|line| serde_json::from_str(line).ok()).unwrap_or_else(|| {
                panic!("ensure: {stdout} {}", String::from_utf8_lossy(&output.stderr))
            });
        let pid = endpoint["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok()).unwrap();
        let started = cmux_tui_core::server::Starter::current(pid)
            .unwrap_or_else(|| panic!("no start time for the owner {pid}"));
        owner.identity = Some((pid, started.started_ms));
        owner.socket = PathBuf::from(endpoint["socket"].as_str().unwrap());
        owner
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--session", &self.session, "--json"])
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("HOME", self.root.join("home"))
            .env("TMPDIR", &self.root)
            .env("CMUX_TUI_STATE_DIR", self.root.join("state"))
            .env("CMUX_TUI_CONFIG", self.root.join("home/no-config.toml"))
            .env("CMUX_TUI_OWNER_KEEPERS", "1");
        command
    }

    /// Whether the owner this test started still runs (its pid with its own
    /// start time, so a reused pid never counts).
    fn running(&self) -> bool {
        let (pid, started_ms) = self.identity.unwrap();
        cmux_tui_core::server::Starter::current(pid).map(|it| it.started_ms) == Some(started_ms)
    }

    /// Fails unless the owner stops within `STOP_BOUND`.
    fn assert_stops(&self, why: &str) {
        let deadline = Instant::now() + STOP_BOUND;
        while self.running() {
            assert!(
                Instant::now() < deadline,
                "the owner still ran {STOP_BOUND:?} after {why}: nothing kept it"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// Fails if the owner stops within `KEPT_FOR`.
    fn assert_kept(&self, by: &str) {
        let deadline = Instant::now() + KEPT_FOR;
        while Instant::now() < deadline {
            assert!(self.running(), "the owner stopped while {by} kept it");
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = self.command().args(["server", "stop", "--force", "--end-terminals"]).output();
        if let Some((pid, _)) = self.identity {
            if self.running() {
                // SAFETY: the owner this test started (pid and start time).
                unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            }
            let deadline = Instant::now() + Duration::from_secs(10);
            while self.running() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
            assert!(
                !self.running() || std::thread::panicking(),
                "the test's owner {pid} did not end"
            );
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// One connection to the owner, answered line by line.
struct Client {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        Self { stream, reader, next: 1 }
    }

    /// The app's connection: `client-hello` role main as its first line.
    fn app(socket: &Path) -> Self {
        let mut client = Self::connect(socket);
        let hello = client.request(serde_json::json!({"cmd": "client-hello", "role": "main"}));
        assert_eq!(hello["ok"], true, "client-hello: {hello}");
        client
    }

    fn request(&mut self, mut value: serde_json::Value) -> serde_json::Value {
        let id = self.next;
        self.next += 1;
        value["id"] = serde_json::json!(id);
        writeln!(self.stream, "{value}").unwrap();
        loop {
            let mut line = String::new();
            let read = self.reader.read_line(&mut line).unwrap();
            assert!(read > 0, "the owner closed the connection before answering {value}");
            let reply: serde_json::Value = match serde_json::from_str(&line) {
                Ok(reply) => reply,
                Err(_) => continue,
            };
            if reply["id"] == serde_json::json!(id) {
                return reply;
            }
        }
    }
}

/// One module, so `owner_keepers` names every test of the stage (with the
/// core's `server::owner_keepers` unit tests) in one fleet filter.
mod owner_keepers {
    use super::*;

    #[test]
    fn an_app_owner_with_nothing_kept_stops_when_its_app_leaves() {
        let owner = Owner::ensure("idle");
        let app = Client::app(&owner.socket);
        owner.assert_kept("the app's connection");
        drop(app);
        owner.assert_stops("its app's last connection closed with no terminal");
    }

    #[test]
    fn an_owner_no_app_ever_reached_is_left_running() {
        // A probe's or a script's `ensure` (no role-main hello) leaves the owner
        // as before: the process that ran `ensure` may connect later.
        let owner = Owner::ensure("no-app");
        let plain = Client::connect(&owner.socket);
        drop(plain);
        owner.assert_kept("its never-armed rule");
    }

    #[test]
    fn a_live_terminal_keeps_the_owner_until_its_shell_exits() {
        let owner = Owner::ensure("terminal");
        let mut app = Client::app(&owner.socket);
        let done = owner.root.join("done");
        // The shell lives until the test creates `done`, then exits by itself.
        let script = format!("while [ ! -e '{}' ]; do sleep 0.1; done", done.display());
        let created = app.request(serde_json::json!({
            "cmd": "create-terminal", "detached": true, "argv": ["/bin/sh", "-c", script],
        }));
        assert_eq!(created["ok"], true, "create-terminal: {created}");
        drop(app);
        owner.assert_kept("a live terminal");
        fs::write(&done, b"").unwrap();
        owner.assert_stops("its last terminal's shell exited");
    }

    #[test]
    fn a_client_that_arrives_keeps_the_owner_and_its_departure_stops_it() {
        let owner = Owner::ensure("returning");
        let app = Client::app(&owner.socket);
        // A second client (a CLI call) connects while the app is still there. An
        // answered request proves the owner registered it (a bare connect is only
        // queued in the kernel).
        let mut cli = Client::connect(&owner.socket);
        let identified = cli.request(serde_json::json!({"cmd": "identify"}));
        assert_eq!(identified["ok"], true, "identify: {identified}");
        drop(app);
        owner.assert_kept("a connected CLI client");
        drop(cli);
        owner.assert_stops("its last client left");
    }
}
