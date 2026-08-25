//! Relay-side PTY sessions (relay wire v4/v5, W78/W86). Behavior port of
//! `packages/relay/bin/pty.mjs`; the unit tests mirror `pty.test.mjs`.
//!
//! The Worker's Relay DO sends `pty_*` frames over the paired socket; this
//! module resolves persistent sessions on the machine and answers
//! pty_opened/pty_output/pty_exit/pty_error.
//!
//! Session model (docs/TERMINAL.md):
//! - cmux-tui path (preferred): a `cmux-tui --headless --session <name>`
//!   daemon owns the mux; each attachment is a `cmux-tui attach` viewer PTY.
//!   Detach kills only the viewer; the daemon keeps the session.
//! - cmux-tui RAW single-terminal path (W86): pty_open with a `surface`
//!   attaches ONE terminal over the daemon's JSON-lines control socket.
//! - fallback (no cmux-tui): a plain $SHELL PTY held across detaches, with a
//!   bounded scrollback ring replayed on reattach, fanned out to any number
//!   of concurrent viewers (0.0.10 multi-viewer).
//!
//! Discipline: trust re-checked here (observe = owner-only); cwd scoped to
//! every non-empty allowed root list; env scrubbed; per-pty buffered output capped; no
//! empty frames; unknown ptyIds tolerated; refusals answer pty_error.

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;
use tokio::sync::{Notify, oneshot};

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use bytes::Bytes;
use serde_json::{Value, json};

use crate::actions::{expand_path, scrubbed_env, validate_request_path};
use crate::control::ControlHandle;
use crate::relay_wire::RelayPtyErrorCode;
use crate::wire::PTY_OPERATIONAL_ERRORS_PROTOCOL_VERSION;

pub const PTY_PROTOCOL_VERSION: u64 = 4;

pub type DataSink = Arc<dyn Fn(Bytes) + Send + Sync>;
pub type ExitSink = Arc<dyn Fn(i64) + Send + Sync>;
/// Max concurrent attachments per relay process.
pub const MAX_PTYS: usize = 8;
/// Fallback-session scrollback ring, bytes.
pub const SCROLLBACK_LIMIT: usize = 256 * 1024;
/// Per-pty outbound buffer cap, bytes (ws bufferedAmount at output time).
pub const OUTPUT_BUFFER_CAP: u64 = 1024 * 1024;
/// cmux-tui control protocol floor for attach-surface/send.
const CONTROL_MIN_PROTOCOL: i64 = 5;
/// cmux-tui protocol floor for per-surface geometry ownership. Older daemons
/// still apply a direct `resize-surface`; newer daemons require a verified
/// `set-client-sizing` claim before a resize changes the PTY grid.
const CLIENT_SIZING_MIN_PROTOCOL: i64 = 10;
/// Inner terminals listed per session (surface_list stays bounded). This is a
/// deliberate capacity/security limit, not a pagination hint: callers must
/// fail closed when the daemon reports more live PTYs than this cap.
const MAX_ENUM_TERMINALS: usize = 8;
const MAX_ALLOWED_ROOTS: usize = 32;
const MAX_ALLOWED_ROOT_BYTES: usize = 16 * 1024;
const MAX_ENUM_SURFACES: usize = 8;
const RAW_ATTACH_BACKLOG_CAP: usize = 1024 * 1024;
const PTY_INPUT_B64_CAP: usize = 4 * 1024 * 1024;
/// A shell viewer must not retain unbounded output while its callback is
/// blocked. The byte cap matches the per-attachment socket budget, and one
/// event slot is reserved for the terminal control transition.
const VIEWER_DELIVERY_MAX_BYTES: usize = OUTPUT_BUFFER_CAP as usize;
const VIEWER_DELIVERY_MAX_EVENTS: usize = 4096;
const MAX_ORDERED_CONTROL_COMMANDS: usize = 256;

pub fn session_name_ok(name: &str) -> bool {
    let invalid = name.is_empty()
        || matches!(name, "." | "..")
        || name.chars().any(|character| {
            character == '/'
                || character == '\\'
                || character == '\0'
                || character.is_control()
                || matches!(character, '\u{0085}' | '\u{2028}' | '\u{2029}')
        });
    !invalid
}

pub fn surface_ref_ok(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '-'))
}

/// Resolve a PTY working directory and enforce every configured root list.
/// Canonicalization closes symlink escapes before the path reaches spawn.
fn scoped_cwd(
    requested: Option<&str>,
    home: &Path,
    local_roots: Option<&[String]>,
    server_roots: Option<&[String]>,
) -> Result<PathBuf, String> {
    // Keep PTY paths on the same wire policy as file actions. The relay sends
    // this error to the peer, so the validator only returns policy text and
    // filesystem failures below are deliberately redacted.
    let validate = |value: &str, kind: &str| {
        validate_request_path(value).map_err(|message| format!("invalid {kind}: {message}"))
    };
    if let Some(value) = requested.filter(|value| !value.is_empty()) {
        validate(value, "cwd")?;
    }
    for roots in [local_roots, server_roots].into_iter().flatten() {
        for root in roots {
            validate(root, "allowed root")?;
        }
    }

    let raw_owned;
    let raw = if let Some(value) = requested.filter(|value| !value.is_empty()) {
        if !Path::new(value).is_absolute()
            && value != "~"
            && !value.starts_with("~/")
            && !value.starts_with("~\\")
        {
            return Err("cwd must be absolute or home-relative".to_owned());
        }
        value
    } else {
        raw_owned =
            match (local_roots.filter(|r| !r.is_empty()), server_roots.filter(|r| !r.is_empty())) {
                (Some(local), Some(server)) => {
                    let mut candidates: Vec<PathBuf> = local
                        .iter()
                        .chain(server.iter())
                        .filter_map(|root| {
                            std::fs::canonicalize(expand_path(root, home, home)).ok()
                        })
                        .collect();
                    candidates.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
                    candidates
                        .into_iter()
                        .find(|candidate| {
                            local.iter().chain(server.iter()).all(|root| {
                                std::fs::canonicalize(expand_path(root, home, home))
                                    .map(|root| candidate.starts_with(root))
                                    .unwrap_or(false)
                            })
                        })
                        .map(|path| path.to_string_lossy().into_owned())
                        .unwrap_or_else(|| "~".to_owned())
                }
                (Some(local), None) => local.first().unwrap().clone(),
                (None, Some(server)) => server.first().unwrap().clone(),
                (None, None) => "~".to_owned(),
            };
        &raw_owned
    };
    let path = expand_path(raw, home, home);
    let canonical = std::fs::canonicalize(&path).map_err(|_| "cwd is not accessible".to_owned())?;
    for roots in [local_roots.filter(|r| !r.is_empty()), server_roots.filter(|r| !r.is_empty())]
        .into_iter()
        .flatten()
    {
        if !roots.iter().map(|root| expand_path(root, home, home)).any(|root| {
            std::fs::canonicalize(root).map(|root| canonical.starts_with(root)).unwrap_or(false)
        }) {
            return Err("cwd is outside the allowed roots".to_owned());
        }
    }
    if !canonical.is_dir() {
        return Err("cwd is not a directory".to_owned());
    }
    Ok(canonical)
}

fn clamp_dim(value: Option<&Value>) -> Option<u16> {
    let number = value.and_then(Value::as_i64)?;
    if (1..=10_000).contains(&number) { u16::try_from(number).ok() } else { None }
}

fn parse_allowed_roots(frame: &Value) -> Result<Option<Vec<String>>, &'static str> {
    let Some(value) = frame.get("allowedRoots") else { return Ok(None) };
    if value.is_null() {
        return Ok(None);
    }
    let roots = value.as_array().ok_or("allowedRoots must be an array")?;
    if roots.len() > MAX_ALLOWED_ROOTS
        || roots.iter().any(|root| !root.is_string() || root.as_str() == Some(""))
    {
        return Err("invalid allowedRoots");
    }
    let total: usize = roots.iter().map(|root| root.as_str().unwrap().len()).sum();
    if total > MAX_ALLOWED_ROOT_BYTES {
        return Err("invalid allowedRoots");
    }
    Ok(Some(roots.iter().map(|root| root.as_str().unwrap().to_owned()).collect()))
}

// ---------------------------------------------------------------------------
// Injected dependencies (real impls in `deps`; tests inject fakes)
// ---------------------------------------------------------------------------

/// One PTY's control surface (write/resize/pause/resume/kill). The kill
/// semantics vary by mode: viewer PTYs detach, shell proxies release a
/// viewer, control handles close the stream.
pub trait PtyControl: Send + Sync {
    fn write(&self, data: &[u8]);
    fn resize(&self, cols: u16, rows: u16);
    fn pause(&self);
    fn resume(&self);
    /// Release relay-local attachment state after the PTY has already exited.
    /// Implementations must not terminate a still-running process here.
    fn release(&self) {}
    /// Transfer a just-spawned process from its cancellation guard to the
    /// manager. Ordinary controls do not need a separate transfer step.
    fn claim(&self) {}
    fn kill(&self);
}

/// A spawned PTY's output: the manager subscribes exactly one (data, exit)
/// sink. The source serializes sink calls as bytes arrive (a real PTY from its
/// reader thread; a test fake directly), buffering anything that arrives
/// before `subscribe`, so no early prompt bytes are lost.
pub trait PtyOutput: Send + Sync {
    fn subscribe(&self, on_data: DataSink, on_exit: ExitSink);
}

/// A spawned PTY: a control surface, its output source, and an optional
/// banner (degraded pipe-mode notice) delivered before live bytes.
pub struct PtyHandle {
    pub control: Arc<dyn PtyControl>,
    pub output: Arc<dyn PtyOutput>,
    pub banner: Option<Vec<u8>>,
}

impl PtyHandle {
    pub(crate) fn disarm_cleanup(&self) {
        self.control.claim();
    }
}

pub struct SpawnSpec {
    pub file: String,
    pub args: Vec<String>,
    pub cols: u16,
    pub rows: u16,
    pub cwd: PathBuf,
    pub env: HashMap<String, String>,
}

/// A resolved cmux-tui binary: file plus an argv prefix.
#[derive(Clone)]
pub struct CmuxTui {
    pub file: String,
    pub prefix: Vec<String>,
}

pub struct EnsureDaemon {
    pub created: bool,
    pub socket_path: PathBuf,
}

#[async_trait]
pub trait PtyDeps: Send + Sync {
    async fn spawn_pty(&self, spec: SpawnSpec) -> PtyHandle;
    async fn resolve_cmux_tui(&self) -> Option<CmuxTui>;
    async fn ensure_daemon(
        &self,
        cmux_tui: &CmuxTui,
        session: &str,
        socket_dir: &Path,
        cwd: &Path,
        env: &HashMap<String, String>,
    ) -> Result<EnsureDaemon, String>;
    async fn connect_control(&self, socket_path: &Path) -> Result<Arc<dyn ControlHandle>, String>;
    async fn read_dir(&self, path: &Path) -> Result<Vec<String>, ()>;
    fn socket_dir(&self) -> PathBuf;
    fn shell(&self) -> String;
}

// ---------------------------------------------------------------------------
// Frame context (the socket send + backpressure probe)
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct FrameContext {
    pub send: Arc<dyn Fn(Value) + Send + Sync>,
    pub buffered_amount: Arc<dyn Fn() -> u64 + Send + Sync>,
    /// Outer relay version negotiated during hello. PTY frames stay v4, but
    /// operational PTY error codes require the v7 feature gate.
    pub negotiated_version: u64,
    pub trust: String,
    pub local_roots: Option<Vec<String>>,
    pub owner_user_id: Option<String>,
}

#[derive(Clone)]
struct AuthSnapshot {
    trust: String,
    owner_user_id: Option<String>,
    send: Arc<dyn Fn(Value) + Send + Sync>,
    buffered_amount: Arc<dyn Fn() -> u64 + Send + Sync>,
}

/// Scrubbed env for interactive PTYs (actions.mjs base, real TERM).
pub fn pty_env(base: &HashMap<String, String>) -> HashMap<String, String> {
    let mut env = scrubbed_env(base);
    env.insert("TERM".to_owned(), "xterm-256color".to_owned());
    env
}

// ---------------------------------------------------------------------------
// Shared session/attachment state
// ---------------------------------------------------------------------------

/// Events queued for one shell viewer while its initial replay is handed off.
/// Keeping the queue separate from `ShellInner` lets the shell state lock stay
/// short while callbacks run, without allowing live output to overtake replay.
enum ViewerEvent {
    Data(Bytes),
    Exit(i64),
}

enum ViewerDeliveryAction {
    None,
    Drain,
    Overflow,
}

struct ViewerDeliveryState {
    active: bool,
    finished: bool,
    released: bool,
    overflowed: bool,
    overflow_notified: bool,
    draining: bool,
    queued_bytes: usize,
    queue: VecDeque<ViewerEvent>,
}

/// Serializes one viewer's banner/replay/live/exit callbacks.
///
/// The delivery starts inactive. Producers can enqueue live output while the
/// initial replay is being assembled; `activate` starts one drainer after the
/// replay has been queued. Every subsequent producer either owns the drainer
/// or appends to its FIFO queue, so callbacks cannot overtake one another.
struct ViewerDelivery {
    state: Mutex<ViewerDeliveryState>,
    on_data: DataSink,
    on_exit: ExitSink,
    on_overflow: Arc<dyn Fn() + Send + Sync>,
}

impl ViewerDelivery {
    fn with_overflow(
        on_data: DataSink,
        on_exit: ExitSink,
        on_overflow: Arc<dyn Fn() + Send + Sync>,
    ) -> Arc<ViewerDelivery> {
        Arc::new(ViewerDelivery {
            state: Mutex::new(ViewerDeliveryState {
                active: false,
                finished: false,
                released: false,
                overflowed: false,
                overflow_notified: false,
                draining: false,
                queued_bytes: 0,
                queue: VecDeque::new(),
            }),
            on_data,
            on_exit,
            on_overflow,
        })
    }

    fn mark_overflow(state: &mut ViewerDeliveryState) {
        state.finished = true;
        state.overflowed = true;
        state.queued_bytes = 0;
        state.queue.clear();
    }

    fn enqueue_data(state: &mut ViewerDeliveryState, chunk: Bytes) -> bool {
        let data_slots = VIEWER_DELIVERY_MAX_EVENTS.saturating_sub(1);
        let Some(total) = state.queued_bytes.checked_add(chunk.len()) else {
            Self::mark_overflow(state);
            return false;
        };
        if state.queue.len() >= data_slots || total > VIEWER_DELIVERY_MAX_BYTES {
            Self::mark_overflow(state);
            return false;
        }
        state.queued_bytes = total;
        state.queue.push_back(ViewerEvent::Data(chunk));
        true
    }

    /// Queue an initial banner or replay while callbacks remain paused.
    fn seed(&self, banner: Option<Bytes>, replay: Option<Bytes>) -> bool {
        let mut state = self.state.lock().expect("viewer delivery lock");
        if state.released {
            return false;
        }
        // A shell can exit before the deferred viewer start finishes building
        // its initial replay. Keep the terminal event last so the viewer still
        // receives banner, replay, then exit.
        let exit = state.finished.then(|| state.queue.pop_back()).flatten();
        let mut overflowed = false;
        if let Some(banner) = banner {
            overflowed |= !Self::enqueue_data(&mut state, banner);
        }
        if !overflowed && let Some(replay) = replay {
            overflowed |= !Self::enqueue_data(&mut state, replay);
        }
        if let Some(exit) = exit
            && !overflowed
        {
            state.queue.push_back(exit);
        }
        overflowed
    }

    /// Queue live output and report whether this caller should drain it.
    fn push_data(&self, chunk: Bytes) -> ViewerDeliveryAction {
        let mut state = self.state.lock().expect("viewer delivery lock");
        if state.finished || state.released {
            return ViewerDeliveryAction::None;
        }
        if !Self::enqueue_data(&mut state, chunk) {
            return ViewerDeliveryAction::Overflow;
        }
        if state.active && !state.draining {
            state.draining = true;
            ViewerDeliveryAction::Drain
        } else {
            ViewerDeliveryAction::None
        }
    }

    /// Mark the viewer active and report whether this caller should drain it.
    fn activate(&self) -> bool {
        let mut state = self.state.lock().expect("viewer delivery lock");
        if state.released || state.overflowed {
            return false;
        }
        state.active = true;
        if !state.queue.is_empty() && !state.draining {
            state.draining = true;
            true
        } else {
            false
        }
    }

    /// Queue terminal exit and report whether this caller should drain it.
    fn finish(&self, code: i64) -> ViewerDeliveryAction {
        let mut state = self.state.lock().expect("viewer delivery lock");
        if state.finished || state.released {
            return ViewerDeliveryAction::None;
        }
        state.finished = true;
        state.queue.push_back(ViewerEvent::Exit(code));
        if state.active && !state.draining {
            state.draining = true;
            ViewerDeliveryAction::Drain
        } else {
            ViewerDeliveryAction::None
        }
    }

    /// Invoke the overflow callback once, outside the delivery mutex.
    fn notify_overflow(&self) {
        let callback = {
            let mut state = self.state.lock().expect("viewer delivery lock");
            if !state.overflowed || state.overflow_notified || state.released {
                None
            } else {
                state.overflow_notified = true;
                Some(Arc::clone(&self.on_overflow))
            }
        };
        if let Some(callback) = callback {
            callback();
        }
    }

    /// Stop future callbacks for a detached viewer and discard queued output.
    fn release(&self) {
        let mut state = self.state.lock().expect("viewer delivery lock");
        state.finished = true;
        state.released = true;
        state.queued_bytes = 0;
        state.queue.clear();
    }

    /// Drain callbacks without holding either the delivery or shell lock.
    fn drain(&self) {
        loop {
            let event = {
                let mut state = self.state.lock().expect("viewer delivery lock");
                let Some(event) = state.queue.pop_front() else {
                    state.draining = false;
                    return;
                };
                if let ViewerEvent::Data(chunk) = &event {
                    state.queued_bytes = state.queued_bytes.saturating_sub(chunk.len());
                }
                event
            };
            match event {
                ViewerEvent::Data(chunk) => (self.on_data)(chunk),
                ViewerEvent::Exit(code) => (self.on_exit)(code),
            }
        }
    }
}

/// A per-attachment output sink into the framing path.
struct ViewerSink {
    id: u64,
    delivery: Arc<ViewerDelivery>,
}

/// A fallback $SHELL session: one PTY, a bounded ring, and a viewer set that
/// fans output out to every attachment (multi-viewer, tmux-style).
struct ShellSession {
    control: Arc<dyn PtyControl>,
    inner: Mutex<ShellInner>,
    resize_lock: Mutex<()>,
    banner: Option<Vec<u8>>,
}

struct ShellInner {
    ring: VecDeque<Bytes>,
    ring_size: usize,
    alive: bool,
    exit_code: Option<i64>,
    viewers: Vec<ViewerSink>,
    viewer_grids: HashMap<u64, SizingGrid>,
    applied_grid: Option<SizingGrid>,
}

#[derive(Clone)]
struct Attachment {
    generation: u64,
    gate: Arc<Mutex<()>>,
    closing: Arc<AtomicBool>,
    /// Releases this attachment (detach a viewer, close a control stream,
    /// kill a viewer PTY) — never kills a shared session.
    control: Arc<dyn PtyControl>,
    actor_id: String,
}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
struct SizingKey {
    socket_path: PathBuf,
    surface_id: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SizingGrid {
    cols: u16,
    rows: u16,
}

#[derive(Clone)]
struct SizingViewer {
    control: Arc<dyn ControlHandle>,
    endpoint: Arc<OrderedControlEndpoint>,
    grid: SizingGrid,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ClaimFence {
    /// The target-state generation that reserved this fence. A late worker
    /// from an older generation must not clear a newer fence with the same
    /// viewer and grid.
    generation: u64,
    viewer_id: u64,
    grid: SizingGrid,
    /// Monotonic queue reservation token. A stale worker must not clear a
    /// newer fence even when the viewer id and grid are unchanged.
    token: u64,
    /// Endpoint identity prevents a late worker from touching a replacement
    /// attachment that reused the same viewer id.
    endpoint_ptr: usize,
}

struct OwnerResizeFence {
    generation: u64,
    owner_id: u64,
    grid: SizingGrid,
    endpoint_ptr: usize,
    /// The response for the verification request already queued after the
    /// resize report. `None` means the bounded queue could not accept the
    /// complete pair; input must fail closed until a new generation.
    response: Option<oneshot::Receiver<Option<Value>>>,
}

struct OrderedControlQueue {
    surface_id: i64,
    self_ref: OnceLock<Weak<OrderedControlQueue>>,
    target: OnceLock<Weak<SizingTarget>>,
    coordinator: OnceLock<Weak<TerminalSizing>>,
    generation: AtomicU64,
    state: Mutex<OrderedControlQueueState>,
    wire_pending: Mutex<VecDeque<OrderedControlCommand>>,
    wire_running: AtomicBool,
    closing_running: AtomicBool,
    closing_notify: Notify,
    /// One daemon-acknowledged mutation at a time across every attachment
    /// socket for this terminal. This is the only ordering primitive that can
    /// establish cross-socket resize/claim/input order without a daemon
    /// generation token.
    wire_gate: tokio::sync::Mutex<()>,
}

struct OrderedControlCommand {
    endpoint: Arc<OrderedControlEndpoint>,
    generation: Option<u64>,
    expected_owner: Option<u64>,
    requires_unowned: bool,
    kind: OrderedControlCommandKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct DispatchReservation {
    id: u64,
    generation: u64,
    endpoint_ptr: usize,
}

enum OrderedControlCommandKind {
    Send { command: String, params: Value },
    Request { command: String, params: Value, reply: oneshot::Sender<Option<Value>> },
    Close { reply: oneshot::Sender<bool> },
}

struct OrderedControlQueueState {
    /// Pending resize metadata carries the generation that created it. A
    /// worker may run after a newer viewer mutation, so it must never retag an
    /// old grid with the current generation while flushing the wire command.
    pending_resize: Option<(u64, Arc<OrderedControlEndpoint>, SizingGrid, bool)>,
    /// The last flushed resize is keyed by generation and endpoint identity
    /// as well as viewer id. A stale worker or reconnect that reuses an id
    /// must receive its own fence.
    last_resize: Option<(u64, u64, usize, SizingGrid, bool)>,
    /// A report/claim pair already reserved on the wire for a candidate.
    /// `apply_target` consumes this marker instead of queueing a duplicate
    /// pair. A failed verified claim clears the marker before a real retry.
    claim_fence: Option<ClaimFence>,
    /// A non-claim owner resize and its verification request were reserved as
    /// one adjacent wire batch. Input may append after this pair, but never
    /// between the report and request. A missing response marks QueueFull.
    owner_resize_fence: Option<OwnerResizeFence>,
    /// Endpoints removed from the target but not yet acknowledged by the
    /// daemon. A new explicit claim must wait for every old transport's
    /// ordered close barrier before it can write authority commands.
    closing: Vec<Arc<OrderedControlEndpoint>>,
    /// Close commands are inserted at detach time, before later input or
    /// sizing commands. Keep their replies here so the close worker can clear
    /// the barrier after the daemon acknowledges each FIFO close.
    closing_waiters: Vec<(usize, oneshot::Receiver<bool>)>,
    /// A failed close barrier permanently freezes this target generation.
    /// The daemon gave no proof that old-socket writes are ordered before a
    /// later command, so new input/claims must fail until the target is
    /// retired and recreated.
    closing_failed: bool,
    /// Close replies removed by the barrier worker but not yet completed.
    /// Input may be queued behind these already-enqueued FIFO closes.
    closing_inflight: Vec<usize>,
    /// The command currently reserved by the wire actor. The reservation is
    /// the linearization point for a daemon mutation: a leave/update that
    /// acquires the queue state lock after this point is ordered after the
    /// reserved command, even if the control call itself awaits a reply.
    dispatching: Option<DispatchReservation>,
    next_dispatch_id: u64,
    next_claim_token: u64,
    worker_running: bool,
    closed: bool,
}

impl OrderedControlQueue {
    fn new(surface_id: i64) -> Arc<Self> {
        let queue = Arc::new(Self {
            surface_id,
            self_ref: OnceLock::new(),
            target: OnceLock::new(),
            coordinator: OnceLock::new(),
            generation: AtomicU64::new(1),
            state: Mutex::new(OrderedControlQueueState {
                pending_resize: None,
                last_resize: None,
                claim_fence: None,
                owner_resize_fence: None,
                closing: Vec::new(),
                closing_waiters: Vec::new(),
                closing_failed: false,
                closing_inflight: Vec::new(),
                dispatching: None,
                next_dispatch_id: 0,
                next_claim_token: 0,
                worker_running: false,
                closed: false,
            }),
            wire_pending: Mutex::new(VecDeque::new()),
            wire_running: AtomicBool::new(false),
            closing_running: AtomicBool::new(false),
            closing_notify: Notify::new(),
            wire_gate: tokio::sync::Mutex::new(()),
        });
        let _ = queue.self_ref.set(Arc::downgrade(&queue));
        queue
    }

    fn bind_target(&self, target: &Arc<SizingTarget>, coordinator: &Arc<TerminalSizing>) {
        let _ = self.target.set(Arc::downgrade(target));
        let _ = self.coordinator.set(Arc::downgrade(coordinator));
    }

    fn current_generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    /// Return whether every detached endpoint already has a FIFO close
    /// command registered with the wire actor. A queued or in-flight close is
    /// enough: later commands are appended after that command, while a close
    /// that could not fit in the bounded queue must block new mutations until
    /// it can be retried.
    fn close_barrier_ready_locked(&self, state: &OrderedControlQueueState) -> bool {
        state.closing.iter().all(|endpoint| {
            let pointer = endpoint_ptr(endpoint);
            state.closing_waiters.iter().any(|(current, _)| *current == pointer)
                || state.closing_inflight.contains(&pointer)
        })
    }

    fn endpoint(
        self: &Arc<Self>,
        viewer_id: u64,
        control: Arc<dyn ControlHandle>,
    ) -> Arc<OrderedControlEndpoint> {
        Arc::new(OrderedControlEndpoint {
            queue: Arc::downgrade(self),
            viewer_id,
            control,
            active: AtomicBool::new(true),
            failure_handler: Mutex::new(None),
        })
    }

    /// Queue a resize while the caller already owns the queue lock. This is
    /// used by owner-loss transitions: the caller can hold this lock across
    /// the ownership update, so input cannot pass between the loss decision
    /// and the survivor's report/claim fence.
    fn enqueue_resize_locked(
        &self,
        state: &mut OrderedControlQueueState,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        claim: bool,
    ) -> bool {
        if state.closed
            || state.closing_failed
            || !self.close_barrier_ready_locked(state)
            || !endpoint.is_active()
        {
            return false;
        }
        // A survivor claim is an ownership reservation, not a best-effort
        // resize. Do not let an older owner update replace its report/claim
        // while the candidate worker is verifying authority.
        if !claim && state.claim_fence.is_some() {
            return false;
        }
        // A failed claim must be retried even when the viewer reports the
        // same grid again. Non-claim owner updates can safely deduplicate
        // an already-enqueued grid.
        if !claim
            && state.pending_resize.is_none()
            && state.last_resize
                == Some((
                    self.current_generation(),
                    endpoint.viewer_id,
                    endpoint_ptr(endpoint),
                    grid,
                    false,
                ))
        {
            return false;
        }
        state.pending_resize = Some((self.current_generation(), Arc::clone(endpoint), grid, claim));
        if state.worker_running {
            return false;
        }
        state.worker_running = true;
        // Establish the first report/claim in the control writer before the
        // caller can admit input. The whole pair is accepted under one
        // pending-queue lock; a full queue leaves state.pending_resize intact
        // and does not advance last_resize or claim_fence.
        if self.flush_resize_locked(state) {
            true
        } else {
            state.worker_running = false;
            // A full bounded wire queue is a deterministic transition
            // failure. Drop the unsent batch and leave ownership frozen; the
            // next explicit viewer event may establish a fresh generation.
            if state.pending_resize.as_ref().is_some_and(|(_, _, _, pending_claim)| *pending_claim)
            {
                state.claim_fence = None;
            }
            state.pending_resize = None;
            false
        }
    }

    /// Reserve a non-claim owner resize and its verification request as one
    /// adjacent wire batch. The queue lock remains held while both commands
    /// are appended, so input cannot enter between the report and request.
    /// `response == None` is a visible QueueFull fence: the caller has no
    /// request id to report and must fail this generation closed.
    fn enqueue_owner_resize_batch_locked(
        &self,
        state: &mut OrderedControlQueueState,
        endpoint: &Arc<OrderedControlEndpoint>,
        owner_id: u64,
        grid: SizingGrid,
        generation: u64,
    ) -> (bool, bool) {
        if state.closed
            || state.closing_failed
            || !self.close_barrier_ready_locked(state)
            || self.current_generation() != generation
            || !endpoint.is_active()
        {
            return (false, false);
        }
        if state.claim_fence.is_some() {
            return (false, false);
        }
        if let Some(fence) = state.owner_resize_fence.take() {
            if fence.generation == generation
                && fence.owner_id == owner_id
                && fence.grid == grid
                && fence.endpoint_ptr == endpoint_ptr(endpoint)
            {
                state.owner_resize_fence = Some(fence);
                return (true, false);
            }
            // A newer generation supersedes the old verification response.
            // Its queued command carries the old generation and will be
            // rejected by the wire actor; dropping this receiver prevents a
            // stale worker from committing authority.
        }
        if state
            .pending_resize
            .as_ref()
            .is_some_and(|(_, pending, _, claim)| *claim || !Arc::ptr_eq(pending, endpoint))
        {
            return (false, false);
        }

        let mut pending = self.wire_pending.lock().expect("ordered control pending lock");
        if pending.len().saturating_add(2) > MAX_ORDERED_CONTROL_COMMANDS {
            state.pending_resize = None;
            state.owner_resize_fence = Some(OwnerResizeFence {
                generation,
                owner_id,
                grid,
                endpoint_ptr: endpoint_ptr(endpoint),
                response: None,
            });
            return (true, false);
        }

        // The pending metadata has not reached the wire yet. Replace it with
        // this latest report and append the verification request immediately
        // after it. Both commands are accepted under the same queue lock.
        state.pending_resize = None;
        let (reply, response) = oneshot::channel();
        pending.push_back(OrderedControlCommand {
            endpoint: Arc::clone(endpoint),
            generation: Some(generation),
            expected_owner: Some(owner_id),
            requires_unowned: false,
            kind: OrderedControlCommandKind::Send {
                command: "resize-surface".to_owned(),
                params: json!({
                    "surface": self.surface_id,
                    "cols": grid.cols,
                    "rows": grid.rows,
                }),
            },
        });
        pending.push_back(OrderedControlCommand {
            endpoint: Arc::clone(endpoint),
            generation: Some(generation),
            expected_owner: Some(owner_id),
            requires_unowned: false,
            kind: OrderedControlCommandKind::Request {
                command: "resize-surface".to_owned(),
                params: json!({
                    "surface": self.surface_id,
                    "cols": grid.cols,
                    "rows": grid.rows,
                }),
                reply,
            },
        });
        drop(pending);
        state.last_resize = Some((generation, owner_id, endpoint_ptr(endpoint), grid, false));
        state.owner_resize_fence = Some(OwnerResizeFence {
            generation,
            owner_id,
            grid,
            endpoint_ptr: endpoint_ptr(endpoint),
            response: Some(response),
        });
        (true, true)
    }

    /// Add one command to the session mutation queue. Callers hold the queue
    /// state lock while deciding which command is canonical; the wire worker
    /// takes ownership of the command before it awaits any daemon response.
    fn enqueue_ordered_locked(
        &self,
        endpoint: &Arc<OrderedControlEndpoint>,
        command: &str,
        params: Value,
    ) -> bool {
        if !endpoint.is_active() {
            return false;
        }
        let mut pending = self.wire_pending.lock().expect("ordered control pending lock");
        if pending.len() >= MAX_ORDERED_CONTROL_COMMANDS {
            return false;
        }
        pending.push_back(OrderedControlCommand {
            endpoint: Arc::clone(endpoint),
            generation: Some(self.current_generation()),
            expected_owner: None,
            requires_unowned: false,
            kind: OrderedControlCommandKind::Send { command: command.to_owned(), params },
        });
        drop(pending);
        true
    }

    fn start_wire_drain(&self) {
        if self.wire_running.swap(true, Ordering::AcqRel) {
            return;
        }
        let Some(queue) = self.self_ref.get().and_then(Weak::upgrade) else {
            self.wire_running.store(false, Ordering::Release);
            return;
        };
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            // Synchronous test controls have no daemon to acknowledge a
            // barrier. Preserve their observable command log without trying
            // to block on an async response outside Tokio.
            queue.drain_wire_sync();
            return;
        };
        handle.spawn(async move { queue.drain_wire().await });
    }

    /// Retry retired-target removal after the wire actor reaches a true idle
    /// point. A close acknowledgement can wake the close worker before the
    /// wire worker has popped its final command; the later idle callback is
    /// the only safe point at which no post-close command can outlive the
    /// target.
    fn remove_retired_if_idle(&self) {
        if let (Some(coordinator), Some(target)) = (
            self.coordinator.get().and_then(Weak::upgrade),
            self.target.get().and_then(Weak::upgrade),
        ) {
            coordinator.remove_retired_target(&target);
        }
    }

    fn drain_wire_sync(&self) {
        loop {
            let Some(command) =
                self.wire_pending.lock().expect("ordered control pending lock").pop_front()
            else {
                self.wire_running.store(false, Ordering::Release);
                self.remove_retired_if_idle();
                return;
            };
            let endpoint = Arc::clone(&command.endpoint);
            if matches!(&command.kind, OrderedControlCommandKind::Close { .. }) {
                // A close is still dispatched after detach. The endpoint is
                // marked inactive before it enters the closing list so no
                // later input can use it, but the close itself must reach the
                // control even in the synchronous test fallback.
                let OrderedControlCommandKind::Close { reply } = command.kind else {
                    unreachable!("close command kind changed")
                };
                self.deactivate_endpoint(&endpoint);
                endpoint.control.end();
                let _ = reply.send(true);
                continue;
            }
            let reservation = self.reserve_command(&command);
            match command.kind {
                OrderedControlCommandKind::Send { command, params } => {
                    // `reservation` is the actor linearization point. The
                    // endpoint may be marked inactive by a later leave while
                    // this command is in flight, but that leave is ordered
                    // after this already-reserved mutation.
                    if reservation.is_some() {
                        endpoint.control.send(&command, params);
                    }
                }
                OrderedControlCommandKind::Request { command, params, reply } => {
                    if reservation.is_some() {
                        endpoint.control.send(&command, params);
                    } else {
                        let _ = reply.send(None);
                    }
                }
                OrderedControlCommandKind::Close { .. } => unreachable!("close handled above"),
            }
            self.clear_dispatch_reservation(reservation);
        }
    }

    /// Reserve a queued mutation at the last possible point before it is
    /// written. The queue-state lock is the actor gate: every coordinator
    /// mutation takes it before target state, so the final generation/owner/
    /// endpoint check and this reservation are one linearized transition.
    /// Once reserved, a later leave/update is ordered after this command; the
    /// worker must therefore dispatch the reserved command before clearing the
    /// reservation, even if the endpoint has since been marked inactive.
    fn reserve_command(&self, command: &OrderedControlCommand) -> Option<DispatchReservation> {
        let Some(generation) = command.generation else {
            return None;
        };
        let mut queue_state = self.state.lock().expect("ordered control queue lock");
        if queue_state.closed
            || queue_state.closing_failed
            || queue_state.dispatching.is_some()
            || self.current_generation() != generation
            || !command.endpoint.is_active()
        {
            return None;
        }
        let reservation = DispatchReservation {
            id: queue_state.next_dispatch_id,
            generation,
            endpoint_ptr: endpoint_ptr(&command.endpoint),
        };
        let Some(target_slot) = self.target.get() else {
            // Unbound queues are used only by synchronous test controls.
            queue_state.next_dispatch_id = queue_state.next_dispatch_id.wrapping_add(1);
            queue_state.dispatching = Some(reservation);
            return Some(reservation);
        };
        let Some(target) = target_slot.upgrade() else {
            // A bound queue whose target was retired cannot write a late
            // mutation. Reject it instead of treating a dropped target as a
            // valid test queue.
            return None;
        };
        let state = target.state.lock().expect("terminal sizing state lock");
        let current = self.current_generation() == generation
            && target.generation.load(Ordering::Acquire) == generation
            && !state.retired
            && command.expected_owner.is_none_or(|owner| state.owner == Some(owner))
            && (!command.requires_unowned || state.owner.is_none())
            && state.viewers.get(&command.endpoint.viewer_id).is_some_and(|viewer| {
                Arc::ptr_eq(&viewer.endpoint, &command.endpoint) && viewer.endpoint.is_active()
            });
        if current {
            queue_state.next_dispatch_id = queue_state.next_dispatch_id.wrapping_add(1);
            queue_state.dispatching = Some(reservation);
            Some(reservation)
        } else {
            None
        }
    }

    fn clear_dispatch_reservation(&self, reservation: Option<DispatchReservation>) {
        let Some(reservation) = reservation else { return };
        let mut state = self.state.lock().expect("ordered control queue lock");
        if state.dispatching == Some(reservation) {
            state.dispatching = None;
        }
    }

    async fn drain_wire(self: Arc<Self>) {
        loop {
            let Some(command) =
                self.wire_pending.lock().expect("ordered control pending lock").pop_front()
            else {
                self.wire_running.store(false, Ordering::Release);
                // A producer can enqueue after the empty check but before the
                // flag reset. Re-check once and keep one worker alive.
                let pending_after_reset =
                    !self.wire_pending.lock().expect("ordered control pending lock").is_empty();
                if pending_after_reset && !self.wire_running.swap(true, Ordering::AcqRel) {
                    continue;
                }
                self.remove_retired_if_idle();
                // A close that could not fit in the bounded wire queue is
                // retryable, not a successful barrier. Once the queue drains,
                // start the close worker again so a retired target does not
                // depend on a future viewer event to make progress.
                if !pending_after_reset {
                    let retry_close = {
                        let state = self.state.lock().expect("ordered control queue lock");
                        !state.closing.is_empty()
                            && state.closing_waiters.is_empty()
                            && state.closing_inflight.is_empty()
                            && !state.closing_failed
                    };
                    if retry_close {
                        self.schedule_closing();
                    }
                }
                return;
            };
            let endpoint = Arc::clone(&command.endpoint);
            let is_close = matches!(&command.kind, OrderedControlCommandKind::Close { .. });
            let (failed, reservation) = {
                let _gate = self.wire_gate.lock().await;
                let reservation = if is_close { None } else { self.reserve_command(&command) };
                let current = is_close || reservation.is_some();
                let kind = command.kind;
                if !current {
                    match kind {
                        OrderedControlCommandKind::Request { reply, .. } => {
                            let _ = reply.send(None);
                        }
                        OrderedControlCommandKind::Send { .. }
                        | OrderedControlCommandKind::Close { .. } => {}
                    }
                    (false, reservation)
                } else {
                    let failed = match kind {
                        OrderedControlCommandKind::Send { command, params } => {
                            !endpoint.control.ordered_send(&command, params).await
                        }
                        OrderedControlCommandKind::Request { command, params, reply } => {
                            let result = endpoint.control.request(&command, params).await;
                            let failed = result.is_none();
                            let _ = reply.send(result);
                            failed
                        }
                        OrderedControlCommandKind::Close { reply } => {
                            self.deactivate_endpoint(&endpoint);
                            let result = endpoint.control.end_and_wait().await;
                            if !result {
                                // Set the fail-closed bit before the worker
                                // can pop any later command. The close reply
                                // and this state transition are one actor
                                // step; a missing daemon barrier must reject
                                // every following mutation.
                                self.state
                                    .lock()
                                    .expect("ordered control queue lock")
                                    .closing_failed = true;
                            }
                            let _ = reply.send(result);
                            !result
                        }
                    };
                    (failed, reservation)
                }
            };
            self.clear_dispatch_reservation(reservation);
            if failed {
                self.fail_endpoint(&endpoint);
            }
        }
    }

    async fn ordered_request_at(
        &self,
        endpoint: &Arc<OrderedControlEndpoint>,
        command: &str,
        params: Value,
        generation: u64,
        expected_owner: Option<u64>,
        requires_unowned: bool,
    ) -> Option<Value> {
        if !endpoint.is_active() {
            return None;
        }
        let (reply, response) = oneshot::channel();
        // Revalidate and register the request while the coordinator queue
        // state is locked. An update or leave cannot advance the generation
        // between this check and the wire enqueue; the worker repeats the
        // check immediately before dispatch as a second fence.
        let _queue_state = self.state.lock().expect("ordered control queue lock");
        if self.current_generation() != generation
            || !_queue_state.closing.is_empty()
            || _queue_state.closing_failed
        {
            return None;
        }
        if let Some(target) = self.target.get().and_then(Weak::upgrade) {
            if target.generation.load(Ordering::Acquire) != generation {
                return None;
            }
            let state = target.state.lock().expect("terminal sizing state lock");
            if state.retired
                || !state.viewers.get(&endpoint.viewer_id).is_some_and(|viewer| {
                    Arc::ptr_eq(&viewer.endpoint, endpoint) && viewer.endpoint.is_active()
                })
            {
                return None;
            }
        }
        let mut pending = self.wire_pending.lock().expect("ordered control pending lock");
        if pending.len() >= MAX_ORDERED_CONTROL_COMMANDS {
            return None;
        }
        pending.push_back(OrderedControlCommand {
            endpoint: Arc::clone(endpoint),
            generation: Some(generation),
            expected_owner,
            requires_unowned,
            kind: OrderedControlCommandKind::Request { command: command.to_owned(), params, reply },
        });
        drop(pending);
        drop(_queue_state);
        self.start_wire_drain();
        response.await.ok().flatten()
    }

    /// Reserve a report/claim pair for a candidate before its verified worker
    /// round-trip. The marker is separate from ordinary claim enqueues so a
    /// worker-created retry cannot leave stale reservation state behind.
    fn reserve_resize_locked(
        &self,
        state: &mut OrderedControlQueueState,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        generation: u64,
    ) -> bool {
        if state.closed
            || state.closing_failed
            || !self.close_barrier_ready_locked(state)
            || !endpoint.is_active()
        {
            return false;
        }
        {
            let pending = self.wire_pending.lock().expect("ordered control pending lock");
            if pending.len().saturating_add(2) > MAX_ORDERED_CONTROL_COMMANDS {
                // Never reserve a claim that cannot be represented as one
                // complete report+claim batch on the bounded wire queue.
                return false;
            }
        }
        if let Some(fence) = state.claim_fence {
            if fence.viewer_id != endpoint.viewer_id {
                return false;
            }
            if fence.generation != generation
                || fence.grid != grid
                || fence.endpoint_ptr != endpoint_ptr(endpoint)
            {
                // The same viewer advanced the state generation. Replace its
                // old unverified fence with the newer canonical grid rather
                // than leaving the worker stuck behind stale geometry.
                state.claim_fence = None;
                if state
                    .pending_resize
                    .as_ref()
                    .is_some_and(|(_, pending, _, _)| Arc::ptr_eq(pending, endpoint))
                {
                    state.pending_resize = None;
                }
            }
        }
        if state.claim_fence.is_some_and(|fence| {
            fence.generation == generation
                && fence.viewer_id == endpoint.viewer_id
                && fence.grid == grid
                && fence.endpoint_ptr == endpoint_ptr(endpoint)
        }) && state.pending_resize.is_none()
            && state.last_resize
                == Some((
                    self.current_generation(),
                    endpoint.viewer_id,
                    endpoint_ptr(endpoint),
                    grid,
                    true,
                ))
        {
            return false;
        }
        let token = state
            .claim_fence
            .filter(|fence| {
                fence.generation == generation
                    && fence.viewer_id == endpoint.viewer_id
                    && fence.grid == grid
                    && fence.endpoint_ptr == endpoint_ptr(endpoint)
            })
            .map_or_else(
                || {
                    let token = state.next_claim_token;
                    state.next_claim_token = state.next_claim_token.wrapping_add(1);
                    token
                },
                |fence| fence.token,
            );
        state.claim_fence = Some(ClaimFence {
            generation,
            viewer_id: endpoint.viewer_id,
            grid,
            token,
            endpoint_ptr: endpoint_ptr(endpoint),
        });
        self.enqueue_resize_locked(state, endpoint, grid, true)
    }

    /// Drop a claim reservation that no longer names the canonical candidate.
    ///
    /// A failed claim keeps a fence in place so input cannot overtake its
    /// bounded retry. A later join, update, or leave can change either the
    /// candidate viewer or the smallest grid, however. In that case the old
    /// reservation is stale and must not block the new candidate forever.
    /// Callers hold the queue and target-state locks while invoking this
    /// helper, so replacing the reservation is one ordered transition.
    fn clear_stale_claim_fence_locked(
        &self,
        state: &mut OrderedControlQueueState,
        candidate: Option<(u64, u64, SizingGrid, usize)>,
    ) {
        let Some(fence) = state.claim_fence else { return };
        if candidate.is_some_and(|(generation, viewer_id, grid, endpoint_ptr)| {
            generation == fence.generation
                && viewer_id == fence.viewer_id
                && grid == fence.grid
                && endpoint_ptr == fence.endpoint_ptr
        }) {
            return;
        }
        state.claim_fence = None;
        if state.pending_resize.as_ref().is_some_and(|(_, endpoint, _, claim)| {
            *claim
                && endpoint.viewer_id == fence.viewer_id
                && endpoint_ptr(endpoint) == fence.endpoint_ptr
        }) {
            state.pending_resize = None;
        }
    }

    fn start_drain(self: &Arc<Self>, should_start: bool) {
        if !should_start {
            return;
        }
        let queue = Arc::clone(self);
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            queue.drain_sync();
            return;
        };
        handle.spawn(async move { queue.drain_async().await });
    }

    /// Input is emitted only after any pending resize has been flushed under
    /// the same mutex. This is the ordering fence for resize-before-input;
    /// ingress itself never awaits the control reply.
    fn enqueue_input(&self, endpoint: &Arc<OrderedControlEndpoint>, data: &[u8]) {
        let (flushed, accepted) = {
            let mut state = self.state.lock().expect("ordered control queue lock");
            if state.closed || !endpoint.is_active() {
                return;
            }
            // A worker may have retained a resize from an older generation
            // while the viewer updated back to the already-applied grid.
            // Drop that stale metadata before deciding whether input failed;
            // a superseded resize is not a transport failure.
            let stale_pending = self.discard_stale_pending_locked(&mut state);
            self.discard_stale_owner_resize_fence_locked(&mut state);
            let close_ready = state.closing.iter().all(|closing| {
                state.closing_waiters.iter().any(|(pointer, _)| *pointer == endpoint_ptr(closing))
                    || state.closing_inflight.contains(&endpoint_ptr(closing))
            });
            // An explicit replacement claim must have a durable queue fence
            // before input is admitted. If the bounded queue rejected the
            // report/claim pair, fail this attachment instead of letting
            // bytes overtake an authority transition that can never run.
            let claim_requested = self.target.get().and_then(Weak::upgrade).is_some_and(|target| {
                target.state.lock().expect("terminal sizing state lock").claim_requested.is_some()
            });
            let claim_without_fence = claim_requested
                && state.claim_fence.is_none()
                && !state.pending_resize.as_ref().is_some_and(|(_, _, _, claim)| *claim);
            let owner_batch_failed = state.owner_resize_fence.as_ref().is_some_and(|fence| {
                fence.generation == self.current_generation() && fence.response.is_none()
            });
            if state.closing_failed || !close_ready || claim_without_fence || owner_batch_failed {
                (false, false)
            } else {
                let flushed = stale_pending || self.flush_resize_locked(&mut state);
                let accepted = flushed
                    && self.enqueue_ordered_locked(
                        endpoint,
                        "send",
                        json!({ "surface": self.surface_id, "bytes": BASE64.encode(data) }),
                    );
                (flushed, accepted)
            }
        };
        // The queue lock is not held while starting a synchronous fallback or
        // spawning the async wire worker. This keeps the actor lock order
        // queue -> target-state and prevents re-entrant control callbacks.
        if flushed {
            self.start_wire_drain();
        }
        if !flushed || !accepted {
            // A saturated mutation queue must not silently discard input.
            // Fence and detach this generation; a later authenticated
            // attachment can retry on a fresh transport.
            self.fail_endpoint(endpoint);
        }
    }

    fn fail_endpoint(&self, endpoint: &Arc<OrderedControlEndpoint>) {
        let became_inactive = {
            // Endpoint invalidation is part of the same actor transition as
            // reserve_command. A failure cannot flip `active` between the
            // worker's final validation and its reserved dispatch.
            let _state = self.state.lock().expect("ordered control queue lock");
            endpoint.active.swap(false, Ordering::AcqRel)
        };
        if !became_inactive {
            return;
        }
        if let Some(handler) = endpoint.failure_handler() {
            handler();
        }
    }

    /// Mark an endpoint inactive under the queue actor lock. Close commands
    /// are already ordered after all preceding mutations; this helper keeps
    /// their invalidation visible to the same reservation gate.
    fn deactivate_endpoint(&self, endpoint: &Arc<OrderedControlEndpoint>) {
        let _state = self.state.lock().expect("ordered control queue lock");
        endpoint.active.store(false, Ordering::Release);
    }

    /// Insert one FIFO close command while the queue actor lock is held. A
    /// full wire queue leaves the endpoint in `closing` without a waiter; the
    /// close worker retries it later, and input remains ordered behind the
    /// barrier rather than overtaking it.
    fn enqueue_close_locked(
        &self,
        state: &mut OrderedControlQueueState,
        endpoint: &Arc<OrderedControlEndpoint>,
    ) -> bool {
        let pointer = endpoint_ptr(endpoint);
        if state.closing_waiters.iter().any(|(current, _)| *current == pointer) {
            return true;
        }
        let mut pending = self.wire_pending.lock().expect("ordered control pending lock");
        if pending.len() >= MAX_ORDERED_CONTROL_COMMANDS {
            return false;
        }
        let (reply, response) = oneshot::channel();
        pending.push_back(OrderedControlCommand {
            endpoint: Arc::clone(endpoint),
            generation: None,
            expected_owner: None,
            requires_unowned: false,
            kind: OrderedControlCommandKind::Close { reply },
        });
        state.closing_waiters.push((pointer, response));
        true
    }

    /// Retry a close that could not fit in the bounded wire queue at detach.
    fn enqueue_close_for_retry(&self, endpoint: &Arc<OrderedControlEndpoint>) -> bool {
        let mut state = self.state.lock().expect("ordered control queue lock");
        if state.closed || !state.closing.iter().any(|current| Arc::ptr_eq(current, endpoint)) {
            return false;
        }
        self.enqueue_close_locked(&mut state, endpoint)
    }

    /// Remove one endpoint while the caller already owns the queue lock. The
    /// pointer check prevents a late leave from clearing a replacement that
    /// reused the same viewer ID.
    fn detach_locked(
        &self,
        state: &mut OrderedControlQueueState,
        endpoint: &Arc<OrderedControlEndpoint>,
    ) {
        // Invalidate the transport before removing its viewer state. This
        // closes the ingress race where a caller passes the active check just
        // as leave commits; the close command is inserted in FIFO before any
        // later input, and drain_closing waits for its acknowledgement.
        endpoint.active.store(false, Ordering::Release);
        if state
            .pending_resize
            .as_ref()
            .is_some_and(|(_, current, _, _)| Arc::ptr_eq(current, endpoint))
        {
            state.pending_resize = None;
        }
        if state.claim_fence.is_some_and(|fence| {
            fence.viewer_id == endpoint.viewer_id && fence.endpoint_ptr == endpoint_ptr(endpoint)
        }) {
            state.claim_fence = None;
        }
        if state.owner_resize_fence.as_ref().is_some_and(|fence| {
            fence.owner_id == endpoint.viewer_id && fence.endpoint_ptr == endpoint_ptr(endpoint)
        }) {
            // The queued request belongs to the detached generation. Drop its
            // waiter before the FIFO close is appended so a late response
            // cannot commit authority after detach.
            state.owner_resize_fence = None;
        }
        if !state.closing.iter().any(|current| Arc::ptr_eq(current, endpoint)) {
            state.closing.push(Arc::clone(endpoint));
        }
        let _ = self.enqueue_close_locked(state, endpoint);
    }

    fn close_locked(&self, state: &mut OrderedControlQueueState) {
        state.closed = true;
        state.pending_resize = None;
        state.claim_fence = None;
        state.owner_resize_fence = None;
        state.closing.clear();
        state.closing_waiters.clear();
        state.closing_inflight.clear();
        state.closing_failed = false;
    }

    /// Wait for the daemon-acknowledged close barrier of every endpoint that
    /// was removed from this target. The queue lock is never held while an
    /// endpoint sends its identify barrier or waits for the response.
    async fn wait_for_closing(&self) -> bool {
        if self.state.lock().expect("ordered control queue lock").closing_failed {
            return false;
        }
        let notified = self.closing_notify.notified();
        if self
            .closing_running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            notified.await;
            let state = self.state.lock().expect("ordered control queue lock");
            return state.closing.is_empty() && !state.closing_failed;
        }
        let completed = self.drain_closing().await;
        self.closing_running.store(false, Ordering::Release);
        self.closing_notify.notify_waiters();
        if !completed && !self.state.lock().expect("ordered control queue lock").closing_failed {
            // If the bounded wire queue was full, retry once the current
            // worker has drained it. The wire worker also performs this check
            // when it reaches an empty queue; this call closes the race where
            // it finished while this waiter still owned `closing_running`.
            self.schedule_closing();
        }
        completed
    }

    fn schedule_closing(self: &Arc<Self>) {
        if self
            .closing_running
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return;
        }
        let queue = Arc::clone(self);
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            queue.closing_running.store(false, Ordering::Release);
            return;
        };
        handle.spawn(async move {
            let completed = queue.drain_closing().await;
            queue.closing_running.store(false, Ordering::Release);
            queue.closing_notify.notify_waiters();
            if let (Some(coordinator), Some(target)) = (
                queue.coordinator.get().and_then(Weak::upgrade),
                queue.target.get().and_then(Weak::upgrade),
            ) {
                if completed {
                    // A pending survivor resize may have been held while the
                    // detached endpoint's close queue was full. Reconcile
                    // it only after the daemon-acknowledged close barrier.
                    coordinator.request_reconcile(Arc::clone(&target));
                }
                coordinator.remove_retired_target(&target);
            }
        });
    }

    async fn drain_closing(&self) -> bool {
        loop {
            let next_waiter = {
                let mut state = self.state.lock().expect("ordered control queue lock");
                if state.closing.is_empty() {
                    return true;
                }
                if let Some(waiter) = state.closing_waiters.pop() {
                    state.closing_inflight.push(waiter.0);
                    Some(waiter)
                } else {
                    let endpoint = state.closing.first().cloned();
                    drop(state);
                    let Some(endpoint) = endpoint else { return true };
                    if !self.enqueue_close_for_retry(&endpoint) {
                        // The bounded wire queue is full or the target was
                        // retired. Keep `closing` non-empty so authority
                        // remains frozen. A later explicit event retries the
                        // close once the bounded queue has drained.
                        return false;
                    }
                    self.start_wire_drain();
                    continue;
                }
            };
            let Some((pointer, response)) = next_waiter else { continue };
            self.start_wire_drain();
            if !response.await.unwrap_or(false) {
                // No daemon-observed barrier means no later authority command
                // is safe. Leave this endpoint in `closing` and freeze.
                let mut state = self.state.lock().expect("ordered control queue lock");
                state.closing_inflight.retain(|current| *current != pointer);
                state.closing_failed = true;
                return false;
            }
            let mut state = self.state.lock().expect("ordered control queue lock");
            state.closing_inflight.retain(|current| *current != pointer);
            state.closing.retain(|endpoint| endpoint_ptr(endpoint) != pointer);
        }
    }

    fn drain_sync(&self) {
        let flushed = {
            let mut state = self.state.lock().expect("ordered control queue lock");
            let flushed = if state.closing_failed || !self.close_barrier_ready_locked(&state) {
                false
            } else {
                self.flush_resize_locked(&mut state)
            };
            state.worker_running = false;
            flushed
        };
        if flushed {
            self.start_wire_drain();
        }
    }

    async fn drain_async(self: Arc<Self>) {
        loop {
            let (again, flushed) = {
                let mut state = self.state.lock().expect("ordered control queue lock");
                if state.closed {
                    state.worker_running = false;
                    (false, false)
                } else if state.closing_failed || !self.close_barrier_ready_locked(&state) {
                    // Keep the pending resize and claim fence intact while a
                    // detached endpoint's FIFO close is queued or retrying.
                    // The close worker requests a fresh reconcile after its
                    // daemon acknowledgement.
                    state.worker_running = false;
                    (false, false)
                } else if state.pending_resize.is_some() {
                    if self.flush_resize_locked(&mut state) {
                        (true, true)
                    } else {
                        if state.pending_resize.as_ref().is_some_and(|(_, _, _, claim)| *claim) {
                            state.claim_fence = None;
                        }
                        state.pending_resize = None;
                        state.worker_running = false;
                        (false, false)
                    }
                } else {
                    state.worker_running = false;
                    (false, false)
                }
            };
            if flushed {
                self.start_wire_drain();
            }
            if !again {
                return;
            }
            tokio::task::yield_now().await;
        }
    }

    fn flush_resize_locked(&self, state: &mut OrderedControlQueueState) -> bool {
        let Some((generation, endpoint, grid, claim)) = state.pending_resize.clone() else {
            return true;
        };
        if generation != self.current_generation() {
            // A newer state transition superseded this worker's grid. Do not
            // retag the old command with the current generation.
            state.pending_resize = None;
            if claim {
                state.claim_fence = None;
            }
            return false;
        }
        if !endpoint.is_active() {
            state.pending_resize = None;
            return false;
        }
        let count = if claim { 2 } else { 1 };
        let mut pending = self.wire_pending.lock().expect("ordered control pending lock");
        if pending.len().saturating_add(count) > MAX_ORDERED_CONTROL_COMMANDS {
            // Do not consume the pending state or advance last_resize when a
            // complete command set cannot fit. The caller freezes/retries on
            // the next viewer event; partial report/claim pairs are invalid.
            return false;
        }
        let (generation, endpoint, grid, claim) =
            state.pending_resize.take().expect("pending resize");
        pending.push_back(OrderedControlCommand {
            endpoint: Arc::clone(&endpoint),
            generation: Some(generation),
            expected_owner: (!claim).then_some(endpoint.viewer_id),
            requires_unowned: claim,
            kind: OrderedControlCommandKind::Send {
                command: "resize-surface".to_owned(),
                params: json!({
                    "surface": self.surface_id,
                    "cols": grid.cols,
                    "rows": grid.rows,
                }),
            },
        });
        if claim {
            pending.push_back(OrderedControlCommand {
                endpoint: Arc::clone(&endpoint),
                generation: Some(generation),
                expected_owner: (!claim).then_some(endpoint.viewer_id),
                requires_unowned: claim,
                kind: OrderedControlCommandKind::Send {
                    command: "set-client-sizing".to_owned(),
                    params: json!({
                        "surface": self.surface_id,
                        "enabled": true,
                        "exclusive": true,
                    }),
                },
            });
        }
        drop(pending);
        state.last_resize =
            Some((generation, endpoint.viewer_id, endpoint_ptr(&endpoint), grid, claim));
        // The caller starts the wire worker after releasing `state`; starting
        // a synchronous fallback while this lock is held would self-deadlock.
        true
    }

    /// Remove pending resize metadata that belongs to an older state
    /// generation. The caller holds the queue actor lock. Return `true` when
    /// a stale entry was removed so ingress can continue without treating it
    /// as a queue-capacity or transport failure.
    fn discard_stale_pending_locked(&self, state: &mut OrderedControlQueueState) -> bool {
        let Some((generation, endpoint, _, claim)) = state.pending_resize.as_ref() else {
            return false;
        };
        if *generation == self.current_generation() {
            return false;
        }
        let pending_generation = *generation;
        let pending_endpoint = endpoint_ptr(endpoint);
        let pending_claim = *claim;
        state.pending_resize = None;
        if pending_claim
            && state.claim_fence.is_some_and(|fence| {
                fence.generation == pending_generation && fence.endpoint_ptr == pending_endpoint
            })
        {
            state.claim_fence = None;
        }
        true
    }

    fn discard_stale_owner_resize_fence_locked(&self, state: &mut OrderedControlQueueState) {
        if state
            .owner_resize_fence
            .as_ref()
            .is_some_and(|fence| fence.generation != self.current_generation())
        {
            state.owner_resize_fence = None;
        }
    }
}

struct OrderedControlEndpoint {
    queue: Weak<OrderedControlQueue>,
    viewer_id: u64,
    control: Arc<dyn ControlHandle>,
    active: AtomicBool,
    failure_handler: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

fn endpoint_ptr(endpoint: &Arc<OrderedControlEndpoint>) -> usize {
    Arc::as_ptr(endpoint) as usize
}

impl OrderedControlEndpoint {
    fn is_active(&self) -> bool {
        self.active.load(Ordering::Acquire)
    }

    fn set_failure_handler(&self, handler: Arc<dyn Fn() + Send + Sync>) {
        *self.failure_handler.lock().expect("ordered control failure lock") = Some(handler);
    }

    fn failure_handler(&self) -> Option<Arc<dyn Fn() + Send + Sync>> {
        self.failure_handler.lock().expect("ordered control failure lock").clone()
    }

    fn enqueue_input(self: &Arc<Self>, data: &[u8]) {
        if let Some(queue) = self.queue.upgrade() {
            queue.enqueue_input(self, data);
        }
    }

    #[cfg(test)]
    fn flush_before_request(self: &Arc<Self>) {
        if let Some(queue) = self.queue.upgrade() {
            let flushed = {
                let mut state = queue.state.lock().expect("ordered control queue lock");
                queue.flush_resize_locked(&mut state)
            };
            if flushed {
                queue.start_wire_drain();
            }
        }
    }
}

struct SizingTargetState {
    surface_id: i64,
    viewers: HashMap<u64, SizingViewer>,
    owner: Option<u64>,
    /// One newly attached viewer may make an explicit first claim. After an
    /// owner leaves, disconnects, or loses a claim, this remains `None` until
    /// another attachment joins. The relay never elects an existing survivor
    /// by itself because the core daemon has no generation token for that
    /// cross-socket hand-off.
    claim_requested: Option<(u64, usize)>,
    applied: Option<SizingGrid>,
    retired: bool,
}

enum CandidateRequestOutcome {
    Stale,
    Reply(Option<Value>),
}

enum CandidatePrepareOutcome {
    Stale,
    QueueFull,
    Ready(u64),
}

enum OwnerResizeRequestOutcome {
    Stale,
    QueueFull,
    Reply(Option<Value>),
}

struct SizingTarget {
    key: SizingKey,
    queue: Arc<OrderedControlQueue>,
    state: Mutex<SizingTargetState>,
    /// Lock-free generation snapshot used while the queue and target-state
    /// locks are held. This avoids taking the retry mutex during a stale
    /// worker commit and keeps lock ordering consistent.
    generation: AtomicU64,
    requested: AtomicBool,
    worker_running: AtomicBool,
    /// Serializes the worker hand-off with request registration. Without
    /// this lock a new resize can start a second worker after the old worker
    /// clears `worker_running` but before it drains waiters.
    transition: Mutex<()>,
    waiters: Mutex<Vec<oneshot::Sender<()>>>,
}

/// Return the viewer that has made an explicit relay-side claim request.
/// Existing survivors are never selected implicitly: the core daemon does not
/// provide a generation token that could order a cross-socket hand-off.
fn candidate_viewer_id(state: &SizingTargetState) -> Option<u64> {
    let (viewer_id, requested_endpoint_ptr) = state.claim_requested?;
    state.viewers.get(&viewer_id).and_then(|viewer| {
        (endpoint_ptr(&viewer.endpoint) == requested_endpoint_ptr).then_some(viewer_id)
    })
}

/// Coordinates geometry ownership for all raw terminal viewers on this relay.
///
/// Protocol 10 daemons accept a terminal resize only from the connection that
/// successfully claimed `set-client-sizing`. Requests are asynchronous, so a
/// single bounded worker per surface serializes report, claim, and resize
/// round-trips while coalescing bursts of viewer updates.
struct TerminalSizing {
    targets: Mutex<HashMap<SizingKey, Arc<SizingTarget>>>,
}

impl TerminalSizing {
    fn new() -> Arc<Self> {
        Arc::new(Self { targets: Mutex::new(HashMap::new()) })
    }

    /// Advance the viewer state generation after an external join/update/
    /// leave. The generation rejects late explicit-claim replies; it never
    /// elects a replacement viewer.
    fn advance_generation(&self, target: &Arc<SizingTarget>) -> u64 {
        let generation = target.generation.load(Ordering::Relaxed).saturating_add(1);
        target.generation.store(generation, Ordering::Release);
        target.queue.generation.store(generation, Ordering::Release);
        generation
    }

    fn current_generation(target: &Arc<SizingTarget>) -> u64 {
        target.generation.load(Ordering::Acquire)
    }

    /// Abandon a failed or stale explicit claim. The relay leaves the core
    /// geometry frozen and waits for a new attachment to claim it. In
    /// particular, this method never schedules a survivor or a delayed retry.
    fn abandon_candidate_request(
        &self,
        target: &Arc<SizingTarget>,
        viewer_id: u64,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        generation: u64,
        token: u64,
    ) {
        let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
        let mut state = target.state.lock().expect("terminal sizing state lock");
        if queue_state.claim_fence
            == Some(ClaimFence {
                generation,
                viewer_id,
                grid,
                token,
                endpoint_ptr: endpoint_ptr(endpoint),
            })
        {
            queue_state.claim_fence = None;
        }
        if state
            .claim_requested
            .is_some_and(|(id, ptr)| id == viewer_id && ptr == endpoint_ptr(endpoint))
        {
            state.claim_requested = None;
        }
    }

    /// Check the endpoint and viewer generation immediately before a
    /// candidate request is started. The endpoint is closed by leave and by
    /// timeout handling, so a stale worker cannot start a new request after a
    /// replacement has been reserved.
    fn candidate_is_current(
        &self,
        target: &Arc<SizingTarget>,
        viewer_id: u64,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        generation: u64,
    ) -> bool {
        // Do not hold the retry lock while taking target state. Generation
        // transitions may run inside the queue/state critical section; the
        // final endpoint and fence identity checks below handle a concurrent
        // transition without creating a lock inversion.
        if Self::current_generation(target) != generation {
            return false;
        }
        let state = target.state.lock().expect("terminal sizing state lock");
        Self::current_generation(target) == generation
            && !state.retired
            && state.owner.is_none()
            && candidate_viewer_id(&state) == Some(viewer_id)
            && smallest_sizing_grid(&state.viewers) == Some(grid)
            && state.viewers.get(&viewer_id).is_some_and(|viewer| {
                viewer.endpoint.is_active() && Arc::ptr_eq(&viewer.endpoint, endpoint)
            })
    }

    async fn candidate_request(
        &self,
        target: &Arc<SizingTarget>,
        viewer_id: u64,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        generation: u64,
        command: &str,
        params: Value,
    ) -> CandidateRequestOutcome {
        if !self.candidate_is_current(target, viewer_id, endpoint, grid, generation) {
            return CandidateRequestOutcome::Stale;
        }
        let response = target
            .queue
            .ordered_request_at(endpoint, command, params, generation, None, true)
            .await;
        // `None` is used both for a transport failure and for a command that
        // the ordered actor rejected as stale.  Do not turn the latter into
        // `leave_endpoint`: a newer generation may already own this viewer
        // identity and must not be detached by an old candidate worker.
        if response.is_none()
            && !self.candidate_is_current(target, viewer_id, endpoint, grid, generation)
        {
            CandidateRequestOutcome::Stale
        } else {
            CandidateRequestOutcome::Reply(response)
        }
    }

    fn join(
        self: &Arc<Self>,
        key: SizingKey,
        viewer_id: u64,
        surface_id: i64,
        control: Arc<dyn ControlHandle>,
        grid: SizingGrid,
    ) -> Option<oneshot::Receiver<()>> {
        self.join_with_endpoint(key, viewer_id, surface_id, control, grid)
            .map(|(waiter, _endpoint)| waiter)
    }

    /// Join and return the exact endpoint registered for this attachment.
    /// Callers that own a lease must retain this identity: a later reconnect
    /// may reuse the viewer id, and an old lease must not update or remove the
    /// replacement endpoint.
    fn join_with_endpoint(
        self: &Arc<Self>,
        key: SizingKey,
        viewer_id: u64,
        surface_id: i64,
        control: Arc<dyn ControlHandle>,
        grid: SizingGrid,
    ) -> Option<(oneshot::Receiver<()>, Arc<OrderedControlEndpoint>)> {
        let (target, joined_endpoint, should_start) = {
            let mut targets = self.targets.lock().expect("terminal sizing targets lock");
            let target_key = key.clone();
            let target = targets.entry(key).or_insert_with(|| {
                let queue = OrderedControlQueue::new(surface_id);
                Arc::new(SizingTarget {
                    key: target_key,
                    queue,
                    state: Mutex::new(SizingTargetState {
                        surface_id,
                        viewers: HashMap::new(),
                        owner: None,
                        claim_requested: None,
                        applied: None,
                        retired: false,
                    }),
                    generation: AtomicU64::new(1),
                    requested: AtomicBool::new(false),
                    worker_running: AtomicBool::new(false),
                    transition: Mutex::new(()),
                    waiters: Mutex::new(Vec::new()),
                })
            });
            let target = Arc::clone(target);
            target.queue.bind_target(&target, self);
            // Keep the map lock while changing the target state. This makes a
            // final leave and a concurrent join observe one linear order and
            // prevents a newly joined viewer from being removed with a
            // retired target.
            let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
            let mut state = target.state.lock().expect("terminal sizing state lock");
            if queue_state.closing_failed
                || (state.retired && !target.queue.close_barrier_ready_locked(&queue_state))
            {
                // The old daemon transport did not acknowledge its close.
                // Do not resurrect this target or attach a new socket to an
                // authority whose cross-socket order is unknown. A queued or
                // in-flight close is safe to join behind; a close that could
                // not fit in the bounded queue must be retried before any
                // replacement can enter the target.
                return None;
            }
            state.retired = false;
            if let Some(previous) = state.viewers.remove(&viewer_id) {
                target.queue.detach_locked(&mut queue_state, &previous.endpoint);
                if state.owner == Some(viewer_id) {
                    state.owner = None;
                }
            }
            let endpoint = target.queue.endpoint(viewer_id, Arc::clone(&control));
            let endpoint_weak = Arc::downgrade(&endpoint);
            let coordinator_weak = Arc::downgrade(self);
            let callback_key = target.key.clone();
            endpoint.set_failure_handler(Arc::new(move || {
                if let (Some(coordinator), Some(endpoint)) =
                    (coordinator_weak.upgrade(), endpoint_weak.upgrade())
                {
                    coordinator.leave_endpoint(&callback_key, viewer_id, &endpoint);
                }
            }));
            state
                .viewers
                .insert(viewer_id, SizingViewer { control, endpoint: Arc::clone(&endpoint), grid });
            let generation = self.advance_generation(&target);
            // A new attachment is the only relay-local event that may make an
            // explicit claim. Existing survivors are not selected after an
            // owner loss or refusal.
            let immediate_claim = state.owner.is_none();
            state.claim_requested = immediate_claim.then_some((viewer_id, endpoint_ptr(&endpoint)));
            let owner_grid = smallest_sizing_grid(&state.viewers);
            let owner_id =
                if !immediate_claim && state.applied != owner_grid { state.owner } else { None };
            let owner_endpoint = owner_id
                .and_then(|id| state.viewers.get(&id).map(|viewer| Arc::clone(&viewer.endpoint)));
            let mut should_start = false;
            // Reserve the canonical command while the join mutation still
            // holds queue -> target-state. A later input cannot enter the
            // queue between the generation bump and this enqueue. If an old
            // endpoint is closing, the FIFO close is already in the wire
            // queue; append the new report/claim after it, so replacement
            // input cannot overtake the authority command.
            if let (Some(endpoint), Some(owner_id), Some(grid)) =
                (owner_endpoint.as_ref(), owner_id, owner_grid)
            {
                let (_, start) = self.enqueue_update_locked(
                    &target,
                    &mut queue_state,
                    &state,
                    owner_id,
                    Some(owner_id),
                    endpoint,
                    grid,
                    false,
                    generation,
                );
                should_start |= start;
            }
            if immediate_claim {
                if let Some(grid) = owner_grid {
                    let (_, start) = self.enqueue_update_locked(
                        &target,
                        &mut queue_state,
                        &state,
                        viewer_id,
                        None,
                        &endpoint,
                        grid,
                        true,
                        generation,
                    );
                    should_start |= start;
                }
            }
            (target, Arc::clone(&endpoint), should_start)
        };
        if should_start {
            target.queue.start_wire_drain();
            target.queue.start_drain(true);
        }
        target.queue.schedule_closing();
        Some((self.request_reconcile_wait(target), joined_endpoint))
    }

    fn queue_for(&self, key: &SizingKey, viewer_id: u64) -> Option<Arc<OrderedControlEndpoint>> {
        let target =
            self.targets.lock().expect("terminal sizing targets lock").get(key).cloned()?;
        let state = target.state.lock().expect("terminal sizing state lock");
        state.viewers.get(&viewer_id).map(|viewer| Arc::clone(&viewer.endpoint))
    }

    fn update(self: &Arc<Self>, key: &SizingKey, viewer_id: u64, grid: SizingGrid) {
        self.update_inner(key, viewer_id, None, grid);
    }

    /// Update only the endpoint that owns a lease. A stale lease may retain
    /// the same viewer id after reconnect; pointer identity prevents it from
    /// mutating the replacement viewer's grid.
    fn update_endpoint(
        self: &Arc<Self>,
        key: &SizingKey,
        viewer_id: u64,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
    ) {
        self.update_inner(key, viewer_id, Some(endpoint), grid);
    }

    fn update_inner(
        self: &Arc<Self>,
        key: &SizingKey,
        viewer_id: u64,
        expected_endpoint: Option<&Arc<OrderedControlEndpoint>>,
        grid: SizingGrid,
    ) {
        let target = self.targets.lock().expect("terminal sizing targets lock").get(key).cloned();
        let Some(target) = target else { return };
        let (target, should_start) = {
            // Serialize the state mutation and generation bump with the
            // shared queue fence. The worker snapshots target state under the
            // state lock, so advancing while that lock is held prevents it
            // from observing a new grid under the previous generation.
            let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
            let mut state = target.state.lock().expect("terminal sizing state lock");
            if queue_state.closing_failed {
                return;
            }
            let owner = state.owner;
            let candidate = owner.is_none() && candidate_viewer_id(&state) == Some(viewer_id);
            let endpoint_matches = state.viewers.get(&viewer_id).is_some_and(|viewer| {
                expected_endpoint.is_none_or(|expected| Arc::ptr_eq(&viewer.endpoint, expected))
            });
            if !endpoint_matches {
                return;
            }
            let Some(viewer) = state.viewers.get_mut(&viewer_id) else { return };
            viewer.grid = grid;
            let Some(effective_grid) = smallest_sizing_grid(&state.viewers) else { return };
            let claim = owner.is_none() && candidate;
            let should_enqueue = claim || state.applied != Some(effective_grid);
            let endpoint = if should_enqueue {
                if let Some(owner_id) = owner {
                    state.viewers.get(&owner_id).map(|viewer| Arc::clone(&viewer.endpoint))
                } else if candidate {
                    state.viewers.get(&viewer_id).map(|viewer| Arc::clone(&viewer.endpoint))
                } else {
                    None
                }
            } else {
                None
            };
            let generation = self.advance_generation(&target);
            let endpoint_viewer_id = owner.unwrap_or(viewer_id);
            let should_start = endpoint.map_or(false, |endpoint| {
                self.enqueue_update_locked(
                    &target,
                    &mut queue_state,
                    &state,
                    endpoint_viewer_id,
                    owner,
                    &endpoint,
                    effective_grid,
                    claim,
                    generation,
                )
                .1
            });
            (target, should_start)
        };
        if should_start {
            target.queue.start_wire_drain();
            target.queue.start_drain(true);
        }
        self.request_reconcile(target);
    }

    fn leave(self: &Arc<Self>, key: &SizingKey, viewer_id: u64) {
        self.leave_inner(key, viewer_id, None, None);
    }

    /// Remove a viewer only when the endpoint that was used for the failed
    /// sizing round is still attached. A viewer id can be reused after a
    /// reconnect; pointer identity prevents a late timeout from removing the
    /// healthy replacement.
    fn leave_endpoint(
        self: &Arc<Self>,
        key: &SizingKey,
        viewer_id: u64,
        endpoint: &Arc<OrderedControlEndpoint>,
    ) {
        self.leave_inner(key, viewer_id, Some(endpoint), None);
    }

    /// Remove an endpoint only if the worker's generation is still current.
    /// Timeout/error responses otherwise can detach a healthy same-pointer
    /// endpoint after an update advanced its generation.
    fn leave_endpoint_at_generation(
        self: &Arc<Self>,
        key: &SizingKey,
        viewer_id: u64,
        endpoint: &Arc<OrderedControlEndpoint>,
        generation: u64,
    ) {
        self.leave_inner(key, viewer_id, Some(endpoint), Some(generation));
    }

    fn leave_inner(
        self: &Arc<Self>,
        key: &SizingKey,
        viewer_id: u64,
        expected_endpoint: Option<&Arc<OrderedControlEndpoint>>,
        expected_generation: Option<u64>,
    ) {
        let (target, should_start) = {
            let mut targets = self.targets.lock().expect("terminal sizing targets lock");
            let Some(target) = targets.get(key).cloned() else { return };
            // Keep the queue before state lock order used by input and owner
            // loss. This makes leave a linear transition: after the endpoint
            // is removed, a survivor input cannot pass before its replacement
            // report/claim or owner resize is enqueued.
            let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
            let mut state = target.state.lock().expect("terminal sizing state lock");
            if expected_generation
                .is_some_and(|expected| Self::current_generation(&target) != expected)
            {
                return;
            }
            let Some(current) = state.viewers.get(&viewer_id) else {
                return;
            };
            if expected_endpoint.is_some_and(|expected| !Arc::ptr_eq(&current.endpoint, expected)) {
                return;
            }
            let Some(removed) = state.viewers.remove(&viewer_id) else { return };
            target.queue.detach_locked(&mut queue_state, &removed.endpoint);
            // Close only this attachment. No replacement claim is issued
            // here: the core daemon freezes its current grid until a new
            // attachment makes an explicit claim.
            let removed_owner = state.owner == Some(viewer_id);
            if state
                .claim_requested
                .is_some_and(|(id, ptr)| id == viewer_id && ptr == endpoint_ptr(&removed.endpoint))
            {
                state.claim_requested = None;
            }
            if removed_owner {
                state.owner = None;
                // Preserve `applied`: this is the frozen core geometry. A
                // later attachment must explicitly claim before changing it.
                state.claim_requested = None;
            }
            let generation = self.advance_generation(&target);
            if state.viewers.is_empty() {
                state.retired = true;
                // Keep the retired target until the ordered close command has
                // completed. Removing it here would drop the only coordinator
                // that can fence a late writer.
                (target, false)
            } else {
                let grid = smallest_sizing_grid(&state.viewers);
                target.queue.clear_stale_claim_fence_locked(&mut queue_state, None);
                let should_start = if !target.queue.close_barrier_ready_locked(&queue_state)
                    || queue_state.closing_failed
                {
                    false
                } else if let (Some(owner_id), Some(grid)) = (state.owner, grid) {
                    if let Some(owner) = state.viewers.get(&owner_id)
                        && owner.endpoint.is_active()
                        && state.applied != Some(grid)
                    {
                        target
                            .queue
                            .enqueue_owner_resize_batch_locked(
                                &mut queue_state,
                                &owner.endpoint,
                                owner_id,
                                grid,
                                generation,
                            )
                            .1
                    } else {
                        false
                    }
                } else {
                    false
                };
                (target, should_start)
            }
        };
        if should_start {
            target.queue.start_wire_drain();
        }
        target.queue.start_drain(should_start);
        target.queue.schedule_closing();
        self.request_reconcile(target);
    }

    fn request_reconcile(self: &Arc<Self>, target: Arc<SizingTarget>) {
        self.request_reconcile_with_waiter(target, None);
    }

    fn request_reconcile_wait(
        self: &Arc<Self>,
        target: Arc<SizingTarget>,
    ) -> oneshot::Receiver<()> {
        let (sender, receiver) = oneshot::channel();
        self.request_reconcile_with_waiter(target, Some(sender));
        receiver
    }

    fn request_reconcile_with_waiter(
        self: &Arc<Self>,
        target: Arc<SizingTarget>,
        waiter: Option<oneshot::Sender<()>>,
    ) {
        let should_start = {
            let _transition = target.transition.lock().expect("terminal sizing transition lock");
            if let Some(waiter) = waiter {
                target.waiters.lock().expect("terminal sizing waiters lock").push(waiter);
            }
            target.requested.store(true, Ordering::Release);
            target
                .worker_running
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
        };
        if !should_start {
            return;
        }
        let coordinator = Arc::clone(self);
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            // All production callers are on the relay runtime. Leave the
            // request and its waiters latched so the next viewer event can
            // retry if a test or embedding caller invokes this method outside
            // Tokio. The waiter is an enqueue/worker-turn notification, not a
            // claim-success acknowledgement; callers that need authority
            // must inspect the subsequent wire response.
            let _transition = target.transition.lock().expect("terminal sizing transition lock");
            target.worker_running.store(false, Ordering::Release);
            return;
        };
        handle.spawn(async move {
            coordinator.run_target(target).await;
        });
    }

    async fn run_target(self: Arc<Self>, target: Arc<SizingTarget>) {
        loop {
            let should_apply = {
                let _transition =
                    target.transition.lock().expect("terminal sizing transition lock");
                if target.requested.swap(false, Ordering::AcqRel) {
                    true
                } else {
                    target.worker_running.store(false, Ordering::Release);
                    // Request registration and waiter completion are serialized
                    // by `transition`, so no new request can pass between this
                    // check and the drain. Completion means the worker turn
                    // drained/enqueued; a daemon refusal is retried on the
                    // next viewer event.
                    self.complete_waiters(&target);
                    false
                }
            };
            if !should_apply {
                self.remove_retired_target(&target);
                return;
            }
            self.apply_target(&target).await;
        }
    }

    fn complete_waiters(&self, target: &Arc<SizingTarget>) {
        let waiters =
            std::mem::take(&mut *target.waiters.lock().expect("terminal sizing waiters lock"));
        for waiter in waiters {
            let _ = waiter.send(());
        }
    }

    fn remove_retired_target(&self, target: &Arc<SizingTarget>) {
        // A failed close is permanent for this target. Keep the retired entry
        // in the map so a later join cannot create a new socket generation
        // beside an old transport whose daemon ordering is unknown. The
        // entry is removed only after a successful close and after every wire
        // command/worker has quiesced; process restart is the recovery path
        // for a permanently failed transport.
        let mut targets = self.targets.lock().expect("terminal sizing targets lock");
        let Some(current) = targets.get(&target.key) else { return };
        if !Arc::ptr_eq(current, target) {
            return;
        }
        // Keep the queue -> target-state order used by sizing transitions.
        // Do not hold target state while closing the queue: that would let a
        // concurrent input path deadlock against a concurrent close.
        let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
        let state = target.state.lock().expect("terminal sizing state lock");
        let wire_pending_empty =
            target.queue.wire_pending.lock().expect("ordered control pending lock").is_empty();
        if state.retired
            && state.viewers.is_empty()
            && !target.worker_running.load(Ordering::Acquire)
            && !target.queue.closing_running.load(Ordering::Acquire)
            && !target.queue.wire_running.load(Ordering::Acquire)
            && wire_pending_empty
            && state.closing.is_empty()
            && state.closing_waiters.is_empty()
            && state.closing_inflight.is_empty()
            && state.dispatching.is_none()
        {
            target.queue.close_locked(&mut queue_state);
            targets.remove(&target.key);
        }
    }

    /// Enqueue a viewer update only if the owner/endpoint snapshot is still
    /// current. The queue lock is taken before target state, so an authority
    /// transition cannot let a stale update replace a pending claim.
    fn enqueue_update_if_current(
        &self,
        target: &Arc<SizingTarget>,
        viewer_id: u64,
        expected_owner: Option<u64>,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        claim: bool,
        generation: u64,
    ) -> bool {
        if Self::current_generation(target) != generation {
            return false;
        }
        let (current, should_start) = {
            let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
            let state = target.state.lock().expect("terminal sizing state lock");
            self.enqueue_update_locked(
                target,
                &mut queue_state,
                &state,
                viewer_id,
                expected_owner,
                endpoint,
                grid,
                claim,
                generation,
            )
        };
        if current && should_start {
            // `flush_resize_locked` only appends while the coordinator locks
            // are held. Start the wire worker after those locks are released.
            target.queue.start_wire_drain();
        }
        target.queue.start_drain(should_start);
        current
    }

    /// Validate and reserve a canonical resize while the caller already holds
    /// the queue-state then target-state locks. Keeping the state mutation and
    /// this enqueue in one actor transition prevents input from entering the
    /// wire queue in the generation gap between them.
    fn enqueue_update_locked(
        &self,
        target: &Arc<SizingTarget>,
        queue_state: &mut OrderedControlQueueState,
        state: &SizingTargetState,
        viewer_id: u64,
        expected_owner: Option<u64>,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        claim: bool,
        generation: u64,
    ) -> (bool, bool) {
        if Self::current_generation(target) != generation
            || state.retired
            || state.owner != expected_owner
            || !target.queue.close_barrier_ready_locked(queue_state)
            || queue_state.closing_failed
        {
            // A closing transport is a daemon-order barrier. The caller
            // leaves the state changed but lets the reconcile worker retry
            // after `wait_for_closing` completes; no command may overtake it.
            return (false, false);
        }
        let candidate = if state.owner.is_none() {
            smallest_sizing_grid(&state.viewers)
                .and_then(|current_grid| candidate_viewer_id(state).map(|id| (id, current_grid)))
        } else {
            None
        };
        target.queue.discard_stale_owner_resize_fence_locked(queue_state);
        target.queue.clear_stale_claim_fence_locked(
            queue_state,
            candidate.and_then(|(candidate_id, candidate_grid)| {
                state.viewers.get(&candidate_id).map(|viewer| {
                    (generation, candidate_id, candidate_grid, endpoint_ptr(&viewer.endpoint))
                })
            }),
        );
        let endpoint_current = state.viewers.get(&viewer_id).is_some_and(|viewer| {
            viewer.endpoint.is_active() && Arc::ptr_eq(&viewer.endpoint, endpoint)
        });
        let grid_current = smallest_sizing_grid(&state.viewers) == Some(grid);
        let candidate_current =
            expected_owner.is_none() && candidate_viewer_id(state) == Some(viewer_id);
        let queue_reserved_for_candidate = !claim && queue_state.claim_fence.is_some();
        let valid = endpoint_current
            && grid_current
            && (claim == candidate_current)
            && !queue_reserved_for_candidate;
        if !valid {
            return (false, false);
        }
        let should_start = if claim {
            target.queue.reserve_resize_locked(queue_state, endpoint, grid, generation)
        } else if let Some(owner_id) = expected_owner {
            // Owner reports must reserve their verification request beside the
            // resize. This prevents input from entering after an eager report
            // flush but before `apply_target` can enqueue the request.
            target
                .queue
                .enqueue_owner_resize_batch_locked(
                    queue_state,
                    endpoint,
                    owner_id,
                    grid,
                    generation,
                )
                .1
        } else {
            target.queue.enqueue_resize_locked(queue_state, endpoint, grid, false)
        };
        (true, should_start)
    }

    /// Enqueue the canonical owner resize and its verified request as one
    /// adjacent batch. A queue worker may already own a pending resize; this
    /// method consumes that pending state while the queue and target state
    /// locks are held, then appends the request immediately after it. This is
    /// the owner-side ordering fence: a later input command cannot overtake
    /// the report, even when a worker is between polls.
    async fn owner_resize_request(
        &self,
        target: &Arc<SizingTarget>,
        owner_id: u64,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        generation: u64,
        surface_id: i64,
    ) -> OwnerResizeRequestOutcome {
        if Self::current_generation(target) != generation {
            return OwnerResizeRequestOutcome::Stale;
        }
        let (reply, response) = oneshot::channel();
        let mut prequeued_response: Option<oneshot::Receiver<Option<Value>>> = None;
        let batch: Result<(), OwnerResizeRequestOutcome> = {
            // All coordinator mutations use queue -> target-state order. Do
            // not await while either lock is held; the wire worker performs
            // the daemon call after this atomic enqueue.
            let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
            let mut state = target.state.lock().expect("terminal sizing state lock");
            let endpoint_current = state.viewers.get(&owner_id).is_some_and(|viewer| {
                viewer.endpoint.is_active() && Arc::ptr_eq(&viewer.endpoint, endpoint)
            });
            if Self::current_generation(target) != generation
                || queue_state.closed
                || queue_state.closing_failed
                || state.retired
                || state.owner != Some(owner_id)
                || !endpoint_current
                || smallest_sizing_grid(&state.viewers) != Some(grid)
                || !queue_state.closing.is_empty()
                || queue_state.claim_fence.is_some()
            {
                Err(OwnerResizeRequestOutcome::Stale)
            } else if let Some(mut fence) = queue_state.owner_resize_fence.take() {
                if fence.generation != generation
                    || fence.owner_id != owner_id
                    || fence.grid != grid
                    || fence.endpoint_ptr != endpoint_ptr(endpoint)
                {
                    // A newer generation must not consume an older response
                    // fence. Its queued command carries the old generation
                    // and will be rejected by the wire actor.
                    queue_state.owner_resize_fence = Some(fence);
                    Err(OwnerResizeRequestOutcome::Stale)
                } else if let Some(response) = fence.response.take() {
                    // The update path already appended resize+request as one
                    // adjacent batch. Consume only the response receiver;
                    // input may safely append after the queued request.
                    prequeued_response = Some(response);
                    Ok(())
                } else {
                    // QueueFull is represented by a fence without a reply
                    // receiver. Keep the generation fail-closed.
                    Err(OwnerResizeRequestOutcome::QueueFull)
                }
            } else {
                // A pending resize belongs to this owner queue. It may be
                // stale after a coalesced update, so replace it with the
                // latest grid; the replacement and the verified request are
                // admitted together.
                let pending_resize = queue_state.pending_resize.as_ref();
                let needs_resize = pending_resize.is_some()
                    || queue_state.last_resize
                        != Some((generation, owner_id, endpoint_ptr(endpoint), grid, false));
                let command_count = usize::from(needs_resize) + 1;
                let mut pending =
                    target.queue.wire_pending.lock().expect("ordered control pending lock");
                if pending.len().saturating_add(command_count) > MAX_ORDERED_CONTROL_COMMANDS {
                    // Leave the pending resize and last_resize untouched. The
                    // caller detaches this endpoint, which freezes authority and
                    // clears the unsent batch without allowing partial enqueue.
                    Err(OwnerResizeRequestOutcome::QueueFull)
                } else {
                    if needs_resize {
                        queue_state.pending_resize = None;
                        pending.push_back(OrderedControlCommand {
                            endpoint: Arc::clone(endpoint),
                            generation: Some(generation),
                            expected_owner: Some(owner_id),
                            requires_unowned: false,
                            kind: OrderedControlCommandKind::Send {
                                command: "resize-surface".to_owned(),
                                params: json!({
                                    "surface": surface_id,
                                    "cols": grid.cols,
                                    "rows": grid.rows,
                                }),
                            },
                        });
                        queue_state.last_resize =
                            Some((generation, owner_id, endpoint_ptr(endpoint), grid, false));
                    }
                    pending.push_back(OrderedControlCommand {
                        endpoint: Arc::clone(endpoint),
                        generation: Some(generation),
                        expected_owner: Some(owner_id),
                        requires_unowned: false,
                        kind: OrderedControlCommandKind::Request {
                            command: "resize-surface".to_owned(),
                            params: json!({
                                "surface": surface_id,
                                "cols": grid.cols,
                                "rows": grid.rows,
                            }),
                            reply,
                        },
                    });
                    Ok(())
                }
            }
        };
        if let Err(outcome) = batch {
            return outcome;
        }
        target.queue.start_wire_drain();
        if let Some(response) = prequeued_response {
            let result = response.await.ok().flatten();
            return if result.is_none() && Self::current_generation(target) != generation {
                OwnerResizeRequestOutcome::Stale
            } else {
                OwnerResizeRequestOutcome::Reply(result)
            };
        }
        let result = response.await.ok().flatten();
        if result.is_none() && Self::current_generation(target) != generation {
            OwnerResizeRequestOutcome::Stale
        } else {
            OwnerResizeRequestOutcome::Reply(result)
        }
    }

    /// Prepare a candidate's verified report/claim request atomically with
    /// the shared queue. A stale owner update cannot replace the survivor
    /// claim between marker consumption and the flush. The queue sends the
    /// claim pair before this method returns, so later input cannot overtake
    /// it. `set-client-sizing` is the authority command; its response is an
    /// acknowledgement, so input is fenced by the command, not by waiting for
    /// the duplicate verification response.
    fn prepare_candidate_request(
        &self,
        target: &Arc<SizingTarget>,
        viewer_id: u64,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        generation: u64,
    ) -> CandidatePrepareOutcome {
        let (should_start, token, wire_ready) = {
            let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
            let state = target.state.lock().expect("terminal sizing state lock");
            let generation_current = Self::current_generation(target) == generation;
            let endpoint_current = state.owner.is_none()
                && candidate_viewer_id(&state) == Some(viewer_id)
                && state.viewers.get(&viewer_id).is_some_and(|viewer| {
                    viewer.endpoint.is_active() && Arc::ptr_eq(&viewer.endpoint, endpoint)
                })
                && smallest_sizing_grid(&state.viewers) == Some(grid)
                && !state.retired;
            if !generation_current
                || !endpoint_current
                || queue_state.closed
                || queue_state.closing_failed
                || !queue_state.closing.is_empty()
            {
                (false, CandidatePrepareOutcome::Stale, false)
            } else {
                target.queue.clear_stale_claim_fence_locked(
                    &mut queue_state,
                    Some((generation, viewer_id, grid, endpoint_ptr(endpoint))),
                );
                // A fence for another endpoint or grid is stale. Clear it
                // while the queue and target-state locks are held; a stale
                // worker cannot replace the new candidate after this point.
                if queue_state.claim_fence.is_some_and(|fence| {
                    fence.generation != generation
                        || fence.viewer_id != viewer_id
                        || fence.grid != grid
                        || fence.endpoint_ptr != endpoint_ptr(endpoint)
                }) {
                    queue_state.claim_fence = None;
                    if queue_state.pending_resize.as_ref().is_some_and(|(_, pending, _, claim)| {
                        *claim && pending.viewer_id == viewer_id
                    }) {
                        queue_state.pending_resize = None;
                    }
                }
                // A pending pair from an older generation cannot satisfy the
                // current candidate fence. Drop it before selecting whether
                // to reuse or reserve a claim token.
                target.queue.discard_stale_pending_locked(&mut queue_state);
                let (should_start, token) = if let Some(fence) = queue_state.claim_fence {
                    (false, Some(fence.token))
                } else {
                    let should_start = target.queue.reserve_resize_locked(
                        &mut queue_state,
                        endpoint,
                        grid,
                        generation,
                    );
                    let token = queue_state.claim_fence.and_then(|fence| {
                        (fence.generation == generation
                            && fence.viewer_id == viewer_id
                            && fence.grid == grid
                            && fence.endpoint_ptr == endpoint_ptr(endpoint))
                        .then_some(fence.token)
                    });
                    (should_start, token)
                };
                if let Some(token) = token {
                    // `reserve_resize_locked` may have left the pair pending
                    // behind a running worker. Flush it under the same queue
                    // lock before the direct verification request is started.
                    if target.queue.flush_resize_locked(&mut queue_state) {
                        queue_state.claim_fence = Some(ClaimFence {
                            generation,
                            viewer_id,
                            grid,
                            token,
                            endpoint_ptr: endpoint_ptr(endpoint),
                        });
                        (should_start, CandidatePrepareOutcome::Ready(token), true)
                    } else {
                        // A bounded queue cannot represent a partial claim
                        // pair. Drop the reservation and freeze until a new
                        // explicit attachment event can retry.
                        queue_state.claim_fence = None;
                        queue_state.pending_resize = None;
                        (false, CandidatePrepareOutcome::QueueFull, false)
                    }
                } else {
                    (false, CandidatePrepareOutcome::QueueFull, false)
                }
            }
        };
        if wire_ready {
            target.queue.start_wire_drain();
        }
        target.queue.start_drain(should_start);
        token
    }

    /// Finish the candidate round-trip while preserving queue/state lock
    /// order. A successful claim clears the fence and records ownership in
    /// one transition; a failed or stale round clears only its own fence so a
    /// later candidate reservation can retry without reviving a stale owner.
    fn finish_candidate_request(
        &self,
        target: &Arc<SizingTarget>,
        viewer_id: u64,
        endpoint: &Arc<OrderedControlEndpoint>,
        grid: SizingGrid,
        generation: u64,
        token: u64,
        success: bool,
    ) -> bool {
        let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
        let mut state = target.state.lock().expect("terminal sizing state lock");
        let generation_current = Self::current_generation(target) == generation;
        let current = !queue_state.closing_failed
            && !state.retired
            && state.owner.is_none()
            && candidate_viewer_id(&state) == Some(viewer_id)
            && smallest_sizing_grid(&state.viewers) == Some(grid)
            && generation_current
            && state.viewers.get(&viewer_id).is_some_and(|viewer| {
                viewer.endpoint.is_active() && Arc::ptr_eq(&viewer.endpoint, endpoint)
            });
        if queue_state.claim_fence
            == Some(ClaimFence {
                generation,
                viewer_id,
                grid,
                token,
                endpoint_ptr: endpoint_ptr(endpoint),
            })
        {
            queue_state.claim_fence = None;
        }
        if success && current {
            state.owner = Some(viewer_id);
            state.claim_requested = None;
            state.applied = Some(grid);
            true
        } else {
            // A refused explicit claim freezes the current core geometry. Do
            // not schedule a replacement or retry from an existing viewer.
            if state
                .claim_requested
                .is_some_and(|(id, ptr)| id == viewer_id && ptr == endpoint_ptr(endpoint))
            {
                state.claim_requested = None;
            }
            false
        }
    }

    /// Freeze geometry after the current owner loses authority. The core
    /// daemon has no generation token for ordering a claim from another
    /// socket, so the relay must not select an existing survivor. A later new
    /// attachment sets `claim_requested` and performs an explicit claim.
    fn freeze_after_owner_loss(
        &self,
        target: &Arc<SizingTarget>,
        lost_owner: u64,
        expected_generation: u64,
    ) -> bool {
        let mut queue_state = target.queue.state.lock().expect("ordered control queue lock");
        let mut state = target.state.lock().expect("terminal sizing state lock");
        if Self::current_generation(target) != expected_generation
            || state.retired
            || state.owner != Some(lost_owner)
        {
            return false;
        }
        state.owner = None;
        state.claim_requested = None;
        target.queue.clear_stale_claim_fence_locked(&mut queue_state, None);
        target.queue.discard_stale_owner_resize_fence_locked(&mut queue_state);
        queue_state.owner_resize_fence = None;
        self.advance_generation(target);
        false
    }

    async fn apply_target(self: &Arc<Self>, target: &Arc<SizingTarget>) {
        // A detached socket is a daemon-order barrier for every later
        // mutation, not only for a replacement claim. Join/update paths may
        // have changed the state while the close worker was still draining;
        // wait before snapshotting the command owner or canonical grid.
        if !target.queue.wait_for_closing().await {
            let failed =
                target.queue.state.lock().expect("ordered control queue lock").closing_failed;
            if failed {
                let mut state = target.state.lock().expect("terminal sizing state lock");
                // A failed daemon barrier cannot be retried from the same
                // attachment. Clear its explicit claim marker and keep
                // geometry frozen until a new authenticated attachment.
                state.claim_requested = None;
            }
            return;
        }
        let (surface_id, grid, owner, owner_queue, candidate) = {
            let state = target.state.lock().expect("terminal sizing state lock");
            if state.retired || state.viewers.is_empty() {
                return;
            }
            let Some(grid) = smallest_sizing_grid(&state.viewers) else { return };
            let owner = state.owner.filter(|id| state.viewers.contains_key(id));
            if let Some(owner_id) = owner {
                let Some(viewer) = state.viewers.get(&owner_id) else { return };
                if state.applied == Some(grid) {
                    return;
                }
                (state.surface_id, grid, Some(owner_id), Some(Arc::clone(&viewer.endpoint)), None)
            } else {
                let Some(viewer_id) = candidate_viewer_id(&state) else {
                    return;
                };
                let Some(viewer) = state.viewers.get(&viewer_id) else { return };
                (
                    state.surface_id,
                    grid,
                    None,
                    None,
                    Some((viewer_id, Arc::clone(&viewer.control), Arc::clone(&viewer.endpoint))),
                )
            }
        };

        if let Some((viewer_id, _control, endpoint)) = candidate {
            let generation = Self::current_generation(target);
            // Only a newly attached viewer reaches this path. Existing
            // survivors are intentionally not elected after owner loss.
            if !self.candidate_is_current(target, viewer_id, &endpoint, grid, generation) {
                return;
            }
            let token = match self
                .prepare_candidate_request(target, viewer_id, &endpoint, grid, generation)
            {
                CandidatePrepareOutcome::Stale => return,
                CandidatePrepareOutcome::QueueFull => {
                    // This worker has no request id to report. Detach the
                    // candidate and freeze authority rather than leaving a
                    // claim fence that can never drain.
                    self.leave_endpoint_at_generation(
                        &target.key,
                        viewer_id,
                        &endpoint,
                        generation,
                    );
                    return;
                }
                CandidatePrepareOutcome::Ready(token) => token,
            };
            // Leave/update can race the preparation above. Re-check the
            // generation and endpoint immediately before starting the
            // round-trip; an invalidated control is closed by leave and must
            // not issue a late authority command.
            if !self.candidate_is_current(target, viewer_id, &endpoint, grid, generation) {
                self.abandon_candidate_request(
                    target, viewer_id, &endpoint, grid, generation, token,
                );
                return;
            }
            let reported = match self
                .candidate_request(
                    target,
                    viewer_id,
                    &endpoint,
                    grid,
                    generation,
                    "resize-surface",
                    json!({ "surface": surface_id, "cols": grid.cols, "rows": grid.rows }),
                )
                .await
            {
                CandidateRequestOutcome::Stale => {
                    if endpoint.is_active() {
                        self.abandon_candidate_request(
                            target, viewer_id, &endpoint, grid, generation, token,
                        );
                    }
                    return;
                }
                CandidateRequestOutcome::Reply(response) => response,
            };
            // A reply can be valid JSON even after a leave/update advanced
            // the candidate generation.  Check the fence before interpreting
            // `ok` or `accepted`; an old refusal must not clear or freeze a
            // newer explicit claim.
            if !self.candidate_is_current(target, viewer_id, &endpoint, grid, generation) {
                if endpoint.is_active() {
                    self.abandon_candidate_request(
                        target, viewer_id, &endpoint, grid, generation, token,
                    );
                } else {
                    self.leave_endpoint_at_generation(
                        &target.key,
                        viewer_id,
                        &endpoint,
                        generation,
                    );
                }
                return;
            }
            if reported.is_none() {
                // A timeout or transport failure leaves a request that may
                // still be queued in the control writer. Close this endpoint
                // before reserving a replacement so the late request cannot
                // steal authority after the survivor fence.
                self.leave_endpoint_at_generation(&target.key, viewer_id, &endpoint, generation);
                return;
            }
            if !control_response_ok(reported.as_ref()) {
                self.abandon_candidate_request(
                    target, viewer_id, &endpoint, grid, generation, token,
                );
                return;
            }
            let claimed = match self
                .candidate_request(
                    target,
                    viewer_id,
                    &endpoint,
                    grid,
                    generation,
                    "set-client-sizing",
                    json!({ "surface": surface_id, "enabled": true, "exclusive": true }),
                )
                .await
            {
                CandidateRequestOutcome::Stale => {
                    if endpoint.is_active() {
                        self.abandon_candidate_request(
                            target, viewer_id, &endpoint, grid, generation, token,
                        );
                    }
                    return;
                }
                CandidateRequestOutcome::Reply(response) => response,
            };
            // Apply the same generation fence to the claim response.  In
            // particular, an old `ok:false` must not clear a newer claim
            // reservation or detach its endpoint.
            if !self.candidate_is_current(target, viewer_id, &endpoint, grid, generation) {
                if endpoint.is_active() {
                    self.abandon_candidate_request(
                        target, viewer_id, &endpoint, grid, generation, token,
                    );
                } else {
                    self.leave_endpoint_at_generation(
                        &target.key,
                        viewer_id,
                        &endpoint,
                        generation,
                    );
                }
                return;
            }
            if claimed.is_none() {
                self.leave_endpoint_at_generation(&target.key, viewer_id, &endpoint, generation);
                return;
            }
            if !control_response_ok(claimed.as_ref()) {
                self.abandon_candidate_request(
                    target, viewer_id, &endpoint, grid, generation, token,
                );
                return;
            }
            if !self.candidate_is_current(target, viewer_id, &endpoint, grid, generation) {
                if endpoint.is_active() {
                    self.abandon_candidate_request(
                        target, viewer_id, &endpoint, grid, generation, token,
                    );
                } else {
                    self.leave_endpoint_at_generation(
                        &target.key,
                        viewer_id,
                        &endpoint,
                        generation,
                    );
                }
                return;
            }
            if !self.finish_candidate_request(
                target, viewer_id, &endpoint, grid, generation, token, true,
            ) {
                self.abandon_candidate_request(
                    target, viewer_id, &endpoint, grid, generation, token,
                );
            }
            return;
        }

        let Some(owner_id) = owner else { return };
        // A non-owner viewer can change the canonical smallest grid. The owner
        // resize and its verified request are admitted as one ordered batch,
        // so input written on any connection cannot overtake this update.
        let generation = Self::current_generation(target);
        let Some(endpoint) = owner_queue.as_ref() else { return };
        let resized = match self
            .owner_resize_request(target, owner_id, endpoint, grid, generation, surface_id)
            .await
        {
            OwnerResizeRequestOutcome::Stale => return,
            OwnerResizeRequestOutcome::QueueFull => {
                // A complete resize+request batch cannot fit. Detach and
                // freeze this generation; never send only one half of the
                // authority transition. `apply_target` is an internal
                // observation with no request ID; its fixed failure is the
                // frozen state and a new explicit attachment event.
                self.leave_endpoint_at_generation(&target.key, owner_id, endpoint, generation);
                return;
            }
            OwnerResizeRequestOutcome::Reply(response) => response,
        };
        // A response from an older generation cannot change authority or
        // freeze the current owner. Check before every refusal path; the
        // freeze helper repeats the check while holding the actor locks.
        if Self::current_generation(target) != generation {
            return;
        }
        if resized.is_none() {
            // A timed-out owner request may still be queued in the control
            // writer. Close that endpoint before reserving a survivor so a
            // late command cannot regain authority.
            if let Some(endpoint) = owner_queue.as_ref() {
                self.leave_endpoint_at_generation(&target.key, owner_id, endpoint, generation);
            } else {
                self.freeze_after_owner_loss(target, owner_id, generation);
            }
            return;
        }
        if !control_response_ok(resized.as_ref()) {
            self.freeze_after_owner_loss(target, owner_id, generation);
            return;
        }
        if resized
            .as_ref()
            .and_then(|response| response.get("data"))
            .and_then(|data| data.get("accepted"))
            .and_then(Value::as_bool)
            == Some(false)
        {
            self.freeze_after_owner_loss(target, owner_id, generation);
            return;
        }
        // Recheck and commit under the same queue -> state fence used by
        // updates. A worker may have passed its earlier generation check
        // while an update advanced the target; it must not publish its old
        // grid after that transition.
        let _queue_state = target.queue.state.lock().expect("ordered control queue lock");
        let mut state = target.state.lock().expect("terminal sizing state lock");
        if Self::current_generation(target) == generation
            && state.owner == Some(owner_id)
            && !state.retired
        {
            state.applied = Some(grid);
        }
    }
}

fn smallest_sizing_grid(viewers: &HashMap<u64, SizingViewer>) -> Option<SizingGrid> {
    viewers.values().map(|viewer| viewer.grid).reduce(|left, right| SizingGrid {
        cols: left.cols.min(right.cols),
        rows: left.rows.min(right.rows),
    })
}

fn smallest_shell_grid(viewers: &HashMap<u64, SizingGrid>) -> Option<SizingGrid> {
    viewers.values().copied().reduce(|left, right| SizingGrid {
        cols: left.cols.min(right.cols),
        rows: left.rows.min(right.rows),
    })
}

fn control_response_ok(response: Option<&Value>) -> bool {
    response.and_then(|value| value.get("ok")).and_then(Value::as_bool) == Some(true)
}

struct TerminalSizingLease {
    // The manager owns the coordinator. A lease must not keep that manager
    // alive through a control callback cycle after cancellation.
    coordinator: std::sync::Weak<TerminalSizing>,
    key: SizingKey,
    viewer_id: u64,
    surface_id: i64,
    state: Mutex<SizingLeaseState>,
}

struct SizingLeaseState {
    joining: bool,
    joined: bool,
    released: bool,
    /// Once setup may have installed a coordinator endpoint, teardown stays
    /// queue-owned for the rest of the lease lifetime. This survives the
    /// joining-cancel rollback, which can enqueue a FIFO close after `joining`
    /// becomes false but before the cleanup guard is dropped.
    queue_owned: bool,
    // Keep only a non-owning identity. The endpoint owns the control handle,
    // whose callbacks retain the lease; an owning Arc here would form a
    // lease -> endpoint -> control -> callback -> lease cycle.
    endpoint: Option<Weak<OrderedControlEndpoint>>,
}

impl TerminalSizingLease {
    fn new(
        coordinator: &Arc<TerminalSizing>,
        key: SizingKey,
        viewer_id: u64,
        surface_id: i64,
    ) -> Arc<Self> {
        Arc::new(Self {
            coordinator: Arc::downgrade(coordinator),
            key,
            viewer_id,
            surface_id,
            state: Mutex::new(SizingLeaseState {
                joining: false,
                joined: false,
                released: false,
                queue_owned: false,
                endpoint: None,
            }),
        })
    }

    fn join(
        &self,
        control: Arc<dyn ControlHandle>,
        grid: SizingGrid,
    ) -> Option<oneshot::Receiver<()>> {
        let should_start = {
            let mut state = self.state.lock().expect("terminal sizing lease lock");
            if state.released || state.joined || state.joining {
                false
            } else {
                state.joining = true;
                true
            }
        };
        if !should_start {
            return None;
        }
        let mut waiter = None;
        let mut endpoint = None;
        {
            let Some(coordinator) = self.coordinator.upgrade() else {
                let mut state = self.state.lock().expect("terminal sizing lease lock");
                state.joining = false;
                state.released = true;
                return None;
            };
            if let Some((joined_waiter, joined_endpoint)) = coordinator.join_with_endpoint(
                self.key.clone(),
                self.viewer_id,
                self.surface_id,
                control,
                grid,
            ) {
                waiter = Some(joined_waiter);
                endpoint = Some(joined_endpoint);
            }
            let rollback = self.finish_join(endpoint.as_ref());
            if rollback {
                if let Some(endpoint) = endpoint.as_ref() {
                    coordinator.leave_endpoint(&self.key, self.viewer_id, endpoint);
                }
                waiter = None;
            }
        }
        waiter
    }

    /// Complete the synchronous coordinator registration. Keeping this state
    /// transition in one helper makes the cancellation/failed-registration
    /// branch explicit: queue ownership survives only when an endpoint exists
    /// and a rollback close can be enqueued.
    fn finish_join(&self, endpoint: Option<&Arc<OrderedControlEndpoint>>) -> bool {
        let mut state = self.state.lock().expect("terminal sizing lease lock");
        state.joining = false;
        if state.released || endpoint.is_none() {
            // Do not retain the endpoint after a cancelled or failed join.
            // The endpoint owns the control callbacks, and those callbacks
            // can retain this lease. Keeping the reference here would create
            // a lease -> endpoint -> control -> callback -> lease cycle.
            state.endpoint = None;
            // A cancellation may have marked teardown as queue-owned while
            // join was in flight. If no endpoint was installed, no FIFO close
            // can be pending for this lease; permit direct standalone cleanup.
            if endpoint.is_none() {
                state.queue_owned = false;
            }
            true
        } else {
            state.joined = true;
            state.queue_owned = true;
            state.endpoint = endpoint.map(Arc::downgrade);
            false
        }
    }

    fn update(&self, grid: SizingGrid) {
        let endpoint = {
            let state = self.state.lock().expect("terminal sizing lease lock");
            if state.joined && !state.released {
                state.endpoint.as_ref().and_then(Weak::upgrade)
            } else {
                None
            }
        };
        if let Some(endpoint) = endpoint {
            if let Some(coordinator) = self.coordinator.upgrade() {
                coordinator.update_endpoint(&self.key, self.viewer_id, &endpoint, grid);
            }
        }
    }

    fn queue(&self) -> Option<Arc<OrderedControlEndpoint>> {
        let endpoint = {
            let state = self.state.lock().expect("terminal sizing lease lock");
            if state.joined && !state.released {
                state.endpoint.as_ref().and_then(Weak::upgrade)
            } else {
                None
            }
        };
        self.coordinator.upgrade()?;
        endpoint
    }

    /// Release the relay sizing attachment. Returns true when the sizing
    /// coordinator owns transport teardown, including repeated calls after a
    /// callback already released the lease. Callers must not close the
    /// control directly in that case because the queue must first establish
    /// the daemon-observed ordering barrier.
    fn leave(&self) -> bool {
        let (queue_owned, endpoint) = {
            let mut state = self.state.lock().expect("terminal sizing lease lock");
            if state.released {
                // A close/event callback can release the lease before the
                // proxy's Drop path runs. Preserve the queue-owned marker so
                // the second path cannot bypass the FIFO close with a direct
                // `control.end()`.
                let queue_owned = state.queue_owned || state.joined || state.joining;
                state.queue_owned = queue_owned;
                (queue_owned, None)
            } else {
                state.released = true;
                // Clone only the endpoint needed for the immediate ordered
                // removal, then drop the owning reference from the lease.
                // Control callbacks may retain the lease, so retaining this
                // Arc after release would keep the whole control cycle alive.
                let queue_owned = state.queue_owned || state.joined || state.joining;
                state.queue_owned = queue_owned;
                (queue_owned, state.endpoint.take().and_then(|endpoint| endpoint.upgrade()))
            }
        };
        if queue_owned && let Some(endpoint) = endpoint {
            if let Some(coordinator) = self.coordinator.upgrade() {
                coordinator.leave_endpoint(&self.key, self.viewer_id, &endpoint);
            }
        }
        queue_owned
    }
}

impl Drop for TerminalSizingLease {
    fn drop(&mut self) {
        // A cancelled open can drop the lease before the control proxy exists.
        // Keep the target map bounded even when no close callback is installed.
        let _ = self.leave();
    }
}

/// Owns a connected cmux-tui control until raw attachment setup completes.
/// Every fallible request in `open_cmux_terminal` is therefore cancellation
/// safe; successful setup transfers ownership to `ControlTerminalControl`.
struct ControlCleanupGuard {
    control: Option<Arc<dyn ControlHandle>>,
    /// Shared-sizing setup can enqueue a FIFO close before open returns. Keep
    /// the lease in this guard until setup transfers ownership to the proxy so
    /// cancellation never calls `control.end()` ahead of that queue barrier.
    sizing: Option<Arc<TerminalSizingLease>>,
}

impl ControlCleanupGuard {
    fn new(control: Arc<dyn ControlHandle>) -> Self {
        Self { control: Some(control), sizing: None }
    }

    fn set_sizing(&mut self, sizing: Arc<TerminalSizingLease>) {
        self.sizing = Some(sizing);
    }

    fn disarm(&mut self) {
        self.control = None;
        self.sizing = None;
    }
}

impl Drop for ControlCleanupGuard {
    fn drop(&mut self) {
        // If the sizing lease ever joined (or is in the middle of joining),
        // its coordinator owns teardown. This remains true when an event
        // callback already released it, so a cancelled open cannot race a
        // queued FIFO close with a direct control end.
        let sizing_owned = self.sizing.take().is_some_and(|sizing| sizing.leave());
        if sizing_owned {
            self.control.take();
            return;
        }
        if let Some(control) = self.control.take() {
            control.end();
        }
    }
}

struct Inner {
    deps: Arc<dyn PtyDeps>,
    home: PathBuf,
    env: HashMap<String, String>,
    max_ptys: usize,
    scrollback_limit: usize,
    output_cap: u64,
    attachments: Mutex<HashMap<String, Attachment>>,
    opening_ids: Mutex<std::collections::HashSet<String>>,
    cancelled_openings: Mutex<std::collections::HashSet<String>>,
    shell_sessions: Mutex<HashMap<String, Arc<ShellSession>>>,
    shell_starting: Mutex<HashMap<String, Arc<Notify>>>,
    sizing: Arc<TerminalSizing>,
    auth: Mutex<Option<AuthSnapshot>>,
    next_generation: AtomicU64,
    next_sizing_id: AtomicU64,
}

struct ShellStartReservation {
    inner: Arc<Inner>,
    session: String,
    notify: Arc<Notify>,
    active: bool,
}

impl Drop for ShellStartReservation {
    fn drop(&mut self) {
        if self.active {
            self.inner.shell_starting.lock().expect("shell starting lock").remove(&self.session);
            self.notify.notify_waiters();
        }
    }
}

struct OpeningReservation {
    inner: Arc<Inner>,
    id: String,
    active: bool,
}
impl Drop for OpeningReservation {
    fn drop(&mut self) {
        if self.active {
            self.inner.opening_ids.lock().expect("opening lock").remove(&self.id);
        }
    }
}

#[derive(Clone)]
pub struct PtyManager {
    inner: Arc<Inner>,
}

impl PtyManager {
    pub fn new(deps: Arc<dyn PtyDeps>, home: PathBuf, env: HashMap<String, String>) -> PtyManager {
        PtyManager {
            inner: Arc::new(Inner {
                deps,
                home,
                env,
                max_ptys: MAX_PTYS,
                scrollback_limit: SCROLLBACK_LIMIT,
                output_cap: OUTPUT_BUFFER_CAP,
                attachments: Mutex::new(HashMap::new()),
                opening_ids: Mutex::new(std::collections::HashSet::new()),
                cancelled_openings: Mutex::new(std::collections::HashSet::new()),
                shell_sessions: Mutex::new(HashMap::new()),
                shell_starting: Mutex::new(HashMap::new()),
                sizing: TerminalSizing::new(),
                auth: Mutex::new(None),
                next_generation: AtomicU64::new(1),
                next_sizing_id: AtomicU64::new(1),
            }),
        }
    }

    pub fn with_limits(
        deps: Arc<dyn PtyDeps>,
        home: PathBuf,
        env: HashMap<String, String>,
        max_ptys: usize,
        scrollback_limit: usize,
        output_cap: u64,
    ) -> PtyManager {
        PtyManager {
            inner: Arc::new(Inner {
                deps,
                home,
                env,
                max_ptys,
                scrollback_limit,
                output_cap,
                attachments: Mutex::new(HashMap::new()),
                opening_ids: Mutex::new(std::collections::HashSet::new()),
                cancelled_openings: Mutex::new(std::collections::HashSet::new()),
                shell_sessions: Mutex::new(HashMap::new()),
                shell_starting: Mutex::new(HashMap::new()),
                sizing: TerminalSizing::new(),
                auth: Mutex::new(None),
                next_generation: AtomicU64::new(1),
                next_sizing_id: AtomicU64::new(1),
            }),
        }
    }

    /// Handle one Worker -> relay PTY frame.
    pub async fn handle_frame(&self, frame: &Value, context: &FrameContext) {
        *self.inner.auth.lock().expect("auth lock") = Some(AuthSnapshot {
            trust: context.trust.clone(),
            owner_user_id: context.owner_user_id.clone(),
            send: Arc::clone(&context.send),
            buffered_amount: Arc::clone(&context.buffered_amount),
        });
        let frame_type = frame.get("type").and_then(Value::as_str).unwrap_or_default();
        match frame_type {
            "pty_open" => self.inner.clone().open(frame, context).await,
            "pty_input" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                let Some(data) = frame
                    .get("dataB64")
                    .and_then(Value::as_str)
                    .filter(|value| value.len() <= PTY_INPUT_B64_CAP)
                    .and_then(|b64| BASE64.decode(b64).ok())
                else {
                    return;
                };
                if let Some(attachment) = self.inner.authorize(pty_id, context, "input") {
                    attachment.control.write(&data);
                }
            }
            "pty_resize" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                let (Some(cols), Some(rows)) =
                    (clamp_dim(frame.get("cols")), clamp_dim(frame.get("rows")))
                else {
                    return;
                };
                if let Some(attachment) = self.inner.authorize(pty_id, context, "resize") {
                    // Resize is a hot-path, fire-and-forget operation.  The
                    // sizing coordinator coalesces updates and performs its
                    // control-plane replies in a separate worker.  Waiting
                    // here can hold the serialized relay ingress for the
                    // full three-second control timeout and block input,
                    // close, or trust updates behind a slow daemon.
                    attachment.control.resize(cols, rows);
                }
            }
            "pty_flow" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                let pause = frame.get("pause").and_then(Value::as_bool).unwrap_or(false);
                if let Some(attachment) = self.inner.authorize(pty_id, context, "flow") {
                    if pause {
                        attachment.control.pause();
                    } else {
                        attachment.control.resume();
                    }
                }
            }
            "pty_close" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                self.inner.close_authorized(pty_id, context);
            }
            "surface_list" => self.inner.clone().list_surfaces(frame, context).await,
            _ => {}
        }
    }

    /// The relay socket dropped: release every attachment (sessions live on).
    pub fn detach_all(&self) {
        let ids: Vec<String> =
            self.inner.attachments.lock().expect("attach lock").keys().cloned().collect();
        for id in ids {
            self.inner.close(&id);
        }
    }

    /// Close one attachment after outbound output saturation. This is kept
    /// separate from `detach_all` so one slow viewer cannot terminate other
    /// sessions on the same relay connection.
    pub fn detach_on_output_overflow(&self, pty_id: &str) {
        self.inner.close(pty_id);
    }
}

fn send_pty_error(context: &FrameContext, pty_id: &str, code: RelayPtyErrorCode, message: &str) {
    // Keep the hand-written frame path aligned with the generated serde
    // contract. A second string mapping can silently drift when a variant is
    // added to RelayPtyErrorCode.
    let encoded =
        serde_json::to_value(code).expect("RelayPtyErrorCode serialization is infallible");
    let wire_code = encoded.as_str().expect("RelayPtyErrorCode serializes as a string");
    (context.send)(json!({
        "version": PTY_PROTOCOL_VERSION,
        "type": "pty_error",
        "ptyId": pty_id,
        "code": wire_code,
        "message": message,
    }));
}

fn operational_pty_error_code(
    context: &FrameContext,
    operational: RelayPtyErrorCode,
) -> RelayPtyErrorCode {
    crate::wire::pty_operational_error_code(context.negotiated_version, operational)
}

fn send_operational_pty_error(
    context: &FrameContext,
    pty_id: &str,
    code: RelayPtyErrorCode,
    typed_message: &str,
    legacy_message: &str,
) {
    let code = operational_pty_error_code(context, code);
    let message = if context.negotiated_version >= PTY_OPERATIONAL_ERRORS_PROTOCOL_VERSION {
        typed_message
    } else {
        legacy_message
    };
    send_pty_error(context, pty_id, code, message);
}

impl Inner {
    /// Remove a shell map entry only when it still points at the session that
    /// exited. A replacement can be installed before a late exit callback
    /// runs; pointer identity prevents that callback from deleting the live
    /// replacement.
    fn remove_shell_session_if_current(&self, session: &str, expected: &Arc<ShellSession>) {
        let mut sessions = self.shell_sessions.lock().expect("shell lock");
        if sessions.get(session).is_some_and(|current| Arc::ptr_eq(current, expected)) {
            sessions.remove(session);
        }
    }

    async fn open(self: Arc<Self>, frame: &Value, context: &FrameContext) {
        let pty_id = frame.get("ptyId").and_then(Value::as_str).unwrap_or_default().to_owned();
        if pty_id.is_empty() {
            return;
        }
        let fail = |code: RelayPtyErrorCode, message: &str| {
            send_pty_error(context, &pty_id, code, message)
        };
        let reservation_result = {
            let mut opening = self.opening_ids.lock().expect("opening lock");
            let attached = self.attachments.lock().expect("attach lock").contains_key(&pty_id);
            if attached || opening.contains(&pty_id) {
                Err((RelayPtyErrorCode::BadRequest, "ptyId is already attached".to_owned()))
            } else if self.attachments.lock().expect("attach lock").len() + opening.len()
                >= self.max_ptys
            {
                Err((
                    RelayPtyErrorCode::SessionLimit,
                    format!("this relay caps concurrent terminals at {}", self.max_ptys),
                ))
            } else {
                opening.insert(pty_id.clone());
                Ok(())
            }
        };
        if let Err((code, message)) = reservation_result {
            fail(code, &message);
            return;
        }
        let mut reservation =
            OpeningReservation { inner: Arc::clone(&self), id: pty_id.clone(), active: true };

        let session = frame.get("session").and_then(Value::as_str).unwrap_or_default().to_owned();
        let (Some(cols), Some(rows)) = (clamp_dim(frame.get("cols")), clamp_dim(frame.get("rows")))
        else {
            fail(RelayPtyErrorCode::BadRequest, "invalid session name or dimensions");
            return;
        };
        if !session_name_ok(&session) {
            fail(RelayPtyErrorCode::BadRequest, "invalid session name or dimensions");
            return;
        }
        let mut surface_ref: Option<String> = None;
        if let Some(surface) = frame.get("surface") {
            match surface.as_str() {
                Some(value) if surface_ref_ok(value) => surface_ref = Some(value.to_owned()),
                _ => {
                    fail(RelayPtyErrorCode::BadRequest, "invalid surface ref");
                    return;
                }
            }
        }

        // Owner-side trust floor: observe-trust machines admit only their
        // OWNER's terminal. Any trust level admits the owner.
        // Only locally established trust is authoritative. Missing local
        // state fails closed; the untrusted frame cannot elevate access.
        let trust = context.trust.clone();
        if trust.is_empty() {
            fail(RelayPtyErrorCode::TrustRefused, "terminal trust is not established");
            return;
        }
        let owner = context.owner_user_id.as_deref();
        let actor = frame.get("actorId").and_then(Value::as_str).unwrap_or_default();
        if trust == "observe" && (owner.is_none() || Some(actor) != owner) {
            fail(
                RelayPtyErrorCode::TrustRefused,
                "this machine is paired at observe trust; terminals are owner-only",
            );
            return;
        }

        // cwd discipline: the local config and server-echoed root lists both
        // apply when present, else $HOME.
        let server_roots = match parse_allowed_roots(frame) {
            Ok(roots) => roots,
            Err(message) => {
                fail(RelayPtyErrorCode::BadRequest, message);
                return;
            }
        };
        if let Some(value) = frame.get("cwd")
            && !value.is_null()
            && !value.is_string()
        {
            fail(RelayPtyErrorCode::BadRequest, "cwd must be a string");
            return;
        }
        let cwd = match scoped_cwd(
            frame.get("cwd").and_then(Value::as_str),
            &self.home,
            context.local_roots.as_deref(),
            server_roots.as_deref(),
        ) {
            Ok(cwd) => cwd,
            Err(message) => {
                fail(RelayPtyErrorCode::BadRequest, &message);
                return;
            }
        };
        let env = pty_env(&self.env);

        let cmux_tui = self.deps.resolve_cmux_tui().await;
        let opened = if let (Some(cmux_tui), Some(surface_ref)) =
            (cmux_tui.as_ref(), surface_ref.as_ref())
        {
            match self
                .clone()
                .open_cmux_terminal(
                    cmux_tui,
                    &session,
                    surface_ref,
                    cols,
                    rows,
                    &cwd,
                    &env,
                    &pty_id,
                    server_roots.as_deref(),
                    context,
                )
                .await
            {
                Ok(Some(opened)) => Some(opened),
                Ok(None) => None, // degrade to whole-session
                Err((code, message)) => {
                    send_pty_error(context, &pty_id, code, &message);
                    return;
                }
            }
        } else {
            None
        };
        let mut opened = match opened {
            Some(opened) => opened,
            None => {
                let result = if let Some(cmux_tui) = cmux_tui.as_ref() {
                    self.clone()
                        .open_cmux(
                            cmux_tui,
                            &session,
                            cols,
                            rows,
                            &cwd,
                            &env,
                            &pty_id,
                            server_roots.as_deref(),
                            context,
                        )
                        .await
                } else {
                    self.clone()
                        .open_shell(
                            &session,
                            cols,
                            rows,
                            &cwd,
                            &env,
                            &pty_id,
                            server_roots.as_deref(),
                            context,
                        )
                        .await
                };
                match result {
                    Ok(opened) => opened,
                    Err(message) => {
                        fail(RelayPtyErrorCode::Failed, &message);
                        return;
                    }
                }
            }
        };

        // Keep the opening marker until the attachment is installed. Release
        // its mutex while waiting for an older delivery gate, so a callback
        // cannot deadlock by asking `close` to cancel this opening.
        let cancelled = {
            let _opening = self.opening_ids.lock().expect("opening lock");
            self.cancelled_openings.lock().expect("cancelled openings lock").remove(&pty_id)
        };
        if cancelled {
            self.opening_ids.lock().expect("opening lock").remove(&pty_id);
            reservation.active = false;
            return;
        }
        let previous_gate = self
            .attachments
            .lock()
            .expect("attach lock")
            .get(&pty_id)
            .map(|attachment| Arc::clone(&attachment.gate));
        let previous_gate_guard =
            previous_gate.as_ref().map(|gate| gate.lock().expect("attachment gate"));
        let mut opening = self.opening_ids.lock().expect("opening lock");
        let cancelled =
            self.cancelled_openings.lock().expect("cancelled openings lock").remove(&pty_id);
        if cancelled {
            opening.remove(&pty_id);
            drop(opening);
            drop(previous_gate_guard);
            reservation.active = false;
            return;
        }
        let previous = self.attachments.lock().expect("attach lock").insert(
            pty_id.clone(),
            Attachment {
                generation: opened.generation,
                gate: Arc::clone(&opened.gate),
                closing: Arc::clone(&opened.closing),
                control: Arc::clone(&opened.control),
                actor_id: actor.to_owned(),
            },
        );
        opening.remove(&pty_id);
        drop(opening);
        drop(previous_gate_guard);
        if let Some(previous) = previous {
            previous.closing.store(true, Ordering::SeqCst);
            previous.control.kill();
        }
        // The attachment table now owns the control. Dropping `opened` after
        // this point must not run its cancellation cleanup.
        opened.disarm_cleanup();
        reservation.active = false;
        let mut opened_frame = serde_json::Map::new();
        opened_frame.insert("version".to_owned(), Value::from(PTY_PROTOCOL_VERSION));
        opened_frame.insert("type".to_owned(), Value::from("pty_opened"));
        opened_frame.insert("ptyId".to_owned(), Value::from(pty_id.clone()));
        opened_frame.insert("session".to_owned(), Value::from(session));
        if let Some(surface) = opened.surface.as_ref() {
            opened_frame.insert("surface".to_owned(), Value::from(surface));
        }
        opened_frame.insert("created".to_owned(), Value::from(opened.created));
        opened_frame.insert("cols".to_owned(), Value::from(cols));
        opened_frame.insert("rows".to_owned(), Value::from(rows));
        (context.send)(Value::Object(opened_frame));

        if opened.post_open_resize {
            // Legacy protocol-5..9 daemons have no shared sizing lease. Send
            // exactly one canonical resize after `pty_opened`, before output
            // or input can reach the control writer.
            opened.control.resize(cols, rows);
        }

        // Output only AFTER pty_opened (ordering): banner, then scrollback
        // replay, then live bytes.
        (opened.start.take().expect("opened start callback"))();
    }

    /// Build the per-attachment emit closures (output + exit framing).
    fn sinks(
        self: &Arc<Self>,
        pty_id: &str,
        context: &FrameContext,
        control: Weak<dyn PtyControl>,
    ) -> (u64, Arc<Mutex<()>>, DataSink, ExitSink) {
        let generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        let gate = Arc::new(Mutex::new(()));
        let on_data = {
            let inner = Arc::clone(self);
            let context = context.clone();
            let pty_id = pty_id.to_owned();
            let control = control.clone();
            let gate = Arc::clone(&gate);
            Arc::new(move |chunk: Bytes| {
                let kill = {
                    let _guard = gate.lock().expect("attachment gate");
                    inner.emit_output(&pty_id, generation, &chunk, &context, &control)
                };
                if let Some(control) = kill {
                    control.kill();
                }
            }) as Arc<dyn Fn(Bytes) + Send + Sync>
        };
        let on_exit = {
            let inner = Arc::clone(self);
            let context = context.clone();
            let pty_id = pty_id.to_owned();
            let control = control.clone();
            let gate = Arc::clone(&gate);
            Arc::new(move |code: i64| {
                let kill = {
                    let _guard = gate.lock().expect("attachment gate");
                    inner.emit_raw_exit(&pty_id, generation, None, code, &context, &control)
                };
                if let Some(control) = kill {
                    control.kill();
                }
            }) as Arc<dyn Fn(i64) + Send + Sync>
        };
        (generation, gate, on_data, on_exit)
    }

    fn emit_output(
        &self,
        pty_id: &str,
        generation: u64,
        chunk: &Bytes,
        context: &FrameContext,
        control: &Weak<dyn PtyControl>,
    ) -> Option<Arc<dyn PtyControl>> {
        let Some(auth) = self.auth.lock().expect("auth lock").clone() else { return None };
        let Some(control) = control.upgrade() else { return None };
        if !self.attachment_is_current(pty_id, generation, &control) {
            return None;
        }
        if self.authorize_snapshot(pty_id, &auth, context, "output").is_none() {
            // The caller already owns the attachment gate. Remove and detach
            // directly instead of calling `close`, which would try to lock
            // the same gate again during a trust downgrade.
            if self.remove_attachment_if_current(pty_id, generation, &control) {
                return Some(control);
            }
            return None;
        }
        // Zero-byte chunks carry nothing and historically crashed the web
        // terminal's write path (D-R6-1); never put an empty frame on the wire.
        if chunk.is_empty() {
            return None;
        }
        let buffered = (auth.buffered_amount)();
        // Admit the complete frame before sending it. The socket may accept a
        // frame exactly at the cap, but must reject one that would push the
        // buffered amount over the cap.
        if buffered.saturating_add(chunk.len() as u64) > self.output_cap {
            if self.remove_attachment_if_current(pty_id, generation, &control) {
                send_operational_pty_error(
                    context,
                    pty_id,
                    RelayPtyErrorCode::Overflow,
                    "terminal output overflowed; reattach to continue receiving output",
                    "PTY output buffer is full. Reattach to continue.",
                );
                return Some(control);
            }
            return None;
        }
        (auth.send)(json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_output",
            "ptyId": pty_id,
            "dataB64": BASE64.encode(chunk),
        }));
        None
    }

    fn emit_raw_exit(
        &self,
        pty_id: &str,
        generation: u64,
        stream: Option<&TerminalStream>,
        code: i64,
        context: &FrameContext,
        control: &Weak<dyn PtyControl>,
    ) -> Option<Arc<dyn PtyControl>> {
        if stream.is_none_or(|stream| !stream.overflowed()) {
            self.emit_exit(pty_id, generation, code, context, control);
            return None;
        }
        let Some(control) = control.upgrade() else { return None };
        // A stale overflow callback must not send an error after a replacement
        // attachment has taken the same pty ID. The generation check and
        // removal are one operation; only the owner of the current entry may
        // kill it or report overflow.
        if self.remove_attachment_if_current(pty_id, generation, &control) {
            send_pty_error(
                context,
                pty_id,
                operational_pty_error_code(context, RelayPtyErrorCode::Overflow),
                "pty output backlog overflowed; reattach to continue receiving output",
            );
            return Some(control);
        }
        None
    }

    fn emit_exit(
        &self,
        pty_id: &str,
        generation: u64,
        code: i64,
        context: &FrameContext,
        control: &Weak<dyn PtyControl>,
    ) {
        let Some(auth) = self.auth.lock().expect("auth lock").clone() else { return };
        let Some(control) = control.upgrade() else { return };
        if !self.attachment_is_current(pty_id, generation, &control) {
            return;
        }
        if self.authorize_snapshot(pty_id, &auth, context, "exit").is_none() {
            if self.remove_attachment_if_current(pty_id, generation, &control) {
                control.kill();
            }
            return;
        }
        if !self.remove_attachment_if_current(pty_id, generation, &control) {
            return;
        }
        // Release relay-local state after the PTY has exited. Do not call
        // `kill`: whole-session controls may still own a process handle and
        // an exit callback must never send a late SIGKILL to a reused PID.
        control.release();
        (auth.send)(json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_exit",
            "ptyId": pty_id,
            "code": code,
        }));
    }

    fn handle_viewer_overflow(
        &self,
        pty_id: &str,
        generation: u64,
        gate: &Arc<Mutex<()>>,
        control: &Weak<dyn PtyControl>,
        context: &FrameContext,
    ) {
        // Serialize overflow teardown with output and exit callbacks. This
        // keeps a callback that already passed its identity check from
        // sending after the overflow error removes the attachment.
        let kill = {
            let _guard = gate.lock().expect("attachment gate");
            let Some(control) = control.upgrade() else { return };
            if self.remove_attachment_if_current(pty_id, generation, &control) {
                // Overflow is a terminal viewer failure. `pty_error` is the
                // protocol's close signal and tells the client to reattach;
                // do not emit a second `pty_exit` for the removed attachment.
                // The operational code is downgraded for pre-v7 Workers.
                send_pty_error(
                    context,
                    pty_id,
                    operational_pty_error_code(context, RelayPtyErrorCode::Overflow),
                    "pty viewer delivery queue overflowed; reattach to continue receiving output",
                );
                Some(control)
            } else {
                None
            }
        };
        if let Some(control) = kill {
            control.kill();
        }
    }

    /// Detach, NOT kill: idempotent, unknown ptyId tolerated.
    fn close(&self, pty_id: &str) {
        // Match `open`'s lock order. If opening still owns the reservation,
        // record cancellation and let it dispose the newly opened PTY.
        let opening = self.opening_ids.lock().expect("opening lock");
        if opening.contains(pty_id) {
            self.cancelled_openings
                .lock()
                .expect("cancelled openings lock")
                .insert(pty_id.to_owned());
            return;
        }
        drop(opening);
        // Capture the identity together with the gate. A replacement can be
        // installed while we wait for the old gate, so removal must prove
        // that the observed generation and control are still current.
        let observed =
            self.attachments.lock().expect("attach lock").get(pty_id).map(|attachment| {
                (
                    Arc::clone(&attachment.gate),
                    attachment.generation,
                    Arc::clone(&attachment.closing),
                    Arc::clone(&attachment.control),
                )
            });
        let removed = observed.and_then(|(gate, generation, closing, control)| {
            let _guard = gate.lock().expect("attachment gate");
            self.remove_attachment_if_current(pty_id, generation, &control)
                .then_some((closing, control))
        });
        if let Some((closing, control)) = removed {
            closing.store(true, Ordering::SeqCst);
            control.kill();
        }
    }

    fn attachment_is_current(
        &self,
        pty_id: &str,
        generation: u64,
        control: &Arc<dyn PtyControl>,
    ) -> bool {
        self.attachments.lock().expect("attach lock").get(pty_id).is_some_and(|attachment| {
            attachment.generation == generation
                && !attachment.closing.load(Ordering::SeqCst)
                && Arc::ptr_eq(&attachment.control, control)
        })
    }

    /// Remove an attachment only if the callback still belongs to the current
    /// generation. The identity check and removal share one lock, so
    /// replacement cannot slip between them.
    fn remove_attachment_if_current(
        &self,
        pty_id: &str,
        generation: u64,
        control: &Arc<dyn PtyControl>,
    ) -> bool {
        let mut attachments = self.attachments.lock().expect("attach lock");
        let matches = attachments.get(pty_id).is_some_and(|attachment| {
            attachment.generation == generation
                && !attachment.closing.load(Ordering::SeqCst)
                && Arc::ptr_eq(&attachment.control, control)
        });
        if matches {
            attachments.remove(pty_id);
        }
        matches
    }

    fn authorize(&self, pty_id: &str, context: &FrameContext, action: &str) -> Option<Attachment> {
        let auth = self.auth.lock().expect("auth lock").clone()?;
        let attachment = self.authorize_snapshot(pty_id, &auth, context, action);
        if attachment.is_none() {
            self.close(pty_id);
        }
        attachment
    }

    fn authorize_snapshot(
        &self,
        pty_id: &str,
        auth: &AuthSnapshot,
        context: &FrameContext,
        _action: &str,
    ) -> Option<Attachment> {
        let attachment = self.attachments.lock().expect("attach lock").get(pty_id)?.clone();
        let owner = auth.owner_user_id.as_deref();
        let allowed = !auth.trust.is_empty()
            && (auth.trust != "observe"
                || (owner.is_some() && owner == Some(attachment.actor_id.as_str())));
        if allowed {
            Some(attachment)
        } else {
            send_operational_pty_error(
                context,
                pty_id,
                RelayPtyErrorCode::TrustRevoked,
                "PTY trust changed. Restore trust, then reattach.",
                "PTY trust changed. Restore trust, then reattach.",
            );
            None
        }
    }

    fn close_authorized(&self, pty_id: &str, context: &FrameContext) {
        let _ = self.authorize(pty_id, context, "close");
        self.close(pty_id);
    }
}

/// A resolved open: what to echo, plus a deferred `start` that begins output.
struct Opened {
    generation: u64,
    gate: Arc<Mutex<()>>,
    created: bool,
    surface: Option<String>,
    control: Arc<dyn PtyControl>,
    /// Legacy protocol-5..9 raw daemons need one canonical resize after the
    /// `pty_opened` frame. Protocol-10 sizing queues perform that fence during
    /// join and must not receive a duplicate direct resize here.
    post_open_resize: bool,
    closing: Arc<AtomicBool>,
    start: Option<Box<dyn FnOnce() + Send>>,
    cleanup_armed: AtomicBool,
}

impl Opened {
    /// Transfer control ownership to the attachment table. Until this call,
    /// dropping the value is the cancellation/error cleanup path.
    fn disarm_cleanup(&self) {
        self.cleanup_armed.store(false, Ordering::Release);
    }
}

impl Drop for Opened {
    fn drop(&mut self) {
        if self.cleanup_armed.swap(false, Ordering::AcqRel) {
            self.closing.store(true, Ordering::Release);
            // The guard owns a just-opened control until attachment insertion;
            // cancellation must release sizing ownership and close the local
            // control socket rather than leaking a daemon attachment.
            self.control.kill();
        }
    }
}

// ---------------------------------------------------------------------------
// A viewer PTY control that pumps its events into the framing sinks
// ---------------------------------------------------------------------------

/// Bridges one PTY (its own source, e.g. a cmux-tui attach viewer) to the
/// framing sinks: banner first, then live bytes via `subscribe`.
fn drive_handle(
    output: Arc<dyn PtyOutput>,
    banner: Option<Vec<u8>>,
    on_data: DataSink,
    on_exit: ExitSink,
) {
    if let Some(banner) = banner {
        on_data(Bytes::from(banner));
    }
    output.subscribe(on_data, on_exit);
}

impl Inner {
    /// cmux-tui path: daemon owns the session; the viewer is disposable.
    #[allow(clippy::too_many_arguments)]
    async fn open_cmux(
        self: Arc<Self>,
        cmux_tui: &CmuxTui,
        session: &str,
        cols: u16,
        rows: u16,
        cwd: &Path,
        env: &HashMap<String, String>,
        pty_id: &str,
        server_roots: Option<&[String]>,
        context: &FrameContext,
    ) -> Result<Opened, String> {
        let socket_dir = self.deps.socket_dir();
        let ensured = self.deps.ensure_daemon(cmux_tui, session, &socket_dir, cwd, env).await?;
        let roots_scoped = context.local_roots.as_deref().is_some_and(|r| !r.is_empty())
            || server_roots.is_some_and(|r| !r.is_empty());
        if roots_scoped {
            let control = self
                .deps
                .connect_control(&ensured.socket_path)
                .await
                .map_err(|_| "cannot inspect existing daemon cwd".to_owned())?;
            let mut control_cleanup = ControlCleanupGuard::new(Arc::clone(&control));
            let Some(listed) = control.request("list-workspaces", json!({})).await else {
                return Err("cannot inspect existing daemon surfaces".to_owned());
            };
            if listed.get("ok").and_then(Value::as_bool) != Some(true) {
                return Err("cannot inspect existing daemon surfaces".to_owned());
            }
            let Some(data) = listed.get("data").and_then(Value::as_object) else {
                return Err("cannot inspect existing daemon surfaces".to_owned());
            };
            if !data.get("workspaces").is_some_and(Value::is_array) {
                return Err("cannot inspect existing daemon surfaces".to_owned());
            }
            if !workspace_shape_valid(listed.get("data")) {
                return Err("cannot inspect existing daemon surfaces".to_owned());
            }
            let tabs = match collect_pty_tabs_strict(listed.get("data")) {
                Ok(tabs) => tabs,
                Err(_) => return Err("cannot inspect existing daemon surfaces".to_owned()),
            };
            if tabs.len() > MAX_ENUM_TERMINALS || (tabs.is_empty() && !ensured.created) {
                return Err("cannot prove existing daemon cwd is within allowed roots".to_owned());
            }
            for tab in tabs {
                let Some(info) =
                    control.request("process-info", json!({ "surface": tab.surface_id })).await
                else {
                    return Err("cannot inspect existing surface cwd".to_owned());
                };
                if info.get("ok").and_then(Value::as_bool) != Some(true) {
                    return Err("cannot inspect existing surface cwd".to_owned());
                }
                let Some(actual) =
                    info.get("data").and_then(|v| v.get("cwd")).and_then(Value::as_str)
                else {
                    return Err(
                        "cannot prove existing surface cwd is within allowed roots".to_owned()
                    );
                };
                if actual.is_empty() || !Path::new(actual).is_absolute() {
                    return Err(
                        "cannot prove existing surface cwd is within allowed roots".to_owned()
                    );
                }
                if scoped_cwd(
                    Some(actual),
                    &self.home,
                    context.local_roots.as_deref(),
                    server_roots,
                )
                .is_err()
                {
                    return Err("existing surface cwd is outside allowed roots".to_owned());
                }
            }
            drop(control_cleanup);
        }
        let mut args = cmux_tui.prefix.clone();
        args.extend([
            "attach".to_owned(),
            "--session".to_owned(),
            session.to_owned(),
            "--socket".to_owned(),
            ensured.socket_path.to_string_lossy().into_owned(),
        ]);
        let mut handle = self
            .deps
            .spawn_pty(SpawnSpec {
                file: cmux_tui.file.clone(),
                args,
                cols,
                rows,
                cwd: cwd.to_path_buf(),
                env: env.clone(),
            })
            .await;
        // The PTY handle owns a cancellation guard until this synchronous
        // setup transfers its control surface into the attachment guard.
        handle.disarm_cleanup();
        let control = Arc::clone(&handle.control);
        let output = Arc::clone(&handle.output);
        let banner = handle.banner.clone();
        let control_identity = Arc::downgrade(&control);
        let (generation, gate, on_data, on_exit) = self.sinks(pty_id, context, control_identity);
        Ok(Opened {
            generation,
            gate,
            created: ensured.created,
            surface: None,
            control,
            post_open_resize: false,
            closing: Arc::new(AtomicBool::new(false)),
            start: Some(Box::new(move || drive_handle(output, banner, on_data, on_exit))),
            cleanup_armed: AtomicBool::new(true),
        })
    }

    /// Fallback: a relay-held $SHELL session with a scrollback ring, fanned
    /// out to any number of concurrent viewers.
    #[allow(clippy::too_many_arguments)]
    async fn open_shell(
        self: Arc<Self>,
        session: &str,
        cols: u16,
        rows: u16,
        cwd: &Path,
        env: &HashMap<String, String>,
        pty_id: &str,
        server_roots: Option<&[String]>,
        context: &FrameContext,
    ) -> Result<Opened, String> {
        let mut created = false;
        let (shell_session, viewer_id, released) = loop {
            // A failed liveness check may retry after the just-created shell
            // exits. Do not carry that attempt's `created` bit to a different
            // session map entry.
            created = false;
            let shell_session = loop {
                if let Some(existing) =
                    self.shell_sessions.lock().expect("shell lock").get(session).cloned()
                {
                    break existing;
                }
                let (notify, owner, waiter) = {
                    let mut starting = self.shell_starting.lock().expect("shell starting lock");
                    if let Some(notify) = starting.get(session) {
                        let notify = Arc::clone(notify);
                        // Register before releasing the map lock. The owner may
                        // finish immediately; creating this future later could
                        // miss `notify_waiters`.
                        let waiter = Arc::clone(&notify).notified_owned();
                        (notify, false, Some(waiter))
                    } else {
                        let notify = Arc::new(Notify::new());
                        starting.insert(session.to_owned(), Arc::clone(&notify));
                        (notify, true, None)
                    }
                };
                if !owner {
                    waiter.expect("shell waiter").await;
                    continue;
                }
                if self.shell_sessions.lock().expect("shell lock").len() >= self.max_ptys {
                    self.shell_starting.lock().expect("shell starting lock").remove(session);
                    notify.notify_waiters();
                    return Err(format!("this relay caps persistent shells at {}", self.max_ptys));
                }
                let mut reservation = ShellStartReservation {
                    inner: Arc::clone(&self),
                    session: session.to_owned(),
                    notify,
                    active: true,
                };
                {
                    let shell = self.deps.shell();
                    let mut handle = self
                        .deps
                        .spawn_pty(SpawnSpec {
                            file: shell,
                            args: Vec::new(),
                            cols,
                            rows,
                            cwd: cwd.to_path_buf(),
                            env: env.clone(),
                        })
                        .await;
                    let control = Arc::clone(&handle.control);
                    let output = Arc::clone(&handle.output);
                    let banner = handle.banner.clone();
                    handle.disarm_cleanup();
                    let shell_session = Arc::new(ShellSession {
                        control,
                        resize_lock: Mutex::new(()),
                        banner,
                        inner: Mutex::new(ShellInner {
                            ring: VecDeque::new(),
                            ring_size: 0,
                            alive: true,
                            exit_code: None,
                            viewers: Vec::new(),
                            viewer_grids: HashMap::new(),
                            applied_grid: Some(SizingGrid { cols, rows }),
                        }),
                    });
                    // Session-level plumbing runs for the session's whole life:
                    // the ring fills even while detached, and exit ends the
                    // session for every attached viewer. One fanout sink is
                    // subscribed to the session PTY; per-viewer sinks live in the
                    // viewer set.
                    let session_name = session.to_owned();
                    let scrollback_limit = self.scrollback_limit;
                    let data_session = Arc::clone(&shell_session);
                    let exit_session = Arc::clone(&shell_session);
                    let manager = Arc::clone(&self);
                    let on_session_data: DataSink = Arc::new(move |chunk: Bytes| {
                        let (viewers_to_drain, viewers_overflowed) = {
                            let mut inner = data_session.inner.lock().expect("shell inner lock");
                            inner.ring_size += chunk.len();
                            inner.ring.push_back(chunk.clone());
                            while inner.ring_size > scrollback_limit && inner.ring.len() > 1 {
                                let Some(dropped) = inner.ring.pop_front() else { break };
                                inner.ring_size -= dropped.len();
                            }
                            let mut viewers_to_drain = Vec::new();
                            let mut viewers_overflowed = Vec::new();
                            for viewer in &inner.viewers {
                                match viewer.delivery.push_data(chunk.clone()) {
                                    ViewerDeliveryAction::Drain => {
                                        viewers_to_drain.push(Arc::clone(&viewer.delivery));
                                    }
                                    ViewerDeliveryAction::Overflow => {
                                        viewers_overflowed.push(Arc::clone(&viewer.delivery));
                                    }
                                    ViewerDeliveryAction::None => {}
                                }
                            }
                            (viewers_to_drain, viewers_overflowed)
                        };
                        for delivery in viewers_overflowed {
                            delivery.notify_overflow();
                        }
                        for delivery in viewers_to_drain {
                            delivery.drain();
                        }
                    });
                    let on_session_exit: ExitSink = Arc::new(move |code: i64| {
                        let (viewers_to_drain, viewers_overflowed) = {
                            let mut inner = exit_session.inner.lock().expect("shell inner lock");
                            if !inner.alive {
                                return;
                            }
                            inner.alive = false;
                            inner.exit_code = Some(code);
                            inner.viewer_grids.clear();
                            let mut viewers_to_drain = Vec::new();
                            let mut viewers_overflowed = Vec::new();
                            for viewer in std::mem::take(&mut inner.viewers) {
                                match viewer.delivery.finish(code) {
                                    ViewerDeliveryAction::Drain => {
                                        viewers_to_drain.push(viewer.delivery);
                                    }
                                    ViewerDeliveryAction::Overflow => {
                                        viewers_overflowed.push(viewer.delivery);
                                    }
                                    ViewerDeliveryAction::None => {}
                                }
                            }
                            (viewers_to_drain, viewers_overflowed)
                        };
                        manager.remove_shell_session_if_current(&session_name, &exit_session);
                        for delivery in viewers_overflowed {
                            delivery.notify_overflow();
                        }
                        for delivery in viewers_to_drain {
                            delivery.drain();
                        }
                    });
                    self.shell_sessions
                        .lock()
                        .expect("shell lock")
                        .insert(session.to_owned(), Arc::clone(&shell_session));
                    // Register before subscribing so a synchronous buffered exit
                    // can remove this session instead of being overwritten by a
                    // later insertion.
                    output.subscribe(on_session_data, on_session_exit);
                    self.shell_starting.lock().expect("shell starting lock").remove(session);
                    reservation.active = false;
                    reservation.notify.notify_waiters();
                    created = true;
                    break shell_session;
                }
            };

            // A stable viewer id lets release remove exactly this sink. The
            // liveness check and grid insertion share the resize lock and the
            // session lock, so an already-exited session cannot be returned.
            let viewer_id = next_viewer_id();
            let released = Arc::new(AtomicBool::new(false));
            if !shell_session.set_viewer_grid(viewer_id, SizingGrid { cols, rows }, &released) {
                self.remove_shell_session_if_current(session, &shell_session);
                continue;
            }
            if !created
                && (context.local_roots.as_deref().is_some_and(|r| !r.is_empty())
                    || server_roots.is_some_and(|r| !r.is_empty()))
            {
                shell_session.release_viewer(viewer_id);
                return Err("cannot reattach existing shell under scoped roots".to_owned());
            }
            break (shell_session, viewer_id, released);
        };
        let closing = Arc::new(AtomicBool::new(false));

        // The per-attachment control proxies onto the session pty but its
        // kill() only unhooks this viewer (release), never the session.
        let proxy = Arc::new(ShellViewerControl {
            session: Arc::clone(&shell_session),
            viewer_id,
            released: Arc::clone(&released),
            delivery: OnceLock::new(),
        });
        let proxy_control: Arc<dyn PtyControl> = proxy.clone();
        let control_identity = Arc::downgrade(&proxy_control);
        let (generation, gate, on_data, on_exit) = self.sinks(pty_id, context, control_identity);
        let overflow_inner = Arc::clone(&self);
        let overflow_context = context.clone();
        let overflow_pty_id = pty_id.to_owned();
        let overflow_gate = Arc::clone(&gate);
        let overflow_control = Arc::downgrade(&proxy_control);
        let on_overflow: Arc<dyn Fn() + Send + Sync> = Arc::new(move || {
            overflow_inner.handle_viewer_overflow(
                &overflow_pty_id,
                generation,
                &overflow_gate,
                &overflow_control,
                &overflow_context,
            );
        });
        let delivery = ViewerDelivery::with_overflow(on_data, on_exit, on_overflow);
        assert!(
            proxy.delivery.set(Arc::clone(&delivery)).is_ok(),
            "shell viewer delivery initialized"
        );

        let start_session = Arc::clone(&shell_session);
        let start_delivery = Arc::clone(&delivery);
        let start: Box<dyn FnOnce() + Send> = Box::new(move || {
            if released.load(Ordering::SeqCst) {
                return;
            }
            // Register an inactive delivery and seed its replay while holding
            // the shell lock. Live bytes arriving after this point queue behind
            // the replay instead of racing past it.
            let (should_activate, seed_overflowed) = {
                let mut inner = start_session.inner.lock().expect("shell inner lock");
                if released.load(Ordering::SeqCst) {
                    (false, false)
                } else {
                    let banner = created.then(|| start_session.banner.clone()).flatten();
                    let replay = (inner.ring_size > 0).then(|| {
                        inner.ring.iter().flat_map(|c| c.iter().copied()).collect::<Vec<u8>>()
                    });
                    let seed_overflowed =
                        start_delivery.seed(banner.map(Bytes::from), replay.map(Bytes::from));
                    if inner.alive && !seed_overflowed {
                        inner.viewers.push(ViewerSink {
                            id: viewer_id,
                            delivery: Arc::clone(&start_delivery),
                        });
                    }
                    if !inner.alive
                        && !seed_overflowed
                        && let Some(code) = inner.exit_code
                    {
                        let _ = start_delivery.finish(code);
                    }
                    (true, seed_overflowed)
                }
            };
            if seed_overflowed {
                start_delivery.notify_overflow();
            } else if should_activate && start_delivery.activate() {
                start_delivery.drain();
            }
        });

        Ok(Opened {
            generation,
            gate,
            created,
            surface: None,
            control: proxy,
            post_open_resize: false,
            closing,
            start: Some(start),
            cleanup_armed: AtomicBool::new(true),
        })
    }
}

struct ShellViewerControl {
    session: Arc<ShellSession>,
    viewer_id: u64,
    released: Arc<AtomicBool>,
    delivery: OnceLock<Arc<ViewerDelivery>>,
}

impl ShellSession {
    /// Register or update one viewer only while the session is alive.
    /// Returns false when the process has already exited, so callers can
    /// discard the stale map entry and acquire a replacement.
    fn set_viewer_grid(&self, viewer_id: u64, grid: SizingGrid, released: &AtomicBool) -> bool {
        // Serialize the state calculation with the actual PTY ioctl. Without
        // this guard, concurrent callbacks can calculate 100x30 and 90x20,
        // then deliver the older 100x30 resize last.
        let _resize_guard = self.resize_lock.lock().expect("shell resize lock");
        if released.load(Ordering::Acquire) {
            return false;
        }
        let resize = {
            let mut inner = self.inner.lock().expect("shell inner lock");
            if !inner.alive {
                return false;
            }
            inner.viewer_grids.insert(viewer_id, grid);
            let next = smallest_shell_grid(&inner.viewer_grids);
            if inner.applied_grid == next {
                None
            } else {
                inner.applied_grid = next;
                next
            }
        };
        if let Some(grid) = resize {
            self.control.resize(grid.cols, grid.rows);
        }
        true
    }

    fn release_viewer(&self, viewer_id: u64) {
        let _resize_guard = self.resize_lock.lock().expect("shell resize lock");
        let resize = {
            let mut inner = self.inner.lock().expect("shell inner lock");
            inner.viewers.retain(|viewer| viewer.id != viewer_id);
            inner.viewer_grids.remove(&viewer_id);
            if !inner.alive || inner.viewer_grids.is_empty() {
                None
            } else {
                let next = smallest_shell_grid(&inner.viewer_grids);
                if inner.applied_grid == next {
                    None
                } else {
                    inner.applied_grid = next;
                    next
                }
            }
        };
        if let Some(grid) = resize {
            self.control.resize(grid.cols, grid.rows);
        }
    }
}

impl ShellViewerControl {
    fn release(&self) {
        if self.released.swap(true, Ordering::SeqCst) {
            return;
        }
        self.session.release_viewer(self.viewer_id);
        // The viewer may already have exited and been removed from the shell
        // set. Release the delivery in either case so a queued handoff cannot
        // emit after the attachment has been closed.
        if let Some(delivery) = self.delivery.get() {
            delivery.release();
        }
    }
}

impl PtyControl for ShellViewerControl {
    fn write(&self, data: &[u8]) {
        self.session.control.write(data);
    }
    fn resize(&self, cols: u16, rows: u16) {
        self.session.set_viewer_grid(self.viewer_id, SizingGrid { cols, rows }, &self.released);
    }
    fn pause(&self) {
        self.session.control.pause();
    }
    fn resume(&self) {
        self.session.control.resume();
    }
    fn kill(&self) {
        self.release();
    }
}

fn next_viewer_id() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// Raw single-terminal attach (W86): speak the cmux-tui control protocol
// directly. attach-surface streams ONE terminal's PTY bytes (vt-state replay
// first), send writes input, resize-surface resizes. No node-pty involved.
// ---------------------------------------------------------------------------

fn decode_b64_field(event: &Value, field: &str) -> Option<Bytes> {
    event
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| BASE64.decode(value).ok())
        .map(Bytes::from)
}

/// Buffers control-stream output until start() attaches the live sinks, then
/// drains one FIFO queue (vt-state/output precede the attach response, and
/// pty_opened must precede all output).
struct TerminalStream {
    state: Mutex<TerminalStreamState>,
    overflowed: AtomicBool,
}

struct TerminalStreamState {
    live_data: Option<Arc<dyn Fn(Bytes) + Send + Sync>>,
    live_exit: Option<Arc<dyn Fn(i64) + Send + Sync>>,
    backlog: VecDeque<Bytes>,
    backlog_bytes: usize,
    // Keep exit behind bytes that arrive before the live handoff drains.
    pending_exit: Option<i64>,
    delivering: bool,
    ended: bool,
}

impl TerminalStream {
    fn new() -> TerminalStream {
        TerminalStream {
            state: Mutex::new(TerminalStreamState {
                live_data: None,
                live_exit: None,
                backlog: VecDeque::new(),
                backlog_bytes: 0,
                pending_exit: None,
                delivering: false,
                ended: false,
            }),
            overflowed: AtomicBool::new(false),
        }
    }
    /// Mark the queue as owned by a drainer, if the live sinks are installed.
    fn start_delivery(state: &mut TerminalStreamState) -> bool {
        if state.delivering
            || (state.backlog.is_empty() && state.pending_exit.is_none())
            || state.live_data.is_none()
            || state.live_exit.is_none()
        {
            return false;
        }
        state.delivering = true;
        true
    }

    /// Deliver queued events serially, without holding the stream mutex while
    /// user code runs. Events accepted during a callback stay behind the
    /// events already queued for replay.
    fn drain(&self) {
        loop {
            let next = {
                let mut state = self.state.lock().expect("terminal stream lock");
                if let Some(chunk) = state.backlog.pop_front() {
                    (Some(chunk), None, state.live_data.clone(), state.live_exit.clone())
                } else if let Some(code) = state.pending_exit.take() {
                    (None, Some(code), state.live_data.clone(), state.live_exit.clone())
                } else {
                    state.delivering = false;
                    return;
                }
            };
            let (chunk, exit, on_data, on_exit) = next;
            match (chunk, exit, on_data, on_exit) {
                (Some(chunk), _, Some(on_data), _) => on_data(chunk),
                (None, Some(code), _, Some(on_exit)) => on_exit(code),
                _ => {}
            }
        }
    }

    fn push_output(&self, chunk: Bytes) {
        let should_drain = {
            let mut state = self.state.lock().expect("terminal stream lock");
            // A raw attach cannot replay an unbounded pre-open stream.  Keep
            // the bytes already accepted, but terminate the stream explicitly
            // when the first complete chunk would exceed the cap.  Returning
            // here used to discard bytes with no wire-visible indication,
            // leaving the client with a corrupted terminal that looked live.
            if state.ended {
                return;
            }
            if state.live_data.is_none() {
                let remaining = RAW_ATTACH_BACKLOG_CAP.saturating_sub(state.backlog_bytes);
                if chunk.len() > remaining {
                    state.ended = true;
                    self.overflowed.store(true, Ordering::Release);
                    state.pending_exit = Some(1);
                    Self::start_delivery(&mut state)
                } else {
                    state.backlog_bytes += chunk.len();
                    state.backlog.push_back(chunk);
                    Self::start_delivery(&mut state)
                }
            } else {
                state.backlog.push_back(chunk);
                Self::start_delivery(&mut state)
            }
        };
        if should_drain {
            self.drain();
        }
    }

    fn overflowed(&self) -> bool {
        self.overflowed.load(Ordering::Acquire)
    }

    fn finish_exit(&self, code: i64) {
        let should_drain = {
            let mut state = self.state.lock().expect("terminal stream lock");
            if state.ended {
                return;
            }
            state.ended = true;
            state.pending_exit = Some(code);
            Self::start_delivery(&mut state)
        };
        if should_drain {
            self.drain();
        }
    }

    fn go_live(
        &self,
        on_data: Arc<dyn Fn(Bytes) + Send + Sync>,
        on_exit: Arc<dyn Fn(i64) + Send + Sync>,
    ) {
        let should_drain = {
            let mut state = self.state.lock().expect("terminal stream lock");
            state.live_data = Some(Arc::clone(&on_data));
            state.live_exit = Some(Arc::clone(&on_exit));
            state.backlog_bytes = 0;
            Self::start_delivery(&mut state)
        };
        if should_drain {
            self.drain();
        }
    }
}

struct ControlTerminalControl {
    control: Arc<dyn ControlHandle>,
    surface_id: i64,
    sizing: Option<Arc<TerminalSizingLease>>,
    queue: Option<Arc<OrderedControlEndpoint>>,
    ended: AtomicBool,
}

impl PtyControl for ControlTerminalControl {
    fn write(&self, data: &[u8]) {
        if self.sizing.is_some() {
            let Some(queue) = &self.queue else {
                // A protocol-10+ control must never bypass the sizing actor.
                // The open path rejects this state; keep the proxy fail
                // closed if a later lifecycle race drops its endpoint.
                self.release();
                return;
            };
            queue.enqueue_input(data);
        } else {
            // Protocols without shared sizing use the legacy whole-session
            // path. Protocol-10+ raw attachments always install `queue` and
            // take the fail-closed branch above if that invariant is broken.
            self.control
                .send("send", json!({ "surface": self.surface_id, "bytes": BASE64.encode(data) }));
        }
    }
    fn resize(&self, cols: u16, rows: u16) {
        if let Some(sizing) = &self.sizing {
            if self.queue.is_none() {
                // Do not send a direct resize after shared sizing setup has
                // failed. Such a frame could race a retired transport.
                self.release();
                return;
            }
            sizing.update(SizingGrid { cols, rows });
        } else {
            // Legacy protocol path: no relay sizing coordinator exists.
            self.control.send(
                "resize-surface",
                json!({ "surface": self.surface_id, "cols": cols, "rows": rows }),
            );
        }
    }
    fn pause(&self) {
        self.control.pause();
    }
    fn resume(&self) {
        self.control.resume();
    }
    fn release(&self) {
        if self.ended.swap(true, Ordering::AcqRel) {
            return;
        }
        let sizing_handoff = self.sizing.as_ref().is_some_and(|sizing| sizing.leave());
        if !sizing_handoff {
            // Legacy or setup path: protocol-10+ raw attachments close through
            // the shared sizing queue. End only this control socket here.
            self.control.end();
        }
    }
    fn kill(&self) {
        self.release();
    }
}

impl Drop for ControlTerminalControl {
    fn drop(&mut self) {
        self.release();
    }
}

fn as_array(value: Option<&Value>) -> Vec<Value> {
    value.and_then(Value::as_array).cloned().unwrap_or_default()
}

struct PtyTab {
    surface_id: i64,
    resource_id: Option<String>,
    title: String,
    name: String,
    workspace: String,
}

/// Walk a list-workspaces tree into flat pty-tab records.
fn collect_pty_tabs(data: Option<&Value>) -> Vec<PtyTab> {
    let mut tabs = Vec::new();
    for workspace in as_array(data.and_then(|d| d.get("workspaces"))) {
        let workspace_name =
            workspace.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
        for screen in as_array(workspace.get("screens")) {
            for pane in as_array(screen.get("panes")) {
                for tab in as_array(pane.get("tabs")) {
                    if tab.get("kind").and_then(Value::as_str) != Some("pty")
                        || tab.get("dead").and_then(Value::as_bool) == Some(true)
                    {
                        continue;
                    }
                    let Some(surface_id) = tab.get("surface").and_then(Value::as_i64) else {
                        continue;
                    };
                    tabs.push(PtyTab {
                        surface_id,
                        resource_id: tab
                            .get("terminal_resource_id")
                            .and_then(Value::as_str)
                            .filter(|value| !value.is_empty())
                            .map(str::to_owned),
                        title: tab
                            .get("title")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        name: tab
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        workspace: workspace_name.clone(),
                    });
                }
            }
        }
    }
    tabs
}

fn collect_pty_tabs_strict(data: Option<&Value>) -> Result<Vec<PtyTab>, ()> {
    let Some(workspaces) = data.and_then(|d| d.get("workspaces")).and_then(Value::as_array) else {
        return Err(());
    };
    let mut tabs = Vec::new();
    for workspace in workspaces {
        let Some(screens) = workspace.get("screens").and_then(Value::as_array) else {
            return Err(());
        };
        for screen in screens {
            let Some(panes) = screen.get("panes").and_then(Value::as_array) else { return Err(()) };
            for pane in panes {
                let Some(entries) = pane.get("tabs").and_then(Value::as_array) else {
                    return Err(());
                };
                for tab in entries {
                    if tab.get("kind").and_then(Value::as_str) != Some("pty")
                        || tab.get("dead").and_then(Value::as_bool) == Some(true)
                    {
                        continue;
                    }
                    let Some(surface_id) = tab.get("surface").and_then(Value::as_i64) else {
                        return Err(());
                    };
                    tabs.push(PtyTab {
                        surface_id,
                        resource_id: tab
                            .get("terminal_resource_id")
                            .and_then(Value::as_str)
                            .filter(|v| !v.is_empty())
                            .map(str::to_owned),
                        title: tab
                            .get("title")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        name: tab
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        workspace: workspace
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                    });
                    if tabs.len() > MAX_ENUM_TERMINALS {
                        return Err(());
                    }
                }
            }
        }
    }
    Ok(tabs)
}

fn workspace_shape_valid(data: Option<&Value>) -> bool {
    let Some(workspaces) = data.and_then(|d| d.get("workspaces")).and_then(Value::as_array) else {
        return false;
    };
    workspaces.iter().all(|workspace| {
        workspace.get("screens").and_then(Value::as_array).is_some_and(|screens| {
            screens.iter().all(|screen| {
                screen.get("panes").and_then(Value::as_array).is_some_and(|panes| {
                    panes.iter().all(|pane| {
                        pane.get("tabs").and_then(Value::as_array).is_some_and(|tabs| {
                            tabs.iter().all(|tab| {
                                tab.get("kind").and_then(Value::as_str) == Some("pty")
                                    || tab.get("kind").and_then(Value::as_str).is_some()
                            })
                        })
                    })
                })
            })
        })
    })
}

/// Compact cwd for picker subtitles: $HOME -> ~, keep the last two parts.
fn shorten_cwd(cwd: &str, home: &str) -> String {
    if cwd.is_empty() {
        return String::new();
    }
    let collapsed = if !home.is_empty() && cwd.starts_with(home) {
        format!("~{}", &cwd[home.len()..])
    } else {
        cwd.to_owned()
    };
    let parts: Vec<&str> = collapsed.split('/').filter(|p| !p.is_empty()).collect();
    if collapsed.starts_with('~') || parts.len() <= 2 {
        return collapsed;
    }
    format!("…/{}", parts[parts.len() - 2..].join("/"))
}

impl Inner {
    #[allow(clippy::too_many_arguments)]
    async fn open_cmux_terminal(
        self: Arc<Self>,
        cmux_tui: &CmuxTui,
        session: &str,
        surface_ref: &str,
        cols: u16,
        rows: u16,
        cwd: &Path,
        env: &HashMap<String, String>,
        pty_id: &str,
        server_roots: Option<&[String]>,
        context: &FrameContext,
    ) -> Result<Option<Opened>, (RelayPtyErrorCode, String)> {
        let socket_dir = self.deps.socket_dir();
        let ensured = self
            .deps
            .ensure_daemon(cmux_tui, session, &socket_dir, cwd, env)
            .await
            // Daemon setup errors can contain paths, command output, or other
            // control-plane details. Keep those details on the machine side;
            // the PTY wire only exposes a stable product-level failure.
            .map_err(|_| {
                (
                    RelayPtyErrorCode::Failed,
                    "terminal service could not prepare the session".to_owned(),
                )
            })?;
        let control = match self.deps.connect_control(&ensured.socket_path).await {
            Ok(control) => control,
            Err(_) => return Ok(None), // degrade to the whole-session attach
        };
        let mut control_cleanup = ControlCleanupGuard::new(Arc::clone(&control));

        let identify = control.request("identify", json!({})).await;
        let info = identify.as_ref().filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true));
        let protocol = info
            .and_then(|v| v.get("data"))
            .and_then(|d| d.get("protocol"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        if protocol < CONTROL_MIN_PROTOCOL {
            return Ok(None);
        }
        let capabilities: Vec<String> = info
            .and_then(|v| v.get("data"))
            .map(|d| as_array(d.get("capabilities")))
            .unwrap_or_default()
            .into_iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect();

        // Resolve the ref: numeric surface id directly, else via the tree.
        let mut surface_id: Option<i64> = if surface_ref.bytes().all(|b| b.is_ascii_digit()) {
            surface_ref.parse().ok()
        } else {
            None
        };
        if surface_id.is_none() {
            let Some(listed) = control.request("list-workspaces", json!({})).await else {
                return Err((
                    RelayPtyErrorCode::Failed,
                    "terminal could not be resolved".to_owned(),
                ));
            };
            if listed.get("ok").and_then(Value::as_bool) != Some(true) {
                return Err((
                    RelayPtyErrorCode::Failed,
                    "terminal could not be resolved".to_owned(),
                ));
            }
            let tabs = match collect_pty_tabs_strict(listed.get("data")) {
                Ok(tabs) => tabs,
                Err(()) => {
                    return Err((
                        RelayPtyErrorCode::Failed,
                        "terminal could not be resolved".to_owned(),
                    ));
                }
            };
            surface_id = tabs
                .iter()
                .find(|tab| tab.resource_id.as_deref() == Some(surface_ref))
                .map(|tab| tab.surface_id);
        }
        let Some(surface_id) = surface_id else {
            // Typed refusal: the terminal died with its process (or its tab
            // closed) — permanent, so clients render an ended state and
            // never offer a retry.
            return Err((
                RelayPtyErrorCode::TerminalGone,
                "requested terminal is no longer available".to_owned(),
            ));
        };

        let roots_scoped = context.local_roots.as_deref().is_some_and(|r| !r.is_empty())
            || server_roots.is_some_and(|r| !r.is_empty());
        if roots_scoped {
            let info = control.request("process-info", json!({ "surface": surface_id })).await;
            let actual = info
                .as_ref()
                .filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true))
                .and_then(|v| v.get("data"))
                .and_then(|v| v.get("cwd"))
                .and_then(Value::as_str);
            if actual.is_none_or(|value| value.is_empty() || !Path::new(value).is_absolute()) {
                return Err((
                    RelayPtyErrorCode::Failed,
                    "cannot prove existing surface cwd is within allowed roots".to_owned(),
                ));
            }
            let Some(actual) = actual else {
                return Err((
                    RelayPtyErrorCode::Failed,
                    "cannot prove existing surface cwd is within allowed roots".to_owned(),
                ));
            };
            if scoped_cwd(Some(actual), &self.home, context.local_roots.as_deref(), server_roots)
                .is_err()
            {
                return Err((
                    RelayPtyErrorCode::Failed,
                    "existing surface cwd is outside allowed roots".to_owned(),
                ));
            }
        }

        let shared_sizing = protocol >= CLIENT_SIZING_MIN_PROTOCOL;
        let sizing = shared_sizing.then(|| {
            let viewer_id = self.next_sizing_id.fetch_add(1, Ordering::Relaxed);
            TerminalSizingLease::new(
                &self.sizing,
                SizingKey { socket_path: ensured.socket_path.clone(), surface_id },
                viewer_id,
                surface_id,
            )
        });
        if let Some(sizing) = &sizing {
            control_cleanup.set_sizing(Arc::clone(sizing));
        }
        let stream = Arc::new(TerminalStream::new());
        let event_stream = Arc::clone(&stream);
        let event_sizing = sizing.clone();
        let event_control = Arc::downgrade(&control);
        control.on_event(Box::new(move |event| {
            if event.get("surface").and_then(Value::as_i64) != Some(surface_id) {
                return;
            }
            match event.get("event").and_then(Value::as_str).unwrap_or_default() {
                "vt-state" | "output" => {
                    if let Some(bytes) = decode_b64_field(event, "data") {
                        event_stream.push_output(bytes);
                    }
                }
                "resized" => {
                    if let Some(replay) = decode_b64_field(event, "replay") {
                        let mut reset = b"\x1bc".to_vec();
                        reset.extend_from_slice(&replay);
                        event_stream.push_output(Bytes::from(reset));
                    }
                }
                "detached" => {
                    let sizing_handoff = event_sizing.as_ref().is_some_and(|sizing| sizing.leave());
                    // A detached raw view no longer needs the control socket.
                    // End it before handing the terminal exit to the relay so
                    // a stale sizing request cannot race a surviving viewer.
                    if !sizing_handoff && let Some(control) = event_control.upgrade() {
                        control.end();
                    }
                    event_stream.finish_exit(0);
                }
                _ => {}
            }
        }));
        let close_stream = Arc::clone(&stream);
        let close_sizing = sizing.clone();
        control.on_close(Box::new(move || {
            if let Some(sizing) = &close_sizing {
                let _ = sizing.leave();
            }
            close_stream.finish_exit(0);
        }));

        let attach_initial_size = capabilities.iter().any(|c| c == "attach-initial-size");
        let attach_params = if attach_initial_size {
            json!({ "surface": surface_id, "cols": cols, "rows": rows })
        } else {
            json!({ "surface": surface_id })
        };
        let attached = control.request("attach-surface", attach_params).await;
        if attached.as_ref().and_then(|v| v.get("ok")).and_then(Value::as_bool) != Some(true) {
            return Err((RelayPtyErrorCode::Failed, "terminal attachment failed".to_owned()));
        }
        if let Some(sizing) = &sizing {
            // A protocol-10+ attach size is only a retained report. Report
            // once more through a verified request, then claim geometry
            // authority before later resize frames can change the PTY grid.
            // The worker is deliberately detached from open: a slow or
            // unavailable control reply must not hold `pty_opened` for the
            // full three-second request budget. Subsequent resize requests
            // are coalesced by the same worker and converge the grid.
            if sizing.join(Arc::clone(&control), SizingGrid { cols, rows }).is_none() {
                // Protocol-10+ attachments require the shared sizing queue.
                // Do not emit `pty_opened` and fall back to direct control
                // writes when the target is retired or its close barrier has
                // failed: that would bypass the fail-closed generation fence.
                return Err((
                    RelayPtyErrorCode::Failed,
                    "terminal sizing coordination is unavailable; reconnect and retry".to_owned(),
                ));
            }
        } else {
            // The client sends one canonical resize after `pty_opened` for
            // protocol 5-9. Do not send a second pre-open resize here: the
            // post-open command is the ordering fence before pending input.
        }

        // The lease installs the queue before `pty_opened` is emitted. The
        // proxy uses that exact queue for every later input so a resize that
        // was accepted before open cannot be overtaken on the control FIFO.
        let sizing_queue = if let Some(sizing) = &sizing {
            let Some(queue) = sizing.queue() else {
                // The lease was reported as joined, but its endpoint was
                // retired before the proxy was created. Keep the same
                // fail-closed rule as the join check above.
                return Err((
                    RelayPtyErrorCode::Failed,
                    "terminal sizing coordination is unavailable; reconnect and retry".to_owned(),
                ));
            };
            Some(queue)
        } else {
            None
        };

        let proxy = Arc::new(ControlTerminalControl {
            control,
            surface_id,
            sizing,
            queue: sizing_queue,
            ended: AtomicBool::new(false),
        });
        let proxy_control: Arc<dyn PtyControl> = proxy.clone();
        let control_identity = Arc::downgrade(&proxy_control);
        let (generation, gate, on_data, _) = self.sinks(pty_id, context, control_identity.clone());
        let relay = Arc::clone(&self);
        let context_for_exit = context.clone();
        let pty_id_for_exit = pty_id.to_owned();
        let stream_for_exit = Arc::clone(&stream);
        let gate_for_exit = Arc::clone(&gate);
        let on_exit: ExitSink = Arc::new(move |code| {
            let kill = {
                let _guard = gate_for_exit.lock().expect("attachment gate");
                relay.emit_raw_exit(
                    &pty_id_for_exit,
                    generation,
                    Some(&stream_for_exit),
                    code,
                    &context_for_exit,
                    &control_identity,
                )
            };
            if let Some(control) = kill {
                control.kill();
            }
        });
        let start_stream = Arc::clone(&stream);
        control_cleanup.disarm();
        Ok(Some(Opened {
            generation,
            gate,
            created: ensured.created,
            surface: Some(surface_ref.to_owned()),
            control: proxy,
            post_open_resize: !shared_sizing && !attach_initial_size,
            closing: Arc::new(AtomicBool::new(false)),
            start: Some(Box::new(move || start_stream.go_live(on_data, on_exit))),
            cleanup_armed: AtomicBool::new(true),
        }))
    }

    async fn list_surfaces(self: Arc<Self>, frame: &Value, context: &FrameContext) {
        let request_id =
            frame.get("requestId").and_then(Value::as_str).unwrap_or_default().to_owned();
        if request_id.is_empty() {
            return;
        }
        let mut surfaces: Vec<Value> = Vec::new();
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let socket_dir = self.deps.socket_dir();
        let mut sessions: Vec<String> = Vec::new();
        // Discovery only scans the preferred runtime directory and cannot
        // reverse a digest socket name back to its original session. Callers
        // must open a session explicitly when the core resolver selected a
        // fallback directory or hashed leaf.
        if let Ok(entries) = self.deps.read_dir(&socket_dir).await {
            for name in entries {
                let Some(id) = name.strip_suffix(".sock") else { continue };
                if !session_name_ok(id) || seen.contains(id) {
                    continue;
                }
                seen.insert(id.to_owned());
                sessions.push(id.to_owned());
            }
        }
        // Inner terminals per session (W86), best-effort.
        let home = self.home.display().to_string();
        for session in &sessions {
            if surfaces.len() >= MAX_ENUM_SURFACES {
                break;
            }
            surfaces.push(json!({
                "kind": "session",
                "id": session,
                "title": session,
                "subtitle": "cmux-tui",
            }));
            let socket_path = socket_dir.join(format!("{session}.sock"));
            for terminal in self.list_session_terminals(&socket_path, &home).await {
                if surfaces.len() >= MAX_ENUM_SURFACES {
                    break;
                }
                surfaces.push(json!({
                    "kind": "terminal",
                    "id": format!("{session}:{}", terminal.0),
                    "title": terminal.1,
                    "subtitle": format!("{session} · raw terminal"),
                }));
            }
        }
        {
            let shell_sessions = self.shell_sessions.lock().expect("shell lock");
            for (name, session) in shell_sessions.iter() {
                if surfaces.len() >= MAX_ENUM_SURFACES {
                    break;
                }
                let alive = session.inner.lock().expect("shell inner lock").alive;
                if !alive || seen.contains(name) {
                    continue;
                }
                seen.insert(name.clone());
                surfaces.push(json!({
                    "kind": "session",
                    "id": name,
                    "title": name,
                    "subtitle": "shell",
                }));
            }
        }
        (context.send)(json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "surface_list_result",
            "requestId": request_id,
            "surfaces": surfaces,
        }));
    }

    /// Enumerate the live terminals inside one cmux-tui session (W86):
    /// (ref, title) pairs, best-effort and bounded.
    async fn list_session_terminals(
        &self,
        socket_path: &Path,
        home: &str,
    ) -> Vec<(String, String)> {
        let Ok(control) = self.deps.connect_control(socket_path).await else {
            return Vec::new();
        };
        let identify = control.request("identify", json!({})).await;
        let protocol = identify
            .as_ref()
            .filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true))
            .and_then(|v| v.get("data"))
            .and_then(|d| d.get("protocol"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        if protocol < CONTROL_MIN_PROTOCOL {
            control.end();
            return Vec::new();
        }
        let listed = control.request("list-workspaces", json!({})).await;
        let tabs: Vec<PtyTab> = listed
            .as_ref()
            .filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true))
            .map(|v| collect_pty_tabs(v.get("data")))
            .unwrap_or_default()
            .into_iter()
            .take(MAX_ENUM_TERMINALS)
            .collect();
        let mut out = Vec::new();
        for tab in tabs {
            let reference = tab.resource_id.clone().unwrap_or_else(|| tab.surface_id.to_string());
            let mut title =
                if !tab.title.is_empty() { tab.title.clone() } else { tab.name.clone() };
            if title.is_empty() {
                let proc =
                    control.request("process-info", json!({ "surface": tab.surface_id })).await;
                if let Some(data) = proc
                    .as_ref()
                    .filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true))
                    .and_then(|v| v.get("data"))
                {
                    let command = data
                        .get("command")
                        .and_then(Value::as_str)
                        .map(|c| {
                            Path::new(c)
                                .file_name()
                                .map(|n| n.to_string_lossy().into_owned())
                                .unwrap_or_default()
                        })
                        .unwrap_or_default();
                    let cwd = shorten_cwd(
                        data.get("cwd").and_then(Value::as_str).unwrap_or_default(),
                        home,
                    );
                    title = [command, cwd]
                        .into_iter()
                        .filter(|p| !p.is_empty())
                        .collect::<Vec<_>>()
                        .join(" · ");
                }
            }
            if title.is_empty() {
                title = format!("terminal {}", tab.surface_id);
            }
            if !tab.workspace.is_empty() {
                title = format!("{}: {title}", tab.workspace);
            }
            out.push((reference, title.chars().take(200).collect()));
        }
        control.end();
        out
    }
}

// ---------------------------------------------------------------------------
// Tests — mirror packages/relay/test/pty.test.mjs. A fake PtyDeps drives the
// real PtyManager through fake PTYs (synchronous emit) and a recording sink.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::{CloseHandler, EventHandler};
    use std::future::Future;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
    use std::sync::{Arc as TestArc, Barrier, Mutex as StdMutex};
    use std::thread;
    use std::time::Duration;
    use tokio::sync::Notify as TestNotify;

    static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(0);

    /// A unique, real directory for tests that exercise cwd canonicalization.
    /// Do not reuse a process-id-only path: tests run in parallel and a stale
    /// path from an interrupted run must never be removed or reused.
    struct TestDirectory {
        path: PathBuf,
    }

    impl TestDirectory {
        fn new(label: &str) -> TestDirectory {
            loop {
                let sequence = NEXT_TEST_DIRECTORY.fetch_add(1, AtomicOrdering::Relaxed);
                let process_id = std::process::id();
                let path = std::env::temp_dir()
                    .join(format!("chatmux-pty-{label}-{process_id}-{sequence}"));
                match std::fs::create_dir(&path) {
                    Ok(()) => return TestDirectory { path },
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(error) => panic!("create PTY test directory failed: {error}"),
                }
            }
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    /// A fake PTY: emit() calls the subscribed sink synchronously, like the
    /// JS fakePty. Records writes/resizes/pause/release/kill for assertions.
    #[derive(Default)]
    struct FakeState {
        on_data: Option<DataSink>,
        on_exit: Option<ExitSink>,
        written: Vec<Vec<u8>>,
        resized: Vec<(u16, u16)>,
        paused: bool,
        killed: bool,
        released: bool,
    }

    #[derive(Clone)]
    struct FakePty {
        state: Arc<StdMutex<FakeState>>,
        spawn_file: String,
        spawn_cwd: PathBuf,
        spawn_term: String,
    }

    #[test]
    fn strict_terminal_enumeration_rejects_more_than_the_cap() {
        let tabs = (0..=MAX_ENUM_TERMINALS)
            .map(|surface| {
                serde_json::json!({
                    "kind": "pty",
                    "surface": surface,
                    "dead": false,
                    "name": format!("terminal-{surface}"),
                })
            })
            .collect::<Vec<_>>();
        let data = serde_json::json!({
            "workspaces": [{
                "name": "workspace",
                "screens": [{
                    "panes": [{"tabs": tabs}]
                }]
            }]
        });
        assert!(collect_pty_tabs_strict(Some(&data)).is_err());

        let bounded = serde_json::json!({
            "workspaces": [{
                "name": "workspace",
                "screens": [{
                    "panes": [{"tabs": (0..MAX_ENUM_TERMINALS)
                        .map(|surface| serde_json::json!({
                            "kind": "pty",
                            "surface": surface,
                            "dead": false,
                        }))
                        .collect::<Vec<_>>() }]
                }]
            }]
        });
        assert_eq!(collect_pty_tabs_strict(Some(&bounded)).unwrap().len(), MAX_ENUM_TERMINALS);
    }

    impl FakePty {
        fn emit(&self, text: &str) {
            let sink = self.state.lock().unwrap().on_data.clone();
            if let Some(sink) = sink {
                sink(Bytes::copy_from_slice(text.as_bytes()));
            }
        }
        fn exit(&self, code: i64) {
            let sink = self.state.lock().unwrap().on_exit.clone();
            if let Some(sink) = sink {
                sink(code);
            }
        }
        fn written_string(&self, index: usize) -> String {
            String::from_utf8_lossy(&self.state.lock().unwrap().written[index]).into_owned()
        }
    }

    impl PtyControl for FakePty {
        fn write(&self, data: &[u8]) {
            self.state.lock().unwrap().written.push(data.to_vec());
        }
        fn resize(&self, cols: u16, rows: u16) {
            self.state.lock().unwrap().resized.push((cols, rows));
        }
        fn pause(&self) {
            self.state.lock().unwrap().paused = true;
        }
        fn resume(&self) {
            self.state.lock().unwrap().paused = false;
        }
        fn release(&self) {
            self.state.lock().unwrap().released = true;
        }
        fn kill(&self) {
            self.state.lock().unwrap().killed = true;
        }
    }

    impl PtyOutput for FakePty {
        fn subscribe(&self, on_data: DataSink, on_exit: ExitSink) {
            let mut state = self.state.lock().unwrap();
            state.on_data = Some(on_data);
            state.on_exit = Some(on_exit);
        }
    }

    #[test]
    fn viewer_delivery_keeps_banner_replay_live_and_exit_ordered() {
        let seen = TestArc::new(StdMutex::new(Vec::<String>::new()));
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));
        let invocations = TestArc::new(AtomicUsize::new(0));

        let callback_seen = TestArc::clone(&seen);
        let callback_entered = TestArc::clone(&entered);
        let callback_release = TestArc::clone(&release);
        let callback_invocations = TestArc::clone(&invocations);
        let on_data: DataSink = TestArc::new(move |chunk| {
            let invocation = callback_invocations.fetch_add(1, AtomicOrdering::Relaxed);
            if invocation == 0 {
                callback_entered.wait();
                callback_release.wait();
            }
            callback_seen
                .lock()
                .expect("viewer callback lock")
                .push(String::from_utf8_lossy(&chunk).into_owned());
        });
        let callback_seen = TestArc::clone(&seen);
        let on_exit: ExitSink = TestArc::new(move |code| {
            callback_seen.lock().expect("viewer callback lock").push(format!("exit:{code}"));
        });

        let delivery = ViewerDelivery::with_overflow(on_data, on_exit, TestArc::new(|| {}));
        delivery.seed(Some(Bytes::from_static(b"banner")), Some(Bytes::from_static(b"buffered")));

        let worker_delivery = TestArc::clone(&delivery);
        let worker = thread::spawn(move || {
            assert!(worker_delivery.activate());
            worker_delivery.drain();
        });

        entered.wait();
        assert!(matches!(
            delivery.push_data(Bytes::from_static(b"live")),
            ViewerDeliveryAction::None
        ));
        assert!(matches!(delivery.finish(7), ViewerDeliveryAction::None));
        release.wait();
        worker.join().expect("viewer delivery worker");

        assert_eq!(
            *seen.lock().expect("viewer callback lock"),
            vec![
                "banner".to_owned(),
                "buffered".to_owned(),
                "live".to_owned(),
                "exit:7".to_owned(),
            ]
        );
    }

    #[test]
    fn viewer_delivery_overflow_is_bounded_and_notified_once() {
        let notifications = TestArc::new(AtomicUsize::new(0));
        let callback_notifications = TestArc::clone(&notifications);
        let delivery = ViewerDelivery::with_overflow(
            TestArc::new(|_| {}),
            TestArc::new(|_| {}),
            TestArc::new(move || {
                callback_notifications.fetch_add(1, AtomicOrdering::Relaxed);
            }),
        );

        assert!(matches!(
            delivery.push_data(Bytes::from(vec![0_u8; VIEWER_DELIVERY_MAX_BYTES])),
            ViewerDeliveryAction::None
        ));
        assert!(matches!(
            delivery.push_data(Bytes::from_static(b"overflow")),
            ViewerDeliveryAction::Overflow
        ));
        delivery.notify_overflow();
        delivery.notify_overflow();

        let state = delivery.state.lock().expect("viewer delivery lock");
        assert!(state.overflowed);
        assert_eq!(state.queued_bytes, 0);
        assert!(state.queue.is_empty());
        drop(state);
        assert_eq!(notifications.load(AtomicOrdering::Relaxed), 1);
    }

    #[test]
    fn viewer_delivery_finish_before_start_preserves_replay_before_exit() {
        let seen = TestArc::new(StdMutex::new(Vec::<String>::new()));
        let data_seen = TestArc::clone(&seen);
        let on_data: DataSink = TestArc::new(move |chunk| {
            data_seen.lock().unwrap().push(String::from_utf8_lossy(&chunk).into_owned());
        });
        let exit_seen = TestArc::clone(&seen);
        let on_exit: ExitSink = TestArc::new(move |code| {
            exit_seen.lock().unwrap().push(format!("exit:{code}"));
        });
        let delivery = ViewerDelivery::with_overflow(on_data, on_exit, TestArc::new(|| {}));
        assert!(matches!(delivery.finish(9), ViewerDeliveryAction::None));
        delivery.seed(Some(Bytes::from_static(b"banner")), Some(Bytes::from_static(b"replay")));
        assert!(delivery.activate());
        delivery.drain();
        assert_eq!(*seen.lock().unwrap(), vec!["banner", "replay", "exit:9"]);
    }

    #[derive(Default)]
    struct Recorded {
        spawned: Vec<FakePty>,
        daemons: Vec<(String, PathBuf)>,
        connected: Vec<PathBuf>,
    }

    struct FakeDeps {
        env: HashMap<String, String>,
        recorded: Arc<StdMutex<Recorded>>,
        resolve: Option<CmuxTui>,
        socket_dir: PathBuf,
        read_dir: Option<Vec<String>>,
        ensure_socket_path: Option<PathBuf>,
        control: Option<Arc<dyn ControlHandle>>,
    }

    #[async_trait]
    impl PtyDeps for FakeDeps {
        async fn spawn_pty(&self, spec: SpawnSpec) -> PtyHandle {
            let pty = FakePty {
                state: Arc::new(StdMutex::new(FakeState::default())),
                spawn_file: spec.file.clone(),
                spawn_cwd: spec.cwd.clone(),
                spawn_term: spec.env.get("TERM").cloned().unwrap_or_default(),
            };
            self.recorded.lock().unwrap().spawned.push(pty.clone());
            let control: Arc<dyn PtyControl> = Arc::new(pty.clone());
            let output: Arc<dyn PtyOutput> = Arc::new(pty);
            PtyHandle { control, output, banner: None }
        }
        async fn resolve_cmux_tui(&self) -> Option<CmuxTui> {
            self.resolve.clone()
        }
        async fn ensure_daemon(
            &self,
            _cmux_tui: &CmuxTui,
            session: &str,
            socket_dir: &Path,
            _cwd: &Path,
            _env: &HashMap<String, String>,
        ) -> Result<EnsureDaemon, String> {
            self.recorded
                .lock()
                .unwrap()
                .daemons
                .push((session.to_owned(), socket_dir.to_path_buf()));
            let socket_path = self
                .ensure_socket_path
                .clone()
                .unwrap_or_else(|| socket_dir.join(format!("{session}.sock")));
            Ok(EnsureDaemon { created: true, socket_path })
        }
        async fn connect_control(
            &self,
            socket_path: &Path,
        ) -> Result<Arc<dyn ControlHandle>, String> {
            self.recorded.lock().unwrap().connected.push(socket_path.to_path_buf());
            match &self.control {
                Some(control) => Ok(Arc::clone(control)),
                None => Err("no control socket in tests unless injected".to_owned()),
            }
        }
        async fn read_dir(&self, _path: &Path) -> Result<Vec<String>, ()> {
            self.read_dir.clone().ok_or(())
        }
        fn socket_dir(&self) -> PathBuf {
            self.socket_dir.clone()
        }
        fn shell(&self) -> String {
            self.env.get("SHELL").cloned().unwrap_or_else(|| "/bin/sh".to_owned())
        }
    }

    struct Harness {
        manager: PtyManager,
        recorded: Arc<StdMutex<Recorded>>,
        sent: Arc<StdMutex<Vec<Value>>>,
        buffered: Arc<AtomicU64>,
        owner: Option<String>,
        home: PathBuf,
        _home: TestDirectory,
    }

    fn env_map(home: &Path) -> HashMap<String, String> {
        HashMap::from([
            ("SHELL".to_owned(), "/bin/fakesh".to_owned()),
            ("PATH".to_owned(), "/usr/bin".to_owned()),
            ("HOME".to_owned(), home.to_string_lossy().into_owned()),
        ])
    }

    fn harness(resolve: Option<CmuxTui>, read_dir: Option<Vec<String>>) -> Harness {
        harness_with_socket_path(resolve, read_dir, None)
    }

    fn harness_with_socket_path(
        resolve: Option<CmuxTui>,
        read_dir: Option<Vec<String>>,
        ensure_socket_path: Option<PathBuf>,
    ) -> Harness {
        harness_with_control(resolve, read_dir, ensure_socket_path, None)
    }

    fn harness_with_control(
        resolve: Option<CmuxTui>,
        read_dir: Option<Vec<String>>,
        ensure_socket_path: Option<PathBuf>,
        control: Option<Arc<dyn ControlHandle>>,
    ) -> Harness {
        let home = TestDirectory::new("harness");
        let home_path = home.path.clone();
        let env = env_map(&home_path);
        let recorded = Arc::new(StdMutex::new(Recorded::default()));
        let socket_dir = PathBuf::from("/run/cmux-tui-501");
        let deps = Arc::new(FakeDeps {
            env: env.clone(),
            recorded: Arc::clone(&recorded),
            resolve,
            socket_dir,
            read_dir,
            ensure_socket_path,
            control,
        });
        let manager = PtyManager::with_limits(
            deps,
            home_path.clone(),
            env,
            MAX_PTYS,
            SCROLLBACK_LIMIT,
            OUTPUT_BUFFER_CAP,
        );
        Harness {
            manager,
            recorded,
            sent: Arc::new(StdMutex::new(Vec::new())),
            buffered: Arc::new(AtomicU64::new(0)),
            owner: Some("user_owner".to_owned()),
            home: home_path,
            _home: home,
        }
    }

    impl Harness {
        fn context(&self, trust: &str, owner: Option<String>) -> FrameContext {
            self.context_at_version(PTY_OPERATIONAL_ERRORS_PROTOCOL_VERSION, trust, owner)
        }

        fn context_at_version(
            &self,
            negotiated_version: u64,
            trust: &str,
            owner: Option<String>,
        ) -> FrameContext {
            let sent = Arc::clone(&self.sent);
            let buffered = Arc::clone(&self.buffered);
            FrameContext {
                send: Arc::new(move |frame| sent.lock().unwrap().push(frame)),
                buffered_amount: Arc::new(move || buffered.load(Ordering::SeqCst)),
                negotiated_version,
                trust: trust.to_owned(),
                local_roots: None,
                owner_user_id: owner,
            }
        }

        fn context_with_version(
            &self,
            trust: &str,
            owner: Option<String>,
            negotiated_version: u64,
        ) -> FrameContext {
            self.context_at_version(negotiated_version, trust, owner)
        }

        async fn open(
            &self,
            pty_id: &str,
            session: &str,
            extra: Value,
            trust: &str,
            owner: Option<String>,
        ) {
            self.open_at_version(
                PTY_OPERATIONAL_ERRORS_PROTOCOL_VERSION,
                pty_id,
                session,
                extra,
                trust,
                owner,
            )
            .await;
        }

        async fn open_at_version(
            &self,
            negotiated_version: u64,
            pty_id: &str,
            session: &str,
            extra: Value,
            trust: &str,
            owner: Option<String>,
        ) {
            let mut frame = serde_json::json!({
                "version": 4,
                "type": "pty_open",
                "ptyId": pty_id,
                "session": session,
                "cols": 80,
                "rows": 24,
                "actorId": "user_owner",
                "trust": "supervised",
                "allowedRoots": Value::Null,
            });
            if let Value::Object(extra) = extra {
                for (k, v) in extra {
                    frame[k] = v;
                }
            }
            self.manager
                .handle_frame(&frame, &self.context_at_version(negotiated_version, trust, owner))
                .await;
        }

        async fn frame(&self, frame: Value) {
            self.manager
                .handle_frame(&frame, &self.context("supervised", self.owner.clone()))
                .await;
        }

        async fn frame_as(&self, frame: Value, trust: &str, owner: Option<String>) {
            self.frame_as_at_version(PTY_OPERATIONAL_ERRORS_PROTOCOL_VERSION, frame, trust, owner)
                .await;
        }

        async fn frame_as_at_version(
            &self,
            negotiated_version: u64,
            frame: Value,
            trust: &str,
            owner: Option<String>,
        ) {
            self.manager
                .handle_frame(&frame, &self.context_at_version(negotiated_version, trust, owner))
                .await;
        }

        fn sent(&self) -> Vec<Value> {
            self.sent.lock().unwrap().clone()
        }
        fn spawned(&self) -> Vec<FakePty> {
            self.recorded.lock().unwrap().spawned.clone()
        }
        fn daemons(&self) -> Vec<(String, PathBuf)> {
            self.recorded.lock().unwrap().daemons.clone()
        }
        fn connected(&self) -> Vec<PathBuf> {
            self.recorded.lock().unwrap().connected.clone()
        }
    }

    fn b64(text: &str) -> String {
        BASE64.encode(text.as_bytes())
    }
    fn from_b64(value: &str) -> String {
        String::from_utf8_lossy(&BASE64.decode(value).unwrap()).into_owned()
    }
    fn ty(frame: &Value) -> &str {
        frame.get("type").and_then(Value::as_str).unwrap_or_default()
    }

    #[tokio::test]
    async fn bad_session_names_and_dims_answer_bad_request() {
        let h = harness(None, None);
        h.open("p1", "bad/name", Value::Null, "supervised", h.owner.clone()).await;
        h.open("p2", "ok", serde_json::json!({ "cols": 0 }), "supervised", h.owner.clone()).await;
        let sent = h.sent();
        assert_eq!(ty(&sent[0]), "pty_error");
        assert_eq!(sent[0]["code"], "bad_request");
        assert_eq!(sent[1]["code"], "bad_request");
    }

    #[test]
    fn session_name_validation_matches_core_path_component_rules() {
        let long_name = format!("long-{}", "x".repeat(256));
        for name in ["legacy name", "名前", "dots.and-dashes_ok", &long_name] {
            assert!(session_name_ok(name), "rejected valid session {name:?}");
        }
        for name in [
            "",
            ".",
            "..",
            "nested/session",
            "nested\\session",
            "nul\0session",
            "line\nfeed",
            "next\u{0085}line",
            "line\u{2028}separator",
            "line\u{2029}separator",
        ] {
            assert!(!session_name_ok(name), "accepted invalid session {name:?}");
        }
    }

    #[tokio::test]
    async fn observe_trust_refuses_non_owner_but_admits_owner() {
        let h = harness(None, None);
        h.open(
            "p1",
            "main",
            serde_json::json!({ "actorId": "user_other" }),
            "observe",
            h.owner.clone(),
        )
        .await;
        assert_eq!(h.sent()[0]["code"], "trust_refused");
        h.open("p2", "main", Value::Null, "observe", h.owner.clone()).await;
        assert_eq!(ty(&h.sent()[1]), "pty_opened");
    }

    #[tokio::test]
    async fn observe_trust_with_unknown_owner_refuses() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "observe", None).await;
        assert_eq!(h.sent()[0]["code"], "trust_refused");
    }

    #[tokio::test]
    async fn shell_open_output_input_resize_flow_round_trip() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let opened = &h.sent()[0];
        assert_eq!(opened["type"], "pty_opened");
        assert_eq!(opened["created"], true);
        assert_eq!(opened["cols"], 80);
        let pty = h.spawned()[0].clone();
        assert_eq!(pty.spawn_file, "/bin/fakesh");
        assert_eq!(pty.spawn_cwd, std::fs::canonicalize(&h.home).unwrap());
        assert_eq!(pty.spawn_term, "xterm-256color");

        pty.emit("hello\r\n");
        assert_eq!(ty(&h.sent()[1]), "pty_output");
        assert_eq!(from_b64(h.sent()[1]["dataB64"].as_str().unwrap()), "hello\r\n");

        h.frame(serde_json::json!({ "type": "pty_input", "ptyId": "p1", "dataB64": b64("ls\r") }))
            .await;
        assert_eq!(pty.written_string(0), "ls\r");

        h.frame(
            serde_json::json!({ "type": "pty_resize", "ptyId": "p1", "cols": 132, "rows": 43 }),
        )
        .await;
        assert!(pty.state.lock().unwrap().resized.contains(&(132, 43)));

        h.frame(serde_json::json!({ "type": "pty_flow", "ptyId": "p1", "pause": true })).await;
        assert!(pty.state.lock().unwrap().paused);
        h.frame(serde_json::json!({ "type": "pty_flow", "ptyId": "p1", "pause": false })).await;
        assert!(!pty.state.lock().unwrap().paused);
    }

    #[tokio::test]
    async fn trust_downgrade_revokes_existing_non_owner_controls() {
        let h = harness(None, None);
        h.open(
            "p1",
            "main",
            serde_json::json!({"actorId": "user_other"}),
            "supervised",
            h.owner.clone(),
        )
        .await;
        h.frame_as(
            serde_json::json!({"type":"pty_input","ptyId":"p1","dataB64":b64("x")}),
            "observe",
            h.owner.clone(),
        )
        .await;
        assert!(h.sent().iter().any(|f| f["code"] == "trust_revoked"));
        assert!(h.spawned()[0].state.lock().unwrap().written.is_empty());
    }

    #[tokio::test]
    async fn trust_downgrade_downgrades_for_v6_workers() {
        let h = harness(None, None);
        h.open_at_version(
            6,
            "p1",
            "main",
            serde_json::json!({"actorId": "user_other"}),
            "supervised",
            h.owner.clone(),
        )
        .await;
        h.frame_as_at_version(
            6,
            serde_json::json!({"type":"pty_input","ptyId":"p1","dataB64":b64("x")}),
            "observe",
            h.owner.clone(),
        )
        .await;
        let error = h
            .sent()
            .into_iter()
            .find(|frame| ty(frame) == "pty_error")
            .expect("trust downgrade error");
        assert_eq!(error["code"], "failed");
        assert!(error["message"].as_str().unwrap_or_default().contains("restore trust"));
    }

    #[tokio::test]
    async fn output_after_trust_downgrade_is_not_forwarded() {
        let h = harness(None, None);
        h.open(
            "p1",
            "main",
            serde_json::json!({"actorId": "user_other"}),
            "supervised",
            h.owner.clone(),
        )
        .await;
        let pty = h.spawned()[0].clone();
        h.frame_as(
            serde_json::json!({"type":"pty_input","ptyId":"p1","dataB64":b64("x")}),
            "observe",
            h.owner.clone(),
        )
        .await;
        pty.emit("secret");
        assert!(!h.sent().iter().any(|f| f["type"] == "pty_output"));
    }

    #[tokio::test]
    async fn close_requires_current_trust() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        h.frame_as(serde_json::json!({"type":"pty_close","ptyId":"p1"}), "", h.owner.clone()).await;
        assert!(h.sent().iter().any(|f| f["code"] == "trust_revoked"));
    }

    #[tokio::test]
    async fn close_detaches_without_killing_reattach_replays_scrollback() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let pty = h.spawned()[0].clone();
        pty.emit("before detach\r\n");
        h.frame(serde_json::json!({ "type": "pty_close", "ptyId": "p1" })).await;
        assert!(!pty.state.lock().unwrap().killed);
        pty.emit("while detached\r\n");
        let before = h.sent().len();
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        let opened = &h.sent()[before];
        assert_eq!(opened["type"], "pty_opened");
        assert_eq!(opened["created"], false);
        let replay = &h.sent()[before + 1];
        assert_eq!(
            from_b64(replay["dataB64"].as_str().unwrap()),
            "before detach\r\nwhile detached\r\n"
        );
        assert_eq!(h.spawned().len(), 1);
    }

    #[tokio::test]
    async fn stale_callbacks_after_reopen_cannot_affect_replacement() {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let h = harness(Some(cmux), None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let old = h.spawned()[0].clone();
        h.frame(serde_json::json!({ "type": "pty_close", "ptyId": "p1" })).await;
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let replacement = h.spawned()[1].clone();

        let before_stale = h.sent().len();
        old.emit("stale output");
        old.exit(7);
        let stale_frames = h.sent();
        assert!(!stale_frames[before_stale..].iter().any(|frame| matches!(
            frame.get("type").and_then(Value::as_str),
            Some("pty_output" | "pty_exit")
        )));

        replacement.emit("replacement output");
        replacement.exit(0);
        let frames = h.sent();
        assert_eq!(
            frames.last().and_then(|frame| frame.get("type")).and_then(Value::as_str),
            Some("pty_exit")
        );
        assert_eq!(
            frames.last().and_then(|frame| frame.get("code")).and_then(Value::as_i64),
            Some(0)
        );
    }

    #[tokio::test]
    async fn stale_overflow_after_reopen_cannot_error_replacement() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let old = h.manager.inner.attachments.lock().unwrap().get("p1").unwrap().clone();
        h.frame(serde_json::json!({ "type": "pty_close", "ptyId": "p1" })).await;
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let replacement_generation =
            h.manager.inner.attachments.lock().unwrap().get("p1").unwrap().generation;

        let stale_stream = TerminalStream::new();
        stale_stream.push_output(Bytes::from(vec![b'x'; RAW_ATTACH_BACKLOG_CAP]));
        stale_stream.push_output(Bytes::from_static(b"late"));
        assert!(stale_stream.overflowed());

        let old_control = Arc::clone(&old.control);
        let old_identity = Arc::downgrade(&old_control);
        let before = h.sent().len();
        let _ = h.manager.inner.emit_raw_exit(
            "p1",
            old.generation,
            Some(&stale_stream),
            1,
            &h.context("supervised", h.owner.clone()),
            &old_identity,
        );

        let after = h.sent();
        assert!(!after[before..].iter().any(|frame| ty(frame) == "pty_error"));
        assert_eq!(
            h.manager.inner.attachments.lock().unwrap().get("p1").unwrap().generation,
            replacement_generation
        );
    }

    #[tokio::test]
    async fn zero_byte_chunks_never_become_output_frames() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let pty = h.spawned()[0].clone();
        pty.emit("");
        assert_eq!(h.sent().len(), 1);
        pty.emit("real bytes");
        assert_eq!(h.sent().len(), 2);
        assert_eq!(from_b64(h.sent()[1]["dataB64"].as_str().unwrap()), "real bytes");
    }

    #[tokio::test]
    async fn unknown_pty_ids_are_tolerated_on_every_verb() {
        let h = harness(None, None);
        for frame in [
            serde_json::json!({ "type": "pty_input", "ptyId": "ghost", "dataB64": b64("x") }),
            serde_json::json!({ "type": "pty_resize", "ptyId": "ghost", "cols": 10, "rows": 10 }),
            serde_json::json!({ "type": "pty_flow", "ptyId": "ghost", "pause": true }),
            serde_json::json!({ "type": "pty_close", "ptyId": "ghost" }),
            serde_json::json!({ "type": "pty_close", "ptyId": "ghost" }),
        ] {
            h.frame(frame).await;
        }
        assert_eq!(h.sent().len(), 0);
    }

    #[tokio::test]
    async fn session_exit_sends_exit_once_and_next_open_creates() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let pty = h.spawned()[0].clone();
        pty.exit(3);
        let exit = &h.sent()[1];
        assert_eq!(exit["type"], "pty_exit");
        assert_eq!(exit["code"], 3);
        let state = pty.state.lock().unwrap();
        assert!(state.released, "PTY exit must release relay state");
        assert!(!state.killed, "PTY exit must not kill a whole-session process");
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        assert_eq!(h.sent()[2]["created"], true);
        assert_eq!(h.spawned().len(), 2);
    }

    #[tokio::test]
    async fn scrollback_ring_is_bounded() {
        let home = TestDirectory::new("scrollback");
        let home_path = home.path.clone();
        let env = env_map(&home_path);
        let recorded = Arc::new(StdMutex::new(Recorded::default()));
        let deps = Arc::new(FakeDeps {
            env: env.clone(),
            recorded: Arc::clone(&recorded),
            resolve: None,
            socket_dir: PathBuf::from("/run/cmux-tui-501"),
            read_dir: None,
            ensure_socket_path: None,
            control: None,
        });
        let manager =
            PtyManager::with_limits(deps, home_path.clone(), env, MAX_PTYS, 32, OUTPUT_BUFFER_CAP);
        let h = Harness {
            manager,
            recorded,
            sent: Arc::new(StdMutex::new(Vec::new())),
            buffered: Arc::new(AtomicU64::new(0)),
            owner: Some("user_owner".to_owned()),
            home: home_path,
            _home: home,
        };
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let pty = h.spawned()[0].clone();
        h.frame(serde_json::json!({ "type": "pty_close", "ptyId": "p1" })).await;
        for i in 0..10 {
            pty.emit(&format!("chunk-{i}-aaaaaaaa\r\n"));
        }
        let before = h.sent().len();
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        let replay = from_b64(h.sent()[before + 1]["dataB64"].as_str().unwrap());
        assert!(replay.len() <= 32 + 20);
        assert!(replay.contains("chunk-9"));
        assert!(!replay.contains("chunk-0"));
    }

    #[tokio::test]
    async fn second_open_adds_a_viewer_output_fans_out_to_both() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        assert_eq!(h.spawned().len(), 1);
        assert_eq!(h.sent()[1]["created"], false);
        h.spawned()[0].emit("hello");
        let mut ids: Vec<String> = h
            .sent()
            .iter()
            .filter(|f| ty(f) == "pty_output")
            .map(|f| f["ptyId"].as_str().unwrap().to_owned())
            .collect();
        ids.sort();
        assert_eq!(ids, vec!["p1", "p2"]);
    }

    #[tokio::test]
    async fn shell_viewers_use_smallest_grid_and_relax_after_release() {
        let h = harness(None, None);
        h.open(
            "p1",
            "main",
            serde_json::json!({ "cols": 120, "rows": 40 }),
            "supervised",
            h.owner.clone(),
        )
        .await;
        h.open(
            "p2",
            "main",
            serde_json::json!({ "cols": 80, "rows": 24 }),
            "supervised",
            h.owner.clone(),
        )
        .await;
        let pty = h.spawned()[0].clone();
        assert_eq!(pty.state.lock().unwrap().resized, vec![(80, 24)]);

        h.frame(serde_json::json!({
            "type": "pty_resize",
            "ptyId": "p2",
            "cols": 100,
            "rows": 30
        }))
        .await;
        h.frame(serde_json::json!({
            "type": "pty_resize",
            "ptyId": "p1",
            "cols": 90,
            "rows": 20
        }))
        .await;
        h.frame(serde_json::json!({ "type": "pty_close", "ptyId": "p1" })).await;
        assert_eq!(
            pty.state.lock().unwrap().resized,
            vec![(80, 24), (100, 30), (90, 20), (100, 30)]
        );
    }

    #[tokio::test]
    async fn detaching_one_viewer_leaves_the_other_live_exit_reaches_every_viewer() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        h.frame(serde_json::json!({ "type": "pty_close", "ptyId": "p1" })).await;
        let before = h.sent().len();
        h.spawned()[0].emit("again");
        let after: Vec<(String, String)> = h.sent()[before..]
            .iter()
            .map(|f| (ty(f).to_owned(), f["ptyId"].as_str().unwrap().to_owned()))
            .collect();
        assert_eq!(after, vec![("pty_output".to_owned(), "p2".to_owned())]);
        h.spawned()[0].exit(0);
        let last = h.sent();
        let last = last.last().unwrap();
        assert_eq!(last["type"], "pty_exit");
        assert_eq!(last["ptyId"], "p2");
    }

    #[tokio::test]
    async fn more_than_max_ptys_answers_session_limit() {
        let h = harness(None, None);
        for i in 0..MAX_PTYS {
            h.open(&format!("p{i}"), &format!("s{i}"), Value::Null, "supervised", h.owner.clone())
                .await;
        }
        h.open("overflow", "extra", Value::Null, "supervised", h.owner.clone()).await;
        let last = h.sent();
        let last = last.last().unwrap();
        assert_eq!(last["type"], "pty_error");
        assert_eq!(last["code"], "session_limit");
    }

    #[tokio::test]
    async fn wedged_worker_drops_attachment_session_survives() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let pty = h.spawned()[0].clone();
        h.buffered.store(OUTPUT_BUFFER_CAP + 1, Ordering::SeqCst);
        pty.emit("flood");
        let last = h.sent();
        let last = last.last().unwrap();
        assert_eq!(last["type"], "pty_error");
        assert_eq!(last["code"], "overflow");
        assert!(last["message"].as_str().unwrap_or_default().contains("reattach"));
        assert!(!pty.state.lock().unwrap().killed);
        h.buffered.store(0, Ordering::SeqCst);
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        let reopened =
            h.sent().into_iter().find(|f| ty(f) == "pty_opened" && f["ptyId"] == "p2").unwrap();
        assert_eq!(reopened["created"], false);
    }

    #[tokio::test]
    async fn output_backlog_overflow_downgrades_for_v6_workers() {
        let h = harness(None, None);
        h.open_at_version(6, "p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let pty = h.spawned()[0].clone();
        h.buffered.store(OUTPUT_BUFFER_CAP + 1, Ordering::SeqCst);
        pty.emit("flood");
        let last = h.sent().last().cloned().expect("overflow error");
        assert_eq!(last["type"], "pty_error");
        assert_eq!(last["code"], "failed");
        assert!(last["message"].as_str().unwrap_or_default().contains("reattach"));
    }

    #[tokio::test]
    async fn cmux_open_ensures_daemon_and_close_kills_only_the_viewer() {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let h = harness(Some(cmux), None);
        h.open("p1", "work", Value::Null, "supervised", h.owner.clone()).await;
        assert_eq!(h.daemons().len(), 1);
        assert_eq!(h.daemons()[0].0, "work");
        assert_eq!(h.daemons()[0].1, PathBuf::from("/run/cmux-tui-501"));
        assert_eq!(h.sent()[0]["created"], true);
        let viewer = h.spawned()[0].clone();
        h.frame(serde_json::json!({ "type": "pty_close", "ptyId": "p1" })).await;
        assert!(viewer.state.lock().unwrap().killed);
    }

    #[tokio::test]
    async fn cmux_protocol_ten_refuses_open_when_sizing_target_is_frozen() {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let control = SizingControl::new(10, &[]);
        let h = harness_with_control(Some(cmux), None, None, Some(Arc::new(control.clone())));

        // Retire the same daemon surface with a failed close barrier. A
        // protocol-10+ raw attach must report a fixed failure, not degrade to
        // a whole-session shell that bypasses the sizing generation fence.
        let old_control = SizingControl::new(10, &[]);
        old_control.set_end_ok(false);
        let key =
            SizingKey { socket_path: PathBuf::from("/run/cmux-tui-501/main.sock"), surface_id: 40 };
        h.manager
            .inner
            .sizing
            .join(
                key.clone(),
                1,
                40,
                Arc::new(old_control.clone()),
                SizingGrid { cols: 80, rows: 24 },
            )
            .expect("initial sizing join")
            .await
            .expect("initial sizing worker");
        h.manager.inner.sizing.leave(&key, 1);
        old_control.wait_for_end().await;
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let frozen = h
                    .manager
                    .inner
                    .sizing
                    .targets
                    .lock()
                    .unwrap()
                    .get(&key)
                    .is_some_and(|target| target.queue.state.lock().unwrap().closing_failed);
                if frozen {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("sizing target did not become frozen");

        h.open_at_version(
            10,
            "p1",
            "main",
            serde_json::json!({ "surface": "40" }),
            "supervised",
            h.owner.clone(),
        )
        .await;
        let sent = h.sent();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0]["type"], "pty_error");
        assert_eq!(sent[0]["code"], "failed");
        assert!(sent[0]["message"].as_str().unwrap_or_default().contains("sizing"));
        assert!(!sent.iter().any(|frame| ty(frame) == "pty_opened"));
        assert!(control.ended(), "failed open must close the raw control");
    }

    #[tokio::test]
    async fn raw_surface_attach_uses_daemon_returned_socket_path() {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let daemon_socket = PathBuf::from("/private/cmux/custom.sock");
        let h = harness_with_socket_path(Some(cmux), None, Some(daemon_socket.clone()));
        h.open(
            "p1",
            "work",
            serde_json::json!({ "surface": "terminal-7" }),
            "supervised",
            h.owner.clone(),
        )
        .await;

        // The fake control connector refuses the connection, so open falls
        // back to the whole-session viewer. Its recorded path still proves
        // that raw attach used EnsureDaemon.socket_path, rather than deriving
        // a second path from socket_dir and session.
        assert_eq!(h.connected(), vec![daemon_socket]);
        assert_eq!(h.sent()[0]["type"], "pty_opened");
    }

    /// Scripted control plane: identifies at the protocol floor and lists a
    /// workspace tree WITHOUT the requested terminal — the JS harness's
    /// "closed tab" shape.
    struct GoneControl;

    impl ControlHandle for GoneControl {
        fn request(
            &self,
            cmd: &str,
            _params: Value,
        ) -> std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send + '_>> {
            let response = match cmd {
                "identify" => Some(serde_json::json!({
                    "ok": true,
                    "data": { "protocol": CONTROL_MIN_PROTOCOL, "capabilities": [] },
                })),
                "list-workspaces" => Some(serde_json::json!({
                    "ok": true,
                    "data": { "workspaces": [] },
                })),
                _ => None,
            };
            Box::pin(async move { response })
        }
        fn send(&self, _cmd: &str, _params: Value) {}
        fn on_event(&self, _handler: EventHandler) {}
        fn on_close(&self, _handler: CloseHandler) {}
        fn pause(&self) {}
        fn resume(&self) {}
        fn end(&self) {}
    }

    #[derive(Clone)]
    struct SizingControl {
        state: TestArc<StdMutex<SizingControlState>>,
        notify: TestArc<TestNotify>,
        sizing_release: TestArc<TestNotify>,
        ordered_send_started: TestArc<TestNotify>,
        ordered_send_release: TestArc<TestNotify>,
        end_started: TestArc<TestNotify>,
        end_release: TestArc<TestNotify>,
        claim_dispatch_started: TestArc<TestNotify>,
        claim_dispatch_release: TestArc<TestNotify>,
        ended_notify: TestArc<TestNotify>,
        settled: TestArc<TestNotify>,
    }

    struct SizingControlState {
        protocol: i64,
        capabilities: Vec<String>,
        claim_ok: bool,
        reject_next_resize: bool,
        block_sizing: bool,
        block_ordered_send: bool,
        ordered_send_started: bool,
        block_end: bool,
        end_started: bool,
        end_ok: bool,
        block_claim_dispatch: bool,
        ended: bool,
        requests: Vec<(String, Value)>,
        sends: Vec<(String, Value)>,
        events: Vec<String>,
    }

    impl SizingControl {
        fn new(protocol: i64, capabilities: &[&str]) -> Self {
            Self {
                state: TestArc::new(StdMutex::new(SizingControlState {
                    protocol,
                    capabilities: capabilities.iter().map(|value| (*value).to_owned()).collect(),
                    claim_ok: true,
                    reject_next_resize: false,
                    block_sizing: false,
                    block_ordered_send: false,
                    ordered_send_started: false,
                    block_end: false,
                    end_started: false,
                    end_ok: true,
                    block_claim_dispatch: false,
                    ended: false,
                    requests: Vec::new(),
                    sends: Vec::new(),
                    events: Vec::new(),
                })),
                notify: TestArc::new(TestNotify::new()),
                sizing_release: TestArc::new(TestNotify::new()),
                ordered_send_started: TestArc::new(TestNotify::new()),
                ordered_send_release: TestArc::new(TestNotify::new()),
                end_started: TestArc::new(TestNotify::new()),
                end_release: TestArc::new(TestNotify::new()),
                claim_dispatch_started: TestArc::new(TestNotify::new()),
                claim_dispatch_release: TestArc::new(TestNotify::new()),
                ended_notify: TestArc::new(TestNotify::new()),
                settled: TestArc::new(TestNotify::new()),
            }
        }

        fn set_claim_ok(&self, value: bool) {
            self.state.lock().unwrap().claim_ok = value;
        }

        fn reject_next_resize(&self) {
            self.state.lock().unwrap().reject_next_resize = true;
        }

        fn block_sizing(&self) {
            self.state.lock().unwrap().block_sizing = true;
        }

        fn release_sizing(&self) {
            self.state.lock().unwrap().block_sizing = false;
            self.sizing_release.notify_waiters();
        }

        fn block_ordered_send(&self) {
            self.state.lock().unwrap().block_ordered_send = true;
        }

        fn release_ordered_send(&self) {
            self.state.lock().unwrap().block_ordered_send = false;
            self.ordered_send_release.notify_waiters();
        }

        fn block_end(&self) {
            self.state.lock().unwrap().block_end = true;
        }

        fn release_end(&self) {
            self.state.lock().unwrap().block_end = false;
            self.end_release.notify_waiters();
        }

        fn set_end_ok(&self, value: bool) {
            self.state.lock().unwrap().end_ok = value;
        }

        fn block_claim_dispatch(&self) {
            self.state.lock().unwrap().block_claim_dispatch = true;
        }

        fn release_claim_dispatch(&self) {
            self.state.lock().unwrap().block_claim_dispatch = false;
            self.claim_dispatch_release.notify_waiters();
        }

        fn requests(&self) -> Vec<(String, Value)> {
            self.state.lock().unwrap().requests.clone()
        }

        fn sends(&self) -> Vec<(String, Value)> {
            self.state.lock().unwrap().sends.clone()
        }

        fn events(&self) -> Vec<String> {
            self.state.lock().unwrap().events.clone()
        }

        fn ended(&self) -> bool {
            self.state.lock().unwrap().ended
        }

        async fn wait_for_requests(&self, count: usize) {
            let wait = async {
                loop {
                    let notified = self.notify.notified();
                    if self.requests().len() >= count {
                        return;
                    }
                    notified.await;
                }
            };
            tokio::time::timeout(Duration::from_secs(2), wait)
                .await
                .expect("terminal sizing request worker did not settle");
        }

        async fn wait_for_sends(&self, count: usize) {
            let wait = async {
                loop {
                    let notified = self.notify.notified();
                    if self.sends().len() >= count {
                        return;
                    }
                    notified.await;
                }
            };
            tokio::time::timeout(Duration::from_secs(2), wait)
                .await
                .expect("terminal sizing send queue did not settle");
        }

        async fn wait_for_settled(&self) {
            let wait = self.settled.notified();
            tokio::time::timeout(Duration::from_secs(2), wait)
                .await
                .expect("terminal sizing request did not settle");
        }

        async fn wait_for_claim_dispatch(&self) {
            let wait = self.claim_dispatch_started.notified();
            tokio::time::timeout(Duration::from_secs(2), wait)
                .await
                .expect("terminal sizing claim did not reach dispatch gate");
        }

        async fn wait_for_ordered_send(&self) {
            let wait = async {
                loop {
                    let notified = self.ordered_send_started.notified();
                    if self.state.lock().unwrap().ordered_send_started {
                        return;
                    }
                    notified.await;
                }
            };
            tokio::time::timeout(Duration::from_secs(2), wait)
                .await
                .expect("terminal sizing ordered send did not reach dispatch gate");
        }

        async fn wait_for_end(&self) {
            let wait = async {
                loop {
                    let notified = self.ended_notify.notified();
                    if self.ended() {
                        return;
                    }
                    notified.await;
                }
            };
            tokio::time::timeout(Duration::from_secs(2), wait)
                .await
                .expect("terminal sizing close did not settle");
        }

        async fn wait_for_end_started(&self) {
            let wait = async {
                loop {
                    let notified = self.end_started.notified();
                    if self.state.lock().unwrap().end_started {
                        return;
                    }
                    notified.await;
                }
            };
            tokio::time::timeout(Duration::from_secs(2), wait)
                .await
                .expect("terminal sizing close did not reach dispatch gate");
        }
    }

    impl ControlHandle for SizingControl {
        fn request(
            &self,
            cmd: &str,
            params: Value,
        ) -> std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send + '_>> {
            let dispatch_blocked = {
                let state = self.state.lock().unwrap();
                state.block_claim_dispatch && cmd == "set-client-sizing"
            };
            let dispatch_release = TestArc::clone(&self.claim_dispatch_release);
            let claim_dispatch_started = TestArc::clone(&self.claim_dispatch_started);
            let settled = TestArc::clone(&self.settled);
            let cmd = cmd.to_owned();
            Box::pin(async move {
                if dispatch_blocked {
                    claim_dispatch_started.notify_waiters();
                    dispatch_release.notified().await;
                    if self.ended() {
                        settled.notify_waiters();
                        return None;
                    }
                }
                let (response, blocked) = {
                    let mut state = self.state.lock().unwrap();
                    if state.ended {
                        return None;
                    }
                    state.requests.push((cmd.clone(), params));
                    state.events.push(format!("request:{cmd}"));
                    let response = match cmd.as_str() {
                        "identify" => Some(json!({
                            "ok": true,
                            "data": {
                                "protocol": state.protocol,
                                "capabilities": state.capabilities.clone(),
                            },
                        })),
                        "attach-surface" => Some(json!({ "ok": true, "data": {} })),
                        "resize-surface" => {
                            let accepted = !state.reject_next_resize;
                            state.reject_next_resize = false;
                            Some(json!({
                                "ok": true,
                                "data": { "accepted": accepted, "reservation_id": Value::Null },
                            }))
                        }
                        "set-client-sizing" if state.claim_ok => {
                            Some(json!({ "ok": true, "data": {} }))
                        }
                        "set-client-sizing" => Some(json!({ "ok": false, "error": "refused" })),
                        _ => Some(json!({ "ok": true, "data": {} })),
                    };
                    let blocked = state.block_sizing
                        && matches!(cmd.as_str(), "resize-surface" | "set-client-sizing");
                    (response, blocked)
                };
                self.notify.notify_waiters();
                let release = TestArc::clone(&self.sizing_release);
                if blocked {
                    release.notified().await;
                }
                settled.notify_waiters();
                response
            })
        }

        fn send(&self, cmd: &str, params: Value) {
            let mut state = self.state.lock().unwrap();
            state.sends.push((cmd.to_owned(), params));
            state.events.push(format!("send:{cmd}"));
            self.notify.notify_waiters();
        }

        fn ordered_send(
            &self,
            cmd: &str,
            params: Value,
        ) -> std::pin::Pin<Box<dyn Future<Output = bool> + Send + '_>> {
            let blocked = {
                let state = self.state.lock().unwrap();
                state.block_ordered_send && cmd == "resize-surface"
            };
            let started = TestArc::clone(&self.ordered_send_started);
            let release = TestArc::clone(&self.ordered_send_release);
            let cmd = cmd.to_owned();
            Box::pin(async move {
                if blocked {
                    self.state.lock().unwrap().ordered_send_started = true;
                    started.notify_waiters();
                    release.notified().await;
                }
                self.send(&cmd, params);
                true
            })
        }

        fn on_event(&self, _handler: EventHandler) {}
        fn on_close(&self, _handler: CloseHandler) {}
        fn pause(&self) {}
        fn resume(&self) {}
        fn end(&self) {
            let mut state = self.state.lock().unwrap();
            state.ended = true;
            state.events.push("end".to_owned());
            self.ended_notify.notify_waiters();
        }

        fn end_and_wait(&self) -> std::pin::Pin<Box<dyn Future<Output = bool> + Send + '_>> {
            let blocked = self.state.lock().unwrap().block_end;
            let end_ok = self.state.lock().unwrap().end_ok;
            let started = TestArc::clone(&self.end_started);
            let release = TestArc::clone(&self.end_release);
            Box::pin(async move {
                if blocked {
                    self.state.lock().unwrap().end_started = true;
                    started.notify_waiters();
                    release.notified().await;
                }
                self.end();
                end_ok
            })
        }
    }

    /// Control test double that retains the close callback. Raw attach uses
    /// callbacks that retain its sizing lease, so this models the ownership
    /// edge that must not keep an endpoint alive after release.
    #[derive(Clone)]
    struct CallbackSizingControl {
        inner: SizingControl,
        close_handler: TestArc<StdMutex<Option<CloseHandler>>>,
    }

    impl CallbackSizingControl {
        fn new(protocol: i64) -> Self {
            Self {
                inner: SizingControl::new(protocol, &[]),
                close_handler: TestArc::new(StdMutex::new(None)),
            }
        }
    }

    impl ControlHandle for CallbackSizingControl {
        fn request(
            &self,
            cmd: &str,
            params: Value,
        ) -> std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send + '_>> {
            self.inner.request(cmd, params)
        }

        fn send(&self, cmd: &str, params: Value) {
            self.inner.send(cmd, params);
        }

        fn on_event(&self, _handler: EventHandler) {}

        fn on_close(&self, handler: CloseHandler) {
            *self.close_handler.lock().unwrap() = Some(handler);
        }

        fn pause(&self) {}

        fn resume(&self) {}

        fn end(&self) {
            self.inner.end();
        }
    }

    #[tokio::test]
    async fn terminal_sizing_refused_claim_freezes_until_new_attachment() {
        let control = SizingControl::new(12, &[]);
        control.set_claim_ok(false);
        let coordinator = TerminalSizing::new();
        let key = SizingKey { socket_path: PathBuf::from("/tmp/cmux-sizing.sock"), surface_id: 7 };
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        coordinator.join(key.clone(), 1, 7, control_handle, SizingGrid { cols: 80, rows: 24 });
        control.wait_for_requests(2).await;
        let initial = control.requests();
        assert_eq!(initial[0].0, "resize-surface");
        assert_eq!(initial[1].0, "set-client-sizing");

        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(control.requests().len(), 2, "a refused claim must not auto-retry");

        let replacement = SizingControl::new(12, &[]);
        coordinator.join(
            key.clone(),
            2,
            7,
            Arc::new(replacement.clone()),
            SizingGrid { cols: 81, rows: 25 },
        );
        replacement.wait_for_requests(2).await;
        assert_eq!(replacement.requests()[1].0, "set-client-sizing");
        assert_eq!(
            coordinator.targets.lock().unwrap().get(&key).unwrap().state.lock().unwrap().owner,
            Some(2)
        );
        coordinator.leave(&key, 1);
        coordinator.leave(&key, 2);
    }

    #[tokio::test]
    async fn stale_candidate_reply_does_not_detach_current_endpoint() {
        let control = SizingControl::new(12, &[]);
        control.block_claim_dispatch();
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-stale-candidate-reply.sock"),
            surface_id: 41,
        };
        coordinator
            .join(key.clone(), 1, 41, Arc::new(control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial sizing barrier");
        control.wait_for_claim_dispatch().await;

        let target = coordinator.targets.lock().unwrap().get(&key).cloned().unwrap();
        let endpoint = coordinator.queue_for(&key, 1).expect("candidate endpoint");
        let old_generation = TerminalSizing::current_generation(&target);

        // Simulate a newer viewer transition while the old claim request is
        // waiting for its daemon response. The generation change is the
        // ordering fence; the endpoint itself remains attached and healthy.
        {
            let _queue_state = target.queue.state.lock().unwrap();
            let _state = target.state.lock().unwrap();
            assert_eq!(TerminalSizing::current_generation(&target), old_generation);
            coordinator.advance_generation(&target);
        }
        control.release_claim_dispatch();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if target.queue.state.lock().unwrap().claim_fence.is_none() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("stale candidate worker did not clear its old fence");

        let current = coordinator.queue_for(&key, 1).expect("current endpoint");
        assert!(Arc::ptr_eq(&current, &endpoint), "stale reply detached the live endpoint");
        assert!(current.is_active(), "stale reply deactivated the live endpoint");
        assert_eq!(
            target.state.lock().unwrap().owner,
            None,
            "stale candidate reply must not claim the newer generation"
        );
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn failed_close_permanently_freezes_retired_target_without_revival() {
        let control = SizingControl::new(12, &[]);
        control.set_end_ok(false);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-close-failure.sock"),
            surface_id: 40,
        };

        coordinator
            .join(key.clone(), 1, 40, Arc::new(control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial sizing barrier")
            .await
            .expect("initial sizing worker");
        let target = coordinator.targets.lock().unwrap().get(&key).cloned().unwrap();

        // The close response is false: the daemon did not prove that all
        // old-socket writes were processed. The target must remain retained
        // and fail closed, because recreating it would allow a new socket to
        // race an unknown old transport generation.
        coordinator.leave(&key, 1);
        control.wait_for_end().await;
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if target.queue.state.lock().unwrap().closing_failed {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("failed close did not freeze the target");
        coordinator.remove_retired_target(&target);

        {
            let queue_state = target.queue.state.lock().unwrap();
            assert!(queue_state.closing_failed);
            assert!(!queue_state.closing.is_empty());
            assert!(target.queue.wire_pending.lock().unwrap().is_empty());
            assert!(!target.queue.wire_running.load(Ordering::Acquire));
        }
        assert!(target.state.lock().unwrap().retired);
        assert!(coordinator.targets.lock().unwrap().contains_key(&key));

        // A failed close is permanent for this target. A join must not clear
        // `retired` or attach a replacement to the un-ordered transport.
        assert!(
            coordinator
                .join(
                    key.clone(),
                    2,
                    40,
                    Arc::new(SizingControl::new(12, &[])),
                    SizingGrid { cols: 80, rows: 24 },
                )
                .is_none(),
            "failed close must not revive a retired target"
        );
        assert!(target.state.lock().unwrap().viewers.is_empty());
    }

    #[tokio::test]
    async fn terminal_sizing_claims_after_a_passive_report_is_not_accepted() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key =
            SizingKey { socket_path: PathBuf::from("/tmp/cmux-sizing-report.sock"), surface_id: 8 };
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        // `accepted:false` on the passive report means that another client
        // currently owns the geometry. It is not a claim failure; the next
        // command must still be the exclusive claim request.
        control.reject_next_resize();
        coordinator.join(key.clone(), 1, 8, control_handle, SizingGrid { cols: 80, rows: 24 });
        control.wait_for_requests(2).await;
        let requests = control.requests();
        assert_eq!(requests[0].0, "resize-surface");
        assert_eq!(requests[1].0, "set-client-sizing");
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn terminal_sizing_refused_owner_resize_freezes_until_new_attachment() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-reclaim.sock"),
            surface_id: 9,
        };
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        coordinator.join(key.clone(), 1, 9, control_handle, SizingGrid { cols: 80, rows: 24 });
        control.wait_for_requests(2).await;

        control.reject_next_resize();
        coordinator.update(&key, 1, SizingGrid { cols: 100, rows: 40 });
        control.wait_for_requests(3).await;
        let requests = control.requests();
        assert_eq!(requests[2].0, "resize-surface");
        assert_eq!(requests[2].1["cols"], 100);
        assert_eq!(requests[2].1["rows"], 40);
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(control.requests().len(), 3, "refusal must not auto-retry");
        assert_eq!(
            coordinator.targets.lock().unwrap().get(&key).unwrap().state.lock().unwrap().owner,
            None
        );

        let replacement = SizingControl::new(12, &[]);
        coordinator.join(
            key.clone(),
            2,
            9,
            Arc::new(replacement.clone()),
            SizingGrid { cols: 100, rows: 40 },
        );
        replacement.wait_for_requests(2).await;
        assert_eq!(replacement.requests()[1].0, "set-client-sizing");
        coordinator.leave(&key, 1);
        coordinator.leave(&key, 2);
    }

    #[tokio::test]
    async fn terminal_sizing_uses_smallest_viewer_and_freezes_after_owner_leaves() {
        let first = SizingControl::new(12, &[]);
        let second = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-multi-viewer.sock"),
            surface_id: 10,
        };
        let first_handle: Arc<dyn ControlHandle> = Arc::new(first.clone());
        let second_handle: Arc<dyn ControlHandle> = Arc::new(second.clone());

        coordinator.join(key.clone(), 1, 10, first_handle, SizingGrid { cols: 120, rows: 40 });
        first.wait_for_requests(2).await;

        coordinator.join(key.clone(), 2, 10, second_handle, SizingGrid { cols: 80, rows: 24 });
        first.wait_for_requests(3).await;
        let first_requests = first.requests();
        assert_eq!(first_requests[2].0, "resize-surface");
        assert_eq!(first_requests[2].1["cols"], 80);
        assert_eq!(first_requests[2].1["rows"], 24);
        assert!(second.requests().is_empty(), "non-owner must not resize the surface");

        // Removing the owner freezes the core grid. The existing survivor is
        // not elected from another socket.
        coordinator.leave(&key, 1);
        assert!(second.requests().is_empty(), "owner loss must not issue a replacement claim");
        let second_endpoint = coordinator.queue_for(&key, 2).expect("survivor endpoint");
        second_endpoint.enqueue_input(b"after-owner-leave");
        assert_eq!(
            second.sends().iter().map(|(command, _)| command.as_str()).collect::<Vec<_>>(),
            vec!["send"]
        );

        // A newly attached viewer makes the explicit replacement claim.
        let replacement = SizingControl::new(12, &[]);
        coordinator.join(
            key.clone(),
            3,
            10,
            Arc::new(replacement.clone()),
            SizingGrid { cols: 100, rows: 30 },
        );
        replacement.wait_for_requests(2).await;
        assert_eq!(replacement.requests()[1].0, "set-client-sizing");
        assert_eq!(
            coordinator.targets.lock().unwrap().get(&key).unwrap().state.lock().unwrap().owner,
            Some(3)
        );

        // A resize from the explicit owner is sent through its connection.
        coordinator.update(&key, 2, SizingGrid { cols: 100, rows: 30 });
        replacement.wait_for_requests(3).await;
        assert_eq!(replacement.requests()[2].0, "resize-surface");
        coordinator.leave(&key, 2);
        coordinator.leave(&key, 3);
    }

    #[tokio::test]
    async fn non_owner_resize_is_fenced_before_owner_input_and_freezes_after_disconnect() {
        let owner = SizingControl::new(12, &[]);
        let viewer = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-cross-viewer-order.sock"),
            surface_id: 15,
        };
        let owner_handle: Arc<dyn ControlHandle> = Arc::new(owner.clone());
        let viewer_handle: Arc<dyn ControlHandle> = Arc::new(viewer.clone());

        let owner_joined = coordinator
            .join(key.clone(), 1, 15, owner_handle.clone(), SizingGrid { cols: 120, rows: 40 })
            .expect("owner sizing barrier");
        owner.wait_for_requests(2).await;
        owner_joined.await.expect("owner sizing worker");
        let viewer_joined = coordinator
            .join(key.clone(), 2, 15, viewer_handle, SizingGrid { cols: 120, rows: 40 })
            .expect("viewer sizing barrier");
        viewer_joined.await.expect("viewer sizing worker");
        let owner_claims_before =
            owner.requests().iter().filter(|(command, _)| command == "set-client-sizing").count();

        // Hold the owner's request reply. The synchronous queue fence must
        // still reach the wire before input from the owner can be accepted.
        owner.block_sizing();
        coordinator.update(&key, 2, SizingGrid { cols: 80, rows: 24 });
        owner.wait_for_requests(3).await;
        let owner_queue = coordinator.queue_for(&key, 1).expect("owner sizing queue");
        let owner_proxy = ControlTerminalControl {
            control: owner_handle,
            surface_id: 15,
            sizing: None,
            queue: Some(owner_queue),
            ended: AtomicBool::new(false),
        };
        owner_proxy.write(b"input-after-viewer-resize");
        let sends = owner.sends();
        let tail =
            sends.iter().map(|(command, _)| command.as_str()).rev().take(2).collect::<Vec<_>>();
        assert_eq!(tail, vec!["send", "resize-surface"]);

        // Disconnect the owner while its direct resize request is blocked.
        // The stale owner must not claim again, and the remaining viewer is
        // left attached with the core grid frozen.
        coordinator.leave(&key, 1);
        owner.end();
        owner.release_sizing();
        let viewer_endpoint = coordinator.queue_for(&key, 2).expect("survivor endpoint");
        viewer_endpoint.enqueue_input(b"input-after-owner-loss");
        assert_eq!(
            viewer.sends(),
            vec![(
                "send".to_owned(),
                json!({
                    "surface": 15,
                    "bytes": BASE64.encode(b"input-after-owner-loss"),
                })
            )]
        );
        assert_eq!(
            owner.requests().iter().filter(|(command, _)| command == "set-client-sizing").count(),
            owner_claims_before,
            "a disconnected owner must not emit a stale claim"
        );
        coordinator.leave(&key, 2);
    }

    #[tokio::test]
    async fn shared_sizing_queue_orders_shrink_and_all_viewer_input() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-shared-input-order.sock"),
            surface_id: 16,
        };
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        let owner_joined = coordinator
            .join(
                key.clone(),
                1,
                16,
                Arc::clone(&control_handle),
                SizingGrid { cols: 120, rows: 40 },
            )
            .expect("owner sizing barrier");
        owner_joined.await.expect("owner sizing worker");
        let viewer_joined = coordinator
            .join(key.clone(), 2, 16, control_handle, SizingGrid { cols: 120, rows: 40 })
            .expect("viewer sizing barrier");
        viewer_joined.await.expect("viewer sizing worker");

        let owner_endpoint = coordinator.queue_for(&key, 1).expect("owner endpoint");
        let viewer_endpoint = coordinator.queue_for(&key, 2).expect("viewer endpoint");
        let owner_proxy = Arc::new(ControlTerminalControl {
            control: Arc::new(control.clone()),
            surface_id: 16,
            sizing: None,
            queue: Some(owner_endpoint),
            ended: AtomicBool::new(false),
        });
        let viewer_proxy = Arc::new(ControlTerminalControl {
            control: Arc::new(control.clone()),
            surface_id: 16,
            sizing: None,
            queue: Some(viewer_endpoint),
            ended: AtomicBool::new(false),
        });

        // The non-owner shrink is canonicalized on the shared session queue;
        // input from that same viewer cannot appear before its resize fence.
        coordinator.update(&key, 2, SizingGrid { cols: 80, rows: 24 });
        viewer_proxy.write(b"viewer-after-shrink");

        // Concurrent input from both viewers uses the same queue. The order of
        // the two input frames may vary, but neither can overtake the resize.
        let owner_thread = {
            let owner_proxy = Arc::clone(&owner_proxy);
            std::thread::spawn(move || owner_proxy.write(b"owner-concurrent"))
        };
        let viewer_thread = {
            let viewer_proxy = Arc::clone(&viewer_proxy);
            std::thread::spawn(move || viewer_proxy.write(b"viewer-concurrent"))
        };
        owner_thread.join().expect("owner input thread");
        viewer_thread.join().expect("viewer input thread");

        let sends = control.sends();
        let commands: Vec<&str> = sends.iter().map(|(command, _)| command.as_str()).collect();
        let resize_index = commands
            .iter()
            .rposition(|command| *command == "resize-surface")
            .expect("canonical shrink resize");
        assert!(
            commands[resize_index..]
                .iter()
                .all(|command| *command == "resize-surface" || *command == "send")
        );
        assert_eq!(commands.len() - resize_index, 4);
        let payloads: Vec<String> = sends[resize_index + 1..]
            .iter()
            .filter_map(|(command, params)| {
                (command == "send").then(|| params["bytes"].as_str().unwrap_or_default().to_owned())
            })
            .map(|encoded| {
                String::from_utf8(BASE64.decode(encoded).expect("base64 input"))
                    .expect("utf8 input")
            })
            .collect();
        assert_eq!(payloads.len(), 3);
        assert!(payloads.iter().any(|payload| payload == "viewer-after-shrink"));
        assert!(payloads.iter().any(|payload| payload == "owner-concurrent"));
        assert!(payloads.iter().any(|payload| payload == "viewer-concurrent"));
        coordinator.leave(&key, 1);
        coordinator.leave(&key, 2);
    }

    #[tokio::test]
    async fn refused_owner_resize_freezes_survivor_until_explicit_claim() {
        let owner = SizingControl::new(12, &[]);
        let survivor = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-refused-owner-order.sock"),
            surface_id: 17,
        };
        let owner_handle: Arc<dyn ControlHandle> = Arc::new(owner.clone());
        let survivor_handle: Arc<dyn ControlHandle> = Arc::new(survivor.clone());
        let owner_joined = coordinator
            .join(key.clone(), 1, 17, owner_handle, SizingGrid { cols: 120, rows: 40 })
            .expect("owner sizing barrier");
        owner_joined.await.expect("owner sizing worker");
        let survivor_joined = coordinator
            .join(key.clone(), 2, 17, survivor_handle, SizingGrid { cols: 120, rows: 40 })
            .expect("survivor sizing barrier");
        survivor_joined.await.expect("survivor sizing worker");

        owner.reject_next_resize();
        owner.block_sizing();
        coordinator.update(&key, 2, SizingGrid { cols: 80, rows: 24 });
        owner.wait_for_requests(3).await;
        owner.release_sizing();

        // The accepted:false response clears ownership and leaves the core
        // geometry frozen. The existing survivor does not receive a claim.
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(
            coordinator.targets.lock().unwrap().get(&key).unwrap().state.lock().unwrap().owner,
            None,
            "accepted:false must freeze authority, not elect the survivor"
        );
        assert_eq!(
            owner.requests().iter().filter(|(command, _)| command == "set-client-sizing").count(),
            1,
            "the refused owner must not claim again"
        );
        let survivor_endpoint = coordinator.queue_for(&key, 2).expect("survivor endpoint");
        let survivor_proxy = ControlTerminalControl {
            control: Arc::new(survivor.clone()),
            surface_id: 17,
            sizing: None,
            queue: Some(survivor_endpoint),
            ended: AtomicBool::new(false),
        };
        survivor_proxy.write(b"input-after-refused-owner");
        assert_eq!(
            survivor.sends().iter().map(|(command, _)| command.as_str()).collect::<Vec<_>>(),
            vec!["send"]
        );
        coordinator.leave(&key, 1);
        coordinator.leave(&key, 2);
    }

    #[tokio::test]
    async fn single_viewer_refused_resize_freezes_without_a_new_claim() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-single-refusal.sock"),
            surface_id: 25,
        };
        let handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        let joined = coordinator
            .join(key.clone(), 1, 25, handle, SizingGrid { cols: 120, rows: 40 })
            .expect("initial sizing barrier");
        control.wait_for_requests(2).await;
        joined.await.expect("initial sizing worker");

        // The owner reports a new grid, but the daemon refuses that resize.
        // With no explicit new claim, authority remains frozen.
        control.reject_next_resize();
        control.block_sizing();
        coordinator.update(&key, 1, SizingGrid { cols: 100, rows: 30 });
        control.wait_for_requests(3).await;
        control.release_sizing();

        tokio::time::sleep(Duration::from_millis(100)).await;
        let requests = control.requests();
        assert_eq!(requests[2].0, "resize-surface");
        assert_eq!(requests.len(), 3);
        assert_eq!(
            coordinator.targets.lock().unwrap().get(&key).unwrap().state.lock().unwrap().owner,
            None
        );

        let endpoint = coordinator.queue_for(&key, 1).expect("frozen endpoint");
        endpoint.enqueue_input(b"after-single-viewer-refusal");
        let sends = control.sends();
        assert_eq!(sends.last().map(|(command, _)| command.as_str()), Some("send"));
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn owner_loss_does_not_auto_claim_from_an_old_or_surviving_socket() {
        let owner = SizingControl::new(12, &[]);
        let survivor = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-frozen-owner-loss.sock"),
            surface_id: 26,
        };
        let owner_handle: Arc<dyn ControlHandle> = Arc::new(owner.clone());
        let survivor_handle: Arc<dyn ControlHandle> = Arc::new(survivor.clone());
        coordinator
            .join(key.clone(), 1, 26, owner_handle, SizingGrid { cols: 120, rows: 40 })
            .expect("owner sizing barrier")
            .await
            .expect("owner sizing worker");
        coordinator
            .join(key.clone(), 2, 26, survivor_handle, SizingGrid { cols: 80, rows: 24 })
            .expect("survivor sizing barrier")
            .await
            .expect("survivor sizing worker");

        let old_generation = {
            let target = coordinator.targets.lock().unwrap().get(&key).cloned().unwrap();
            TerminalSizing::current_generation(&target)
        };
        coordinator.leave(&key, 1);
        coordinator.update(&key, 2, SizingGrid { cols: 80, rows: 24 });
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(survivor.requests().is_empty(), "survivor update must not auto-claim");
        assert_eq!(
            coordinator.targets.lock().unwrap().get(&key).unwrap().state.lock().unwrap().owner,
            None
        );
        assert!(
            TerminalSizing::current_generation(
                &coordinator.targets.lock().unwrap().get(&key).cloned().unwrap()
            ) > old_generation
        );

        // A new attachment is the only event that may issue a replacement
        // report/claim.
        let replacement = SizingControl::new(12, &[]);
        coordinator.join(
            key.clone(),
            3,
            26,
            Arc::new(replacement.clone()),
            SizingGrid { cols: 80, rows: 24 },
        );
        replacement.wait_for_requests(2).await;
        assert_eq!(replacement.requests()[1].0, "set-client-sizing");
        assert_eq!(
            coordinator.targets.lock().unwrap().get(&key).unwrap().state.lock().unwrap().owner,
            Some(3)
        );
        coordinator.leave(&key, 2);
        coordinator.leave(&key, 3);
    }

    #[tokio::test]
    async fn owner_leave_freezes_survivor_input_until_explicit_claim() {
        let owner = SizingControl::new(12, &[]);
        let survivor = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-owner-leave-order.sock"),
            surface_id: 18,
        };
        let owner_handle: Arc<dyn ControlHandle> = Arc::new(owner.clone());
        let survivor_handle: Arc<dyn ControlHandle> = Arc::new(survivor.clone());
        coordinator
            .join(key.clone(), 1, 18, owner_handle, SizingGrid { cols: 120, rows: 40 })
            .expect("owner sizing barrier")
            .await
            .expect("owner sizing worker");
        coordinator
            .join(key.clone(), 2, 18, survivor_handle, SizingGrid { cols: 100, rows: 30 })
            .expect("survivor sizing barrier")
            .await
            .expect("survivor sizing worker");
        assert_eq!(
            coordinator.targets.lock().unwrap().get(&key).unwrap().state.lock().unwrap().owner,
            Some(1)
        );

        let before = survivor.sends().len();
        coordinator.leave(&key, 1);
        let survivor_endpoint = coordinator.queue_for(&key, 2).expect("survivor endpoint");
        survivor_endpoint.enqueue_input(b"after-owner-leave");
        let suffix: Vec<String> =
            survivor.sends()[before..].iter().map(|(command, _)| command.clone()).collect();
        assert_eq!(suffix, vec!["send"]);
        coordinator.leave(&key, 2);
    }

    #[tokio::test]
    async fn non_owner_leave_fences_owner_grid_growth_before_input() {
        let owner = SizingControl::new(12, &[]);
        let viewer = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-viewer-leave-order.sock"),
            surface_id: 21,
        };
        let owner_handle: Arc<dyn ControlHandle> = Arc::new(owner.clone());
        let viewer_handle: Arc<dyn ControlHandle> = Arc::new(viewer.clone());
        coordinator
            .join(key.clone(), 1, 21, owner_handle, SizingGrid { cols: 120, rows: 40 })
            .expect("owner sizing barrier")
            .await
            .expect("owner sizing worker");
        coordinator
            .join(key.clone(), 2, 21, viewer_handle, SizingGrid { cols: 80, rows: 24 })
            .expect("viewer sizing barrier")
            .await
            .expect("viewer sizing worker");

        let before = owner.sends().len();
        coordinator.leave(&key, 2);
        let owner_endpoint = coordinator.queue_for(&key, 1).expect("owner endpoint");
        owner_endpoint.enqueue_input(b"after-viewer-leave");
        let suffix: Vec<String> =
            owner.sends()[before..].iter().map(|(command, _)| command.clone()).collect();
        assert_eq!(suffix, vec!["resize-surface", "send"]);
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn stale_update_for_missing_viewer_keeps_claim_generation() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-stale-update-generation.sock"),
            surface_id: 29,
        };
        coordinator
            .join(key.clone(), 1, 29, Arc::new(control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial sizing barrier")
            .await
            .expect("initial sizing worker");
        let target = coordinator.targets.lock().unwrap().get(&key).cloned().unwrap();
        let endpoint = coordinator.queue_for(&key, 1).expect("active endpoint");
        let generation = TerminalSizing::current_generation(&target);
        {
            let mut state = target.queue.state.lock().unwrap();
            state.claim_fence = Some(ClaimFence {
                generation,
                viewer_id: 1,
                grid: SizingGrid { cols: 80, rows: 24 },
                token: 41,
                endpoint_ptr: endpoint_ptr(&endpoint),
            });
        }

        // This update names no attached viewer. It must not advance the
        // active generation or clear the current candidate fence.
        coordinator.update(&key, 99, SizingGrid { cols: 100, rows: 30 });
        assert_eq!(TerminalSizing::current_generation(&target), generation);
        assert!(target.queue.state.lock().unwrap().claim_fence.is_some_and(|fence| {
            fence.generation == generation
                && fence.viewer_id == 1
                && fence.token == 41
                && fence.endpoint_ptr == endpoint_ptr(&endpoint)
        }));
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn stale_leave_cannot_remove_a_reconnected_endpoint_or_advance_generation() {
        let old_control = SizingControl::new(12, &[]);
        let new_control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-stale-leave-generation.sock"),
            surface_id: 30,
        };
        coordinator
            .join(
                key.clone(),
                1,
                30,
                Arc::new(old_control.clone()),
                SizingGrid { cols: 80, rows: 24 },
            )
            .expect("old sizing barrier")
            .await
            .expect("old sizing worker");
        let old_endpoint = coordinator.queue_for(&key, 1).expect("old endpoint");
        coordinator
            .join(
                key.clone(),
                1,
                30,
                Arc::new(new_control.clone()),
                SizingGrid { cols: 80, rows: 24 },
            )
            .expect("replacement sizing barrier")
            .await
            .expect("replacement sizing worker");
        let new_endpoint = coordinator.queue_for(&key, 1).expect("replacement endpoint");
        let target = coordinator.targets.lock().unwrap().get(&key).cloned().unwrap();
        let generation = TerminalSizing::current_generation(&target);

        coordinator.leave_endpoint(&key, 1, &old_endpoint);
        assert_eq!(TerminalSizing::current_generation(&target), generation);
        let current = coordinator.queue_for(&key, 1).expect("replacement remains attached");
        assert!(Arc::ptr_eq(&current, &new_endpoint));
        assert!(new_endpoint.is_active());
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn stale_sizing_lease_cannot_update_or_remove_replacement() {
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-stale-lease.sock"),
            surface_id: 31,
        };
        let old_control = SizingControl::new(12, &[]);
        let new_control = SizingControl::new(12, &[]);
        let old_lease = TerminalSizingLease::new(&coordinator, key.clone(), 1, 31);
        let new_lease = TerminalSizingLease::new(&coordinator, key.clone(), 1, 31);

        old_lease
            .join(Arc::new(old_control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("old lease join")
            .await
            .expect("old sizing worker");
        let old_endpoint = old_lease.queue().expect("old lease endpoint");
        new_lease
            .join(Arc::new(new_control.clone()), SizingGrid { cols: 100, rows: 30 })
            .expect("replacement lease join")
            .await
            .expect("replacement sizing worker");
        let new_endpoint = new_lease.queue().expect("replacement lease endpoint");
        assert!(!Arc::ptr_eq(&old_endpoint, &new_endpoint));

        let target = coordinator.targets.lock().unwrap().get(&key).cloned().unwrap();
        let generation = TerminalSizing::current_generation(&target);
        old_lease.update(SizingGrid { cols: 40, rows: 20 });
        assert_eq!(TerminalSizing::current_generation(&target), generation);
        assert_eq!(
            target.state.lock().unwrap().viewers.get(&1).map(|viewer| viewer.grid),
            Some(SizingGrid { cols: 100, rows: 30 })
        );

        old_lease.leave();
        let current = coordinator.queue_for(&key, 1).expect("replacement remains attached");
        assert!(Arc::ptr_eq(&current, &new_endpoint));
        assert!(new_endpoint.is_active());
        new_lease.leave();
    }

    #[tokio::test]
    async fn released_sizing_lease_drops_endpoint_callback_cycle() {
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-lease-cycle.sock"),
            surface_id: 32,
        };
        let control = CallbackSizingControl::new(12);
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        let lease = TerminalSizingLease::new(&coordinator, key, 1, 32);
        let lease_for_callback = Arc::clone(&lease);
        control_handle.on_close(Box::new(move || {
            let _ = lease_for_callback.leave();
        }));

        let waiter = lease
            .join(control_handle.clone(), SizingGrid { cols: 80, rows: 24 })
            .expect("sizing lease join");
        waiter.await.expect("sizing worker");
        let endpoint = lease.queue().expect("sizing endpoint");
        let endpoint_weak = Arc::downgrade(&endpoint);
        let lease_weak = Arc::downgrade(&lease);

        assert!(lease.leave(), "joined lease must own queue teardown");
        // The close callback and the proxy drop can both release the same
        // lease. A repeated call must retain the queue-owned marker; otherwise
        // the second path can call control.end() directly while the FIFO close
        // is still pending.
        assert!(lease.leave(), "repeated joined-lease release must stay queue-owned");
        assert!(lease.state.lock().unwrap().endpoint.is_none());
        drop(endpoint);
        drop(lease);
        drop(control_handle);
        drop(control);

        assert!(endpoint_weak.upgrade().is_none(), "released lease retained endpoint");
        assert!(lease_weak.upgrade().is_none(), "control callback retained released lease");
    }

    #[tokio::test]
    async fn setup_cleanup_guard_waits_for_queued_sizing_close() {
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-guard-close.sock"),
            surface_id: 42,
        };
        let control = SizingControl::new(12, &[]);
        control.block_end();
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        let lease = TerminalSizingLease::new(&coordinator, key.clone(), 1, 42);
        lease
            .join(control_handle.clone(), SizingGrid { cols: 80, rows: 24 })
            .expect("sizing join")
            .await
            .expect("sizing worker");

        let mut guard = ControlCleanupGuard::new(control_handle);
        guard.set_sizing(Arc::clone(&lease));
        assert!(lease.leave(), "joined lease must queue its close");
        control.wait_for_end_started().await;

        // The setup guard is released while the coordinator's end barrier is
        // still waiting. It must not call control.end() directly.
        drop(guard);
        assert!(!control.ended(), "cleanup bypassed the queued sizing close");
        control.release_end();
        control.wait_for_end().await;
    }

    #[tokio::test]
    async fn joining_cancel_persists_queue_owned_cleanup_through_rollback() {
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-joining-cancel.sock"),
            surface_id: 43,
        };
        let control = SizingControl::new(12, &[]);
        control.block_end();
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        let lease = TerminalSizingLease::new(&coordinator, key.clone(), 1, 43);
        let mut guard = ControlCleanupGuard::new(Arc::clone(&control_handle));
        guard.set_sizing(Arc::clone(&lease));

        // Model the cancellation point inside TerminalSizingLease::join:
        // the coordinator endpoint has been created, but the lease has not
        // yet transferred to `joined`.
        let (waiter, endpoint) = coordinator
            .join_with_endpoint(
                key.clone(),
                1,
                43,
                control_handle,
                SizingGrid { cols: 80, rows: 24 },
            )
            .expect("coordinator endpoint");
        waiter.await.expect("initial sizing worker");
        {
            let mut state = lease.state.lock().unwrap();
            state.joining = true;
        }
        assert!(lease.leave(), "cancellation during join must reserve queue teardown");
        {
            let mut state = lease.state.lock().unwrap();
            // This is the rollback transition after join observes released.
            state.joining = false;
            state.joined = false;
        }
        coordinator.leave_endpoint(&key, 1, &endpoint);
        control.wait_for_end_started().await;

        // The rollback close is now in flight, but the lease no longer says
        // `joining` or `joined`. The persistent queue-owned marker must still
        // prevent the cleanup guard from directly ending the socket.
        drop(guard);
        assert!(!control.ended(), "joining-cancel cleanup bypassed FIFO close");
        control.release_end();
        control.wait_for_end().await;
    }

    #[test]
    fn failed_join_without_endpoint_releases_queue_owned_marker() {
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-failed-join-marker.sock"),
            surface_id: 44,
        };
        let control = SizingControl::new(12, &[]);
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        let lease = TerminalSizingLease::new(&coordinator, key, 1, 44);
        {
            let mut state = lease.state.lock().unwrap();
            state.joining = true;
            state.released = true;
            state.queue_owned = true;
        }

        // A failed coordinator registration returns no endpoint, so no FIFO
        // close can exist. The rollback must clear the provisional marker and
        // let the setup guard close this standalone control.
        assert!(lease.finish_join(None));
        assert!(!lease.state.lock().unwrap().queue_owned);
        let mut guard = ControlCleanupGuard::new(control_handle);
        guard.set_sizing(lease);
        drop(guard);
        assert!(control.ended(), "failed join did not close its standalone control");
    }

    #[test]
    fn delayed_claim_fence_is_preserved_before_survivor_input() {
        let control = SizingControl::new(12, &[]);
        let queue = OrderedControlQueue::new(18);
        let endpoint = queue.endpoint(2, Arc::new(control.clone()));

        // Model an owner-loss transition while the sizing worker is between
        // polls. The candidate pair is reserved but not yet drained.
        {
            let mut state = queue.state.lock().unwrap();
            state.worker_running = true;
            assert!(!queue.reserve_resize_locked(
                &mut state,
                &endpoint,
                SizingGrid { cols: 80, rows: 24 },
                1,
            ));
        }

        // An intervening same-grid candidate update must not consume the
        // private marker. Input still flushes the reserved report/claim
        // first; when the delayed worker reaches the candidate it consumes
        // the marker instead of emitting a duplicate pair after this input.
        {
            let mut state = queue.state.lock().unwrap();
            assert!(!queue.enqueue_resize_locked(
                &mut state,
                &endpoint,
                SizingGrid { cols: 80, rows: 24 },
                true,
            ));
        }
        endpoint.enqueue_input(b"survivor-input");
        let state = queue.state.lock().unwrap();
        assert!(state.claim_fence.is_some_and(|fence| {
            fence.viewer_id == endpoint.viewer_id
                && fence.grid == SizingGrid { cols: 80, rows: 24 }
                && fence.endpoint_ptr == endpoint_ptr(&endpoint)
        }));
        drop(state);
        let commands: Vec<&str> =
            control.sends().iter().map(|(command, _)| command.as_str()).collect();
        assert_eq!(commands, vec!["resize-surface", "set-client-sizing", "send"]);
    }

    #[tokio::test]
    async fn reserved_resize_precedes_generation_update_and_leave() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-dispatch-reservation.sock"),
            surface_id: 35,
        };
        coordinator
            .join(key.clone(), 1, 35, Arc::new(control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial sizing barrier")
            .await
            .expect("initial sizing worker");
        let endpoint = coordinator.queue_for(&key, 1).expect("owner endpoint");
        let before = control.events().len();
        let before_sends = control.sends().len();
        control.block_ordered_send();

        // The worker reserves the resize while the old generation is still
        // current, then pauses immediately before the control write.
        coordinator.update(&key, 1, SizingGrid { cols: 100, rows: 30 });
        control.wait_for_ordered_send().await;

        // Both mutations acquire the queue actor lock after the reservation.
        // They must advance/freeze the state, but they cannot retract the
        // already-reserved resize or let a later close overtake it.
        coordinator.update(&key, 1, SizingGrid { cols: 120, rows: 40 });
        coordinator.leave_endpoint(&key, 1, &endpoint);
        assert!(!endpoint.is_active());

        control.release_ordered_send();
        control.wait_for_sends(before_sends + 1).await;
        control.wait_for_end().await;
        let events = control.events();
        assert_eq!(events[before], "send:resize-surface");
        assert!(control.ended());
    }

    #[tokio::test]
    async fn reserved_resize_precedes_failure_invalidation_and_close() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-dispatch-failure.sock"),
            surface_id: 36,
        };
        coordinator
            .join(key.clone(), 1, 36, Arc::new(control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial sizing barrier")
            .await
            .expect("initial sizing worker");
        let endpoint = coordinator.queue_for(&key, 1).expect("owner endpoint");
        let queue = endpoint.queue.upgrade().expect("sizing queue");
        let before = control.events().len();
        let before_sends = control.sends().len();
        control.block_ordered_send();

        coordinator.update(&key, 1, SizingGrid { cols: 100, rows: 30 });
        control.wait_for_ordered_send().await;

        // A transport failure uses the same actor lock as reserve_command.
        // It invalidates the endpoint and queues its close, but cannot cancel
        // the resize that was already reserved before the failure.
        queue.fail_endpoint(&endpoint);
        assert!(!endpoint.is_active());
        control.release_ordered_send();
        control.wait_for_sends(before_sends + 1).await;
        control.wait_for_end().await;

        let events = control.events();
        assert_eq!(events[before], "send:resize-surface");
        assert!(control.ended());
    }

    #[tokio::test]
    async fn busy_queue_flushes_resize_before_verified_request() {
        let control = SizingControl::new(12, &[]);
        let queue = OrderedControlQueue::new(19);
        let endpoint = queue.endpoint(1, Arc::new(control.clone()));
        {
            let mut state = queue.state.lock().unwrap();
            state.worker_running = true;
            assert!(!queue.enqueue_resize_locked(
                &mut state,
                &endpoint,
                SizingGrid { cols: 100, rows: 30 },
                false,
            ));
        }

        // A worker may be between drain polls. The verified request must not
        // enter the control writer before the pending report.
        endpoint.flush_before_request();
        let _ = control
            .request("resize-surface", json!({ "surface": 19, "cols": 100, "rows": 30 }))
            .await;
        assert_eq!(control.sends()[0].0, "resize-surface");
        assert_eq!(control.requests()[0].0, "resize-surface");
    }

    #[tokio::test]
    async fn owner_resize_batch_keeps_pending_report_before_request_when_worker_running() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-owner-batch.sock"),
            surface_id: 33,
        };
        let joined = coordinator
            .join(key.clone(), 1, 33, Arc::new(control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial owner sizing barrier");
        joined.await.expect("initial owner sizing worker");
        control.wait_for_sends(2).await;
        control.wait_for_requests(2).await;

        let target = coordinator.targets.lock().unwrap().get(&key).cloned().unwrap();
        let endpoint = coordinator.queue_for(&key, 1).expect("owner endpoint");
        let before = control.events().len();
        let before_sends = control.sends().len();
        let grid = SizingGrid { cols: 100, rows: 30 };
        let generation = {
            // Leave a pending resize behind a worker that is already marked
            // running. The owner batch must consume it and append its
            // verified request before any later input command.
            let mut queue_state = target.queue.state.lock().unwrap();
            let mut state = target.state.lock().unwrap();
            state.viewers.get_mut(&1).unwrap().grid = grid;
            state.applied = Some(SizingGrid { cols: 80, rows: 24 });
            let generation = coordinator.advance_generation(&target);
            queue_state.worker_running = true;
            queue_state.pending_resize = Some((generation, Arc::clone(&endpoint), grid, false));
            generation
        };

        let result =
            coordinator.owner_resize_request(&target, 1, &endpoint, grid, generation, 33).await;
        assert!(matches!(result, OwnerResizeRequestOutcome::Reply(Some(_))));

        endpoint.enqueue_input(b"after-owner-resize");
        control.wait_for_sends(before_sends + 2).await;
        let events = control.events();
        let suffix: Vec<&str> = events[before..].iter().map(String::as_str).collect();
        assert_eq!(suffix, vec!["send:resize-surface", "request:resize-surface", "send:send"]);
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn update_enqueues_resize_before_owner_input() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-update-input-order.sock"),
            surface_id: 37,
        };
        coordinator
            .join(key.clone(), 1, 37, Arc::new(control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial sizing barrier")
            .await
            .expect("initial sizing worker");
        let endpoint = coordinator.queue_for(&key, 1).expect("owner endpoint");
        let before = control.events().len();
        let before_sends = control.sends().len();
        let before_requests = control.requests().len();
        control.block_sizing();
        coordinator.update(&key, 1, SizingGrid { cols: 100, rows: 30 });
        endpoint.enqueue_input(b"ordered-update-input");
        control.wait_for_requests(before_requests + 1).await;
        let blocked_events = control.events();
        assert_eq!(
            blocked_events[before..].iter().map(String::as_str).collect::<Vec<_>>(),
            vec!["send:resize-surface", "request:resize-surface"]
        );
        control.release_sizing();
        control.wait_for_sends(before_sends + 2).await;
        let events = control.events();
        let suffix: Vec<&str> = events[before..before + 3].iter().map(String::as_str).collect();
        assert_eq!(suffix, vec!["send:resize-surface", "request:resize-surface", "send:send"]);
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn join_enqueues_owner_resize_before_owner_input() {
        let owner = SizingControl::new(12, &[]);
        let viewer = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-join-input-order.sock"),
            surface_id: 38,
        };
        coordinator
            .join(key.clone(), 1, 38, Arc::new(owner.clone()), SizingGrid { cols: 120, rows: 40 })
            .expect("initial sizing barrier")
            .await
            .expect("initial sizing worker");
        let before = owner.events().len();
        let before_sends = owner.sends().len();
        let before_requests = owner.requests().len();
        coordinator
            .join(key.clone(), 2, 38, Arc::new(viewer.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("viewer sizing barrier")
            .await
            .expect("viewer sizing worker");
        let endpoint = coordinator.queue_for(&key, 1).expect("owner endpoint");
        endpoint.enqueue_input(b"ordered-join-input");
        owner.wait_for_requests(before_requests + 1).await;
        owner.wait_for_sends(before_sends + 2).await;
        let events = owner.events();
        let suffix: Vec<&str> = events[before..before + 3].iter().map(String::as_str).collect();
        assert_eq!(suffix, vec!["send:resize-surface", "request:resize-surface", "send:send"]);
        coordinator.leave(&key, 2);
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn reconnect_input_waits_behind_fifo_close_barrier() {
        let old = SizingControl::new(12, &[]);
        let new = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-close-fifo.sock"),
            surface_id: 39,
        };
        coordinator
            .join(key.clone(), 1, 39, Arc::new(old.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial sizing barrier")
            .await
            .expect("initial sizing worker");
        let old_endpoint = coordinator.queue_for(&key, 1).expect("old endpoint");
        old.block_end();
        let replacement_waiter = coordinator
            .join(key.clone(), 1, 39, Arc::new(new.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("replacement sizing barrier");
        let replacement = coordinator.queue_for(&key, 1).expect("replacement endpoint");
        old.wait_for_end_started().await;

        // The replacement can enqueue input while the old close is waiting,
        // but the close command was inserted first under the queue actor. No
        // replacement frame may reach its control before the old barrier.
        replacement.enqueue_input(b"after-reconnect");
        assert!(new.sends().is_empty());

        old.release_end();
        old.wait_for_end().await;
        replacement_waiter.await.expect("replacement sizing worker");
        new.wait_for_sends(3).await;
        let events = new.events();
        let input_index = events.iter().position(|event| event == "send:send");
        let claim_index = events.iter().position(|event| event == "send:set-client-sizing");
        assert!(input_index > claim_index, "input overtook replacement claim: {events:?}");
        assert!(!old_endpoint.is_active());
        coordinator.leave(&key, 1);
    }

    #[tokio::test]
    async fn owner_resize_batch_queue_full_freezes_without_partial_commands() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-owner-batch-full.sock"),
            surface_id: 34,
        };
        coordinator
            .join(key.clone(), 1, 34, Arc::new(control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial owner sizing barrier")
            .await
            .expect("initial owner sizing worker");
        control.wait_for_sends(2).await;
        control.wait_for_requests(2).await;
        let target = coordinator.targets.lock().unwrap().get(&key).cloned().unwrap();
        let endpoint = coordinator.queue_for(&key, 1).expect("owner endpoint");
        let generation = TerminalSizing::current_generation(&target);
        {
            let mut queue_state = target.queue.state.lock().unwrap();
            let mut state = target.state.lock().unwrap();
            state.viewers.get_mut(&1).unwrap().grid = SizingGrid { cols: 100, rows: 30 };
            state.applied = Some(SizingGrid { cols: 80, rows: 24 });
            // Keep the bounded wire queue full and do not start a worker. The
            // owner batch must reject both commands together, not append only
            // its request and leave a report behind.
            queue_state.worker_running = true;
            let mut pending = target.queue.wire_pending.lock().unwrap();
            for _ in 0..MAX_ORDERED_CONTROL_COMMANDS {
                pending.push_back(OrderedControlCommand {
                    endpoint: Arc::clone(&endpoint),
                    generation: None,
                    expected_owner: None,
                    requires_unowned: false,
                    kind: OrderedControlCommandKind::Send {
                        command: "capacity-probe".to_owned(),
                        params: Value::Null,
                    },
                });
            }
        }

        let before_sends = control.sends().len();
        let before_requests = control.requests().len();
        let result = coordinator
            .owner_resize_request(
                &target,
                1,
                &endpoint,
                SizingGrid { cols: 100, rows: 30 },
                generation,
                34,
            )
            .await;
        assert!(matches!(result, OwnerResizeRequestOutcome::QueueFull));
        assert_eq!(control.sends().len(), before_sends);
        assert_eq!(control.requests().len(), before_requests);
        assert_eq!(target.queue.wire_pending.lock().unwrap().len(), MAX_ORDERED_CONTROL_COMMANDS);

        // `apply_target` has no request id to fail. Its documented QueueFull
        // response is to detach this owner and leave the core geometry frozen.
        coordinator.leave(&key, 1);
        let state = target.state.lock().unwrap();
        assert_eq!(state.owner, None);
        assert_eq!(state.applied, Some(SizingGrid { cols: 80, rows: 24 }));
        assert!(state.viewers.is_empty());
        drop(state);
        assert!(
            coordinator
                .join(
                    key,
                    2,
                    34,
                    Arc::new(SizingControl::new(12, &[])),
                    SizingGrid { cols: 80, rows: 24 },
                )
                .is_none(),
            "a retired target with an unqueued close must not be revived"
        );
    }

    #[tokio::test]
    async fn stale_pending_resize_is_dropped_after_generation_advance() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-stale-pending.sock"),
            surface_id: 41,
        };
        let joined = coordinator
            .join(key.clone(), 1, 41, Arc::new(control.clone()), SizingGrid { cols: 80, rows: 24 })
            .expect("initial sizing barrier");
        joined.await.expect("initial sizing worker");
        let target = coordinator.targets.lock().unwrap().get(&key).cloned().unwrap();
        let endpoint = coordinator.queue_for(&key, 1).expect("owner endpoint");
        let old_generation = TerminalSizing::current_generation(&target);
        {
            let mut queue_state = target.queue.state.lock().unwrap();
            let mut state = target.state.lock().unwrap();
            state.viewers.get_mut(&1).unwrap().grid = SizingGrid { cols: 100, rows: 30 };
            queue_state.pending_resize = Some((
                old_generation,
                Arc::clone(&endpoint),
                SizingGrid { cols: 100, rows: 30 },
                false,
            ));
            queue_state.worker_running = true;
            let first_new_generation = coordinator.advance_generation(&target);
            state.viewers.get_mut(&1).unwrap().grid = SizingGrid { cols: 80, rows: 24 };
            let second_new_generation = coordinator.advance_generation(&target);
            assert!(first_new_generation > old_generation);
            assert!(second_new_generation > first_new_generation);
        }

        let sends_before = control.sends().len();
        target.queue.clone().drain_async().await;
        assert!(target.queue.state.lock().unwrap().pending_resize.is_none());
        endpoint.enqueue_input(b"after-stale-resize");
        control.wait_for_sends(sends_before + 1).await;
        assert_eq!(control.sends()[sends_before].0, "send");
        assert!(endpoint.is_active(), "stale resize must not detach a healthy endpoint");
    }

    #[test]
    fn stale_nonclaim_pending_does_not_clear_current_claim_fence() {
        let queue = OrderedControlQueue::new(41);
        let old_control: Arc<dyn ControlHandle> = Arc::new(SizingControl::new(12, &[]));
        let new_control: Arc<dyn ControlHandle> = Arc::new(SizingControl::new(12, &[]));
        let old_endpoint = queue.endpoint(1, old_control);
        let new_endpoint = queue.endpoint(2, new_control);
        let current_generation = queue.current_generation();
        let expected_fence = ClaimFence {
            generation: current_generation,
            viewer_id: new_endpoint.viewer_id,
            grid: SizingGrid { cols: 80, rows: 24 },
            token: 7,
            endpoint_ptr: endpoint_ptr(&new_endpoint),
        };
        let mut state = queue.state.lock().unwrap();
        state.claim_fence = Some(expected_fence);
        state.pending_resize = Some((
            current_generation.saturating_sub(1),
            old_endpoint,
            SizingGrid { cols: 100, rows: 30 },
            false,
        ));
        assert!(queue.discard_stale_pending_locked(&mut state));
        assert_eq!(state.claim_fence, Some(expected_fence));
        assert!(state.pending_resize.is_none());
    }

    #[test]
    fn terminal_resize_does_not_wait_for_control_plane_barrier() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-fire-and-forget.sock"),
            surface_id: 14,
        };
        let lease = TerminalSizingLease::new(&coordinator, key, 1, 14);
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        lease.join(Arc::clone(&control_handle), SizingGrid { cols: 80, rows: 24 });
        let queue = lease.queue();
        // This is the same operation used by the pty_resize ingress branch;
        // it must only enqueue a coalesced worker request and return.
        let proxy = ControlTerminalControl {
            control: control_handle,
            surface_id: 14,
            sizing: Some(lease),
            queue,
            ended: AtomicBool::new(false),
        };
        proxy.resize(140, 50);
        assert!(control.requests().is_empty());
        proxy.write(b"input");
        let sends = control.sends();
        assert_eq!(
            sends.iter().map(|(command, _)| command.as_str()).collect::<Vec<_>>(),
            vec![
                "resize-surface",
                "set-client-sizing",
                "resize-surface",
                "set-client-sizing",
                "send"
            ]
        );
    }

    #[test]
    fn protocol_ten_proxy_fails_closed_without_sizing_queue() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let lease = TerminalSizingLease::new(
            &coordinator,
            SizingKey {
                socket_path: PathBuf::from("/tmp/cmux-sizing-missing-queue.sock"),
                surface_id: 26,
            },
            1,
            26,
        );
        let proxy = ControlTerminalControl {
            control: Arc::new(control.clone()),
            surface_id: 26,
            sizing: Some(lease),
            queue: None,
            ended: AtomicBool::new(false),
        };

        // A protocol-10+ proxy without its ordered queue must never fall
        // back to direct daemon writes. The defensive path closes the
        // transport instead.
        proxy.write(b"must-not-bypass-sizing");
        proxy.resize(120, 40);
        assert!(control.sends().is_empty());
        assert!(control.requests().is_empty());
        assert!(control.ended());
    }

    #[tokio::test]
    async fn raw_release_ends_only_control_socket_and_releases_sizing_lease() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-release.sock"),
            surface_id: 11,
        };
        let lease = TerminalSizingLease::new(&coordinator, key, 1, 11);
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        lease.join(Arc::clone(&control_handle), SizingGrid { cols: 80, rows: 24 });
        control.wait_for_requests(2).await;
        let queue = lease.queue();

        let proxy = ControlTerminalControl {
            control: control_handle,
            surface_id: 11,
            sizing: Some(lease),
            queue,
            ended: AtomicBool::new(false),
        };
        proxy.release();
        assert!(control.ended(), "release must close only the relay control socket");
        assert!(coordinator.targets.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn cancelled_open_guard_releases_raw_control_before_attachment_insert() {
        let control = SizingControl::new(12, &[]);
        let coordinator = TerminalSizing::new();
        let key = SizingKey {
            socket_path: PathBuf::from("/tmp/cmux-sizing-cancel.sock"),
            surface_id: 12,
        };
        let lease = TerminalSizingLease::new(&coordinator, key, 1, 12);
        let control_handle: Arc<dyn ControlHandle> = Arc::new(control.clone());
        lease.join(Arc::clone(&control_handle), SizingGrid { cols: 80, rows: 24 });
        control.wait_for_requests(1).await;
        let queue = lease.queue();
        let proxy: Arc<dyn PtyControl> = Arc::new(ControlTerminalControl {
            control: control_handle,
            surface_id: 12,
            sizing: Some(lease),
            queue,
            ended: AtomicBool::new(false),
        });
        let opened = Opened {
            generation: 1,
            gate: Arc::new(Mutex::new(())),
            created: false,
            surface: Some("12".to_owned()),
            control: proxy,
            post_open_resize: false,
            closing: Arc::new(AtomicBool::new(false)),
            start: None,
            cleanup_armed: AtomicBool::new(true),
        };
        drop(opened);
        assert!(control.ended(), "cancellation must close the raw control socket");
        assert!(coordinator.targets.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn protocol_five_to_nine_without_initial_size_sends_one_post_open_resize() {
        for protocol in 5..=9 {
            let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
            let control = SizingControl::new(protocol, &[]);
            let h = harness_with_control(
                Some(cmux),
                None,
                Some(PathBuf::from(format!("/tmp/cmux-sizing-v{protocol}.sock"))),
                Some(Arc::new(control.clone())),
            );
            h.open_at_version(
                PTY_OPERATIONAL_ERRORS_PROTOCOL_VERSION,
                "p1",
                "work",
                serde_json::json!({ "surface": "7" }),
                "supervised",
                h.owner.clone(),
            )
            .await;
            h.frame_as_at_version(
                PTY_OPERATIONAL_ERRORS_PROTOCOL_VERSION,
                serde_json::json!({
                    "version": 4,
                    "type": "pty_resize",
                    "ptyId": "p1",
                    "cols": 80,
                    "rows": 24,
                }),
                "supervised",
                h.owner.clone(),
            )
            .await;
            let requests = control.requests();
            let attach =
                requests.iter().find(|(cmd, _)| cmd == "attach-surface").expect("attach request");
            assert_eq!(attach.1["surface"], 7);
            assert!(attach.1.get("cols").is_none());
            assert_eq!(control.sends().len(), 1);
            assert_eq!(control.sends()[0].0, "resize-surface");
            assert_eq!(control.sends()[0].1["cols"], 80);
            assert_eq!(control.sends()[0].1["rows"], 24);
        }
    }

    #[tokio::test]
    async fn protocol_nine_with_initial_size_capability_uses_attach_dimensions_once() {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let control = SizingControl::new(9, &["attach-initial-size"]);
        let h = harness_with_control(
            Some(cmux),
            None,
            Some(PathBuf::from("/tmp/cmux-sizing-v9-cap.sock")),
            Some(Arc::new(control.clone())),
        );
        h.open("p1", "work", serde_json::json!({ "surface": "7" }), "supervised", h.owner.clone())
            .await;
        let requests = control.requests();
        let attach =
            requests.iter().find(|(cmd, _)| cmd == "attach-surface").expect("attach request");
        assert_eq!(attach.1["surface"], 7);
        assert_eq!(attach.1["cols"], 80);
        assert_eq!(attach.1["rows"], 24);
        assert!(control.sends().is_empty());
    }

    #[tokio::test]
    async fn raw_open_emits_before_a_slow_sizing_reply_and_converges_after_release() {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let control = SizingControl::new(12, &[]);
        control.block_sizing();
        let h = harness_with_control(
            Some(cmux),
            None,
            Some(PathBuf::from("/tmp/cmux-sizing-open-order.sock")),
            Some(Arc::new(control.clone())),
        );

        // A hung set-client-sizing/resize reply must not delay pty_opened.
        h.open("p1", "work", serde_json::json!({ "surface": "7" }), "supervised", h.owner.clone())
            .await;
        assert!(h.sent().iter().any(|frame| ty(frame) == "pty_opened"));
        control.wait_for_requests(3).await;

        control.release_sizing();
        control.wait_for_requests(4).await;
        let requests = control.requests();
        assert_eq!(requests[2].0, "resize-surface");
        assert_eq!(requests[3].0, "set-client-sizing");
    }

    #[tokio::test]
    async fn raw_detach_cancels_pending_sizing_without_a_stale_claim() {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let control = SizingControl::new(12, &[]);
        control.block_sizing();
        let h = harness_with_control(
            Some(cmux),
            None,
            Some(PathBuf::from("/tmp/cmux-sizing-detach-order.sock")),
            Some(Arc::new(control.clone())),
        );
        h.open("p1", "work", serde_json::json!({ "surface": "7" }), "supervised", h.owner.clone())
            .await;
        control.wait_for_requests(3).await;
        let sends_before_close = control.sends().len();
        h.frame(serde_json::json!({ "type": "pty_close", "ptyId": "p1" })).await;

        control.release_sizing();
        tokio::task::yield_now().await;
        let requests = control.requests();
        assert_eq!(
            requests.iter().filter(|(command, _)| command == "resize-surface").count(),
            1,
            "the blocked report may complete, but no new resize is allowed after leave"
        );
        assert!(!requests.iter().any(|(command, _)| command == "set-client-sizing"));
        assert_eq!(control.sends().len(), sends_before_close, "leave cancels pending wire work");
        assert!(control.ended(), "detaching the raw viewer must close its control socket");
    }

    #[tokio::test]
    async fn missing_surface_refuses_with_typed_terminal_gone() {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let h = harness_with_control(Some(cmux), None, None, Some(Arc::new(GoneControl)));
        h.open(
            "p1",
            "job-x",
            serde_json::json!({ "surface": "term_dead" }),
            "supervised",
            h.owner.clone(),
        )
        .await;
        let sent = h.sent();
        let error = sent.iter().find(|f| ty(f) == "pty_error").expect("pty_error frame");
        // The typed code is the contract (chatmux protocol RelayPtyErrorCode);
        // the message keeps the human wording the Node relay used.
        assert_eq!(error["code"], "terminal_gone");
        let decoded: crate::relay_wire::RelayPtyError =
            serde_json::from_value(error.clone()).expect("generated pty_error fixture");
        assert_eq!(decoded.code, RelayPtyErrorCode::TerminalGone);
        assert_eq!(error["message"], "requested terminal is no longer available");
        // A gone terminal must NOT degrade to a whole-session attach.
        assert!(!sent.iter().any(|f| ty(f) == "pty_opened"));
    }

    #[test]
    fn typed_pty_error_codes_use_the_generated_wire_names() {
        let harness = harness(None, None);
        let context = harness.context("supervised", harness.owner.clone());
        let cases = [
            (RelayPtyErrorCode::BadRequest, "bad_request"),
            (RelayPtyErrorCode::TrustRefused, "trust_refused"),
            (RelayPtyErrorCode::SessionLimit, "session_limit"),
            (RelayPtyErrorCode::TerminalGone, "terminal_gone"),
            (RelayPtyErrorCode::Failed, "failed"),
            (RelayPtyErrorCode::Overflow, "overflow"),
            (RelayPtyErrorCode::TrustRevoked, "trust_revoked"),
            (RelayPtyErrorCode::Busy, "busy"),
        ];
        for (code, expected) in cases {
            send_pty_error(&context, "p1", code, "test");
            assert_eq!(harness.sent().pop().expect("error frame")["code"], expected);
        }
    }

    #[test]
    fn pty_operational_errors_use_v7_codes_and_v6_safe_fallbacks() {
        let harness = harness(None, None);
        let old_context = harness.context_with_version(
            "supervised",
            harness.owner.clone(),
            crate::wire::RELAY_PROTOCOL_PTY_OPERATIONAL_ERRORS_VERSION - 1,
        );
        send_operational_pty_error(
            &old_context,
            "p1",
            RelayPtyErrorCode::Overflow,
            "typed overflow detail",
            "PTY output overflowed. Reattach to continue.",
        );
        let old_frame = harness.sent().pop().expect("legacy error frame");
        assert_eq!(old_frame["code"], "failed");
        assert_eq!(old_frame["message"], "PTY output overflowed. Reattach to continue.");

        let new_context = harness.context_with_version(
            "supervised",
            harness.owner.clone(),
            crate::wire::RELAY_PROTOCOL_PTY_OPERATIONAL_ERRORS_VERSION,
        );
        send_operational_pty_error(
            &new_context,
            "p1",
            RelayPtyErrorCode::Overflow,
            "typed overflow detail",
            "PTY output overflowed. Reattach to continue.",
        );
        let new_frame = harness.sent().pop().expect("typed error frame");
        assert_eq!(new_frame["code"], "overflow");
        assert_eq!(new_frame["message"], "typed overflow detail");
    }

    struct InvalidListControl {
        response: Option<Value>,
    }

    impl ControlHandle for InvalidListControl {
        fn request(
            &self,
            cmd: &str,
            _params: Value,
        ) -> std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send + '_>> {
            let response = match cmd {
                "identify" => Some(serde_json::json!({
                    "ok": true,
                    "data": { "protocol": CONTROL_MIN_PROTOCOL, "capabilities": [] },
                })),
                "list-workspaces" => self.response.clone(),
                _ => None,
            };
            Box::pin(async move { response })
        }
        fn send(&self, _cmd: &str, _params: Value) {}
        fn on_event(&self, _handler: EventHandler) {}
        fn on_close(&self, _handler: CloseHandler) {}
        fn pause(&self) {}
        fn resume(&self) {}
        fn end(&self) {}
    }

    async fn assert_invalid_list_is_failed(response: Option<Value>) {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let h = harness_with_control(
            Some(cmux),
            None,
            None,
            Some(Arc::new(InvalidListControl { response })),
        );
        h.open(
            "p1",
            "job-x",
            serde_json::json!({ "surface": "term_dead" }),
            "supervised",
            h.owner.clone(),
        )
        .await;
        let error = h.sent().into_iter().find(|f| ty(f) == "pty_error").unwrap();
        assert_eq!(error["code"], "failed");
        let message = error["message"].as_str().unwrap_or_default();
        assert!(!message.contains("list-workspaces"));
        assert!(!message.contains("response"));
    }

    #[tokio::test]
    async fn failed_list_workspaces_is_not_terminal_gone() {
        assert_invalid_list_is_failed(Some(serde_json::json!({ "ok": false }))).await;
    }

    #[tokio::test]
    async fn missing_list_workspaces_is_not_terminal_gone() {
        assert_invalid_list_is_failed(None).await;
    }

    #[tokio::test]
    async fn malformed_list_workspaces_is_not_terminal_gone() {
        assert_invalid_list_is_failed(Some(serde_json::json!({
            "ok": true,
            "data": { "workspaces": {} }
        })))
        .await;
    }

    #[tokio::test]
    async fn surface_list_globs_socket_dir_and_merges_shell_sessions() {
        let h = harness(
            None,
            Some(vec!["work.sock".to_owned(), "notes.sock".to_owned(), "junk".to_owned()]),
        );
        // A live shell session too.
        h.open("p1", "myshell", Value::Null, "supervised", h.owner.clone()).await;
        h.frame(serde_json::json!({ "type": "surface_list", "requestId": "r1" })).await;
        let result = h.sent().into_iter().find(|f| ty(f) == "surface_list_result").unwrap();
        let surfaces = result["surfaces"].as_array().unwrap();
        let ids: Vec<&str> = surfaces.iter().map(|s| s["id"].as_str().unwrap()).collect();
        assert!(ids.contains(&"work"));
        assert!(ids.contains(&"notes"));
        assert!(ids.contains(&"myshell"));
        assert!(!ids.contains(&"junk"));
    }

    #[tokio::test]
    async fn detach_all_releases_attachments_sessions_stay_reattachable() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        h.manager.detach_all();
        let before = h.sent().len();
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        assert_eq!(h.sent()[before]["created"], false); // same session survived
        assert_eq!(h.spawned().len(), 1);
    }

    #[test]
    fn pty_env_scrubs_secrets_but_keeps_a_real_term() {
        let home = TestDirectory::new("env");
        let mut base = env_map(&home.path);
        base.insert("OPENAI_API_KEY".to_owned(), "secret".to_owned());
        let env = pty_env(&base);
        assert!(!env.contains_key("OPENAI_API_KEY"));
        assert_eq!(env.get("PATH").map(String::as_str), Some("/usr/bin"));
        assert_eq!(env.get("TERM").map(String::as_str), Some("xterm-256color"));
    }

    #[test]
    fn scoped_cwd_accepts_absolute_and_home_relative_paths() {
        let root = TestDirectory::new("cwd");
        let nested = root.path.join("nested");
        std::fs::create_dir_all(&nested).unwrap();
        let home = root.path.to_string_lossy().into_owned();
        assert_eq!(
            scoped_cwd(Some(&home), Path::new(&home), None, None).unwrap(),
            std::fs::canonicalize(&root.path).unwrap()
        );
        assert_eq!(
            scoped_cwd(Some("~/nested"), Path::new(&home), None, None).unwrap(),
            std::fs::canonicalize(nested).unwrap()
        );
    }

    #[test]
    fn scoped_cwd_rejects_relative_requests_and_defaults_null_or_empty() {
        let root = TestDirectory::new("cwd-default");
        assert_eq!(
            scoped_cwd(Some("relative"), &root.path, None, None).unwrap_err(),
            "cwd must be absolute or home-relative"
        );
        assert_eq!(
            scoped_cwd(None, &root.path, None, None).unwrap(),
            std::fs::canonicalize(&root.path).unwrap()
        );
        assert_eq!(
            scoped_cwd(Some(""), &root.path, None, None).unwrap(),
            std::fs::canonicalize(&root.path).unwrap()
        );
    }

    #[test]
    fn malformed_process_info_cwd_is_cleaned_to_empty_picker_component() {
        assert_eq!(shorten_cwd("", "/home/u"), "");
        assert_eq!(shorten_cwd("/home/u/project", "/home/u"), "~/project");
        let malformed = serde_json::json!({"cwd": {"path": "/tmp"}});
        assert_eq!(
            shorten_cwd(
                malformed.get("cwd").and_then(Value::as_str).unwrap_or_default(),
                "/home/u"
            ),
            ""
        );
    }

    #[test]
    fn go_live_replay_stays_ahead_of_concurrent_output_and_exit() {
        let stream = TestArc::new(TerminalStream::new());
        stream.push_output(Bytes::from_static(b"buffered"));

        let seen = TestArc::new(StdMutex::new(Vec::<String>::new()));
        let invocations = TestArc::new(AtomicUsize::new(0));
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));

        let callback_seen = TestArc::clone(&seen);
        let callback_invocations = TestArc::clone(&invocations);
        let callback_entered = TestArc::clone(&entered);
        let callback_release = TestArc::clone(&release);
        let on_data: TestArc<dyn Fn(Bytes) + Send + Sync> = TestArc::new(move |chunk| {
            let value = String::from_utf8_lossy(&chunk).into_owned();
            let invocation = callback_invocations.fetch_add(1, AtomicOrdering::Relaxed) + 1;
            if invocation == 1 {
                callback_entered.wait();
                callback_release.wait();
            }
            callback_seen.lock().expect("seen lock").push(value);
        });
        let callback_seen = TestArc::clone(&seen);
        let on_exit: TestArc<dyn Fn(i64) + Send + Sync> = TestArc::new(move |code| {
            callback_seen.lock().expect("seen lock").push(format!("exit:{code}"));
        });

        let start_stream = TestArc::clone(&stream);
        let join = thread::spawn(move || start_stream.go_live(on_data, on_exit));

        entered.wait();
        stream.push_output(Bytes::from_static(b"live"));
        stream.finish_exit(11);
        release.wait();
        join.join().expect("go_live thread");

        assert_eq!(
            *seen.lock().expect("seen lock"),
            vec!["buffered".to_owned(), "live".to_owned(), "exit:11".to_owned()]
        );
    }

    #[test]
    fn backlog_overflow_ends_after_accepted_bytes_and_marks_overflow() {
        let stream = TerminalStream::new();
        stream.push_output(Bytes::from(vec![b'x'; RAW_ATTACH_BACKLOG_CAP]));
        stream.push_output(Bytes::from_static(b"late"));
        assert!(stream.overflowed());

        let seen = Arc::new(Mutex::new(Vec::new()));
        let data_seen = Arc::clone(&seen);
        let exit_seen = Arc::clone(&seen);
        stream.go_live(
            Arc::new(move |chunk| data_seen.lock().unwrap().push(chunk.len())),
            Arc::new(move |code| exit_seen.lock().unwrap().push(code as usize)),
        );
        assert_eq!(*seen.lock().unwrap(), vec![RAW_ATTACH_BACKLOG_CAP, 1]);
    }

    #[test]
    fn backlog_overflow_uses_contract_pty_error_code() {
        let harness = harness(None, None);
        let context = harness.context("supervised", harness.owner.clone());
        send_pty_error(
            &context,
            "p1",
            operational_pty_error_code(&context, RelayPtyErrorCode::Overflow),
            "terminal output overflowed; reattach to continue receiving output",
        );
        let frame = harness.sent().pop().unwrap();
        assert_eq!(frame["type"], "pty_error");
        assert_eq!(frame["code"], "overflow");
        let decoded: crate::relay_wire::RelayPtyError =
            serde_json::from_value(frame).expect("contract-valid pty_error frame");
        assert_eq!(decoded.code, RelayPtyErrorCode::Overflow);
    }

    #[test]
    fn operational_pty_error_downgrades_for_older_workers() {
        let harness = harness(None, None);
        let context = harness.context_at_version(6, "supervised", harness.owner.clone());
        send_pty_error(
            &context,
            "p1",
            operational_pty_error_code(&context, RelayPtyErrorCode::Overflow),
            "pty output backlog overflowed; reattach to continue receiving output",
        );
        let frame = harness.sent().pop().unwrap();
        assert_eq!(frame["code"], "failed");
        let decoded: crate::relay_wire::RelayPtyError =
            serde_json::from_value(frame).expect("contract-valid downgraded pty_error frame");
        assert_eq!(decoded.code, RelayPtyErrorCode::Failed);
    }
}
