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

use std::io::{self, BufRead, Read, Write};
use std::path::Path;
use std::sync::Arc;

use base64::Engine as _;
use cmux_tui_core::SurfaceId;
use cmux_tui_core::resource::TerminalPublicId;

use crate::session::{
    PipeIoEvent, PipeIoQueue, PipeIoQueuePushError, RemoteSession, Session, SurfaceAttach,
    SurfaceHandle, is_remote_surface_unavailable, is_remote_transport_failure,
};

/// The terminal ended, or the embedder walked away: respawning is wrong.
pub const EXIT_DO_NOT_RESPAWN: i32 = 0;
/// The daemon connection was lost: the embedder may respawn to resync.
pub const EXIT_DAEMON_LOST: i32 = 2;

/// Bound one stdin frame before JSON parsing and base64 decoding. The
/// embedder sends keyboard and paste chunks, so a one-megabyte decoded limit
/// is large enough for normal input while keeping a hostile parent from
/// turning one line into an unbounded allocation.
const MAX_PIPE_IO_INPUT_BYTES: usize = 1024 * 1024;
/// The line bound includes the JSON bytes and its newline. It leaves room for
/// base64 expansion and the small JSON envelope around one input chunk.
const MAX_PIPE_IO_REQUEST_LINE_BYTES: usize = 2 * 1024 * 1024;
const MAX_PIPE_IO_INPUT_BASE64_BYTES: usize = MAX_PIPE_IO_INPUT_BYTES.div_ceil(3) * 4;

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
        anyhow::ensure!(
            encoded.len() <= MAX_PIPE_IO_INPUT_BASE64_BYTES,
            "input exceeds the {MAX_PIPE_IO_INPUT_BYTES}-byte limit"
        );
        let bytes = base64::engine::general_purpose::STANDARD.decode(encoded)?;
        anyhow::ensure!(
            bytes.len() <= MAX_PIPE_IO_INPUT_BYTES,
            "input exceeds the {MAX_PIPE_IO_INPUT_BYTES}-byte limit"
        );
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

/// Read one complete JSON line without allowing `BufRead::lines` to allocate
/// an attacker-controlled amount of memory. A final, shorter line at EOF is
/// accepted, matching the standard `lines` behavior.
fn read_request_line(reader: &mut impl BufRead, line: &mut String) -> io::Result<bool> {
    line.clear();
    let mut limited = reader.take((MAX_PIPE_IO_REQUEST_LINE_BYTES + 1) as u64);
    let bytes_read = limited.read_line(line)?;
    if bytes_read == 0 {
        return Ok(false);
    }
    if bytes_read > MAX_PIPE_IO_REQUEST_LINE_BYTES
        || (bytes_read == MAX_PIPE_IO_REQUEST_LINE_BYTES && !line.ends_with('\n'))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "pipe-io request line exceeds its byte limit",
        ));
    }
    Ok(true)
}

struct PipeIoTapGuard<'a> {
    remote: &'a RemoteSession,
    id: u64,
}

impl Drop for PipeIoTapGuard<'_> {
    fn drop(&mut self) {
        self.remote.clear_pipe_io_tap(self.id);
    }
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
    let queue = Arc::new(PipeIoQueue::new());
    // Install before attach so the initial replay cannot be missed.
    let tap_id = remote.install_pipe_io_tap(surface, queue.clone());
    let tap_guard = PipeIoTapGuard { remote, id: tap_id };
    let handle = match session.try_surface_sized(surface, Some((cols.max(1), rows.max(1)))) {
        Ok(SurfaceAttach::Attached(handle)) => handle,
        Ok(SurfaceAttach::Retired | SurfaceAttach::Missing) => {
            return Ok(PipeIoExitReason::TerminalEnded);
        }
        Ok(SurfaceAttach::Deferred) => anyhow::bail!("terminal attach was deferred by the server"),
        Err(error) if is_remote_transport_failure(&error) => {
            return Ok(PipeIoExitReason::DaemonLost);
        }
        Err(error) if is_remote_surface_unavailable(&error, surface) => {
            return Ok(PipeIoExitReason::TerminalEnded);
        }
        Err(error) => return Err(error),
    };
    // The daemon resizes a terminal's PTY only for its geometry-authority
    // client (the full TUI client claims this for its active surface). The
    // relay is the embedder's only viewer of this terminal, so claim the
    // authority or every embedder resize is recorded but never applied.
    if session.claim_terminal_geometry(surface).is_err() {
        eprintln!(
            "{}",
            serde_json::json!({"diag": {"claim-terminal-geometry": {"code": "claim_failed"}}})
        );
    }
    spawn_stdin_pump(handle, queue.clone());
    let reason = pump_events_to_stdout(&queue, &mut std::io::stdout().lock())?;
    // Stop forwarding while the daemon probe runs. Otherwise events can fill
    // the abandoned queue and falsely disconnect the session during probing.
    drop(tap_guard);
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
fn spawn_stdin_pump(handle: SurfaceHandle, queue: Arc<PipeIoQueue>) {
    std::thread::Builder::new()
        .name("pipe-io-stdin".into())
        .spawn(move || {
            let stdin = std::io::stdin();
            let mut reader = stdin.lock();
            let mut line = String::new();
            let mut transport_lost = false;
            loop {
                let Ok(has_line) = read_request_line(&mut reader, &mut line) else { break };
                if !has_line {
                    break;
                }
                if line.trim().is_empty() {
                    continue;
                }
                match parse_request(&line) {
                    Ok(PipeIoRequest::Input(bytes)) => {
                        if handle.write_bytes(&bytes).is_err() {
                            // A failed input write is a transport failure, not
                            // a clean parent close. Signal it out of band so
                            // it cannot race a queued StdinClosed event.
                            queue.signal_transport_lost();
                            transport_lost = true;
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
                            Err(_error) => eprintln!(
                                "{}",
                                serde_json::json!({
                                    "diag": {"resize": {"cols": cols, "rows": rows, "code": "resize_failed"}}
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
            if !transport_lost {
                let _ = queue.push(PipeIoEvent::StdinClosed);
            }
        })
        .expect("spawn pipe-io stdin pump");
}

fn pump_events_to_stdout(
    queue: &PipeIoQueue,
    stdout: &mut impl Write,
) -> anyhow::Result<PipeIoExitReason> {
    let mut emitted_output = false;
    loop {
        // A dropped sender without a prior event means the session went
        // away wholesale: report it as a lost daemon.
        let Some(event) = queue.recv() else {
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
    fn parse_request_rejects_oversized_input_before_decoding() {
        let encoded =
            base64::engine::general_purpose::STANDARD
                .encode(vec![b'x'; MAX_PIPE_IO_INPUT_BYTES + 1]);
        let line = serde_json::json!({"input": encoded}).to_string();
        assert!(parse_request(&line).is_err());
    }

    #[test]
    fn request_line_reader_rejects_unterminated_and_oversized_lines() {
        let mut exact =
            std::io::Cursor::new(format!("{}\n", "x".repeat(MAX_PIPE_IO_REQUEST_LINE_BYTES - 1)));
        let mut line = String::new();
        assert!(read_request_line(&mut exact, &mut line).unwrap());

        let mut oversized = std::io::Cursor::new("x".repeat(MAX_PIPE_IO_REQUEST_LINE_BYTES + 1));
        assert_eq!(
            read_request_line(&mut oversized, &mut line).unwrap_err().kind(),
            std::io::ErrorKind::InvalidData
        );
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
        let queue = PipeIoQueue::new();
        queue.push(replay(b"FIRST")).unwrap();
        queue.push(PipeIoEvent::Output(b"live".to_vec())).unwrap();
        queue.push(replay(b"SECOND")).unwrap();
        queue.push(PipeIoEvent::SurfaceExited).unwrap();
        let mut stdout = Vec::new();
        let reason = pump_events_to_stdout(&queue, &mut stdout).unwrap();
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
            let queue = PipeIoQueue::new();
            queue.push(event).unwrap();
            let mut stdout = Vec::new();
            assert_eq!(pump_events_to_stdout(&queue, &mut stdout).unwrap(), expected);
            assert!(stdout.is_empty());
        }
        // A closed queue without any event means the session vanished wholesale.
        let queue = PipeIoQueue::new();
        queue.close();
        let mut stdout = Vec::new();
        assert_eq!(
            pump_events_to_stdout(&queue, &mut stdout).unwrap(),
            PipeIoExitReason::DaemonLost
        );
    }

    #[test]
    fn event_queue_bounds_bytes_and_prioritizes_transport_loss() {
        let queue = PipeIoQueue::new();
        assert!(queue.push(PipeIoEvent::Output(vec![0; 8 * 1024 * 1024])).is_ok());
        assert_eq!(
            queue.push(PipeIoEvent::Output(vec![1])).unwrap_err(),
            PipeIoQueuePushError::Full
        );
        queue.push(PipeIoEvent::TransportLost).unwrap();
        assert_eq!(queue.recv(), Some(PipeIoEvent::TransportLost));
    }

    #[test]
    fn direct_transport_loss_signal_wakes_a_full_queue() {
        let queue = PipeIoQueue::new();
        assert!(queue.push(PipeIoEvent::Output(vec![0; 8 * 1024 * 1024])).is_ok());
        queue.signal_transport_lost();
        queue.close();
        assert_eq!(queue.recv(), Some(PipeIoEvent::TransportLost));
        assert!(queue.recv().is_none());
    }
}
