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
//!   reattaches and resyncs from a fresh replay), and 1 when the embedder
//!   violated this protocol or the relay cannot establish its contract.

use std::io::{self, BufRead, BufReader, Write};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_tui_core::SurfaceId;
use cmux_tui_core::resource::TerminalPublicId;
use crossbeam_channel::{Receiver, Sender};

use crate::session::{
    PipeIoByteBudget, PipeIoEvent, PipeIoSurfaceAttach, RemoteSession,
    is_remote_surface_unavailable,
};

/// The terminal ended, or the embedder walked away: respawning is wrong.
pub const EXIT_DO_NOT_RESPAWN: i32 = 0;
/// The daemon connection was lost: the embedder may respawn to resync.
pub const EXIT_DAEMON_LOST: i32 = 2;
/// The request stream violated the pipe-IO contract. Retrying the same input
/// cannot repair it, so the embedder must stop rather than respawn forever.
pub const EXIT_PROTOCOL_ERROR: i32 = 1;

/// Bounded event queue between the session reader thread and the stdout
/// pump. A full queue means the embedder stopped reading; the session
/// treats that as a lost transport rather than wedging its reader thread.
const EVENT_QUEUE_CAPACITY: usize = 4096;
const EVENT_QUEUE_MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_PIPE_IO_INPUT_BYTES: usize = 1024 * 1024;
const MAX_PIPE_IO_REQUEST_LINE_BYTES: usize = 2 * 1024 * 1024;
const MAX_PIPE_IO_DIMENSION: u64 = 10_000;

/// Emitted before any replay that is not the relay's first output: full
/// reset plus erase-scrollback, so the replacement replay does not stack on
/// top of the embedder's previous terminal state.
const REPLAY_RESET: &[u8] = b"\x1bc\x1b[3J";
const DAEMON_LOSS_PROBE_TIMEOUT: Duration = Duration::from_millis(500);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipeIoExitReason {
    TerminalEnded,
    DaemonLost,
    ParentClosed,
    ProtocolError,
}

impl PipeIoExitReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TerminalEnded => "terminal-ended",
            Self::DaemonLost => "daemon-lost",
            Self::ParentClosed => "parent-closed",
            Self::ProtocolError => "protocol-error",
        }
    }

    pub fn exit_code(self) -> i32 {
        match self {
            Self::TerminalEnded | Self::ParentClosed => EXIT_DO_NOT_RESPAWN,
            Self::DaemonLost => EXIT_DAEMON_LOST,
            Self::ProtocolError => EXIT_PROTOCOL_ERROR,
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
    /// Re-assert this relay's geometry authority. Claims are last-writer-wins
    /// across viewers and are sent when the embedder receives user input.
    ClaimGeometry,
    /// A well-formed line carrying no verb this relay knows: ignored, so a
    /// newer embedder can talk to an older relay.
    Unknown,
}

pub fn parse_request(line: &str) -> anyhow::Result<PipeIoRequest> {
    let value: serde_json::Value = serde_json::from_str(line)?;
    let object = value
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("a pipe-io request must be a JSON object"))?;
    let known_count = ["input", "resize", "claim"]
        .iter()
        .filter(|key| object.contains_key(**key))
        .count();
    if known_count > 1 {
        anyhow::bail!("a pipe-io request must contain one verb");
    }
    if let Some(encoded) = object.get("input") {
        let encoded = encoded
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("input must be a base64 string"))?;
        // Reject before decoding so a malformed peer cannot make the decoder
        // allocate an unbounded output buffer.
        let max_encoded = MAX_PIPE_IO_INPUT_BYTES
            .saturating_add(2)
            .saturating_mul(4)
            .saturating_div(3);
        if encoded.len() > max_encoded {
            anyhow::bail!("input exceeds the pipe-IO byte limit");
        }
        let bytes = base64::engine::general_purpose::STANDARD.decode(encoded)?;
        if bytes.len() > MAX_PIPE_IO_INPUT_BYTES {
            anyhow::bail!("input exceeds the pipe-IO byte limit");
        }
        return Ok(PipeIoRequest::Input(bytes));
    }
    if let Some(resize) = object.get("resize") {
        let resize = resize
            .as_object()
            .ok_or_else(|| anyhow::anyhow!("resize must be an object"))?;
        let cols = resize.get("cols").and_then(serde_json::Value::as_u64);
        let rows = resize.get("rows").and_then(serde_json::Value::as_u64);
        let (Some(cols), Some(rows)) = (cols, rows) else {
            anyhow::bail!("resize needs numeric cols and rows");
        };
        if cols > MAX_PIPE_IO_DIMENSION || rows > MAX_PIPE_IO_DIMENSION {
            anyhow::bail!("resize exceeds the pipe-IO dimension limit");
        }
        let (cols, rows) = (u16::try_from(cols)?, u16::try_from(rows)?);
        return Ok(PipeIoRequest::Resize { cols: cols.max(1), rows: rows.max(1) });
    }
    if let Some(claim) = object.get("claim") {
        if claim.get("geometry").and_then(serde_json::Value::as_bool) != Some(true) {
            anyhow::bail!("claim.geometry must be true");
        }
        return Ok(PipeIoRequest::ClaimGeometry);
    }
    Ok(PipeIoRequest::Unknown)
}

pub fn run(
    remote: &Arc<RemoteSession>,
    socket_path: &Path,
    terminal: &TerminalPublicId,
    surface: SurfaceId,
    cols: u16,
    rows: u16,
) -> anyhow::Result<PipeIoExitReason> {
    let (sender, receiver) = crossbeam_channel::bounded(EVENT_QUEUE_CAPACITY);
    // Lifecycle events have their own reserved signal path. A stalled
    // embedder can fill the byte queue, but it must never be able to hide the
    // transport-loss event that tells the embedder to respawn.
    let (lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
    let byte_budget = Arc::new(PipeIoByteBudget::new(EVENT_QUEUE_MAX_BYTES));
    // Install before attach so the initial replay cannot be missed.
    let tap_token = remote.install_pipe_io_tap(
        surface,
        sender.clone(),
        lifecycle_sender.clone(),
        byte_budget.clone(),
    );
    let tap_guard = PipeIoTapGuard { remote: remote.as_ref(), token: tap_token };
    let handle = match remote.try_attach_pipe_io(surface, Some((cols.max(1), rows.max(1)))) {
        Ok(PipeIoSurfaceAttach::Attached) => PipeIoSurfaceHandle {
            remote: remote.clone(),
            surface,
        },
        Ok(PipeIoSurfaceAttach::Retired) => {
            return Ok(PipeIoExitReason::TerminalEnded);
        }
        Ok(PipeIoSurfaceAttach::Deferred) => return Ok(PipeIoExitReason::DaemonLost),
        Err(error) => return Ok(attach_failure_exit_reason(&error, surface)),
    };
    // The attach request already reports the initial size atomically when the
    // server supports it. Reassert ownership asynchronously for older servers;
    // later user input sends another ordered claim before its bytes.
    if let Err(error) = handle.claim() {
        eprintln!(
            "{}",
            serde_json::json!({"diag": {"claim-terminal-geometry": {"error": error.to_string()}}})
        );
    }
    spawn_stdin_pump(handle, lifecycle_sender);
    let reason = pump_events_to_stdout(
        &receiver,
        &lifecycle_receiver,
        &byte_budget,
        &mut std::io::stdout().lock(),
    )?;
    // Stop forwarding while the daemon probe runs. The probe has its own
    // request path, and events for the finished relay must not fill the data
    // queue or tear down a replacement transport.
    drop(tap_guard);
    if reason == PipeIoExitReason::DaemonLost {
        return Ok(classify_daemon_loss(remote, socket_path, terminal));
    }
    Ok(reason)
}

/// A pipe relay only owns the remote request path. It never allocates a local
/// VT mirror, because the embedder is the single parser for these bytes.
#[derive(Clone)]
struct PipeIoSurfaceHandle {
    remote: Arc<RemoteSession>,
    surface: SurfaceId,
}

impl PipeIoSurfaceHandle {
    fn write_bytes(&self, bytes: &[u8]) -> anyhow::Result<()> {
        self.remote.send_bytes(self.surface, bytes)
    }

    fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.remote.resize_pipe_io(self.surface, cols, rows)
    }

    fn claim(&self) -> anyhow::Result<()> {
        self.remote.notify_claim_terminal_geometry(self.surface)
    }
}

struct PipeIoTapGuard<'a> {
    remote: &'a RemoteSession,
    token: Arc<u8>,
}

impl Drop for PipeIoTapGuard<'_> {
    fn drop(&mut self) {
        self.remote.clear_pipe_io_tap(&self.token);
    }
}

fn attach_failure_exit_reason(error: &anyhow::Error, surface: SurfaceId) -> PipeIoExitReason {
    // A rejected attach naming this exact surface means the terminal ended
    // between the tree lookup and the attach request. Every other failure is
    // reported as retryable daemon loss so the embedder receives the normal
    // final JSON record and exit code.
    if is_remote_surface_unavailable(error, surface) {
        PipeIoExitReason::TerminalEnded
    } else {
        PipeIoExitReason::DaemonLost
    }
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
    let deadline = Instant::now() + DAEMON_LOSS_PROBE_TIMEOUT;
    let terminal_still_exists = remote
        .refresh_tree_until(deadline)
        .ok()
        .map(|tree| tree.resolve_terminal(terminal).is_some())
        .or_else(|| {
            let probe =
                RemoteSession::connect_for_terminal_attach_until(socket_path, deadline).ok()?;
            let tree = probe.refresh_tree_until(deadline).ok()?;
            Some(tree.resolve_terminal(terminal).is_some())
        });
    match terminal_still_exists {
        Some(false) => PipeIoExitReason::TerminalEnded,
        Some(true) | None => PipeIoExitReason::DaemonLost,
    }
}

/// Forwards embedder requests from stdin until EOF, then reports the closed
/// parent through the shared event queue.
fn spawn_stdin_pump(handle: PipeIoSurfaceHandle, lifecycle_sender: Sender<PipeIoEvent>) {
    std::thread::Builder::new()
        .name("pipe-io-stdin".into())
        .spawn(move || {
            let stdin = io::stdin();
            let mut reader = BufReader::new(stdin.lock());
            let mut raw_line = Vec::new();
            let mut exit_event = PipeIoEvent::StdinClosed;
            loop {
                let has_line = match read_capped_line(&mut reader, &mut raw_line) {
                    Ok(has_line) => has_line,
                    Err(error) => {
                        report_diag("stdin", &error.to_string());
                        exit_event = PipeIoEvent::ProtocolError;
                        break;
                    }
                };
                if !has_line {
                    break;
                }
                let line = match std::str::from_utf8(&raw_line) {
                    Ok(line) => line,
                    Err(error) => {
                        report_diag("stdin", &error.to_string());
                        exit_event = PipeIoEvent::ProtocolError;
                        break;
                    }
                };
                if line.trim().is_empty() {
                    continue;
                }
                match parse_request(line) {
                    Ok(PipeIoRequest::Input(bytes)) => {
                        if let Err(error) = handle.write_bytes(&bytes) {
                            // The remote writer emits the authoritative
                            // transport lifecycle event. Do not replace it
                            // with a local clean-close signal.
                            report_diag("input", &error.to_string());
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
                            Err(error) => report_diag("resize", &error.to_string()),
                        }
                    }
                    Ok(PipeIoRequest::ClaimGeometry) => {
                        match handle.claim() {
                            Ok(()) => eprintln!(
                                "{}",
                                serde_json::json!({"diag": {"claim": {"accepted": true}}})
                            ),
                            Err(error) => report_diag("claim-terminal-geometry", &error.to_string()),
                        }
                    }
                    Ok(PipeIoRequest::Unknown) => {}
                    // A malformed line means the embedder side is broken;
                    // stop consuming rather than misinterpreting input.
                    Err(error) => {
                        report_diag("stdin", &error.to_string());
                        exit_event = PipeIoEvent::ProtocolError;
                        break;
                    }
                }
            }
            // Lifecycle has a reserved one-slot channel, so parent close
            // cannot be hidden behind queued output.
            let _ = lifecycle_sender.send(exit_event);
        })
        .expect("spawn pipe-io stdin pump");
}

/// Read one newline-delimited request without allowing a peer to grow the
/// line buffer without bound. `BufRead::read_line` has no allocation limit;
/// consuming from `fill_buf` lets us enforce the limit before appending.
fn read_capped_line<R: BufRead>(reader: &mut R, line: &mut Vec<u8>) -> io::Result<bool> {
    line.clear();
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return Ok(!line.is_empty());
        }
        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            if line.len().saturating_add(newline) > MAX_PIPE_IO_REQUEST_LINE_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "pipe-IO request line exceeds the byte limit",
                ));
            }
            line.extend_from_slice(&available[..newline]);
            reader.consume(newline + 1);
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            return Ok(true);
        }
        if line.len().saturating_add(available.len()) > MAX_PIPE_IO_REQUEST_LINE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "pipe-IO request line exceeds the byte limit",
            ));
        }
        let length = available.len();
        line.extend_from_slice(available);
        reader.consume(length);
    }
}

fn pump_events_to_stdout(
    receiver: &Receiver<PipeIoEvent>,
    lifecycle_receiver: &Receiver<PipeIoEvent>,
    byte_budget: &PipeIoByteBudget,
    stdout: &mut impl Write,
) -> anyhow::Result<PipeIoExitReason> {
    let mut emitted_output = false;
    loop {
        // Lifecycle signals have a separate bounded channel, so a full byte
        // queue cannot delay or drop a transport-loss notification.
        let event = crossbeam_channel::select_biased! {
            recv(lifecycle_receiver) -> event => {
                match event {
                    Ok(PipeIoEvent::SurfaceExited) => {
                        // A lifecycle event can overtake bytes already
                        // committed to the bounded queue. Preserve those
                        // bytes for the terminal's final frame. Transport
                        // loss has different semantics, so stale bytes are
                        // discarded there.
                        while let Ok(event) = receiver.try_recv() {
                            byte_budget.release(event.retained_bytes());
                            match event {
                                PipeIoEvent::Replay { .. } | PipeIoEvent::Output(_) => {
                                    if write_pipe_io_data(&event, &mut emitted_output, stdout).is_err() {
                                        return Ok(PipeIoExitReason::ParentClosed);
                                    }
                                }
                                PipeIoEvent::SurfaceExited => break,
                                PipeIoEvent::TransportLost => {
                                    return Ok(PipeIoExitReason::DaemonLost);
                                }
                                PipeIoEvent::ProtocolError => {
                                    return Ok(PipeIoExitReason::ProtocolError);
                                }
                                PipeIoEvent::StdinClosed => {
                                    return Ok(PipeIoExitReason::ParentClosed);
                                }
                            }
                        }
                        return Ok(PipeIoExitReason::TerminalEnded);
                    }
                    Ok(PipeIoEvent::TransportLost) => {
                        return Ok(PipeIoExitReason::DaemonLost);
                    }
                    Ok(PipeIoEvent::StdinClosed) => {
                        return Ok(PipeIoExitReason::ParentClosed);
                    }
                    Ok(PipeIoEvent::Replay { .. } | PipeIoEvent::Output(_)) => {
                        // Lifecycle senders never carry byte events. Ignore a
                        // malformed producer rather than violating framing.
                        continue;
                    }
                    Err(_) => return Ok(PipeIoExitReason::DaemonLost),
                }
            }
            recv(receiver) -> event => {
                match event {
                    Ok(event) => event,
                    Err(_) => return Ok(PipeIoExitReason::DaemonLost),
                }
            }
        };
        byte_budget.release(event.retained_bytes());
        let write_result = match &event {
            PipeIoEvent::Replay { .. } | PipeIoEvent::Output(_) => {
                write_pipe_io_data(&event, &mut emitted_output, stdout)
            }
            PipeIoEvent::SurfaceExited => return Ok(PipeIoExitReason::TerminalEnded),
            PipeIoEvent::TransportLost => return Ok(PipeIoExitReason::DaemonLost),
            PipeIoEvent::ProtocolError => return Ok(PipeIoExitReason::ProtocolError),
            PipeIoEvent::StdinClosed => return Ok(PipeIoExitReason::ParentClosed),
        };
        if write_result.is_err() {
            // stdout is the embedder; a failed write means it is gone.
            return Ok(PipeIoExitReason::ParentClosed);
        }
    }
}

fn write_pipe_io_data(
    event: &PipeIoEvent,
    emitted_output: &mut bool,
    stdout: &mut impl Write,
) -> io::Result<()> {
    match event {
        PipeIoEvent::Replay { bytes } => {
            if *emitted_output {
                stdout.write_all(REPLAY_RESET)?;
            }
            stdout.write_all(bytes)?;
            stdout.flush()?;
        }
        PipeIoEvent::Output(bytes) => {
            stdout.write_all(bytes)?;
            stdout.flush()?;
        }
        PipeIoEvent::SurfaceExited
        | PipeIoEvent::TransportLost
        | PipeIoEvent::ProtocolError
        | PipeIoEvent::StdinClosed => {
            debug_assert!(false, "lifecycle event passed to byte writer");
        }
    }
    *emitted_output = true;
    Ok(())
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
        assert_eq!(
            parse_request(r#"{"claim":{"geometry":true}}"#).unwrap(),
            PipeIoRequest::ClaimGeometry
        );
        assert_eq!(parse_request(r#"{"future-verb":true}"#).unwrap(), PipeIoRequest::Unknown);
        assert!(parse_request("not json").is_err());
        assert!(parse_request(r#"{"input":"@@not-base64@@"}"#).is_err());
        assert!(parse_request(r#"{"resize":{"cols":100}}"#).is_err());
        assert!(parse_request(r#"{"claim":{"geometry":false}}"#).is_err());
        assert!(parse_request(r#"{"input":"aGk=","resize":{"cols":80,"rows":24}}"#).is_err());
        assert!(parse_request(r#"[]"#).is_err());
    }

    #[test]
    fn exit_reasons_map_to_the_respawn_contract() {
        assert_eq!(PipeIoExitReason::TerminalEnded.exit_code(), EXIT_DO_NOT_RESPAWN);
        assert_eq!(PipeIoExitReason::ParentClosed.exit_code(), EXIT_DO_NOT_RESPAWN);
        assert_eq!(PipeIoExitReason::DaemonLost.exit_code(), EXIT_DAEMON_LOST);
        assert_eq!(PipeIoExitReason::ProtocolError.exit_code(), EXIT_PROTOCOL_ERROR);
        assert_eq!(PipeIoExitReason::TerminalEnded.as_str(), "terminal-ended");
        assert_eq!(PipeIoExitReason::DaemonLost.as_str(), "daemon-lost");
        assert_eq!(PipeIoExitReason::ParentClosed.as_str(), "parent-closed");
        assert_eq!(PipeIoExitReason::ProtocolError.as_str(), "protocol-error");
    }

    #[test]
    fn stdout_pump_prefixes_only_non_initial_replays_with_a_full_reset() {
        let (sender, receiver) = crossbeam_channel::bounded(8);
        let (_lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
        sender.send(replay(b"FIRST")).unwrap();
        sender.send(PipeIoEvent::Output(b"live".to_vec())).unwrap();
        sender.send(replay(b"SECOND")).unwrap();
        sender.send(PipeIoEvent::SurfaceExited).unwrap();
        let mut stdout = Vec::new();
        let budget = PipeIoByteBudget::new(1024);
        let reason =
            pump_events_to_stdout(&receiver, &lifecycle_receiver, &budget, &mut stdout).unwrap();
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
            (PipeIoEvent::ProtocolError, PipeIoExitReason::ProtocolError),
            (PipeIoEvent::StdinClosed, PipeIoExitReason::ParentClosed),
        ] {
            let (sender, receiver) = crossbeam_channel::bounded(8);
            let (_lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
            sender.send(event).unwrap();
            let mut stdout = Vec::new();
            let budget = PipeIoByteBudget::new(1024);
            assert_eq!(
                pump_events_to_stdout(&receiver, &lifecycle_receiver, &budget, &mut stdout)
                    .unwrap(),
                expected
            );
            assert!(stdout.is_empty());
        }
        // Sender dropped without any event: the session vanished wholesale.
        let (sender, receiver) = crossbeam_channel::bounded::<PipeIoEvent>(8);
        let (_lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
        drop(sender);
        let mut stdout = Vec::new();
        let budget = PipeIoByteBudget::new(1024);
        assert_eq!(
            pump_events_to_stdout(&receiver, &lifecycle_receiver, &budget, &mut stdout).unwrap(),
            PipeIoExitReason::DaemonLost
        );
    }

    #[test]
    fn parse_request_rejects_malformed_known_verbs_and_ambiguous_lines() {
        assert!(parse_request(r#"{"input":null}"#).is_err());
        assert!(parse_request(r#"{"resize":null}"#).is_err());
        assert!(parse_request(r#"{"input":"aGk=","resize":{"cols":80,"rows":24}}"#).is_err());
    }

    #[test]
    fn stdout_pump_prioritizes_a_transport_loss_over_queued_bytes() {
        let (sender, receiver) = crossbeam_channel::bounded(1);
        let (lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
        sender.send(PipeIoEvent::Output(b"stale".to_vec())).unwrap();
        lifecycle_sender.send(PipeIoEvent::TransportLost).unwrap();

        let mut stdout = Vec::new();
        let budget = PipeIoByteBudget::new(1024);
        assert_eq!(
            pump_events_to_stdout(&receiver, &lifecycle_receiver, &budget, &mut stdout).unwrap(),
            PipeIoExitReason::DaemonLost
        );
        assert!(stdout.is_empty(), "stale bytes must not be emitted after transport loss");
    }

    #[test]
    fn attach_failures_preserve_terminal_and_daemon_exit_contracts() {
        let terminal_ended =
            crate::session::test_remote_rejected_error_with_message("unknown surface 7");
        assert_eq!(attach_failure_exit_reason(&terminal_ended, 7), PipeIoExitReason::TerminalEnded);

        let daemon_lost = crate::session::test_remote_transport_error();
        assert_eq!(attach_failure_exit_reason(&daemon_lost, 7), PipeIoExitReason::DaemonLost);

        let unexpected = anyhow::anyhow!("attach capability negotiation failed");
        assert_eq!(attach_failure_exit_reason(&unexpected, 7), PipeIoExitReason::DaemonLost);
    }
}
