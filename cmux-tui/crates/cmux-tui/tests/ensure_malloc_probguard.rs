//! p10-stability-201: `server ensure` started with `MallocProbGuard` (the
//! app's sampled Nightly allocator check, DaemonLaunchEnvironment.swift)
//! starts its owner under it, and no terminal of that owner inherits it.
//! The client takes the variable out of its own environment at start
//! (startup_env.rs), so without the handoff in local_owner.rs the owner would
//! start without it; without the owner's own take every shell and program in
//! its terminals would run under the check.
//! A real owner process, started the way the app starts it.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

const VARIABLE: &str = "MallocProbGuard";

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-pg-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        Self { socket: dir.join("mux.sock"), session: "ensure-probguard".into(), dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env_remove(VARIABLE);
        command
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn request(path: &Path, value: &Value) -> Option<Value> {
    let stream = transport::connect(path).ok()?;
    let mut writer = stream.try_clone_box().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}

/// The environment a terminal of the owner at `socket` starts with.
fn terminal_env(socket: &Path, dir: &Path) -> String {
    let out = dir.join("env.out");
    let script = format!("env > {0}.tmp; mv {0}.tmp {0}; sleep 30", out.display());
    let created = request(
        socket,
        &json!({"cmd": "run", "argv": ["/bin/sh", "-c", script], "new_workspace": true,
                "name": "probguard-env"}),
    )
    .expect("the owner answers run");
    assert_eq!(created["ok"], true, "{created}");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let env = loop {
        if let Ok(env) = fs::read_to_string(&out) {
            break env;
        }
        assert!(Instant::now() < deadline, "the terminal never wrote {}", out.display());
        std::thread::sleep(Duration::from_millis(25));
    };
    assert!(env.contains("PATH="), "the terminal env looks empty: {env}");
    env
}

#[test]
fn an_ensured_owner_starts_under_probguard_and_no_terminal_inherits_it() {
    let fixture = Fixture::new();
    let ensured = fixture.command("ensure").env(VARIABLE, "1").output().unwrap();
    assert!(ensured.status.success(), "{}", String::from_utf8_lossy(&ensured.stderr));
    let stdout = String::from_utf8_lossy(&ensured.stdout);
    let reply: Value = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str(line.trim()).ok())
        .unwrap_or_else(|| panic!("no JSON from ensure: {stdout}"));
    assert_eq!(reply["status"], "started", "{reply}");

    // The owner's initial environment (Linux keeps it in /proc after the
    // owner's own take): the handoff gave it the variable.
    #[cfg(target_os = "linux")]
    {
        let pid = reply["pid"].as_u64().expect("ensure returns the owner's pid");
        let environ = fs::read(format!("/proc/{pid}/environ")).unwrap();
        let entries: Vec<&[u8]> = environ.split(|byte| *byte == 0).collect();
        assert!(
            entries.contains(&format!("{VARIABLE}=1").as_bytes()),
            "the owner started without {VARIABLE}=1"
        );
    }

    let env = terminal_env(&fixture.socket, &fixture.dir);
    assert!(!env.contains(VARIABLE), "the terminal inherited {VARIABLE}:\n{env}");
}
