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

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;

use crate::actions::{expand_path, scrubbed_env, validate_request_path};
use crate::control::ControlHandle;
use crate::relay_wire::RelayPtyErrorCode;
use crate::trust::Trust;
use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use bytes::Bytes;
use serde_json::{Value, json};

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
/// Inner terminals listed per session (surface_list stays bounded).
const MAX_ENUM_TERMINALS: usize = 8;
const MAX_ALLOWED_ROOTS: usize = 32;
const MAX_ALLOWED_ROOT_BYTES: usize = 16 * 1024;
const MAX_ENUM_SURFACES: usize = 8;
const RAW_ATTACH_BACKLOG_CAP: usize = 1024 * 1024;
const PTY_INPUT_B64_CAP: usize = 4 * 1024 * 1024;

/// Random lowercase-hex identity for transports and tunnel attachments.
///
/// Identity generation is security-sensitive. Callers must reject the
/// operation when the operating system cannot provide entropy instead of
/// continuing with a predictable identifier.
pub fn random_hex(bytes: usize) -> Result<String, getrandom::Error> {
    let mut buffer = vec![0_u8; bytes];
    getrandom::fill(&mut buffer)?;
    let mut out = String::with_capacity(bytes * 2);
    for byte in buffer {
        out.push_str(&format!("{byte:02x}"));
    }
    Ok(out)
}

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

pub struct SpawnSpec {
    pub file: String,
    pub args: Vec<String>,
    pub cols: u16,
    pub rows: u16,
    pub cwd: PathBuf,
    pub env: HashMap<String, String>,
    pub cancellation: CancellationToken,
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

/// Opaque capacity owned by one in-flight PTY open.
///
/// `PtyDeps` implementations receive this value and must keep it alive until
/// all blocking setup for the open has returned. Cloning the value is safe,
/// and dropping every clone releases one slot. The constructor is private so
/// callers cannot mint capacity outside `PtyManager` admission.
#[derive(Clone)]
pub struct OpenPermit(Arc<OwnedSemaphorePermit>);

impl OpenPermit {
    pub(crate) fn new(permit: OwnedSemaphorePermit) -> Self {
        Self(Arc::new(permit))
    }
}

/// Start blocking PTY setup without releasing its open capacity when the
/// async owner is cancelled.
pub(crate) fn spawn_blocking_with_open_permit<T, F>(
    permit: OpenPermit,
    operation: F,
) -> tokio::task::JoinHandle<T>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        operation()
    })
}

#[async_trait]
pub trait PtyDeps: Send + Sync {
    /// Start a PTY while observing the lifetime of its open operation. An
    /// implementation must reclaim any process or descriptor it creates when
    /// the token is cancelled before ownership is returned.
    async fn spawn_pty(
        &self,
        spec: SpawnSpec,
        cancellation: CancellationToken,
        permit: OpenPermit,
    ) -> PtyHandle;
    async fn resolve_cmux_tui(&self, cancellation: CancellationToken) -> Option<CmuxTui>;
    async fn ensure_daemon(
        &self,
        cmux_tui: &CmuxTui,
        session: &str,
        socket_dir: &Path,
        cwd: &Path,
        env: &HashMap<String, String>,
        cancellation: CancellationToken,
    ) -> Result<EnsureDaemon, String>;
    async fn connect_control(
        &self,
        socket_path: &Path,
        cancellation: CancellationToken,
    ) -> Result<Arc<dyn ControlHandle>, String>;
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
    pub trust: String,
    pub local_roots: Option<Vec<String>>,
    pub owner_user_id: Option<String>,
    /// Identity of the transport this frame arrived on. The PtyManager is
    /// shared between the relay WebSocket and the managed tunnel listener;
    /// an attachment may only be written to, resized, flow-controlled, or
    /// closed by the transport that opened it, and a dropped transport
    /// detaches only its own attachments. `None` preserves the legacy
    /// owns-everything behavior for callers that own the whole manager.
    pub transport_id: Option<String>,
    /// Raised when the transport that requested this work disconnects.
    pub cancellation: CancellationToken,
    /// Structured transport class. IDs are opaque and must not be classified
    /// by string prefixes at a security boundary.
    pub transport_kind: TransportKind,
    /// Generation of the managed tunnel authority that admitted this frame.
    /// `None` is retained for legacy whole-manager and relay-socket callers.
    pub auth_generation: Option<u64>,
}

#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
pub enum TransportKind {
    /// The legacy whole-manager caller, which owns all non-tunnel state.
    #[default]
    Legacy,
    /// The authenticated relay WebSocket.
    Relay,
    /// The managed-sandbox loopback tunnel.
    Tunnel,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct TransportOwner {
    id: Option<String>,
    kind: TransportKind,
}

impl TransportOwner {
    fn from_context(context: &FrameContext) -> Self {
        Self { id: context.transport_id.clone(), kind: context.transport_kind }
    }
}

#[derive(Clone)]
struct AuthSnapshot {
    trust: String,
    local_roots: Option<Vec<String>>,
    owner_user_id: Option<String>,
    send: Arc<dyn Fn(Value) + Send + Sync>,
    buffered_amount: Arc<dyn Fn() -> u64 + Send + Sync>,
    auth_generation: Option<u64>,
    transport_kind: TransportKind,
}

impl AuthSnapshot {
    fn from_context(context: &FrameContext) -> Self {
        Self {
            trust: context.trust.clone(),
            local_roots: context.local_roots.clone(),
            owner_user_id: context.owner_user_id.clone(),
            send: Arc::clone(&context.send),
            buffered_amount: Arc::clone(&context.buffered_amount),
            auth_generation: context.auth_generation,
            transport_kind: context.transport_kind,
        }
    }
}

fn auth_snapshot_matches(left: &AuthSnapshot, right: &AuthSnapshot) -> bool {
    left.trust == right.trust
        && left.local_roots == right.local_roots
        && left.owner_user_id == right.owner_user_id
        && left.auth_generation == right.auth_generation
        && left.transport_kind == right.transport_kind
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

/// A per-attachment output sink into the framing path.
struct ViewerSink {
    id: u64,
    on_data: Arc<dyn Fn(Bytes) + Send + Sync>,
    on_exit: Arc<dyn Fn(i64) + Send + Sync>,
    /// Serializes this viewer's live and replay callbacks without blocking
    /// other viewers on a session-wide lock.
    delivery_lock: Arc<Mutex<()>>,
}

/// A fallback $SHELL session: one PTY, a bounded ring, and a viewer set that
/// fans output out to every attachment (multi-viewer, tmux-style).
struct ShellSession {
    control: Arc<dyn PtyControl>,
    /// Existing-session opens that have selected this session but have not
    /// published their viewer yet. Cancellation cleanup must not kill the
    /// session while one of these opens can still attach.
    pending_viewers: AtomicUsize,
    /// Serializes pause ownership transitions before touching the shared PTY.
    flow_lock: Mutex<()>,
    /// Serializes output delivery with paused-viewer replay.
    dispatch_lock: Mutex<()>,
    inner: Mutex<ShellInner>,
    banner: Option<Vec<u8>>,
}

struct ShellInner {
    ring: VecDeque<Bytes>,
    ring_size: usize,
    alive: bool,
    viewers: Vec<ViewerSink>,
    /// Viewer ids that currently own a pause on the shared PTY.
    paused_viewers: HashSet<u64>,
    /// Bounded output accumulated for paused or resuming viewers.
    paused_backlog: HashMap<u64, PausedBacklog>,
    /// Viewers whose paused output is being replayed in order.
    draining_viewers: HashSet<u64>,
}

#[derive(Default)]
struct PausedBacklog {
    chunks: VecDeque<Bytes>,
    bytes: usize,
}

#[derive(Clone)]
struct Attachment {
    closing: Arc<AtomicBool>,
    /// Number of control operations admitted before retirement. Admission
    /// uses a closing double-check so revocation cannot race a new operation.
    active_operations: Arc<AtomicUsize>,
    /// Serializes operations for this attachment only. The relay state lock
    /// must never be held while a PTY control method runs.
    operation_gate: Arc<Mutex<()>>,
    /// Serializes open success publication with attachment retirement. This
    /// is separate because start callbacks can emit output and re-enter the
    /// operation gate.
    publication_gate: Arc<Mutex<()>>,
    /// Even values admit output publication. Revocation flips the low bit,
    /// giving emitters an atomic linearization point without waiting on the
    /// transport callback.
    publication_state: Arc<AtomicU64>,
    /// Releases this attachment (detach a viewer, close a control stream,
    /// kill a viewer PTY) — never kills a shared session.
    control: Arc<dyn PtyControl>,
    actor_id: String,
    /// Typed transport that opened this attachment.
    owner: TransportOwner,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct OpeningOwner {
    owner: TransportOwner,
    /// Unique for the lifetime of an open attempt. A transport may reuse a
    /// pty id after a timed-out attempt has been removed from reservations;
    /// this token keeps the late task from touching the replacement.
    attempt_id: u64,
}

#[derive(Default)]
struct OpeningState {
    reservations: HashMap<String, OpeningOwner>,
    /// Every open attempt is registered before admission can await a
    /// provider. Authority replacement can therefore cancel an attempt even
    /// when it has not reached the capacity reservation yet.
    active_openings: HashMap<String, (OpeningOwner, OpenCancellation)>,
    /// Cancellation capability for each live reservation. The owner key
    /// keeps a late timeout from cancelling a replacement that reused the
    /// same pty id.
    cancellations: HashMap<OpeningOwner, OpenCancellation>,
    /// The owner is part of the cancellation key. A late drop from an old
    /// reservation cannot clear a marker for a newer reservation of the same
    /// pty id.
    cancelled: HashMap<String, OpeningOwner>,
}

struct Inner {
    deps: Arc<dyn PtyDeps>,
    home: PathBuf,
    env: HashMap<String, String>,
    max_ptys: usize,
    scrollback_limit: usize,
    output_cap: u64,
    attachments: Mutex<HashMap<String, Attachment>>,
    /// Reservations and cancellation markers share one lock so close and
    /// open cannot observe a gap between the two states.
    opening_state: Mutex<OpeningState>,
    shell_sessions: Mutex<HashMap<String, Arc<ShellSession>>>,
    shell_starting: Mutex<HashMap<String, Arc<Notify>>>,
    /// Authentication is scoped to the transport that owns an attachment.
    /// A single manager serves the relay socket and managed tunnel sockets;
    /// one global snapshot would let the last frame on either transport
    /// authorize asynchronous output for every other attachment.
    transport_auth: Mutex<HashMap<TransportOwner, AuthSnapshot>>,
    /// Serializes authority replacement. The lock spans the short map
    /// transition and the detached-attachment scan, but never platform I/O.
    /// Without this separate lock, two concurrent refreshes could each
    /// observe the same old snapshot and publish in reverse order.
    transport_auth_updates: Mutex<()>,
    /// Serializes short authority and attachment state transitions. It is
    /// never held while a PTY control method, callback, or provider await runs.
    tunnel_state: Mutex<()>,
    /// Monotonic floor for managed tunnel authority generations. It remains
    /// effective while a stale open is still unwinding after revocation.
    tunnel_authority_generation: AtomicU64,
    /// Monotonic identity for in-flight open attempts. Zero is reserved as
    /// the exhausted state so a wrapped token is never reused.
    next_open_attempt: AtomicU64,
    /// Bounds provider/PTY opens, including opens that have timed out while
    /// their provider task is still unwinding. A permit is owned by the open
    /// task and is released only when that task has returned, so a hung
    /// provider can consume only the finite terminal budget, never an
    /// unbounded number of reservations or tasks.
    open_slots: Arc<Semaphore>,
}

struct ShellStartReservation {
    inner: Arc<Inner>,
    session: String,
    notify: Arc<Notify>,
    active: bool,
}

fn remove_cached_shell_if_same_without_viewers(
    inner: &Inner,
    session: &str,
    target: &Arc<ShellSession>,
) -> bool {
    // Serialize with viewer start. A concurrent opener may have cloned this
    // session but cannot publish its viewer while this dispatch lock is held.
    let _dispatch = target.dispatch_lock.lock().expect("shell dispatch lock");
    if !target.inner.lock().expect("shell inner lock").viewers.is_empty()
        || target.pending_viewers.load(Ordering::Acquire) != 0
    {
        return false;
    }
    let mut shells = inner.shell_sessions.lock().expect("shell lock");
    if shells.get(session).is_some_and(|cached| Arc::ptr_eq(cached, target)) {
        shells.remove(session);
        true
    } else {
        false
    }
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
    owner: OpeningOwner,
    active: bool,
}

struct ActiveOpening {
    inner: Arc<Inner>,
    id: String,
    owner: OpeningOwner,
    active: bool,
}

impl ActiveOpening {
    fn disarm(&mut self) {
        self.active = false;
    }
}

impl Drop for ActiveOpening {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        let mut state = self.inner.opening_state.lock().expect("opening state lock");
        if state.active_openings.get(&self.id).is_some_and(|(owner, _)| owner == &self.owner) {
            state.active_openings.remove(&self.id);
        }
        // A close can remove this pre-reservation attempt and leave an
        // owner-specific tombstone so a late task cannot claim a replacement
        // with the same pty id. The tombstone is needed only until this task
        // has unwound. Match the full owner, including attempt_id, so an old
        // task cannot clear a newer attempt's fence.
        if state.cancelled.get(&self.id) == Some(&self.owner) {
            state.cancelled.remove(&self.id);
        }
    }
}
impl Drop for OpeningReservation {
    fn drop(&mut self) {
        if self.active {
            let mut state = self.inner.opening_state.lock().expect("opening state lock");
            if state.reservations.get(&self.id) == Some(&self.owner) {
                state.reservations.remove(&self.id);
            }
            state.cancellations.remove(&self.owner);
            if state.cancelled.get(&self.id) == Some(&self.owner) {
                state.cancelled.remove(&self.id);
            }
        }
    }
}

pub struct PtyManager {
    inner: Arc<Inner>,
}

/// Cancellation and identity for one terminal-open attempt. The identity is
/// allocated by the manager before a task is spawned, so timeout cleanup can
/// name the exact reservation even when the task is still unwinding.
#[derive(Clone)]
pub(crate) struct OpenCancellation {
    token: CancellationToken,
    attempt_id: u64,
}

impl OpenCancellation {
    pub(crate) fn cancel(&self) {
        self.token.cancel();
    }

    fn is_cancelled(&self) -> bool {
        self.token.is_cancelled()
    }

    fn token(&self) -> CancellationToken {
        self.token.clone()
    }

    fn attempt_id(&self) -> u64 {
        self.attempt_id
    }
}

async fn request_control_with_cancellation(
    control: &Arc<dyn ControlHandle>,
    command: &str,
    params: Value,
    cancellation: &OpenCancellation,
) -> Option<Value> {
    tokio::select! {
        biased;
        _ = cancellation.token.cancelled() => None,
        response = control.request(command, params) => response,
    }
}

/// Attachments whose ownership has already been removed from the manager.
/// The controls are retired after the caller releases any outer trust lock,
/// so a slow platform kill cannot block authorization readers or a later
/// reconciliation. Dropping this value still retires every control.
pub struct RetiredAttachments {
    inner: Arc<Inner>,
    attachments: Vec<Attachment>,
}

impl RetiredAttachments {
    /// Run the potentially blocking control cleanup after the state boundary.
    pub fn retire(mut self) {
        let attachments = std::mem::take(&mut self.attachments);
        for attachment in attachments {
            self.inner.retire_attachment(attachment);
        }
    }
}

impl Drop for RetiredAttachments {
    fn drop(&mut self) {
        let attachments = std::mem::take(&mut self.attachments);
        for attachment in attachments {
            self.inner.retire_attachment(attachment);
        }
    }
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
                opening_state: Mutex::new(OpeningState::default()),
                shell_sessions: Mutex::new(HashMap::new()),
                shell_starting: Mutex::new(HashMap::new()),
                transport_auth: Mutex::new(HashMap::new()),
                transport_auth_updates: Mutex::new(()),
                tunnel_state: Mutex::new(()),
                tunnel_authority_generation: AtomicU64::new(0),
                next_open_attempt: AtomicU64::new(1),
                open_slots: Arc::new(Semaphore::new(MAX_PTYS)),
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
                opening_state: Mutex::new(OpeningState::default()),
                shell_sessions: Mutex::new(HashMap::new()),
                shell_starting: Mutex::new(HashMap::new()),
                transport_auth: Mutex::new(HashMap::new()),
                transport_auth_updates: Mutex::new(()),
                tunnel_state: Mutex::new(()),
                tunnel_authority_generation: AtomicU64::new(0),
                next_open_attempt: AtomicU64::new(1),
                open_slots: Arc::new(Semaphore::new(max_ptys)),
            }),
        }
    }

    /// Handle one Worker -> relay PTY frame.
    pub async fn handle_frame(&self, frame: &Value, context: &FrameContext) {
        self.handle_frame_with_open_cancellation(frame, context, None).await;
    }

    /// Handle a frame whose `pty_open` is owned by a connection-level
    /// cancellation token. The token is created before the task is spawned,
    /// so a deadline or disconnect can fence an open even when its task has
    /// not received its first poll yet.
    pub(crate) async fn handle_frame_with_open_cancellation(
        &self,
        frame: &Value,
        context: &FrameContext,
        cancellation: Option<OpenCancellation>,
    ) {
        if cancellation.as_ref().is_some_and(OpenCancellation::is_cancelled) {
            return;
        }
        let frame_type = frame.get("type").and_then(Value::as_str).unwrap_or_default();
        // Keep the cache result for operations that enumerate state, but do
        // not turn a failed cache admission into a silent drop for terminal
        // verbs. `pty_open` validates its trust before allocation, while the
        // existing-attachment verbs must reach their authorization path so a
        // stale or malformed context emits `trust_revoked` and retires the
        // attachment. The cache never stores an invalid snapshot, so this
        // does not let an untrusted frame acquire authority.
        let authority_current = self.inner.cache_transport_auth(context);
        match frame_type {
            "pty_open" => {
                let Some(cancellation) =
                    cancellation.or_else(|| self.new_open_cancellation_for_context(context))
                else {
                    let pty_id = frame.get("ptyId").and_then(Value::as_str).unwrap_or_default();
                    if !pty_id.is_empty() {
                        send_pty_error(context, pty_id, "session_limit", "terminal limit reached");
                    }
                    return;
                };
                self.inner.clone().open(frame, context, cancellation).await;
            }
            "pty_input" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                if !self.inner.transport_owns(pty_id, context) {
                    return;
                }
                let Some(data) = frame
                    .get("dataB64")
                    .and_then(Value::as_str)
                    .filter(|value| value.len() <= PTY_INPUT_B64_CAP)
                    .and_then(|b64| BASE64.decode(b64).ok())
                else {
                    return;
                };
                self.inner.with_authorized(pty_id, context, "input", |attachment| {
                    attachment.control.write(&data);
                });
            }
            "pty_resize" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                if !self.inner.transport_owns(pty_id, context) {
                    return;
                }
                let (Some(cols), Some(rows)) =
                    (clamp_dim(frame.get("cols")), clamp_dim(frame.get("rows")))
                else {
                    return;
                };
                self.inner.with_authorized(pty_id, context, "resize", |attachment| {
                    attachment.control.resize(cols, rows);
                });
            }
            "pty_flow" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                if !self.inner.transport_owns(pty_id, context) {
                    return;
                }
                let pause = frame.get("pause").and_then(Value::as_bool).unwrap_or(false);
                self.inner.with_authorized(pty_id, context, "flow", |attachment| {
                    if pause {
                        attachment.control.pause();
                    } else {
                        attachment.control.resume();
                    }
                });
            }
            "pty_close" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                if !self.inner.transport_owns(pty_id, context) {
                    return;
                }
                self.inner.close_authorized(pty_id, context);
            }
            "surface_list" if authority_current => {
                self.inner.clone().list_surfaces(frame, context).await
            }
            _ => {}
        }
    }

    /// Publish the authoritative snapshot for one live transport. This is
    /// called only after the relay has reconciled trust, roots, and owner.
    /// Network frames never get to register or replace an existing snapshot
    /// implicitly. Callers must publish this snapshot before dispatching the
    /// first frame for an identified transport.
    pub fn update_transport_auth(&self, context: &FrameContext) {
        debug_assert!(context.transport_id.is_some(), "transport refresh needs an id");
        if context.transport_id.is_none()
            || context.cancellation.is_cancelled()
            || Trust::parse(&context.trust).is_none()
        {
            return;
        }
        let owner = TransportOwner::from_context(context);
        let snapshot = AuthSnapshot::from_context(context);
        // Serialize replacement. A changed snapshot is removed before the
        // new one is published, so stale frames cannot re-register it during
        // attachment cleanup.
        let _update = self.inner.transport_auth_updates.lock().expect("transport auth update lock");
        let changed = {
            let _state = self.inner.tunnel_state.lock().expect("tunnel state lock");
            if context.cancellation.is_cancelled()
                || !self.inner.tunnel_authority_generation_current(context)
            {
                return;
            }
            let transport_auth = self.inner.transport_auth.lock().expect("transport auth lock");
            let changed = transport_auth
                .get(&owner)
                .is_some_and(|current| !auth_snapshot_matches(current, &snapshot));
            changed
        };
        // `detach_matching` acquires `transport_auth_updates` itself. We
        // already hold that lock here, so call the locked variant to avoid a
        // non-reentrant mutex deadlock when a transport refresh changes its
        // authority. Retire controls after publishing the replacement and
        // releasing the update lock, so platform cleanup cannot block a
        // concurrent authority refresh.
        let retired = if changed {
            Some(self.detach_matching_locked(|candidate| candidate == &owner))
        } else {
            None
        };
        {
            let _state = self.inner.tunnel_state.lock().expect("tunnel state lock");
            if !context.cancellation.is_cancelled()
                && self.inner.tunnel_authority_generation_current(context)
            {
                self.inner
                    .transport_auth
                    .lock()
                    .expect("transport auth lock")
                    .insert(owner.clone(), snapshot);
            }
        }
        drop(_update);
        if let Some(retired) = retired {
            retired.retire();
        }
    }

    /// Advance the managed tunnel authority floor before publishing the
    /// matching snapshot. A stale in-flight frame cannot recreate a removed
    /// transport entry after this point.
    pub fn set_tunnel_authority_generation(&self, generation: u64) {
        let _state = self.inner.tunnel_state.lock().expect("tunnel state lock");
        let mut current = self.inner.tunnel_authority_generation.load(Ordering::Acquire);
        while generation > current {
            match self.inner.tunnel_authority_generation.compare_exchange_weak(
                current,
                generation,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(observed) => current = observed,
            }
        }
    }

    /// True while `pty_id` has a live attachment. The tunnel listener uses
    /// this after a pty_error reply to tell a fatal refusal (attachment gone,
    /// connection ends) from a non-fatal one (oversized input, stream lives).
    pub fn has_attachment(&self, pty_id: &str) -> bool {
        self.inner.attachments.lock().expect("attach lock").contains_key(pty_id)
    }

    /// Live attachment count (viewers, not sessions). Diagnostics and tests.
    pub fn attachment_count(&self) -> usize {
        self.inner.attachments.lock().expect("attach lock").len()
    }

    /// The relay socket dropped: release every attachment (sessions live on).
    /// Callers that own the whole manager only; a per-connection transport
    /// must use `detach_transport` so it cannot detach attachments the
    /// managed tunnel listener (or another socket) owns.
    pub fn detach_all(&self) {
        self.detach_matching(|_| true).retire();
    }

    /// One legacy relay transport dropped: release only its attachments and
    /// cancel only its in-flight opens. Identified tunnel transports must use
    /// `detach_transport_kind`, because transport IDs are scoped by kind.
    pub fn detach_transport(&self, transport_id: &str) {
        self.detach_transport_kind(transport_id, TransportKind::Relay);
    }

    /// One typed transport dropped. This avoids treating an opaque relay ID
    /// as a namespace discriminator.
    pub fn detach_transport_kind(&self, transport_id: &str, kind: TransportKind) {
        let owner = TransportOwner { id: Some(transport_id.to_owned()), kind };
        let target_owner = owner;
        // Identified transports must be registered explicitly. Removing the
        // active snapshot is therefore sufficient to reject a queued frame,
        // including one from a connection that disconnected before its first
        // frame. A reconnect gets a fresh random identity.
        self.detach_matching(move |candidate| candidate == &target_owner).retire();
    }

    /// Release all managed tunnel attachments. The relay connection clears
    /// tunnel authority on disconnect or trust renegotiation; existing tunnel
    /// viewers must lose their attachments at the same boundary.
    pub fn detach_tunnel_transports(&self) {
        self.detach_tunnel_transports_deferred().retire();
    }

    /// Remove managed tunnel ownership while the caller still holds its
    /// authority boundary, but defer control kills until `retire` is called.
    /// This lets session reconciliation release the global trust lock before
    /// touching platform PTY state.
    pub fn detach_tunnel_transports_deferred(&self) -> RetiredAttachments {
        self.detach_matching(|owner| owner.kind == TransportKind::Tunnel)
    }

    /// Cancel one opening reservation at the timeout boundary. The capability
    /// carries both the cancellation signal and the unique attempt identity.
    /// Its owner-specific tombstone rejects a late result without retaining
    /// the reservation in the capacity count. Tombstones are bounded by
    /// `open_slots`, because each one belongs to an outstanding open permit.
    pub(crate) fn cancel_open(
        &self,
        pty_id: &str,
        context: &FrameContext,
        cancellation: &OpenCancellation,
    ) {
        cancellation.cancel();
        let owner = OpeningOwner {
            owner: TransportOwner::from_context(context),
            attempt_id: cancellation.attempt_id(),
        };
        let _state = self.inner.tunnel_state.lock().expect("tunnel state lock");
        let mut opening = self.inner.opening_state.lock().expect("opening state lock");
        if opening.reservations.get(pty_id) == Some(&owner) {
            opening.reservations.remove(pty_id);
            opening.cancellations.remove(&owner);
            opening.cancelled.insert(pty_id.to_owned(), owner);
        }
    }

    fn detach_matching(&self, owns: impl Fn(&TransportOwner) -> bool) -> RetiredAttachments {
        let _update = self.inner.transport_auth_updates.lock().expect("transport auth update lock");
        self.detach_matching_locked(owns)
    }

    /// Remove one ownership set while the authority-update lock is held.
    /// Callers must retire the returned controls after the state boundary.
    fn detach_matching_locked(&self, owns: impl Fn(&TransportOwner) -> bool) -> RetiredAttachments {
        // Revoke the transport snapshot and opening reservations at one
        // authority boundary. Do not wait for an attachment operation while
        // holding the state lock: output/control callbacks take the gate
        // before that lock, so waiting here would deadlock the relay.
        let candidates = {
            let _state = self.inner.tunnel_state.lock().expect("tunnel state lock");
            let mut transport_auth = self.inner.transport_auth.lock().expect("transport auth lock");
            // Every identified opening and attachment is admitted through an
            // active auth snapshot. Removing that snapshot is the disconnect
            // fence. No historical tombstone is stored.
            transport_auth.retain(|owner, _| !owns(owner));
            let mut opening = self.inner.opening_state.lock().expect("opening state lock");
            let cancelled: Vec<(String, OpeningOwner)> = opening
                .reservations
                .iter()
                .filter(|(_, owner)| owns(&owner.owner))
                .map(|(id, owner)| (id.clone(), owner.clone()))
                .collect();
            for (id, owner) in cancelled {
                opening.reservations.remove(&id);
                if let Some(cancellation) = opening.cancellations.remove(&owner) {
                    cancellation.cancel();
                }
                opening.cancelled.insert(id, owner);
            }
            let active: Vec<(String, OpeningOwner, OpenCancellation)> = opening
                .active_openings
                .iter()
                .filter(|(_, (owner, _))| owns(&owner.owner))
                .map(|(id, (owner, cancellation))| {
                    (id.clone(), owner.clone(), cancellation.clone())
                })
                .collect();
            for (id, _owner, cancellation) in active {
                opening.active_openings.remove(&id);
                cancellation.cancel();
            }

            let candidates = self
                .inner
                .attachments
                .lock()
                .expect("attach lock")
                .iter()
                .filter(|(_, attachment)| owns(&attachment.owner))
                .map(|(id, attachment)| (id.clone(), attachment.clone()))
                .collect::<Vec<_>>();
            candidates
        };

        // Removal is linearized with publication by the same per-attachment
        // gate. If an output callback already owns the gate, it completes
        // before removal. If removal wins, the callback observes that its
        // identity is gone and cannot publish after revocation.
        let mut retired = Vec::new();
        for (id, candidate) in candidates {
            let publication =
                candidate.publication_gate.lock().expect("attachment publication lock");
            let operation = candidate.operation_gate.lock().expect("attachment operation lock");
            Self::revoke_publication(&candidate);
            candidate.closing.store(true, Ordering::Release);
            let removed = {
                let _state = self.inner.tunnel_state.lock().expect("tunnel state lock");
                let mut attachments = self.inner.attachments.lock().expect("attach lock");
                let same = attachments.get(&id).is_some_and(|current| {
                    Arc::ptr_eq(&current.operation_gate, &candidate.operation_gate)
                });
                if same { attachments.remove(&id) } else { None }
            };
            if let Some(removed) = removed {
                retired.push(removed);
            }
            drop(operation);
            drop(publication);
        }
        RetiredAttachments { inner: Arc::clone(&self.inner), attachments: retired }
    }

    /// Allocate the capability that identifies one in-flight terminal open.
    /// IDs are never reused. Exhaustion is a fail-closed terminal limit.
    pub(crate) fn new_open_cancellation(&self) -> Option<OpenCancellation> {
        self.allocate_open_cancellation(CancellationToken::new())
    }

    /// Allocate an open capability that is also cancelled when the owning
    /// transport disconnects. A child token keeps the local timeout/revocation
    /// cancellation independent while inheriting the transport lifetime.
    pub(crate) fn new_open_cancellation_for_context(
        &self,
        context: &FrameContext,
    ) -> Option<OpenCancellation> {
        self.new_open_cancellation_with_parent(&context.cancellation)
    }

    /// Allocate an open capability whose lifetime is bounded by `parent`.
    /// The caller can still cancel this capability independently.
    pub(crate) fn new_open_cancellation_with_parent(
        &self,
        parent: &CancellationToken,
    ) -> Option<OpenCancellation> {
        self.allocate_open_cancellation(parent.child_token())
    }

    fn allocate_open_cancellation(&self, token: CancellationToken) -> Option<OpenCancellation> {
        let mut current = self.inner.next_open_attempt.load(Ordering::Relaxed);
        loop {
            if current == 0 {
                return None;
            }
            let next = current.checked_add(1).unwrap_or(0);
            match self.inner.next_open_attempt.compare_exchange_weak(
                current,
                next,
                Ordering::AcqRel,
                Ordering::Relaxed,
            ) {
                Ok(_) => {
                    return Some(OpenCancellation { token, attempt_id: current });
                }
                Err(observed) => current = observed,
            }
        }
    }
}

/// Convert an internal refusal into the stable public error vocabulary.
///
/// `open_cmux_terminal` and provider-backed daemon calls can return text that
/// contains paths, command lines, or remote response bodies. A PTY error is a
/// network boundary, so truncating that text would still disclose secrets.
/// Keep the caller's message parameter for the internal call-site contract,
/// but never put it on the wire.
fn public_pty_error_message(code: &str) -> &'static str {
    match code {
        "bad_request" => "invalid terminal request",
        "trust_refused" => "terminal access denied",
        "trust_revoked" => "terminal access revoked",
        "session_limit" => "terminal limit reached",
        "terminal_gone" => "terminal is no longer available",
        "overflow" => "terminal output overflowed; reattach to continue",
        "busy" => "terminal is busy",
        _ => "terminal operation failed",
    }
}

fn send_pty_error(context: &FrameContext, pty_id: &str, code: &str, _message: &str) {
    (context.send)(json!({
        "version": PTY_PROTOCOL_VERSION,
        "type": "pty_error",
        "ptyId": pty_id,
        "code": code,
        "message": public_pty_error_message(code),
    }));
}

/// Validate the local authority before acquiring a PTY permit or creating an
/// opening reservation. Tunnel state is a public boundary, so an unknown
/// trust value must fail closed even when the normal producer only emits enum
/// values.
fn terminal_open_trust_allowed(context: &FrameContext, actor: &str) -> bool {
    let Some(trust) = Trust::parse(&context.trust) else {
        return false;
    };
    if trust != Trust::Observe {
        return true;
    }
    context.owner_user_id.as_deref().is_some_and(|owner| owner == actor)
}

fn send_typed_pty_error(
    context: &FrameContext,
    pty_id: &str,
    code: RelayPtyErrorCode,
    message: &str,
) {
    let wire_code = match code {
        RelayPtyErrorCode::BadRequest => "bad_request",
        RelayPtyErrorCode::TrustRefused => "trust_refused",
        RelayPtyErrorCode::SessionLimit => "session_limit",
        RelayPtyErrorCode::TerminalGone => "terminal_gone",
        RelayPtyErrorCode::Failed => "failed",
    };
    // Do not reflect provider or filesystem details to remote callers.
    let safe_message = match code {
        RelayPtyErrorCode::BadRequest => "invalid terminal request",
        RelayPtyErrorCode::TrustRefused => "terminal access denied",
        RelayPtyErrorCode::SessionLimit => "terminal session limit reached",
        RelayPtyErrorCode::TerminalGone => "terminal is no longer available",
        RelayPtyErrorCode::Failed => "terminal open failed",
    };
    let _ = message;
    send_pty_error(context, pty_id, wire_code, safe_message);
}

impl Inner {
    async fn open(
        self: Arc<Self>,
        frame: &Value,
        context: &FrameContext,
        cancellation: OpenCancellation,
    ) {
        if cancellation.is_cancelled() {
            return;
        }
        let pty_id = frame.get("ptyId").and_then(Value::as_str).unwrap_or_default().to_owned();
        if pty_id.is_empty() {
            return;
        }
        // `cache_transport_auth` deliberately rejects malformed trust before
        // touching the authority cache. Keep the protocol response here,
        // before the cache lookup can return `None`, so a malformed open is a
        // typed refusal rather than a silent drop.
        if Trust::parse(&context.trust).is_none() {
            send_pty_error(context, &pty_id, "trust_refused", "terminal trust is not established");
            return;
        }
        let Some(auth) = self.auth_for_transport(context) else {
            return;
        };
        if !self.transport_auth_is_current(context, &auth) {
            send_pty_error(context, &pty_id, "trust_revoked", "terminal trust is not current");
            return;
        }
        let reservation_owner = OpeningOwner {
            owner: TransportOwner::from_context(context),
            attempt_id: cancellation.attempt_id(),
        };
        // Read the actor once at the boundary. The same immutable identity is
        // used for admission and for the attachment ownership record.
        let actor = frame.get("actorId").and_then(Value::as_str).unwrap_or_default().to_owned();
        if !terminal_open_trust_allowed(context, &actor) {
            send_pty_error(context, &pty_id, "trust_refused", "terminal trust is not established");
            return;
        }
        // Register before any provider boundary. This gives authority
        // replacement a cancellation handle even if the task has not yet
        // installed its capacity reservation.
        let active_registered = {
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            // Revalidate at the same state boundary as registration. A stale
            // frame may have passed the earlier snapshot read while a detach
            // was waiting for this lock; do not admit provider work after the
            // active transport snapshot has been removed or replaced.
            let authority_current = !context.cancellation.is_cancelled()
                && self.tunnel_authority_generation_current(context)
                && self
                    .transport_auth
                    .lock()
                    .expect("transport auth lock")
                    .get(&reservation_owner.owner)
                    .is_some_and(|current| auth_snapshot_matches(current, &auth));
            let mut opening = self.opening_state.lock().expect("opening state lock");
            let attachments = self.attachments.lock().expect("attach lock");
            if !authority_current {
                Err(("trust_revoked", "terminal trust is not current"))
            } else if attachments.contains_key(&pty_id)
                || opening.reservations.contains_key(&pty_id)
                || opening.active_openings.contains_key(&pty_id)
            {
                Err(("bad_request", "ptyId is already attached"))
            } else if attachments.len() + opening.reservations.len() + opening.active_openings.len()
                >= self.max_ptys
            {
                Err(("session_limit", "terminal limit reached"))
            } else {
                opening
                    .active_openings
                    .insert(pty_id.clone(), (reservation_owner.clone(), cancellation.clone()));
                Ok(())
            }
        };
        if let Err((code, message)) = active_registered {
            send_pty_error(context, &pty_id, code, message);
            return;
        }
        let mut active_opening = ActiveOpening {
            inner: Arc::clone(&self),
            id: pty_id.clone(),
            owner: reservation_owner.clone(),
            active: true,
        };
        // Keep one permit for the complete provider/PTY open. A timeout may
        // leave that task unwinding in the background, so the permit remains
        // owned until the task returns. This is the supervisor boundary that
        // makes stalled providers consume only the finite terminal budget.
        let open_permit = match self.open_slots.clone().try_acquire_owned() {
            Ok(permit) => OpenPermit::new(permit),
            Err(_) => {
                send_pty_error(context, &pty_id, "session_limit", "terminal limit reached");
                return;
            }
        };
        if cancellation.is_cancelled() {
            return;
        }
        if !self.tunnel_authority_generation_current(context) {
            send_pty_error(context, &pty_id, "trust_revoked", "tunnel authority changed");
            return;
        }
        let fail = |code: &str, message: &str| send_pty_error(context, &pty_id, code, message);
        let reservation_result = {
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            let mut opening = self.opening_state.lock().expect("opening state lock");
            let attachments = self.attachments.lock().expect("attach lock");
            let active_owned = opening
                .active_openings
                .get(&pty_id)
                .is_some_and(|(owner, _)| owner == &reservation_owner);
            if attachments.contains_key(&pty_id)
                || opening.reservations.contains_key(&pty_id)
                || !active_owned
            {
                Err(("bad_request", "ptyId is already attached".to_owned()))
            } else if attachments.len()
                + opening.reservations.len()
                + opening.active_openings.len().saturating_sub(1)
                >= self.max_ptys
            {
                Err((
                    "session_limit",
                    format!("this relay caps concurrent terminals at {}", self.max_ptys),
                ))
            } else {
                opening.active_openings.remove(&pty_id);
                opening.reservations.insert(pty_id.clone(), reservation_owner.clone());
                opening.cancellations.insert(reservation_owner.clone(), cancellation.clone());
                Ok(())
            }
        };
        if let Err((code, message)) = reservation_result {
            fail(code, &message);
            return;
        }
        active_opening.disarm();
        let mut reservation = OpeningReservation {
            inner: Arc::clone(&self),
            id: pty_id.clone(),
            owner: reservation_owner.clone(),
            active: true,
        };

        let session = frame.get("session").and_then(Value::as_str).unwrap_or_default().to_owned();
        let (Some(cols), Some(rows)) = (clamp_dim(frame.get("cols")), clamp_dim(frame.get("rows")))
        else {
            fail("bad_request", "invalid session name or dimensions");
            return;
        };
        if !session_name_ok(&session) {
            fail("bad_request", "invalid session name or dimensions");
            return;
        }
        let mut surface_ref: Option<String> = None;
        if let Some(surface) = frame.get("surface") {
            match surface.as_str() {
                Some(value) if surface_ref_ok(value) => surface_ref = Some(value.to_owned()),
                _ => {
                    fail("bad_request", "invalid surface ref");
                    return;
                }
            }
        }

        // Owner-side trust floor: observe-trust machines admit only their
        // OWNER's terminal. Any trust level admits the owner.
        // Only locally established trust is authoritative. Missing local
        // state fails closed; the untrusted frame cannot elevate access.
        // cwd discipline: the local config and server-echoed root lists both
        // apply when present, else $HOME.
        let server_roots = match parse_allowed_roots(frame) {
            Ok(roots) => roots,
            Err(message) => {
                fail("bad_request", message);
                return;
            }
        };
        if let Some(value) = frame.get("cwd")
            && !value.is_null()
            && !value.is_string()
        {
            fail("bad_request", "cwd must be a string");
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
                fail("bad_request", &message);
                return;
            }
        };
        let env = pty_env(&self.env);

        let cancellation_token = cancellation.token();
        let cmux_tui = tokio::select! {
            _ = cancellation_token.cancelled() => return,
            resolved = self.deps.resolve_cmux_tui(cancellation_token.clone()) => resolved,
        };
        if cancellation.is_cancelled() {
            return;
        }
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
                    &cancellation,
                    &open_permit,
                )
                .await
            {
                Ok(Some(opened)) => Some(opened),
                Ok(None) => None, // degrade to whole-session
                Err((code, message)) => {
                    send_typed_pty_error(context, &pty_id, code, &message);
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
                            &cancellation,
                            &open_permit,
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
                            &cancellation,
                            &open_permit,
                        )
                        .await
                };
                match result {
                    Ok(opened) => opened,
                    Err(message) => {
                        fail("failed", &message);
                        return;
                    }
                }
            }
        };

        // Keep the opening reservation held until the attachment is installed.
        // The short state lock couples this transition with revocation, while
        // no PTY operation runs under it.
        let (surface, start, previous, publication_gate) = {
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            let auth_changed = self
                .transport_auth
                .lock()
                .expect("transport auth lock")
                .get(&TransportOwner::from_context(context))
                .is_none_or(|auth| {
                    auth.trust != context.trust
                        || auth.local_roots != context.local_roots
                        || auth.owner_user_id != context.owner_user_id
                        || auth.auth_generation != context.auth_generation
                        || auth.transport_kind != context.transport_kind
                });
            let mut opening = self.opening_state.lock().expect("opening state lock");
            let cancelled = opening.cancelled.get(&pty_id) == Some(&reservation_owner);
            let externally_cancelled = cancellation.is_cancelled();
            let authority_changed = !self.tunnel_authority_generation_current(context);
            let reservation_owned = opening.reservations.get(&pty_id) == Some(&reservation_owner);
            if !reservation_owned
                || cancelled
                || externally_cancelled
                || auth_changed
                || authority_changed
            {
                if reservation_owned {
                    opening.reservations.remove(&pty_id);
                }
                opening.cancellations.remove(&reservation_owner);
                if opening.cancelled.get(&pty_id) == Some(&reservation_owner) {
                    opening.cancelled.remove(&pty_id);
                }
                reservation.active = false;
                return;
            }
            // The value is now owned by the attachment map. Its Drop handler
            // must not release a live viewer when this local is consumed below.
            opened.cleanup_on_drop = false;
            let closing = opened.closing.take().expect("opened closing handle");
            let control = opened.control.take().expect("opened control handle");
            let start = opened.start.take().expect("opened start callback");
            let surface = opened.surface.take();
            let publication_gate = Arc::new(Mutex::new(()));
            let previous = self.attachments.lock().expect("attach lock").insert(
                pty_id.clone(),
                Attachment {
                    closing,
                    active_operations: Arc::new(AtomicUsize::new(0)),
                    operation_gate: Arc::new(Mutex::new(())),
                    publication_gate: Arc::clone(&publication_gate),
                    publication_state: Arc::new(AtomicU64::new(0)),
                    control,
                    actor_id: actor.to_owned(),
                    owner: TransportOwner::from_context(context),
                },
            );
            opening.reservations.remove(&pty_id);
            opening.cancellations.remove(&reservation_owner);
            opening.cancelled.remove(&pty_id);
            reservation.active = false;
            (surface, start, previous, publication_gate)
        };
        if let Some(previous) = previous {
            self.retire_attachment(previous);
        }

        // Keep retirement behind the success frame and startup callbacks.
        // Every attachment removal takes this gate, so a concurrent detach
        // cannot revoke the attachment between the final check and publish.
        let _publication = publication_gate.lock().expect("attachment publication lock");
        let authority_current = self
            .auth_for_transport(context)
            .is_some_and(|auth| self.transport_auth_is_current(context, &auth));
        let attachment_current = self
            .attachments
            .lock()
            .expect("attach lock")
            .get(&pty_id)
            .is_some_and(|current| Arc::ptr_eq(&current.publication_gate, &publication_gate));
        if cancellation.is_cancelled() || !authority_current || !attachment_current {
            let removed = {
                let _state = self.tunnel_state.lock().expect("tunnel state lock");
                let mut attachments = self.attachments.lock().expect("attach lock");
                if let Some(current) = attachments.get(&pty_id) {
                    Self::revoke_publication(current);
                    current.closing.store(true, Ordering::Release);
                }
                attachments.remove(&pty_id)
            };
            if let Some(removed) = removed {
                self.retire_attachment(removed);
            }
            return;
        }

        let mut opened_frame = serde_json::Map::new();
        opened_frame.insert("version".to_owned(), Value::from(PTY_PROTOCOL_VERSION));
        opened_frame.insert("type".to_owned(), Value::from("pty_opened"));
        opened_frame.insert("ptyId".to_owned(), Value::from(pty_id.clone()));
        opened_frame.insert("session".to_owned(), Value::from(session));
        if let Some(surface) = surface {
            opened_frame.insert("surface".to_owned(), Value::from(surface));
        }
        opened_frame.insert("created".to_owned(), Value::from(opened.created));
        opened_frame.insert("cols".to_owned(), Value::from(cols));
        opened_frame.insert("rows".to_owned(), Value::from(rows));
        // The attachment is fully visible in the registry. Release the
        // ordering gate before crossing the transport boundary so a blocked
        // client cannot stall detach or authority revocation.
        drop(_publication);
        // A detach may win after the first admission check while this task
        // prepares the frame. Re-check immediately before each external
        // callback and retire the exact attachment when the capability is no
        // longer current.
        let Some(current_attachment) = self
            .attachment(pty_id)
            .filter(|attachment| Arc::ptr_eq(&attachment.publication_gate, &publication_gate))
        else {
            return;
        };
        let Some(auth) = self.auth_for_transport(context) else {
            self.retire_if_current(pty_id, &current_attachment);
            return;
        };
        if context.cancellation.is_cancelled()
            || cancellation.is_cancelled()
            || !self.transport_auth_is_current(context, &auth)
            || !self.attachment_snapshot_is_current(pty_id, &current_attachment)
        {
            self.retire_if_current(pty_id, &current_attachment);
            return;
        }
        (context.send)(Value::Object(opened_frame));

        // Output only AFTER pty_opened (ordering): banner, then scrollback
        // replay, then live bytes.
        if context.cancellation.is_cancelled()
            || cancellation.is_cancelled()
            || !self
                .auth_for_transport(context)
                .is_some_and(|auth| self.transport_auth_is_current(context, &auth))
            || !self
                .attachment(pty_id)
                .is_some_and(|attachment| self.attachment_snapshot_is_current(pty_id, &attachment))
        {
            self.retire_if_current(pty_id, &current_attachment);
            return;
        }
        start();
    }

    /// Build the per-attachment emit closures (output + exit framing).
    fn sinks(self: &Arc<Self>, pty_id: &str, context: &FrameContext) -> (DataSink, ExitSink) {
        let on_data = {
            let inner = Arc::clone(self);
            let context = context.clone();
            let pty_id = pty_id.to_owned();
            Arc::new(move |chunk: Bytes| inner.emit_output(&pty_id, &chunk, &context))
                as Arc<dyn Fn(Bytes) + Send + Sync>
        };
        let on_exit = {
            let inner = Arc::clone(self);
            let context = context.clone();
            let pty_id = pty_id.to_owned();
            Arc::new(move |code: i64| inner.emit_exit(&pty_id, code, &context))
                as Arc<dyn Fn(i64) + Send + Sync>
        };
        (on_data, on_exit)
    }

    fn emit_output(&self, pty_id: &str, chunk: &Bytes, context: &FrameContext) {
        if !self.tunnel_authority_generation_current(context) {
            return;
        }
        let Some(auth) = self.auth_for_transport(context) else {
            return;
        };
        let Some(attachment) = self.attachment(pty_id) else {
            return;
        };
        // Serialize only the authorization snapshot. Never hold the gate
        // across the transport callback: a stalled consumer must not block a
        // disconnect or trust revocation from retiring this attachment.
        let authorized = {
            let _operation = attachment.operation_gate.lock().expect("attachment operation lock");
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            self.attachment_is_authorized(pty_id, &attachment, &auth, context)
        };
        if !authorized {
            self.handle_authorization_failure(pty_id, &attachment, &auth, context, "output");
            return;
        }
        // Zero-byte chunks carry nothing and historically crashed the web
        // terminal's write path (D-R6-1); never put an empty frame on the wire.
        if chunk.is_empty() {
            return;
        }
        let buffered = (auth.buffered_amount)();
        // Admit the complete frame before sending it. The socket may accept a
        // frame exactly at the cap, but must reject one that would push the
        // buffered amount over the cap.
        if buffered.saturating_add(chunk.len() as u64) > self.output_cap {
            self.retire_if_current(pty_id, &attachment);
            send_pty_error(
                context,
                pty_id,
                "failed",
                &format!(
                    "dropped: {buffered} bytes buffered toward the server (cap {})",
                    self.output_cap
                ),
            );
            return;
        }
        // Claim publication atomically with revocation. If detach wins the
        // claim, no callback runs. If this claim wins first, the frame is
        // ordered before detach even if the callback itself is slow.
        if !self.attachment_snapshot_is_current(pty_id, &attachment)
            || !Self::try_claim_publication(&attachment)
        {
            return;
        }
        (auth.send)(json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_output",
            "ptyId": pty_id,
            "dataB64": BASE64.encode(chunk),
        }));
    }

    fn emit_exit(&self, pty_id: &str, code: i64, context: &FrameContext) {
        if !self.tunnel_authority_generation_current(context) {
            return;
        }
        let Some(auth) = self.auth_for_transport(context) else {
            return;
        };
        let Some(attachment) = self.attachment(pty_id) else {
            return;
        };
        let _publication = attachment.publication_gate.lock().expect("attachment publication lock");
        let _operation = attachment.operation_gate.lock().expect("attachment operation lock");
        let authorized = {
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            self.attachment_is_authorized(pty_id, &attachment, &auth, context)
        };
        if !authorized {
            drop(_operation);
            drop(_publication);
            self.handle_authorization_failure(pty_id, &attachment, &auth, context, "exit");
            return;
        }
        let removed = {
            Self::revoke_publication(&attachment);
            attachment.closing.store(true, Ordering::Release);
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            let mut attachments = self.attachments.lock().expect("attach lock");
            let same = attachments.get(pty_id).is_some_and(|current| {
                Arc::ptr_eq(&current.operation_gate, &attachment.operation_gate)
            });
            if same { attachments.remove(pty_id).is_some() } else { false }
        };
        if !removed {
            return;
        }
        // Exit publication crosses the transport boundary. Release the
        // lifecycle state before invoking the callback.
        drop(_operation);
        drop(_publication);
        (auth.send)(json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_exit",
            "ptyId": pty_id,
            "code": code,
        }));
    }

    /// Detach, NOT kill: idempotent, unknown ptyId tolerated.
    fn close(&self, pty_id: &str) {
        // Match `open`'s lock order. If opening still owns the reservation,
        // record an owner-specific cancellation and let it dispose the PTY.
        let attachment = {
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            let mut opening = self.opening_state.lock().expect("opening state lock");
            if let Some(owner) = opening.reservations.get(pty_id).cloned() {
                opening.reservations.remove(pty_id);
                if let Some(cancellation) = opening.cancellations.remove(&owner) {
                    cancellation.cancel();
                }
                opening.cancelled.insert(pty_id.to_owned(), owner);
                return;
            }
            self.attachments.lock().expect("attach lock").get(pty_id).cloned()
        };
        if let Some(attachment) = attachment {
            let _publication =
                attachment.publication_gate.lock().expect("attachment publication lock");
            let _operation = attachment.operation_gate.lock().expect("attachment operation lock");
            let removed = {
                let _state = self.tunnel_state.lock().expect("tunnel state lock");
                let mut attachments = self.attachments.lock().expect("attach lock");
                let same = attachments.get(pty_id).is_some_and(|current| {
                    Arc::ptr_eq(&current.publication_gate, &attachment.publication_gate)
                });
                if same { attachments.remove(pty_id) } else { None }
            };
            drop(_operation);
            drop(_publication);
            if let Some(removed) = removed {
                self.retire_attachment(removed);
            }
        }
    }

    /// Frame-level transport fence. Unknown ids retain the protocol's silent
    /// no-op behavior; once an id is reserved or attached, a different
    /// transport may not act on it. A `None` caller owns everything (legacy).
    fn transport_owns(&self, pty_id: &str, context: &FrameContext) -> bool {
        let Some(transport_id) = context.transport_id.as_deref() else {
            return context.transport_kind == TransportKind::Legacy;
        };
        if let Some(owner) =
            self.opening_state.lock().expect("opening state lock").reservations.get(pty_id).cloned()
        {
            return owner.owner.id.as_deref() == Some(transport_id)
                && owner.owner.kind == context.transport_kind;
        }
        if let Some((owner, _)) = self
            .opening_state
            .lock()
            .expect("opening state lock")
            .active_openings
            .get(pty_id)
            .cloned()
        {
            return owner.owner.id.as_deref() == Some(transport_id)
                && owner.owner.kind == context.transport_kind;
        }
        if let Some(attachment) = self.attachments.lock().expect("attach lock").get(pty_id) {
            return attachment.owner.id.as_deref() == Some(transport_id)
                && attachment.owner.kind == context.transport_kind;
        }
        true
    }

    fn with_authorized<F>(
        &self,
        pty_id: &str,
        context: &FrameContext,
        action: &str,
        operation: F,
    ) -> bool
    where
        F: FnOnce(&Attachment),
    {
        let Some(auth) = self.auth_for_transport(context) else { return false };
        let Some(attachment) = self.attachment(pty_id) else { return false };
        // The gate and state lock form the authorization linearization point.
        // Snapshot that decision, then release both before entering platform
        // I/O. A child that does not read stdin must not block its output
        // callback or a close on this attachment.
        let authorized = {
            let _operation = attachment.operation_gate.lock().expect("attachment operation lock");
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            self.attachment_is_authorized(pty_id, &attachment, &auth, context)
        };
        if !authorized {
            self.handle_authorization_failure(pty_id, &attachment, &auth, context, action);
            return false;
        }
        // Couple admission to retirement with a closing double-check. A
        // detach that stores `closing` before removal wins the race and the
        // operation is rejected. An operation that increments first is
        // already admitted and may finish without blocking retirement.
        if !Self::try_admit_operation(&attachment) {
            return false;
        }
        if !self.attachment_snapshot_is_current(pty_id, &attachment) {
            Self::release_operation(&attachment);
            return false;
        }
        operation(&attachment);
        Self::release_operation(&attachment);
        // The operation was admitted at the snapshot boundary and may finish
        // concurrently with retirement. Re-read the attachment identity so
        // callers never treat a replaced or closed generation as current.
        self.attachment_snapshot_is_current(pty_id, &attachment)
    }

    fn try_admit_operation(attachment: &Attachment) -> bool {
        if attachment.closing.load(Ordering::Acquire) {
            return false;
        }
        attachment.active_operations.fetch_add(1, Ordering::AcqRel);
        if attachment.closing.load(Ordering::Acquire) {
            attachment.active_operations.fetch_sub(1, Ordering::AcqRel);
            return false;
        }
        true
    }

    fn release_operation(attachment: &Attachment) {
        attachment.active_operations.fetch_sub(1, Ordering::AcqRel);
    }

    fn auth_for_transport(&self, context: &FrameContext) -> Option<AuthSnapshot> {
        if context.cancellation.is_cancelled() {
            return None;
        }
        let key = TransportOwner::from_context(context);
        let _state = self.tunnel_state.lock().expect("tunnel state lock");
        self.transport_auth.lock().expect("transport auth lock").get(&key).cloned()
    }

    fn attachment(&self, pty_id: &str) -> Option<Attachment> {
        self.attachments.lock().expect("attach lock").get(pty_id).cloned()
    }

    fn attachment_is_authorized(
        &self,
        pty_id: &str,
        attachment: &Attachment,
        auth: &AuthSnapshot,
        context: &FrameContext,
    ) -> bool {
        let transport_id = context.transport_id.as_deref();
        let Some(trust) = Self::matching_trust(auth, context) else { return false };
        let owner = auth.owner_user_id.as_deref();
        let trust_allowed = trust != Trust::Observe
            || (owner.is_some() && owner == Some(attachment.actor_id.as_str()));
        trust_allowed
            && !attachment.closing.load(Ordering::SeqCst)
            && self.tunnel_authority_generation_current(context)
            && self.attachment_is_current(pty_id, attachment)
            && self.transport_auth_is_current(context, auth)
            && match context.transport_kind {
                TransportKind::Legacy => context.transport_id.is_none(),
                TransportKind::Relay | TransportKind::Tunnel => {
                    transport_id.is_some_and(|id| attachment.owner.id.as_deref() == Some(id))
                        && attachment.owner.kind == context.transport_kind
                }
            }
    }

    fn close_authorized(&self, pty_id: &str, context: &FrameContext) {
        let Some(auth) = self.auth_for_transport(context) else { return };

        // A close may arrive while the PTY provider is still resolving. In
        // that window there is no attachment to authorize, but the open is
        // already consuming an attempt. Cancel only the exact owner that the
        // caller is allowed to retire, so a late close cannot cancel a
        // replacement that reused the same pty id.
        let opening = {
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            let state = self.opening_state.lock().expect("opening state lock");
            state.reservations.get(pty_id).cloned().map(|owner| (owner, None)).or_else(|| {
                state
                    .active_openings
                    .get(pty_id)
                    .map(|(owner, cancellation)| (owner.clone(), Some(cancellation.clone())))
            })
        };
        if let Some((owner, _active_cancellation)) = opening {
            let owner_matches = match context.transport_kind {
                TransportKind::Legacy => context.transport_id.is_none(),
                TransportKind::Relay | TransportKind::Tunnel => {
                    context.transport_id.is_some()
                        && owner.owner == TransportOwner::from_context(context)
                }
            };
            let authorized = owner_matches
                && Self::matching_trust(&auth, context).is_some()
                && self.tunnel_authority_generation_current(context)
                && self.transport_auth_is_current(context, &auth);
            if !authorized {
                return;
            }
            let cancellation = {
                let _state = self.tunnel_state.lock().expect("tunnel state lock");
                let mut opening = self.opening_state.lock().expect("opening state lock");
                if opening.reservations.get(pty_id) == Some(&owner) {
                    opening.reservations.remove(pty_id);
                    let cancellation = opening.cancellations.remove(&owner);
                    opening.cancelled.insert(pty_id.to_owned(), owner);
                    cancellation
                } else if opening
                    .active_openings
                    .get(pty_id)
                    .is_some_and(|(active_owner, _)| active_owner == &owner)
                {
                    let (_, cancellation) =
                        opening.active_openings.remove(pty_id).expect("active opening present");
                    opening.cancelled.insert(pty_id.to_owned(), owner);
                    Some(cancellation)
                } else {
                    None
                }
            };
            if let Some(cancellation) = cancellation {
                cancellation.cancel();
                return;
            }
            // The opening may have published an attachment between the
            // snapshot above and the cancellation mutation. Fall through to
            // the attachment path so this close frame still retires that
            // exact generation. Do not cancel the stale token: it may belong
            // to a completed open or to a replacement that won the race.
        }

        let Some(attachment) = self.attachment(pty_id) else { return };
        let _publication = attachment.publication_gate.lock().expect("attachment publication lock");
        let _operation = attachment.operation_gate.lock().expect("attachment operation lock");
        let authorized = {
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            self.attachment_is_authorized(pty_id, &attachment, &auth, context)
        };
        if !authorized {
            drop(_operation);
            drop(_publication);
            self.handle_authorization_failure(pty_id, &attachment, &auth, context, "close");
            return;
        }
        let removed = {
            attachment.closing.store(true, Ordering::Release);
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            let mut attachments = self.attachments.lock().expect("attach lock");
            let same = attachments.get(pty_id).is_some_and(|current| {
                Arc::ptr_eq(&current.operation_gate, &attachment.operation_gate)
            });
            if same { attachments.remove(pty_id).is_some() } else { false }
        };
        if removed {
            // Killing a PTY can acquire a platform mutex. Keep it outside the
            // lifecycle barrier and the per-attachment operation gate.
            drop(_operation);
            drop(_publication);
            attachment.control.kill();
        }
    }

    fn attachment_is_current(&self, pty_id: &str, attachment: &Attachment) -> bool {
        self.attachments
            .lock()
            .expect("attach lock")
            .get(pty_id)
            .is_some_and(|current| Arc::ptr_eq(&current.operation_gate, &attachment.operation_gate))
    }

    fn attachment_snapshot_is_current(&self, pty_id: &str, attachment: &Attachment) -> bool {
        !attachment.closing.load(Ordering::Acquire)
            && self.attachment_is_current(pty_id, attachment)
    }

    fn try_claim_publication(attachment: &Attachment) -> bool {
        loop {
            let state = attachment.publication_state.load(Ordering::Acquire);
            if state & 1 != 0 {
                return false;
            }
            let next = state.wrapping_add(2);
            match attachment.publication_state.compare_exchange_weak(
                state,
                next,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return true,
                Err(_) => continue,
            }
        }
    }

    fn revoke_publication(attachment: &Attachment) {
        attachment.publication_state.fetch_or(1, Ordering::AcqRel);
    }

    fn transport_auth_is_current(&self, context: &FrameContext, auth: &AuthSnapshot) -> bool {
        if context.cancellation.is_cancelled()
            || Self::matching_trust(auth, context).is_none()
            // `auth_for_transport` is keyed only by transport id and kind.
            // Require the complete frame snapshot here so a stale context
            // cannot reuse an older owner's identity or root scope.
            || !auth_snapshot_matches(auth, &AuthSnapshot::from_context(context))
        {
            return false;
        }
        let key = TransportOwner::from_context(context);
        self.transport_auth
            .lock()
            .expect("transport auth lock")
            .get(&key)
            .is_some_and(|current| auth_snapshot_matches(current, auth))
    }

    fn handle_authorization_failure(
        &self,
        pty_id: &str,
        attachment: &Attachment,
        auth: &AuthSnapshot,
        context: &FrameContext,
        action: &str,
    ) {
        let trust_allowed = Self::matching_trust(auth, context).is_some_and(|trust| {
            trust != Trust::Observe
                || (auth.owner_user_id.is_some()
                    && auth.owner_user_id.as_deref() == Some(attachment.actor_id.as_str()))
        });
        if trust_allowed
            && self.tunnel_authority_generation_current(context)
            && self.transport_auth_is_current(context, auth)
        {
            return;
        }
        self.retire_if_current(pty_id, attachment);
        send_pty_error(
            context,
            pty_id,
            "trust_revoked",
            &format!("PTY {action} refused after trust change"),
        );
    }

    fn retire_if_current(&self, pty_id: &str, attachment: &Attachment) {
        // The publication gate serializes open success with removal. The
        // operation gate then protects the attachment's control lifecycle.
        // Callers must release any prior guard before entering this helper.
        let publication = attachment.publication_gate.lock().expect("attachment publication lock");
        let operation = attachment.operation_gate.lock().expect("attachment operation lock");
        Self::revoke_publication(attachment);
        attachment.closing.store(true, Ordering::Release);
        let removed = {
            let _state = self.tunnel_state.lock().expect("tunnel state lock");
            let mut attachments = self.attachments.lock().expect("attach lock");
            let same = attachments.get(pty_id).is_some_and(|current| {
                Arc::ptr_eq(&current.operation_gate, &attachment.operation_gate)
            });
            if same { attachments.remove(pty_id) } else { None }
        };
        drop(operation);
        drop(publication);
        if let Some(removed) = removed {
            self.retire_attachment(removed);
        }
    }

    fn retire_attachment(&self, attachment: Attachment) {
        // Revocation must not wait for an admitted PTY write. The operation
        // was linearized before removal from the attachment map; killing the
        // control concurrently closes that admitted operation when the
        // platform permits it, while this transition remains bounded.
        Self::revoke_publication(&attachment);
        attachment.closing.store(true, Ordering::SeqCst);
        attachment.control.kill();
    }
}

/// A resolved open: what to echo, plus a deferred `start` that begins output.
struct Opened {
    created: bool,
    surface: Option<String>,
    control: Option<Arc<dyn PtyControl>>,
    closing: Option<Arc<AtomicBool>>,
    start: Option<Box<dyn FnOnce() + Send>>,
    /// A cancelled open can finish after the caller's deadline. Until the
    /// attachment is installed, dropping this value must release the spawned
    /// viewer instead of leaking a PTY and its process group.
    cleanup_on_drop: bool,
}

/// Control sockets use an explicit `end()` operation. Own every probe until
/// its async handshake has completed so cancellation cannot leave a reader or
/// writer task attached to a timed-out terminal open.
struct ControlEndOnDrop {
    control: Option<Arc<dyn ControlHandle>>,
}

impl ControlEndOnDrop {
    fn new(control: Arc<dyn ControlHandle>) -> Self {
        Self { control: Some(control) }
    }

    fn disarm(&mut self) {
        self.control = None;
    }
}

impl Drop for ControlEndOnDrop {
    fn drop(&mut self) {
        if let Some(control) = self.control.take() {
            control.end();
        }
    }
}

impl Drop for Opened {
    fn drop(&mut self) {
        if self.cleanup_on_drop {
            if let Some(closing) = &self.closing {
                closing.store(true, Ordering::SeqCst);
            }
            if let Some(control) = &self.control {
                control.kill();
            }
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
    fn cache_transport_auth(&self, context: &FrameContext) -> bool {
        // The frame context is a security boundary. Never let an unknown
        // trust string reuse a previously cached valid snapshot.
        if context.cancellation.is_cancelled() || Trust::parse(&context.trust).is_none() {
            return false;
        }
        // Legacy callers have no transport identity, so their cache write is
        // the only disconnect fence available. Serialize it with detach and
        // identified-authority replacement. A frame admitted before a detach
        // is then included in that detach's cleanup scan rather than
        // re-registering authority halfway through it.
        let _update = self.transport_auth_updates.lock().expect("transport auth update lock");
        let _state = self.tunnel_state.lock().expect("tunnel state lock");
        if context.cancellation.is_cancelled() || !self.tunnel_authority_generation_current(context)
        {
            return false;
        }
        let snapshot = AuthSnapshot::from_context(context);
        let owner = TransportOwner::from_context(context);
        if context.transport_kind == TransportKind::Legacy && context.transport_id.is_none() {
            // Legacy whole-manager callers use `None` and provide the
            // current trust on each frame. Keep that contract for non-
            // transport code.
            self.transport_auth.lock().expect("transport auth lock").insert(owner, snapshot);
            return true;
        }
        if context.transport_id.is_none() {
            // Relay and managed tunnel contexts require an explicit transport
            // identity. A missing ID is not a legacy capability.
            return false;
        }
        // Identified transports must publish authority through
        // `update_transport_auth` before their first frame. A frame cannot
        // create a new map entry, so removing the active snapshot is a
        // complete disconnect fence without an unbounded tombstone set.
        self.transport_auth
            .lock()
            .expect("transport auth lock")
            .get(&owner)
            .is_some_and(|cached| auth_snapshot_matches(cached, &snapshot))
    }

    fn matching_trust(auth: &AuthSnapshot, context: &FrameContext) -> Option<Trust> {
        let auth_trust = Trust::parse(&auth.trust)?;
        let context_trust = Trust::parse(&context.trust)?;
        (auth_trust == context_trust).then_some(auth_trust)
    }

    fn tunnel_authority_generation_current(&self, context: &FrameContext) -> bool {
        let current = self.tunnel_authority_generation.load(Ordering::Acquire);
        match context.transport_kind {
            TransportKind::Tunnel => {
                // Managed tunnel frames always carry the generation that was
                // published to their connection. Missing metadata is an
                // invalid capability, even while the floor is zero.
                context.auth_generation == Some(current)
            }
            TransportKind::Legacy | TransportKind::Relay => {
                // Legacy and relay callers predate managed tunnel
                // generations. They may omit the field, but a supplied
                // generation still has to match exactly.
                context.auth_generation.is_none_or(|generation| generation == current)
            }
        }
    }

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
        cancellation: &OpenCancellation,
        open_permit: &OpenPermit,
    ) -> Result<Opened, String> {
        let socket_dir = self.deps.socket_dir();
        let cancellation_token = cancellation.token();
        let ensured = tokio::select! {
            _ = cancellation_token.cancelled() => return Err("terminal open cancelled".to_owned()),
            result = self.deps.ensure_daemon(
                cmux_tui,
                session,
                &socket_dir,
                cwd,
                env,
                cancellation_token.clone(),
            ) => result,
        }?;
        let roots_scoped = context.local_roots.as_deref().is_some_and(|r| !r.is_empty())
            || server_roots.is_some_and(|r| !r.is_empty());
        if roots_scoped {
            let control = self
                .deps
                .connect_control(&ensured.socket_path, cancellation.token())
                .await
                .map_err(|_| "cannot inspect existing daemon cwd".to_owned())?;
            let mut control_guard = ControlEndOnDrop::new(Arc::clone(&control));
            if cancellation.is_cancelled() {
                return Err("terminal open cancelled".to_owned());
            }
            let Some(listed) = request_control_with_cancellation(
                &control,
                "list-workspaces",
                json!({}),
                cancellation,
            )
            .await
            else {
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
                Err(_) => {
                    return Err("cannot inspect existing daemon surfaces".to_owned());
                }
            };
            if tabs.len() > MAX_ENUM_TERMINALS || (tabs.is_empty() && !ensured.created) {
                return Err("cannot prove existing daemon cwd is within allowed roots".to_owned());
            }
            for tab in tabs {
                if cancellation.is_cancelled() {
                    return Err("terminal open cancelled".to_owned());
                }
                let Some(info) = request_control_with_cancellation(
                    &control,
                    "process-info",
                    json!({ "surface": tab.surface_id }),
                    cancellation,
                )
                .await
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
            control.end();
            control_guard.disarm();
        }
        let mut args = cmux_tui.prefix.clone();
        args.extend([
            "attach".to_owned(),
            "--session".to_owned(),
            session.to_owned(),
            "--socket".to_owned(),
            ensured.socket_path.to_string_lossy().into_owned(),
        ]);
        let handle = self
            .deps
            .spawn_pty(
                SpawnSpec {
                    file: cmux_tui.file.clone(),
                    args,
                    cols,
                    rows,
                    cwd: cwd.to_path_buf(),
                    env: env.clone(),
                    cancellation: cancellation.token(),
                },
                cancellation.token(),
                open_permit.clone(),
            )
            .await;
        let control = Arc::clone(&handle.control);
        let output = Arc::clone(&handle.output);
        let banner = handle.banner.clone();
        let (on_data, on_exit) = self.sinks(pty_id, context);
        Ok(Opened {
            created: ensured.created,
            surface: None,
            control: Some(control),
            closing: Some(Arc::new(AtomicBool::new(false))),
            start: Some(Box::new(move || drive_handle(output, banner, on_data, on_exit))),
            cleanup_on_drop: true,
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
        cancellation: &OpenCancellation,
        open_permit: &OpenPermit,
    ) -> Result<Opened, String> {
        let mut created = false;
        let pending_viewer = Arc::new(AtomicBool::new(false));
        let shell_session = loop {
            if let Some(existing) =
                self.shell_sessions.lock().expect("shell lock").get(session).cloned()
            {
                if context.local_roots.as_deref().is_some_and(|r| !r.is_empty())
                    || server_roots.is_some_and(|r| !r.is_empty())
                {
                    return Err("cannot reattach existing shell under scoped roots".to_owned());
                }
                existing.control.resize(cols, rows);
                existing.pending_viewers.fetch_add(1, Ordering::AcqRel);
                pending_viewer.store(true, Ordering::Release);
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
                let cancellation_token = cancellation.token();
                tokio::select! {
                    biased;
                    _ = cancellation_token.cancelled() => {
                        return Err("terminal open cancelled".to_owned());
                    }
                    _ = waiter.expect("shell waiter") => {}
                }
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
                let handle = self
                    .deps
                    .spawn_pty(
                        SpawnSpec {
                            file: shell,
                            args: Vec::new(),
                            cols,
                            rows,
                            cwd: cwd.to_path_buf(),
                            env: env.clone(),
                            cancellation: cancellation.token(),
                        },
                        cancellation.token(),
                        open_permit.clone(),
                    )
                    .await;
                if cancellation.is_cancelled() {
                    handle.control.kill();
                    return Err("terminal open cancelled".to_owned());
                }
                let PtyHandle { control, output, banner } = handle;
                let shell_session = Arc::new(ShellSession {
                    control,
                    pending_viewers: AtomicUsize::new(0),
                    flow_lock: Mutex::new(()),
                    dispatch_lock: Mutex::new(()),
                    banner,
                    inner: Mutex::new(ShellInner {
                        ring: VecDeque::new(),
                        ring_size: 0,
                        alive: true,
                        viewers: Vec::new(),
                        paused_viewers: HashSet::new(),
                        paused_backlog: HashMap::new(),
                        draining_viewers: HashSet::new(),
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
                    let _dispatch = data_session.dispatch_lock.lock().expect("shell dispatch lock");
                    let viewers_to_notify: Vec<(Arc<Mutex<()>>, Arc<dyn Fn(Bytes) + Send + Sync>)> = {
                        let mut inner = data_session.inner.lock().expect("shell inner lock");
                        inner.ring_size += chunk.len();
                        inner.ring.push_back(chunk.clone());
                        while inner.ring_size > scrollback_limit && inner.ring.len() > 1 {
                            let Some(dropped) = inner.ring.pop_front() else { break };
                            inner.ring_size -= dropped.len();
                        }
                        let mut viewers_to_notify = Vec::new();
                        for viewer in &inner.viewers {
                            if inner.paused_viewers.contains(&viewer.id)
                                || inner.draining_viewers.contains(&viewer.id)
                            {
                                let backlog = inner.paused_backlog.entry(viewer.id).or_default();
                                backlog.chunks.push_back(chunk.clone());
                                backlog.bytes += chunk.len();
                                while backlog.bytes > scrollback_limit && backlog.chunks.len() > 1 {
                                    if let Some(dropped) = backlog.chunks.pop_front() {
                                        backlog.bytes -= dropped.len();
                                    }
                                }
                            } else {
                                viewers_to_notify.push((
                                    Arc::clone(&viewer.delivery_lock),
                                    Arc::clone(&viewer.on_data),
                                ));
                            }
                        }
                        viewers_to_notify
                    };
                    drop(_dispatch);
                    for (delivery_lock, on_data) in viewers_to_notify {
                        let _delivery = delivery_lock.lock().expect("viewer delivery lock");
                        on_data(chunk.clone());
                    }
                });
                let on_session_exit: ExitSink = Arc::new(move |code: i64| {
                    let viewers = {
                        let _flow = exit_session.flow_lock.lock().expect("shell flow lock");
                        let mut inner = exit_session.inner.lock().expect("shell inner lock");
                        inner.alive = false;
                        inner.paused_viewers.clear();
                        inner.paused_backlog.clear();
                        inner.draining_viewers.clear();
                        std::mem::take(&mut inner.viewers)
                    };
                    manager.shell_sessions.lock().expect("shell lock").remove(&session_name);
                    for viewer in viewers {
                        let _delivery = viewer.delivery_lock.lock().expect("viewer delivery lock");
                        (viewer.on_exit)(code);
                    }
                });
                if cancellation.is_cancelled() {
                    shell_session.control.kill();
                    return Err("terminal open cancelled".to_owned());
                }
                output.subscribe(on_session_data, on_session_exit);
                self.shell_sessions
                    .lock()
                    .expect("shell lock")
                    .insert(session.to_owned(), Arc::clone(&shell_session));
                // Cancellation can arrive while `subscribe` is replaying its
                // backlog (the callback is synchronous). Re-check after the
                // identity is cached, and remove only this exact session so a
                // replacement cannot be disturbed.
                if cancellation.is_cancelled() {
                    let removed =
                        remove_cached_shell_if_same_without_viewers(&self, session, &shell_session);
                    if removed {
                        shell_session.control.kill();
                    }
                    self.shell_starting.lock().expect("shell starting lock").remove(session);
                    reservation.active = false;
                    reservation.notify.notify_waiters();
                    return Err("terminal open cancelled".to_owned());
                }
                self.shell_starting.lock().expect("shell starting lock").remove(session);
                reservation.active = false;
                reservation.notify.notify_waiters();
                created = true;
                break shell_session;
            }
        };

        // A stable viewer id lets release remove exactly this sink.
        let viewer_id = next_viewer_id();
        let released = Arc::new(AtomicBool::new(false));
        let closing = Arc::new(AtomicBool::new(false));
        let (on_data, on_exit) = self.sinks(pty_id, context);

        // The per-attachment control proxies onto the session pty but its
        // kill() only unhooks this viewer (release), never the session.
        let proxy = Arc::new(ShellViewerControl {
            session: Arc::clone(&shell_session),
            viewer_id,
            released: Arc::clone(&released),
            pending_viewer: Arc::clone(&pending_viewer),
        });

        let start_session = Arc::clone(&shell_session);
        let start_pending_viewer = Arc::clone(&pending_viewer);
        let start: Box<dyn FnOnce() + Send> = Box::new(move || {
            // This open has reached its publication callback. It no longer
            // counts as a pending viewer for cancellation cleanup.
            if start_pending_viewer.swap(false, Ordering::AcqRel) {
                start_session.pending_viewers.fetch_sub(1, Ordering::AcqRel);
            }
            let (banner, replay, alive, delivery_lock) = {
                let _dispatch = start_session.dispatch_lock.lock().expect("shell dispatch lock");
                let _flow = start_session.flow_lock.lock().expect("shell flow lock");
                let mut inner = start_session.inner.lock().expect("shell inner lock");
                if released.load(Ordering::SeqCst) {
                    return;
                }
                let banner = created.then(|| start_session.banner.clone()).flatten();
                let replay = (!created && inner.ring_size > 0).then(|| {
                    inner.ring.iter().flat_map(|c| c.iter().copied()).collect::<Vec<u8>>()
                });
                let alive = inner.alive;
                let delivery_lock = alive.then(|| Arc::new(Mutex::new(())));
                if let Some(delivery_lock) = &delivery_lock {
                    inner.viewers.push(ViewerSink {
                        id: viewer_id,
                        on_data: Arc::clone(&on_data),
                        on_exit: Arc::clone(&on_exit),
                        delivery_lock: Arc::clone(delivery_lock),
                    });
                    inner.draining_viewers.insert(viewer_id);
                }
                (banner, replay, alive, delivery_lock)
            };
            if !alive {
                on_exit(0);
                return;
            }
            let Some(delivery_lock) = delivery_lock else { return };
            if let Some(banner) = banner {
                let _delivery = delivery_lock.lock().expect("viewer delivery lock");
                on_data(Bytes::from(banner));
            }
            if let Some(replay) = replay {
                let _delivery = delivery_lock.lock().expect("viewer delivery lock");
                on_data(Bytes::from(replay));
            }
            if released.load(Ordering::SeqCst) {
                return;
            }
            loop {
                let chunk = {
                    let _flow = start_session.flow_lock.lock().expect("shell flow lock");
                    let mut inner = start_session.inner.lock().expect("shell inner lock");
                    if released.load(Ordering::SeqCst) {
                        inner.paused_backlog.remove(&viewer_id);
                        inner.draining_viewers.remove(&viewer_id);
                        None
                    } else {
                        let chunk = inner.paused_backlog.get_mut(&viewer_id).and_then(|backlog| {
                            let chunk = backlog.chunks.pop_front()?;
                            backlog.bytes -= chunk.len();
                            Some(chunk)
                        });
                        if chunk.is_none() {
                            inner.paused_backlog.remove(&viewer_id);
                            inner.draining_viewers.remove(&viewer_id);
                        }
                        chunk
                    }
                };
                let Some(chunk) = chunk else { break };
                let _delivery = delivery_lock.lock().expect("viewer delivery lock");
                on_data(chunk);
            }
        });

        Ok(Opened {
            created,
            surface: None,
            control: Some(proxy),
            closing: Some(closing),
            start: Some(start),
            cleanup_on_drop: true,
        })
    }
}

struct ShellViewerControl {
    session: Arc<ShellSession>,
    viewer_id: u64,
    released: Arc<AtomicBool>,
    pending_viewer: Arc<AtomicBool>,
}

impl ShellViewerControl {
    fn release(&self) {
        self.released.store(true, Ordering::SeqCst);
        if self.pending_viewer.swap(false, Ordering::AcqRel) {
            self.session.pending_viewers.fetch_sub(1, Ordering::AcqRel);
        }
        {
            let _flow = self.session.flow_lock.lock().expect("shell flow lock");
            let mut inner = self.session.inner.lock().expect("shell inner lock");
            inner.viewers.retain(|viewer| viewer.id != self.viewer_id);
            inner.paused_backlog.remove(&self.viewer_id);
            inner.draining_viewers.remove(&self.viewer_id);
            inner.paused_viewers.remove(&self.viewer_id);
        }
    }
}

impl PtyControl for ShellViewerControl {
    fn write(&self, data: &[u8]) {
        self.session.control.write(data);
    }
    fn resize(&self, cols: u16, rows: u16) {
        self.session.control.resize(cols, rows);
    }
    fn pause(&self) {
        let should_pause = {
            let _flow = self.session.flow_lock.lock().expect("shell flow lock");
            let mut inner = self.session.inner.lock().expect("shell inner lock");
            inner.paused_viewers.insert(self.viewer_id) && inner.paused_viewers.len() == 1
        };
        // The shared shell PTY stays running. Output fanout buffers only this
        // viewer while it is paused, so one slow client cannot stall peers.
    }
    fn resume(&self) {
        let should_resume = {
            let _flow = self.session.flow_lock.lock().expect("shell flow lock");
            let mut inner = self.session.inner.lock().expect("shell inner lock");
            let removed = inner.paused_viewers.remove(&self.viewer_id);
            if removed {
                inner.draining_viewers.insert(self.viewer_id);
                inner.paused_backlog.entry(self.viewer_id).or_default();
            }
            removed && inner.paused_viewers.is_empty()
        };
        self.drain_backlog();
    }

    fn drain_backlog(&self) {
        loop {
            let next = {
                let _flow = self.session.flow_lock.lock().expect("shell flow lock");
                let mut inner = self.session.inner.lock().expect("shell inner lock");
                if self.released.load(Ordering::SeqCst) {
                    inner.paused_backlog.remove(&self.viewer_id);
                    inner.draining_viewers.remove(&self.viewer_id);
                    None
                } else {
                    if let Some(on_data) = inner
                        .viewers
                        .iter()
                        .find(|viewer| viewer.id == self.viewer_id)
                        .map(|viewer| Arc::clone(&viewer.on_data))
                    {
                        let delivery_lock = inner
                            .viewers
                            .iter()
                            .find(|viewer| viewer.id == self.viewer_id)
                            .map(|viewer| Arc::clone(&viewer.delivery_lock));
                        let chunk =
                            inner.paused_backlog.get_mut(&self.viewer_id).and_then(|backlog| {
                                let chunk = backlog.chunks.pop_front()?;
                                backlog.bytes -= chunk.len();
                                Some(chunk)
                            });
                        if let (Some(delivery_lock), Some(chunk)) = (delivery_lock, chunk) {
                            Some((delivery_lock, on_data, chunk))
                        } else {
                            inner.paused_backlog.remove(&self.viewer_id);
                            inner.draining_viewers.remove(&self.viewer_id);
                            None
                        }
                    } else {
                        inner.paused_backlog.remove(&self.viewer_id);
                        inner.draining_viewers.remove(&self.viewer_id);
                        None
                    }
                }
            };
            let Some((delivery_lock, on_data, chunk)) = next else { break };
            let _delivery = delivery_lock.lock().expect("viewer delivery lock");
            on_data(chunk);
        }
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
}

impl Drop for ControlTerminalControl {
    fn drop(&mut self) {
        // A cancelled open can drop this proxy before it reaches the
        // attachment map. Explicitly close the underlying control stream.
        self.control.end();
    }
}

impl PtyControl for ControlTerminalControl {
    fn write(&self, data: &[u8]) {
        self.control
            .send("send", json!({ "surface": self.surface_id, "bytes": BASE64.encode(data) }));
    }
    fn resize(&self, cols: u16, rows: u16) {
        self.control.send(
            "resize-surface",
            json!({ "surface": self.surface_id, "cols": cols, "rows": rows }),
        );
    }
    fn pause(&self) {
        self.control.pause();
    }
    fn resume(&self) {
        self.control.resume();
    }
    fn kill(&self) {
        self.control.end(); // detach only; the daemon keeps the terminal
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
        cancellation: &OpenCancellation,
        open_permit: &OpenPermit,
    ) -> Result<Option<Opened>, (RelayPtyErrorCode, String)> {
        let socket_dir = self.deps.socket_dir();
        let cancellation_token = cancellation.token();
        let ensured = tokio::select! {
            biased;
            _ = cancellation_token.cancelled() => {
                return Err((RelayPtyErrorCode::Failed, "terminal open cancelled".to_owned()));
            }
            result = self.deps.ensure_daemon(
                cmux_tui,
                session,
                &socket_dir,
                cwd,
                env,
                cancellation_token.clone(),
            ) => result.map_err(|message| (RelayPtyErrorCode::Failed, message))?,
        };
        let control = tokio::select! {
            biased;
            _ = cancellation_token.cancelled() => {
                return Err((RelayPtyErrorCode::Failed, "terminal open cancelled".to_owned()));
            }
            result = self.deps.connect_control(&ensured.socket_path, cancellation_token.clone()) => {
                match result {
                    Ok(control) => control,
                    Err(_) => return Ok(None), // degrade to the whole-session attach
                }
            }
        };
        let mut control_guard = ControlEndOnDrop::new(Arc::clone(&control));

        if cancellation.is_cancelled() {
            return Err((RelayPtyErrorCode::Failed, "terminal open cancelled".to_owned()));
        }
        let identify =
            request_control_with_cancellation(&control, "identify", json!({}), cancellation).await;
        if cancellation.is_cancelled() {
            return Err((RelayPtyErrorCode::Failed, "terminal open cancelled".to_owned()));
        }
        let info = identify.as_ref().filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true));
        let protocol = info
            .and_then(|v| v.get("data"))
            .and_then(|d| d.get("protocol"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        if protocol < CONTROL_MIN_PROTOCOL {
            control.end();
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
            if cancellation.is_cancelled() {
                return Err((RelayPtyErrorCode::Failed, "terminal open cancelled".to_owned()));
            }
            let listed = request_control_with_cancellation(
                &control,
                "list-workspaces",
                json!({}),
                cancellation,
            )
            .await;
            if cancellation.is_cancelled() {
                return Err((RelayPtyErrorCode::Failed, "terminal open cancelled".to_owned()));
            }
            let tabs = listed
                .as_ref()
                .filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true))
                .map(|v| collect_pty_tabs(v.get("data")))
                .unwrap_or_default();
            surface_id = tabs
                .iter()
                .find(|tab| tab.resource_id.as_deref() == Some(surface_ref))
                .map(|tab| tab.surface_id);
        }
        let Some(surface_id) = surface_id else {
            control.end();
            // Typed refusal: the terminal died with its process (or its tab
            // closed) — permanent, so clients render an ended state and
            // never offer a retry.
            return Err((
                RelayPtyErrorCode::TerminalGone,
                format!(
                    "terminal \"{surface_ref}\" not found in session \"{session}\" (it may have been closed)"
                ),
            ));
        };

        let roots_scoped = context.local_roots.as_deref().is_some_and(|r| !r.is_empty())
            || server_roots.is_some_and(|r| !r.is_empty());
        if roots_scoped {
            if cancellation.is_cancelled() {
                return Err((RelayPtyErrorCode::Failed, "terminal open cancelled".to_owned()));
            }
            let info = request_control_with_cancellation(
                &control,
                "process-info",
                json!({ "surface": surface_id }),
                cancellation,
            )
            .await;
            if cancellation.is_cancelled() {
                return Err((RelayPtyErrorCode::Failed, "terminal open cancelled".to_owned()));
            }
            let actual = info
                .as_ref()
                .filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true))
                .and_then(|v| v.get("data"))
                .and_then(|v| v.get("cwd"))
                .and_then(Value::as_str);
            if actual.is_none_or(|value| value.is_empty() || !Path::new(value).is_absolute()) {
                control.end();
                return Err((
                    RelayPtyErrorCode::Failed,
                    "cannot prove existing surface cwd is within allowed roots".to_owned(),
                ));
            }
            let Some(actual) = actual else {
                control.end();
                return Err((
                    RelayPtyErrorCode::Failed,
                    "cannot prove existing surface cwd is within allowed roots".to_owned(),
                ));
            };
            if scoped_cwd(Some(actual), &self.home, context.local_roots.as_deref(), server_roots)
                .is_err()
            {
                control.end();
                return Err((
                    RelayPtyErrorCode::Failed,
                    "existing surface cwd is outside allowed roots".to_owned(),
                ));
            }
        }

        let stream = Arc::new(TerminalStream::new());
        if cancellation.is_cancelled() {
            return Err((RelayPtyErrorCode::Failed, "terminal open cancelled".to_owned()));
        }
        let event_stream = Arc::clone(&stream);
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
                "detached" => event_stream.finish_exit(0),
                _ => {}
            }
        }));
        let close_stream = Arc::clone(&stream);
        control.on_close(Box::new(move || close_stream.finish_exit(0)));

        let attach_params = if capabilities.iter().any(|c| c == "attach-initial-size") {
            json!({ "surface": surface_id, "cols": cols, "rows": rows })
        } else {
            json!({ "surface": surface_id })
        };
        let attached = control.request("attach-surface", attach_params).await;
        if attached.as_ref().and_then(|v| v.get("ok")).and_then(Value::as_bool) != Some(true) {
            control.end();
            let reason = attached
                .as_ref()
                .and_then(|v| v.get("error"))
                .and_then(Value::as_str)
                .unwrap_or("no reply");
            return Err((
                RelayPtyErrorCode::Failed,
                format!("attach-surface failed for terminal \"{surface_ref}\": {reason}"),
            ));
        }

        let proxy = Arc::new(ControlTerminalControl { control, surface_id });
        control_guard.disarm();
        let (on_data, _) = self.sinks(pty_id, context);
        let relay = Arc::clone(&self);
        let context_for_exit = context.clone();
        let pty_id_for_exit = pty_id.to_owned();
        let stream_for_exit = Arc::clone(&stream);
        let on_exit: ExitSink = Arc::new(move |code| {
            if stream_for_exit.overflowed() {
                relay.close(&pty_id_for_exit);
                send_pty_error(
                    &context_for_exit,
                    &pty_id_for_exit,
                    "overflow",
                    "pty output backlog overflowed; reattach to continue receiving output",
                );
            } else {
                relay.emit_exit(&pty_id_for_exit, code, &context_for_exit);
            }
        });
        let start_stream = Arc::clone(&stream);
        Ok(Some(Opened {
            created: ensured.created,
            surface: Some(surface_ref.to_owned()),
            control: Some(proxy),
            closing: Some(Arc::new(AtomicBool::new(false))),
            start: Some(Box::new(move || start_stream.go_live(on_data, on_exit))),
            cleanup_on_drop: true,
        }))
    }

    async fn list_surfaces(self: Arc<Self>, frame: &Value, context: &FrameContext) {
        if context.cancellation.is_cancelled() {
            return;
        }
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
            if context.cancellation.is_cancelled() {
                return;
            }
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
            for terminal in
                self.list_session_terminals(&socket_path, &home, context.cancellation.clone()).await
            {
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
        let Some(auth) = self.auth_for_transport(context) else { return };
        if !self.tunnel_authority_generation_current(context)
            || !self.transport_auth_is_current(context, &auth)
        {
            return;
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
        cancellation: CancellationToken,
    ) -> Vec<(String, String)> {
        let Ok(control) = self.deps.connect_control(socket_path, cancellation.clone()).await else {
            return Vec::new();
        };
        let mut control_guard = ControlEndOnDrop::new(Arc::clone(&control));
        let identify = tokio::select! {
            _ = cancellation.cancelled() => return Vec::new(),
            result = control.request("identify", json!({})) => result,
        };
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
        let listed = tokio::select! {
            _ = cancellation.cancelled() => return Vec::new(),
            result = control.request("list-workspaces", json!({})) => result,
        };
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
                let proc = tokio::select! {
                    _ = cancellation.cancelled() => return Vec::new(),
                    result = control.request("process-info", json!({ "surface": tab.surface_id })) => result,
                };
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
        control_guard.disarm();
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
    use std::sync::{Arc as TestArc, Barrier, Mutex as StdMutex, mpsc::sync_channel};
    use std::thread;
    use std::time::Duration;

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
    /// JS fakePty. Records writes/resizes/pause/kill for assertions.
    #[derive(Default)]
    struct FakeState {
        on_data: Option<DataSink>,
        on_exit: Option<ExitSink>,
        written: Vec<Vec<u8>>,
        resized: Vec<(u16, u16)>,
        paused: bool,
        killed: bool,
    }

    #[derive(Clone)]
    struct FakePty {
        state: Arc<StdMutex<FakeState>>,
        spawn_file: String,
        spawn_cwd: PathBuf,
        spawn_term: String,
        cancel_on_subscribe: Arc<AtomicBool>,
        cancellation: CancellationToken,
    }

    impl FakePty {
        fn emit(&self, text: &str) {
            let sink = self.state.lock().unwrap().on_data.clone();
            if let Some(sink) = sink {
                sink(Bytes::copy_from_slice(text.as_bytes()));
            }
        }
        fn emit_while_paused(&self, text: &str) {
            self.emit(text);
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
        fn kill(&self) {
            self.state.lock().unwrap().killed = true;
        }
    }

    impl PtyOutput for FakePty {
        fn subscribe(&self, on_data: DataSink, on_exit: ExitSink) {
            let mut state = self.state.lock().unwrap();
            state.on_data = Some(on_data);
            state.on_exit = Some(on_exit);
            if self.cancel_on_subscribe.swap(false, Ordering::SeqCst) {
                self.cancellation.cancel();
            }
        }
    }

    struct BlockingControl {
        entered: Arc<Barrier>,
        release: Arc<Barrier>,
    }

    impl PtyControl for BlockingControl {
        fn write(&self, _data: &[u8]) {
            self.entered.wait();
            self.release.wait();
        }

        fn resize(&self, _cols: u16, _rows: u16) {}
        fn pause(&self) {}
        fn resume(&self) {}
        fn kill(&self) {}
    }

    /// Pauses provider resolution after the open reservation is published.
    /// This gives lifecycle tests a deterministic boundary at which a
    /// transport can detach while its provider task is still in flight.
    struct ResolveGate {
        entered: Arc<Notify>,
        release: Arc<Notify>,
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
        resolve_gate: Option<Arc<ResolveGate>>,
        cancel_on_subscribe: Arc<AtomicBool>,
    }

    #[async_trait]
    impl PtyDeps for FakeDeps {
        async fn spawn_pty(
            &self,
            spec: SpawnSpec,
            cancellation: CancellationToken,
            _permit: OpenPermit,
        ) -> PtyHandle {
            let pty = FakePty {
                state: Arc::new(StdMutex::new(FakeState::default())),
                spawn_file: spec.file.clone(),
                spawn_cwd: spec.cwd.clone(),
                spawn_term: spec.env.get("TERM").cloned().unwrap_or_default(),
                cancel_on_subscribe: Arc::clone(&self.cancel_on_subscribe),
                cancellation,
            };
            self.recorded.lock().unwrap().spawned.push(pty.clone());
            let control: Arc<dyn PtyControl> = Arc::new(pty.clone());
            let output: Arc<dyn PtyOutput> = Arc::new(pty);
            PtyHandle { control, output, banner: None }
        }
        async fn resolve_cmux_tui(&self, _cancellation: CancellationToken) -> Option<CmuxTui> {
            if let Some(gate) = &self.resolve_gate {
                gate.entered.notify_one();
                gate.release.notified().await;
            }
            self.resolve.clone()
        }
        async fn ensure_daemon(
            &self,
            _cmux_tui: &CmuxTui,
            session: &str,
            socket_dir: &Path,
            _cwd: &Path,
            _env: &HashMap<String, String>,
            _cancellation: CancellationToken,
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
            _cancellation: CancellationToken,
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
        cancel_on_subscribe: Arc<AtomicBool>,
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
        harness_with_control_and_gate(resolve, read_dir, ensure_socket_path, control, None)
    }

    fn harness_with_control_and_gate(
        resolve: Option<CmuxTui>,
        read_dir: Option<Vec<String>>,
        ensure_socket_path: Option<PathBuf>,
        control: Option<Arc<dyn ControlHandle>>,
        resolve_gate: Option<Arc<ResolveGate>>,
    ) -> Harness {
        let home = TestDirectory::new("harness");
        let home_path = home.path.clone();
        let env = env_map(&home_path);
        let recorded = Arc::new(StdMutex::new(Recorded::default()));
        let cancel_on_subscribe = Arc::new(AtomicBool::new(false));
        let socket_dir = PathBuf::from("/run/cmux-tui-501");
        let deps = Arc::new(FakeDeps {
            env: env.clone(),
            recorded: Arc::clone(&recorded),
            resolve,
            socket_dir,
            read_dir,
            ensure_socket_path,
            control,
            resolve_gate,
            cancel_on_subscribe: Arc::clone(&cancel_on_subscribe),
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
            cancel_on_subscribe,
        }
    }

    impl Harness {
        fn context(&self, trust: &str, owner: Option<String>) -> FrameContext {
            let sent = Arc::clone(&self.sent);
            let buffered = Arc::clone(&self.buffered);
            FrameContext {
                send: Arc::new(move |frame| sent.lock().unwrap().push(frame)),
                buffered_amount: Arc::new(move || buffered.load(Ordering::SeqCst)),
                trust: trust.to_owned(),
                local_roots: None,
                owner_user_id: owner,
                transport_id: None,
                cancellation: CancellationToken::new(),
                transport_kind: TransportKind::Legacy,
                auth_generation: None,
            }
        }

        fn context_with_transport(
            &self,
            trust: &str,
            owner: Option<String>,
            transport_id: Option<&str>,
        ) -> FrameContext {
            let mut context = self.context(trust, owner);
            context.transport_id = transport_id.map(str::to_owned);
            context.transport_kind =
                transport_id.map_or(TransportKind::Legacy, |_| TransportKind::Relay);
            context.auth_generation = transport_id.map(|_| 0);
            context
        }

        async fn open_with_transport(&self, pty_id: &str, session: &str, transport_id: &str) {
            let frame = serde_json::json!({
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
            let context =
                self.context_with_transport("supervised", self.owner.clone(), Some(transport_id));
            self.manager.update_transport_auth(&context);
            self.manager.handle_frame(&frame, &context).await;
        }

        async fn open(
            &self,
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
            self.manager.handle_frame(&frame, &self.context(trust, owner)).await;
        }

        async fn frame(&self, frame: Value) {
            self.manager
                .handle_frame(&frame, &self.context("supervised", self.owner.clone()))
                .await;
        }

        async fn frame_as(&self, frame: Value, trust: &str, owner: Option<String>) {
            self.manager.handle_frame(&frame, &self.context(trust, owner)).await;
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
    async fn unknown_trust_refuses_before_a_pty_is_spawned() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "forged-trust", h.owner.clone()).await;
        let sent = h.sent();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0]["type"], "pty_error");
        assert_eq!(sent[0]["code"], "trust_refused");
        assert!(h.spawned().is_empty(), "malformed authority must not allocate a PTY");
    }

    #[tokio::test]
    async fn unknown_trust_cannot_reuse_existing_attachment_authority() {
        let h = harness(None, None);
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });
        let mut trusted = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        trusted.transport_kind = TransportKind::Tunnel;
        h.manager.update_transport_auth(&trusted);
        h.manager.handle_frame(&frame, &trusted).await;
        let pty = h.spawned()[0].clone();

        let input = serde_json::json!({
            "type": "pty_input",
            "ptyId": "p1",
            "dataB64": b64("must-not-write"),
        });
        let mut forged =
            h.context_with_transport("forged-trust", h.owner.clone(), Some("tunnel-a"));
        forged.transport_kind = TransportKind::Tunnel;
        h.manager.handle_frame(&input, &forged).await;

        assert!(pty.state.lock().unwrap().written.is_empty());
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
        assert!(!pty.state.lock().unwrap().paused);
        h.frame(serde_json::json!({ "type": "pty_flow", "ptyId": "p1", "pause": false })).await;
        assert!(!pty.state.lock().unwrap().paused);
    }

    #[tokio::test]
    async fn cancelled_shell_spawn_is_not_cached() {
        let h = harness(None, None);
        let cancellation = h.manager.new_open_cancellation().expect("open attempt token");
        cancellation.cancel();
        let context = h.context("supervised", h.owner.clone());
        let env = env_map(&h.home);
        let open_permit = OpenPermit::new(
            h.manager.inner.open_slots.clone().try_acquire_owned().expect("open permit"),
        );

        // The fake returns a handle even for a cancelled token. This models a
        // blocking provider that finishes its spawn while cancellation wins.
        let result = Arc::clone(&h.manager.inner)
            .open_shell(
                "cancelled",
                80,
                24,
                &h.home,
                &env,
                "p1",
                None,
                &context,
                &cancellation,
                &open_permit,
            )
            .await;

        assert_eq!(result.err().as_deref(), Some("terminal open cancelled"));
        assert!(h.manager.inner.shell_sessions.lock().unwrap().is_empty());
        assert!(h.manager.inner.shell_starting.lock().unwrap().is_empty());
        let spawned = h.spawned();
        assert_eq!(spawned.len(), 1);
        assert!(spawned[0].state.lock().unwrap().killed);
    }

    #[tokio::test]
    async fn cancellation_during_shell_subscribe_is_not_cached_and_killed() {
        let h = harness(None, None);
        h.cancel_on_subscribe.store(true, Ordering::SeqCst);
        let cancellation = h.manager.new_open_cancellation().expect("open attempt token");
        let context = h.context("supervised", h.owner.clone());
        let env = env_map(&h.home);
        let open_permit = OpenPermit::new(
            h.manager.inner.open_slots.clone().try_acquire_owned().expect("open permit"),
        );

        // The fake cancels from inside subscribe, after the session callbacks
        // have been installed. The completed open must remove only its own
        // cached session and kill the newly spawned child.
        let result = Arc::clone(&h.manager.inner)
            .open_shell(
                "cancelled-subscribe",
                80,
                24,
                &h.home,
                &env,
                "p1",
                None,
                &context,
                &cancellation,
                &open_permit,
            )
            .await;

        assert_eq!(result.err().as_deref(), Some("terminal open cancelled"));
        assert!(h.manager.inner.shell_sessions.lock().unwrap().is_empty());
        assert!(h.manager.inner.shell_starting.lock().unwrap().is_empty());
        let spawned = h.spawned();
        assert_eq!(spawned.len(), 1);
        assert!(spawned[0].state.lock().unwrap().killed);
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
        h.spawned()[0].exit(3);
        let exit = &h.sent()[1];
        assert_eq!(exit["type"], "pty_exit");
        assert_eq!(exit["code"], 3);
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
            resolve_gate: None,
            cancel_on_subscribe: Arc::new(AtomicBool::new(false)),
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
            cancel_on_subscribe: Arc::new(AtomicBool::new(false)),
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
    async fn paused_shell_viewer_does_not_receive_continued_output() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        let pty = h.spawned()[0].clone();

        h.frame(serde_json::json!({ "type": "pty_flow", "ptyId": "p1", "pause": true })).await;
        let before = h.sent().len();
        pty.emit_while_paused("continued output");
        let continued: Vec<(String, String)> = h.sent()[before..]
            .iter()
            .filter(|frame| ty(frame) == "pty_output")
            .map(|frame| {
                (
                    frame["ptyId"].as_str().unwrap().to_owned(),
                    from_b64(frame["dataB64"].as_str().unwrap()),
                )
            })
            .collect();
        assert_eq!(continued, vec![("p2".to_owned(), "continued output".to_owned())]);

        let before_resume = h.sent().len();
        h.frame(serde_json::json!({ "type": "pty_flow", "ptyId": "p1", "pause": false })).await;
        let replayed: Vec<(String, String)> = h.sent()[before_resume..]
            .iter()
            .filter(|frame| ty(frame) == "pty_output")
            .map(|frame| {
                (
                    frame["ptyId"].as_str().unwrap().to_owned(),
                    from_b64(frame["dataB64"].as_str().unwrap()),
                )
            })
            .collect();
        assert_eq!(replayed, vec![("p1".to_owned(), "continued output".to_owned())]);
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
        assert_eq!(last["code"], "failed");
        assert!(!pty.state.lock().unwrap().killed);
        h.buffered.store(0, Ordering::SeqCst);
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        let reopened =
            h.sent().into_iter().find(|f| ty(f) == "pty_opened" && f["ptyId"] == "p2").unwrap();
        assert_eq!(reopened["created"], false);
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

    /// A control plane that accepts a request but never answers until the
    /// test releases it. This models a daemon that wedged after connect.
    struct HangingControl {
        started: Arc<Notify>,
        release: Arc<Notify>,
    }

    impl ControlHandle for HangingControl {
        fn request(
            &self,
            _cmd: &str,
            _params: Value,
        ) -> std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send + '_>> {
            let started = Arc::clone(&self.started);
            let release = Arc::clone(&self.release);
            Box::pin(async move {
                started.notify_one();
                release.notified().await;
                None
            })
        }
        fn send(&self, _cmd: &str, _params: Value) {}
        fn on_event(&self, _handler: EventHandler) {}
        fn on_close(&self, _handler: CloseHandler) {}
        fn pause(&self) {}
        fn resume(&self) {}
        fn end(&self) {}
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
        // the public message is stable and contains no surface or session
        // identifiers.
        assert_eq!(error["code"], "terminal_gone");
        let decoded: crate::relay_wire::RelayPtyError =
            serde_json::from_value(error.clone()).expect("generated pty_error fixture");
        assert_eq!(decoded.code, RelayPtyErrorCode::TerminalGone);
        assert_eq!(error["message"], "terminal is no longer available");
        // A gone terminal must NOT degrade to a whole-session attach.
        assert!(!sent.iter().any(|f| ty(f) == "pty_opened"));
    }

    #[tokio::test]
    async fn existing_surface_probe_stops_when_open_is_cancelled() {
        let started = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let control = Arc::new(HangingControl {
            started: Arc::clone(&started),
            release: Arc::clone(&release),
        });
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let h = harness_with_control(Some(cmux), None, None, Some(control));
        let context = h.context("supervised", h.owner.clone());
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "surface": "resource-1",
            "cols": 80,
            "rows": 24,
        });
        let cancellation = h.manager.new_open_cancellation().expect("open attempt token");
        let task_manager = Arc::new(h.manager);
        let spawned_task_manager = Arc::clone(&task_manager);
        let task_context = context.clone();
        let task_cancellation = cancellation.clone();
        let task = tokio::spawn(async move {
            spawned_task_manager
                .handle_frame_with_open_cancellation(&frame, &task_context, Some(task_cancellation))
                .await;
        });

        started.notified().await;
        cancellation.cancel();
        task.await.unwrap();
        assert!(!task_manager.has_attachment("p1"));
        let state = task_manager.inner.opening_state.lock().unwrap();
        assert!(state.reservations.is_empty());
        assert!(state.active_openings.is_empty());
        release.notify_waiters();
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

    #[tokio::test]
    async fn a_foreign_transport_cannot_write_resize_or_close_an_owned_pty() {
        let h = harness(None, None);
        h.open_with_transport("p1", "main", "transport-a").await;
        let foreign = h.context_with_transport("supervised", h.owner.clone(), Some("transport-b"));
        let input = serde_json::json!({
            "version": 4,
            "type": "pty_input",
            "ptyId": "p1",
            "dataB64": b64("stolen"),
        });
        h.manager.handle_frame(&input, &foreign).await;
        assert!(h.spawned()[0].state.lock().unwrap().written.is_empty());
        let close = serde_json::json!({ "version": 4, "type": "pty_close", "ptyId": "p1" });
        h.manager.handle_frame(&close, &foreign).await;
        assert!(h.manager.has_attachment("p1"), "a foreign close must be a silent no-op");
        let owner = h.context_with_transport("supervised", h.owner.clone(), Some("transport-a"));
        h.manager.handle_frame(&input, &owner).await;
        assert_eq!(h.spawned()[0].written_string(0), "stolen");
        // A caller with no transport identity owns the whole manager (legacy).
        h.manager.handle_frame(&close, &h.context("supervised", h.owner.clone())).await;
        assert!(!h.manager.has_attachment("p1"));
    }

    #[tokio::test]
    async fn detached_transport_rejects_late_frames_and_allows_a_fresh_owner() {
        let h = harness(None, None);
        let old = h.context_with_transport("supervised", h.owner.clone(), Some("relay-old"));
        h.manager.update_transport_auth(&old);
        h.manager.detach_transport_kind("relay-old", TransportKind::Relay);

        let old_frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "late",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        h.manager.handle_frame(&old_frame, &old).await;
        assert!(h.spawned().is_empty(), "a detached transport must stay fenced");
        assert!(!h.manager.inner.cache_transport_auth(&old));

        let fresh = h.context_with_transport("supervised", h.owner.clone(), Some("relay-fresh"));
        h.manager.update_transport_auth(&fresh);
        let fresh_frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "fresh",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        h.manager.handle_frame(&fresh_frame, &fresh).await;
        assert_eq!(h.spawned().len(), 1, "a new transport identity remains usable");
    }

    #[tokio::test]
    async fn identified_transport_must_publish_auth_before_its_first_frame() {
        let h = harness(None, None);
        let context = h.context_with_transport("supervised", h.owner.clone(), Some("relay-new"));
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "unregistered",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });

        h.manager.handle_frame(&frame, &context).await;
        assert!(h.spawned().is_empty(), "an unregistered transport cannot open a PTY");

        h.manager.update_transport_auth(&context);
        h.manager.handle_frame(&frame, &context).await;
        assert_eq!(h.spawned().len(), 1, "published authority admits the transport");
    }

    #[tokio::test]
    async fn detached_transport_cannot_start_provider_work() {
        let gate = Arc::new(ResolveGate {
            entered: Arc::new(Notify::new()),
            release: Arc::new(Notify::new()),
        });
        let h = harness_with_control_and_gate(None, None, None, None, Some(gate));
        let context = h.context_with_transport("supervised", h.owner.clone(), Some("relay-gone"));
        h.manager.update_transport_auth(&context);
        h.manager.detach_transport_kind("relay-gone", TransportKind::Relay);

        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "late-open",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        h.manager.handle_frame(&frame, &context).await;
        assert!(h.spawned().is_empty(), "a detached transport must not reach provider setup");
    }

    #[test]
    fn transport_authority_registry_releases_every_disconnected_identity() {
        let h = harness(None, None);
        for index in 0..4096 {
            let context = h.context_with_transport(
                "supervised",
                h.owner.clone(),
                Some(&format!("relay-{index}")),
            );
            h.manager.update_transport_auth(&context);
            assert_eq!(h.manager.inner.transport_auth.lock().unwrap().len(), 1);
            context.cancellation.cancel();
            h.manager.detach_transport_kind(
                context.transport_id.as_deref().unwrap(),
                context.transport_kind,
            );
            assert!(h.manager.inner.transport_auth.lock().unwrap().is_empty());
        }
    }

    #[tokio::test]
    async fn tunnel_authority_without_a_generation_is_rejected_after_revoke() {
        let h = harness(None, None);
        let mut context =
            h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-old"));
        context.transport_kind = TransportKind::Tunnel;
        context.auth_generation = None;
        h.manager.update_transport_auth(&context);
        h.manager.set_tunnel_authority_generation(1);

        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "revoked",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        h.manager.handle_frame(&frame, &context).await;
        assert!(h.spawned().is_empty(), "a tunnel without a generation cannot survive revoke");
    }

    #[test]
    fn tunnel_operations_on_different_attachments_do_not_share_a_gate() {
        let h = harness(None, None);
        let inner = Arc::clone(&h.manager.inner);
        let entered = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let slow: Arc<dyn PtyControl> = Arc::new(BlockingControl {
            entered: Arc::clone(&entered),
            release: Arc::clone(&release),
        });
        let fast = FakePty {
            state: Arc::new(StdMutex::new(FakeState::default())),
            spawn_file: String::new(),
            spawn_cwd: PathBuf::new(),
            spawn_term: String::new(),
            cancel_on_subscribe: Arc::new(AtomicBool::new(false)),
            cancellation: CancellationToken::new(),
        };
        let owner_a =
            TransportOwner { id: Some("tunnel-a".to_owned()), kind: TransportKind::Tunnel };
        let owner_b =
            TransportOwner { id: Some("tunnel-b".to_owned()), kind: TransportKind::Tunnel };
        {
            let mut attachments = inner.attachments.lock().unwrap();
            attachments.insert(
                "p1".to_owned(),
                Attachment {
                    closing: Arc::new(AtomicBool::new(false)),
                    active_operations: Arc::new(AtomicUsize::new(0)),
                    operation_gate: Arc::new(Mutex::new(())),
                    publication_gate: Arc::new(Mutex::new(())),
                    publication_state: Arc::new(AtomicU64::new(0)),
                    control: slow,
                    actor_id: "user_owner".to_owned(),
                    owner: owner_a,
                },
            );
            attachments.insert(
                "p2".to_owned(),
                Attachment {
                    closing: Arc::new(AtomicBool::new(false)),
                    active_operations: Arc::new(AtomicUsize::new(0)),
                    operation_gate: Arc::new(Mutex::new(())),
                    publication_gate: Arc::new(Mutex::new(())),
                    publication_state: Arc::new(AtomicU64::new(0)),
                    control: Arc::new(fast),
                    actor_id: "user_owner".to_owned(),
                    owner: owner_b,
                },
            );
        }
        let mut context_a =
            h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        let mut context_b =
            h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-b"));
        context_a.transport_kind = TransportKind::Tunnel;
        context_b.transport_kind = TransportKind::Tunnel;
        h.manager.update_transport_auth(&context_a);
        h.manager.update_transport_auth(&context_b);

        let slow_inner = Arc::clone(&inner);
        let slow_context = context_a;
        let slow_thread = thread::spawn(move || {
            slow_inner.with_authorized("p1", &slow_context, "input", |attachment| {
                attachment.control.write(b"slow");
            });
        });
        entered.wait();

        let (done_tx, done_rx) = sync_channel(1);
        let fast_inner = Arc::clone(&inner);
        let fast_context = context_b;
        let fast_thread = thread::spawn(move || {
            fast_inner.with_authorized("p2", &fast_context, "input", |attachment| {
                attachment.control.write(b"fast");
            });
            done_tx.send(()).unwrap();
        });
        assert!(done_rx.recv_timeout(Duration::from_secs(1)).is_ok());
        release.wait();
        slow_thread.join().unwrap();
        fast_thread.join().unwrap();
    }

    #[test]
    fn tunnel_output_progresses_while_input_is_blocked() {
        let h = harness(None, None);
        let inner = Arc::clone(&h.manager.inner);
        let entered = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let owner = TransportOwner { id: Some("tunnel-a".to_owned()), kind: TransportKind::Tunnel };
        {
            let mut attachments = inner.attachments.lock().unwrap();
            attachments.insert(
                "p1".to_owned(),
                Attachment {
                    closing: Arc::new(AtomicBool::new(false)),
                    active_operations: Arc::new(AtomicUsize::new(0)),
                    operation_gate: Arc::new(Mutex::new(())),
                    publication_gate: Arc::new(Mutex::new(())),
                    publication_state: Arc::new(AtomicU64::new(0)),
                    control: Arc::new(BlockingControl {
                        entered: Arc::clone(&entered),
                        release: Arc::clone(&release),
                    }),
                    actor_id: "user_owner".to_owned(),
                    owner,
                },
            );
        }
        let mut context = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        context.transport_kind = TransportKind::Tunnel;
        h.manager.update_transport_auth(&context);

        let operation_inner = Arc::clone(&inner);
        let operation_context = context.clone();
        let operation = thread::spawn(move || {
            operation_inner.with_authorized("p1", &operation_context, "input", |attachment| {
                attachment.control.write(b"blocked");
            });
        });
        entered.wait();

        let (output_tx, output_rx) = sync_channel(1);
        let output_inner = Arc::clone(&inner);
        let output_context = context;
        let output = thread::spawn(move || {
            output_inner.emit_output("p1", &Bytes::from_static(b"output"), &output_context);
            output_tx.send(()).unwrap();
        });
        let progressed = output_rx.recv_timeout(Duration::from_millis(250)).is_ok();

        release.wait();
        operation.join().unwrap();
        output.join().unwrap();
        assert!(progressed, "output must not wait for a blocking PTY input operation");
        assert!(h.sent().iter().any(|frame| frame["type"] == "pty_output"));
    }

    #[test]
    fn tunnel_revocation_does_not_wait_for_a_blocking_operation() {
        let h = harness(None, None);
        let inner = Arc::clone(&h.manager.inner);
        let entered = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let owner = TransportOwner { id: Some("tunnel-a".to_owned()), kind: TransportKind::Tunnel };
        {
            let mut attachments = inner.attachments.lock().unwrap();
            attachments.insert(
                "p1".to_owned(),
                Attachment {
                    closing: Arc::new(AtomicBool::new(false)),
                    active_operations: Arc::new(AtomicUsize::new(0)),
                    operation_gate: Arc::new(Mutex::new(())),
                    publication_gate: Arc::new(Mutex::new(())),
                    publication_state: Arc::new(AtomicU64::new(0)),
                    control: Arc::new(BlockingControl {
                        entered: Arc::clone(&entered),
                        release: Arc::clone(&release),
                    }),
                    actor_id: "user_owner".to_owned(),
                    owner,
                },
            );
        }
        let mut context = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        context.transport_kind = TransportKind::Tunnel;
        h.manager.update_transport_auth(&context);

        let operation_inner = Arc::clone(&inner);
        let operation_context = context;
        let operation = thread::spawn(move || {
            operation_inner.with_authorized("p1", &operation_context, "input", |attachment| {
                attachment.control.write(b"blocked");
            });
        });
        entered.wait();

        let (done_tx, done_rx) = sync_channel(1);
        let revoke_manager = PtyManager { inner: Arc::clone(&inner) };
        let revoke = thread::spawn(move || {
            revoke_manager.detach_tunnel_transports();
            done_tx.send(()).unwrap();
        });
        let completed_without_waiting = done_rx.recv_timeout(Duration::from_millis(250)).is_ok();
        release.wait();
        operation.join().unwrap();
        revoke.join().unwrap();
        assert!(completed_without_waiting, "revocation must not wait for PTY I/O");
        assert!(!h.manager.has_attachment("p1"));
    }

    #[test]
    fn detaching_does_not_wait_for_a_blocked_output_sink() {
        let h = harness(None, None);
        let entered = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let sent = Arc::new(StdMutex::new(Vec::new()));
        let context = FrameContext {
            send: {
                let entered = Arc::clone(&entered);
                let release = Arc::clone(&release);
                Arc::new(move |frame| {
                    sent.lock().unwrap().push(frame);
                    entered.wait();
                    release.wait();
                })
            },
            buffered_amount: Arc::new(|| 0),
            trust: "supervised".to_owned(),
            local_roots: None,
            owner_user_id: h.owner.clone(),
            transport_id: Some("relay-blocked".to_owned()),
            cancellation: CancellationToken::new(),
            transport_kind: TransportKind::Relay,
            auth_generation: None,
        };
        h.manager.update_transport_auth(&context);
        let pty = FakePty {
            state: Arc::new(StdMutex::new(FakeState::default())),
            spawn_file: String::new(),
            spawn_cwd: PathBuf::new(),
            spawn_term: String::new(),
            cancel_on_subscribe: Arc::new(AtomicBool::new(false)),
            cancellation: CancellationToken::new(),
        };
        let attachment = Attachment {
            closing: Arc::new(AtomicBool::new(false)),
            active_operations: Arc::new(AtomicUsize::new(0)),
            operation_gate: Arc::new(Mutex::new(())),
            publication_gate: Arc::new(Mutex::new(())),
            publication_state: Arc::new(AtomicU64::new(0)),
            control: Arc::new(pty),
            actor_id: "user_owner".to_owned(),
            owner: TransportOwner {
                id: Some("relay-blocked".to_owned()),
                kind: TransportKind::Relay,
            },
        };
        h.manager.inner.attachments.lock().unwrap().insert("p1".to_owned(), attachment);

        let inner = Arc::clone(&h.manager.inner);
        let output_context = context.clone();
        let output = thread::spawn(move || {
            inner.emit_output("p1", &Bytes::from_static(b"blocked"), &output_context);
        });
        entered.wait();

        let manager = Arc::new(h.manager);
        let (detached_tx, detached_rx) = sync_channel(0);
        let detach_manager = Arc::clone(&manager);
        let detach = thread::spawn(move || {
            detach_manager.detach_transport_kind("relay-blocked", TransportKind::Relay);
            detached_tx.send(()).unwrap();
        });
        assert!(
            detached_rx.recv_timeout(Duration::from_millis(100)).is_ok(),
            "detach must not wait for a blocked output callback"
        );

        release.wait();
        output.join().unwrap();
        detach.join().unwrap();
    }

    #[test]
    fn an_old_open_drop_cannot_clear_a_new_owner_cancellation_marker() {
        let h = harness(None, None);
        let inner = Arc::clone(&h.manager.inner);
        let id = "reused".to_owned();
        let owner_a = OpeningOwner {
            owner: TransportOwner { id: Some("tunnel-a".to_owned()), kind: TransportKind::Tunnel },
            attempt_id: 1,
        };
        let owner_b = OpeningOwner {
            owner: TransportOwner { id: Some("tunnel-b".to_owned()), kind: TransportKind::Tunnel },
            attempt_id: 2,
        };
        let old = OpeningReservation {
            inner: Arc::clone(&inner),
            id: id.clone(),
            owner: owner_a.clone(),
            active: true,
        };
        {
            let mut state = inner.opening_state.lock().unwrap();
            state.reservations.insert(id.clone(), owner_a.clone());
            state.cancelled.insert(id.clone(), owner_a);
            state.reservations.remove(&id);
            state.reservations.insert(id.clone(), owner_b.clone());
            state.cancelled.insert(id.clone(), owner_b.clone());
        }
        drop(old);
        let state = inner.opening_state.lock().unwrap();
        assert_eq!(state.reservations.get(&id), Some(&owner_b));
        assert_eq!(state.cancelled.get(&id), Some(&owner_b));
    }

    #[test]
    fn cancelling_an_open_releases_the_reservation_before_the_task_returns() {
        let h = harness(None, None);
        let inner = Arc::clone(&h.manager.inner);
        let mut context = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        context.transport_kind = TransportKind::Tunnel;
        h.manager.update_transport_auth(&context);
        let cancellation = h.manager.new_open_cancellation().expect("open attempt token");
        let owner = OpeningOwner {
            owner: TransportOwner::from_context(&context),
            attempt_id: cancellation.attempt_id(),
        };
        let reservation = OpeningReservation {
            inner: Arc::clone(&inner),
            id: "p1".to_owned(),
            owner: owner.clone(),
            active: true,
        };
        inner.opening_state.lock().unwrap().reservations.insert("p1".to_owned(), owner.clone());

        h.manager.cancel_open("p1", &context, &cancellation);

        {
            let state = inner.opening_state.lock().unwrap();
            assert!(!state.reservations.contains_key("p1"));
            assert_eq!(state.cancelled.get("p1"), Some(&owner));
        }
        drop(reservation);
        assert!(!inner.opening_state.lock().unwrap().cancelled.contains_key("p1"));
    }

    #[test]
    fn stale_open_cancellation_cannot_touch_a_same_owner_replacement() {
        let h = harness(None, None);
        let inner = Arc::clone(&h.manager.inner);
        let mut context = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        context.transport_kind = TransportKind::Tunnel;
        let old_cancellation = h.manager.new_open_cancellation().expect("old token");
        let new_cancellation = h.manager.new_open_cancellation().expect("new token");
        let replacement = OpeningOwner {
            owner: TransportOwner::from_context(&context),
            attempt_id: new_cancellation.attempt_id(),
        };
        inner
            .opening_state
            .lock()
            .unwrap()
            .reservations
            .insert("reused".to_owned(), replacement.clone());

        // The old timeout arrives after the caller has reused the pty id on
        // the same transport. Its capability must not cancel the replacement.
        h.manager.cancel_open("reused", &context, &old_cancellation);

        let state = inner.opening_state.lock().unwrap();
        assert_eq!(state.reservations.get("reused"), Some(&replacement));
        assert!(!state.cancelled.contains_key("reused"));
        assert!(old_cancellation.is_cancelled());
        assert!(!new_cancellation.is_cancelled());
    }

    #[tokio::test]
    async fn cancelled_active_open_drop_clears_its_tombstone() {
        let h = harness(None, None);
        let inner = Arc::clone(&h.manager.inner);
        let mut context = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        context.transport_kind = TransportKind::Tunnel;
        h.manager.update_transport_auth(&context);

        let cancellation = h.manager.new_open_cancellation().expect("open attempt token");
        let owner = OpeningOwner {
            owner: TransportOwner::from_context(&context),
            attempt_id: cancellation.attempt_id(),
        };
        let active = ActiveOpening {
            inner: Arc::clone(&inner),
            id: "p1".to_owned(),
            owner: owner.clone(),
            active: true,
        };
        inner
            .opening_state
            .lock()
            .unwrap()
            .active_openings
            .insert("p1".to_owned(), (owner.clone(), cancellation.clone()));

        h.manager
            .handle_frame(&serde_json::json!({ "type": "pty_close", "ptyId": "p1" }), &context)
            .await;

        {
            let state = inner.opening_state.lock().unwrap();
            assert!(!state.active_openings.contains_key("p1"));
            assert_eq!(state.cancelled.get("p1"), Some(&owner));
        }
        drop(active);
        assert!(!inner.opening_state.lock().unwrap().cancelled.contains_key("p1"));
    }

    #[test]
    fn open_attempt_tokens_fail_closed_before_reuse_on_counter_wrap() {
        let h = harness(None, None);
        h.manager.inner.next_open_attempt.store(u64::MAX, Ordering::Relaxed);
        let last = h.manager.new_open_cancellation().expect("last unique token");
        assert_eq!(last.attempt_id(), u64::MAX);
        assert!(h.manager.new_open_cancellation().is_none());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn cancelled_open_is_fenced_before_its_task_is_first_polled() {
        let h = harness(None, None);
        let mut context = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        context.transport_kind = TransportKind::Tunnel;
        h.manager.update_transport_auth(&context);
        let manager = Arc::new(h.manager);
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        let cancellation = manager.new_open_cancellation().expect("open attempt token");
        let task_cancellation = cancellation.clone();
        let task_manager = Arc::clone(&manager);
        let task = tokio::spawn(async move {
            task_manager
                .handle_frame_with_open_cancellation(&frame, &context, Some(task_cancellation))
                .await;
        });

        // A current-thread executor does not poll the spawned task until this
        // function yields. Cancelling first proves the pre-reservation fence,
        // rather than relying on the task having installed a reservation.
        cancellation.cancel();
        task.await.unwrap();
        assert!(h.recorded.lock().unwrap().spawned.is_empty());
        assert_eq!(manager.attachment_count(), 0);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn detaching_transport_cancels_an_in_flight_open() {
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let gate =
            Arc::new(ResolveGate { entered: Arc::clone(&entered), release: Arc::clone(&release) });
        let h = harness_with_control_and_gate(None, None, None, None, Some(gate));
        let mut context = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        context.transport_kind = TransportKind::Tunnel;
        h.manager.update_transport_auth(&context);
        let manager = Arc::new(h.manager);
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        let cancellation = manager.new_open_cancellation().expect("open attempt token");
        let task_manager = Arc::clone(&manager);
        let task_context = context.clone();
        let task_cancellation = cancellation.clone();
        let task = tokio::spawn(async move {
            task_manager
                .handle_frame_with_open_cancellation(&frame, &task_context, Some(task_cancellation))
                .await;
        });

        // Provider resolution is paused only after the reservation is live.
        // Detach must signal the exact open before allowing the provider to
        // continue, independent of scheduler timing.
        entered.notified().await;
        manager.detach_transport_kind("tunnel-a", TransportKind::Tunnel);
        assert!(cancellation.is_cancelled());

        release.notify_one();
        task.await.unwrap();
        assert_eq!(manager.attachment_count(), 0);
    }

    #[tokio::test]
    async fn closing_an_in_flight_open_cancels_provider_resolution() {
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let gate =
            Arc::new(ResolveGate { entered: Arc::clone(&entered), release: Arc::clone(&release) });
        let h = harness_with_control_and_gate(None, None, None, None, Some(gate));
        let context = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        h.manager.update_transport_auth(&context);
        let manager = Arc::new(h.manager);
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        let cancellation = manager.new_open_cancellation().expect("open attempt token");
        let task_manager = Arc::clone(&manager);
        let task_context = context.clone();
        let task_cancellation = cancellation.clone();
        let task = tokio::spawn(async move {
            task_manager
                .handle_frame_with_open_cancellation(&frame, &task_context, Some(task_cancellation))
                .await;
        });

        // Provider resolution is paused only after the reservation is live.
        // Close must signal the exact open before allowing the provider to
        // continue, independent of scheduler timing.
        entered.notified().await;
        manager
            .handle_frame(&serde_json::json!({ "type": "pty_close", "ptyId": "p1" }), &context)
            .await;
        assert!(cancellation.is_cancelled());

        release.notify_one();
        task.await.unwrap();
        assert_eq!(manager.attachment_count(), 0);
    }

    #[tokio::test]
    async fn frame_context_cancellation_cancels_a_default_open() {
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let gate =
            Arc::new(ResolveGate { entered: Arc::clone(&entered), release: Arc::clone(&release) });
        let h = harness_with_control_and_gate(None, None, None, None, Some(gate));
        let context = h.context_with_transport("supervised", h.owner.clone(), Some("tunnel-a"));
        h.manager.update_transport_auth(&context);
        let manager = Arc::new(h.manager);
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        let task_manager = Arc::clone(&manager);
        let task_context = context.clone();
        let task = tokio::spawn(async move {
            task_manager.handle_frame(&frame, &task_context).await;
        });

        entered.notified().await;
        context.cancellation.cancel();
        release.notify_one();
        task.await.unwrap();
        assert_eq!(manager.attachment_count(), 0);
        assert!(manager.inner.opening_state.lock().unwrap().reservations.is_empty());
    }

    #[tokio::test]
    async fn detached_unknown_transport_rejects_a_late_frame() {
        let h = harness(None, None);
        let old = h.context_with_transport("supervised", h.owner.clone(), Some("relay-never-seen"));

        // No frame from this owner reached the manager before disconnect.
        // The absent active snapshot is enough to reject a late frame.
        h.manager.detach_transport_kind("relay-never-seen", TransportKind::Relay);

        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "late",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        h.manager.handle_frame(&frame, &old).await;

        assert!(h.spawned().is_empty(), "a disconnected owner must stay fenced");
        assert!(!h.manager.inner.cache_transport_auth(&old));
    }

    #[tokio::test]
    async fn changed_transport_auth_cancels_an_in_flight_relay_open() {
        let h = harness(None, None);
        let inner = Arc::clone(&h.manager.inner);
        let old = h.context_with_transport("supervised", h.owner.clone(), Some("relay-a"));
        h.manager.update_transport_auth(&old);

        let cancellation = h.manager.new_open_cancellation().expect("open attempt token");
        let owner = OpeningOwner {
            owner: TransportOwner::from_context(&old),
            attempt_id: cancellation.attempt_id(),
        };
        {
            let mut state = inner.opening_state.lock().unwrap();
            state.active_openings.insert("p1".to_owned(), (owner.clone(), cancellation.clone()));
        }

        let mut changed = old.clone();
        changed.trust = "observe".to_owned();
        h.manager.update_transport_auth(&changed);

        assert!(cancellation.is_cancelled());
        let state = inner.opening_state.lock().unwrap();
        assert!(!state.reservations.contains_key("p1"));
        assert!(!state.active_openings.contains_key("p1"));
        assert!(!state.cancelled.contains_key("p1"));
        drop(state);
        assert!(!inner.cache_transport_auth(&old));
        assert!(inner.cache_transport_auth(&changed));

        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "stale",
            "session": "main",
            "cols": 80,
            "rows": 24,
        });
        h.manager.handle_frame(&frame, &old).await;
        assert!(h.spawned().is_empty(), "a stale relay context must not start a PTY");
    }

    #[tokio::test]
    async fn stale_transport_identity_cannot_open_after_owner_change() {
        let h = harness(None, None);
        let old =
            h.context_with_transport("observe", Some("user_owner".to_owned()), Some("relay-a"));
        h.manager.update_transport_auth(&old);

        // The transport id and trust are unchanged, but the reconciled owner
        // changed. The old cached authority must not authorize this frame.
        let mut changed = old.clone();
        changed.owner_user_id = Some("attacker".to_owned());
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "stale-owner",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "attacker",
        });

        h.manager.handle_frame(&frame, &changed).await;

        assert!(h.spawned().is_empty(), "stale owner metadata must not authorize a PTY open");
    }

    #[tokio::test]
    async fn blocking_open_worker_keeps_its_permit_until_completion() {
        let slots = Arc::new(Semaphore::new(1));
        let permit = OpenPermit::new(slots.clone().try_acquire_owned().expect("open permit"));
        let (started_tx, started_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let worker = spawn_blocking_with_open_permit(permit, move || {
            started_tx.send(()).expect("worker start receiver");
            release_rx.recv().expect("worker release sender");
        });

        started_rx.recv_timeout(Duration::from_secs(1)).expect("blocking worker must start");
        assert!(
            slots.clone().try_acquire_owned().is_err(),
            "cancelled open capacity must stay held by the blocking worker"
        );

        release_tx.send(()).expect("worker release receiver");
        worker.await.expect("blocking worker join");
        assert!(slots.try_acquire_owned().is_ok(), "open permit returns after worker completion");
    }

    #[tokio::test]
    async fn detach_transport_releases_only_that_transports_attachments() {
        let h = harness(None, None);
        h.open_with_transport("p-relay", "relay-side", "transport-relay").await;
        h.open_with_transport("p-tunnel", "tunnel-side", "transport-tunnel").await;
        h.manager.detach_transport("transport-relay");
        assert!(!h.manager.has_attachment("p-relay"), "the relay transport's viewer must detach");
        assert!(h.manager.has_attachment("p-tunnel"), "the tunnel viewer must survive");
        h.manager.detach_all();
        assert!(!h.manager.has_attachment("p-tunnel"));
    }

    #[tokio::test]
    async fn legacy_detach_transport_does_not_cross_transport_kind() {
        let h = harness(None, None);
        h.open_with_transport("p-relay", "relay-side", "shared-id").await;

        let mut tunnel = h.context_with_transport("supervised", h.owner.clone(), Some("shared-id"));
        tunnel.transport_kind = TransportKind::Tunnel;
        h.manager.update_transport_auth(&tunnel);
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p-tunnel",
            "session": "tunnel-side",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });
        h.manager.handle_frame(&frame, &tunnel).await;

        h.manager.detach_transport("shared-id");
        assert!(!h.manager.has_attachment("p-relay"));
        assert!(h.manager.has_attachment("p-tunnel"));
    }

    #[tokio::test]
    async fn asynchronous_output_stays_bound_to_the_transport_that_opened_it() {
        let h = harness(None, None);
        let sent_a = Arc::new(StdMutex::new(Vec::<Value>::new()));
        let sent_b = Arc::new(StdMutex::new(Vec::<Value>::new()));
        let context = |sent: Arc<StdMutex<Vec<Value>>>, transport: &str| FrameContext {
            send: Arc::new(move |frame| sent.lock().unwrap().push(frame)),
            buffered_amount: Arc::new(|| 0),
            trust: "supervised".to_owned(),
            local_roots: None,
            owner_user_id: Some("user_owner".to_owned()),
            transport_id: Some(transport.to_owned()),
            cancellation: CancellationToken::new(),
            transport_kind: TransportKind::Relay,
            auth_generation: None,
        };
        let context_a = context(Arc::clone(&sent_a), "transport-a");
        let context_b = context(Arc::clone(&sent_b), "transport-b");
        h.manager.update_transport_auth(&context_a);
        h.manager.update_transport_auth(&context_b);
        let open = |pty_id: &str, session: &str| {
            serde_json::json!({
                "version": 4,
                "type": "pty_open",
                "ptyId": pty_id,
                "session": session,
                "cols": 80,
                "rows": 24,
                "actorId": "user_owner",
            })
        };
        h.manager.handle_frame(&open("p-a", "session-a"), &context_a).await;
        h.manager.handle_frame(&open("p-b", "session-b"), &context_b).await;
        let spawned = h.spawned();
        assert_eq!(spawned.len(), 2);

        spawned[0].emit("output-a");
        spawned[1].emit("output-b");
        let a = sent_a.lock().unwrap().clone();
        let b = sent_b.lock().unwrap().clone();
        assert!(a.iter().any(|frame| frame["ptyId"] == "p-a"));
        assert!(!a.iter().any(|frame| frame["ptyId"] == "p-b"));
        assert!(b.iter().any(|frame| frame["ptyId"] == "p-b"));
        assert!(!b.iter().any(|frame| frame["ptyId"] == "p-a"));
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
    fn backlog_overflow_uses_explicit_pty_error_code() {
        let harness = harness(None, None);
        let context = harness.context("supervised", harness.owner.clone());
        send_pty_error(
            &context,
            "p1",
            "overflow",
            "pty output backlog overflowed; reattach to continue receiving output",
        );
        let frame = harness.sent().pop().unwrap();
        assert_eq!(frame["type"], "pty_error");
        assert_eq!(frame["code"], "overflow");
        assert_eq!(frame["message"], "terminal output overflowed; reattach to continue");
    }

    #[test]
    fn pty_errors_never_echo_remote_diagnostics() {
        let sent = Arc::new(StdMutex::new(Vec::<Value>::new()));
        let sink = Arc::clone(&sent);
        let context = FrameContext {
            send: Arc::new(move |frame| sink.lock().unwrap().push(frame)),
            buffered_amount: Arc::new(|| 0),
            trust: "supervised".to_owned(),
            local_roots: None,
            owner_user_id: None,
            transport_id: None,
            cancellation: CancellationToken::new(),
            transport_kind: TransportKind::Legacy,
            auth_generation: None,
        };
        send_pty_error(
            &context,
            "pty-1",
            "failed",
            "attach-surface failed for terminal \"s:1\": /home/alice/.ssh/id_ed25519",
        );
        let frame = sent.lock().unwrap().pop().expect("error frame");
        assert_eq!(frame["code"], "failed");
        assert_eq!(frame["message"], "terminal operation failed");
        assert!(!frame.to_string().contains("id_ed25519"));
    }
}
