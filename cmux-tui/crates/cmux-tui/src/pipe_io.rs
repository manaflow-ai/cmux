//! Renderer-less byte relay for embedder-fed (manual-IO) surfaces.
//!
//! `cmux attach --terminal <id> --pipe-io` is the scoped attach client minus
//! the renderer: the embedder (the macOS GUI's manual-mirror Ghostty
//! surface) parses the byte stream itself, so this process only relays.
//!
//! Contract:
//! - stdout: raw VT bytes — the daemon replay first, then live PTY output.
//!   A replay that is not the relay's first output is prefixed with a full
//!   reset (`ESC c` + erase-scrollback) because a daemon replay REPLACES
//!   terminal state while a byte stream can only append.
//! - stdin: JSON lines — `{"input":"<base64>"}` forwards raw bytes to the
//!   daemon terminal's PTY; `{"resize":{"cols":N,"rows":N}}` drives the
//!   daemon-side viewer size. Unknown keys are ignored (forward compat);
//!   stdin EOF means the embedder is gone and ends the relay cleanly.
//! - stderr: one final JSON line `{"exit":{"reason":...}}`.
//! - exit code: 0 when the terminal ended or the embedder closed stdin (do
//!   not respawn), 2 when the daemon connection was lost (respawning
//!   reattaches and resyncs from a fresh replay).

use std::io::{BufRead, Write};
use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, SyncSender};

use base64::Engine as _;
use cmux_tui_core::SurfaceId;
use cmux_tui_core::resource::TerminalPublicId;

use crate::session::{PipeIoEvent, RemoteSession, Session, SurfaceAttach, SurfaceHandle};

/// The terminal ended, or the embedder walked away: respawning is wrong.
pub const EXIT_DO_NOT_RESPAWN: i32 = 0;
/// The daemon connection was lost: the embedder may respawn to resync.
pub const EXIT_DAEMON_LOST: i32 = 2;

/// Bounded event queue between the session reader thread and the stdout
/// pump. A full queue means the embedder stopped reading; the session
/// treats that as a lost transport rather than wedging its reader thread.
const EVENT_QUEUE_CAPACITY: usize = 4096;

/// Emitted before any replay that is not the relay's first output: full
/// reset plus erase-scrollback, so the replacement replay does not stack on
/// top of the embedder's previous terminal state.
const REPLAY_RESET: &[u8] = b"\x1bc\x1b[3J";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipeIoExitReason {
    TerminalEnded,
    DaemonLost,
    ParentClosed,
}

impl PipeIoExitReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TerminalEnded => "terminal-ended",
            Self::DaemonLost => "daemon-lost",
            Self::ParentClosed => "parent-closed",
        }
    }

    pub fn exit_code(self) -> i32 {
        match self {
            Self::TerminalEnded | Self::ParentClosed => EXIT_DO_NOT_RESPAWN,
            Self::DaemonLost => EXIT_DAEMON_LOST,
        }
    }
}

/// One parsed stdin line.
#[derive(Debug, PartialEq, Eq)]
pub enum PipeIoRequest {
    Input(Vec<u8>),
    Resize {
        cols: u16,
        rows: u16,
    },
    /// A well-formed line carrying no verb this relay knows: ignored, so a
    /// newer embedder can talk to an older relay.
    Unknown,
}

pub fn parse_request(line: &str) -> anyhow::Result<PipeIoRequest> {
    let value: serde_json::Value = serde_json::from_str(line)?;
    if let Some(encoded) = value.get("input").and_then(serde_json::Value::as_str) {
        let bytes = base64::engine::general_purpose::STANDARD.decode(encoded)?;
        return Ok(PipeIoRequest::Input(bytes));
    }
    if let Some(resize) = value.get("resize") {
        let cols = resize.get("cols").and_then(serde_json::Value::as_u64);
        let rows = resize.get("rows").and_then(serde_json::Value::as_u64);
        let (Some(cols), Some(rows)) = (cols, rows) else {
            anyhow::bail!("resize needs numeric cols and rows");
        };
        let (cols, rows) = (u16::try_from(cols)?, u16::try_from(rows)?);
        return Ok(PipeIoRequest::Resize { cols: cols.max(1), rows: rows.max(1) });
    }
    Ok(PipeIoRequest::Unknown)
}

pub fn run(
    session: &Session,
    remote: &Arc<RemoteSession>,
    socket_path: &Path,
    terminal: &TerminalPublicId,
    surface: SurfaceId,
    cols: u16,
    rows: u16,
) -> anyhow::Result<PipeIoExitReason> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(EVENT_QUEUE_CAPACITY);
    // Install before attach so the initial replay cannot be missed.
    remote.install_pipe_io_tap(surface, sender.clone());
    let handle = match session.try_surface_sized(surface, Some((cols.max(1), rows.max(1))))? {
        SurfaceAttach::Attached(handle) => handle,
        SurfaceAttach::Retired | SurfaceAttach::Missing => {
            return Ok(PipeIoExitReason::TerminalEnded);
        }
        SurfaceAttach::Deferred => anyhow::bail!("terminal attach was deferred by the server"),
    };
    // The daemon resizes a terminal's PTY only for its geometry-authority
    // client (the full TUI client claims this for its active surface). The
    // relay is the embedder's only viewer of this terminal, so claim the
    // authority or every embedder resize is recorded but never applied.
    if let Err(error) = session.claim_terminal_geometry(surface) {
        eprintln!(
            "{}",
            serde_json::json!({"diag": {"claim-terminal-geometry": {"error": error.to_string()}}})
        );
    }
    spawn_stdin_pump(handle, sender);
    let reason = pump_events_to_stdout(&receiver, &mut std::io::stdout().lock())?;
    if reason == PipeIoExitReason::DaemonLost {
        return Ok(classify_daemon_loss(remote, socket_path, terminal));
    }
    Ok(reason)
}

/// The stream ended without a terminal-exit event, but "stream lost" covers
/// two situations the embedder must tell apart: the daemon really is
/// unreachable (respawn until it returns), or the terminal was closed and
/// the daemon tore the scoped stream down before the exit event reached us
/// (never respawn). One bounded probe of the daemon resolves it: prefer the
/// existing connection, and fall back to a fresh connect when the socket
/// died with the stream.
fn classify_daemon_loss(
    remote: &Arc<RemoteSession>,
    socket_path: &Path,
    terminal: &TerminalPublicId,
) -> PipeIoExitReason {
    let terminal_still_exists =
        remote.refresh_tree().ok().map(|tree| tree.resolve_terminal(terminal).is_some()).or_else(
            || {
                let probe = RemoteSession::connect_for_terminal_attach(socket_path).ok()?;
                let tree = probe.refresh_tree().ok()?;
                Some(tree.resolve_terminal(terminal).is_some())
            },
        );
    match terminal_still_exists {
        Some(false) => PipeIoExitReason::TerminalEnded,
        Some(true) | None => PipeIoExitReason::DaemonLost,
    }
}

/// Forwards embedder requests from stdin until EOF, then reports the closed
/// parent through the shared event queue.
fn spawn_stdin_pump(handle: SurfaceHandle, sender: SyncSender<PipeIoEvent>) {
    std::thread::Builder::new()
        .name("pipe-io-stdin".into())
        .spawn(move || {
            let stdin = std::io::stdin();
            for line in stdin.lock().lines() {
                let Ok(line) = line else { break };
                if line.trim().is_empty() {
                    continue;
                }
                match parse_request(&line) {
                    Ok(PipeIoRequest::Input(bytes)) => {
                        if handle.write_bytes(&bytes).is_err() {
                            // The transport owns loss reporting; input can
                            // only stop early.
                            break;
                        }
                    }
                    Ok(PipeIoRequest::Resize { cols, rows }) => {
                        // Diagnostics only; the exit JSON stays the final
                        // stderr line and embedders skip lines without an
                        // "exit" key.
                        match handle.resize(cols, rows) {
                            Ok(accepted) => eprintln!(
                                "{}",
                                serde_json::json!({
                                    "diag": {"resize": {"cols": cols, "rows": rows, "accepted": accepted}}
                                })
                            ),
                            Err(error) => eprintln!(
                                "{}",
                                serde_json::json!({
                                    "diag": {"resize": {"cols": cols, "rows": rows, "error": error.to_string()}}
                                })
                            ),
                        }
                    }
                    Ok(PipeIoRequest::Unknown) => {}
                    // A malformed line means the embedder side is broken;
                    // stop consuming rather than misinterpreting input.
                    Err(_) => break,
                }
            }
            // Blocking send: the queue is drained until the main loop
            // returns, and a dropped receiver just ends this thread.
            let _ = sender.send(PipeIoEvent::StdinClosed);
        })
        .expect("spawn pipe-io stdin pump");
}

fn pump_events_to_stdout(
    receiver: &Receiver<PipeIoEvent>,
    stdout: &mut impl Write,
) -> anyhow::Result<PipeIoExitReason> {
    let mut emitted_output = false;
    loop {
        // A dropped sender without a prior event means the session went
        // away wholesale: report it as a lost daemon.
        let Ok(event) = receiver.recv() else {
            return Ok(PipeIoExitReason::DaemonLost);
        };
        let write_result = match &event {
            PipeIoEvent::Replay { bytes } => {
                let reset = if emitted_output { stdout.write_all(REPLAY_RESET) } else { Ok(()) };
                reset.and_then(|()| stdout.write_all(bytes)).and_then(|()| stdout.flush())
            }
            PipeIoEvent::Output(bytes) => stdout.write_all(bytes).and_then(|()| stdout.flush()),
            PipeIoEvent::SurfaceExited => return Ok(PipeIoExitReason::TerminalEnded),
            PipeIoEvent::TransportLost => return Ok(PipeIoExitReason::DaemonLost),
            PipeIoEvent::StdinClosed => return Ok(PipeIoExitReason::ParentClosed),
        };
        if write_result.is_err() {
            // stdout is the embedder; a failed write means it is gone.
            return Ok(PipeIoExitReason::ParentClosed);
        }
        emitted_output = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn replay(bytes: &[u8]) -> PipeIoEvent {
        PipeIoEvent::Replay { bytes: bytes.to_vec() }
    }

    #[test]
    fn parse_request_decodes_input_resize_and_ignores_unknown_verbs() {
        assert_eq!(
            parse_request(r#"{"input":"aGk="}"#).unwrap(),
            PipeIoRequest::Input(b"hi".to_vec())
        );
        assert_eq!(
            parse_request(r#"{"resize":{"cols":100,"rows":30}}"#).unwrap(),
            PipeIoRequest::Resize { cols: 100, rows: 30 }
        );
        assert_eq!(
            parse_request(r#"{"resize":{"cols":0,"rows":0}}"#).unwrap(),
            PipeIoRequest::Resize { cols: 1, rows: 1 }
        );
        assert_eq!(parse_request(r#"{"future-verb":true}"#).unwrap(), PipeIoRequest::Unknown);
        assert!(parse_request("not json").is_err());
        assert!(parse_request(r#"{"input":"@@not-base64@@"}"#).is_err());
        assert!(parse_request(r#"{"resize":{"cols":100}}"#).is_err());
    }

    #[test]
    fn exit_reasons_map_to_the_respawn_contract() {
        assert_eq!(PipeIoExitReason::TerminalEnded.exit_code(), EXIT_DO_NOT_RESPAWN);
        assert_eq!(PipeIoExitReason::ParentClosed.exit_code(), EXIT_DO_NOT_RESPAWN);
        assert_eq!(PipeIoExitReason::DaemonLost.exit_code(), EXIT_DAEMON_LOST);
        assert_eq!(PipeIoExitReason::TerminalEnded.as_str(), "terminal-ended");
        assert_eq!(PipeIoExitReason::DaemonLost.as_str(), "daemon-lost");
        assert_eq!(PipeIoExitReason::ParentClosed.as_str(), "parent-closed");
    }

    #[test]
    fn stdout_pump_prefixes_only_non_initial_replays_with_a_full_reset() {
        let (sender, receiver) = std::sync::mpsc::sync_channel(8);
        sender.send(replay(b"FIRST")).unwrap();
        sender.send(PipeIoEvent::Output(b"live".to_vec())).unwrap();
        sender.send(replay(b"SECOND")).unwrap();
        sender.send(PipeIoEvent::SurfaceExited).unwrap();
        let mut stdout = Vec::new();
        let reason = pump_events_to_stdout(&receiver, &mut stdout).unwrap();
        assert_eq!(reason, PipeIoExitReason::TerminalEnded);
        let mut expected = b"FIRSTlive".to_vec();
        expected.extend_from_slice(REPLAY_RESET);
        expected.extend_from_slice(b"SECOND");
        assert_eq!(stdout, expected);
    }

    #[test]
    fn stdout_pump_maps_lifecycle_events_to_exit_reasons() {
        for (event, expected) in [
            (PipeIoEvent::TransportLost, PipeIoExitReason::DaemonLost),
            (PipeIoEvent::StdinClosed, PipeIoExitReason::ParentClosed),
        ] {
            let (sender, receiver) = std::sync::mpsc::sync_channel(8);
            sender.send(event).unwrap();
            let mut stdout = Vec::new();
            assert_eq!(pump_events_to_stdout(&receiver, &mut stdout).unwrap(), expected);
            assert!(stdout.is_empty());
        }
        // Sender dropped without any event: the session vanished wholesale.
        let (sender, receiver) = std::sync::mpsc::sync_channel::<PipeIoEvent>(8);
        drop(sender);
        let mut stdout = Vec::new();
        assert_eq!(
            pump_events_to_stdout(&receiver, &mut stdout).unwrap(),
            PipeIoExitReason::DaemonLost
        );
    }
}
