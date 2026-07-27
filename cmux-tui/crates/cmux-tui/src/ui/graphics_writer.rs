use std::collections::{BTreeSet, VecDeque};
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
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
    pending_recovery: Mutex<PendingStreamRecovery>,
}

#[derive(Default)]
struct PendingStreamRecovery {
    required: bool,
    possibly_visible: BTreeSet<SurfaceId>,
}

impl StdoutLock {
    pub fn new(_: ()) -> Self {
        Self {
            mutex: ReentrantMutex::new(()),
            pending_recovery: Mutex::new(PendingStreamRecovery::default()),
        }
    }

    pub fn lock(&self) -> ReentrantMutexGuard<'_, ()> {
        self.mutex.lock()
    }

    pub fn try_lock(&self) -> Option<ReentrantMutexGuard<'_, ()>> {
        self.mutex.try_lock()
    }

    fn pending_stream_recovery(&self) -> Option<BTreeSet<SurfaceId>> {
        let pending = self.pending_recovery.lock().unwrap();
        pending.required.then(|| pending.possibly_visible.clone())
    }

    fn mark_stream_recovery(&self, possibly_visible: &BTreeSet<SurfaceId>) {
        let mut pending = self.pending_recovery.lock().unwrap();
        pending.required = true;
        pending.possibly_visible.extend(possibly_visible);
    }

    fn clear_stream_recovery(&self) {
        let mut pending = self.pending_recovery.lock().unwrap();
        pending.required = false;
        pending.possibly_visible.clear();
    }

    pub(crate) fn recover_stream_locked(&self) -> std::io::Result<()> {
        let Some(possibly_visible) = self.pending_stream_recovery() else {
            return Ok(());
        };
        let mode = GraphicsOutputMode::stdout();
        let mut output = std::io::stdout();
        let mut nonblocking = NonblockingOutputGuard::begin(mode)?;
        let result = recover_partial_graphics_output(&mut output, mode, &possibly_visible);
        let restored = nonblocking.restore();
        if result.is_ok() {
            self.clear_stream_recovery();
        }
        result.and(restored)
    }
}

const PROCESSING_FENCE_TIMEOUT: Duration = Duration::from_secs(1);
const PROCESSING_FENCE_SHUTDOWN_POLL: Duration = Duration::from_millis(25);
const LATE_FENCE_RESPONSE_GRACE: Duration = Duration::from_secs(4);
const INCOMPLETE_GRAPHICS_RESPONSE_GRACE: Duration = Duration::from_millis(200);
const MAX_RETIRED_FENCES: usize = 4;
const MAX_GRAPHICS_RESPONSE_EVENTS: usize = 128;
const MAX_CONSECUTIVE_GRAPHICS_FENCE_TIMEOUTS: u8 = 2;
const GRAPHICS_OUTPUT_TIMEOUT: Duration = Duration::from_secs(1);
const GRAPHICS_OUTPUT_RECOVERY_TIMEOUT: Duration = Duration::from_millis(250);
const GRAPHICS_OUTPUT_POLL: Duration = Duration::from_millis(25);
const KITTY_STRING_TERMINATOR: &[u8] = b"\x1b\\";

#[derive(Clone, Copy)]
enum GraphicsOutputMode {
    #[cfg_attr(all(unix, not(test)), allow(dead_code))]
    Cooperative,
    #[cfg(unix)]
    NonblockingFd(std::os::fd::RawFd),
}

impl GraphicsOutputMode {
    fn stdout() -> Self {
        #[cfg(unix)]
        {
            Self::NonblockingFd(libc::STDOUT_FILENO)
        }
        #[cfg(not(unix))]
        {
            Self::Cooperative
        }
    }
}

struct NonblockingOutputGuard {
    #[cfg(unix)]
    restore: Option<(std::os::fd::RawFd, libc::c_int)>,
}

impl NonblockingOutputGuard {
    fn begin(mode: GraphicsOutputMode) -> std::io::Result<Self> {
        #[cfg(unix)]
        if let GraphicsOutputMode::NonblockingFd(fd) = mode {
            // SAFETY: `fd` is the live stdout descriptor supplied by the
            // process, and F_GETFL does not mutate memory.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if flags & libc::O_NONBLOCK == 0 {
                // SAFETY: the descriptor remains live while the graphics
                // writer owns the shared stdout lock.
                if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                return Ok(Self { restore: Some((fd, flags)) });
            }
        }
        Ok(Self {
            #[cfg(unix)]
            restore: None,
        })
    }

    fn restore(&mut self) -> std::io::Result<()> {
        #[cfg(unix)]
        if let Some((fd, flags)) = self.restore.take() {
            // SAFETY: the guard only stores a descriptor after a successful
            // F_GETFL/F_SETFL pair, and restoration runs before releasing the
            // shared stdout lock.
            if unsafe { libc::fcntl(fd, libc::F_SETFL, flags) } < 0 {
                return Err(std::io::Error::last_os_error());
            }
        }
        Ok(())
    }
}

impl Drop for NonblockingOutputGuard {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

struct GraphicsSubmission {
    id: u64,
    session_generation: u64,
    placements: Vec<GraphicPlacement>,
}

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
    fn wait_for(&self, expected: u32) -> std::io::Result<()> {
        self.wait_for_shutdown(expected, &AtomicBool::new(false))
    }

    fn wait_for_shutdown(&self, expected: u32, shutdown: &AtomicBool) -> std::io::Result<()> {
        let deadline = Instant::now() + PROCESSING_FENCE_TIMEOUT;
        let response = loop {
            if shutdown.load(Ordering::Acquire) {
                self.cancel(expected);
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Interrupted,
                    "graphics processing fence wait interrupted by shutdown",
                ));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                self.cancel(expected);
                return Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "graphics processing fence timed out",
                ));
            }
            match self.responses.recv_timeout(remaining.min(PROCESSING_FENCE_SHUTDOWN_POLL)) {
                Ok(response) => break response,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    self.cancel(expected);
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::BrokenPipe,
                        "graphics processing fence channel disconnected",
                    ));
                }
            }
        };
        self.cancel(expected);
        if response.id != expected {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!(
                    "graphics processing fence replied out of order: expected {expected}, got {}",
                    response.id
                ),
            ));
        }
        if !response.ok {
            return Err(std::io::Error::other(format!(
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
    fn wait(&mut self, id: u32, shutdown: &AtomicBool) -> std::io::Result<()>;
}

impl ProcessingFence for GraphicsFenceWaiter {
    fn prepare(&mut self, id: u32) {
        GraphicsFenceWaiter::prepare(self, id);
    }

    fn cancel(&mut self, id: u32) {
        GraphicsFenceWaiter::cancel(self, id);
    }

    fn wait(&mut self, id: u32, shutdown: &AtomicBool) -> std::io::Result<()> {
        self.wait_for_shutdown(id, shutdown)
    }
}

#[cfg(test)]
struct ClosureProcessingFence<F>(F);

#[cfg(test)]
impl<F> ProcessingFence for ClosureProcessingFence<F>
where
    F: FnMut() -> std::io::Result<()> + Send + 'static,
{
    fn wait(&mut self, _id: u32, shutdown: &AtomicBool) -> std::io::Result<()> {
        if shutdown.load(Ordering::Acquire) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "graphics processing fence wait interrupted by shutdown",
            ));
        }
        (self.0)()
    }
}

pub struct GraphicsWriter {
    slot: Arc<Mutex<Option<GraphicsSubmission>>>,
    completion: Arc<Mutex<Option<GraphicsCompletion>>>,
    notify: Option<SyncSender<()>>,
    done: Option<Receiver<()>>,
    handle: Option<JoinHandle<()>>,
    shutdown: Arc<AtomicBool>,
}

impl GraphicsWriter {
    pub fn spawn(
        stdout_lock: Arc<StdoutLock>,
        processing_fence: GraphicsFenceWaiter,
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        Self::spawn_with_fence(
            stdout_lock,
            std::io::stdout(),
            GraphicsOutputMode::stdout(),
            processing_fence,
            on_ready,
        )
    }

    #[cfg(test)]
    fn spawn_with_output(
        stdout_lock: Arc<StdoutLock>,
        output: impl Write + Send + 'static,
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        Self::spawn_with_output_and_fence(stdout_lock, output, || Ok(()), on_ready)
    }

    #[cfg(test)]
    fn spawn_with_output_and_fence(
        stdout_lock: Arc<StdoutLock>,
        output: impl Write + Send + 'static,
        processing_fence: impl FnMut() -> std::io::Result<()> + Send + 'static,
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        Self::spawn_with_fence(
            stdout_lock,
            output,
            GraphicsOutputMode::Cooperative,
            ClosureProcessingFence(processing_fence),
            on_ready,
        )
    }

    fn spawn_with_fence(
        stdout_lock: Arc<StdoutLock>,
        output: impl Write + Send + 'static,
        output_mode: GraphicsOutputMode,
        processing_fence: impl ProcessingFence,
        on_ready: impl Fn() + Send + 'static,
    ) -> std::io::Result<Self> {
        let (tx, rx) = sync_channel(1);
        let (done_tx, done_rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(None));
        let completion = Arc::new(Mutex::new(None));
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = std::thread::Builder::new().name("mux-graphics-writer".into()).spawn({
            let slot = slot.clone();
            let completion = completion.clone();
            let shutdown = shutdown.clone();
            move || {
                writer_loop(WriterLoop {
                    slot,
                    completion,
                    rx,
                    stdout_lock,
                    output,
                    output_mode,
                    processing_fence_waiter: processing_fence,
                    on_ready,
                    done_tx,
                    shutdown,
                });
            }
        })?;
        Ok(Self {
            slot,
            completion,
            notify: Some(tx),
            done: Some(done_rx),
            handle: Some(handle),
            shutdown,
        })
    }

    pub fn submit(
        &self,
        id: u64,
        session_generation: u64,
        placements: Vec<GraphicPlacement>,
    ) -> bool {
        if self.shutdown.load(Ordering::Acquire) {
            return false;
        }
        let Some(tx) = &self.notify else { return false };
        submit_snapshot(&self.slot, tx, GraphicsSubmission { id, session_generation, placements })
    }

    pub fn take_completion(&self) -> Option<GraphicsCompletion> {
        self.completion.lock().unwrap().take()
    }

    pub fn shutdown(&mut self, timeout: Duration) {
        self.shutdown.store(true, Ordering::Release);
        self.notify.take();
        let Some(handle) = self.handle.take() else { return };
        let Some(done) = self.done.take() else {
            let _ = handle.join();
            return;
        };
        match done.recv_timeout(timeout) {
            Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                let _ = handle.join();
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                self.done = Some(done);
                self.handle = Some(handle);
            }
        }
    }
}

impl Drop for GraphicsWriter {
    fn drop(&mut self) {
        self.shutdown(Duration::from_millis(200));
    }
}

fn submit_snapshot(
    slot: &Arc<Mutex<Option<GraphicsSubmission>>>,
    tx: &SyncSender<()>,
    submission: GraphicsSubmission,
) -> bool {
    *slot.lock().unwrap() = Some(submission);
    match tx.try_send(()) {
        Ok(()) | Err(TrySendError::Full(())) => true,
        Err(TrySendError::Disconnected(())) => false,
    }
}

struct WriterLoop<W, P, F> {
    slot: Arc<Mutex<Option<GraphicsSubmission>>>,
    completion: Arc<Mutex<Option<GraphicsCompletion>>>,
    rx: Receiver<()>,
    stdout_lock: Arc<StdoutLock>,
    output: W,
    output_mode: GraphicsOutputMode,
    processing_fence_waiter: P,
    on_ready: F,
    done_tx: SyncSender<()>,
    shutdown: Arc<AtomicBool>,
}

fn graphics_output_interrupted() -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Interrupted, "graphics output interrupted by shutdown")
}

fn graphics_output_timed_out() -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::TimedOut, "graphics output timed out")
}

fn check_graphics_output_deadline(
    deadline: Instant,
    shutdown: &AtomicBool,
) -> std::io::Result<Duration> {
    if shutdown.load(Ordering::Acquire) {
        return Err(graphics_output_interrupted());
    }
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(graphics_output_timed_out());
    }
    Ok(remaining)
}

fn wait_for_graphics_output(
    mode: GraphicsOutputMode,
    deadline: Instant,
    shutdown: &AtomicBool,
) -> std::io::Result<()> {
    let wait = check_graphics_output_deadline(deadline, shutdown)?.min(GRAPHICS_OUTPUT_POLL);
    #[cfg(unix)]
    if let GraphicsOutputMode::NonblockingFd(fd) = mode {
        let timeout_ms = wait.as_millis().clamp(1, i32::MAX as u128) as i32;
        let mut descriptor = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
        // SAFETY: `descriptor` points to one initialized pollfd for the live
        // stdout descriptor, and poll only mutates its revents field.
        let ready = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error);
            }
            return Ok(());
        }
        let terminal_events = libc::POLLERR | libc::POLLHUP | libc::POLLNVAL;
        if descriptor.revents & terminal_events != 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "graphics output descriptor closed",
            ));
        }
        return Ok(());
    }
    std::thread::sleep(wait);
    Ok(())
}

fn write_graphics_bytes<W: Write>(
    output: &mut W,
    mode: GraphicsOutputMode,
    mut bytes: &[u8],
    deadline: Instant,
    shutdown: &AtomicBool,
    wrote_any: &mut bool,
) -> std::io::Result<()> {
    while !bytes.is_empty() {
        check_graphics_output_deadline(deadline, shutdown)?;
        match output.write(bytes) {
            Ok(0) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WriteZero,
                    "graphics output made no progress",
                ));
            }
            Ok(written) => {
                *wrote_any = true;
                bytes = &bytes[written..];
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                wait_for_graphics_output(mode, deadline, shutdown)?;
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn flush_graphics_output<W: Write>(
    output: &mut W,
    mode: GraphicsOutputMode,
    deadline: Instant,
    shutdown: &AtomicBool,
) -> std::io::Result<()> {
    loop {
        check_graphics_output_deadline(deadline, shutdown)?;
        match output.flush() {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                wait_for_graphics_output(mode, deadline, shutdown)?;
            }
            Err(error) => return Err(error),
        }
    }
}

fn recover_partial_graphics_output<W: Write>(
    output: &mut W,
    mode: GraphicsOutputMode,
    possibly_visible: &BTreeSet<SurfaceId>,
) -> std::io::Result<()> {
    let deadline = Instant::now() + GRAPHICS_OUTPUT_RECOVERY_TIMEOUT;
    let recovery = AtomicBool::new(false);
    let mut wrote_any = false;
    let mut result = write_graphics_bytes(
        output,
        mode,
        KITTY_STRING_TERMINATOR,
        deadline,
        &recovery,
        &mut wrote_any,
    );
    for surface in possibly_visible {
        if result.is_err() {
            break;
        }
        result = write_graphics_bytes(
            output,
            mode,
            &super::graphics::delete_image(*surface),
            deadline,
            &recovery,
            &mut wrote_any,
        );
    }
    let terminated = write_graphics_bytes(
        output,
        mode,
        KITTY_STRING_TERMINATOR,
        deadline,
        &recovery,
        &mut wrote_any,
    )
    .and_then(|()| flush_graphics_output(output, mode, deadline, &recovery));
    result.and(terminated)
}

fn write_graphics_output<W, I, B>(
    stdout_lock: &StdoutLock,
    output: &mut W,
    output_mode: GraphicsOutputMode,
    chunks: I,
    possibly_visible: &BTreeSet<SurfaceId>,
    shutdown: &AtomicBool,
) -> std::io::Result<()>
where
    W: Write,
    I: IntoIterator<Item = B>,
    B: AsRef<[u8]>,
{
    let deadline = Instant::now() + GRAPHICS_OUTPUT_TIMEOUT;
    let _guard = loop {
        check_graphics_output_deadline(deadline, shutdown)?;
        if let Some(guard) = stdout_lock.try_lock() {
            break guard;
        }
        std::thread::sleep(
            check_graphics_output_deadline(deadline, shutdown)?.min(GRAPHICS_OUTPUT_POLL),
        );
    };
    let mut nonblocking = NonblockingOutputGuard::begin(output_mode)?;
    if let Some(pending) = stdout_lock.pending_stream_recovery() {
        let recovered = recover_partial_graphics_output(output, output_mode, &pending);
        if recovered.is_ok() {
            stdout_lock.clear_stream_recovery();
        } else {
            let restored = nonblocking.restore();
            return recovered.and(restored);
        }
    }
    let mut wrote_any = false;
    let result = (|| {
        for chunk in chunks {
            write_graphics_bytes(
                output,
                output_mode,
                chunk.as_ref(),
                deadline,
                shutdown,
                &mut wrote_any,
            )?;
        }
        flush_graphics_output(output, output_mode, deadline, shutdown)
    })();
    if result.is_err()
        && wrote_any
        && recover_partial_graphics_output(output, output_mode, possibly_visible).is_err()
    {
        stdout_lock.mark_stream_recovery(possibly_visible);
    }
    let restored = nonblocking.restore();
    result.and(restored)
}

fn writer_loop<W, P, F>(worker: WriterLoop<W, P, F>)
where
    W: Write,
    P: ProcessingFence,
    F: Fn(),
{
    let WriterLoop {
        slot,
        completion,
        rx,
        stdout_lock,
        mut output,
        output_mode,
        mut processing_fence_waiter,
        on_ready,
        done_tx,
        shutdown,
    } = worker;
    let _done = DoneOnDrop(done_tx);
    let mut graphics = GraphicsState::default();
    let mut acknowledged_visible = BTreeSet::new();
    let mut possibly_visible = BTreeSet::new();
    let mut consecutive_fence_timeouts = 0_u8;
    while rx.recv().is_ok() {
        if shutdown.load(Ordering::Acquire) {
            return;
        }
        loop {
            if shutdown.load(Ordering::Acquire) {
                return;
            }
            let next = slot.lock().unwrap().take();
            let Some(submission) = next else { break };
            let processed_graphics = submission
                .placements
                .iter()
                .map(|placement| ProcessedGraphic {
                    surface: placement.surface,
                    rect: placement.rect,
                    seq: placement.seq,
                    pointer_frame_seq: placement.pointer_frame_seq,
                })
                .collect();
            let submitted_visible = submission
                .placements
                .iter()
                .filter(|placement| placement.rect.width > 0 && placement.rect.height > 0)
                .map(|placement| placement.surface)
                .collect::<BTreeSet<_>>();
            let acknowledged_graphics = graphics.clone();
            let mut batches = possibly_visible
                .difference(&acknowledged_visible)
                .filter(|surface| !submitted_visible.contains(surface))
                .copied()
                .map(super::graphics::delete_image)
                .collect::<Vec<_>>();
            batches.extend(
                graphics.frame_batches(submission.session_generation, &submission.placements),
            );
            possibly_visible.extend(submitted_visible.iter().copied());
            let fence_id = processing_fence_id(submission.id);
            processing_fence_waiter.prepare(fence_id);
            let output_result = write_graphics_output(
                &stdout_lock,
                &mut output,
                output_mode,
                batches.into_iter().chain(std::iter::once(processing_fence(fence_id))),
                &possibly_visible,
                &shutdown,
            );
            if output_result.is_err() {
                processing_fence_waiter.cancel(fence_id);
                if shutdown.load(Ordering::Acquire) {
                    return;
                }
                *completion.lock().unwrap() = Some(GraphicsCompletion::Failed);
                on_ready();
                return;
            }
            let mut processed = processing_fence_waiter.wait(fence_id, &shutdown);
            if shutdown.load(Ordering::Acquire) {
                processing_fence_waiter.cancel(fence_id);
                return;
            }
            if processed.as_ref().is_err_and(|error| error.kind() == std::io::ErrorKind::TimedOut) {
                // The graphics bytes were written successfully. A second
                // ordered query distinguishes a delayed response from a
                // failed output stream without retransmitting image data.
                processing_fence_waiter.prepare(fence_id);
                let retry_output = write_graphics_output(
                    &stdout_lock,
                    &mut output,
                    output_mode,
                    std::iter::once(processing_fence(fence_id)),
                    &possibly_visible,
                    &shutdown,
                );
                if retry_output.is_err() {
                    processing_fence_waiter.cancel(fence_id);
                    if shutdown.load(Ordering::Acquire) {
                        return;
                    }
                    *completion.lock().unwrap() = Some(GraphicsCompletion::Failed);
                    on_ready();
                    return;
                }
                processed = processing_fence_waiter.wait(fence_id, &shutdown);
            }
            if shutdown.load(Ordering::Acquire) {
                processing_fence_waiter.cancel(fence_id);
                return;
            }
            if let Err(error) = processed {
                processing_fence_waiter.cancel(fence_id);
                if error.kind() == std::io::ErrorKind::TimedOut {
                    consecutive_fence_timeouts = consecutive_fence_timeouts.saturating_add(1);
                    graphics = acknowledged_graphics;
                    if consecutive_fence_timeouts >= MAX_CONSECUTIVE_GRAPHICS_FENCE_TIMEOUTS {
                        let cleanup = possibly_visible
                            .iter()
                            .copied()
                            .map(super::graphics::delete_image)
                            .collect::<Vec<_>>();
                        let _ = write_graphics_output(
                            &stdout_lock,
                            &mut output,
                            output_mode,
                            cleanup,
                            &possibly_visible,
                            &shutdown,
                        );
                        *completion.lock().unwrap() = Some(GraphicsCompletion::Failed);
                        on_ready();
                        return;
                    }
                    // One bounded re-probe may retransmit the unconfirmed
                    // image data. Persistent fence loss disables graphics.
                    *completion.lock().unwrap() = Some(GraphicsCompletion::TimedOut {
                        id: submission.id,
                        session_generation: submission.session_generation,
                    });
                    on_ready();
                    continue;
                }
                *completion.lock().unwrap() = Some(GraphicsCompletion::Failed);
                on_ready();
                return;
            }
            consecutive_fence_timeouts = 0;
            acknowledged_visible = submitted_visible.clone();
            possibly_visible = submitted_visible;
            *completion.lock().unwrap() = Some(GraphicsCompletion::Processed(GraphicsProcessing {
                id: submission.id,
                session_generation: submission.session_generation,
                graphics: processed_graphics,
            }));
            on_ready();
        }
    }
}

struct DoneOnDrop(SyncSender<()>);

impl Drop for DoneOnDrop {
    fn drop(&mut self) {
        let _ = self.0.try_send(());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::graphics::delete_image;
    use cmux_tui_core::Rect;

    struct FailingOutput;

    impl Write for FailingOutput {
        fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
            Err(std::io::Error::other("injected graphics output failure"))
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[derive(Clone, Default)]
    struct SharedOutput(Arc<Mutex<Vec<u8>>>);

    impl SharedOutput {
        fn bytes(&self) -> Vec<u8> {
            self.0.lock().unwrap().clone()
        }
    }

    impl Write for SharedOutput {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    struct BackpressuredOutput {
        attempts: Arc<std::sync::atomic::AtomicUsize>,
    }

    impl Write for BackpressuredOutput {
        fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
            self.attempts.fetch_add(1, Ordering::AcqRel);
            Err(std::io::Error::from(std::io::ErrorKind::WouldBlock))
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[derive(Clone, Default)]
    struct PartialThenBackpressuredOutput(Arc<Mutex<PartialThenBackpressuredState>>);

    #[derive(Default)]
    struct PartialThenBackpressuredState {
        bytes: Vec<u8>,
        blocked_until: Option<Instant>,
    }

    impl PartialThenBackpressuredOutput {
        fn bytes(&self) -> Vec<u8> {
            self.0.lock().unwrap().bytes.clone()
        }
    }

    impl Write for PartialThenBackpressuredOutput {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            let mut state = self.0.lock().unwrap();
            match state.blocked_until {
                None => {
                    let written = buf.len().min(8);
                    state.bytes.extend_from_slice(&buf[..written]);
                    state.blocked_until =
                        Some(Instant::now() + GRAPHICS_OUTPUT_TIMEOUT + Duration::from_millis(50));
                    Ok(written)
                }
                Some(blocked_until) if Instant::now() < blocked_until => {
                    Err(std::io::Error::from(std::io::ErrorKind::WouldBlock))
                }
                Some(_) => {
                    state.bytes.extend_from_slice(buf);
                    Ok(buf.len())
                }
            }
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn occurrences(haystack: &[u8], needle: &[u8]) -> usize {
        haystack.windows(needle.len()).filter(|window| *window == needle).count()
    }

    fn key(ch: char, modifiers: KeyModifiers) -> Event {
        Event::Key(KeyEvent::new(KeyCode::Char(ch), modifiers))
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
    fn impossible_graphics_response_prefix_replays_during_active_fence() {
        let (waiter, notifier) = graphics_fence_channel();
        let mut filter = GraphicsResponseFilter::new(notifier);
        let id = processing_fence_id(12);
        waiter.prepare(id);
        let boundary = key('_', KeyModifiers::ALT);
        let impossible_prefix = key('x', KeyModifiers::NONE);
        assert!(filter.filter(boundary.clone()).is_empty());

        assert_eq!(
            filter.filter(impossible_prefix.clone()),
            vec![boundary, impossible_prefix],
            "an impossible APC prefix must not wait for the active fence to expire"
        );
        let following = key('z', KeyModifiers::NONE);
        assert_eq!(filter.filter(following.clone()), vec![following]);
        waiter.cancel(id);
    }

    #[test]
    fn late_canceled_processing_fence_reply_is_consumed() {
        let (waiter, notifier) = graphics_fence_channel();
        let mut filter = GraphicsResponseFilter::new(notifier);
        let id = processing_fence_id(13);
        waiter.prepare(id);
        waiter.cancel(id);
        let response = format!("Gi={id};OK");
        let replayed = std::iter::once(key('_', KeyModifiers::ALT))
            .chain(response.chars().map(|ch| {
                key(ch, if ch.is_uppercase() { KeyModifiers::SHIFT } else { KeyModifiers::NONE })
            }))
            .chain(std::iter::once(key('\\', KeyModifiers::ALT)))
            .flat_map(|event| filter.filter(event))
            .collect::<Vec<_>>();

        assert!(
            replayed.is_empty(),
            "a late terminal response for a canceled fence must not become user input"
        );
    }

    #[test]
    fn incomplete_canceled_graphics_response_replays_after_deadline() {
        let (waiter, notifier) = graphics_fence_channel();
        let mut filter = GraphicsResponseFilter::new(notifier);
        let id = processing_fence_id(14);
        waiter.prepare(id);
        let boundary = key('_', KeyModifiers::ALT);
        let graphics_prefix = key('G', KeyModifiers::SHIFT);
        assert!(filter.filter(boundary.clone()).is_empty());
        assert!(filter.filter(graphics_prefix.clone()).is_empty());

        waiter.cancel(id);
        let buffered_key = key('i', KeyModifiers::NONE);
        assert!(filter.filter(buffered_key.clone()).is_empty());
        std::thread::sleep(Duration::from_millis(300));
        let following = key('z', KeyModifiers::NONE);

        assert_eq!(
            filter.take_expired(),
            vec![boundary, graphics_prefix, buffered_key],
            "an unterminated late response must replay without waiting for more keyboard input"
        );
        assert_eq!(filter.filter(following.clone()), vec![following]);
    }

    #[test]
    fn snapshot_slot_is_latest_wins_and_shutdown_is_clean() {
        let (tx, rx) = sync_channel(1);
        let slot = Arc::new(Mutex::new(None));
        submit_snapshot(
            &slot,
            &tx,
            GraphicsSubmission {
                id: 1,
                session_generation: 1,
                placements: vec![GraphicPlacement {
                    surface: 1,
                    rect: Rect { x: 0, y: 0, width: 10, height: 5 },
                    seq: 1,
                    pointer_frame_seq: Some(1),
                    data_b64: "AAAA".to_string(),
                }],
            },
        );
        submit_snapshot(
            &slot,
            &tx,
            GraphicsSubmission {
                id: 2,
                session_generation: 1,
                placements: vec![GraphicPlacement {
                    surface: 1,
                    rect: Rect { x: 1, y: 1, width: 11, height: 6 },
                    seq: 2,
                    pointer_frame_seq: Some(1),
                    data_b64: "BBBB".to_string(),
                }],
            },
        );

        let latest = slot.lock().unwrap().take().expect("latest snapshot");
        assert_eq!(latest.id, 2);
        assert_eq!(latest.placements.len(), 1);
        assert_eq!(latest.placements[0].seq, 2);
        assert_eq!(latest.placements[0].rect.x, 1);
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(rx.try_recv().is_err());

        let lock = Arc::new(StdoutLock::new(()));
        let (fence, _notifier) = graphics_fence_channel();
        let mut writer = GraphicsWriter::spawn(lock, fence, || {}).unwrap();
        writer.shutdown(Duration::from_secs(1));
        assert!(writer.handle.as_ref().is_none_or(|handle| handle.is_finished()));
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

        assert!(writer.submit(
            7,
            1,
            vec![GraphicPlacement {
                surface: 11,
                rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                seq: 13,
                pointer_frame_seq: Some(8),
                data_b64: "AAAA".to_string(),
            }]
        ));
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
    fn shutdown_cancels_backpressured_output_and_releases_stdout_lock() {
        let lock = Arc::new(StdoutLock::new(()));
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output(
            lock.clone(),
            BackpressuredOutput { attempts: attempts.clone() },
            move || {
                ready_tx.send(()).unwrap();
            },
        )
        .unwrap();

        assert!(writer.submit(
            8,
            1,
            vec![GraphicPlacement {
                surface: 11,
                rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                seq: 14,
                pointer_frame_seq: Some(8),
                data_b64: "AAAA".to_string(),
            }]
        ));
        let attempt_deadline = Instant::now() + Duration::from_secs(1);
        while attempts.load(Ordering::Acquire) == 0 {
            assert!(
                Instant::now() < attempt_deadline,
                "writer never attempted backpressured output"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
        let completed_before_shutdown = ready_rx.recv_timeout(Duration::from_millis(50)).is_ok();

        writer.shutdown(Duration::from_millis(200));
        let stopped = writer.handle.as_ref().is_none_or(|handle| handle.is_finished());
        let lock_released = lock.try_lock().is_some();

        assert!(
            !completed_before_shutdown,
            "temporary stdout backpressure must remain retryable until cancellation or deadline"
        );
        assert!(
            attempts.load(Ordering::Acquire) > 1,
            "the writer must retry temporary stdout backpressure"
        );
        assert!(stopped, "shutdown must cancel a backpressured graphics write within its budget");
        assert!(lock_released, "canceled graphics output must release the shared stdout lock");
    }

    #[test]
    fn partial_output_failure_terminates_apc_and_cleans_possible_images() {
        let lock = Arc::new(StdoutLock::new(()));
        let output = PartialThenBackpressuredOutput::default();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer =
            GraphicsWriter::spawn_with_output(lock.clone(), output.clone(), move || {
                ready_tx.send(()).unwrap();
            })
            .unwrap();

        assert!(writer.submit(
            36,
            1,
            vec![GraphicPlacement {
                surface: 15,
                rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                seq: 21,
                pointer_frame_seq: Some(21),
                data_b64: "AAAA".to_string(),
            }]
        ));
        let partial_deadline = Instant::now() + Duration::from_secs(1);
        while output.bytes().is_empty() {
            assert!(Instant::now() < partial_deadline, "writer never emitted the partial APC");
            std::thread::sleep(Duration::from_millis(5));
        }
        std::thread::sleep(GRAPHICS_OUTPUT_TIMEOUT + Duration::from_millis(20));
        let released_before_recovery = lock.try_lock().is_some();
        ready_rx
            .recv_timeout(GRAPHICS_OUTPUT_TIMEOUT + Duration::from_secs(1))
            .expect("partial graphics output must settle after bounded stream recovery");
        assert_eq!(writer.take_completion(), Some(GraphicsCompletion::Failed));
        writer.shutdown(Duration::from_secs(1));

        let bytes = output.bytes();
        assert!(
            bytes.windows(2).any(|window| window == b"\x1b\\"),
            "a partial Kitty APC must be terminated before stdout ownership is released"
        );
        assert!(
            occurrences(&bytes, &delete_image(15)) >= 1,
            "a partially emitted image must be deleted before text fallback can render"
        );
        assert!(
            !released_before_recovery,
            "stdout ownership must remain exclusive until the partial APC is recovered"
        );
        assert!(lock.try_lock().is_some(), "stream recovery must release the shared stdout lock");
    }

    #[test]
    fn transient_processing_timeout_retries_without_stopping_writer() {
        let lock = Arc::new(StdoutLock::new(()));
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock,
            Vec::new(),
            move || {
                if attempts.fetch_add(1, Ordering::AcqRel) == 0 {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "injected transient fence timeout",
                    ))
                } else {
                    Ok(())
                }
            },
            move || {
                ready_tx.send(()).unwrap();
            },
        )
        .unwrap();
        let placement = |seq| GraphicPlacement {
            surface: 11,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq,
            pointer_frame_seq: Some(seq),
            data_b64: "AAAA".to_string(),
        };

        assert!(writer.submit(9, 1, vec![placement(15)]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let first_processed = matches!(
            writer.take_completion(),
            Some(GraphicsCompletion::Processed(GraphicsProcessing { id: 9, .. }))
        );
        let second_accepted = writer.submit(10, 1, vec![placement(16)]);
        let second_processed = if second_accepted {
            ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
            matches!(
                writer.take_completion(),
                Some(GraphicsCompletion::Processed(GraphicsProcessing { id: 10, .. }))
            )
        } else {
            false
        };
        writer.shutdown(Duration::from_secs(1));

        assert!(first_processed, "one fence timeout must retry the accepted submission");
        assert!(second_accepted, "a transient timeout must not stop the graphics writer");
        assert!(second_processed, "the writer must process later graphics after recovery");
    }

    #[test]
    fn timed_out_deletion_is_reemitted_until_acknowledged() {
        let lock = Arc::new(StdoutLock::new(()));
        let output = SharedOutput::default();
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock,
            output.clone(),
            move || match attempts.fetch_add(1, Ordering::AcqRel) {
                0 | 3 => Ok(()),
                _ => Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "injected ambiguous deletion timeout",
                )),
            },
            move || {
                ready_tx.send(()).unwrap();
            },
        )
        .unwrap();
        let placement = GraphicPlacement {
            surface: 11,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq: 17,
            pointer_frame_seq: Some(17),
            data_b64: "AAAA".to_string(),
        };

        assert!(writer.submit(21, 1, vec![placement]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            writer.take_completion(),
            Some(GraphicsCompletion::Processed(GraphicsProcessing { id: 21, .. }))
        ));
        assert!(writer.submit(22, 1, Vec::new()));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            writer.take_completion(),
            Some(GraphicsCompletion::TimedOut { id: 22, .. })
        ));
        assert!(writer.submit(23, 1, Vec::new()));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            writer.take_completion(),
            Some(GraphicsCompletion::Processed(GraphicsProcessing { id: 23, .. }))
        ));
        writer.shutdown(Duration::from_secs(1));

        let deletion = delete_image(11);
        assert_eq!(
            occurrences(&output.bytes(), &deletion),
            2,
            "an ambiguous deletion must remain pending until a fence acknowledges its retry"
        );
    }

    #[test]
    fn persistent_fence_loss_emits_final_cleanup_for_known_images() {
        let lock = Arc::new(StdoutLock::new(()));
        let output = SharedOutput::default();
        let attempts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock,
            output.clone(),
            move || {
                if attempts.fetch_add(1, Ordering::AcqRel) == 0 {
                    Ok(())
                } else {
                    Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "injected persistent deletion timeout",
                    ))
                }
            },
            move || {
                ready_tx.send(()).unwrap();
            },
        )
        .unwrap();
        let placement = GraphicPlacement {
            surface: 12,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq: 18,
            pointer_frame_seq: Some(18),
            data_b64: "AAAA".to_string(),
        };

        assert!(writer.submit(31, 1, vec![placement]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            writer.take_completion(),
            Some(GraphicsCompletion::Processed(GraphicsProcessing { id: 31, .. }))
        ));
        assert!(writer.submit(32, 1, Vec::new()));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            writer.take_completion(),
            Some(GraphicsCompletion::TimedOut { id: 32, .. })
        ));
        assert!(writer.submit(33, 1, Vec::new()));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(writer.take_completion(), Some(GraphicsCompletion::Failed));
        writer.shutdown(Duration::from_secs(1));

        let deletion = delete_image(12);
        assert_eq!(
            occurrences(&output.bytes(), &deletion),
            3,
            "disabling graphics must make one final best-effort deletion of every known image"
        );
    }

    #[test]
    fn persistent_fence_loss_cleans_every_unacknowledged_image() {
        let lock = Arc::new(StdoutLock::new(()));
        let output = SharedOutput::default();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock,
            output.clone(),
            || {
                Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "injected persistent fence timeout",
                ))
            },
            move || {
                ready_tx.send(()).unwrap();
            },
        )
        .unwrap();
        let placement = |surface, seq| GraphicPlacement {
            surface,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq,
            pointer_frame_seq: Some(seq),
            data_b64: "AAAA".to_string(),
        };

        assert!(writer.submit(34, 1, vec![placement(13, 19)]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            writer.take_completion(),
            Some(GraphicsCompletion::TimedOut { id: 34, .. })
        ));
        assert!(writer.submit(35, 1, vec![placement(14, 20)]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(writer.take_completion(), Some(GraphicsCompletion::Failed));
        writer.shutdown(Duration::from_secs(1));

        let bytes = output.bytes();
        assert!(
            occurrences(&bytes, &delete_image(13)) >= 1,
            "final cleanup must delete an image whose first submission was never acknowledged"
        );
        assert!(
            occurrences(&bytes, &delete_image(14)) >= 1,
            "final cleanup must delete an image whose last submission was never acknowledged"
        );
    }

    #[test]
    fn exhausted_processing_timeout_remains_recoverable() {
        let lock = Arc::new(StdoutLock::new(()));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock,
            Vec::new(),
            || {
                Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "injected persistent fence timeout",
                ))
            },
            move || {
                ready_tx.send(()).unwrap();
            },
        )
        .unwrap();
        let placement = |seq| GraphicPlacement {
            surface: 11,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq,
            pointer_frame_seq: Some(seq),
            data_b64: "AAAA".to_string(),
        };

        assert!(writer.submit(11, 1, vec![placement(17)]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let completion = writer.take_completion();
        let later_accepted = writer.submit(12, 1, vec![placement(18)]);
        if later_accepted {
            ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        }
        writer.shutdown(Duration::from_secs(1));

        assert!(
            completion.is_some() && !matches!(completion, Some(GraphicsCompletion::Failed)),
            "an exhausted fence timeout must request recovery without disabling graphics"
        );
        assert!(later_accepted, "the writer must remain available for a later re-probe");
    }

    #[test]
    fn persistent_processing_timeouts_eventually_stop_writer() {
        let lock = Arc::new(StdoutLock::new(()));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output_and_fence(
            lock,
            Vec::new(),
            || {
                Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "injected persistent fence timeout",
                ))
            },
            move || {
                ready_tx.send(()).unwrap();
            },
        )
        .unwrap();
        let placement = |seq| GraphicPlacement {
            surface: 11,
            rect: Rect { x: 1, y: 2, width: 3, height: 4 },
            seq,
            pointer_frame_seq: Some(seq),
            data_b64: "AAAA".to_string(),
        };

        assert!(writer.submit(13, 1, vec![placement(19)]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(writer.take_completion(), Some(GraphicsCompletion::TimedOut { .. })));
        assert!(writer.submit(14, 1, vec![placement(20)]));
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let completion = writer.take_completion();
        writer.shutdown(Duration::from_secs(1));

        assert_eq!(
            completion,
            Some(GraphicsCompletion::Failed),
            "persistent fence loss must disable graphics instead of retransmitting forever"
        );
    }

    #[test]
    fn shutdown_interrupts_unanswered_processing_fence_before_retry() {
        let lock = Arc::new(StdoutLock::new(()));
        let output = SharedOutput::default();
        let (fence, _notifier) = graphics_fence_channel();
        let mut writer = GraphicsWriter::spawn_with_fence(
            lock,
            output.clone(),
            GraphicsOutputMode::Cooperative,
            fence,
            || {},
        )
        .unwrap();
        let id = 15;
        let query = processing_fence(processing_fence_id(id));
        assert!(writer.submit(
            id,
            1,
            vec![GraphicPlacement {
                surface: 11,
                rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                seq: 21,
                pointer_frame_seq: Some(21),
                data_b64: "AAAA".to_string(),
            }]
        ));
        let deadline = Instant::now() + Duration::from_secs(1);
        while occurrences(&output.bytes(), &query) == 0 {
            assert!(Instant::now() < deadline, "writer never emitted its initial fence query");
            std::thread::sleep(Duration::from_millis(5));
        }

        writer.shutdown(Duration::from_millis(200));
        let stopped = writer.handle.as_ref().is_none_or(|handle| handle.is_finished());
        std::thread::sleep(Duration::from_millis(1_100));
        let query_count = occurrences(&output.bytes(), &query);

        assert!(stopped, "shutdown must interrupt an unanswered fence within its wait budget");
        assert_eq!(
            query_count, 1,
            "the graphics worker must not emit a retry query after terminal restoration"
        );
    }

    #[test]
    fn output_failure_notifies_the_app_to_settle_the_submission() {
        let lock = Arc::new(StdoutLock::new(()));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let mut writer = GraphicsWriter::spawn_with_output(lock, FailingOutput, move || {
            ready_tx.send(()).unwrap();
        })
        .unwrap();

        assert!(writer.submit(
            9,
            1,
            vec![GraphicPlacement {
                surface: 11,
                rect: Rect { x: 1, y: 2, width: 3, height: 4 },
                seq: 15,
                pointer_frame_seq: Some(9),
                data_b64: "AAAA".to_string(),
            }]
        ));
        ready_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("a failed accepted submission must wake the app");
        assert_eq!(writer.take_completion(), Some(GraphicsCompletion::Failed));
        writer.shutdown(Duration::from_secs(1));
    }
}
