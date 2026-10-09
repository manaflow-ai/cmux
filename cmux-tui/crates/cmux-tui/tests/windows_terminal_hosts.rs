//! Windows per-terminal hosts (bead cx-ko2e, plans/cmux-next/windows-terminal-hosts.md):
//! a terminal survives a daemon restart, as on Unix
//! (terminal_host_recovery.rs `fenced_daemon_shutdown_acks_then_preserves_and_re_adopts_terminal_host`).
//! Red until the Windows host lands: today the daemon owns the ConPTY, and a
//! fenced shutdown ends the terminal.
#![cfg(windows)]

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

/// A headless daemon on a private socket and state folder. Dropping it ends
/// its terminals and the daemon (exact child only).
struct Daemon {
    child: Option<Child>,
    socket: PathBuf,
    state: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
        // Short: AF_UNIX paths are limited on Windows too.
        let dir = std::env::temp_dir().join(format!("cwth-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut daemon = Self { child: None, socket: dir.join("mux.sock"), state: dir.join("state"), dir };
        daemon.start();
        daemon
    }

    fn start(&mut self) {
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&self.socket)
            .arg("--state")
            .arg(&self.state)
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        self.child = Some(child);
        let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
        while transport::connect(&self.socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", self.socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// The fenced shutdown that keeps terminal hosts (`server stop`).
    fn stop_keeping_terminals(&mut self) {
        let identify = request(&self.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
        let accepted = request(
            &self.socket,
            serde_json::json!({
                "id": 2,
                "cmd": "shutdown-daemon",
                "pid": identify["pid"],
                "generation": identify["generation"],
            }),
        );
        assert_eq!(accepted["accepted"], true, "{accepted}");
        let mut child = self.child.take().unwrap();
        let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
        while child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "daemon did not exit after a fenced shutdown");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.child.is_some() {
            if let Ok(identify) = std::panic::catch_unwind(|| request(&self.socket, serde_json::json!({"cmd": "identify"}))) {
                let _ = request_response(
                    &self.socket,
                    serde_json::json!({
                        "cmd": "shutdown-daemon",
                        "pid": identify["pid"],
                        "generation": identify["generation"],
                        "end_terminals": true,
                    }),
                );
            }
            if let Some(mut child) = self.child.take() {
                let deadline = Instant::now() + Duration::from_secs(15);
                while child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(50));
                }
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn request_response(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let response = request_response(path, value);
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["data"].clone()
}

fn wait_for_screen(path: &Path, surface: u64, marker: &str) -> String {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let mut last = String::new();
    while Instant::now() < deadline {
        last = request(path, serde_json::json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        if last.contains(marker) {
            return last;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    last
}

#[test]
fn a_terminal_survives_a_fenced_daemon_restart_on_windows() {
    let mut daemon = Daemon::new("restart");
    let marker = format!("before-restart-{}", std::process::id());
    // cmd.exe echoes its input and keeps running.
    let created = request(
        &daemon.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["cmd.exe", "/q", "/k"],
            "new_workspace": true,
            "name": "restart-survivor",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    request(&daemon.socket, serde_json::json!({"id": 2, "cmd": "send", "surface": surface, "text": format!("echo {marker}\r")}));
    assert!(wait_for_screen(&daemon.socket, surface, &marker).contains(&marker));

    daemon.stop_keeping_terminals();
    daemon.start();

    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    let adopted = loop {
        let resolved = request_response(
            &daemon.socket,
            serde_json::json!({"id": 3, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
        );
        let data = &resolved["data"];
        if resolved["ok"] == true
            && data["lifecycle"] == "running"
            && data["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && let Some(surface) = data["surface"].as_u64()
        {
            break surface;
        }
        assert!(
            Instant::now() < deadline,
            "the restarted daemon did not adopt terminal {terminal_id} (incarnation {incarnation}): {resolved}"
        );
        std::thread::sleep(Duration::from_millis(100));
    };
    assert!(wait_for_screen(&daemon.socket, adopted, &marker).contains(&marker), "the screen from before the restart is gone");

    let after = format!("after-restart-{}", std::process::id());
    request(&daemon.socket, serde_json::json!({"id": 4, "cmd": "send", "surface": adopted, "text": format!("echo {after}\r")}));
    assert!(wait_for_screen(&daemon.socket, adopted, &after).contains(&after), "input after the restart did not reach the same shell");
}
