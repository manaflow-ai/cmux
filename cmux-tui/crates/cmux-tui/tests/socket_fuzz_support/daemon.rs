//! An isolated headless daemon for the fuzzer, and a line connection to it
//! with a deadline on every read.
//!
//! Isolation: its own HOME, config, state root and working folder (not a git
//! repository: GIT_CEILING_DIRECTORIES stops at it), and every terminal runs a
//! sink (`cat > /dev/null`) instead of a shell, so fuzzed text that reaches a
//! terminal is never executed.

use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

pub fn scaled(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

pub struct Daemon {
    pub child: Child,
    pub socket: PathBuf,
    pub dir: PathBuf,
}

impl Daemon {
    pub fn start(label: &str) -> Self {
        let stamp =
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
        let n = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
        // Short: a Unix socket path holds about 100 bytes.
        let dir =
            PathBuf::from("/tmp").join(format!("cxf-{label}-{}-{n}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let sink = dir.join("sink.sh");
        fs::write(&sink, "#!/bin/sh\nexec cat > /dev/null\n").unwrap();
        fs::set_permissions(&sink, fs::Permissions::from_mode(0o755)).unwrap();
        let socket = dir.join("mux.sock");
        let stderr = fs::File::create(dir.join("daemon.stderr")).unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .current_dir(&dir)
            .env("HOME", &dir)
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("SHELL", &sink)
            .env("CMUX_TUI_NO_LOGIN_SHELL", "1")
            .env("GIT_CEILING_DIRECTORIES", &dir)
            .env("XDG_CONFIG_HOME", dir.join("xdg-config"))
            .env("XDG_DATA_HOME", dir.join("xdg-data"))
            .env("XDG_STATE_HOME", dir.join("xdg-state"))
            .env("XDG_RUNTIME_DIR", &dir)
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(stderr);
        let root = dir.join("cmux-tui");
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        command.env("CMUX_TUI_STATE_DIR", root.join("sessions"));
        let child = command.spawn().unwrap();
        let mut daemon = Self { child, socket, dir };
        let deadline = Instant::now() + scaled(Duration::from_secs(20));
        while UnixStream::connect(&daemon.socket).is_err() {
            assert!(daemon.alive(), "daemon exited at start:\n{}", daemon.stderr_tail());
            assert!(Instant::now() < deadline, "daemon did not create {}", daemon.socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        daemon
    }

    pub fn alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    /// How the daemon ended, when it did.
    pub fn exit(&mut self) -> Option<String> {
        match self.child.try_wait() {
            Ok(Some(status)) => Some(format!("{status:?}")),
            _ => None,
        }
    }

    pub fn stderr_tail(&self) -> String {
        let text = fs::read_to_string(self.dir.join("daemon.stderr")).unwrap_or_default();
        let lines: Vec<&str> = text.lines().collect();
        lines[lines.len().saturating_sub(40)..].join("\n")
    }

    pub fn connect(&self) -> Conn {
        Conn::open(&self.socket)
            .unwrap_or_else(|error| panic!("connect {}: {error}", self.socket.display()))
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if std::env::var_os("CMUX_FUZZ_KEEP").is_none() {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }
}

/// What one request got.
#[derive(Debug, Clone)]
pub enum Outcome {
    /// The reply line with the request's id.
    Reply(Value),
    /// No reply before the deadline (a hang).
    Timeout,
    /// The daemon closed the connection with no reply.
    Closed,
    /// A reply line that is not JSON.
    NotJson(String),
}

pub struct Conn {
    stream: UnixStream,
    buffer: Vec<u8>,
}

impl Conn {
    pub fn open(path: &Path) -> std::io::Result<Self> {
        let stream = UnixStream::connect(path)?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        Ok(Self { stream, buffer: Vec::new() })
    }

    pub fn send_raw(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        self.stream.write_all(bytes)
    }

    /// Sends `request` as one line and reads lines until the one whose `id`
    /// equals `id` (stream items and events in between are skipped).
    pub fn call(&mut self, request: &Value, id: &Value, deadline: Duration) -> Outcome {
        let mut line = request.to_string().into_bytes();
        line.push(b'\n');
        if self.send_raw(&line).is_err() {
            return Outcome::Closed;
        }
        self.reply_to(id, deadline)
    }

    /// Reads lines until the reply to `id`; a `Value::Null` id takes the first
    /// reply-shaped line (a request that had no readable id).
    pub fn reply_to(&mut self, id: &Value, deadline: Duration) -> Outcome {
        let end = Instant::now() + scaled(deadline);
        loop {
            match self.next_line(end) {
                Err(outcome) => return outcome,
                Ok(line) => {
                    let Ok(value) = serde_json::from_slice::<Value>(&line) else {
                        return Outcome::NotJson(String::from_utf8_lossy(&line).into_owned());
                    };
                    let is_reply = value.get("ok").is_some()
                        || value.get("type").and_then(Value::as_str) == Some("response");
                    if value.get("id") == Some(id) || (id.is_null() && is_reply) {
                        return Outcome::Reply(value);
                    }
                }
            }
        }
    }

    fn next_line(&mut self, end: Instant) -> Result<Vec<u8>, Outcome> {
        loop {
            if let Some(at) = self.buffer.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = self.buffer.drain(..=at).collect();
                return Ok(line[..line.len() - 1].to_vec());
            }
            let now = Instant::now();
            if now >= end {
                return Err(Outcome::Timeout);
            }
            let _ = self.stream.set_read_timeout(Some((end - now).max(Duration::from_millis(1))));
            let mut chunk = [0u8; 65536];
            match self.stream.read(&mut chunk) {
                Ok(0) => return Err(Outcome::Closed),
                Ok(read) => self.buffer.extend_from_slice(&chunk[..read]),
                Err(error)
                    if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
                {
                    return Err(Outcome::Timeout);
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => {}
                Err(_) => return Err(Outcome::Closed),
            }
        }
    }
}
