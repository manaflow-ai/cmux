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
//!   daemon-side viewer size; `{"claim":{"geometry":true}}` re-asserts this
//!   relay's geometry authority (last claim wins across attachments; the
//!   embedder sends it when its pane receives user input). Unknown keys are
//!   ignored (forward compat); stdin EOF means the embedder is gone and
//!   ends the relay cleanly.
//! - stderr: one final JSON line `{"exit":{"reason":...}}`.
//! - exit code: 0 when the terminal ended, the embedder closed stdin, or
//!   setup failed (do not respawn); 2 when the daemon connection was lost
//!   (respawning reattaches and resyncs from a fresh replay).

use std::borrow::Cow;
use std::io::{self, BufRead, Write};
use std::path::Path;
#[cfg(test)]
use std::sync::mpsc::sync_channel;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::os::fd::{AsFd, AsRawFd, RawFd};
#[cfg(unix)]
use std::os::unix::net::UnixStream;

use base64::Engine as _;
use cmux_tui_core::SurfaceId;
use cmux_tui_core::resource::TerminalPublicId;
use crossbeam_channel::{Receiver, Sender};
use serde::Deserialize;

use crate::session::{PipeIoByteBudget, PipeIoEvent, PipeIoSurfaceAttach, RemoteSession};

/// The terminal ended, or the embedder walked away: respawning is wrong.
pub const EXIT_DO_NOT_RESPAWN: i32 = 0;
/// The daemon connection was lost: the embedder may respawn to resync.
pub const EXIT_DAEMON_LOST: i32 = 2;

/// Bounded event queue between the session reader thread and the stdout
/// pump. A full queue means the embedder stopped reading; the session
/// treats that as a lost transport rather than wedging its reader thread.
const EVENT_QUEUE_CAPACITY: usize = 4096;
const EVENT_QUEUE_MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_PIPE_IO_INPUT_BYTES: usize = crate::pty_input::PTY_INPUT_MAX_BYTES;
const MAX_PIPE_IO_BASE64_BYTES: usize = MAX_PIPE_IO_INPUT_BYTES.div_ceil(3) * 4;
const MAX_PIPE_IO_LINE_BYTES: usize = MAX_PIPE_IO_BASE64_BYTES + 128;

/// Emitted before any replay that is not the relay's first output: full
/// reset plus erase-scrollback, so the replacement replay does not stack on
/// top of the embedder's previous terminal state.
const REPLAY_RESET: &[u8] = b"\x1bc\x1b[3J";
const DAEMON_LOSS_PROBE_TIMEOUT: Duration = Duration::from_millis(500);
const STDERR_WRITE_TIMEOUT: Duration = Duration::from_millis(100);
const PIPE_IO_FINAL_DRAIN_TIMEOUT: Duration = Duration::from_millis(500);
const CLAIM_GEOMETRY_ERROR_CODE: &str = "claim-terminal-geometry-failed";
const STDIN_PUMP_ERROR_CODE: &str = "stdin-pump-failed";
const RESIZE_ERROR_CODE: &str = "resize-failed";
const CLAIM_ERROR_CODE: &str = "claim-failed";

fn log_pipe_io_error(operation: &str, error: &anyhow::Error) {
    crate::client_log::error("pipe-io", &format!("{operation}: {error}"));
}

/// Serializes stdin diagnostics with the final machine-readable exit record.
/// The stdin pump may remain blocked in a read when the relay ends, so closing
/// the gate stops later diagnostics without detaching an in-flight write.
#[derive(Default)]
struct StderrGate {
    state: Mutex<StderrGateState>,
    idle: Condvar,
}

#[derive(Default)]
struct StderrGateState {
    closed: bool,
    in_flight: usize,
}

struct StderrFlight<'a> {
    gate: &'a StderrGate,
}

impl Drop for StderrFlight<'_> {
    fn drop(&mut self) {
        let mut state = self.gate.state.lock().unwrap_or_else(|poison| poison.into_inner());
        state.in_flight = state.in_flight.saturating_sub(1);
        if state.in_flight == 0 {
            self.gate.idle.notify_all();
        }
    }
}

impl StderrGate {
    fn close(&self) {
        let mut state = self.state.lock().unwrap_or_else(|poison| poison.into_inner());
        state.closed = true;
        while state.in_flight != 0 {
            state = self.idle.wait(state).unwrap_or_else(|poison| poison.into_inner());
        }
    }

    fn emit_with(&self, line: String, writer: impl FnOnce(&str)) {
        let mut state = self.state.lock().unwrap_or_else(|poison| poison.into_inner());
        if state.closed {
            return;
        }
        state.in_flight += 1;
        drop(state);
        let _flight = StderrFlight { gate: self };
        writer(&line);
    }

    fn diag(&self, line: String) {
        self.emit_with(line, write_stderr_line_bounded);
    }
}

/// Writes one stderr line without allowing a stopped embedder to strand the
/// relay. Unix uses a temporary nonblocking descriptor and a short deadline;
/// other platforms retain the standard stream writer as their fallback.
#[cfg(unix)]
pub(crate) fn write_stderr_line_bounded(line: &str) {
    let stderr = io::stderr();
    let Ok(fd) = stderr.as_fd().try_clone_to_owned() else { return };
    let _ = write_fd_line_bounded(fd.as_raw_fd(), line);
}

#[cfg(not(unix))]
pub(crate) fn write_stderr_line_bounded(line: &str) {
    let mut stderr = io::stderr().lock();
    let _ = writeln!(stderr, "{line}");
    let _ = stderr.flush();
}

#[cfg(unix)]
fn write_fd_line_bounded(fd: RawFd, line: &str) -> bool {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return false;
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return false;
    }

    let mut bytes = Vec::with_capacity(line.len() + 1);
    bytes.extend_from_slice(line.as_bytes());
    bytes.push(b'\n');
    let deadline = Instant::now() + STDERR_WRITE_TIMEOUT;
    let mut offset = 0;
    let complete = loop {
        if offset == bytes.len() {
            break true;
        }
        let written =
            unsafe { libc::write(fd, bytes[offset..].as_ptr().cast(), bytes.len() - offset) };
        if written > 0 {
            offset += written as usize;
            continue;
        }
        if written == 0 {
            break false;
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        if !matches!(
            error.raw_os_error(),
            Some(code) if code == libc::EAGAIN || code == libc::EWOULDBLOCK
        ) {
            break false;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break false;
        }
        let timeout_ms = remaining.as_millis().clamp(1, i32::MAX as u128) as i32;
        let mut poll_fd = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
        let ready = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
        if ready > 0 {
            continue;
        }
        if ready < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        break false;
    };
    // The duplicate shares the stream's open-file description, so restore the
    // caller's flags before dropping it. The bounded write itself is complete
    // or explicitly abandoned at the deadline.
    let _ = unsafe { libc::fcntl(fd, libc::F_SETFL, flags) };
    complete
}

/// Cancellation shared by the lifecycle monitor and the stdout writer.
///
/// Unix uses a wake-up stream in addition to the reason state. This lets a
/// blocked nonblocking write wait for either writable stdout or a lifecycle
/// event, with no polling timeout and no detached writer thread.
#[derive(Clone)]
struct PipeIoOutputCancellation {
    state: Arc<Mutex<PipeIoCancellationState>>,
    #[cfg(unix)]
    wake_reader: Arc<UnixStream>,
    #[cfg(unix)]
    wake_writer: Arc<Mutex<UnixStream>>,
}

#[derive(Clone, Copy, Default)]
struct PipeIoCancellationState {
    reason: Option<PipeIoExitReason>,
    drain_deadline: Option<Instant>,
}

impl PipeIoOutputCancellation {
    fn new() -> io::Result<Self> {
        #[cfg(unix)]
        {
            let (wake_reader, wake_writer) = UnixStream::pair()?;
            // The monitor must never block while publishing a lifecycle
            // reason. One byte is enough to wake the writer, and a full
            // socket already means a wake is pending.
            wake_reader.set_nonblocking(true)?;
            wake_writer.set_nonblocking(true)?;
            Ok(Self {
                state: Arc::new(Mutex::new(PipeIoCancellationState::default())),
                wake_reader: Arc::new(wake_reader),
                wake_writer: Arc::new(Mutex::new(wake_writer)),
            })
        }

        #[cfg(not(unix))]
        Ok(Self { state: Arc::new(Mutex::new(PipeIoCancellationState::default())) })
    }

    fn request(&self, reason: PipeIoExitReason) {
        let first_reason = {
            let mut state = self.state.lock().unwrap_or_else(|poison| poison.into_inner());
            if state.reason.is_none() {
                state.reason = Some(reason);
                if reason == PipeIoExitReason::TerminalEnded {
                    state.drain_deadline = Some(Instant::now() + PIPE_IO_FINAL_DRAIN_TIMEOUT);
                }
                true
            } else {
                false
            }
        };
        if !first_reason {
            return;
        }

        #[cfg(unix)]
        if let Ok(mut wake_writer) = self.wake_writer.lock() {
            let _ = wake_writer.write(&[1]);
        }
    }

    fn reason(&self) -> Option<PipeIoExitReason> {
        self.state.lock().unwrap_or_else(|poison| poison.into_inner()).reason
    }

    fn cancellation_state(&self) -> PipeIoCancellationState {
        *self.state.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    fn writes_cancelled(&self) -> bool {
        let state = self.cancellation_state();
        match state.reason {
            None => false,
            Some(PipeIoExitReason::TerminalEnded) => {
                state.drain_deadline.is_none_or(|deadline| Instant::now() >= deadline)
            }
            Some(_) => true,
        }
    }

    #[cfg(unix)]
    fn wake_fd(&self) -> RawFd {
        self.wake_reader.as_raw_fd()
    }
}

/// Output abstraction used by the event pump. The normal test writers use the
/// standard `Write` implementation, while the process stdout writer uses a
/// nonblocking descriptor that can observe lifecycle cancellation.
trait PipeIoOutput {
    fn write_bytes(&mut self, bytes: &[u8]) -> io::Result<()>;
    fn flush_output(&mut self) -> io::Result<()>;
    fn cancellation_reason(&self) -> Option<PipeIoExitReason> {
        None
    }
}

impl<W: Write> PipeIoOutput for W {
    fn write_bytes(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.write_all(bytes)
    }

    fn flush_output(&mut self) -> io::Result<()> {
        self.flush()
    }
}

#[cfg(unix)]
struct PipeIoStdout {
    file: File,
    cancellation: PipeIoOutputCancellation,
}

#[cfg(unix)]
fn pipe_io_stdout(cancellation: PipeIoOutputCancellation) -> io::Result<PipeIoStdout> {
    let stdout = io::stdout();
    let stdout_fd = stdout.as_fd().try_clone_to_owned()?;
    let file = File::from(stdout_fd);
    set_nonblocking(file.as_raw_fd())?;
    Ok(PipeIoStdout { file, cancellation })
}

#[cfg(unix)]
fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    // `fd` is borrowed from the live `File`; both fcntl calls only inspect or
    // update descriptor flags and do not take ownership of it.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if flags & libc::O_NONBLOCK != 0 {
        return Ok(());
    }
    let result = unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) };
    if result < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
}

#[cfg(unix)]
impl PipeIoStdout {
    fn wait_until_writable(&self) -> io::Result<()> {
        loop {
            let cancellation = self.cancellation.cancellation_state();
            let terminal_drain = cancellation.reason == Some(PipeIoExitReason::TerminalEnded)
                && cancellation.drain_deadline.is_some_and(|deadline| Instant::now() < deadline);
            if cancellation.reason.is_some() && !terminal_drain {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "pipe-io stdout canceled"));
            }
            let timeout_ms = if terminal_drain {
                let remaining = cancellation
                    .drain_deadline
                    .expect("terminal drain has a deadline")
                    .saturating_duration_since(Instant::now());
                remaining.as_millis().clamp(1, i32::MAX as u128) as i32
            } else {
                -1
            };
            let mut poll_fds = [
                libc::pollfd { fd: self.file.as_raw_fd(), events: libc::POLLOUT, revents: 0 },
                libc::pollfd {
                    fd: self.cancellation.wake_fd(),
                    // Once terminal-exit draining begins, ignore the already
                    // readable wake descriptor and wait for stdout or the
                    // explicit drain deadline. Otherwise poll would spin on
                    // the same cancellation byte.
                    events: if terminal_drain { 0 } else { libc::POLLIN },
                    revents: 0,
                },
            ];
            let ready =
                unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as _, timeout_ms) };
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "pipe-io stdout canceled"));
            }

            let output_events = poll_fds[0].revents;
            let cancel_events = poll_fds[1].revents;
            let cancellation_requested = cancel_events
                & (libc::POLLIN | libc::POLLHUP | libc::POLLERR | libc::POLLNVAL)
                != 0;
            let output_writable = output_events & libc::POLLOUT != 0;

            if output_events & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                if let Some(reason) = self.cancellation.reason() {
                    return Err(io::Error::new(
                        io::ErrorKind::Interrupted,
                        format!("pipe-io stdout canceled ({})", reason.as_str()),
                    ));
                }
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "pipe-io stdout closed"));
            }
            if output_writable {
                if self.cancellation.writes_cancelled() {
                    return Err(io::Error::new(
                        io::ErrorKind::Interrupted,
                        "pipe-io stdout canceled",
                    ));
                }
                return Ok(());
            }
            if cancellation_requested && !terminal_drain {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "pipe-io stdout canceled"));
            }
        }
    }
}

#[cfg(unix)]
impl PipeIoOutput for PipeIoStdout {
    fn write_bytes(&mut self, mut bytes: &[u8]) -> io::Result<()> {
        while !bytes.is_empty() {
            if self.cancellation.writes_cancelled() {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "pipe-io stdout canceled"));
            }
            // The descriptor is nonblocking, so a full pipe returns EAGAIN
            // and the poll below can also watch the cancellation wakeup.
            let written =
                unsafe { libc::write(self.file.as_raw_fd(), bytes.as_ptr().cast(), bytes.len()) };
            if written > 0 {
                bytes = &bytes[written as usize..];
                continue;
            }
            if written == 0 {
                return Err(io::Error::new(io::ErrorKind::WriteZero, "pipe-io stdout write zero"));
            }
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            if matches!(
                error.raw_os_error(),
                Some(code) if code == libc::EAGAIN || code == libc::EWOULDBLOCK
            ) {
                self.wait_until_writable()?;
                continue;
            }
            return Err(error);
        }
        Ok(())
    }

    fn flush_output(&mut self) -> io::Result<()> {
        // Each event is written directly to the descriptor. There is no
        // userspace buffer whose flush could block independently.
        Ok(())
    }

    fn cancellation_reason(&self) -> Option<PipeIoExitReason> {
        self.cancellation.reason()
    }
}

#[cfg(not(unix))]
struct PipeIoStdout {
    inner: std::io::BufWriter<std::io::Stdout>,
    cancellation: PipeIoOutputCancellation,
}

#[cfg(not(unix))]
fn pipe_io_stdout(cancellation: PipeIoOutputCancellation) -> io::Result<PipeIoStdout> {
    Ok(PipeIoStdout { inner: std::io::BufWriter::new(std::io::stdout()), cancellation })
}

#[cfg(not(unix))]
impl PipeIoOutput for PipeIoStdout {
    fn write_bytes(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.inner.write_all(bytes)
    }

    fn flush_output(&mut self) -> io::Result<()> {
        self.inner.flush()
    }

    fn cancellation_reason(&self) -> Option<PipeIoExitReason> {
        self.cancellation.reason()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PipeIoExitReason {
    TerminalEnded,
    DaemonLost,
    ParentClosed,
    SetupFailed,
}

impl PipeIoExitReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TerminalEnded => "terminal-ended",
            Self::DaemonLost => "daemon-lost",
            Self::ParentClosed => "parent-closed",
            Self::SetupFailed => "setup-failed",
        }
    }

    pub fn exit_code(self) -> i32 {
        match self {
            Self::TerminalEnded | Self::ParentClosed | Self::SetupFailed => EXIT_DO_NOT_RESPAWN,
            Self::DaemonLost => EXIT_DAEMON_LOST,
        }
    }
}

fn lifecycle_exit_reason(event: &PipeIoEvent) -> PipeIoExitReason {
    match event {
        PipeIoEvent::SurfaceExited => PipeIoExitReason::TerminalEnded,
        PipeIoEvent::TransportLost => PipeIoExitReason::DaemonLost,
        PipeIoEvent::StdinClosed => PipeIoExitReason::ParentClosed,
        PipeIoEvent::StdinError => PipeIoExitReason::SetupFailed,
        PipeIoEvent::Replay { .. } | PipeIoEvent::Output(_) => {
            // Lifecycle senders never carry byte events. Treat a malformed
            // event as a daemon loss, which is the only retryable safe
            // classification when framing is corrupted.
            PipeIoExitReason::DaemonLost
        }
    }
}

/// Relays lifecycle events to the byte pump and wakes a blocked stdout write.
/// The source channel is separate from the bounded byte queue, so this thread
/// remains able to publish daemon loss while the embedder has stopped reading.
struct PipeIoLifecycleMonitor {
    stop: Sender<()>,
    join: std::thread::JoinHandle<()>,
}

impl PipeIoLifecycleMonitor {
    fn spawn(
        lifecycle_receiver: Receiver<PipeIoEvent>,
        pump_sender: Sender<PipeIoEvent>,
        cancellation: PipeIoOutputCancellation,
    ) -> io::Result<Self> {
        let (stop, stop_receiver) = crossbeam_channel::bounded(1);
        let join = std::thread::Builder::new()
            .name("pipe-io-lifecycle".into())
            .spawn(move || {
                crossbeam_channel::select_biased! {
                    recv(stop_receiver) -> _ => {}
                    recv(lifecycle_receiver) -> event => {
                        let event = event.unwrap_or(PipeIoEvent::TransportLost);
                        cancellation.request(lifecycle_exit_reason(&event));
                        let _ = pump_sender.try_send(event);
                    }
                }
            })
            .map_err(|error| {
                io::Error::other(format!("spawn pipe-io lifecycle monitor: {error}"))
            })?;
        Ok(Self { stop, join })
    }

    fn stop(self) {
        let _ = self.stop.send(());
        let _ = self.join.join();
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
    /// Re-assert this relay's geometry authority over the terminal. Sent by
    /// the embedder when its pane receives user input: authority is
    /// last-claim-wins across attachments, so with several panes (or stale
    /// restored panes) viewing one terminal, the pane the user actually
    /// types in must own the PTY size.
    ClaimGeometry,
    /// A well-formed line carrying no verb this relay knows: ignored, so a
    /// newer embedder can talk to an older relay.
    Unknown,
}

#[derive(Deserialize)]
struct PipeIoWireRequest<'a> {
    #[serde(borrow)]
    input: Option<Cow<'a, str>>,
    resize: Option<PipeIoWireResize>,
    #[serde(default)]
    claim: PipeIoClaimField,
}

#[derive(Deserialize)]
struct PipeIoWireResize {
    cols: Option<u64>,
    rows: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PipeIoWireClaim {
    geometry: bool,
}

#[derive(Default)]
enum PipeIoClaimField {
    #[default]
    Absent,
    Enabled,
}

impl<'de> Deserialize<'de> for PipeIoClaimField {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let claim = PipeIoWireClaim::deserialize(deserializer)?;
        if claim.geometry {
            Ok(Self::Enabled)
        } else {
            Err(serde::de::Error::custom("claim geometry must be true"))
        }
    }
}

pub fn parse_request(line: &str) -> anyhow::Result<PipeIoRequest> {
    if line.len() > MAX_PIPE_IO_LINE_BYTES {
        anyhow::bail!("pipe-io request line exceeds {MAX_PIPE_IO_LINE_BYTES} bytes");
    }
    let request: PipeIoWireRequest<'_> = serde_json::from_str(line)?;
    if let Some(encoded) = request.input {
        let encoded = encoded.as_ref();
        if encoded.len() > MAX_PIPE_IO_BASE64_BYTES {
            anyhow::bail!("pipe-io input exceeds {MAX_PIPE_IO_INPUT_BYTES} decoded bytes");
        }
        if encoded.len() % 4 == 0 {
            let padding = encoded.bytes().rev().take_while(|byte| *byte == b'=').count();
            let decoded_len = encoded
                .len()
                .checked_div(4)
                .and_then(|quads| quads.checked_mul(3))
                .and_then(|bytes| bytes.checked_sub(padding))
                .unwrap_or(usize::MAX);
            if decoded_len > MAX_PIPE_IO_INPUT_BYTES {
                anyhow::bail!("pipe-io input exceeds {MAX_PIPE_IO_INPUT_BYTES} decoded bytes");
            }
        } else if base64::decoded_len_estimate(encoded.len()) > MAX_PIPE_IO_INPUT_BYTES {
            anyhow::bail!("pipe-io input exceeds {MAX_PIPE_IO_INPUT_BYTES} decoded bytes");
        }
        let bytes = base64::engine::general_purpose::STANDARD.decode(encoded)?;
        if bytes.len() > MAX_PIPE_IO_INPUT_BYTES {
            anyhow::bail!("pipe-io input exceeds {MAX_PIPE_IO_INPUT_BYTES} decoded bytes");
        }
        return Ok(PipeIoRequest::Input(bytes));
    }
    if let Some(resize) = request.resize {
        let cols = resize.cols;
        let rows = resize.rows;
        let (Some(cols), Some(rows)) = (cols, rows) else {
            anyhow::bail!("resize needs numeric cols and rows");
        };
        let (cols, rows) = (u16::try_from(cols)?, u16::try_from(rows)?);
        return Ok(PipeIoRequest::Resize { cols: cols.max(1), rows: rows.max(1) });
    }
    if matches!(request.claim, PipeIoClaimField::Enabled) {
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
    let tap_token =
        remote.install_pipe_io_tap(surface, sender, lifecycle_sender.clone(), byte_budget.clone());
    let tap_guard = PipeIoTapGuard { remote: remote.as_ref(), token: tap_token };
    let handle = match remote.try_attach_pipe_io(surface, Some((cols.max(1), rows.max(1)))) {
        Ok(PipeIoSurfaceAttach::Attached) => {
            PipeIoSurfaceHandle { remote: remote.clone(), surface }
        }
        Ok(PipeIoSurfaceAttach::Retired) => {
            return Ok(PipeIoExitReason::TerminalEnded);
        }
        Ok(PipeIoSurfaceAttach::Deferred) => return Ok(PipeIoExitReason::DaemonLost),
        Err(error) => return Ok(attach_failure_exit_reason(&error)),
    };
    // The daemon resizes a terminal's PTY only for its geometry-authority
    // client (the full TUI client claims this for its active surface). The
    // relay is the embedder's only viewer of this terminal, so claim the
    // authority or every embedder resize is recorded but never applied.
    if let Err(error) = remote.claim_terminal_geometry(surface) {
        log_pipe_io_error("claim terminal geometry", &error);
        write_stderr_line_bounded(
            &serde_json::json!({
                "diag": {"claim-terminal-geometry": {"error": CLAIM_GEOMETRY_ERROR_CODE}}
            })
            .to_string(),
        );
        // Continuing without geometry authority would make later resize
        // requests look accepted while the daemon keeps the wrong PTY size.
        // Classify the startup failure so the embedder can either stop for a
        // retired terminal or reconnect after a lost daemon transport.
        return Ok(classify_claim_failure(remote, surface, &error));
    }
    // Older daemons receive a best-effort pre-attach size in
    // `try_attach_pipe_io`. Re-apply it after claiming authority because a
    // newer terminal-authority daemon may report the pre-attach sample as
    // passive. An unchanged size does not produce a second replay.
    if !remote.supports_pipe_io_initial_size()
        && let Err(error) = remote.resize_pipe_io(surface, cols.max(1), rows.max(1))
    {
        return Ok(attach_failure_exit_reason(&error));
    }
    let stderr_gate = Arc::new(StderrGate::default());
    let cancellation = match PipeIoOutputCancellation::new() {
        Ok(cancellation) => cancellation,
        Err(error) => {
            stderr_gate.close();
            drop(tap_guard);
            return Err(error.into());
        }
    };
    // On Unix, duplicate stdout and make the descriptor nonblocking. Each
    // write then waits on stdout readiness and the lifecycle wakeup together,
    // so a stopped reader cannot strand this relay in write_all or flush.
    let mut stdout = match pipe_io_stdout(cancellation.clone()) {
        Ok(stdout) => stdout,
        Err(error) => {
            stderr_gate.close();
            drop(tap_guard);
            return Err(error.into());
        }
    };
    let (pump_lifecycle_sender, pump_lifecycle_receiver) = crossbeam_channel::bounded(1);
    let lifecycle_monitor = match PipeIoLifecycleMonitor::spawn(
        lifecycle_receiver,
        pump_lifecycle_sender,
        cancellation,
    ) {
        Ok(monitor) => monitor,
        Err(error) => {
            stderr_gate.close();
            drop(tap_guard);
            return Err(error.into());
        }
    };
    let _stdin_pump = match spawn_stdin_pump(handle, lifecycle_sender, stderr_gate.clone()) {
        Ok(pump) => pump,
        Err(error) => {
            let error = anyhow::Error::new(error);
            log_pipe_io_error("spawn stdin pump", &error);
            write_stderr_line_bounded(
                &serde_json::json!({"diag": {"stdin-pump": {"error": STDIN_PUMP_ERROR_CODE}}})
                    .to_string(),
            );
            lifecycle_monitor.stop();
            drop(tap_guard);
            stderr_gate.close();
            return Ok(PipeIoExitReason::SetupFailed);
        }
    };
    let pump_result =
        pump_events_to_stdout(&receiver, &pump_lifecycle_receiver, &byte_budget, &mut stdout);
    lifecycle_monitor.stop();
    // The stdin pump can still be blocked in read(2). Close the gate before
    // returning so no late resize/claim diagnostic can follow the exit record.
    stderr_gate.close();
    let reason = pump_result?;
    // Stop forwarding while the daemon probe runs. The probe has its own
    // request path, and events for the finished relay must not fill the data
    // queue or tear down a replacement transport.
    drop(tap_guard);
    if reason == PipeIoExitReason::DaemonLost {
        return Ok(classify_daemon_loss(remote, socket_path, terminal));
    }
    Ok(reason)
}

/// The pipe-IO relay needs only the remote request path. Keeping this handle
/// separate from `SurfaceHandle::Remote` prevents the normal local VT mirror
/// from being created or mutated for a renderer-less attachment.
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

fn attach_failure_exit_reason(error: &anyhow::Error) -> PipeIoExitReason {
    // Unknown rejection text is not a reliable lifecycle signal. Fail closed
    // unless the transport itself is explicitly retryable; setup errors must
    // not respawn forever on a stale or unauthorized surface.
    if crate::session::is_pipe_io_retryable_error(error) {
        PipeIoExitReason::DaemonLost
    } else {
        PipeIoExitReason::SetupFailed
    }
}

/// A claim can be rejected after the terminal-exit event retires its surface.
/// Preserve the terminal-ended contract for that known race; unrelated claim
/// failures retain their setup or daemon-loss classification.
pub(crate) fn classify_claim_failure(
    remote: &RemoteSession,
    surface: SurfaceId,
    error: &anyhow::Error,
) -> PipeIoExitReason {
    if remote.surface_is_retired(surface) {
        PipeIoExitReason::TerminalEnded
    } else {
        attach_failure_exit_reason(error)
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

fn read_pipe_io_line(reader: &mut impl BufRead, line: &mut String) -> io::Result<usize> {
    line.clear();
    let mut bytes = Vec::new();
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            if bytes.is_empty() {
                return Ok(0);
            }
            *line = String::from_utf8(bytes)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            return Ok(line.len());
        }
        let (chunk_len, has_newline) = match available.iter().position(|byte| *byte == b'\n') {
            Some(index) => (index + 1, true),
            None => (available.len(), false),
        };
        if bytes.len().saturating_add(chunk_len) > MAX_PIPE_IO_LINE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("pipe-io request line exceeds {MAX_PIPE_IO_LINE_BYTES} bytes"),
            ));
        }
        let chunk = &available[..chunk_len];
        bytes.extend_from_slice(chunk);
        reader.consume(chunk_len);
        if has_newline {
            *line = String::from_utf8(bytes)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            return Ok(line.len());
        }
    }
}

/// Forwards embedder requests from stdin until EOF, then reports the closed
/// parent through the shared event queue.
fn spawn_stdin_pump(
    handle: PipeIoSurfaceHandle,
    lifecycle_sender: Sender<PipeIoEvent>,
    stderr_gate: Arc<StderrGate>,
) -> io::Result<std::thread::JoinHandle<()>> {
    let remote = Arc::downgrade(&handle.remote);
    let surface = handle.surface;
    std::thread::Builder::new()
        .name("pipe-io-stdin".into())
        .spawn(move || {
            let stdin = io::stdin();
            let mut reader = stdin.lock();
            run_stdin_pump(&mut reader, &remote, surface, &lifecycle_sender, &stderr_gate);
        })
        .map_err(|error| io::Error::other(format!("spawn pipe-io stdin pump: {error}")))
}

enum PipeIoControlResult<T> {
    Completed(T),
    Gone,
    Failed(anyhow::Error),
}

fn run_stdin_pump(
    reader: &mut impl BufRead,
    remote: &Weak<RemoteSession>,
    surface: SurfaceId,
    lifecycle_sender: &Sender<PipeIoEvent>,
    stderr_gate: &StderrGate,
) {
    let input_remote = remote.clone();
    let resize_remote = remote.clone();
    let claim_remote = remote.clone();
    let mut emit_diag = |line: String| stderr_gate.diag(line);
    run_stdin_pump_with_handlers(
        reader,
        lifecycle_sender,
        move |bytes| {
            let Some(remote) = input_remote.upgrade() else {
                return PipeIoControlResult::Gone;
            };
            let handle = PipeIoSurfaceHandle { remote, surface };
            match handle.write_bytes(bytes) {
                Ok(()) => PipeIoControlResult::Completed(()),
                Err(error) => PipeIoControlResult::Failed(error),
            }
        },
        move |cols, rows| {
            let Some(remote) = resize_remote.upgrade() else {
                return PipeIoControlResult::Gone;
            };
            let handle = PipeIoSurfaceHandle { remote, surface };
            match handle.resize(cols, rows) {
                Ok(accepted) => PipeIoControlResult::Completed(accepted),
                Err(error) => PipeIoControlResult::Failed(error),
            }
        },
        move || {
            let Some(remote) = claim_remote.upgrade() else {
                return PipeIoControlResult::Gone;
            };
            match remote.claim_terminal_geometry(surface) {
                Ok(()) => PipeIoControlResult::Completed(()),
                Err(error) => PipeIoControlResult::Failed(error),
            }
        },
        &mut emit_diag,
    );
}

fn run_stdin_pump_with_handlers(
    reader: &mut impl BufRead,
    lifecycle_sender: &Sender<PipeIoEvent>,
    mut write_input: impl FnMut(&[u8]) -> PipeIoControlResult<()>,
    mut resize: impl FnMut(u16, u16) -> PipeIoControlResult<bool>,
    mut claim: impl FnMut() -> PipeIoControlResult<()>,
    mut emit_diag: impl FnMut(String),
) {
    let mut line = String::new();
    let mut stop_event = None;
    loop {
        let bytes_read = match read_pipe_io_line(reader, &mut line) {
            Ok(bytes_read) => bytes_read,
            Err(_) => {
                stop_event = Some(PipeIoEvent::StdinError);
                break;
            }
        };
        if bytes_read == 0 {
            break;
        }
        if line.trim().is_empty() {
            continue;
        }
        match parse_request(&line) {
            Ok(PipeIoRequest::Input(bytes)) => {
                if !matches!(write_input(&bytes), PipeIoControlResult::Completed(())) {
                    // The transport owns loss reporting; input can only stop
                    // early.
                    stop_event = Some(PipeIoEvent::TransportLost);
                    break;
                }
            }
            Ok(PipeIoRequest::Resize { cols, rows }) => {
                let result = resize(cols, rows);
                emit_diag(resize_diag_line(cols, rows, &result));
                if matches!(result, PipeIoControlResult::Gone) {
                    stop_event = Some(PipeIoEvent::TransportLost);
                    break;
                }
            }
            Ok(PipeIoRequest::ClaimGeometry) => {
                // Claims only establish ownership. Enqueue them on the same
                // ordered writer as input so a claim cannot overtake the
                // keystroke that follows it, and avoid a new blocking thread
                // for every claim.
                let result = claim();
                emit_diag(claim_diag_line(&result));
                if matches!(result, PipeIoControlResult::Gone) {
                    stop_event = Some(PipeIoEvent::TransportLost);
                    break;
                }
            }
            Ok(PipeIoRequest::Unknown) => {}
            // A malformed line means the embedder side is broken; stop
            // consuming rather than misinterpreting input.
            Err(_) => {
                stop_event = Some(PipeIoEvent::StdinError);
                break;
            }
        }
    }
    // Lifecycle has its own one-slot channel, so a full byte queue cannot
    // delay the parent-close or failure signal. Only actual stdin EOF maps to
    // StdinClosed; transport and protocol failures keep their own reason.
    let _ = lifecycle_sender.send(stop_event.unwrap_or(PipeIoEvent::StdinClosed));
}

fn resize_diag_line(cols: u16, rows: u16, result: &PipeIoControlResult<bool>) -> String {
    let details = match result {
        PipeIoControlResult::Completed(accepted) => {
            serde_json::json!({"cols": cols, "rows": rows, "accepted": accepted})
        }
        PipeIoControlResult::Gone => serde_json::json!({
            "cols": cols,
            "rows": rows,
            "error": RESIZE_ERROR_CODE
        }),
        PipeIoControlResult::Failed(error) => {
            log_pipe_io_error("resize", error);
            serde_json::json!({"cols": cols, "rows": rows, "error": RESIZE_ERROR_CODE})
        }
    };
    serde_json::json!({"diag": {"resize": details}}).to_string()
}

fn claim_diag_line(result: &PipeIoControlResult<()>) -> String {
    let details = match result {
        PipeIoControlResult::Completed(()) => serde_json::json!({"accepted": true}),
        PipeIoControlResult::Gone => serde_json::json!({"error": CLAIM_ERROR_CODE}),
        PipeIoControlResult::Failed(error) => {
            log_pipe_io_error("claim geometry", error);
            serde_json::json!({"error": CLAIM_ERROR_CODE})
        }
    };
    serde_json::json!({"diag": {"claim": details}}).to_string()
}

fn pump_events_to_stdout(
    receiver: &Receiver<PipeIoEvent>,
    lifecycle_receiver: &Receiver<PipeIoEvent>,
    byte_budget: &PipeIoByteBudget,
    stdout: &mut impl PipeIoOutput,
) -> anyhow::Result<PipeIoExitReason> {
    let mut emitted_output = false;
    loop {
        // Lifecycle signals have a separate bounded channel, so a full byte
        // queue cannot delay or drop a transport-loss notification.
        let event = crossbeam_channel::select_biased! {
            recv(lifecycle_receiver) -> event => {
                match event {
                    Ok(PipeIoEvent::SurfaceExited) => {
                        // Lifecycle signals use a separate channel, so a
                        // surface-exit notification can overtake bytes that
                        // the reader already queued. Drain those committed
                        // bytes before preserving the terminal's final frame.
                        // Transport loss has different semantics: queued
                        // bytes are stale and must be discarded.
                        while let Ok(event) = receiver.try_recv() {
                            byte_budget.release_event(&event);
                            match event {
                                PipeIoEvent::Replay { .. } | PipeIoEvent::Output(_) => {
                                    if write_pipe_io_data(
                                        &event,
                                        &mut emitted_output,
                                        stdout,
                                    )
                                    .is_err()
                                    {
                                        return Ok(
                                            stdout
                                                .cancellation_reason()
                                                .unwrap_or(PipeIoExitReason::ParentClosed),
                                        );
                                    }
                                }
                                PipeIoEvent::SurfaceExited => {
                                    break;
                                }
                                PipeIoEvent::TransportLost => {
                                    return Ok(PipeIoExitReason::DaemonLost);
                                }
                                PipeIoEvent::StdinClosed => {
                                    return Ok(PipeIoExitReason::ParentClosed);
                                }
                                PipeIoEvent::StdinError => {
                                    return Ok(PipeIoExitReason::SetupFailed);
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
                    Ok(PipeIoEvent::StdinError) => {
                        return Ok(PipeIoExitReason::SetupFailed);
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
        byte_budget.release_event(&event);
        let write_result = match &event {
            PipeIoEvent::Replay { .. } | PipeIoEvent::Output(_) => {
                write_pipe_io_data(&event, &mut emitted_output, stdout)
            }
            PipeIoEvent::SurfaceExited => return Ok(PipeIoExitReason::TerminalEnded),
            PipeIoEvent::TransportLost => return Ok(PipeIoExitReason::DaemonLost),
            PipeIoEvent::StdinClosed => return Ok(PipeIoExitReason::ParentClosed),
            PipeIoEvent::StdinError => return Ok(PipeIoExitReason::SetupFailed),
        };
        if write_result.is_err() {
            // stdout is the embedder; a failed write means it is gone.
            return Ok(stdout.cancellation_reason().unwrap_or(PipeIoExitReason::ParentClosed));
        }
    }
}

fn write_pipe_io_data(
    event: &PipeIoEvent,
    emitted_output: &mut bool,
    stdout: &mut impl PipeIoOutput,
) -> io::Result<()> {
    match event {
        PipeIoEvent::Replay { bytes, .. } => {
            if *emitted_output {
                stdout.write_bytes(REPLAY_RESET)?;
            }
            stdout.write_bytes(bytes)?;
            stdout.flush_output()?;
        }
        PipeIoEvent::Output(bytes) => {
            stdout.write_bytes(bytes)?;
            stdout.flush_output()?;
        }
        PipeIoEvent::SurfaceExited
        | PipeIoEvent::TransportLost
        | PipeIoEvent::StdinClosed
        | PipeIoEvent::StdinError => {
            debug_assert!(false, "lifecycle event passed to byte writer");
        }
    }
    *emitted_output = true;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;
    use std::sync::Weak;

    use super::*;

    fn replay(bytes: &[u8]) -> PipeIoEvent {
        PipeIoEvent::replay(bytes.to_vec())
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
    fn parse_request_requires_a_valid_geometry_claim() {
        assert_eq!(
            parse_request(r#"{"claim":{"geometry":true}}"#).unwrap(),
            PipeIoRequest::ClaimGeometry
        );
        for line in [
            r#"{"claim":true}"#,
            r#"{"claim":false}"#,
            r#"{"claim":null}"#,
            r#"{"claim":{"geometry":false}}"#,
            r#"{"claim":{"other":true}}"#,
            r#"{"claim":{"geometry":true,"other":true}}"#,
            r#"{"claim":"true"}"#,
        ] {
            assert!(parse_request(line).is_err(), "accepted invalid claim {line}");
        }
    }

    #[test]
    fn parse_request_rejects_oversized_lines_and_input_before_decoding() {
        let oversized_line = " ".repeat(MAX_PIPE_IO_LINE_BYTES + 1);
        let error = parse_request(&oversized_line).unwrap_err().to_string();
        assert!(error.contains("request line exceeds"), "{error}");

        let oversized_base64 = "A".repeat(MAX_PIPE_IO_BASE64_BYTES + 4);
        let line = format!(r#"{{"input":"{oversized_base64}"}}"#);
        let error = parse_request(&line).unwrap_err().to_string();
        assert!(error.contains("input exceeds"), "{error}");
    }

    #[test]
    fn exit_reasons_map_to_the_respawn_contract() {
        assert_eq!(PipeIoExitReason::TerminalEnded.exit_code(), EXIT_DO_NOT_RESPAWN);
        assert_eq!(PipeIoExitReason::ParentClosed.exit_code(), EXIT_DO_NOT_RESPAWN);
        assert_eq!(PipeIoExitReason::SetupFailed.exit_code(), EXIT_DO_NOT_RESPAWN);
        assert_eq!(PipeIoExitReason::DaemonLost.exit_code(), EXIT_DAEMON_LOST);
        assert_eq!(PipeIoExitReason::TerminalEnded.as_str(), "terminal-ended");
        assert_eq!(PipeIoExitReason::DaemonLost.as_str(), "daemon-lost");
        assert_eq!(PipeIoExitReason::ParentClosed.as_str(), "parent-closed");
        assert_eq!(PipeIoExitReason::SetupFailed.as_str(), "setup-failed");
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
            (PipeIoEvent::StdinClosed, PipeIoExitReason::ParentClosed),
            (PipeIoEvent::StdinError, PipeIoExitReason::SetupFailed),
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
    fn stdout_pump_drains_committed_bytes_before_surface_exit() {
        let (sender, receiver) = crossbeam_channel::bounded(8);
        let (lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
        let budget = PipeIoByteBudget::new(1024);
        assert!(budget.try_reserve(5));
        sender.send(replay(b"FINAL")).unwrap();
        lifecycle_sender.send(PipeIoEvent::SurfaceExited).unwrap();

        let mut stdout = Vec::new();
        let reason =
            pump_events_to_stdout(&receiver, &lifecycle_receiver, &budget, &mut stdout).unwrap();
        assert_eq!(reason, PipeIoExitReason::TerminalEnded);
        assert_eq!(stdout, b"FINAL");
    }

    #[cfg(unix)]
    #[test]
    fn stdout_writer_stops_when_lifecycle_arrives_with_reader_open() {
        use std::os::fd::{AsRawFd, FromRawFd, RawFd};

        let mut fds = [0 as RawFd; 2];
        // SAFETY: `fds` points to two writable integers owned by this test;
        // `pipe` initializes both descriptors on success.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        // Keep the read side open but never consume it. This models an
        // embedder that stopped reading while its process remains alive.
        let reader = unsafe { File::from_raw_fd(fds[0]) };
        let writer_file = unsafe { File::from_raw_fd(fds[1]) };
        set_nonblocking(writer_file.as_raw_fd()).unwrap();

        // Fill the kernel pipe so the first relay write must wait for
        // POLLOUT. No unbounded userspace buffer is involved.
        let fill = [0_u8; 4096];
        loop {
            // SAFETY: `writer_file` owns the descriptor and `fill` remains
            // alive and readable for the duration of each call.
            let written =
                unsafe { libc::write(writer_file.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
            if written >= 0 {
                continue;
            }
            let error = io::Error::last_os_error();
            assert!(
                error.raw_os_error() == Some(libc::EAGAIN)
                    || error.raw_os_error() == Some(libc::EWOULDBLOCK),
                "unexpected pipe fill error: {error}"
            );
            break;
        }

        let cancellation = PipeIoOutputCancellation::new().unwrap();
        let (lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
        let (pump_sender, pump_receiver) = crossbeam_channel::bounded(1);
        let monitor =
            PipeIoLifecycleMonitor::spawn(lifecycle_receiver, pump_sender, cancellation.clone())
                .unwrap();
        let mut stdout = PipeIoStdout { file: writer_file, cancellation: cancellation.clone() };
        let (finished_sender, finished_receiver) = std::sync::mpsc::channel();
        let writer = std::thread::spawn(move || {
            finished_sender.send(stdout.write_bytes(b"blocked")).unwrap();
        });

        lifecycle_sender.send(PipeIoEvent::TransportLost).unwrap();
        let result = match finished_receiver.recv_timeout(Duration::from_secs(1)) {
            Ok(result) => result,
            Err(_) => {
                // Ensure the writer can be joined if the assertion below
                // fails, while retaining the primary timeout signal.
                drop(reader);
                let _ = finished_receiver.recv_timeout(Duration::from_secs(1));
                let _ = writer.join();
                panic!("stdout writer did not observe lifecycle cancellation");
            }
        };
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Interrupted);
        assert_eq!(cancellation.reason(), Some(PipeIoExitReason::DaemonLost));
        assert_eq!(pump_receiver.recv().unwrap(), PipeIoEvent::TransportLost);
        writer.join().unwrap();
        monitor.stop();
        drop(reader);
    }

    #[cfg(unix)]
    #[test]
    fn stdout_writer_drains_committed_bytes_after_surface_exit() {
        use std::io::Read;
        use std::os::fd::{AsRawFd, FromRawFd, RawFd};

        let mut fds = [0 as RawFd; 2];
        // SAFETY: `fds` points to two writable integers owned by this test;
        // `pipe` initializes both descriptors on success.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let mut reader = unsafe { File::from_raw_fd(fds[0]) };
        let writer_file = unsafe { File::from_raw_fd(fds[1]) };
        set_nonblocking(writer_file.as_raw_fd()).unwrap();

        let fill = [0_u8; 4096];
        loop {
            // SAFETY: `writer_file` owns the descriptor and `fill` remains
            // alive and readable for the duration of each call.
            let written =
                unsafe { libc::write(writer_file.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
            if written >= 0 {
                continue;
            }
            let error = io::Error::last_os_error();
            assert!(
                error.raw_os_error() == Some(libc::EAGAIN)
                    || error.raw_os_error() == Some(libc::EWOULDBLOCK),
                "unexpected pipe fill error: {error}"
            );
            break;
        }

        let cancellation = PipeIoOutputCancellation::new().unwrap();
        cancellation.request(PipeIoExitReason::TerminalEnded);
        let mut stdout = PipeIoStdout { file: writer_file, cancellation };
        let (started_sender, started_receiver) = sync_channel(0);
        let (finished_sender, finished_receiver) = std::sync::mpsc::channel();
        let writer = std::thread::spawn(move || {
            started_sender.send(()).unwrap();
            finished_sender.send(stdout.write_bytes(b"final")).unwrap();
        });
        started_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        // A terminal-exit drain is bounded, but it must not reject committed
        // bytes while the embedder is still able to resume reading.
        assert!(finished_receiver.recv_timeout(Duration::from_millis(50)).is_err());

        let reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            reader.read_to_end(&mut bytes).unwrap();
            bytes
        });
        let result = finished_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(result.is_ok(), "terminal-exit drain failed: {result:?}");
        let bytes = reader.join().unwrap();
        assert!(bytes.ends_with(b"final"), "final bytes were not drained");
        writer.join().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn stderr_writer_bounds_a_stalled_pipe() {
        use std::os::fd::{AsRawFd, FromRawFd, RawFd};

        let mut fds = [0 as RawFd; 2];
        // SAFETY: `fds` points to two writable integers owned by this test;
        // `pipe` initializes both descriptors on success.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let reader = unsafe { File::from_raw_fd(fds[0]) };
        let writer = unsafe { File::from_raw_fd(fds[1]) };
        set_nonblocking(writer.as_raw_fd()).unwrap();

        let fill = [0_u8; 4096];
        loop {
            // SAFETY: `writer` owns the descriptor and `fill` remains alive
            // and readable for the duration of each call.
            let written =
                unsafe { libc::write(writer.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
            if written >= 0 {
                continue;
            }
            let error = io::Error::last_os_error();
            assert!(
                error.raw_os_error() == Some(libc::EAGAIN)
                    || error.raw_os_error() == Some(libc::EWOULDBLOCK),
                "unexpected pipe fill error: {error}"
            );
            break;
        }

        let started = Instant::now();
        assert!(!write_fd_line_bounded(writer.as_raw_fd(), "blocked"));
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(reader);
        drop(writer);
    }

    #[test]
    fn stdin_pump_stops_without_retaining_a_gone_remote_session() {
        let (lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
        let mut input = Cursor::new(b"{\"input\":\"aGk=\"}\n".to_vec());
        let stderr_gate = StderrGate::default();

        run_stdin_pump(&mut input, &Weak::new(), 7, &lifecycle_sender, &stderr_gate);

        assert_eq!(lifecycle_receiver.recv().unwrap(), PipeIoEvent::TransportLost);
    }

    #[test]
    fn stdin_pump_does_not_retry_non_transport_input_failures() {
        let (lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
        let mut input = Cursor::new(b"{\"input\":\"aGk=\"}\n".to_vec());

        run_stdin_pump_with_handlers(
            &mut input,
            &lifecycle_sender,
            |_bytes| PipeIoControlResult::Failed(anyhow::anyhow!("healthy daemon rejected input")),
            |_cols, _rows| PipeIoControlResult::Completed(true),
            || PipeIoControlResult::Completed(()),
            |_line| {},
        );

        assert_eq!(lifecycle_receiver.recv().unwrap(), PipeIoEvent::StdinError);
    }

    #[test]
    fn stdin_pump_reports_line_read_errors_as_stdin_errors() {
        let inputs = vec![b"\xff\n".to_vec(), vec![b'a'; MAX_PIPE_IO_LINE_BYTES + 1]];
        for input in inputs {
            let (lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
            let mut input = Cursor::new(input.to_vec());
            let stderr_gate = StderrGate::default();
            run_stdin_pump(&mut input, &Weak::new(), 7, &lifecycle_sender, &stderr_gate);
            assert_eq!(lifecycle_receiver.recv().unwrap(), PipeIoEvent::StdinError);
        }
    }

    #[test]
    fn stderr_gate_waits_for_in_flight_diagnostic_before_closing() {
        let gate = Arc::new(StderrGate::default());
        let (entered_sender, entered_receiver) = sync_channel(0);
        let (release_sender, release_receiver) = std::sync::mpsc::channel();
        let lines = Arc::new(Mutex::new(Vec::new()));

        let writer_gate = gate.clone();
        let writer_lines = lines.clone();
        let writer = std::thread::spawn(move || {
            writer_gate.emit_with("in-flight".to_string(), |line| {
                entered_sender.send(()).unwrap();
                release_receiver.recv().unwrap();
                writer_lines.lock().unwrap().push(line.to_string());
            });
        });
        entered_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        let (closed_sender, closed_receiver) = std::sync::mpsc::channel();
        let close_gate = gate.clone();
        let closer = std::thread::spawn(move || {
            close_gate.close();
            closed_sender.send(()).unwrap();
        });
        assert!(closed_receiver.recv_timeout(Duration::from_millis(50)).is_err());

        release_sender.send(()).unwrap();
        writer.join().unwrap();
        closer.join().unwrap();
        closed_receiver.recv_timeout(Duration::from_secs(1)).unwrap();

        gate.emit_with("late".to_string(), |line| lines.lock().unwrap().push(line.to_string()));
        assert_eq!(lines.lock().unwrap().as_slice(), ["in-flight"]);
    }

    #[test]
    fn stdin_pump_emits_structured_resize_and_claim_diagnostics() {
        let mut input = Cursor::new(
            b"{\"resize\":{\"cols\":100,\"rows\":30}}\n\
              {\"resize\":{\"cols\":80,\"rows\":24}}\n\
              {\"resize\":{\"cols\":120,\"rows\":40}}\n\
              {\"claim\":{\"geometry\":true}}\n\
              {\"claim\":{\"geometry\":true}}\n"
                .to_vec(),
        );
        let (lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
        let mut resize_results = vec![
            PipeIoControlResult::Completed(true),
            PipeIoControlResult::Completed(false),
            PipeIoControlResult::Failed(anyhow::anyhow!("resize rejected")),
        ]
        .into_iter();
        let mut claim_results = vec![
            PipeIoControlResult::Completed(()),
            PipeIoControlResult::Failed(anyhow::anyhow!("claim enqueue failed")),
        ]
        .into_iter();
        let mut diagnostics = Vec::new();

        run_stdin_pump_with_handlers(
            &mut input,
            &lifecycle_sender,
            |_bytes| PipeIoControlResult::Completed(()),
            |cols, rows| {
                assert!(matches!((cols, rows), (100, 30) | (80, 24) | (120, 40)));
                resize_results.next().unwrap()
            },
            || claim_results.next().unwrap(),
            |line| diagnostics.push(line),
        );

        assert_eq!(lifecycle_receiver.recv().unwrap(), PipeIoEvent::StdinClosed);
        let diagnostics = diagnostics
            .iter()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            diagnostics,
            vec![
                serde_json::json!({"diag": {"resize": {"cols": 100, "rows": 30, "accepted": true}}}),
                serde_json::json!({"diag": {"resize": {"cols": 80, "rows": 24, "accepted": false}}}),
                serde_json::json!({"diag": {"resize": {"cols": 120, "rows": 40, "error": RESIZE_ERROR_CODE}}}),
                serde_json::json!({"diag": {"claim": {"accepted": true}}}),
                serde_json::json!({"diag": {"claim": {"error": CLAIM_ERROR_CODE}}}),
            ]
        );
    }

    #[test]
    fn stdin_pump_uses_contract_tokens_when_remote_session_is_gone() {
        for (line, expected) in [
            (
                r#"{"resize":{"cols":80,"rows":24}}"#,
                serde_json::json!({
                    "diag": {
                        "resize": {
                            "cols": 80,
                            "rows": 24,
                            "error": RESIZE_ERROR_CODE,
                        }
                    }
                }),
            ),
            (
                r#"{"claim":{"geometry":true}}"#,
                serde_json::json!({"diag": {"claim": {"error": CLAIM_ERROR_CODE}}}),
            ),
        ] {
            let mut input = Cursor::new(format!("{line}\n").into_bytes());
            let (lifecycle_sender, lifecycle_receiver) = crossbeam_channel::bounded(1);
            let mut diagnostics = Vec::new();

            run_stdin_pump_with_handlers(
                &mut input,
                &lifecycle_sender,
                |_bytes| PipeIoControlResult::Completed(()),
                |_cols, _rows| PipeIoControlResult::Gone,
                || PipeIoControlResult::Gone,
                |line| diagnostics.push(line),
            );

            assert_eq!(lifecycle_receiver.recv().unwrap(), PipeIoEvent::TransportLost);
            assert_eq!(diagnostics.len(), 1);
            assert_eq!(
                serde_json::from_str::<serde_json::Value>(&diagnostics[0]).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn attach_failures_preserve_terminal_and_daemon_exit_contracts() {
        let terminal_ended =
            crate::session::test_remote_rejected_error_with_message("unknown surface 7");
        assert_eq!(attach_failure_exit_reason(&terminal_ended), PipeIoExitReason::SetupFailed);

        let daemon_lost = crate::session::test_remote_transport_error();
        assert_eq!(attach_failure_exit_reason(&daemon_lost), PipeIoExitReason::DaemonLost);

        let unexpected = anyhow::anyhow!("attach capability negotiation failed");
        assert_eq!(attach_failure_exit_reason(&unexpected), PipeIoExitReason::SetupFailed);
    }
}
