//! `server restart` (HQ#7149 R4, the daemon swap): stop the session's owner
//! the way an update hands it off (no `--end-terminals`), wait for it to exit,
//! then start an owner from this binary. Terminal hosts outlive the old owner
//! and the new one adopts them, so a daemon edit reaches the running session
//! without ending a terminal: the same terminal incarnation keeps running,
//! with its scrollback, and answers new input.

#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(session: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-rs-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        fs::create_dir(dir.join("home")).unwrap();
        Self { socket: dir.join("mux.sock"), session: session.into(), dir }
    }

    fn command(&self, action: &str, extra: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .args(extra)
            .env("HOME", self.dir.join("home"))
            .env("CFFIXED_USER_HOME", self.dir.join("home"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("SHELL", "/bin/sh");
        command
    }

    /// Whether a `server` command succeeded, and its result or JSON error
    /// (the last JSON line on stdout or stderr).
    fn run(&self, action: &str, extra: &[&str]) -> (bool, Value) {
        let output = self.command(action, extra).output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stream = if output.status.success() { &stdout } else { &stderr };
        let last = stream.lines().rfind(|line| line.starts_with('{')).unwrap_or_default();
        let value: Value = serde_json::from_str(last).unwrap_or_else(|_| {
            panic!("server {action} printed no JSON: stdout {stdout:?} stderr {stderr:?}")
        });
        (output.status.success(), value)
    }

    fn server(&self, action: &str, extra: &[&str]) -> Value {
        let (success, value) = self.run(action, extra);
        assert!(success, "server {action} {extra:?} failed: {value}");
        value
    }

    fn request(&self, request: Value) -> Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut stream = BufReader::new(stream);
        let mut request = request;
        request["id"] = json!(1);
        writeln!(stream.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(stream.read_line(&mut line).unwrap(), 0, "closed during {request}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == 1 {
                assert_eq!(reply["ok"], true, "{request}: {reply}");
                return reply["data"].clone();
            }
        }
    }

    fn screen_has(&self, surface: &Value, text: &str) -> bool {
        let screen = self.request(json!({"cmd": "read-screen", "surface": surface}));
        screen["text"].as_str().is_some_and(|screen| screen.contains(text))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop", &["--end-terminals"]).output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn wait_for(what: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Whether `pid` exists and is not a zombie its new parent has yet to reap.
fn running(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the pid exists.
    if unsafe { libc::kill(pid, 0) } != 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    if let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat"))
        && let Some((_, rest)) = stat.rsplit_once(')')
    {
        return rest.split_whitespace().next() != Some("Z");
    }
    true
}

fn pid_of(value: &Value) -> i32 {
    i32::try_from(value["pid"].as_u64().unwrap_or_else(|| panic!("no pid in {value}"))).unwrap()
}

#[test]
fn restart_swaps_the_owner_and_keeps_its_terminals() {
    let fixture = Fixture::new("restart-keeps");
    let old = pid_of(&fixture.server("ensure", &[]));
    let created =
        fixture.request(json!({"cmd": "run", "argv": ["/bin/sh"], "new_workspace": true}));
    let (terminal, incarnation) = (created["terminal_id"].clone(), created["terminal_incarnation"].clone());
    fixture.request(json!({"cmd": "send", "surface": created["surface"], "text": "echo before-$((20+1))\n"}));
    wait_for("the shell before the restart", || fixture.screen_has(&created["surface"], "before-21"));

    let restarted = fixture.server("restart", &[]);
    let new = pid_of(&restarted);
    assert_ne!(new, old, "restart kept the old owner: {restarted}");
    assert!(!running(old), "the old owner {old} still runs after restart");
    assert_eq!(pid_of(&fixture.server("status", &[])), new);

    // Adopted, not respawned: the same incarnation, its scrollback, and input.
    let resolved = fixture.request(json!({"cmd": "resolve-terminal", "terminal_id": terminal}));
    assert_eq!(resolved["lifecycle"], "running", "{resolved}");
    assert_eq!(resolved["terminal_incarnation"], incarnation, "{resolved}");
    let surface = resolved["surface"].clone();
    assert!(fixture.screen_has(&surface, "before-21"), "scrollback lost across restart");
    fixture.request(json!({"cmd": "send", "surface": surface, "text": "echo after-$((40+2))\n"}));
    wait_for("the shell after the restart", || fixture.screen_has(&surface, "after-42"));
}

#[test]
fn restart_starts_an_owner_when_none_runs() {
    let fixture = Fixture::new("restart-absent");
    let started = fixture.server("restart", &[]);
    assert_eq!(pid_of(&fixture.server("status", &[])), pid_of(&started));
}

#[test]
fn restart_refuses_end_terminals() {
    let fixture = Fixture::new("restart-end");
    let (success, value) = fixture.run("restart", &["--end-terminals"]);
    assert!(!success, "restart --end-terminals succeeded: {value}");
}
