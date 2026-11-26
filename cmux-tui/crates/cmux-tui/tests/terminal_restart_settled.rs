#![cfg(unix)]
//! Restart to settled, terminal side: a Claude Code CLI session coming back
//! after the app restarts, over a simulated link.
//!
//! Leo, 2026-11-22: "the restart to update loading settling is pretty bad as
//! well. you guys need to be able to simulate the update/restart and the
//! connection speed and what is actually displayed and get that gui agent chat
//! sped up to be nearly as fast as the terminal coming back (e.g. my claude
//! code cli, interim-coord) and how it is essentially lickety split instantly
//! rendered properly, in the right place, all that. the agent gui needs that
//! too."
//!
//! This is the terminal half of the harness (the chat half is
//! webviews/bench/first-load-after-restart.bench.ts). It runs the daemon the
//! Mac app runs (`cmux-tui --headless --state`: each terminal in its own
//! terminal host process, the PTY held there), prints a Claude Code-like
//! transcript and input box into a real PTY at 120x40, attaches the "old app"
//! viewer and closes it (the app quit; the daemon and the PTY stay). Then each
//! round is the relaunched app: a new connection, through an in-process link
//! proxy, doing exactly what `TerminalAttachment.attach` in
//! Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Terminal/TerminalAttachment.swift
//! sends: `identify` and `set-client-info` pipelined in one write, then
//! `attach-surface {mode: bytes, expected_generation, expected_terminal_id,
//! cols, rows, snapshot: ghostsnp, snapshot_version, snapshot_local_history}`
//! (the restored pane attaches by its `term_` id). The client parses what
//! arrives with libghostty-vt the way the surface does:
//!
//! - `snapshot` attach (the Mac app's default when its libghostty restores
//!   GHOSTSNP, `TerminalSession.snapshotVersion != 0`): the READY record is
//!   restored with `ghostty_snapshot_decoder_ready` into a terminal, live
//!   `output` is written to it;
//! - `bytes` attach (the app's fallback, and the iOS / cmux-terminal-client
//!   path): `vt-state` replay into a fresh terminal, then `output`.
//!
//! After every read the client reads the viewport (text and cursor) and
//! records when it changed. Per link profile (webviews/bench/link-profiles.json,
//! shared with the chat side) it prints the medians over ROUNDS reattaches:
//!
//! `TERMINAL_RESTART_JSON {"link","firstContentMs","settledMs","changesAfterFirst","bytes","finalScreenOk",...}`
//! for the snapshot attach, and `TERMINAL_RESTART_BYTES_JSON {...}` for the
//! byte replay attach.
//!
//! Not covered: the Swift side (surface creation, `TerminalAttachDriver`'s
//! queue, the Metal draw), the app's launch before it opens the attach, and
//! anything the app does on its control connection first (tree load). The
//! numbers are the wire, the daemon and the parse; the draw comes on top.
//!
//! Run (ignored in the normal test run):
//! `cargo test --release -p cmux-tui --test it -- terminal_restart_settled:: --ignored --nocapture`.
//! `ROUNDS` (default 5) sets the reattaches per profile; `LINK_PROFILES` a
//! profiles file other than webviews/bench/link-profiles.json;
//! `RESTART_ATTACH` = `snapshot`, `bytes` or `both` (default).

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use cmux_tui_core::platform::transport;
use cmux_tui_core::terminal_host_runtime::{
    TerminalHostLiveness, adopt_terminal_host, load_terminal_host_records,
    remove_stale_terminal_host_record, terminal_host_record_liveness, terminal_host_root,
};
use ghostty_vt::{Callbacks, Terminal};
use ghostty_vt_sys as sys;
use serde_json::{Value, json};

use crate::private_state;

const SESSION: &str = "restart-settled";
const COLS: u16 = 120;
const ROWS: u16 = 40;
const TURNS: usize = 120;
/// The screen is settled once it has not changed for this long.
const QUIET: Duration = Duration::from_millis(300);
/// A round records at most this long.
const CAP: Duration = Duration::from_secs(15);
/// The client checks for quiet this often while nothing arrives.
const POLL: Duration = Duration::from_millis(5);
/// The last line of the fixture: Claude Code's status line under its box.
const STATUS: &str = "  ? for shortcuts                                          interim-coord · Opus · 61% context left";

/// What the Mac app advertises in `set-client-info` (`DaemonCapability.advertised`
/// plus `shared-sizing-v1`, which a view that names its device adds), as of
/// Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift.
/// Only the terminal ones change an attach; the rest are listed so the
/// connection looks like the app's.
const APP_CAPABILITIES: &[&str] = &[
    "workspace-registry-v1",
    "viewport-splits-v1",
    "viewport-column-resize-v1",
    "layout-undo-v1",
    "view-attachment-lease-v1",
    "view-attachment-detach-v1",
    "attach-initial-size",
    "shared-sizing-v1",
    "terminal-env-v1",
    "terminal-input-while-creating-v1",
    "terminal-reap-v1",
    "terminal-pending-sequence-v1",
    "attach-visibility-v1",
    "subscribe-scroll-on-attach-v1",
    "attach-identity-v1",
    "terminal-color-overrides-v1",
    "terminal-snapshot-history-v1",
    "terminal-snapshot-local-history-v1",
    "terminal-clipboard-read-v1",
    "terminal-resources-v1",
    "session-identity-v1",
    "machine-identity-v1",
];

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

// ---------------------------------------------------------------------------
// The fixture: a Claude Code CLI transcript and its input box.

/// 120 turns of `> Prompt N: ...` and `⏺ Answer N: ...` (every 10th answer
/// runs several lines, one longer than the grid), then Claude Code's rounded
/// input box with `> ` inside and the status line under it. The cursor ends
/// in the box after `> `, where Claude Code leaves it.
fn fixture() -> String {
    let mut out = String::new();
    out.push_str("\x1b[2J\x1b[H");
    out.push_str(
        "\x1b[1m✻ Welcome to Claude Code!\x1b[0m\n\n  /help for help, /status for your current setup\n\n",
    );
    for turn in 1..=TURNS {
        out.push_str(&format!(
            "\x1b[2m>\x1b[0m Prompt {turn}: check the merged head of lane {turn} and say what changed\n\n"
        ));
        if turn % 10 == 0 {
            out.push_str(&format!(
                "\x1b[37m⏺\x1b[0m Answer {turn}: the checks on the merged head are green. What changed:\n"
            ));
            out.push_str(
                "  ⎿  crates/cmux-tui/src/session/remote.rs: the attach reply carries the replay\n",
            );
            out.push_str(
                "  ⎿  webviews/src/agent/Transcript.tsx: the transcript keeps its scroll anchor\n",
            );
            out.push_str(&format!(
                "     A longer note that runs past the edge of the grid so it wraps onto a second row: {}\n\n",
                "the merged head builds, the suite passes and the bench numbers moved the right way ".repeat(2)
            ));
        } else {
            out.push_str(&format!(
                "\x1b[37m⏺\x1b[0m Answer {turn}: the checks on the merged head are green.\n\n"
            ));
        }
    }
    let inner = usize::from(COLS) - 2;
    out.push_str(&format!("\x1b[2m╭{}╮\x1b[0m\n", "─".repeat(inner)));
    out.push_str(&format!("\x1b[2m│\x1b[0m > {}\x1b[2m│\x1b[0m\n", " ".repeat(inner - 3)));
    out.push_str(&format!("\x1b[2m╰{}╯\x1b[0m\n", "─".repeat(inner)));
    out.push_str(&format!("\x1b[2m{STATUS}\x1b[0m"));
    // Back into the box: two rows up, after "│ > ".
    out.push_str("\x1b[2A\x1b[5G");
    out
}

// ---------------------------------------------------------------------------
// The daemon, as the app runs it.

struct Daemon {
    child: Option<Child>,
    dir: PathBuf,
    socket: PathBuf,
    state: PathBuf,
}

impl Daemon {
    fn start() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-rs-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let mut command = Command::new(bin());
        command
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("SHELL", "/bin/sh")
            .env_remove("ENV")
            .env_remove("BASH_ENV")
            .env("CMUX_TUI_HOST_EXE_DIR", dir.join("host-exe"))
            .args(["--headless", "--session", SESSION, "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        private_state::use_private_state(&mut command, &dir);
        let child = command.spawn().unwrap();
        let daemon = Self { child: Some(child), dir, socket, state };
        let deadline = Instant::now() + Duration::from_secs(20);
        while transport::connect(&daemon.socket).is_err() {
            assert!(
                Instant::now() < deadline,
                "the daemon did not open {}",
                daemon.socket.display()
            );
            std::thread::sleep(Duration::from_millis(25));
        }
        daemon
    }

    fn host_root(&self) -> PathBuf {
        terminal_host_root(&self.state, SESSION)
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        // The terminal hosts this daemon started (its records name them).
        let records = load_terminal_host_records(&self.host_root()).unwrap_or_default();
        for (path, record) in &records {
            if let Ok(mut host) = adopt_terminal_host(record.clone(), path.clone()) {
                let _ = host.terminate();
                host.disconnect();
            }
        }
        for (path, record) in &records {
            let deadline = Instant::now() + Duration::from_secs(2);
            while terminal_host_record_liveness(path, record).ok()
                != Some(TerminalHostLiveness::Dead)
                && Instant::now() < deadline
            {
                std::thread::sleep(Duration::from_millis(20));
            }
            if terminal_host_record_liveness(path, record).ok() != Some(TerminalHostLiveness::Dead)
            {
                // SAFETY: this test's own terminal host, past its graceful Terminate.
                let _ = unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) };
            }
            let _ = remove_stale_terminal_host_record(path, record);
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn request(path: &Path, value: Value) -> Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "request {value} failed: {response}");
    response["data"].clone()
}

fn screen_text(path: &Path, surface: u64) -> String {
    request(path, json!({"cmd": "read-screen", "surface": surface}))["text"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

fn vt_size(path: &Path, surface: u64) -> (u64, u64) {
    let state = request(path, json!({"cmd": "vt-state", "surface": surface}));
    (state["cols"].as_u64().unwrap_or(0), state["rows"].as_u64().unwrap_or(0))
}

fn wait_for(what: &str, within: Duration, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + within;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// The app that ran before the restart: one view at 120x40 that owns the
/// grid. Dropping it is the app quitting.
struct OldApp {
    _stream: Box<dyn transport::Stream>,
}

impl OldApp {
    fn open(path: &Path, surface: u64) -> Self {
        let stream = transport::connect(path).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(stream.try_clone_box().unwrap());
        let mut send = |id: u64, mut value: Value| {
            value["id"] = json!(id);
            writeln!(writer, "{value}").unwrap();
            loop {
                let mut line = String::new();
                assert!(reader.read_line(&mut line).unwrap() > 0, "old app connection closed");
                let message: Value = serde_json::from_str(&line).unwrap();
                if message["id"] == json!(id) {
                    assert_eq!(message["ok"], true, "{value} failed: {message}");
                    return;
                }
            }
        };
        send(1, json!({"cmd": "attach-surface", "surface": surface, "cols": COLS, "rows": ROWS}));
        send(
            2,
            json!({"cmd": "set-client-sizing", "surface": surface, "enabled": true, "exclusive": true}),
        );
        // Its reader is gone; the daemon's events for it only fill the socket
        // buffer until it closes, and the daemon never blocks on a viewer.
        Self { _stream: stream }
    }
}

struct Target {
    surface: u64,
    terminal_id: String,
}

/// Runs the fixture in a new terminal at 120x40 and waits until the daemon's
/// screen shows all of it (the status line on the last row, the cursor in the
/// box), then lets the old app quit.
fn prepare(daemon: &Daemon) -> Target {
    let fixture_path = daemon.dir.join("transcript.txt");
    fs::write(&fixture_path, fixture()).unwrap();
    let go = daemon.dir.join("go");
    let script = format!(
        "while [ ! -e '{go}' ]; do sleep 0.02; done; cat '{fixture}'; exec sleep 100000",
        go = go.display(),
        fixture = fixture_path.display()
    );
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/sh", "-c", script], "new_workspace": true, "name": "claude"}),
    );
    let surface =
        created["surface"].as_u64().unwrap_or_else(|| panic!("run gave no surface: {created}"));
    let old_app = OldApp::open(&daemon.socket, surface);
    wait_for("the terminal at 120x40", Duration::from_secs(10), || {
        vt_size(&daemon.socket, surface) == (u64::from(COLS), u64::from(ROWS))
    });
    fs::write(&go, b"").unwrap();
    let status = STATUS.trim_end();
    wait_for("the daemon to consume the transcript", Duration::from_secs(20), || {
        let text = screen_text(&daemon.socket, surface);
        text.lines().any(|line| line.trim_end() == status)
    });
    // Quit the app; the daemon and its PTY keep running.
    drop(old_app);
    std::thread::sleep(Duration::from_millis(500));
    let size = vt_size(&daemon.socket, surface);
    assert_eq!(
        size,
        (u64::from(COLS), u64::from(ROWS)),
        "the terminal changed size when the old app quit"
    );
    let tree = request(&daemon.socket, json!({"cmd": "list-workspaces"}));
    let terminal_id = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"].as_u64() == Some(surface))
        .and_then(|tab| tab["terminal_resource_id"].as_str())
        .unwrap_or_else(|| panic!("list-workspaces has no term_ id for surface {surface}: {tree}"))
        .to_string();
    Target { surface, terminal_id }
}

// ---------------------------------------------------------------------------
// The link.

#[derive(Clone, Debug)]
struct Link {
    name: String,
    rtt: Duration,
    /// Bits per second each way; 0 is unlimited.
    bps: u64,
}

fn links() -> Vec<Link> {
    let path = std::env::var_os("LINK_PROFILES").map(PathBuf::from).unwrap_or_else(|| {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../webviews/bench/link-profiles.json")
    });
    let parsed: Option<Vec<Link>> = fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| {
            let profiles = value["profiles"].as_object()?;
            Some(
                profiles
                    .iter()
                    .map(|(name, profile)| Link {
                        name: name.clone(),
                        rtt: Duration::from_secs_f64(
                            profile["rttMs"].as_f64().unwrap_or(0.0) / 1000.0,
                        ),
                        bps: profile["bps"].as_u64().unwrap_or(0),
                    })
                    .collect(),
            )
        });
    let mut links = parsed.unwrap_or_else(|| {
        eprintln!("TERMINAL_RESTART: no profiles at {}, using the built-in four", path.display());
        [("local", 0, 0), ("rtt50", 50, 0), ("rtt200", 200, 0), ("throttled", 150, 1_000_000)]
            .into_iter()
            .map(|(name, rtt, bps)| Link {
                name: name.into(),
                rtt: Duration::from_millis(rtt),
                bps,
            })
            .collect()
    });
    // The file's order is lost in the JSON map; the four known ones go first.
    let order = ["local", "rtt50", "rtt200", "throttled"];
    links.sort_by_key(|link| {
        order.iter().position(|name| *name == link.name).unwrap_or(order.len())
    });
    links
}

/// One direction of the link: a FIFO pipe. A chunk of n bytes handed to it at
/// t departs at max(t, free) + n*8/bps, which becomes `free`, and arrives
/// rtt/2 later. `free` starts one full RTT after the connection opened (the
/// handshake). Ends when `src` ends or `dst` refuses a write.
fn pipe(src: UnixStream, dst: UnixStream, link: &Link, opened: Instant) -> JoinHandle<()> {
    let link = link.clone();
    std::thread::spawn(move || {
        let (tx, rx) = mpsc::channel::<(Instant, Vec<u8>)>();
        let mut dst_writer = dst;
        let src_on_error = src.try_clone().unwrap();
        let writer = std::thread::spawn(move || {
            for (arrive, bytes) in rx {
                let now = Instant::now();
                if arrive > now {
                    std::thread::sleep(arrive - now);
                }
                if dst_writer.write_all(&bytes).is_err() {
                    let _ = src_on_error.shutdown(Shutdown::Both);
                    let _ = dst_writer.shutdown(Shutdown::Both);
                    return;
                }
            }
            let _ = dst_writer.shutdown(Shutdown::Write);
        });
        let mut src = src;
        let mut free = opened + link.rtt;
        let mut buf = vec![0u8; 1 << 16];
        loop {
            let n = match src.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            let now = Instant::now();
            let serialize = if link.bps == 0 {
                Duration::ZERO
            } else {
                Duration::from_secs_f64(n as f64 * 8.0 / link.bps as f64)
            };
            let depart = now.max(free) + serialize;
            free = depart;
            if tx.send((depart + link.rtt / 2, buf[..n].to_vec())).is_err() {
                break;
            }
        }
        drop(tx);
        let _ = src.shutdown(Shutdown::Read);
        let _ = writer.join();
    })
}

/// A proxy for one connection between the relaunched app and the daemon.
struct Proxy {
    path: PathBuf,
    handle: JoinHandle<()>,
}

impl Proxy {
    fn start(dir: &Path, upstream: &Path, link: &Link, round: usize) -> Self {
        let path = dir.join(format!("link-{}-{round}.sock", link.name));
        let _ = fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        let upstream = upstream.to_path_buf();
        let link = link.clone();
        let handle = std::thread::spawn(move || {
            let Ok((client, _)) = listener.accept() else { return };
            let opened = Instant::now();
            drop(listener);
            let Ok(daemon) = UnixStream::connect(&upstream) else { return };
            let up = pipe(client.try_clone().unwrap(), daemon.try_clone().unwrap(), &link, opened);
            let down = pipe(daemon, client, &link, opened);
            let _ = up.join();
            let _ = down.join();
        });
        Self { path, handle }
    }

    /// Every thread of the proxy has ended once the connection closed.
    fn finish(self) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !self.handle.is_finished() {
            assert!(
                Instant::now() < deadline,
                "the link proxy did not stop after its connection closed"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        let _ = self.handle.join();
        let _ = fs::remove_file(&self.path);
    }
}

// ---------------------------------------------------------------------------
// The relaunched app's terminal.

/// A terminal restored from a GHOSTSNP READY, as the Mac surface restores it.
struct SnapshotTerm(sys::GhosttyTerminal);

impl SnapshotTerm {
    fn restore(ready: &[u8]) -> Self {
        let mut decoder: sys::GhosttySnapshotDecoder = std::ptr::null_mut();
        // SAFETY: `ready` outlives the decoder, which is freed below.
        let result = unsafe {
            sys::ghostty_snapshot_decoder_new_buf(
                std::ptr::null(),
                &mut decoder,
                ready.as_ptr(),
                ready.len(),
            )
        };
        assert_eq!(result, sys::GHOSTTY_SUCCESS, "snapshot decoder");
        let mut terminal: sys::GhosttyTerminal = std::ptr::null_mut();
        // SAFETY: the decoder is live; on success the terminal is ours.
        let result = unsafe { sys::ghostty_snapshot_decoder_ready(decoder, &mut terminal) };
        // SAFETY: freeing the decoder leaves the READY terminal usable (snapshot.h).
        unsafe { sys::ghostty_snapshot_decoder_free(decoder) };
        assert_eq!(result, sys::GHOSTTY_SUCCESS, "snapshot READY restore");
        Self(terminal)
    }

    fn write(&mut self, bytes: &[u8]) {
        // SAFETY: the terminal is live and owned here.
        unsafe { sys::ghostty_terminal_vt_write(self.0, bytes.as_ptr(), bytes.len()) };
    }

    fn get_u16(&self, data: sys::GhosttyTerminalData) -> u16 {
        let mut out = 0u16;
        // SAFETY: COLS, ROWS and CURSOR_X/Y are u16 (terminal.h).
        unsafe { sys::ghostty_terminal_get(self.0, data, (&mut out as *mut u16).cast()) };
        out
    }

    fn grid_ref(&self, x: u16, y: u16) -> sys::GhosttyGridRef {
        let point = sys::GhosttyPoint {
            tag: sys::GHOSTTY_POINT_TAG_VIEWPORT,
            value: sys::GhosttyPointValue {
                coordinate: sys::GhosttyPointCoordinate { x, y: u32::from(y) },
            },
        };
        let mut out =
            sys::GhosttyGridRef { size: size_of::<sys::GhosttyGridRef>(), ..Default::default() };
        // SAFETY: the terminal is live; `out` is sized.
        let result = unsafe { sys::ghostty_terminal_grid_ref(self.0, point, &mut out) };
        assert_eq!(result, sys::GHOSTTY_SUCCESS, "grid ref {x},{y}");
        out
    }

    /// The viewport as plain text, trimmed, wrapped rows kept apart: the
    /// formatter options `Terminal::viewport_text` uses.
    fn viewport_text(&self) -> String {
        let cols = self.get_u16(sys::GHOSTTY_TERMINAL_DATA_COLS);
        let rows = self.get_u16(sys::GHOSTTY_TERMINAL_DATA_ROWS);
        let selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: self.grid_ref(0, 0),
            end: self.grid_ref(cols.saturating_sub(1), rows.saturating_sub(1)),
            rectangle: false,
        };
        let options = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
            unwrap: false,
            trim: true,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                ..Default::default()
            },
            selection: &selection,
        };
        let mut formatter: sys::GhosttyFormatter = std::ptr::null_mut();
        // SAFETY: the terminal outlives the formatter, freed below.
        let result = unsafe {
            sys::ghostty_formatter_terminal_new(std::ptr::null(), &mut formatter, self.0, options)
        };
        assert_eq!(result, sys::GHOSTTY_SUCCESS, "formatter");
        let mut needed = 0usize;
        // SAFETY: a size query with no buffer.
        unsafe {
            sys::ghostty_formatter_format_buf(formatter, std::ptr::null_mut(), 0, &mut needed)
        };
        let mut buf = vec![0u8; needed.max(1)];
        let mut written = 0usize;
        // SAFETY: `buf` holds `needed` bytes.
        let result = unsafe {
            sys::ghostty_formatter_format_buf(formatter, buf.as_mut_ptr(), buf.len(), &mut written)
        };
        // SAFETY: the formatter is ours.
        unsafe { sys::ghostty_formatter_free(formatter) };
        assert_eq!(result, sys::GHOSTTY_SUCCESS, "format");
        buf.truncate(written);
        String::from_utf8_lossy(&buf).into_owned()
    }

    fn cursor(&self) -> (u16, u16) {
        (
            self.get_u16(sys::GHOSTTY_TERMINAL_DATA_CURSOR_X),
            self.get_u16(sys::GHOSTTY_TERMINAL_DATA_CURSOR_Y),
        )
    }
}

impl Drop for SnapshotTerm {
    fn drop(&mut self) {
        // SAFETY: the terminal is ours.
        unsafe { sys::ghostty_terminal_free(self.0) };
    }
}

enum ClientTerm {
    Bytes(Box<Terminal>),
    Snapshot(SnapshotTerm),
}

/// What the view shows: its text and where its cursor is.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
struct Shown {
    text: String,
    cursor: (u16, u16),
}

impl Shown {
    fn has_content(&self) -> bool {
        self.text.chars().any(|c| !c.is_whitespace())
    }
}

impl ClientTerm {
    fn write(&mut self, bytes: &[u8]) {
        match self {
            Self::Bytes(term) => term.vt_write(bytes),
            Self::Snapshot(term) => term.write(bytes),
        }
    }

    fn shown(&mut self) -> Shown {
        match self {
            Self::Bytes(term) => Shown {
                text: term.viewport_text().unwrap_or_default(),
                cursor: term.cursor_position().unwrap_or_default(),
            },
            Self::Snapshot(term) => Shown { text: term.viewport_text(), cursor: term.cursor() },
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum AttachMode {
    Snapshot,
    Bytes,
}

impl AttachMode {
    fn name(self) -> &'static str {
        match self {
            Self::Snapshot => "snapshot",
            Self::Bytes => "bytes",
        }
    }
}

#[derive(Debug, Clone)]
struct Round {
    first_content_ms: Option<f64>,
    settled_ms: Option<f64>,
    changes_after_first: usize,
    bytes_at_settled: usize,
    bytes_total: usize,
    replied_ms: Option<f64>,
    /// The attach the daemon answered with (`snapshot` or `bytes`).
    served: Option<AttachMode>,
    capped: bool,
    shown: Shown,
}

fn ms(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 10_000.0).round() / 10.0
}

/// One relaunch: connect to `path`, attach the way the app does, record what
/// the view shows until it has been still for [`QUIET`] (or [`CAP`]).
fn reattach(path: &Path, target: &Target, mode: AttachMode) -> Round {
    let engine = base64::engine::general_purpose::STANDARD;
    let started = Instant::now();
    let mut stream = UnixStream::connect(path).unwrap();
    stream.set_read_timeout(Some(POLL)).unwrap();
    let mut writer = stream.try_clone().unwrap();
    // Pipelined, as TerminalAttachment.open sends them.
    let set_client_info = json!({
        "id": 2, "cmd": "set-client-info", "name": "cmux-next-terminal", "kind": "frontend",
        "capabilities": APP_CAPABILITIES, "device_kind": "mac", "device_name": "restart-settled",
    });
    writer
        .write_all(
            format!("{}\n{}\n", json!({"id": 1, "cmd": "identify"}), set_client_info).as_bytes(),
        )
        .unwrap();

    let mut identity: Option<Value> = None;
    let mut info_ok = false;
    let mut attach_sent = false;
    let mut replied_ms = None;
    let mut served = None;
    let mut term: Option<ClientTerm> = None;
    let mut pending: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 1 << 16];
    let mut bytes = 0usize;
    let mut last = Shown::default();
    let mut first_content: Option<Duration> = None;
    let mut last_change: Option<(Duration, usize)> = None;
    let mut changes_after_first = 0usize;
    let mut capped = false;
    loop {
        let elapsed = started.elapsed();
        if let Some((at, _)) = last_change
            && replied_ms.is_some()
            && elapsed >= at + QUIET
        {
            break;
        }
        if elapsed >= CAP {
            capped = true;
            break;
        }
        let n = match stream.read(&mut buf) {
            Ok(0) => panic!("the daemon closed the attach after {bytes} bytes"),
            Ok(n) => n,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(error) => panic!("attach read: {error}"),
        };
        bytes += n;
        pending.extend_from_slice(&buf[..n]);
        let mut consumed = 0;
        while let Some(offset) = pending[consumed..].iter().position(|b| *b == b'\n') {
            let line = &pending[consumed..consumed + offset];
            consumed += offset + 1;
            let message: Value = match serde_json::from_slice(line) {
                Ok(message) => message,
                Err(error) => {
                    panic!("unreadable attach line ({error}): {}", String::from_utf8_lossy(line))
                }
            };
            let decode = |key: &str| {
                message[key]
                    .as_str()
                    .map(|data| engine.decode(data).expect("base64"))
                    .unwrap_or_default()
            };
            match message["event"].as_str() {
                None => {
                    let ok = message["ok"] == true;
                    assert!(ok, "request {} failed: {message}", message["id"]);
                    match message["id"].as_u64() {
                        Some(1) => identity = Some(message["data"].clone()),
                        Some(2) => info_ok = true,
                        Some(3) => replied_ms = Some(ms(started.elapsed())),
                        _ => {}
                    }
                }
                Some("vt-state") | Some("resized") => {
                    let cols = message["cols"].as_u64().unwrap_or(u64::from(COLS)) as u16;
                    let rows = message["rows"].as_u64().unwrap_or(u64::from(ROWS)) as u16;
                    let replay = if message.get("replay").is_some() {
                        decode("replay")
                    } else {
                        decode("data")
                    };
                    let mut fresh =
                        Terminal::new(cols, rows, 10 << 20, Callbacks::default()).unwrap();
                    fresh.vt_write(&replay);
                    fresh.vt_write(&decode("pending"));
                    term = Some(ClientTerm::Bytes(Box::new(fresh)));
                    served.get_or_insert(AttachMode::Bytes);
                }
                // Only the ready snapshot sets the screen. History chunks
                // (deflate) restore scrollback only: the viewport never shows
                // them, so they fall to the last arm and count as bytes.
                Some("snapshot") if message["phase"] == "ready" => {
                    term = Some(ClientTerm::Snapshot(SnapshotTerm::restore(&decode("data"))));
                    served.get_or_insert(AttachMode::Snapshot);
                }
                Some("output") => {
                    if let Some(term) = term.as_mut() {
                        term.write(&decode("data"));
                    }
                }
                _ => {}
            }
        }
        pending.drain(..consumed);
        if !attach_sent
            && info_ok
            && let Some(identity) = identity.as_ref()
        {
            let supports = |cap: &str| {
                identity["capabilities"]
                    .as_array()
                    .is_some_and(|caps| caps.iter().any(|c| c == cap))
            };
            let mut attach = json!({"id": 3, "cmd": "attach-surface", "mode": "bytes", "cols": COLS, "rows": ROWS});
            if supports("attach-identity-v1") {
                attach["expected_generation"] = identity["generation"].clone();
                attach["expected_terminal_id"] = json!(target.terminal_id);
            } else {
                attach["surface"] = json!(target.surface);
            }
            if mode == AttachMode::Snapshot && supports("terminal-snapshot-history-v1") {
                attach["snapshot"] = json!("ghostsnp");
                attach["snapshot_version"] = json!(ghostty_vt::snapshot_version());
                if supports("terminal-snapshot-local-history-v1") {
                    attach["snapshot_local_history"] = json!(true);
                }
            }
            writer.write_all(format!("{attach}\n").as_bytes()).unwrap();
            attach_sent = true;
        }
        if let Some(term) = term.as_mut() {
            let shown = term.shown();
            if shown != last {
                let at = started.elapsed();
                if shown.has_content() {
                    if first_content.is_none() {
                        first_content = Some(at);
                    } else {
                        changes_after_first += 1;
                    }
                }
                if first_content.is_some() {
                    last_change = Some((at, bytes));
                }
                last = shown;
            }
        }
    }
    drop(writer);
    let _ = stream.shutdown(Shutdown::Both);
    Round {
        first_content_ms: first_content.map(ms),
        settled_ms: last_change.map(|(at, _)| ms(at)),
        changes_after_first,
        bytes_at_settled: last_change.map(|(_, bytes)| bytes).unwrap_or(bytes),
        bytes_total: bytes,
        replied_ms,
        served,
        capped,
        shown: last,
    }
}

fn median(values: &mut [f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mid = values.len() / 2;
    Some(if values.len() % 2 == 1 { values[mid] } else { (values[mid - 1] + values[mid]) / 2.0 })
}

/// The fixture is where Claude Code draws it: the status line on the last
/// row, the box above it, the cursor in the box after `> `, and the last
/// answer above the box.
fn fixture_in_place(shown: &Shown) -> Result<(), String> {
    let mut lines: Vec<&str> = shown.text.split('\n').collect();
    lines.resize(usize::from(ROWS), "");
    let row = |r: usize| lines[r].trim_end();
    let last = usize::from(ROWS) - 1;
    if row(last) != STATUS.trim_end() {
        return Err(format!("row {last} is {:?}, not the status line", row(last)));
    }
    if !row(last - 1).starts_with('╰')
        || !row(last - 3).starts_with('╭')
        || !row(last - 2).starts_with("│ >")
    {
        return Err(format!("rows {}..{} are not the input box", last - 3, last - 1));
    }
    if shown.cursor != (4, (last - 2) as u16) {
        return Err(format!("the cursor is at {:?}, not in the box after `> `", shown.cursor));
    }
    let answers = lines[..last - 3].iter().rev().find(|line| line.contains("Answer"));
    if !answers.is_some_and(|line| line.contains(&format!("Answer {TURNS}:"))) {
        return Err(format!("the last answer above the box is {answers:?}"));
    }
    Ok(())
}

#[test]
#[ignore = "measurement: cargo test --release -p cmux-tui --test it -- terminal_restart_settled:: --ignored --nocapture"]
fn terminal_restart_to_settled_per_link() {
    let rounds: usize =
        std::env::var("ROUNDS").ok().and_then(|value| value.parse().ok()).unwrap_or(5).max(1);
    let modes = match std::env::var("RESTART_ATTACH").as_deref() {
        Ok("snapshot") => vec![AttachMode::Snapshot],
        Ok("bytes") => vec![AttachMode::Bytes],
        _ => vec![AttachMode::Snapshot, AttachMode::Bytes],
    };
    let links = links();
    let daemon = Daemon::start();
    let target = prepare(&daemon);
    eprintln!(
        "TERMINAL_RESTART: surface {} ({}) at {COLS}x{ROWS}, fixture {} bytes, {rounds} rounds, links {:?}",
        target.surface,
        target.terminal_id,
        fixture().len(),
        links.iter().map(|link| &link.name).collect::<Vec<_>>()
    );

    for mode in modes {
        // The reference: a direct attach (no proxy) of the same kind.
        let direct = reattach(&daemon.socket, &target, mode);
        std::thread::sleep(Duration::from_millis(200));
        let fixture_ok = fixture_in_place(&direct.shown);
        if let Err(why) = &fixture_ok {
            eprintln!(
                "TERMINAL_RESTART: direct {} attach: {why}\n{}",
                mode.name(),
                direct.shown.text
            );
        }
        for link in &links {
            let mut runs = Vec::new();
            for round in 0..rounds {
                let proxy = Proxy::start(&daemon.dir, &daemon.socket, link, round);
                let run = reattach(&proxy.path, &target, mode);
                proxy.finish();
                // The daemon drops the closed viewer before the next relaunch.
                std::thread::sleep(Duration::from_millis(200));
                runs.push(run);
            }
            let pick = |f: fn(&Round) -> Option<f64>| {
                let mut values: Vec<f64> = runs.iter().filter_map(f).collect();
                median(&mut values)
            };
            let final_ok = runs.iter().all(|run| run.shown == direct.shown);
            let mismatch = runs.iter().position(|run| run.shown != direct.shown);
            if let Some(index) = mismatch {
                eprintln!(
                    "TERMINAL_RESTART: {} {} round {index} ended on a different screen than the direct attach:\n{}\n--- direct:\n{}",
                    link.name,
                    mode.name(),
                    runs[index].shown.text,
                    direct.shown.text
                );
            }
            let served: BTreeMap<&str, usize> =
                runs.iter().fold(BTreeMap::new(), |mut counts, run| {
                    *counts
                        .entry(run.served.map(AttachMode::name).unwrap_or("none"))
                        .or_default() += 1;
                    counts
                });
            let line = json!({
                "link": link.name,
                "rttMs": ms(link.rtt),
                "bps": link.bps,
                "attach": mode.name(),
                "served": served,
                "firstContentMs": pick(|run| run.first_content_ms),
                "settledMs": pick(|run| run.settled_ms),
                "changesAfterFirst": pick(|run| Some(run.changes_after_first as f64)),
                "bytes": pick(|run| Some(run.bytes_at_settled as f64)),
                "bytesTotal": pick(|run| Some(run.bytes_total as f64)),
                "attachReplyMs": pick(|run| run.replied_ms),
                "finalScreenOk": final_ok,
                "fixtureInPlace": fixture_ok.is_ok(),
                "capped": runs.iter().filter(|run| run.capped).count(),
                "rounds": rounds,
                "firstContentMsAll": runs.iter().map(|run| run.first_content_ms).collect::<Vec<_>>(),
                "settledMsAll": runs.iter().map(|run| run.settled_ms).collect::<Vec<_>>(),
                "cols": COLS,
                "rows": ROWS,
            });
            let prefix = match mode {
                AttachMode::Snapshot => "TERMINAL_RESTART_JSON",
                AttachMode::Bytes => "TERMINAL_RESTART_BYTES_JSON",
            };
            println!("{prefix} {line}");
        }
    }
}
