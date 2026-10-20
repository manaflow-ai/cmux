//! Tester rollout #7 (plans/cmux-next/tui-tester-rollout.md): a standalone
//! cmux-tui (Linux, npm, PyPI) sends its owner panics to Sentry itself; only
//! the Mac app did, so a Linux tester's crash never left the machine.
//!
//! The owner forwards the panic lines it has not sent yet when it starts
//! (a main-thread panic ends the process, so the next start sends it), at
//! most once per line, never a test line, and nothing when the user turned
//! `app.sendAnonymousTelemetry` off. Debug builds take the Sentry DSN from
//! `CMUX_TUI_TEST_SENTRY_DSN`; this test points it at a local listener.

#![cfg(all(unix, debug_assertions))]

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

/// A local stand-in for Sentry's envelope endpoint: each request's path and body.
fn sentry() -> (String, mpsc::Receiver<(String, String)>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut request_line = String::new();
            reader.read_line(&mut request_line).unwrap_or_default();
            let mut length = 0usize;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or_default() == 0 || line == "\r\n" {
                    break;
                }
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = value.trim().parse().unwrap_or_default();
                }
            }
            let mut body = vec![0; length];
            let _ = reader.read_exact(&mut body);
            let path = request_line.split_whitespace().nth(1).unwrap_or_default().to_string();
            let _ = sender.send((path, String::from_utf8_lossy(&body).into_owned()));
            let _ = stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
        }
    });
    (format!("http://publickey@127.0.0.1:{port}/42"), receiver)
}

struct Owner {
    child: Child,
    dir: PathBuf,
    session: &'static str,
}

fn command(dir: &Path) -> Command {
    let mut command = Command::new(bin());
    command
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_NEXT_CONFIG_FILE", dir.join("cmux-next.json"))
        .env("CMUX_TUI_LOG_FILE", dir.join("client.log"))
        .env_remove("CI");
    command
}

impl Owner {
    fn start(dir: &Path, session: &'static str, dsn: &str) -> Owner {
        let child = command(dir)
            .args(["--headless", "--session", session, "--socket"])
            .arg(dir.join("mux.sock"))
            .env("CMUX_TUI_TEST_SENTRY_DSN", dsn)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        Owner { child, dir: dir.to_path_buf(), session }
    }

    /// The forwarder's one outcome line for this start (`crash-forward: ...`).
    fn outcome(&self, starts_seen: usize) -> String {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let log = fs::read_to_string(self.dir.join("client.log")).unwrap_or_default();
            let outcomes: Vec<&str> =
                log.lines().filter(|line| line.contains("crash-forward:")).collect();
            if outcomes.len() > starts_seen {
                return outcomes[starts_seen].to_string();
            }
            assert!(Instant::now() < deadline, "no crash-forward outcome in client.log:\n{log}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = command(&self.dir)
            .args(["server", "stop", "--session", self.session, "--end-terminals", "--socket"])
            .arg(self.dir.join("mux.sock"))
            .output();
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

fn temp_dir(tag: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-cf-{tag}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    dir
}

fn seed_panics(dir: &Path, session: &str) {
    let lines = [
        serde_json::json!({"session": session, "message": "test panic", "location": "src/t.rs:1:1",
            "thread": "owner-panic-test", "version": "0.13.5", "test": true, "backtrace": ""}),
        serde_json::json!({"session": session, "message": "boom-from-last-run", "location": "src/a.rs:7:9",
            "thread": "worker", "version": "0.13.5", "build_identity": "abc123", "os": "linux",
            "arch": "aarch64", "test": false, "backtrace": "frame"}),
    ];
    let text: String = lines.iter().map(|line| format!("{line}\n")).collect();
    fs::write(dir.join("state").join(format!("owner-panics-{session}.jsonl")), text).unwrap();
}

#[test]
fn crash_forward_sends_unsent_panics_once_and_never_test_lines() {
    let (dsn, requests) = sentry();
    let dir = temp_dir("send");
    let session = "cf-send";
    seed_panics(&dir, session);

    let owner = Owner::start(&dir, session, &dsn);
    let outcome = owner.outcome(0);
    assert!(outcome.contains("sent=1"), "{outcome}");
    let (path, body) = requests.recv_timeout(Duration::from_secs(5)).expect("one envelope");
    assert_eq!(path, "/api/42/envelope/");
    assert!(body.contains("boom-from-last-run"), "{body}");
    assert!(!body.contains("test panic"), "a test line must never be sent: {body}");
    assert!(body.contains(r#""process":"cmux-tui""#), "{body}");
    assert!(body.contains(r#""tui_version":"0.13.5""#), "{body}");
    assert!(body.contains(r#""tui_build":"abc123""#), "{body}");
    assert!(body.contains(r#""tui_arch":"aarch64""#), "{body}");
    drop(owner);

    // The next start finds nothing new: each line goes once.
    let owner = Owner::start(&dir, session, &dsn);
    let outcome = owner.outcome(1);
    assert!(outcome.contains("sent=0"), "{outcome}");
    assert!(requests.try_recv().is_err(), "a line was sent twice");
    drop(owner);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn crash_forward_sends_nothing_with_telemetry_off() {
    let (dsn, requests) = sentry();
    let dir = temp_dir("off");
    let session = "cf-off";
    seed_panics(&dir, session);
    fs::write(dir.join("cmux-next.json"), r#"{ "app": { "sendAnonymousTelemetry": false } }"#)
        .unwrap();

    let owner = Owner::start(&dir, session, &dsn);
    let outcome = owner.outcome(0);
    assert!(outcome.contains("off") && outcome.contains("app.sendAnonymousTelemetry"), "{outcome}");
    assert!(requests.try_recv().is_err(), "nothing may be sent with telemetry off");
    drop(owner);
    let _ = fs::remove_dir_all(&dir);
}
