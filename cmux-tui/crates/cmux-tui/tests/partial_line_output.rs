#![cfg(unix)]
//! A write with no newline at its end is on the screen while its process still runs (manaflow-ai/cmux#3079).
//!
//! The report: `node -e "process.stderr.write('CMUX-STDERR-VISIBLE: '); setTimeout(()=>process.exit(), 5000)"`
//! left the pane blank for the 5 s and never drew the text, so every inquirer-style prompt (`bw unlock`,
//! `npm init`, `create-vite`) showed a blank pane waiting on input. A prompt is a partial line: it is printed
//! without `\n` and then the program blocks on stdin.
//!
//! Here a real headless daemon runs an interactive `sh` as the app runs a terminal (`--state`: the shell in its
//! own terminal host process). A client attached in bytes mode, as the Mac app's terminal and the phone are,
//! types the reproducer: `printf` of a marker to stderr with no newline, then `sleep 30` (the program waiting
//! on input). Within a few seconds, long before the sleep ends, the marker must reach both the attached
//! client's output stream and the daemon's screen (`read-screen`). When node is on the host the issue's own
//! one-liner runs too.
//!
//! The typed command spells the marker's first letter as `\103`, so the shell's echo of the command line never
//! contains the marker: only the program's own write can.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde_json::{Value, json};

const MARKER: &str = "CMUX-STDERR-VISIBLE:";
/// Well under the 30 s the program sleeps: the marker must show while it still runs.
const SHOWN_WITHIN: Duration = Duration::from_secs(5);

fn b64() -> &'static base64::engine::GeneralPurpose {
    &base64::engine::general_purpose::STANDARD
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // The daemon this test started, by its own handle; its terminal hosts end with their shells.
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-partial-line-{name}-{}-{stamp}", std::process::id()));
        let home = dir.join("home");
        fs::create_dir_all(&home).unwrap();
        let settings = dir.join("cmux-next.json");
        fs::write(&settings, "{}\n").unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--session", "main", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("HOME", &home)
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_DATA_HOME")
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("CMUX_NEXT_CONFIG_FILE", &settings)
            .env("ACPMUX_SOCKET", dir.join("acpmux.sock"))
            .env("CMUX_TUI_HOST_EXE_DIR", dir.join("host-exe"))
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("SHELL", "/bin/sh")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    fn request(&self, value: Value) -> Value {
        let stream = UnixStream::connect(&self.socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        (&stream).write_all(format!("{value}\n").as_bytes()).unwrap();
        let mut reader = BufReader::new(&stream);
        loop {
            let mut line = String::new();
            assert!(reader.read_line(&mut line).unwrap() > 0, "daemon closed for {value}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply.get("ok").is_some() {
                assert_eq!(reply["ok"], true, "{value} failed: {reply}");
                return reply["data"].clone();
            }
        }
    }

    /// A new workspace running an interactive `sh` at a `READY>` prompt.
    fn shell(&self, name: &str) -> u64 {
        let created = self.request(json!({
            "cmd": "run", "new_workspace": true, "name": name, "cols": 100, "rows": 24,
            "argv": ["/bin/sh", "-c", "PS1='READY> '; export PS1; exec /bin/sh -i"],
        }));
        created["surface"]
            .as_u64()
            .or_else(|| created["surface_id"].as_u64())
            .unwrap_or_else(|| panic!("run reply names no surface: {created}"))
    }

    fn screen(&self, surface: u64) -> String {
        self.request(json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap_or_default()
            .to_string()
    }

    /// Polls `read-screen` until it holds `needle`; Err is the last screen.
    fn wait_for_screen(&self, surface: u64, needle: &str, within: Duration) -> Result<(), String> {
        let deadline = Instant::now() + within;
        let mut last = String::new();
        while Instant::now() < deadline {
            last = self.screen(surface);
            if last.contains(needle) {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        Err(last)
    }
}

/// A client attached to one terminal in bytes mode: every `output` event's bytes arrive on `outputs`.
struct Attached {
    writer: UnixStream,
    outputs: mpsc::Receiver<Vec<u8>>,
    surface: u64,
}

impl Attached {
    fn open(daemon: &Daemon, surface: u64) -> Self {
        let stream = UnixStream::connect(&daemon.socket).unwrap();
        let reader = stream.try_clone().unwrap();
        let (tx, outputs) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(reader).lines() {
                let Ok(line) = line else { return };
                let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
                if value["event"] == "output"
                    && let Some(data) = value["data"].as_str()
                    && tx.send(b64().decode(data).unwrap_or_default()).is_err()
                {
                    return;
                }
            }
        });
        let mut attached = Self { writer: stream, outputs, surface };
        attached.submit(json!({"cmd": "attach-surface", "surface": surface}));
        attached
    }

    fn submit(&mut self, value: Value) {
        writeln!(self.writer, "{value}").unwrap();
    }

    fn type_bytes(&mut self, bytes: &[u8]) {
        let surface = self.surface;
        self.submit(json!({"cmd": "send", "surface": surface, "bytes": b64().encode(bytes)}));
    }

    /// Reads output until the bytes so far hold `needle`; Err is what arrived.
    fn wait_for_output(&self, needle: &str, within: Duration) -> Result<(), String> {
        let deadline = Instant::now() + within;
        let mut seen = Vec::new();
        loop {
            if String::from_utf8_lossy(&seen).contains(needle) {
                return Ok(());
            }
            let left = deadline.saturating_duration_since(Instant::now());
            match self.outputs.recv_timeout(left) {
                Ok(bytes) => seen.extend(bytes),
                Err(_) => return Err(String::from_utf8_lossy(&seen).into_owned()),
            }
        }
    }
}

/// Types `command` at the prompt and checks that [`MARKER`] reaches the attached client and the screen within
/// [`SHOWN_WITHIN`], while the program still sleeps.
fn partial_line_shows_while_running(name: &str, command: &str) {
    let daemon = Daemon::start(name);
    let surface = daemon.shell(name);
    daemon
        .wait_for_screen(surface, "READY>", Duration::from_secs(20))
        .unwrap_or_else(|screen| panic!("sh never drew its prompt; the screen was:\n{screen}"));
    let mut client = Attached::open(&daemon, surface);
    client
        .wait_for_output("READY>", Duration::from_secs(10))
        .unwrap_or_else(|got| panic!("the attach replay has no prompt: {got:?}"));

    let started = Instant::now();
    client.type_bytes(format!("{command}\r").as_bytes());
    if let Err(got) = client.wait_for_output(MARKER, SHOWN_WITHIN) {
        panic!(
            "{command:?}: the attached client got no {MARKER:?} within {SHOWN_WITHIN:?} while the program \
             still ran (a partial line held until a newline or exit, #3079); it got:\n{got:?}"
        );
    }
    if let Err(screen) = daemon.wait_for_screen(surface, MARKER, SHOWN_WITHIN) {
        panic!(
            "{command:?}: the daemon's screen has no {MARKER:?} within {SHOWN_WITHIN:?} while the program \
             still ran (#3079); the screen was:\n{screen}"
        );
    }
    let shown_after = started.elapsed();
    // The marker showed before the program could have ended: it was painted, not drained at exit.
    assert!(shown_after < Duration::from_secs(20), "{command:?}: shown only after {shown_after:?}");
    eprintln!("PARTIAL-LINE {name}: {MARKER:?} on screen after {shown_after:?}");
    client.type_bytes(b"\x03");
}

#[test]
fn a_partial_line_on_stderr_shows_while_its_program_waits() {
    partial_line_shows_while_running("stderr", r"printf '\103MUX-STDERR-VISIBLE: ' >&2; sleep 30");
}

#[test]
fn a_partial_line_on_stdout_shows_while_its_program_waits() {
    partial_line_shows_while_running("stdout", r"printf '\103MUX-STDERR-VISIBLE: '; sleep 30");
}

/// The issue's own reproducer, when node is on this host.
#[test]
fn the_issue_node_reproducer_shows_its_prompt() {
    let node = Command::new("node").arg("--version").output();
    if !node.is_ok_and(|out| out.status.success()) {
        eprintln!("PARTIAL-LINE-SKIP: no node on this host");
        return;
    }
    partial_line_shows_while_running(
        "node",
        r#"node -e "process.stderr.write('\x43MUX-STDERR-VISIBLE: '); setTimeout(()=>process.exit(), 30000)""#,
    );
}
