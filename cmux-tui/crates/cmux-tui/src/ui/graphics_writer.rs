use std::collections::VecDeque;
use std::io;
#[cfg(test)]
use std::io::Write;
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
#[cfg(test)]
use std::sync::atomic::AtomicU64;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::thread::{JoinHandle, ThreadId};
use std::time::{Duration, Instant};

use cmux_tui_core::{Rect, SurfaceId};
use crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use parking_lot::{ReentrantMutex, ReentrantMutexGuard};

use super::graphics::{
    GraphicPlacement, GraphicsState, PROCESSING_FENCE_ID_BASE, processing_fence,
    processing_fence_id,
};

pub struct StdoutLock {
    mutex: ReentrantMutex<()>,
}

impl StdoutLock {
    pub fn new(_: ()) -> Self {
        Self { mutex: ReentrantMutex::new(()) }
    }

    pub fn lock(&self) -> ReentrantMutexGuard<'_, ()> {
        self.mutex.lock()
    }

    #[cfg(test)]
    pub fn try_lock(&self) -> Option<ReentrantMutexGuard<'_, ()>> {
        self.mutex.try_lock()
    }

    pub(crate) const fn recover_stream_locked(&self) -> io::Result<()> {
        Ok(())
    }
}

const PROCESSING_FENCE_TIMEOUT: Duration = Duration::from_secs(1);
const PROCESSING_FENCE_SHUTDOWN_POLL: Duration = Duration::from_millis(25);
const LATE_FENCE_RESPONSE_GRACE: Duration = Duration::from_secs(4);
const INCOMPLETE_GRAPHICS_RESPONSE_GRACE: Duration = Duration::from_millis(200);
const MAX_RETIRED_FENCES: usize = 4;
const MAX_GRAPHICS_RESPONSE_EVENTS: usize = 128;
const MAX_CONSECUTIVE_GRAPHICS_FENCE_TIMEOUTS: u8 = 2;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessedGraphic {
    pub surface: SurfaceId,
    pub rect: Rect,
    pub seq: u64,
    pub pointer_frame_seq: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GraphicsProcessing {
    pub id: u64,
    pub session_generation: u64,
    pub graphics: Vec<ProcessedGraphic>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GraphicsCompletion {
    Processed(GraphicsProcessing),
    TimedOut { id: u64, session_generation: u64 },
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct GraphicsFenceResponse {
    id: u32,
    ok: bool,
}

pub struct GraphicsFenceWaiter {
    responses: Receiver<GraphicsFenceResponse>,
    state: Arc<Mutex<GraphicsFenceState>>,
}

#[derive(Clone)]
pub struct GraphicsFenceNotifier {
    responses: SyncSender<GraphicsFenceResponse>,
    state: Arc<Mutex<GraphicsFenceState>>,
}

#[derive(Default)]
struct GraphicsFenceState {
    expected: u32,
    retired: VecDeque<RetiredGraphicsFence>,
}

struct RetiredGraphicsFence {
    id: u32,
    expires_at: Instant,
}

impl GraphicsFenceState {
    fn prune(&mut self, now: Instant) {
        self.retired.retain(|fence| fence.expires_at > now);
    }

    fn retire(&mut self, id: u32, now: Instant) {
        if id == 0 {
            return;
        }
        self.prune(now);
        self.retired.retain(|fence| fence.id != id);
        self.retired
            .push_back(RetiredGraphicsFence { id, expires_at: now + LATE_FENCE_RESPONSE_GRACE });
        while self.retired.len() > MAX_RETIRED_FENCES {
            self.retired.pop_front();
        }
    }

    fn candidates(&mut self, now: Instant) -> Vec<u32> {
        self.prune(now);
        let mut candidates =
            Vec::with_capacity(self.retired.len() + usize::from(self.expected != 0));
        if self.expected != 0 {
            candidates.push(self.expected);
        }
        for fence in &self.retired {
            if !candidates.contains(&fence.id) {
                candidates.push(fence.id);
            }
        }
        candidates
    }
}

pub fn graphics_fence_channel() -> (GraphicsFenceWaiter, GraphicsFenceNotifier) {
    let (responses, pending) = sync_channel(4);
    let state = Arc::new(Mutex::new(GraphicsFenceState::default()));
    (
        GraphicsFenceWaiter { responses: pending, state: state.clone() },
        GraphicsFenceNotifier { responses, state },
    )
}

impl GraphicsFenceWaiter {
    fn prepare(&self, expected: u32) {
        while self.responses.try_recv().is_ok() {}
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        if state.expected != 0 && state.expected != expected {
            let previous = state.expected;
            state.retire(previous, now);
        }
        state.expected = expected;
    }

    fn cancel(&self, expected: u32) {
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        if state.expected == expected {
            state.expected = 0;
            state.retire(expected, now);
        }
    }

    #[cfg(test)]
    fn wait_for(&self, expected: u32) -> io::Result<()> {
        self.wait_for_shutdown(expected, &AtomicBool::new(false))
    }

    fn wait_for_shutdown(&self, expected: u32, shutdown: &AtomicBool) -> io::Result<()> {
        let deadline = Instant::now() + PROCESSING_FENCE_TIMEOUT;
        let response = loop {
            if shutdown.load(Ordering::Acquire) {
                self.cancel(expected);
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "graphics processing fence wait interrupted by shutdown",
                ));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                self.cancel(expected);
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "graphics processing fence timed out",
                ));
            }
            match self.responses.recv_timeout(remaining.min(PROCESSING_FENCE_SHUTDOWN_POLL)) {
                Ok(response) => break response,
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    self.cancel(expected);
                    return Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "graphics processing fence channel disconnected",
                    ));
                }
            }
        };
        self.cancel(expected);
        if response.id != expected {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "graphics processing fence replied out of order: expected {expected}, got {}",
                    response.id
                ),
            ));
        }
        if !response.ok {
            return Err(io::Error::other(format!(
                "host rejected graphics processing fence {expected}"
            )));
        }
        Ok(())
    }
}

impl GraphicsFenceNotifier {
    fn candidate_ids(&self) -> Vec<u32> {
        self.state.lock().unwrap().candidates(Instant::now())
    }

    fn has_active_candidate(&self, candidates: &[u32]) -> bool {
        let state = self.state.lock().unwrap();
        state.expected != 0 && candidates.contains(&state.expected)
    }

    fn notify(&self, response: GraphicsFenceResponse) {
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        state.prune(now);
        let active = state.expected == response.id;
        if active {
            state.expected = 0;
            state.retire(response.id, now);
        }
        drop(state);
        if active {
            let _ = self.responses.try_send(response);
        }
    }
}

struct BufferedGraphicsResponse {
    candidates: Vec<u32>,
    events: Vec<Event>,
    payload: String,
    inactive_since: Option<Instant>,
}

/// Crossterm exposes an APC reply as Alt+_ followed by ordinary key events and
/// Alt+\. Reassemble only complete Kitty graphics responses and leave every
/// other host input unchanged.
pub struct GraphicsResponseFilter {
    notifier: GraphicsFenceNotifier,
    buffered: Option<BufferedGraphicsResponse>,
}

impl GraphicsResponseFilter {
    pub fn new(notifier: GraphicsFenceNotifier) -> Self {
        Self { notifier, buffered: None }
    }

    fn refresh_inactive_since(&mut self, now: Instant) {
        let active = self
            .buffered
            .as_ref()
            .is_some_and(|buffered| self.notifier.has_active_candidate(&buffered.candidates));
        if let Some(buffered) = self.buffered.as_mut() {
            if active {
                buffered.inactive_since = None;
            } else {
                buffered.inactive_since.get_or_insert(now);
            }
        }
    }

    pub fn time_until_expiry(&mut self) -> Option<Duration> {
        let now = Instant::now();
        self.refresh_inactive_since(now);
        self.buffered.as_ref().and_then(|buffered| {
            buffered.inactive_since.map(|inactive_since| {
                (inactive_since + INCOMPLETE_GRAPHICS_RESPONSE_GRACE).saturating_duration_since(now)
            })
        })
    }

    pub fn take_expired(&mut self) -> Vec<Event> {
        let now = Instant::now();
        self.refresh_inactive_since(now);
        let expired = self.buffered.as_ref().is_some_and(|buffered| {
            buffered.inactive_since.is_some_and(|inactive_since| {
                now.saturating_duration_since(inactive_since) >= INCOMPLETE_GRAPHICS_RESPONSE_GRACE
            })
        });
        if expired {
            return self.buffered.take().unwrap().events;
        }
        Vec::new()
    }

    pub fn filter(&mut self, event: Event) -> Vec<Event> {
        let now = Instant::now();
        self.refresh_inactive_since(now);
        if self.buffered.as_ref().is_some_and(|buffered| {
            buffered.inactive_since.is_some_and(|inactive_since| {
                now.saturating_duration_since(inactive_since) >= INCOMPLETE_GRAPHICS_RESPONSE_GRACE
            })
        }) {
            let mut replay = self.buffered.take().unwrap().events;
            replay.extend(self.filter(event));
            return replay;
        }
        if self.buffered.is_none() {
            let candidates = self.notifier.candidate_ids();
            if !candidates.is_empty() && is_apc_boundary(&event, '_') {
                self.buffered = Some(BufferedGraphicsResponse {
                    candidates,
                    events: vec![event],
                    payload: String::new(),
                    inactive_since: None,
                });
                return Vec::new();
            }
            return vec![event];
        }

        if is_apc_boundary(&event, '_') {
            let mut replay = self.buffered.take().unwrap().events;
            let candidates = self.notifier.candidate_ids();
            if candidates.is_empty() {
                replay.push(event);
            } else {
                self.buffered = Some(BufferedGraphicsResponse {
                    candidates,
                    events: vec![event],
                    payload: String::new(),
                    inactive_since: None,
                });
            }
            return replay;
        }

        if is_apc_boundary(&event, '\\') {
            let mut buffered = self.buffered.take().unwrap();
            buffered.events.push(event);
            if let Some(response) = parse_graphics_response(&buffered.payload)
                && response.id >= PROCESSING_FENCE_ID_BASE
                && buffered.candidates.contains(&response.id)
            {
                self.notifier.notify(response);
                return Vec::new();
            }
            return buffered.events;
        }

        let Some(ch) = graphics_response_char(&event) else {
            let mut replay = self.buffered.take().unwrap().events;
            replay.push(event);
            return replay;
        };
        let buffered = self.buffered.as_mut().unwrap();
        buffered.events.push(event);
        if buffered.events.len() > MAX_GRAPHICS_RESPONSE_EVENTS {
            return self.buffered.take().unwrap().events;
        }
        buffered.payload.push(ch);
        if !buffered.payload.starts_with('G') {
            return self.buffered.take().unwrap().events;
        }
        Vec::new()
    }
}

fn is_apc_boundary(event: &Event, boundary: char) -> bool {
    matches!(
        event,
        Event::Key(KeyEvent {
            code: KeyCode::Char(ch),
            modifiers,
            kind: KeyEventKind::Press,
            ..
        }) if *ch == boundary && *modifiers == KeyModifiers::ALT
    )
}

fn graphics_response_char(event: &Event) -> Option<char> {
    let Event::Key(KeyEvent {
        code: KeyCode::Char(ch), modifiers, kind: KeyEventKind::Press, ..
    }) = event
    else {
        return None;
    };
    (*ch)
        .is_ascii()
        .then_some(*ch)
        .filter(|_| modifiers.is_empty() || *modifiers == KeyModifiers::SHIFT)
}

fn parse_graphics_response(payload: &str) -> Option<GraphicsFenceResponse> {
    let (control, message) = payload.strip_prefix('G')?.split_once(';')?;
    let id = control.split(',').find_map(|field| field.strip_prefix("i="))?.parse::<u32>().ok()?;
    Some(GraphicsFenceResponse { id, ok: message == "OK" })
}

trait ProcessingFence: Send + 'static {
    fn prepare(&mut self, _id: u32) {}
    fn cancel(&mut self, _id: u32) {}
    fn wait(&mut self, id: u32, shutdown: &AtomicBool) -> io::Result<()>;
}

impl ProcessingFence for GraphicsFenceWaiter {
    fn prepare(&mut self, id: u32) {
        GraphicsFenceWaiter::prepare(self, id);
    }

    fn cancel(&mut self, id: u32) {
        GraphicsFenceWaiter::cancel(self, id);
    }

    fn wait(&mut self, id: u32, shutdown: &AtomicBool) -> io::Result<()> {
        self.wait_for_shutdown(id, shutdown)
    }
}

#[cfg(test)]
struct ClosureProcessingFence<F>(F);

#[cfg(test)]
impl<F> ProcessingFence for ClosureProcessingFence<F>
where
    F: FnMut() -> io::Result<()> + Send + 'static,
{
    fn wait(&mut self, _id: u32, shutdown: &AtomicBool) -> io::Result<()> {
        if shutdown.load(Ordering::Acquire) {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "graphics processing fence wait interrupted by shutdown",
            ));
        }
        (self.0)()
    }
}

/// Bound one stdout-lock hold while preserving complete Kitty APC commands.
/// This lets ordinary terminal draws make progress during multi-megabyte
/// image uploads without ever interleaving bytes inside one protocol command.
const MAX_LOCKED_GRAPHICS_WRITE_BYTES: usize = 64 * 1024;
const CONTROL_STRING_CANCEL: u8 = 0x18;
const DELETE_ALL_GRAPHICS: &[u8] = b"\x1b_Ga=d,d=A,q=2;\x1b\\";
const TERMINATE_MULTIPART_GRAPHICS: &[u8] = b"\x1b_Gq=2,m=0;\x1b\\\x1b_Ga=d,d=A,q=2;\x1b\\";
#[cfg(unix)]
const OUTPUT_POLL_INTERVAL_MS: i32 = 20;
#[cfg(unix)]
const CONTROL_STRING_ABORT_TIMEOUT: Duration = Duration::from_millis(200);
#[cfg(unix)]
const GRAPHICS_SEGMENT_WRITE_TIMEOUT: Duration = Duration::from_millis(200);

trait GraphicsOutput: Send + 'static {
    /// Write one complete group of Kitty APC commands. `Ok(false)` means
    /// cancellation or snapshot supersession won before the complete group
    /// was emitted. `emitted` reports accepted bytes even when the write
    /// stops early, so completed multipart chunks can still be recovered.
    fn write_segment(
        &mut self,
        bytes: &[u8],
        permit: &WritePermit<'_>,
        emitted: &mut usize,
    ) -> io::Result<bool>;

    /// Write protocol recovery bytes without honoring the permit that caused
    /// the interruption. Production implementations must keep this bounded.
    fn write_recovery(&mut self, bytes: &[u8]) -> io::Result<()>;
}

#[cfg(unix)]
struct InterruptibleStdout {
    fd: OwnedFd,
}

#[cfg(unix)]
impl InterruptibleStdout {
    fn open() -> io::Result<Self> {
        // `dup` would share file-status flags with stdout, so setting
        // O_NONBLOCK on the duplicate would also make ratatui's stdout
        // writes nonblocking. Opening the controlling terminal creates an
        // independent open-file description for the same terminal.
        let raw = unsafe {
            libc::open(c"/dev/tty".as_ptr(), libc::O_WRONLY | libc::O_NONBLOCK | libc::O_CLOEXEC)
        };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        Ok(Self { fd })
    }

    fn abort_partial_control_string(&mut self) -> io::Result<()> {
        let deadline = Instant::now() + CONTROL_STRING_ABORT_TIMEOUT;
        loop {
            if Instant::now() >= deadline {
                // The terminal output queue is shared with Ratatui and other
                // descriptors. A graphics timeout may abandon this operation,
                // but it must never flush their bytes.
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "terminal stayed blocked while canceling a partial control string",
                ));
            }
            let written = unsafe {
                libc::write(self.fd.as_raw_fd(), (&CONTROL_STRING_CANCEL as *const u8).cast(), 1)
            };
            if written == 1 {
                return Ok(());
            }
            if written == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "terminal accepted zero cancellation bytes",
                ));
            }
            let error = io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EINTR) => continue,
                Some(libc::EAGAIN) => {
                    let mut poll_fd =
                        libc::pollfd { fd: self.fd.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    let poll_ms = remaining
                        .min(Duration::from_millis(OUTPUT_POLL_INTERVAL_MS as u64))
                        .as_millis() as i32;
                    let ready = unsafe { libc::poll(&mut poll_fd, 1, poll_ms) };
                    if ready < 0 && io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                        return Err(io::Error::last_os_error());
                    }
                }
                _ => return Err(error),
            }
        }
    }
}

#[cfg(unix)]
impl GraphicsOutput for InterruptibleStdout {
    fn write_segment(
        &mut self,
        bytes: &[u8],
        permit: &WritePermit<'_>,
        emitted: &mut usize,
    ) -> io::Result<bool> {
        let mut offset = 0;
        *emitted = 0;
        let deadline = Instant::now() + GRAPHICS_SEGMENT_WRITE_TIMEOUT;
        while offset < bytes.len() {
            if permit.should_abort() {
                if offset != 0 {
                    self.abort_partial_control_string()?;
                }
                return Ok(false);
            }
            if Instant::now() >= deadline {
                if offset != 0 {
                    self.abort_partial_control_string()?;
                }
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "terminal stayed blocked while writing a graphics segment",
                ));
            }
            let written = unsafe {
                libc::write(
                    self.fd.as_raw_fd(),
                    bytes[offset..].as_ptr().cast(),
                    bytes.len() - offset,
                )
            };
            if written > 0 {
                offset += written as usize;
                *emitted = offset;
                continue;
            }
            if written == 0 {
                if offset != 0 {
                    let _ = self.abort_partial_control_string();
                }
                return Err(io::Error::new(io::ErrorKind::WriteZero, "stdout accepted zero bytes"));
            }
            let error = io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EINTR) => continue,
                Some(libc::EAGAIN) => {
                    #[cfg(test)]
                    permit.control.report_write_attempt();
                    let mut poll_fd =
                        libc::pollfd { fd: self.fd.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
                    let ready = unsafe { libc::poll(&mut poll_fd, 1, OUTPUT_POLL_INTERVAL_MS) };
                    if ready < 0 && io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                        return Err(io::Error::last_os_error());
                    }
                }
                _ => {
                    if offset != 0 {
                        let _ = self.abort_partial_control_string();
                    }
                    return Err(error);
                }
            }
        }
        Ok(true)
    }

    fn write_recovery(&mut self, bytes: &[u8]) -> io::Result<()> {
        let mut offset = 0;
        let deadline = Instant::now() + CONTROL_STRING_ABORT_TIMEOUT;
        while offset < bytes.len() {
            if Instant::now() >= deadline {
                if offset != 0 {
                    let _ = self.abort_partial_control_string();
                }
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "terminal stayed blocked while recovering a graphics command",
                ));
            }
            let written = unsafe {
                libc::write(
                    self.fd.as_raw_fd(),
                    bytes[offset..].as_ptr().cast(),
                    bytes.len() - offset,
                )
            };
            if written > 0 {
                offset += written as usize;
                continue;
            }
            if written == 0 {
                if offset != 0 {
                    let _ = self.abort_partial_control_string();
                }
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "terminal accepted zero recovery bytes",
                ));
            }
            let error = io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EINTR) => continue,
                Some(libc::EAGAIN) => {
                    let mut poll_fd =
                        libc::pollfd { fd: self.fd.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    let poll_ms = remaining
                        .min(Duration::from_millis(OUTPUT_POLL_INTERVAL_MS as u64))
                        .as_millis() as i32;
                    let ready = unsafe { libc::poll(&mut poll_fd, 1, poll_ms) };
                    if ready < 0 && io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                        if offset != 0 {
                            let _ = self.abort_partial_control_string();
                        }
                        return Err(io::Error::last_os_error());
                    }
                }
                _ => {
                    if offset != 0 {
                        let _ = self.abort_partial_control_string();
                    }
                    return Err(error);
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
struct TestOutput<W>(W);

#[cfg(test)]
impl<W> GraphicsOutput for TestOutput<W>
where
    W: Write + Send + 'static,
{
    fn write_segment(
        &mut self,
        bytes: &[u8],
        permit: &WritePermit<'_>,
        emitted: &mut usize,
    ) -> io::Result<bool> {
        *emitted = 0;
        if permit.should_abort() {
            return Ok(false);
        }
        self.0.write_all(bytes)?;
        self.0.flush()?;
        *emitted = bytes.len();
        Ok(true)
    }

    fn write_recovery(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.0.write_all(bytes)?;
        self.0.flush()
    }
}

pub(crate) type GraphicsScene = Vec<Arc<[GraphicPlacement]>>;

struct GraphicsSubmission {
    id: u64,
    session_generation: u64,
    scene: GraphicsScene,
}

#[derive(Default)]
struct PendingGraphics {
    submission: Option<GraphicsSubmission>,
    host_scene_epoch: u64,
    revision: u64,
}

struct PendingUpdate {
    submission: Option<GraphicsSubmission>,
    host_scene_epoch: u64,
    revision: u64,
}

struct WriterLoopState {
    slot: Arc<Mutex<PendingGraphics>>,
    completion: Arc<Mutex<Option<GraphicsCompletion>>>,
    notifications: Receiver<()>,
    stdout_lock: Arc<StdoutLock>,
    control: Arc<WriterControl>,
}

struct WritePermit<'a> {
    slot: &'a Mutex<PendingGraphics>,
    control: &'a WriterControl,
    revision: u64,
}

impl WritePermit<'_> {
    fn superseded(&self) -> bool {
        lock_recover(self.slot).revision != self.revision
    }

    fn should_abort(&self) -> bool {
        self.control.is_cancelled() || self.superseded()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct GraphicsWriterFailure {
    pub(crate) parser_reset_required: bool,
}

#[derive(Default)]
struct WriterControlState {
    done: bool,
    failure: Option<GraphicsWriterFailure>,
}

#[derive(Default)]
struct WriterControl {
    stop_requested: AtomicBool,
    cancelled: AtomicBool,
    worker_thread: OnceLock<ThreadId>,
    state: Mutex<WriterControlState>,
    changed: Condvar,
    #[cfg(test)]
    write_attempt_observer: Mutex<Option<SyncSender<()>>>,
}

impl WriterControl {
    fn request_stop(&self, notify: &SyncSender<()>) {
        self.stop_requested.store(true, Ordering::Release);
        notify_writer(notify);
    }

    fn request_cancel(&self, notify: &SyncSender<()>) {
        self.cancelled.store(true, Ordering::Release);
        self.changed.notify_all();
        notify_writer(notify);
    }

    fn is_stopping(&self) -> bool {
        self.stop_requested.load(Ordering::Acquire)
            || self.is_cancelled()
            || self.failure().is_some()
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    fn mark_done(&self) {
        self.state.lock().unwrap().done = true;
        self.changed.notify_all();
    }

    fn record_failure(&self, parser_reset_required: bool) {
        let mut state = self.state.lock().unwrap();
        state.failure = Some(GraphicsWriterFailure {
            parser_reset_required: state
                .failure
                .is_some_and(|failure| failure.parser_reset_required)
                || parser_reset_required,
        });
        self.changed.notify_all();
    }

    fn failure(&self) -> Option<GraphicsWriterFailure> {
        self.state.lock().unwrap().failure
    }

    fn wait_done(&self) {
        let state = self.state.lock().unwrap();
        drop(self.changed.wait_while(state, |state| !state.done).unwrap());
    }

    fn wait_done_timeout(&self, timeout: Duration) -> bool {
        let state = self.state.lock().unwrap();
        if state.done {
            return true;
        }
        let (state, _) =
            self.changed.wait_timeout_while(state, timeout, |state| !state.done).unwrap();
        state.done
    }

    #[cfg(test)]
    fn wait_until_cancelled(&self) {
        let state = self.state.lock().unwrap();
        drop(self.changed.wait_while(state, |_| !self.cancelled.load(Ordering::Acquire)).unwrap());
    }

    #[cfg(test)]
    fn observe_write_attempts(&self, observer: SyncSender<()>) {
        *self.write_attempt_observer.lock().unwrap() = Some(observer);
    }

    #[cfg(test)]
    fn report_write_attempt(&self) {
        if let Some(observer) = self.write_attempt_observer.lock().unwrap().as_ref() {
            let _ = observer.try_send(());
        }
    }
}

#[derive(Clone)]
pub(crate) struct GraphicsWriterShutdown {
    control: Arc<WriterControl>,
    notify: SyncSender<()>,
}

impl GraphicsWriterShutdown {
    /// Stop the writer and wait until no future host-terminal writes are
    /// possible. Callers must not own the stdout lock while waiting.
    pub(crate) fn cancel_and_wait(&self) {
        self.control.request_cancel(&self.notify);
        if self
            .control
            .worker_thread
            .get()
            .is_none_or(|worker| *worker != std::thread::current().id())
        {
            self.control.wait_done();
        }
    }

    pub(crate) fn cancel_for_panic_hook(&self) {
        // A renderer panic can still own the reentrant stdout lock. Only
        // signal here; the writer observes cancellation before writing after
        // that lock is released, and normal unwind cleanup performs the join.
        self.control.request_cancel(&self.notify);
    }

    #[cfg(test)]
    fn wait_until_cancelled(&self) {
        self.control.wait_until_cancelled();
    }
}

pub struct GraphicsWriter {
    slot: Arc<Mutex<PendingGraphics>>,
    completion: Arc<Mutex<Option<GraphicsCompletion>>>,
    notify: Option<SyncSender<()>>,
    control: Arc<WriterControl>,
    handle: Option<JoinHandle<()>>,
}

impl GraphicsWriter {
    pub(crate) const fn platform_supported() -> bool {
        cfg!(unix)
    }

    #[cfg(unix)]
    pub fn spawn(
        stdout_lock: Arc<StdoutLock>,
        processing_fence: GraphicsFenceWaiter,
        on_ready: impl Fn() + Send + 'static,
    ) -> io::Result<Self> {
        Self::spawn_with_graphics_output(
            stdout_lock,
            InterruptibleStdout::open()?,
            processing_fence,
            on_ready,
        )
    }

    #[cfg(not(unix))]
    pub fn spawn(
        _stdout_lock: Arc<StdoutLock>,
        _processing_fence: GraphicsFenceWaiter,
        _on_ready: impl Fn() + Send + 'static,
    ) -> io::Result<Self> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "inline graphics output requires an interruptible terminal writer",
        ))
    }

    #[cfg(test)]
    fn spawn_with_output<W>(stdout_lock: Arc<StdoutLock>, output: W) -> io::Result<Self>
    where
        W: Write + Send + 'static,
    {
        Self::spawn_with_output_and_fence(stdout_lock, output, || Ok(()), || {})
    }

    #[cfg(test)]
    fn spawn_with_output_and_fence<W>(
        stdout_lock: Arc<StdoutLock>,
        output: W,
        processing_fence: impl FnMut() -> io::Result<()> + Send + 'static,
        on_ready: impl Fn() + Send + 'static,
    ) -> io::Result<Self>
    where
        W: Write + Send + 'static,
    {
        Self::spawn_with_graphics_output(
            stdout_lock,
            TestOutput(output),
            ClosureProcessingFence(processing_fence),
            on_ready,
        )
    }

    #[cfg(test)]
    fn spawn_with_test_graphics_output<O>(
        stdout_lock: Arc<StdoutLock>,
        output: O,
    ) -> io::Result<Self>
    where
        O: GraphicsOutput,
    {
        Self::spawn_with_graphics_output(
            stdout_lock,
            output,
            ClosureProcessingFence(|| Ok(())),
            || {},
        )
    }

    fn spawn_with_graphics_output<O>(
        stdout_lock: Arc<StdoutLock>,
        output: O,
        processing_fence: impl ProcessingFence,
        on_ready: impl Fn() + Send + 'static,
    ) -> io::Result<Self>
    where
        O: GraphicsOutput,
    {
        let (tx, rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(PendingGraphics::default()));
        let completion = Arc::new(Mutex::new(None));
        let control = Arc::new(WriterControl::default());
        let handle = std::thread::Builder::new().name("mux-graphics-writer".into()).spawn({
            let slot = slot.clone();
            let completion = completion.clone();
            let control = control.clone();
            move || {
                writer_loop(
                    WriterLoopState { slot, completion, notifications: rx, stdout_lock, control },
                    output,
                    processing_fence,
                    on_ready,
                );
            }
        })?;
        Ok(Self { slot, completion, notify: Some(tx), control, handle: Some(handle) })
    }

    pub(crate) fn shutdown_control(&self) -> GraphicsWriterShutdown {
        GraphicsWriterShutdown {
            control: self.control.clone(),
            notify: self.notify.as_ref().expect("active graphics writer").clone(),
        }
    }

    pub(crate) fn failure(&self) -> Option<GraphicsWriterFailure> {
        self.control.failure()
    }

    #[cfg(test)]
    pub fn submit(
        &self,
        id: u64,
        session_generation: u64,
        placements: Vec<GraphicPlacement>,
    ) -> bool {
        self.submit_scene(id, session_generation, vec![Arc::from(placements)])
    }

    #[cfg(test)]
    fn submit_test(&self, placements: Vec<GraphicPlacement>) -> bool {
        static NEXT_SUBMISSION: AtomicU64 = AtomicU64::new(1);
        self.submit(NEXT_SUBMISSION.fetch_add(1, Ordering::Relaxed), 1, placements)
    }

    pub(crate) fn submit_scene(
        &self,
        id: u64,
        session_generation: u64,
        scene: GraphicsScene,
    ) -> bool {
        if self.control.is_stopping() {
            return false;
        }
        let Some(tx) = &self.notify else { return false };
        submit_snapshot(&self.slot, tx, GraphicsSubmission { id, session_generation, scene })
    }

    pub fn take_completion(&self) -> Option<GraphicsCompletion> {
        self.completion.lock().unwrap().take()
    }

    /// Mark the host terminal's Kitty scene as cleared.
    ///
    /// The epoch remains in the latest-wins slot until the writer observes
    /// it, so later snapshot replacement cannot discard the invalidation.
    pub fn invalidate_host_scene(&self) {
        if self.control.is_stopping() {
            return;
        }
        let Some(tx) = &self.notify else { return };
        let mut pending = lock_recover(&self.slot);
        pending.revision = pending.revision.wrapping_add(1).max(1);
        pending.host_scene_epoch = pending.host_scene_epoch.wrapping_add(1);
        if pending.host_scene_epoch == 0 {
            pending.host_scene_epoch = 1;
        }
        drop(pending);
        notify_writer(tx);
    }

    pub fn shutdown(&mut self, timeout: Duration) {
        let Some(handle) = self.handle.take() else { return };
        let Some(notify) = self.notify.as_ref() else {
            let _ = handle.join();
            return;
        };
        self.control.request_stop(notify);
        if !self.control.wait_done_timeout(timeout) {
            self.control.request_cancel(notify);
            // The production stdout descriptor is nonblocking and polls
            // cancellation at most every OUTPUT_POLL_INTERVAL_MS.
            self.control.wait_done();
        }
        let _ = handle.join();
        self.notify.take();
    }
}

impl Drop for GraphicsWriter {
    fn drop(&mut self) {
        self.shutdown(Duration::from_millis(200));
    }
}

fn submit_snapshot(
    slot: &Arc<Mutex<PendingGraphics>>,
    tx: &SyncSender<()>,
    submission: GraphicsSubmission,
) -> bool {
    let mut pending = lock_recover(slot);
    pending.revision = pending.revision.wrapping_add(1).max(1);
    pending.submission = Some(submission);
    drop(pending);
    notify_writer(tx)
}

fn notify_writer(tx: &SyncSender<()>) -> bool {
    match tx.try_send(()) {
        Ok(()) | Err(TrySendError::Full(())) => true,
        Err(TrySendError::Disconnected(())) => false,
    }
}

fn take_pending_update(
    slot: &Arc<Mutex<PendingGraphics>>,
    applied_host_scene_epoch: u64,
) -> Option<PendingUpdate> {
    let mut pending = lock_recover(slot);
    if pending.submission.is_none() && pending.host_scene_epoch == applied_host_scene_epoch {
        return None;
    }
    Some(PendingUpdate {
        submission: pending.submission.take(),
        host_scene_epoch: pending.host_scene_epoch,
        revision: pending.revision,
    })
}

fn writer_loop<O, P, F>(
    state: WriterLoopState,
    mut output: O,
    mut processing_fence_waiter: P,
    on_ready: F,
) where
    O: GraphicsOutput,
    P: ProcessingFence,
    F: Fn(),
{
    let WriterLoopState { slot, completion, notifications, stdout_lock, control } = state;
    let _ = control.worker_thread.set(std::thread::current().id());
    let _done = DoneOnDrop(control.clone());
    let mut graphics = GraphicsState::default();
    let mut applied_host_scene_epoch = 0;
    let mut host_reset_required = false;
    let mut consecutive_fence_timeouts = 0_u8;
    'writer: loop {
        if control.is_cancelled() {
            break;
        }
        while let Some(update) = take_pending_update(&slot, applied_host_scene_epoch) {
            if update.host_scene_epoch != applied_host_scene_epoch {
                graphics.invalidate_host_scene();
                applied_host_scene_epoch = update.host_scene_epoch;
                host_reset_required = false;
            }
            let Some(submission) = update.submission else {
                continue;
            };
            if host_reset_required {
                match write_batch(
                    &mut output,
                    &stdout_lock,
                    &slot,
                    &control,
                    update.revision,
                    DELETE_ALL_GRAPHICS,
                ) {
                    BatchWriteOutcome::Complete => {
                        graphics.invalidate_host_scene();
                        host_reset_required = false;
                    }
                    BatchWriteOutcome::Superseded => continue,
                    BatchWriteOutcome::Stopped => break 'writer,
                }
            }
            let placements = submission
                .scene
                .iter()
                .flat_map(|placements| placements.iter().cloned())
                .collect::<Vec<_>>();
            let processed_graphics = placements
                .iter()
                .filter(|placement| placement.is_browser_frame())
                .map(|placement| ProcessedGraphic {
                    surface: placement.key.image.surface,
                    rect: placement.rect,
                    seq: placement.image.generation,
                    pointer_frame_seq: placement.pointer_frame_seq,
                })
                .collect::<Vec<_>>();
            let mut next_graphics = graphics.clone();
            let mut completed = true;
            let mut wrote_batch = false;
            let mut batches = next_graphics.frame_batch_stream(&placements);
            loop {
                if control.is_cancelled() {
                    break 'writer;
                }
                if lock_recover(&slot).revision != update.revision {
                    host_reset_required |= wrote_batch;
                    completed = false;
                    break;
                }
                let Some(batch) = batches.next() else {
                    break;
                };
                match write_batch(
                    &mut output,
                    &stdout_lock,
                    &slot,
                    &control,
                    update.revision,
                    &batch,
                ) {
                    BatchWriteOutcome::Complete => wrote_batch = true,
                    BatchWriteOutcome::Superseded => {
                        host_reset_required = true;
                        completed = false;
                        break;
                    }
                    BatchWriteOutcome::Stopped => break 'writer,
                }
            }
            drop(batches);
            if !completed {
                continue;
            }

            let fence_id = processing_fence_id(submission.id);
            processing_fence_waiter.prepare(fence_id);
            match write_batch(
                &mut output,
                &stdout_lock,
                &slot,
                &control,
                update.revision,
                &processing_fence(fence_id),
            ) {
                BatchWriteOutcome::Complete => {}
                BatchWriteOutcome::Superseded => {
                    processing_fence_waiter.cancel(fence_id);
                    host_reset_required = true;
                    continue;
                }
                BatchWriteOutcome::Stopped => {
                    processing_fence_waiter.cancel(fence_id);
                    break 'writer;
                }
            }

            let mut processed = processing_fence_waiter.wait(fence_id, &control.cancelled);
            if processed.as_ref().is_err_and(|error| error.kind() == io::ErrorKind::TimedOut) {
                processing_fence_waiter.prepare(fence_id);
                match write_batch(
                    &mut output,
                    &stdout_lock,
                    &slot,
                    &control,
                    update.revision,
                    &processing_fence(fence_id),
                ) {
                    BatchWriteOutcome::Complete => {
                        processed = processing_fence_waiter.wait(fence_id, &control.cancelled);
                    }
                    BatchWriteOutcome::Superseded => {
                        processing_fence_waiter.cancel(fence_id);
                        host_reset_required = true;
                        continue;
                    }
                    BatchWriteOutcome::Stopped => {
                        processing_fence_waiter.cancel(fence_id);
                        break 'writer;
                    }
                }
            }

            match processed {
                Ok(()) => {
                    consecutive_fence_timeouts = 0;
                    graphics = next_graphics;
                    *lock_recover(&completion) =
                        Some(GraphicsCompletion::Processed(GraphicsProcessing {
                            id: submission.id,
                            session_generation: submission.session_generation,
                            graphics: processed_graphics,
                        }));
                    on_ready();
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                    processing_fence_waiter.cancel(fence_id);
                    break 'writer;
                }
                Err(error) if error.kind() == io::ErrorKind::TimedOut => {
                    processing_fence_waiter.cancel(fence_id);
                    consecutive_fence_timeouts = consecutive_fence_timeouts.saturating_add(1);
                    host_reset_required = true;
                    if consecutive_fence_timeouts >= MAX_CONSECUTIVE_GRAPHICS_FENCE_TIMEOUTS {
                        control.record_failure(false);
                        *lock_recover(&completion) = Some(GraphicsCompletion::Failed);
                        on_ready();
                        break 'writer;
                    }
                    *lock_recover(&completion) = Some(GraphicsCompletion::TimedOut {
                        id: submission.id,
                        session_generation: submission.session_generation,
                    });
                    on_ready();
                }
                Err(_) => {
                    processing_fence_waiter.cancel(fence_id);
                    control.record_failure(false);
                    *lock_recover(&completion) = Some(GraphicsCompletion::Failed);
                    on_ready();
                    break 'writer;
                }
            }
        }
        if control.stop_requested.load(Ordering::Acquire) {
            break;
        }
        if notifications.recv().is_err() {
            break;
        }
    }
    if !control.is_cancelled() && control.failure().is_none() {
        let revision = lock_recover(&slot).revision;
        for batch in graphics.frame_batches(&[]) {
            if !matches!(
                write_batch(&mut output, &stdout_lock, &slot, &control, revision, &batch,),
                BatchWriteOutcome::Complete
            ) {
                break;
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BatchWriteOutcome {
    Complete,
    Superseded,
    Stopped,
}

fn write_batch<O: GraphicsOutput>(
    output: &mut O,
    stdout_lock: &Arc<StdoutLock>,
    slot: &Arc<Mutex<PendingGraphics>>,
    control: &WriterControl,
    revision: u64,
    batch: &[u8],
) -> BatchWriteOutcome {
    let permit = WritePermit { slot, control, revision };
    let mut offset = 0;
    let mut multipart_active = false;
    while offset < batch.len() {
        if control.is_cancelled() {
            return finish_interrupted_batch(
                output,
                stdout_lock,
                control,
                multipart_active,
                false,
                false,
                BatchWriteOutcome::Stopped,
            );
        }
        if permit.superseded() {
            return finish_interrupted_batch(
                output,
                stdout_lock,
                control,
                multipart_active,
                false,
                false,
                BatchWriteOutcome::Superseded,
            );
        }
        let Some(end) = next_graphics_write_end(batch, offset) else {
            return finish_interrupted_batch(
                output,
                stdout_lock,
                control,
                multipart_active,
                false,
                true,
                BatchWriteOutcome::Stopped,
            );
        };
        #[cfg(test)]
        control.report_write_attempt();
        {
            let _guard = stdout_lock.lock();
            if control.is_cancelled() {
                return finish_interrupted_batch(
                    output,
                    stdout_lock,
                    control,
                    multipart_active,
                    false,
                    false,
                    BatchWriteOutcome::Stopped,
                );
            }
            if permit.superseded() {
                return finish_interrupted_batch(
                    output,
                    stdout_lock,
                    control,
                    multipart_active,
                    false,
                    false,
                    BatchWriteOutcome::Superseded,
                );
            }
            let mut emitted = 0;
            let result = output.write_segment(&batch[offset..end], &permit, &mut emitted);
            let emitted_end = offset.saturating_add(emitted).min(end);
            multipart_active = multipart_state_after_complete_commands(
                &batch[offset..emitted_end],
                multipart_active,
            );
            let parser_reset_required =
                emitted != 0 && !batch[offset..emitted_end].ends_with(b"\x1b\\");
            match result {
                Ok(true) if emitted == end - offset => {}
                Ok(true) => {
                    return finish_interrupted_batch(
                        output,
                        stdout_lock,
                        control,
                        multipart_active,
                        parser_reset_required,
                        true,
                        BatchWriteOutcome::Stopped,
                    );
                }
                Ok(false) if permit.superseded() => {
                    return finish_interrupted_batch(
                        output,
                        stdout_lock,
                        control,
                        multipart_active,
                        parser_reset_required,
                        false,
                        BatchWriteOutcome::Superseded,
                    );
                }
                Ok(false) => {
                    return finish_interrupted_batch(
                        output,
                        stdout_lock,
                        control,
                        multipart_active,
                        parser_reset_required,
                        !control.is_cancelled(),
                        BatchWriteOutcome::Stopped,
                    );
                }
                Err(_) => {
                    return finish_interrupted_batch(
                        output,
                        stdout_lock,
                        control,
                        multipart_active,
                        parser_reset_required,
                        true,
                        BatchWriteOutcome::Stopped,
                    );
                }
            }
        }
        offset = end;
        if control.is_cancelled() {
            return finish_interrupted_batch(
                output,
                stdout_lock,
                control,
                multipart_active,
                false,
                false,
                BatchWriteOutcome::Stopped,
            );
        }
        if permit.superseded() {
            return finish_interrupted_batch(
                output,
                stdout_lock,
                control,
                multipart_active,
                false,
                false,
                BatchWriteOutcome::Superseded,
            );
        }
    }
    BatchWriteOutcome::Complete
}

fn finish_interrupted_batch<O: GraphicsOutput>(
    output: &mut O,
    stdout_lock: &Arc<StdoutLock>,
    control: &WriterControl,
    multipart_active: bool,
    parser_reset_required: bool,
    writer_failed: bool,
    outcome: BatchWriteOutcome,
) -> BatchWriteOutcome {
    if !parser_reset_required && !multipart_active {
        if writer_failed && !control.is_cancelled() {
            control.record_failure(false);
            return BatchWriteOutcome::Stopped;
        }
        return outcome;
    }
    let _guard = stdout_lock.lock();
    let mut parser_grounded = true;
    let mut recovery_failed = false;
    if parser_reset_required && output.write_recovery(&[CONTROL_STRING_CANCEL]).is_err() {
        parser_grounded = false;
        recovery_failed = true;
    }
    if parser_grounded
        && multipart_active
        && output.write_recovery(TERMINATE_MULTIPART_GRAPHICS).is_err()
    {
        recovery_failed = true;
        if output.write_recovery(&[CONTROL_STRING_CANCEL]).is_err() {
            parser_grounded = false;
        }
    }
    if writer_failed || recovery_failed {
        if !control.is_cancelled() {
            // Record the fatal state before releasing the shared stdout lock.
            // A waiting Ratatui draw observes it before emitting normal bytes.
            control.record_failure(!parser_grounded);
        }
        return BatchWriteOutcome::Stopped;
    }
    outcome
}

#[cfg(test)]
fn assert_writer_failed(control: &WriterControl, expected_parser_reset_required: bool) {
    assert_eq!(
        control.failure(),
        Some(GraphicsWriterFailure { parser_reset_required: expected_parser_reset_required })
    );
}

fn multipart_state_after_complete_commands(bytes: &[u8], mut active: bool) -> bool {
    let mut offset = 0;
    while let Some(start) =
        bytes[offset..].windows(3).position(|window| window == b"\x1b_G").map(|at| offset + at)
    {
        let header_start = start + 3;
        let Some(end) = bytes[header_start..]
            .windows(2)
            .position(|window| window == b"\x1b\\")
            .map(|at| header_start + at)
        else {
            break;
        };
        if let Some(header_end) = bytes[header_start..end].iter().position(|byte| *byte == b';') {
            for parameter in
                bytes[header_start..header_start + header_end].split(|byte| *byte == b',')
            {
                match parameter {
                    b"m=1" => active = true,
                    b"m=0" => active = false,
                    _ => {}
                }
            }
        }
        offset = end + 2;
    }
    active
}

fn next_graphics_write_end(batch: &[u8], start: usize) -> Option<usize> {
    let mut end = start;
    while end < batch.len() {
        let Some(terminator) = batch[end..]
            .windows(2)
            .position(|bytes| bytes == b"\x1b\\")
            .map(|offset| end + offset + 2)
        else {
            if end > start && !batch[end..].windows(3).any(|bytes| bytes == b"\x1b_G") {
                return Some(batch.len());
            }
            return (end > start).then_some(end);
        };
        if end > start && terminator - start > MAX_LOCKED_GRAPHICS_WRITE_BYTES {
            break;
        }
        end = terminator;
        if end - start >= MAX_LOCKED_GRAPHICS_WRITE_BYTES {
            break;
        }
    }
    (end > start).then_some(end)
}

fn lock_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct DoneOnDrop(Arc<WriterControl>);

impl Drop for DoneOnDrop {
    fn drop(&mut self) {
        self.0.mark_done();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::graphics::{
        GraphicData, GraphicFormat, GraphicImage, GraphicImageKey, GraphicPlacementKey,
        clear_image_transmission_observer, observe_image_transmissions,
    };
    use cmux_tui_core::Rect;
    use ghostty_vt::{Callbacks, Terminal};
    use std::sync::atomic::{AtomicBool, Ordering};

    struct BlockingOutput {
        entered: SyncSender<()>,
        release: Receiver<()>,
        restored: Arc<AtomicBool>,
        writes_after_restore: Arc<Mutex<Vec<bool>>>,
    }

    impl Write for BlockingOutput {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let _ = self.entered.try_send(());
            self.release.recv().unwrap();
            self.writes_after_restore.lock().unwrap().push(self.restored.load(Ordering::Acquire));
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct ObservedOutput {
        bytes: Arc<Mutex<Vec<u8>>>,
        flushed: SyncSender<()>,
    }

    impl Write for ObservedOutput {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.bytes.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            let _ = self.flushed.try_send(());
            Ok(())
        }
    }

    struct SupersedingOutput {
        bytes: Arc<Mutex<Vec<u8>>>,
        entered: Option<SyncSender<()>>,
        release: Option<Receiver<()>>,
        flushed: SyncSender<()>,
    }

    impl GraphicsOutput for SupersedingOutput {
        fn write_segment(
            &mut self,
            bytes: &[u8],
            _permit: &WritePermit<'_>,
            emitted: &mut usize,
        ) -> io::Result<bool> {
            *emitted = 0;
            self.bytes.lock().unwrap().extend_from_slice(bytes);
            *emitted = bytes.len();
            let _ = self.flushed.try_send(());
            if let Some(entered) = self.entered.take() {
                entered.send(()).unwrap();
                self.release.take().unwrap().recv().unwrap();
            }
            Ok(true)
        }

        fn write_recovery(&mut self, bytes: &[u8]) -> io::Result<()> {
            self.bytes.lock().unwrap().extend_from_slice(bytes);
            let _ = self.flushed.try_send(());
            Ok(())
        }
    }

    struct PrefixInterruptOutput {
        bytes: Vec<u8>,
    }

    impl GraphicsOutput for PrefixInterruptOutput {
        fn write_segment(
            &mut self,
            bytes: &[u8],
            _permit: &WritePermit<'_>,
            emitted: &mut usize,
        ) -> io::Result<bool> {
            let end = bytes
                .windows(2)
                .position(|window| window == b"\x1b\\")
                .map(|at| at + 2)
                .expect("graphics segment must contain a complete APC");
            self.bytes.extend_from_slice(&bytes[..end]);
            *emitted = end;
            Ok(false)
        }

        fn write_recovery(&mut self, bytes: &[u8]) -> io::Result<()> {
            self.bytes.extend_from_slice(bytes);
            Ok(())
        }
    }

    struct RecoveringPartialOutput {
        bytes: Vec<u8>,
        recovery_attempts: usize,
    }

    impl GraphicsOutput for RecoveringPartialOutput {
        fn write_segment(
            &mut self,
            bytes: &[u8],
            _permit: &WritePermit<'_>,
            emitted: &mut usize,
        ) -> io::Result<bool> {
            let partial = bytes.len().min(8);
            self.bytes.extend_from_slice(&bytes[..partial]);
            *emitted = partial;
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "terminal stayed blocked after a partial APC",
            ))
        }

        fn write_recovery(&mut self, bytes: &[u8]) -> io::Result<()> {
            self.recovery_attempts += 1;
            self.bytes.extend_from_slice(bytes);
            Ok(())
        }
    }

    struct PermanentRecoveryFailureOutput {
        attempted: SyncSender<()>,
    }

    impl GraphicsOutput for PermanentRecoveryFailureOutput {
        fn write_segment(
            &mut self,
            bytes: &[u8],
            _permit: &WritePermit<'_>,
            emitted: &mut usize,
        ) -> io::Result<bool> {
            *emitted = bytes.len().min(8);
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "terminal stayed blocked after a partial APC",
            ))
        }

        fn write_recovery(&mut self, _bytes: &[u8]) -> io::Result<()> {
            let _ = self.attempted.try_send(());
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "terminal output is gone"))
        }
    }

    fn rgba_placement(image_id: u32, generation: u64, x: u16, rgba: [u8; 4]) -> GraphicPlacement {
        rgba_placement_in_namespace(91, image_id, generation, x, rgba)
    }

    fn rgba_placement_in_namespace(
        namespace: u64,
        image_id: u32,
        generation: u64,
        x: u16,
        rgba: [u8; 4],
    ) -> GraphicPlacement {
        let image_key = GraphicImageKey { namespace, surface: 7, image_id };
        GraphicPlacement {
            key: GraphicPlacementKey { image: image_key, placement_id: 1, ordinal: 0 },
            image: Arc::new(GraphicImage {
                key: image_key,
                generation,
                width: 1,
                height: 1,
                format: GraphicFormat::Rgba,
                data: GraphicData::Bytes(Arc::from(rgba)),
            }),
            rect: Rect { x, y: 0, width: 1, height: 1 },
            pointer_frame_seq: None,
            columns: Some(1),
            rows: Some(1),
            source: None,
            x_offset: 0,
            y_offset: 0,
            z: 0,
        }
    }

    fn wait_for_output(
        flushed: &Receiver<()>,
        bytes: &Arc<Mutex<Vec<u8>>>,
        predicate: impl Fn(&[u8]) -> bool,
    ) {
        loop {
            flushed.recv_timeout(Duration::from_secs(2)).expect("graphics writer flush");
            if predicate(&bytes.lock().unwrap()) {
                return;
            }
        }
    }

    fn key(ch: char, modifiers: KeyModifiers) -> Event {
        Event::Key(KeyEvent::new(KeyCode::Char(ch), modifiers))
    }

    #[test]
    fn large_batches_split_only_between_complete_kitty_commands() {
        let command = |payload: u8| {
            let mut command = b"\x1b_Gq=2,m=1;".to_vec();
            command.extend(std::iter::repeat_n(payload, 4_096));
            command.extend_from_slice(b"\x1b\\");
            command
        };
        let commands = (0..40).map(command).collect::<Vec<_>>();
        let batch = commands.concat();

        let mut offset = 0;
        let mut segments = Vec::new();
        while offset < batch.len() {
            let end = next_graphics_write_end(&batch, offset).expect("complete Kitty segment");
            let segment = &batch[offset..end];
            assert!(segment.ends_with(b"\x1b\\"));
            assert!(
                segment.len() <= MAX_LOCKED_GRAPHICS_WRITE_BYTES,
                "bounded command grouping held stdout for {} bytes",
                segment.len()
            );
            segments.extend_from_slice(segment);
            offset = end;
        }
        assert_eq!(segments, batch);
        assert!(next_graphics_write_end(b"\x1b_Gunterminated", 0).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn shutdown_cancels_a_writer_blocked_by_terminal_backpressure() {
        let mut raw_fds = [-1; 2];
        assert_eq!(unsafe { libc::pipe(raw_fds.as_mut_ptr()) }, 0);
        let read_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[0]) };
        let write_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[1]) };
        let flags = unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_GETFL) };
        assert!(flags >= 0);
        assert_eq!(
            unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
            0
        );
        let fill = [0_u8; 4_096];
        loop {
            let written =
                unsafe { libc::write(write_fd.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
            if written >= 0 {
                continue;
            }
            assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
            break;
        }

        let mut writer = GraphicsWriter::spawn_with_test_graphics_output(
            Arc::new(StdoutLock::new(())),
            InterruptibleStdout { fd: write_fd },
        )
        .unwrap();
        let (attempt_tx, attempt_rx) = sync_channel(1);
        writer.control.observe_write_attempts(attempt_tx);
        writer.submit_test(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            1,
            10,
            5,
            "AAAA".to_string(),
        )]);
        attempt_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let started = Instant::now();
        writer.shutdown(Duration::ZERO);
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "cancelable stdout did not stop within its bounded poll interval"
        );
        drop(read_fd);
    }

    #[cfg(not(unix))]
    #[test]
    fn production_graphics_writer_is_disabled_without_interruptible_output() {
        let (processing_fence, _processing_fence_notifier) = graphics_fence_channel();
        let result = GraphicsWriter::spawn(Arc::new(StdoutLock::new(())), processing_fence, || {});
        let Err(error) = result else {
            panic!("non-Unix graphics output must be disabled");
        };
        assert_eq!(error.kind(), io::ErrorKind::Unsupported);
    }

    #[cfg(unix)]
    #[test]
    fn segment_backpressure_has_a_total_deadline_without_external_supersession() {
        let mut raw_fds = [-1; 2];
        assert_eq!(unsafe { libc::pipe(raw_fds.as_mut_ptr()) }, 0);
        let _read_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[0]) };
        let write_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[1]) };
        let flags = unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_GETFL) };
        assert!(flags >= 0);
        assert_eq!(
            unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
            0
        );
        let fill = [0_u8; MAX_LOCKED_GRAPHICS_WRITE_BYTES];
        let mut fill_len = fill.len();
        loop {
            let written =
                unsafe { libc::write(write_fd.as_raw_fd(), fill.as_ptr().cast(), fill_len) };
            if written > 0 {
                continue;
            }
            assert_ne!(written, 0, "pipe accepted a zero-length fill write");
            assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
            if fill_len == 1 {
                break;
            }
            fill_len = (fill_len / 2).max(1);
        }

        let control = Arc::new(WriterControl::default());
        let slot =
            Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
        let (attempt_tx, attempt_rx) = sync_channel(1);
        control.observe_write_attempts(attempt_tx);
        let (done_tx, done_rx) = sync_channel(1);
        let worker_control = control.clone();
        let mut segment = b"\x1b_Gq=2;".to_vec();
        segment.resize(MAX_LOCKED_GRAPHICS_WRITE_BYTES - 2, b'A');
        segment.extend_from_slice(b"\x1b\\");
        let worker = std::thread::spawn(move || {
            let mut output = InterruptibleStdout { fd: write_fd };
            let mut emitted = 0;
            let result = output.write_segment(
                &segment,
                &WritePermit { slot: &slot, control: &worker_control, revision: 1 },
                &mut emitted,
            );
            let _ = done_tx.send(result);
        });

        attempt_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("writer never reached terminal backpressure");
        let result = match done_rx.recv_timeout(Duration::from_secs(1)) {
            Ok(result) => result,
            Err(_) => {
                control.cancelled.store(true, Ordering::Release);
                worker.join().unwrap();
                panic!("graphics segment ignored its total output deadline");
            }
        };
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::TimedOut);
        worker.join().unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn cancellation_terminates_a_partially_written_apc_before_returning() {
        let mut raw_fds = [-1; 2];
        assert_eq!(unsafe { libc::pipe(raw_fds.as_mut_ptr()) }, 0);
        let read_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[0]) };
        let write_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[1]) };
        let flags = unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_GETFL) };
        assert!(flags >= 0);
        assert_eq!(
            unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
            0
        );

        let mut command = b"\x1b_Gq=2;".to_vec();
        command.resize(256 * 1024, b'A');
        command.extend_from_slice(b"\x1b\\");
        let control = Arc::new(WriterControl::default());
        let slot =
            Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
        let worker_control = control.clone();
        let worker_slot = slot;
        let worker = std::thread::spawn(move || {
            let mut output = InterruptibleStdout { fd: write_fd };
            let mut emitted = 0;
            output.write_segment(
                &command,
                &WritePermit { slot: &worker_slot, control: &worker_control, revision: 1 },
                &mut emitted,
            )
        });

        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let mut available: libc::c_int = 0;
            assert_eq!(
                unsafe { libc::ioctl(read_fd.as_raw_fd(), libc::FIONREAD, &mut available) },
                0
            );
            if available > 0 {
                break;
            }
            assert!(Instant::now() < deadline, "writer never emitted its APC prefix");
            std::thread::yield_now();
        }
        control.cancelled.store(true, Ordering::Release);

        let mut emitted = Vec::new();
        let mut buffer = [0_u8; 8 * 1024];
        while !emitted.contains(&CONTROL_STRING_CANCEL) {
            let count = unsafe {
                libc::read(read_fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len())
            };
            assert!(count > 0, "pipe closed before the APC cancellation byte");
            emitted.extend_from_slice(&buffer[..count as usize]);
        }
        assert!(!worker.join().unwrap().unwrap());
        assert!(emitted.starts_with(b"\x1b_Gq=2;"));
        assert!(
            emitted.iter().position(|byte| *byte == CONTROL_STRING_CANCEL).unwrap() < 256 * 1024,
            "writer completed the large payload instead of canceling its partial APC"
        );
    }

    #[cfg(unix)]
    #[test]
    fn partial_apc_abort_is_bounded_when_output_never_becomes_writable() {
        let mut raw_fds = [-1; 2];
        assert_eq!(unsafe { libc::pipe(raw_fds.as_mut_ptr()) }, 0);
        let read_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[0]) };
        let write_fd = unsafe { OwnedFd::from_raw_fd(raw_fds[1]) };
        let flags = unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_GETFL) };
        assert!(flags >= 0);
        assert_eq!(
            unsafe { libc::fcntl(write_fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
            0
        );

        let fill = [0_u8; 4_096];
        loop {
            let written =
                unsafe { libc::write(write_fd.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
            if written >= 0 {
                continue;
            }
            assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
            break;
        }
        let mut full_bytes: libc::c_int = 0;
        assert_eq!(unsafe { libc::ioctl(read_fd.as_raw_fd(), libc::FIONREAD, &mut full_bytes) }, 0);
        let mut drained = [0_u8; 4_096];
        let drain_bytes = usize::try_from(full_bytes).unwrap().min(drained.len());
        assert_eq!(
            unsafe { libc::read(read_fd.as_raw_fd(), drained.as_mut_ptr().cast(), drain_bytes) },
            drain_bytes as isize
        );

        let mut command = b"\x1b_Gq=2;".to_vec();
        command.resize(256 * 1024, b'A');
        command.extend_from_slice(b"\x1b\\");
        let control = Arc::new(WriterControl::default());
        let slot =
            Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
        let (blocked_tx, blocked_rx) = sync_channel(1);
        control.observe_write_attempts(blocked_tx);
        let worker_control = control.clone();
        let worker_slot = slot;
        let worker = std::thread::spawn(move || {
            let mut output = InterruptibleStdout { fd: write_fd };
            let mut emitted = 0;
            output.write_segment(
                &command,
                &WritePermit { slot: &worker_slot, control: &worker_control, revision: 1 },
                &mut emitted,
            )
        });

        blocked_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("writer never reached terminal backpressure");
        let started = Instant::now();
        control.cancelled.store(true, Ordering::Release);
        let error = worker.join().unwrap().unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "partial APC cancellation remained blocked after its deadline"
        );
    }

    #[cfg(unix)]
    fn stopped_pty_output_with_sentinel(sentinel: &[u8]) -> (OwnedFd, InterruptibleStdout) {
        let mut master = -1;
        let mut slave = -1;
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            },
            0
        );
        let master = unsafe { OwnedFd::from_raw_fd(master) };
        let slave = unsafe { OwnedFd::from_raw_fd(slave) };
        // Linux can reject even the first nonblocking write after TCOOFF. Queue
        // unrelated output before suspending the PTY, then fill the stopped queue.
        assert_eq!(
            unsafe { libc::write(slave.as_raw_fd(), sentinel.as_ptr().cast(), sentinel.len()) },
            sentinel.len() as isize
        );
        assert_eq!(unsafe { libc::tcflow(slave.as_raw_fd(), libc::TCOOFF) }, 0);
        let flags = unsafe { libc::fcntl(slave.as_raw_fd(), libc::F_GETFL) };
        assert!(flags >= 0);
        assert_eq!(
            unsafe { libc::fcntl(slave.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
            0
        );
        let fill = [b'x'; 4_096];
        loop {
            let written =
                unsafe { libc::write(slave.as_raw_fd(), fill.as_ptr().cast(), fill.len()) };
            if written >= 0 {
                continue;
            }
            assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EAGAIN));
            break;
        }
        (master, InterruptibleStdout { fd: slave })
    }

    #[cfg(unix)]
    fn resume_pty_and_read_prefix(master: &OwnedFd, output: &InterruptibleStdout) -> Vec<u8> {
        assert_eq!(unsafe { libc::tcflow(output.fd.as_raw_fd(), libc::TCOON) }, 0);
        let mut bytes = vec![0_u8; 8 * 1024];
        let count =
            unsafe { libc::read(master.as_raw_fd(), bytes.as_mut_ptr().cast(), bytes.len()) };
        assert!(count > 0, "resumed pseudo-terminal produced no queued output");
        bytes.truncate(count as usize);
        bytes
    }

    #[cfg(unix)]
    #[test]
    fn partial_apc_timeout_does_not_flush_unrelated_terminal_output() {
        let sentinel = b"ratatui-frame-before-graphics";
        let (master, mut output) = stopped_pty_output_with_sentinel(sentinel);

        let result = output.abort_partial_control_string();
        let queued = resume_pty_and_read_prefix(&master, &output);

        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::TimedOut);
        assert!(
            queued.windows(sentinel.len()).any(|window| window == sentinel),
            "graphics cancellation discarded output queued by another terminal writer"
        );
    }

    #[cfg(unix)]
    #[test]
    fn recovery_timeout_does_not_flush_unrelated_terminal_output() {
        let sentinel = b"ratatui-frame-before-recovery";
        let (master, mut output) = stopped_pty_output_with_sentinel(sentinel);

        let result = output.write_recovery(DELETE_ALL_GRAPHICS);
        let queued = resume_pty_and_read_prefix(&master, &output);

        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::TimedOut);
        assert!(
            queued.windows(sentinel.len()).any(|window| window == sentinel),
            "graphics recovery discarded output queued by another terminal writer"
        );
    }

    #[test]
    fn kitty_graphics_response_completes_matching_processing_fence() {
        let (waiter, notifier) = graphics_fence_channel();
        let mut filter = GraphicsResponseFilter::new(notifier);
        let id = processing_fence_id(11);
        waiter.prepare(id);
        let response = format!("Gi={id};OK");
        let wire_events = std::iter::once(key('_', KeyModifiers::ALT))
            .chain(response.chars().map(|ch| {
                key(ch, if ch.is_uppercase() { KeyModifiers::SHIFT } else { KeyModifiers::NONE })
            }))
            .chain(std::iter::once(key('\\', KeyModifiers::ALT)));

        assert!(wire_events.flat_map(|event| filter.filter(event)).next().is_none());
        waiter.wait_for(id).unwrap();
    }

    #[test]
    fn non_graphics_apc_input_is_replayed_losslessly() {
        let (_waiter, notifier) = graphics_fence_channel();
        let mut filter = GraphicsResponseFilter::new(notifier);
        let events = vec![
            key('_', KeyModifiers::ALT),
            key('x', KeyModifiers::NONE),
            key('\\', KeyModifiers::ALT),
        ];

        let replayed =
            events.clone().into_iter().flat_map(|event| filter.filter(event)).collect::<Vec<_>>();

        assert_eq!(replayed, events);
    }

    #[test]
    fn processing_completion_waits_for_host_fence_after_stdout_flush() {
        let lock = Arc::new(StdoutLock::new(()));
        let held = lock.lock();
        let (processed_tx, processed_rx) = std::sync::mpsc::channel();
        let (fence_entered_tx, fence_entered_rx) = std::sync::mpsc::channel();
        let (fence_release_tx, fence_release_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock.clone(),
            Vec::new(),
            move || {
                fence_entered_tx.send(()).unwrap();
                fence_release_rx.recv().unwrap();
                Ok(())
            },
            move || {
                processed_tx.send(()).unwrap();
            },
        )
        .unwrap();
        let mut placement = GraphicPlacement::browser(
            1,
            11,
            Rect { x: 1, y: 2, width: 3, height: 4 },
            13,
            3,
            4,
            "AAAA".to_string(),
        );
        placement.pointer_frame_seq = Some(8);

        assert!(writer.submit(7, 1, vec![placement]));
        assert!(
            processed_rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "submission must not complete while output is blocked"
        );

        drop(held);
        fence_entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(
            lock.try_lock().is_some(),
            "waiting for a graphics response must not monopolize terminal output"
        );
        assert_eq!(
            writer.take_completion(),
            None,
            "stdout flush alone must not complete the ordered submission"
        );
        assert!(
            processed_rx.recv_timeout(Duration::from_millis(50)).is_err(),
            "the app must wait until the host acknowledges command processing"
        );

        fence_release_tx.send(()).unwrap();
        processed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(
            writer.take_completion(),
            Some(GraphicsCompletion::Processed(GraphicsProcessing {
                id: 7,
                session_generation: 1,
                graphics: vec![ProcessedGraphic {
                    surface: 11,
                    rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                    seq: 13,
                    pointer_frame_seq: Some(8),
                }],
            }))
        );
        writer.shutdown(Duration::from_secs(1));
    }

    #[test]
    fn snapshot_slot_is_latest_wins_and_shutdown_is_clean() {
        let (tx, rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(PendingGraphics::default()));
        submit_snapshot(
            &slot,
            &tx,
            GraphicsSubmission {
                id: 1,
                session_generation: 1,
                scene: vec![Arc::from(vec![GraphicPlacement::browser(
                    0,
                    1,
                    Rect { x: 0, y: 0, width: 10, height: 5 },
                    1,
                    10,
                    5,
                    "AAAA".to_string(),
                )])],
            },
        );
        submit_snapshot(
            &slot,
            &tx,
            GraphicsSubmission {
                id: 2,
                session_generation: 1,
                scene: vec![Arc::from(vec![GraphicPlacement::browser(
                    0,
                    1,
                    Rect { x: 1, y: 1, width: 11, height: 6 },
                    2,
                    11,
                    6,
                    "BBBB".to_string(),
                )])],
            },
        );

        let latest = take_pending_update(&slot, 0)
            .and_then(|update| update.submission)
            .map(|submission| submission.scene)
            .expect("latest snapshot");
        assert_eq!(latest.len(), 1);
        assert_eq!(latest[0][0].image.generation, 2);
        assert_eq!(latest[0][0].rect.x, 1);
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(rx.try_recv().is_err());

        let lock = Arc::new(StdoutLock::new(()));
        let mut writer = GraphicsWriter::spawn_with_output(lock, io::sink()).unwrap();
        writer.shutdown(Duration::from_secs(1));
        assert!(writer.handle.as_ref().is_none_or(|handle| handle.is_finished()));
    }

    #[test]
    fn host_scene_invalidation_survives_latest_wins_coalescing() {
        let (tx, rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(PendingGraphics::default()));
        let writer = GraphicsWriter {
            slot: slot.clone(),
            completion: Arc::new(Mutex::new(None)),
            notify: Some(tx),
            control: Arc::new(WriterControl::default()),
            handle: None,
        };

        writer.invalidate_host_scene();
        writer.submit_test(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            1,
            10,
            5,
            "AAAA".to_string(),
        )]);
        writer.submit_test(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 1, y: 1, width: 11, height: 6 },
            2,
            11,
            6,
            "BBBB".to_string(),
        )]);

        let update = take_pending_update(&slot, 0).expect("pending scene update");
        assert_ne!(update.host_scene_epoch, 0);
        let latest = update.submission.expect("latest submission").scene;
        assert_eq!(latest.len(), 1);
        assert_eq!(latest[0][0].image.generation, 2);
        assert_eq!(latest[0][0].rect.x, 1);
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn host_scene_invalidation_discards_a_pre_clear_write_waiting_on_stdout() {
        let stdout_lock = Arc::new(StdoutLock::new(()));
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (flushed_tx, flushed_rx) = sync_channel(8);
        let output = ObservedOutput { bytes: bytes.clone(), flushed: flushed_tx };
        let (ready_tx, ready_rx) = sync_channel(1);
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            stdout_lock.clone(),
            output,
            || Ok(()),
            move || {
                let _ = ready_tx.try_send(());
            },
        )
        .unwrap();
        let first = rgba_placement(41, 1, 0, [255, 0, 0, 255]);
        let second = rgba_placement(42, 1, 1, [0, 255, 0, 255]);

        writer.submit_test(vec![first.clone(), second]);
        wait_for_output(&flushed_rx, &bytes, |bytes| {
            String::from_utf8_lossy(bytes).matches("a=p").count() == 2
        });
        ready_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("initial graphics batch must finish before blocking stdout");
        bytes.lock().unwrap().clear();

        let draw_guard = stdout_lock.lock();
        let (attempt_tx, attempt_rx) = sync_channel(1);
        writer.control.observe_write_attempts(attempt_tx);
        let changed_second = rgba_placement(42, 2, 1, [0, 0, 255, 255]);
        writer.submit_test(vec![first, changed_second.clone()]);
        attempt_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("pre-clear graphics batch must be waiting on stdout");

        writer.invalidate_host_scene();
        writer.submit_test(vec![changed_second]);
        drop(draw_guard);

        wait_for_output(&flushed_rx, &bytes, |bytes| {
            String::from_utf8_lossy(bytes).matches("a=p").count() == 1
        });
        let raced_output = bytes.lock().unwrap().clone();
        let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
        host.resize(8, 4, 1, 1).unwrap();
        host.vt_write(&raced_output);
        let snapshot = host.kitty_graphics_snapshot().unwrap();
        assert_eq!(
            snapshot.images.len(),
            1,
            "stale pre-clear transmission left a duplicate host image: {snapshot:?}"
        );
        assert_eq!(
            snapshot.placements.len(),
            1,
            "stale pre-clear placement survived host-scene invalidation: {snapshot:?}"
        );

        writer.shutdown(Duration::from_secs(1));
    }

    #[test]
    fn newer_snapshot_supersedes_an_inflight_scene_and_resets_the_host() {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (entered_tx, entered_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let (flushed_tx, flushed_rx) = sync_channel(8);
        let output = SupersedingOutput {
            bytes: bytes.clone(),
            entered: Some(entered_tx),
            release: Some(release_rx),
            flushed: flushed_tx,
        };
        let mut writer =
            GraphicsWriter::spawn_with_test_graphics_output(Arc::new(StdoutLock::new(())), output)
                .unwrap();
        let old = rgba_placement(41, 1, 0, [255, 0, 0, 255]);
        let latest = rgba_placement(41, 2, 0, [0, 0, 255, 255]);

        writer.submit_test(vec![old]);
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        writer.submit_test(vec![latest]);
        release_tx.send(()).unwrap();

        wait_for_output(&flushed_rx, &bytes, |bytes| {
            bytes.windows(DELETE_ALL_GRAPHICS.len()).any(|window| window == DELETE_ALL_GRAPHICS)
                && String::from_utf8_lossy(bytes).contains("AAD//w==")
        });

        let emitted = bytes.lock().unwrap().clone();
        let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
        host.resize(8, 4, 1, 1).unwrap();
        host.vt_write(&emitted);
        let snapshot = host.kitty_graphics_snapshot().unwrap();
        assert_eq!(snapshot.images.len(), 1);
        assert_eq!(snapshot.images[0].data.as_ref(), &[0, 0, 255, 255]);
        assert_eq!(snapshot.placements.len(), 1);
        writer.shutdown(Duration::from_secs(1));
    }

    #[test]
    fn superseded_scene_does_not_encode_images_beyond_the_active_batch() {
        let namespace = u64::MAX - 17;
        let (observed_tx, observed_rx) = std::sync::mpsc::channel();
        observe_image_transmissions(observed_tx);
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (entered_tx, entered_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let (flushed_tx, _flushed_rx) = sync_channel(8);
        let output = SupersedingOutput {
            bytes,
            entered: Some(entered_tx),
            release: Some(release_rx),
            flushed: flushed_tx,
        };
        let mut writer =
            GraphicsWriter::spawn_with_test_graphics_output(Arc::new(StdoutLock::new(())), output)
                .unwrap();
        let old = (0..3)
            .map(|index| {
                rgba_placement_in_namespace(
                    namespace,
                    41 + index,
                    1,
                    u16::try_from(index).unwrap(),
                    [u8::try_from(index).unwrap(), 0, 0, 255],
                )
            })
            .collect();

        writer.submit_test(old);
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let encoded_before_supersession =
            observed_rx.try_iter().filter(|key| key.namespace == namespace).count();
        writer.submit_test(Vec::new());
        release_tx.send(()).unwrap();
        writer.shutdown(Duration::from_secs(1));
        clear_image_transmission_observer();

        assert_eq!(
            encoded_before_supersession, 1,
            "the writer encoded later images before checking for a newer scene"
        );
    }

    #[test]
    fn superseding_a_multipart_upload_does_not_poison_the_next_image() {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (entered_tx, entered_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let (flushed_tx, flushed_rx) = sync_channel(8);
        let output = SupersedingOutput {
            bytes: bytes.clone(),
            entered: Some(entered_tx),
            release: Some(release_rx),
            flushed: flushed_tx,
        };
        let mut writer =
            GraphicsWriter::spawn_with_test_graphics_output(Arc::new(StdoutLock::new(())), output)
                .unwrap();
        let old = GraphicPlacement::browser(
            0,
            7,
            Rect { x: 0, y: 0, width: 1, height: 1 },
            1,
            1,
            1,
            "A".repeat(MAX_LOCKED_GRAPHICS_WRITE_BYTES * 2),
        );
        let latest = rgba_placement(41, 1, 0, [0, 0, 255, 255]);

        writer.submit_test(vec![old]);
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        writer.submit_test(vec![latest]);
        release_tx.send(()).unwrap();

        wait_for_output(&flushed_rx, &bytes, |bytes| {
            bytes.windows(DELETE_ALL_GRAPHICS.len()).any(|window| window == DELETE_ALL_GRAPHICS)
                && String::from_utf8_lossy(bytes).contains("AAD//w==")
        });
        let emitted = bytes.lock().unwrap().clone();
        let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
        host.resize(8, 4, 1, 1).unwrap();
        host.vt_write(&emitted);
        let snapshot = host.kitty_graphics_snapshot().unwrap();
        assert_eq!(snapshot.images.len(), 1, "{snapshot:?}");
        assert_eq!(snapshot.images[0].data.as_ref(), &[0, 0, 255, 255]);
        assert_eq!(snapshot.placements.len(), 1);
        writer.shutdown(Duration::from_secs(1));
    }

    #[test]
    fn cancellation_terminates_a_completed_multipart_chunk() {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (entered_tx, entered_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let (flushed_tx, _flushed_rx) = sync_channel(8);
        let output = SupersedingOutput {
            bytes: bytes.clone(),
            entered: Some(entered_tx),
            release: Some(release_rx),
            flushed: flushed_tx,
        };
        let mut writer =
            GraphicsWriter::spawn_with_test_graphics_output(Arc::new(StdoutLock::new(())), output)
                .unwrap();
        let shutdown = writer.shutdown_control();
        writer.submit_test(vec![GraphicPlacement::browser(
            0,
            7,
            Rect { x: 0, y: 0, width: 1, height: 1 },
            1,
            1,
            1,
            "A".repeat(MAX_LOCKED_GRAPHICS_WRITE_BYTES * 2),
        )]);
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let cleanup = std::thread::spawn(move || writer.shutdown(Duration::ZERO));
        shutdown.wait_until_cancelled();
        release_tx.send(()).unwrap();
        cleanup.join().unwrap();

        let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
        host.resize(8, 4, 1, 1).unwrap();
        host.vt_write(&bytes.lock().unwrap());
        let mut next = GraphicsState::default();
        let latest = rgba_placement(41, 1, 0, [0, 0, 255, 255]);
        for batch in next.frame_batches(&[latest]) {
            host.vt_write(&batch);
        }
        let snapshot = host.kitty_graphics_snapshot().unwrap();
        assert_eq!(snapshot.images.len(), 1, "{snapshot:?}");
        assert_eq!(snapshot.images[0].data.as_ref(), &[0, 0, 255, 255]);
        assert_eq!(snapshot.placements.len(), 1);
    }

    #[test]
    fn partial_segment_progress_recovers_completed_multipart_chunks() {
        let old = GraphicPlacement::browser(
            0,
            7,
            Rect { x: 0, y: 0, width: 1, height: 1 },
            1,
            1,
            1,
            "A".repeat(4_096 * 2),
        );
        let mut graphics = GraphicsState::default();
        let batch = graphics.frame_batches(&[old]).remove(0);
        let slot =
            Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
        let control = WriterControl::default();
        let stdout_lock = Arc::new(StdoutLock::new(()));
        let mut output = PrefixInterruptOutput { bytes: Vec::new() };

        assert_eq!(
            write_batch(&mut output, &stdout_lock, &slot, &control, 1, &batch),
            BatchWriteOutcome::Stopped
        );

        let mut host = Terminal::new(8, 4, 0, Callbacks::default()).unwrap();
        host.resize(8, 4, 1, 1).unwrap();
        host.vt_write(&output.bytes);
        let mut next = GraphicsState::default();
        for batch in next.frame_batches(&[rgba_placement(41, 1, 0, [0, 0, 255, 255])]) {
            host.vt_write(&batch);
        }
        let snapshot = host.kitty_graphics_snapshot().unwrap();
        assert_eq!(snapshot.images.len(), 1, "{snapshot:?}");
        assert_eq!(snapshot.images[0].data.as_ref(), &[0, 0, 255, 255]);
        assert_eq!(snapshot.placements.len(), 1);
    }

    #[test]
    fn failed_partial_apc_recovery_precedes_later_terminal_output() {
        let slot =
            Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
        let control = WriterControl::default();
        let stdout_lock = Arc::new(StdoutLock::new(()));
        let mut output = RecoveringPartialOutput { bytes: Vec::new(), recovery_attempts: 0 };
        let command = b"\x1b_Gq=2;payload\x1b\\";

        assert_eq!(
            write_batch(&mut output, &stdout_lock, &slot, &control, 1, command),
            BatchWriteOutcome::Stopped
        );
        assert_writer_failed(&control, false);
        output.bytes.extend_from_slice(b"visible-after-recovery");

        let mut host = Terminal::new(80, 4, 0, Callbacks::default()).unwrap();
        host.resize(80, 4, 1, 1).unwrap();
        host.vt_write(&output.bytes);
        assert!(
            host.viewport_text().unwrap().contains("visible-after-recovery"),
            "normal terminal output was consumed by an unterminated Kitty APC"
        );
        assert_eq!(output.recovery_attempts, 1);
    }

    #[test]
    fn permanent_parser_recovery_failure_returns_without_retrying_forever() {
        let slot =
            Arc::new(Mutex::new(PendingGraphics { revision: 1, ..PendingGraphics::default() }));
        let control = Arc::new(WriterControl::default());
        let stdout_lock = Arc::new(StdoutLock::new(()));
        let (attempted_tx, attempted_rx) = sync_channel(1);
        let (done_tx, done_rx) = sync_channel(1);
        let worker_control = control.clone();
        let worker = std::thread::spawn(move || {
            let mut output = PermanentRecoveryFailureOutput { attempted: attempted_tx };
            let outcome = write_batch(
                &mut output,
                &stdout_lock,
                &slot,
                &worker_control,
                1,
                b"\x1b_Gq=2;payload\x1b\\",
            );
            let _ = done_tx.send(outcome);
        });

        attempted_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("writer never attempted parser recovery");
        let outcome = match done_rx.recv_timeout(Duration::from_millis(250)) {
            Ok(outcome) => outcome,
            Err(_) => {
                control.cancelled.store(true, Ordering::Release);
                worker.join().unwrap();
                panic!("permanent parser recovery failure retried forever");
            }
        };
        assert_eq!(outcome, BatchWriteOutcome::Stopped);
        assert_writer_failed(&control, true);
        worker.join().unwrap();
    }

    #[test]
    fn shutdown_quiesces_a_blocked_writer_before_terminal_restore() {
        let (entered_tx, entered_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let restored = Arc::new(AtomicBool::new(false));
        let writes_after_restore = Arc::new(Mutex::new(Vec::new()));
        let output = BlockingOutput {
            entered: entered_tx,
            release: release_rx,
            restored: restored.clone(),
            writes_after_restore: writes_after_restore.clone(),
        };
        let mut writer =
            GraphicsWriter::spawn_with_output(Arc::new(StdoutLock::new(())), output).unwrap();
        let shutdown = writer.shutdown_control();
        writer.submit_test(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            1,
            10,
            5,
            "AAAA".to_string(),
        )]);
        entered_rx.recv().unwrap();

        let (shutdown_done_tx, shutdown_done_rx) = sync_channel(1);
        let restored_for_shutdown = restored.clone();
        std::thread::spawn(move || {
            writer.shutdown(Duration::ZERO);
            restored_for_shutdown.store(true, Ordering::Release);
            shutdown_done_tx.send(()).unwrap();
        });

        shutdown.wait_until_cancelled();
        release_tx.send(()).unwrap();
        shutdown_done_rx.recv().unwrap();

        assert!(restored.load(Ordering::Acquire));
        assert!(
            writes_after_restore.lock().unwrap().iter().all(|after_restore| !after_restore),
            "graphics bytes were written after terminal restoration"
        );
    }

    #[test]
    fn panic_shutdown_control_quiesces_before_terminal_restore() {
        let (entered_tx, entered_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let restored = Arc::new(AtomicBool::new(false));
        let writes_after_restore = Arc::new(Mutex::new(Vec::new()));
        let output = BlockingOutput {
            entered: entered_tx,
            release: release_rx,
            restored: restored.clone(),
            writes_after_restore: writes_after_restore.clone(),
        };
        let writer =
            GraphicsWriter::spawn_with_output(Arc::new(StdoutLock::new(())), output).unwrap();
        let shutdown = writer.shutdown_control();
        writer.submit_test(vec![GraphicPlacement::browser(
            0,
            1,
            Rect { x: 0, y: 0, width: 10, height: 5 },
            1,
            10,
            5,
            "AAAA".to_string(),
        )]);
        entered_rx.recv().unwrap();

        let (panic_hook_done_tx, panic_hook_done_rx) = sync_channel(1);
        let panic_shutdown = shutdown.clone();
        let restored_for_hook = restored.clone();
        std::thread::spawn(move || {
            panic_shutdown.cancel_and_wait();
            restored_for_hook.store(true, Ordering::Release);
            panic_hook_done_tx.send(()).unwrap();
        });

        shutdown.wait_until_cancelled();
        release_tx.send(()).unwrap();
        panic_hook_done_rx.recv().unwrap();

        assert!(restored.load(Ordering::Acquire));
        assert!(
            writes_after_restore.lock().unwrap().iter().all(|after_restore| !after_restore),
            "panic restoration raced a graphics write"
        );
    }

    #[test]
    fn panic_hook_cancellation_does_not_join_writer_waiting_on_owned_stdout() {
        const CHILD_ENV: &str = "CMUX_TEST_PANIC_GRAPHICS_OWNER";
        if std::env::var_os(CHILD_ENV).is_some() {
            let stdout_lock = Arc::new(StdoutLock::new(()));
            let writer = GraphicsWriter::spawn_with_output(stdout_lock.clone(), io::sink())
                .expect("spawn graphics writer");
            let shutdown = writer.shutdown_control();
            let (attempt_tx, attempt_rx) = sync_channel(1);
            writer.control.observe_write_attempts(attempt_tx);
            let guard = stdout_lock.lock();
            writer.submit_test(vec![GraphicPlacement::browser(
                0,
                1,
                Rect { x: 0, y: 0, width: 10, height: 5 },
                1,
                10,
                5,
                "AAAA".to_string(),
            )]);
            attempt_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("graphics writer never waited on the owned stdout lock");

            shutdown.cancel_for_panic_hook();
            drop(guard);
            return;
        }

        let current_exe = std::env::current_exe().expect("resolve current test executable");
        let mut child = std::process::Command::new(current_exe)
            .arg("panic_hook_cancellation_does_not_join_writer_waiting_on_owned_stdout")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .spawn()
            .expect("spawn isolated panic-hook regression");
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(status) = child.try_wait().expect("poll panic-hook regression") {
                assert!(status.success(), "isolated panic-hook regression failed: {status}");
                break;
            }
            if Instant::now() >= deadline {
                child.kill().expect("kill deadlocked panic-hook regression");
                let _ = child.wait();
                panic!("panic hook joined a graphics writer waiting on its stdout lock");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
