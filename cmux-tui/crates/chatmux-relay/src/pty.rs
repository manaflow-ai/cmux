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
#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::ThreadId;
use std::time::{Duration, Instant};
use tokio::sync::{Notify, oneshot};
use tokio_util::sync::CancellationToken;

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use bytes::Bytes;
use serde_json::{Value, json};

use crate::actions::{expand_path, scrubbed_env, validate_request_path};
use crate::control::ControlHandle;
use crate::relay_wire::RelayPtyErrorCode;

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
const MAX_OUTPUT_CHUNK_BYTES: usize = 256 * 1024;
const CONTROL_OPERATION_DRAIN_TIMEOUT: Duration = Duration::from_millis(250);
const PTY_INPUT_B64_CAP: usize = 4 * 1024 * 1024;

/// Random lowercase-hex identity for transports and tunnel attachments.
pub fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0_u8; bytes];
    let _ = getrandom::fill(&mut buffer);
    let mut out = String::with_capacity(bytes * 2);
    for byte in buffer {
        out.push_str(&format!("{byte:02x}"));
    }
    out
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

/// A cwd validated against the relay root policy and pinned to its directory
/// descriptor on Unix. Child processes use the descriptor, not the pathname,
/// so a same-uid rename or symlink swap cannot redirect the cwd after checks.
#[derive(Clone)]
pub struct ResolvedCwd {
    pub path: PathBuf,
    #[cfg(unix)]
    pub directory: Arc<File>,
}

#[cfg(unix)]
#[derive(Clone, Copy, PartialEq, Eq)]
struct DirectoryIdentity {
    dev: u64,
    ino: u64,
}

/// Resolve a PTY working directory and enforce every configured root list.
fn scoped_cwd(
    requested: Option<&str>,
    home: &Path,
    local_roots: Option<&[String]>,
    server_roots: Option<&[String]>,
) -> Result<ResolvedCwd, String> {
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
    if path.components().any(|component| component == std::path::Component::ParentDir) {
        return Err("cwd parent traversal is not supported".to_owned());
    }
    let path = std::fs::canonicalize(&path).map_err(|_| "cwd is not accessible".to_owned())?;
    #[cfg(unix)]
    let allowed_root_groups: Vec<Vec<Vec<DirectoryIdentity>>> =
        [local_roots.filter(|r| !r.is_empty()), server_roots.filter(|r| !r.is_empty())]
            .into_iter()
            .flatten()
            .map(|roots| {
                roots
                    .iter()
                    .filter_map(|root| {
                        let canonical_root =
                            std::fs::canonicalize(expand_path(root, home, home)).ok()?;
                        Some(open_pinned_directory(&canonical_root).ok()?.1)
                    })
                    .collect()
            })
            .collect();
    #[cfg(not(unix))]
    let allowed_root_groups: Vec<Vec<Vec<()>>> = Vec::new();
    #[cfg(not(unix))]
    for roots in [local_roots.filter(|r| !r.is_empty()), server_roots.filter(|r| !r.is_empty())]
        .into_iter()
        .flatten()
    {
        let canonical =
            std::fs::canonicalize(&path).map_err(|_| "cwd is not accessible".to_owned())?;
        if !roots.iter().map(|root| expand_path(root, home, home)).any(|root| {
            std::fs::canonicalize(root).map(|root| canonical.starts_with(root)).unwrap_or(false)
        }) {
            return Err("cwd is outside the allowed roots".to_owned());
        }
    }
    if allowed_root_groups.iter().any(|group| group.is_empty()) {
        return Err("cwd is outside the allowed roots".to_owned());
    }
    #[cfg(unix)]
    {
        let (directory, ancestry) = open_pinned_directory(&path)?;
        if allowed_root_groups
            .iter()
            .any(|group| !group.iter().any(|root| ancestry.starts_with(root)))
        {
            return Err("cwd is outside the allowed roots".to_owned());
        }
        Ok(ResolvedCwd { path, directory: Arc::new(directory) })
    }
    #[cfg(not(unix))]
    {
        if !path.is_dir() {
            return Err("cwd is not a directory".to_owned());
        }
        Ok(ResolvedCwd { path })
    }
}

#[cfg(unix)]
fn open_pinned_directory(path: &Path) -> Result<(File, Vec<DirectoryIdentity>), String> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::io::FromRawFd;

    // Linux O_PATH avoids requiring read permission. Darwin's O_EXEC combined
    // with O_DIRECTORY requests search-only directory access, so execute-only
    // cwd directories remain valid without relying on a pathname after checks.
    #[cfg(target_os = "linux")]
    const ACCESS_MODE: libc::c_int = libc::O_PATH;
    #[cfg(target_os = "macos")]
    const ACCESS_MODE: libc::c_int = libc::O_EXEC;
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    const ACCESS_MODE: libc::c_int = libc::O_RDONLY;
    let flags = ACCESS_MODE | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    let root = CString::new("/").expect("literal root path has no NUL");
    // SAFETY: `root` is a valid NUL-terminated path and `flags` requests a
    // directory descriptor with the platform-specific access mode above.
    let root_fd = unsafe { libc::open(root.as_ptr(), flags) };
    if root_fd < 0 {
        return Err("cwd is not accessible".to_owned());
    }
    // SAFETY: `root_fd` is a newly-owned descriptor from `open`.
    let mut parent = unsafe { File::from_raw_fd(root_fd) };
    let mut expected_path = PathBuf::from("/");
    let mut ancestry = Vec::new();
    for component in path.components() {
        let std::path::Component::Normal(name) = component else {
            continue;
        };
        expected_path.push(name);
        let expected =
            std::fs::metadata(&expected_path).map_err(|_| "cwd is not accessible".to_owned())?;
        ancestry.push(DirectoryIdentity { dev: expected.dev(), ino: expected.ino() });
        let name = CString::new(name.as_bytes()).map_err(|_| "cwd is not accessible".to_owned())?;
        // SAFETY: `parent` is an open directory and `name` is NUL-free.
        let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err("cwd is not accessible".to_owned());
        }
        // SAFETY: `fd` is a newly-owned descriptor from openat.
        let child = unsafe { File::from_raw_fd(fd) };
        let observed = child.metadata().map_err(|_| "cwd is not accessible".to_owned())?;
        if expected.dev() != observed.dev() || expected.ino() != observed.ino() {
            return Err("the selected folder changed; select it again".to_owned());
        }
        parent = child;
    }
    Ok((parent, ancestry))
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
    pub cwd: ResolvedCwd,
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

#[async_trait]
pub trait PtyDeps: Send + Sync {
    async fn spawn_pty(&self, spec: SpawnSpec) -> PtyHandle;
    async fn resolve_cmux_tui(&self) -> Option<CmuxTui>;
    async fn ensure_daemon(
        &self,
        cmux_tui: &CmuxTui,
        session: &str,
        socket_dir: &Path,
        cwd: &ResolvedCwd,
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
    pub trust: String,
    pub local_roots: Option<Vec<String>>,
    pub owner_user_id: Option<String>,
    /// Read current trust and owner for an attachment. Session transports
    /// update this closure's backing state after trust acknowledgements.
    pub live_auth: Arc<dyn Fn() -> LiveAuth + Send + Sync>,
    /// Identity of the transport this frame arrived on. The PtyManager is
    /// shared between the relay WebSocket and the managed tunnel listener;
    /// an attachment may only be written to, resized, flow-controlled, or
    /// closed by the transport that opened it, and a dropped transport
    /// detaches only its own attachments. `None` preserves the legacy
    /// owns-everything behavior for callers that own the whole manager.
    pub transport_id: Option<String>,
    /// Raised when the transport that requested this work disconnects.
    pub cancellation: CancellationToken,
}

#[derive(Clone, Debug, Default)]
pub struct LiveAuth {
    pub trust: String,
    pub roots: Option<Vec<String>>,
    pub owner_user_id: Option<String>,
    pub version: u64,
}

#[derive(Clone)]
struct AuthSnapshot {
    trust: String,
    roots: Option<Vec<String>>,
    owner_user_id: Option<String>,
    version: u64,
    send: Arc<dyn Fn(Value) + Send + Sync>,
    buffered_amount: Arc<dyn Fn() -> u64 + Send + Sync>,
}

enum CloseAuthorizationFailure {
    Missing,
    Denied,
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
}

/// A fallback $SHELL session: one PTY, a bounded ring, and a viewer set that
/// fans output out to every attachment (multi-viewer, tmux-style).
struct ShellSession {
    control: Arc<dyn PtyControl>,
    inner: Mutex<ShellInner>,
    banner: Option<Vec<u8>>,
}

struct ShellInner {
    ring: VecDeque<Bytes>,
    ring_size: usize,
    alive: bool,
    viewers: Vec<ViewerSink>,
}

/// A reentrant publication gate for one attachment generation. The gate
/// serializes route publication and control-operation admission across
/// threads while allowing an outbound/control callback to synchronously
/// re-enter the same route (for example, a test sink that closes the PTY).
/// A callback must not synchronously wait for another thread that needs this
/// same gate.
struct RouteGate {
    state: Mutex<RouteGateState>,
    changed: Condvar,
    async_changed: Notify,
}

#[derive(Default)]
struct RouteGateState {
    owner: Option<ThreadId>,
    depth: usize,
}

struct RouteGuard<'a> {
    gate: &'a RouteGate,
    owner: ThreadId,
}

impl RouteGate {
    fn new() -> Self {
        Self {
            state: Mutex::new(RouteGateState::default()),
            changed: Condvar::new(),
            async_changed: Notify::new(),
        }
    }

    fn lock(&self) -> RouteGuard<'_> {
        let owner = std::thread::current().id();
        let mut state = self.state.lock().expect("route gate lock");
        while state.owner.is_some_and(|current| current != owner) {
            state = self.changed.wait(state).expect("route gate wait");
        }
        state.owner = Some(owner);
        state.depth += 1;
        drop(state);
        RouteGuard { gate: self, owner }
    }

    /// Acquire the gate without blocking a Tokio worker. The critical
    /// sections protected by this gate never await, so the polling thread is
    /// stable for the lifetime of the guard and can safely re-enter through a
    /// synchronous callback.
    async fn lock_async(&self) -> RouteGuard<'_> {
        loop {
            let owner = std::thread::current().id();
            let notified = self.async_changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let mut state = self.state.lock().expect("route gate lock");
                if state.owner.is_none_or(|current| current == owner) {
                    state.owner = Some(owner);
                    state.depth += 1;
                    return RouteGuard { gate: self, owner };
                }
            }
            notified.await;
        }
    }

    fn held_by_current_thread(&self) -> bool {
        self.state
            .lock()
            .expect("route gate lock")
            .owner
            .is_some_and(|owner| owner == std::thread::current().id())
    }
}

impl Drop for RouteGuard<'_> {
    fn drop(&mut self) {
        let mut state = self.gate.state.lock().expect("route gate lock");
        debug_assert_eq!(state.owner, Some(self.owner));
        state.depth = state.depth.saturating_sub(1);
        if state.depth == 0 {
            state.owner = None;
            self.gate.changed.notify_all();
            self.gate.async_changed.notify_waiters();
        }
    }
}

#[derive(Clone)]
struct Attachment {
    closing: Arc<AtomicBool>,
    close_pending: Arc<AtomicBool>,
    /// Releases this attachment (detach a viewer, close a control stream,
    /// kill a viewer PTY) — never kills a shared session.
    control: Arc<dyn PtyControl>,
    actor_id: String,
    cwd: PathBuf,
    auth_version: u64,
    /// Transport that opened this attachment (see FrameContext::transport_id).
    transport_id: Option<String>,
    generation: u64,
    publication_gate: Arc<RouteGate>,
    control_ops: Arc<ControlOperationState>,
}

struct ControlOperationState {
    active: AtomicUsize,
    wait_lock: Mutex<()>,
    owners: Mutex<HashMap<ThreadId, usize>>,
    changed: Condvar,
    async_changed: Notify,
}

impl ControlOperationState {
    fn new() -> Self {
        Self {
            active: AtomicUsize::new(0),
            wait_lock: Mutex::new(()),
            owners: Mutex::new(HashMap::new()),
            changed: Condvar::new(),
            async_changed: Notify::new(),
        }
    }

    fn begin(&self) {
        let _wait = self.wait_lock.lock().expect("control operation wait lock");
        self.active.fetch_add(1, Ordering::AcqRel);
        let owner = std::thread::current().id();
        *self.owners.lock().expect("control operation owners lock").entry(owner).or_default() += 1;
    }

    fn end(&self) {
        let _wait = self.wait_lock.lock().expect("control operation wait lock");
        let owner = std::thread::current().id();
        let mut owners = self.owners.lock().expect("control operation owners lock");
        if let Some(count) = owners.get_mut(&owner) {
            *count -= 1;
            if *count == 0 {
                owners.remove(&owner);
            }
        }
        if self.active.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.changed.notify_all();
            self.async_changed.notify_waiters();
        }
    }

    fn owned_by_current_thread(&self) -> bool {
        self.owners
            .lock()
            .expect("control operation owners lock")
            .contains_key(&std::thread::current().id())
    }

    fn wait_sync_timeout(&self, timeout: Option<Duration>) -> bool {
        if self.owned_by_current_thread() {
            return true;
        }
        let deadline = timeout.map(|duration| Instant::now() + duration);
        let mut guard = self.wait_lock.lock().expect("control operation wait lock");
        while self.active.load(Ordering::Acquire) != 0 {
            if let Some(deadline) = deadline {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return false;
                }
                let (next, result) =
                    self.changed.wait_timeout(guard, remaining).expect("control operation wait");
                guard = next;
                if result.timed_out() {
                    return false;
                }
            } else {
                guard = self.changed.wait(guard).expect("control operation wait");
            }
        }
        true
    }

    async fn wait_async(&self) {
        if self.owned_by_current_thread() {
            return;
        }
        loop {
            if self.active.load(Ordering::Acquire) == 0 {
                return;
            }
            let notified = self.async_changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.active.load(Ordering::Acquire) == 0 {
                return;
            }
            notified.await;
        }
    }
}

struct ControlOperationLease(Arc<ControlOperationState>);

impl Drop for ControlOperationLease {
    fn drop(&mut self) {
        self.0.end();
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
    /// Reservation state is one lock so close/open/drop cannot leave a stale
    /// cancellation marker between the id and marker updates.
    opening_state: Mutex<OpeningState>,
    shell_sessions: Mutex<HashMap<String, Arc<ShellSession>>>,
    shell_starting: Mutex<HashMap<String, Arc<Notify>>>,
    next_generation: AtomicU64,
}

#[derive(Default)]
struct OpeningState {
    ids: HashMap<String, OpeningEntry>,
    cancelled: HashMap<String, u64>,
}

#[derive(Clone)]
struct OpeningEntry {
    transport_id: Option<String>,
    generation: u64,
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
    generation: u64,
    active: bool,
}
impl Drop for OpeningReservation {
    fn drop(&mut self) {
        if self.active {
            let mut state = self.inner.opening_state.lock().expect("opening state lock");
            if state.ids.get(&self.id).is_some_and(|entry| entry.generation == self.generation) {
                state.ids.remove(&self.id);
            }
            if state.cancelled.get(&self.id) == Some(&self.generation) {
                state.cancelled.remove(&self.id);
            }
        }
    }
}

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
                opening_state: Mutex::new(OpeningState::default()),
                shell_sessions: Mutex::new(HashMap::new()),
                shell_starting: Mutex::new(HashMap::new()),
                next_generation: AtomicU64::new(1),
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
                next_generation: AtomicU64::new(1),
            }),
        }
    }

    /// Handle one Worker -> relay PTY frame.
    pub async fn handle_frame(&self, frame: &Value, context: &FrameContext) {
        let frame_type = frame.get("type").and_then(Value::as_str).unwrap_or_default();
        match frame_type {
            "pty_open" => self.inner.clone().open(frame, context).await,
            "pty_input" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                if !self.inner.transport_owns(pty_id, context.transport_id.as_deref()) {
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
                if let Some(attachment) = self.inner.authorize(pty_id, context, "input") {
                    self.inner
                        .with_live_attachment_async(
                            pty_id,
                            &attachment,
                            context,
                            "input",
                            |control| {
                                control.write(&data);
                            },
                        )
                        .await;
                }
            }
            "pty_resize" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                if !self.inner.transport_owns(pty_id, context.transport_id.as_deref()) {
                    return;
                }
                let (Some(cols), Some(rows)) =
                    (clamp_dim(frame.get("cols")), clamp_dim(frame.get("rows")))
                else {
                    return;
                };
                if let Some(attachment) = self.inner.authorize(pty_id, context, "resize") {
                    self.inner
                        .with_live_attachment_async(
                            pty_id,
                            &attachment,
                            context,
                            "resize",
                            |control| {
                                control.resize(cols, rows);
                            },
                        )
                        .await;
                }
            }
            "pty_flow" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                if !self.inner.transport_owns(pty_id, context.transport_id.as_deref()) {
                    return;
                }
                let pause = frame.get("pause").and_then(Value::as_bool).unwrap_or(false);
                if let Some(attachment) = self.inner.authorize(pty_id, context, "flow") {
                    self.inner
                        .with_live_attachment_async(
                            pty_id,
                            &attachment,
                            context,
                            "flow",
                            |control| {
                                if pause {
                                    control.pause();
                                } else {
                                    control.resume();
                                }
                            },
                        )
                        .await;
                }
            }
            "pty_close" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                if !self.inner.transport_owns(pty_id, context.transport_id.as_deref()) {
                    return;
                }
                self.inner.close_authorized_async(pty_id, context).await;
            }
            "surface_list" => self.inner.clone().list_surfaces(frame, context).await,
            _ => {}
        }
    }

    /// True while `pty_id` has a live attachment. The tunnel listener uses
    /// this after a pty_error reply to tell a fatal refusal (attachment gone,
    /// connection ends) from a non-fatal one (oversized input, stream lives).
    pub fn has_attachment(&self, pty_id: &str) -> bool {
        self.inner
            .attachments
            .lock()
            .expect("attach lock")
            .get(pty_id)
            .is_some_and(|attachment| !attachment.closing.load(Ordering::SeqCst))
    }

    /// Live attachment count (viewers, not sessions). Diagnostics and tests.
    pub fn attachment_count(&self) -> usize {
        self.inner.attachments.lock().expect("attach lock").len()
    }

    #[cfg(test)]
    pub(crate) fn opening_count(&self) -> usize {
        self.inner.opening_state.lock().expect("opening state lock").ids.len()
    }

    /// The relay socket dropped: release every attachment (sessions live on).
    /// Callers that own the whole manager only; a per-connection transport
    /// must use `detach_transport` so it cannot detach attachments the
    /// managed tunnel listener (or another socket) owns.
    pub fn detach_all(&self) {
        self.detach_matching(|_| true);
    }

    /// One transport dropped: release only its attachments and cancel only
    /// its in-flight opens. Sessions live on either way (docs/TERMINAL.md).
    pub fn detach_transport(&self, transport_id: &str) {
        self.detach_matching(|owner| owner == Some(transport_id));
    }

    /// Async transport teardown. Gate contention yields to Tokio instead of
    /// blocking the connection worker while a publication callback finishes.
    pub async fn detach_transport_async(&self, transport_id: &str) {
        self.detach_matching_async(|owner| owner == Some(transport_id)).await;
    }

    fn detach_matching(&self, owns: impl Fn(Option<&str>) -> bool) {
        // Openings first: close() records cancellation for a reserved id, so
        // a late open cannot install an attachment after its transport died.
        let opening_ids: Vec<(String, Option<String>, u64)> = {
            let opening = self.inner.opening_state.lock().expect("opening state lock");
            opening
                .ids
                .iter()
                .map(|(id, entry)| (id.clone(), entry.transport_id.clone(), entry.generation))
                .collect()
        };
        let attachment_ids: Vec<(String, Option<String>, u64)> = {
            let attachments = self.inner.attachments.lock().expect("attach lock");
            attachments
                .iter()
                .map(|(id, attachment)| {
                    (id.clone(), attachment.transport_id.clone(), attachment.generation)
                })
                .collect()
        };
        let mut ids: Vec<(String, Option<String>, u64)> =
            opening_ids.into_iter().filter(|(_, owner, _)| owns(owner.as_deref())).collect();
        ids.extend(attachment_ids.into_iter().filter(|(_, owner, _)| owns(owner.as_deref())));
        for (id, owner, generation) in ids {
            self.inner.close_if_transport(&id, owner.as_deref(), Some(generation));
        }
    }

    async fn detach_matching_async(&self, owns: impl Fn(Option<&str>) -> bool) {
        let opening_ids: Vec<(String, Option<String>, u64)> = {
            let opening = self.inner.opening_state.lock().expect("opening state lock");
            opening
                .ids
                .iter()
                .map(|(id, entry)| (id.clone(), entry.transport_id.clone(), entry.generation))
                .collect()
        };
        let attachment_ids: Vec<(String, Option<String>, u64)> = {
            let attachments = self.inner.attachments.lock().expect("attach lock");
            attachments
                .iter()
                .map(|(id, attachment)| {
                    (id.clone(), attachment.transport_id.clone(), attachment.generation)
                })
                .collect()
        };
        let mut ids: Vec<(String, Option<String>, u64)> =
            opening_ids.into_iter().filter(|(_, owner, _)| owns(owner.as_deref())).collect();
        ids.extend(attachment_ids.into_iter().filter(|(_, owner, _)| owns(owner.as_deref())));
        for (id, owner, generation) in ids {
            self.inner.close_if_transport_async(&id, owner.as_deref(), Some(generation)).await;
        }
    }
}

fn send_pty_error(context: &FrameContext, pty_id: &str, code: &str, message: &str) {
    (context.send)(json!({
        "version": PTY_PROTOCOL_VERSION,
        "type": "pty_error",
        "ptyId": pty_id,
        "code": code,
        "message": message,
    }));
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
    send_pty_error(context, pty_id, wire_code, message);
}

impl Inner {
    fn auth_snapshot(context: &FrameContext) -> AuthSnapshot {
        let live = (context.live_auth)();
        AuthSnapshot {
            trust: live.trust,
            roots: live.roots,
            owner_user_id: live.owner_user_id,
            version: live.version,
            send: Arc::clone(&context.send),
            buffered_amount: Arc::clone(&context.buffered_amount),
        }
    }

    async fn open(self: Arc<Self>, frame: &Value, context: &FrameContext) {
        let pty_id = frame.get("ptyId").and_then(Value::as_str).unwrap_or_default().to_owned();
        if pty_id.is_empty() {
            return;
        }
        let fail = |code: &str, message: &str| send_pty_error(context, &pty_id, code, message);
        let opening_generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        // Do not inspect the route gate while holding the attachment map. The
        // normal publication path takes RouteGate -> attachments, so this
        // preflight must run before the reservation's opening_state ->
        // attachments critical section to preserve lock ordering.
        let closing_attachment = {
            let attachments = self.attachments.lock().expect("attach lock");
            attachments.get(&pty_id).cloned()
        };
        let reentrant_replacement = closing_attachment.is_some_and(|attachment| {
            attachment.closing.load(Ordering::SeqCst)
                && attachment.publication_gate.held_by_current_thread()
        });
        let reservation_result = if reentrant_replacement {
            // A callback may synchronously re-enter OPEN for the same id
            // while publishing an exit/error. Reject that replacement,
            // because allowing it to acquire the reentrant gate would
            // publish the new generation before the old frame returns.
            Err(("bad_request", "ptyId is still publishing".to_owned()))
        } else {
            let mut opening = self.opening_state.lock().expect("opening state lock");
            let attachments = self.attachments.lock().expect("attach lock");
            let attached = attachments.get(&pty_id).is_some_and(|attachment| {
                !attachment.closing.load(Ordering::SeqCst)
                    || attachment.close_pending.load(Ordering::SeqCst)
            });
            if attached || opening.ids.contains_key(&pty_id) {
                Err(("bad_request", "ptyId is already attached".to_owned()))
            } else if attachments.values().count() + opening.ids.len() >= self.max_ptys {
                Err((
                    "session_limit",
                    format!("this relay caps concurrent terminals at {}", self.max_ptys),
                ))
            } else {
                // A prior generation may have left a cancellation marker
                // after its reservation was dropped. It cannot cancel this
                // fresh generation and is discarded while claiming the id.
                opening.cancelled.remove(&pty_id);
                opening.ids.insert(
                    pty_id.clone(),
                    OpeningEntry {
                        transport_id: context.transport_id.clone(),
                        generation: opening_generation,
                    },
                );
                Ok(())
            }
        };
        if let Err((code, message)) = reservation_result {
            fail(code, &message);
            return;
        }
        let mut reservation = OpeningReservation {
            inner: Arc::clone(&self),
            id: pty_id.clone(),
            generation: opening_generation,
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
        let trust = context.trust.clone();
        if trust.is_empty() {
            fail("trust_refused", "terminal trust is not established");
            return;
        }
        let owner = context.owner_user_id.as_deref();
        let actor = frame.get("actorId").and_then(Value::as_str).unwrap_or_default();
        if trust == "observe" && (owner.is_none() || Some(actor) != owner) {
            fail(
                "trust_refused",
                "this machine is paired at observe trust; terminals are owner-only",
            );
            return;
        }

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
                    opening_generation,
                    context,
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
        let opened = match opened {
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
                            opening_generation,
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
                            opening_generation,
                            context,
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

        if context.cancellation.is_cancelled() {
            return;
        }

        // Keep both locks held until the attachment is installed. `close`
        // takes opening_state first, so it cannot observe a gap between
        // removing the opening marker and inserting the attachment.
        let mut opening = self.opening_state.lock().expect("opening state lock");
        let mut attachments = self.attachments.lock().expect("attach lock");
        let cancelled = opening.cancelled.get(&pty_id) == Some(&opening_generation);
        if cancelled {
            opening.cancelled.remove(&pty_id);
            opening.ids.remove(&pty_id);
            drop(opening);
            drop(attachments);
            reservation.active = false;
            opened.closing.store(true, Ordering::SeqCst);
            opened.control.kill();
            return;
        }
        // A terminal callback locks its publication gate before it rechecks
        // the attachment map. Acquire the previous generation's gate before
        // replacing it, otherwise a same-ID open can overtake a blocked exit.
        if let Some(previous_gate) =
            attachments.get(&pty_id).map(|previous| Arc::clone(&previous.publication_gate))
        {
            drop(attachments);
            drop(opening);
            let _previous_publication = previous_gate.lock_async().await;
            opening = self.opening_state.lock().expect("opening state lock");
            attachments = self.attachments.lock().expect("attach lock");
            if opening.cancelled.get(&pty_id) == Some(&opening_generation) {
                opening.cancelled.remove(&pty_id);
                opening.ids.remove(&pty_id);
                drop(opening);
                drop(attachments);
                reservation.active = false;
                opened.closing.store(true, Ordering::SeqCst);
                opened.control.kill();
                return;
            }
        }
        // This is the publication linearization point. Read the live
        // authority only after waiting for any prior generation's publication
        // gate and while the opening state is held. Do not invoke the public
        // live-auth callback while the attachment map mutex is held. The
        // opening lock serializes competing reservations; reacquiring the
        // attachment map after the read keeps callbacks outside map locks.
        drop(attachments);
        let live_auth = Self::auth_snapshot(context);
        attachments = self.attachments.lock().expect("attach lock");
        if !self.auth_allows_claim(&live_auth, actor, &cwd, 0) {
            drop(opening);
            drop(attachments);
            opened.closing.store(true, Ordering::SeqCst);
            opened.control.kill();
            fail("trust_revoked", "terminal trust changed while opening");
            return;
        }
        let previous = attachments.insert(
            pty_id.clone(),
            Attachment {
                closing: opened.closing,
                close_pending: Arc::new(AtomicBool::new(false)),
                control: Arc::clone(&opened.control),
                actor_id: actor.to_owned(),
                cwd: cwd.clone(),
                auth_version: live_auth.version,
                transport_id: context.transport_id.clone(),
                generation: opened.generation,
                publication_gate: Arc::clone(&opened.publication_gate),
                control_ops: Arc::new(ControlOperationState::new()),
            },
        );
        opening.ids.remove(&pty_id);
        drop(opening);
        drop(attachments);
        if let Some(previous) = previous {
            previous.closing.store(true, Ordering::SeqCst);
            previous.control.kill();
        }
        opened.cleanup.claimed.store(true, Ordering::Release);
        reservation.active = false;
        let mut opened_frame = serde_json::Map::new();
        opened_frame.insert("version".to_owned(), Value::from(PTY_PROTOCOL_VERSION));
        opened_frame.insert("type".to_owned(), Value::from("pty_opened"));
        opened_frame.insert("ptyId".to_owned(), Value::from(pty_id.clone()));
        opened_frame.insert("session".to_owned(), Value::from(session));
        if let Some(surface) = opened.surface {
            opened_frame.insert("surface".to_owned(), Value::from(surface));
        }
        opened_frame.insert("created".to_owned(), Value::from(opened.created));
        opened_frame.insert("cols".to_owned(), Value::from(cols));
        opened_frame.insert("rows".to_owned(), Value::from(rows));
        (context.send)(Value::Object(opened_frame));

        // Output only AFTER pty_opened (ordering): banner, then scrollback
        // replay, then live bytes.
        let generation = opened.generation;
        let publication_gate = Arc::clone(&opened.publication_gate);
        let start = opened.start;
        // Do not hold the frame handler open for the lifetime of a live PTY
        // stream. Wait only until the sink is installed, then let the
        // generation fence and control kill own its lifecycle.
        let (started_tx, started_rx) = oneshot::channel();
        let start_result = std::thread::Builder::new()
            .name("chatmux-relay-pty-start".to_owned())
            .spawn(move || {
                start(Box::new(move || {
                    let _ = started_tx.send(());
                }));
            });
        if start_result.is_err() {
            self.emit_error_for_generation_async(
                context,
                &pty_id,
                generation,
                &publication_gate,
                "failed",
                "PTY output start could not be scheduled",
            )
            .await;
            return;
        }
        let _ = started_rx.await;
    }

    /// Build the per-attachment emit closures (output + exit framing).
    fn sinks(
        self: &Arc<Self>,
        pty_id: &str,
        context: &FrameContext,
        generation: u64,
        publication_gate: Arc<RouteGate>,
    ) -> (DataSink, ExitSink) {
        let output_gate = Arc::clone(&publication_gate);
        let on_data = {
            let inner = Arc::clone(self);
            let context = context.clone();
            let pty_id = pty_id.to_owned();
            Arc::new(move |chunk: Bytes| {
                inner.emit_output_for_generation(
                    &pty_id,
                    &chunk,
                    &context,
                    generation,
                    &output_gate,
                )
            }) as Arc<dyn Fn(Bytes) + Send + Sync>
        };
        let exit_gate = Arc::clone(&publication_gate);
        let on_exit = {
            let inner = Arc::clone(self);
            let context = context.clone();
            let pty_id = pty_id.to_owned();
            Arc::new(move |code: i64| {
                inner.emit_exit_for_generation(&pty_id, code, &context, generation, &exit_gate)
            }) as Arc<dyn Fn(i64) + Send + Sync>
        };
        (on_data, on_exit)
    }

    fn emit_output_for_generation(
        &self,
        pty_id: &str,
        chunk: &Bytes,
        context: &FrameContext,
        generation: u64,
        publication_gate: &Arc<RouteGate>,
    ) {
        let gate = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
                || (context.transport_id.is_some() && current.transport_id != context.transport_id)
            {
                return;
            }
            Arc::clone(&current.publication_gate)
        };
        let _publication = gate.lock();
        {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
        }
        // Trust can change after the first route check and before this
        // callback reaches the socket. Re-read authority while the generation
        // publication gate is held, then publish using that fresh snapshot.
        let live_auth = Self::auth_snapshot(context);
        let attachment = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
            current.clone()
        };
        if !self.auth_allows(&live_auth, &attachment) {
            drop(_publication);
            self.emit_error_for_generation(
                context,
                pty_id,
                generation,
                publication_gate,
                "trust_revoked",
                "PTY output refused after trust change",
            );
            return;
        }
        // Zero-byte chunks carry nothing and historically crashed the web
        // terminal's write path (D-R6-1); never put an empty frame on the wire.
        if chunk.is_empty() {
            return;
        }
        if chunk.len() > MAX_OUTPUT_CHUNK_BYTES {
            drop(_publication);
            self.emit_error_for_generation(
                context,
                pty_id,
                generation,
                publication_gate,
                "failed",
                "pty output chunk exceeds the relay frame budget",
            );
            return;
        }
        let buffered = (live_auth.buffered_amount)();
        // Admit the complete frame before sending it. The socket may accept a
        // frame exactly at the cap, but must reject one that would push the
        // buffered amount over the cap.
        if buffered.saturating_add(chunk.len() as u64) > self.output_cap {
            drop(_publication);
            self.emit_error_for_generation(
                context,
                pty_id,
                generation,
                publication_gate,
                "failed",
                &format!(
                    "dropped: {buffered} bytes buffered toward the server (cap {})",
                    self.output_cap
                ),
            );
            return;
        }
        (live_auth.send)(json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_output",
            "ptyId": pty_id,
            "dataB64": BASE64.encode(chunk),
        }));
    }

    fn emit_exit_for_generation(
        &self,
        pty_id: &str,
        code: i64,
        context: &FrameContext,
        generation: u64,
        publication_gate: &Arc<RouteGate>,
    ) {
        let initial_auth = Self::auth_snapshot(context);
        if self
            .authorize_snapshot_for_generation(pty_id, &initial_auth, context, "exit", generation)
            .is_none()
        {
            return;
        }
        let gate = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
            Arc::clone(&current.publication_gate)
        };
        let _publication = gate.lock();
        let attachment = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
            current.clone()
        };
        // A trust downgrade can race the first route check. Re-read authority
        // after acquiring the generation gate, then publish using this live
        // snapshot. The trust read is the exit frame's linearization point.
        let live_auth = Self::auth_snapshot(context);
        if !self.auth_allows(&live_auth, &attachment) {
            drop(_publication);
            self.emit_error_for_generation(
                context,
                pty_id,
                generation,
                publication_gate,
                "trust_revoked",
                "PTY exit refused after trust change",
            );
            return;
        }
        let attachment = {
            let mut attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
            current.closing.store(true, Ordering::SeqCst);
            current.clone()
        };
        (live_auth.send)(json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_exit",
            "ptyId": pty_id,
            "code": code,
        }));
        let mut attachments = self.attachments.lock().expect("attach lock");
        if attachments.get(pty_id).is_some_and(|current| {
            current.generation == generation
                && Arc::ptr_eq(&current.publication_gate, publication_gate)
        }) {
            attachments.remove(pty_id);
        }
        drop(attachments);
        drop(_publication);
        attachment.control.kill();
    }

    fn emit_error_for_generation(
        &self,
        context: &FrameContext,
        pty_id: &str,
        generation: u64,
        publication_gate: &Arc<RouteGate>,
        code: &str,
        message: &str,
    ) {
        self.emit_terminal_for_generation(pty_id, generation, publication_gate, || {
            send_pty_error(context, pty_id, code, message);
        });
    }

    async fn emit_error_for_generation_async(
        &self,
        context: &FrameContext,
        pty_id: &str,
        generation: u64,
        publication_gate: &Arc<RouteGate>,
        code: &str,
        message: &str,
    ) {
        let gate = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
            {
                return;
            }
            Arc::clone(&current.publication_gate)
        };
        let _publication = gate.lock_async().await;
        let attachment = {
            let mut attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
            current.closing.store(true, Ordering::SeqCst);
            current.clone()
        };
        send_pty_error(context, pty_id, code, message);
        let mut attachments = self.attachments.lock().expect("attach lock");
        if attachments.get(pty_id).is_some_and(|current| {
            current.generation == generation
                && Arc::ptr_eq(&current.publication_gate, publication_gate)
        }) {
            attachments.remove(pty_id);
        }
        drop(attachments);
        drop(_publication);
        attachment.control.kill();
    }

    fn emit_terminal_for_generation(
        &self,
        pty_id: &str,
        generation: u64,
        publication_gate: &Arc<RouteGate>,
        publish: impl FnOnce(),
    ) {
        let gate = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
            {
                return;
            }
            Arc::clone(&current.publication_gate)
        };
        let _publication = gate.lock();
        let attachment = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != generation
                || !Arc::ptr_eq(&current.publication_gate, publication_gate)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
            current.closing.store(true, Ordering::SeqCst);
            current.clone()
        };
        // Keep the closing attachment in the map while the terminal frame is
        // published. A same-ID open therefore cannot overtake this callback.
        publish();
        let mut attachments = self.attachments.lock().expect("attach lock");
        if attachments.get(pty_id).is_some_and(|current| {
            current.generation == generation
                && Arc::ptr_eq(&current.publication_gate, publication_gate)
        }) {
            attachments.remove(pty_id);
        }
        drop(attachments);
        drop(_publication);
        // Terminal publication retires the viewer. Killing is idempotent for
        // an already-exited PTY and releases an overflowed or revoked one.
        attachment.control.kill();
    }

    fn close_if_transport(
        &self,
        pty_id: &str,
        transport_id: Option<&str>,
        generation: Option<u64>,
    ) {
        let mut opening = self.opening_state.lock().expect("opening state lock");
        if let Some(entry) = opening.ids.get(pty_id) {
            let owns_opening =
                transport_id.is_none() || entry.transport_id.as_deref() == transport_id;
            if generation.is_none_or(|expected| entry.generation == expected) && owns_opening {
                opening.cancelled.insert(pty_id.to_owned(), entry.generation);
            }
        }
        drop(opening);
        let Some(attachment) = self.attachments.lock().expect("attach lock").get(pty_id).cloned()
        else {
            return;
        };
        if generation.is_none_or(|expected| attachment.generation == expected)
            && attachment.transport_id.as_deref() == transport_id
        {
            self.close_exact(
                pty_id,
                Some(attachment.generation),
                Some(&attachment.publication_gate),
            );
        }
    }

    /// Frame-level transport fence. Unknown ids retain the protocol's silent
    /// no-op behavior; once an id is reserved or attached, a different
    /// transport may not act on it. A `None` caller owns everything (legacy).
    fn transport_owns(&self, pty_id: &str, transport_id: Option<&str>) -> bool {
        let Some(transport_id) = transport_id else { return true };
        if let Some(owner) = self
            .opening_state
            .lock()
            .expect("opening state lock")
            .ids
            .get(pty_id)
            .map(|entry| entry.transport_id.clone())
        {
            return owner.as_deref() == Some(transport_id);
        }
        if let Some(attachment) = self.attachments.lock().expect("attach lock").get(pty_id) {
            return attachment.transport_id.as_deref() == Some(transport_id);
        }
        true
    }

    fn authorize(&self, pty_id: &str, context: &FrameContext, action: &str) -> Option<Attachment> {
        let auth = Self::auth_snapshot(context);
        self.authorize_snapshot(pty_id, &auth, context, action)
    }

    fn auth_allows(&self, auth: &AuthSnapshot, attachment: &Attachment) -> bool {
        self.auth_allows_claim(auth, &attachment.actor_id, &attachment.cwd, attachment.auth_version)
    }

    fn auth_allows_claim(
        &self,
        auth: &AuthSnapshot,
        actor_id: &str,
        cwd: &Path,
        minimum_version: u64,
    ) -> bool {
        let owner = auth.owner_user_id.as_deref();
        let roots_allow_cwd = auth.roots.as_deref().is_none_or(|roots| {
            roots.is_empty() || scoped_cwd(cwd.to_str(), &self.home, Some(roots), None).is_ok()
        });
        auth.version >= minimum_version
            && roots_allow_cwd
            && !auth.trust.is_empty()
            && (auth.trust != "observe" || (owner.is_some() && owner == Some(actor_id)))
    }

    fn authorize_snapshot(
        &self,
        pty_id: &str,
        auth: &AuthSnapshot,
        context: &FrameContext,
        action: &str,
    ) -> Option<Attachment> {
        self.authorize_snapshot_for_generation(pty_id, auth, context, action, 0)
    }

    fn with_live_attachment(
        &self,
        pty_id: &str,
        attachment: &Attachment,
        context: &FrameContext,
        action: &str,
        operation: impl FnOnce(&dyn PtyControl),
    ) {
        let _publication = attachment.publication_gate.lock();
        {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != attachment.generation
                || !Arc::ptr_eq(&current.publication_gate, &attachment.publication_gate)
                || current.closing.load(Ordering::SeqCst)
                || current.close_pending.load(Ordering::SeqCst)
            {
                return;
            }
        }
        let live_auth = Self::auth_snapshot(context);
        if !self.auth_allows(&live_auth, attachment) {
            drop(_publication);
            self.emit_error_for_generation(
                context,
                pty_id,
                attachment.generation,
                &attachment.publication_gate,
                "trust_revoked",
                &format!("PTY {action} refused after trust change"),
            );
            return;
        }
        attachment.control_ops.begin();
        let _operation = ControlOperationLease(Arc::clone(&attachment.control_ops));
        operation(attachment.control.as_ref());
    }

    async fn with_live_attachment_async(
        &self,
        pty_id: &str,
        attachment: &Attachment,
        context: &FrameContext,
        action: &str,
        operation: impl FnOnce(&dyn PtyControl),
    ) {
        let _publication = attachment.publication_gate.lock_async().await;
        {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != attachment.generation
                || !Arc::ptr_eq(&current.publication_gate, &attachment.publication_gate)
                || current.closing.load(Ordering::SeqCst)
                || current.close_pending.load(Ordering::SeqCst)
            {
                return;
            }
        }
        let live_auth = Self::auth_snapshot(context);
        if !self.auth_allows(&live_auth, attachment) {
            drop(_publication);
            self.emit_error_for_generation_async(
                context,
                pty_id,
                attachment.generation,
                &attachment.publication_gate,
                "trust_revoked",
                &format!("PTY {action} refused after trust change"),
            )
            .await;
            return;
        }
        attachment.control_ops.begin();
        let _operation = ControlOperationLease(Arc::clone(&attachment.control_ops));
        drop(_publication);
        operation(attachment.control.as_ref());
    }

    fn authorize_snapshot_for_generation(
        &self,
        pty_id: &str,
        auth: &AuthSnapshot,
        context: &FrameContext,
        action: &str,
        generation: u64,
    ) -> Option<Attachment> {
        let attachment = self.attachments.lock().expect("attach lock").get(pty_id)?.clone();
        if generation != 0 && attachment.generation != generation {
            return None;
        }
        if context.transport_id.is_some() && attachment.transport_id != context.transport_id {
            return None;
        }
        if self.auth_allows(auth, &attachment) {
            Some(attachment)
        } else {
            self.emit_error_for_generation(
                context,
                pty_id,
                attachment.generation,
                &attachment.publication_gate,
                "trust_revoked",
                &format!("PTY {action} refused after trust change"),
            );
            None
        }
    }

    /// A CLOSE from the owning transport cannot operate without authority.
    /// Retire only when a newer machine-authority generation revoked the
    /// attachment; a denied caller snapshot must leave another user's PTY.
    fn authorize_snapshot_for_close(
        &self,
        pty_id: &str,
        auth: &AuthSnapshot,
        context: &FrameContext,
        action: &str,
        generation: u64,
    ) -> Result<Attachment, CloseAuthorizationFailure> {
        let attachment = self
            .attachments
            .lock()
            .expect("attach lock")
            .get(pty_id)
            .cloned()
            .ok_or(CloseAuthorizationFailure::Missing)?;
        if generation != 0 && attachment.generation != generation {
            return Err(CloseAuthorizationFailure::Missing);
        }
        if context.transport_id.is_some() && attachment.transport_id != context.transport_id {
            return Err(CloseAuthorizationFailure::Missing);
        }
        if self.auth_allows(auth, &attachment) {
            Ok(attachment)
        } else if auth.version > attachment.auth_version {
            // A newer machine-authority generation invalidated this existing
            // attachment. Retire it so revoked state cannot keep a PTY slot.
            self.emit_error_for_generation(
                context,
                pty_id,
                attachment.generation,
                &attachment.publication_gate,
                "trust_revoked",
                &format!("PTY {action} refused after trust change"),
            );
            Err(CloseAuthorizationFailure::Denied)
        } else {
            // The caller's snapshot did not authorize CLOSE, but it is not a
            // newer authority generation. Report denial without allowing a
            // same-transport non-owner to destroy another user's PTY.
            send_pty_error(
                context,
                pty_id,
                "trust_revoked",
                &format!("PTY {action} refused after trust change"),
            );
            Err(CloseAuthorizationFailure::Denied)
        }
    }

    fn close_authorized(&self, pty_id: &str, context: &FrameContext) {
        let auth = Self::auth_snapshot(context);
        let attachment = match self.authorize_snapshot_for_close(pty_id, &auth, context, "close", 0)
        {
            Ok(attachment) => attachment,
            Err(CloseAuthorizationFailure::Denied) => return,
            Err(CloseAuthorizationFailure::Missing) => {
                // A close may race the asynchronous open before its attachment
                // is published. The transport fence ran at frame dispatch, so
                // this exact owner can cancel the pending reservation now.
                self.close_if_transport(pty_id, context.transport_id.as_deref(), None);
                return;
            }
        };
        if context.transport_id.is_some() && attachment.transport_id != context.transport_id {
            return;
        }
        self.close_exact_authorized(pty_id, &attachment, context);
    }

    async fn close_authorized_async(&self, pty_id: &str, context: &FrameContext) {
        let auth = Self::auth_snapshot(context);
        let attachment = match self
            .authorize_snapshot_for_generation_nonterminal(pty_id, &auth, context, "close", 0)
        {
            Ok(attachment) => attachment,
            Err(NonterminalAuthorizationFailure::Denied) => return,
            Err(NonterminalAuthorizationFailure::Missing) => {
                self.close_if_transport_async(pty_id, context.transport_id.as_deref(), None).await;
                return;
            }
        };
        if context.transport_id.is_some() && attachment.transport_id != context.transport_id {
            return;
        }
        self.close_exact_authorized_async(pty_id, &attachment, context).await;
    }

    async fn close_if_transport_async(
        &self,
        pty_id: &str,
        transport_id: Option<&str>,
        generation: Option<u64>,
    ) {
        let mut opening = self.opening_state.lock().expect("opening state lock");
        if let Some(entry) = opening.ids.get(pty_id) {
            let owns_opening =
                transport_id.is_none() || entry.transport_id.as_deref() == transport_id;
            if generation.is_none_or(|expected| entry.generation == expected) && owns_opening {
                opening.cancelled.insert(pty_id.to_owned(), entry.generation);
            }
        }
        drop(opening);
        let Some(attachment) = self.attachments.lock().expect("attach lock").get(pty_id).cloned()
        else {
            return;
        };
        if generation.is_none_or(|expected| attachment.generation == expected)
            && attachment.transport_id.as_deref() == transport_id
        {
            let publication_gate = Arc::clone(&attachment.publication_gate);
            let _publication = publication_gate.lock_async().await;
            let Some(current) = self.attachments.lock().expect("attach lock").get(pty_id).cloned()
            else {
                return;
            };
            if generation.is_some_and(|expected| current.generation != expected)
                || !Arc::ptr_eq(&current.publication_gate, &publication_gate)
                || current.transport_id.as_deref() != transport_id
            {
                return;
            }
            current.close_pending.store(true, Ordering::SeqCst);
            drop(_publication);
            let _ = tokio::time::timeout(
                CONTROL_OPERATION_DRAIN_TIMEOUT,
                attachment.control_ops.wait_async(),
            )
            .await;
            let _publication = publication_gate.lock_async().await;
            let Some(current) = self.attachments.lock().expect("attach lock").get(pty_id).cloned()
            else {
                return;
            };
            if generation.is_some_and(|expected| current.generation != expected)
                || !Arc::ptr_eq(&current.publication_gate, &publication_gate)
                || !current.close_pending.load(Ordering::SeqCst)
            {
                return;
            }
            let removed = {
                let mut attachments = self.attachments.lock().expect("attach lock");
                let Some(current) = attachments.get(pty_id) else { return };
                if generation.is_some_and(|expected| current.generation != expected)
                    || !Arc::ptr_eq(&current.publication_gate, &publication_gate)
                    || !current.close_pending.load(Ordering::SeqCst)
                    || current.closing.load(Ordering::SeqCst)
                {
                    return;
                }
                let removed = attachments.remove(pty_id).expect("attachment still present");
                removed.closing.store(true, Ordering::SeqCst);
                removed
            };
            drop(_publication);
            removed.control.kill();
        }
    }

    fn close_exact_authorized(
        &self,
        pty_id: &str,
        attachment: &Attachment,
        context: &FrameContext,
    ) {
        let gate = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != attachment.generation
                || !Arc::ptr_eq(&current.publication_gate, &attachment.publication_gate)
            {
                return;
            }
            Arc::clone(&current.publication_gate)
        };
        let _publication = gate.lock();
        let current = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != attachment.generation
                || !Arc::ptr_eq(&current.publication_gate, &gate)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
            current.clone()
        };
        let live_auth = Self::auth_snapshot(context);
        if !self.auth_allows(&live_auth, &current) {
            current.close_pending.store(false, Ordering::SeqCst);
            drop(_publication);
            send_pty_error(
                context,
                pty_id,
                "trust_revoked",
                "PTY close refused after trust change",
            );
            return;
        }
        current.close_pending.store(true, Ordering::SeqCst);
        drop(_publication);
        let _ = current.control_ops.wait_sync_timeout(Some(CONTROL_OPERATION_DRAIN_TIMEOUT));
        let _publication = gate.lock();
        let removed = {
            let mut attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != attachment.generation
                || !Arc::ptr_eq(&current.publication_gate, &gate)
                || !current.close_pending.load(Ordering::SeqCst)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
            let removed = attachments.remove(pty_id).expect("attachment still present");
            removed.closing.store(true, Ordering::SeqCst);
            removed
        };
        drop(_publication);
        removed.control.kill();
    }

    async fn close_exact_authorized_async(
        &self,
        pty_id: &str,
        attachment: &Attachment,
        context: &FrameContext,
    ) {
        let gate = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != attachment.generation
                || !Arc::ptr_eq(&current.publication_gate, &attachment.publication_gate)
            {
                return;
            }
            Arc::clone(&current.publication_gate)
        };
        let _publication = gate.lock_async().await;
        let Some(current) = self.attachments.lock().expect("attach lock").get(pty_id).cloned()
        else {
            return;
        };
        if current.generation != attachment.generation
            || !Arc::ptr_eq(&current.publication_gate, &gate)
            || current.closing.load(Ordering::SeqCst)
        {
            return;
        }
        current.close_pending.store(true, Ordering::SeqCst);
        drop(_publication);
        let _ = tokio::time::timeout(
            CONTROL_OPERATION_DRAIN_TIMEOUT,
            attachment.control_ops.wait_async(),
        )
        .await;
        let _publication = gate.lock_async().await;
        let Some(current) = self.attachments.lock().expect("attach lock").get(pty_id).cloned()
        else {
            return;
        };
        if current.generation != attachment.generation
            || !Arc::ptr_eq(&current.publication_gate, &gate)
            || !current.close_pending.load(Ordering::SeqCst)
        {
            return;
        }
        let live_auth = Self::auth_snapshot(context);
        if !self.auth_allows(&live_auth, &current) {
            current.close_pending.store(false, Ordering::SeqCst);
            drop(_publication);
            send_pty_error(
                context,
                pty_id,
                "trust_revoked",
                "PTY close refused after trust change",
            );
            return;
        }
        let removed = {
            let mut attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if current.generation != attachment.generation
                || !Arc::ptr_eq(&current.publication_gate, &gate)
                || !current.close_pending.load(Ordering::SeqCst)
                || current.closing.load(Ordering::SeqCst)
            {
                return;
            }
            let removed = attachments.remove(pty_id).expect("attachment still present");
            removed.closing.store(true, Ordering::SeqCst);
            removed
        };
        drop(_publication);
        removed.control.kill();
    }

    fn close_exact(
        &self,
        pty_id: &str,
        generation: Option<u64>,
        publication_gate: Option<&Arc<RouteGate>>,
    ) {
        let gate = {
            let attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if generation.is_some_and(|expected| current.generation != expected)
                || publication_gate
                    .is_some_and(|expected| !Arc::ptr_eq(&current.publication_gate, expected))
            {
                return;
            }
            Arc::clone(&current.publication_gate)
        };
        let _publication = gate.lock();
        let attachment = {
            let mut attachments = self.attachments.lock().expect("attach lock");
            let Some(current) = attachments.get(pty_id) else { return };
            if generation.is_some_and(|expected| current.generation != expected)
                || !Arc::ptr_eq(&current.publication_gate, &gate)
            {
                return;
            }
            let attachment = attachments.remove(pty_id).expect("attachment still present");
            attachment.closing.store(true, Ordering::SeqCst);
            attachment
        };
        let _ = attachment.control_ops.wait_sync_timeout(Some(CONTROL_OPERATION_DRAIN_TIMEOUT));
        drop(_publication);
        attachment.control.kill();
    }
}

/// A resolved open: what to echo, plus a deferred `start` that begins output.
struct Opened {
    created: bool,
    surface: Option<String>,
    control: Arc<dyn PtyControl>,
    closing: Arc<AtomicBool>,
    generation: u64,
    publication_gate: Arc<RouteGate>,
    cleanup: Arc<OpenedCleanup>,
    start: Box<dyn FnOnce(Box<dyn FnOnce() + Send>) + Send>,
}

struct OpenedCleanup {
    control: Arc<dyn PtyControl>,
    claimed: AtomicBool,
}

impl Drop for OpenedCleanup {
    fn drop(&mut self) {
        if !self.claimed.swap(true, Ordering::AcqRel) {
            self.control.kill();
        }
    }
}

/// Own a control connection while an OPEN operation performs cancellable
/// discovery and attach requests. Dropping the request must close the socket
/// even when no `Opened` value has been returned yet.
struct ControlGuard(Option<Arc<dyn ControlHandle>>);

impl ControlGuard {
    fn new(control: Arc<dyn ControlHandle>) -> Self {
        Self(Some(control))
    }

    fn end(&mut self) {
        if let Some(control) = self.0.take() {
            control.end();
        }
    }

    fn disarm(&mut self) -> Arc<dyn ControlHandle> {
        self.0.take().expect("control guard owns a connection")
    }
}

async fn request_control_with_cancellation(
    control_guard: &mut ControlGuard,
    cmd: &str,
    params: Value,
    cancellation: &CancellationToken,
) -> Option<Value> {
    let control = control_guard.0.as_ref()?.clone();
    tokio::select! {
        response = control.request(cmd, params) => response,
        _ = cancellation.cancelled() => {
            control_guard.end();
            None
        }
    }
}

impl Drop for ControlGuard {
    fn drop(&mut self) {
        self.end();
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
        emit_bounded_bytes(&on_data, Bytes::from(banner));
    }
    output.subscribe(on_data, on_exit);
}

fn emit_bounded_bytes(on_data: &DataSink, bytes: Bytes) {
    let mut offset = 0;
    while offset < bytes.len() {
        let end = (offset + MAX_OUTPUT_CHUNK_BYTES).min(bytes.len());
        on_data(bytes.slice(offset..end));
        offset = end;
    }
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
        cwd: &ResolvedCwd,
        env: &HashMap<String, String>,
        pty_id: &str,
        server_roots: Option<&[String]>,
        generation: u64,
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
            let mut control_guard = ControlGuard::new(Arc::clone(&control));
            let Some(listed) = request_control_with_cancellation(
                &mut control_guard,
                "list-workspaces",
                json!({}),
                &context.cancellation,
            )
            .await
            else {
                control_guard.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            };
            if listed.get("ok").and_then(Value::as_bool) != Some(true) {
                control_guard.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            }
            let Some(data) = listed.get("data").and_then(Value::as_object) else {
                control_guard.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            };
            if !data.get("workspaces").is_some_and(Value::is_array) {
                control_guard.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            }
            if !workspace_shape_valid(listed.get("data")) {
                control_guard.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            }
            let tabs = match collect_pty_tabs_strict(listed.get("data")) {
                Ok(tabs) => tabs,
                Err(_) => {
                    control_guard.end();
                    return Err("cannot inspect existing daemon surfaces".to_owned());
                }
            };
            if tabs.len() > MAX_ENUM_TERMINALS || (tabs.is_empty() && !ensured.created) {
                control_guard.end();
                return Err("cannot prove existing daemon cwd is within allowed roots".to_owned());
            }
            for tab in tabs {
                let Some(info) = request_control_with_cancellation(
                    &mut control_guard,
                    "process-info",
                    json!({ "surface": tab.surface_id }),
                    &context.cancellation,
                )
                .await
                else {
                    control_guard.end();
                    return Err("cannot inspect existing surface cwd".to_owned());
                };
                if info.get("ok").and_then(Value::as_bool) != Some(true) {
                    control_guard.end();
                    return Err("cannot inspect existing surface cwd".to_owned());
                }
                let Some(actual) =
                    info.get("data").and_then(|v| v.get("cwd")).and_then(Value::as_str)
                else {
                    control_guard.end();
                    return Err(
                        "cannot prove existing surface cwd is within allowed roots".to_owned()
                    );
                };
                if actual.is_empty() || !Path::new(actual).is_absolute() {
                    control_guard.end();
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
                    control_guard.end();
                    return Err("existing surface cwd is outside allowed roots".to_owned());
                }
            }
            control_guard.end();
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
            .spawn_pty(SpawnSpec {
                file: cmux_tui.file.clone(),
                args,
                cols,
                rows,
                cwd: cwd.clone(),
                env: env.clone(),
                cancellation: context.cancellation.clone(),
            })
            .await;
        let control = Arc::clone(&handle.control);
        let output = Arc::clone(&handle.output);
        let banner = handle.banner.clone();
        let publication_gate = Arc::new(RouteGate::new());
        let (on_data, on_exit) =
            self.sinks(pty_id, context, generation, Arc::clone(&publication_gate));
        Ok(Opened {
            created: ensured.created,
            surface: None,
            control: Arc::clone(&control),
            closing: Arc::new(AtomicBool::new(false)),
            generation,
            publication_gate,
            cleanup: Arc::new(OpenedCleanup {
                control: Arc::clone(&control),
                claimed: AtomicBool::new(false),
            }),
            start: Box::new(move |ready| {
                ready();
                drive_handle(output, banner, on_data, on_exit);
            }),
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
        cwd: &ResolvedCwd,
        env: &HashMap<String, String>,
        pty_id: &str,
        server_roots: Option<&[String]>,
        generation: u64,
        context: &FrameContext,
    ) -> Result<Opened, String> {
        let mut created = false;
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
                let handle = self
                    .deps
                    .spawn_pty(SpawnSpec {
                        file: shell,
                        args: Vec::new(),
                        cols,
                        rows,
                        cwd: cwd.clone(),
                        env: env.clone(),
                        cancellation: context.cancellation.clone(),
                    })
                    .await;
                let PtyHandle { control, output, banner } = handle;
                let shell_session = Arc::new(ShellSession {
                    control,
                    banner,
                    inner: Mutex::new(ShellInner {
                        ring: VecDeque::new(),
                        ring_size: 0,
                        alive: true,
                        viewers: Vec::new(),
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
                    let viewers_to_notify: Vec<Arc<dyn Fn(Bytes) + Send + Sync>> = {
                        let mut inner = data_session.inner.lock().expect("shell inner lock");
                        inner.ring_size += chunk.len();
                        inner.ring.push_back(chunk.clone());
                        while inner.ring_size > scrollback_limit && inner.ring.len() > 1 {
                            let Some(dropped) = inner.ring.pop_front() else { break };
                            inner.ring_size -= dropped.len();
                        }
                        inner.viewers.iter().map(|viewer| Arc::clone(&viewer.on_data)).collect()
                    };
                    for on_data in viewers_to_notify {
                        on_data(chunk.clone());
                    }
                });
                let on_session_exit: ExitSink = Arc::new(move |code: i64| {
                    let viewers = {
                        let mut inner = exit_session.inner.lock().expect("shell inner lock");
                        inner.alive = false;
                        std::mem::take(&mut inner.viewers)
                    };
                    manager.shell_sessions.lock().expect("shell lock").remove(&session_name);
                    for viewer in viewers {
                        (viewer.on_exit)(code);
                    }
                });
                output.subscribe(on_session_data, on_session_exit);
                self.shell_sessions
                    .lock()
                    .expect("shell lock")
                    .insert(session.to_owned(), Arc::clone(&shell_session));
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
        let publication_gate = Arc::new(RouteGate::new());
        let (on_data, on_exit) =
            self.sinks(pty_id, context, generation, Arc::clone(&publication_gate));

        // The per-attachment control proxies onto the session pty but its
        // kill() only unhooks this viewer (release), never the session.
        let proxy = Arc::new(ShellViewerControl {
            session: Arc::clone(&shell_session),
            viewer_id,
            released: Arc::clone(&released),
        });

        let start_session = Arc::clone(&shell_session);
        let start_gate = Arc::clone(&publication_gate);
        let start: Box<dyn FnOnce(Box<dyn FnOnce() + Send>) + Send> = Box::new(move |ready| {
            let _publication = start_gate.lock();
            let (banner, replay, alive) = {
                let mut inner = start_session.inner.lock().expect("shell inner lock");
                let banner = created.then(|| start_session.banner.clone()).flatten();
                // Clone the retained chunks, not their bytes. `Bytes` clones
                // share the backing storage, so a large scrollback replay
                // does not allocate one contiguous buffer before framing.
                let replay = (!created && inner.ring_size > 0)
                    .then(|| inner.ring.iter().cloned().collect::<Vec<Bytes>>());
                if inner.alive && !released.load(Ordering::SeqCst) {
                    inner.viewers.push(ViewerSink {
                        id: viewer_id,
                        on_data: Arc::clone(&on_data),
                        on_exit: Arc::clone(&on_exit),
                    });
                }
                (banner, replay, inner.alive)
            };
            // The viewer is installed while the publication gate is held.
            // Subsequent PTY output therefore waits behind replay callbacks.
            ready();
            if let Some(banner) = banner {
                emit_bounded_bytes(&on_data, Bytes::from(banner));
            }
            if let Some(replay) = replay {
                for chunk in replay {
                    emit_bounded_bytes(&on_data, chunk);
                }
            }
            if released.load(Ordering::SeqCst) {
                return;
            }
            if !alive {
                on_exit(0);
                return;
            }
        });

        Ok(Opened {
            created,
            surface: None,
            control: Arc::clone(&proxy),
            closing,
            generation,
            publication_gate,
            cleanup: Arc::new(OpenedCleanup {
                control: Arc::clone(&proxy),
                claimed: AtomicBool::new(false),
            }),
            start,
        })
    }
}

struct ShellViewerControl {
    session: Arc<ShellSession>,
    viewer_id: u64,
    released: Arc<AtomicBool>,
}

impl ShellViewerControl {
    fn release(&self) {
        self.released.store(true, Ordering::SeqCst);
        let mut inner = self.session.inner.lock().expect("shell inner lock");
        inner.viewers.retain(|viewer| viewer.id != self.viewer_id);
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
        self.go_live_with_ready(on_data, on_exit, || {});
    }

    fn go_live_with_ready(
        &self,
        on_data: Arc<dyn Fn(Bytes) + Send + Sync>,
        on_exit: Arc<dyn Fn(i64) + Send + Sync>,
        ready: impl FnOnce(),
    ) {
        let should_drain = {
            let mut state = self.state.lock().expect("terminal stream lock");
            state.live_data = Some(Arc::clone(&on_data));
            state.live_exit = Some(Arc::clone(&on_exit));
            state.backlog_bytes = 0;
            Self::start_delivery(&mut state)
        };
        ready();
        if should_drain {
            self.drain();
        }
    }
}

struct ControlTerminalControl {
    control: Arc<dyn ControlHandle>,
    surface_id: i64,
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
        cwd: &ResolvedCwd,
        env: &HashMap<String, String>,
        pty_id: &str,
        server_roots: Option<&[String]>,
        generation: u64,
        context: &FrameContext,
    ) -> Result<Option<Opened>, (RelayPtyErrorCode, String)> {
        let socket_dir = self.deps.socket_dir();
        let ensured = self
            .deps
            .ensure_daemon(cmux_tui, session, &socket_dir, cwd, env)
            .await
            .map_err(|message| (RelayPtyErrorCode::Failed, message))?;
        let control = match self.deps.connect_control(&ensured.socket_path).await {
            Ok(control) => control,
            Err(_) => return Ok(None), // degrade to the whole-session attach
        };
        let mut control_guard = ControlGuard::new(Arc::clone(&control));

        let identify = request_control_with_cancellation(
            &mut control_guard,
            "identify",
            json!({}),
            &context.cancellation,
        )
        .await;
        let info = identify.as_ref().filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true));
        let protocol = info
            .and_then(|v| v.get("data"))
            .and_then(|d| d.get("protocol"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        if protocol < CONTROL_MIN_PROTOCOL {
            control_guard.end();
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
            let listed = request_control_with_cancellation(
                &mut control_guard,
                "list-workspaces",
                json!({}),
                &context.cancellation,
            )
            .await;
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
            control_guard.end();
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
            let info = request_control_with_cancellation(
                &mut control_guard,
                "process-info",
                json!({ "surface": surface_id }),
                &context.cancellation,
            )
            .await;
            let actual = info
                .as_ref()
                .filter(|v| v.get("ok").and_then(Value::as_bool) == Some(true))
                .and_then(|v| v.get("data"))
                .and_then(|v| v.get("cwd"))
                .and_then(Value::as_str);
            if actual.is_none_or(|value| value.is_empty() || !Path::new(value).is_absolute()) {
                control_guard.end();
                return Err((
                    RelayPtyErrorCode::Failed,
                    "cannot prove existing surface cwd is within allowed roots".to_owned(),
                ));
            }
            let Some(actual) = actual else {
                control_guard.end();
                return Err((
                    RelayPtyErrorCode::Failed,
                    "cannot prove existing surface cwd is within allowed roots".to_owned(),
                ));
            };
            if scoped_cwd(Some(actual), &self.home, context.local_roots.as_deref(), server_roots)
                .is_err()
            {
                control_guard.end();
                return Err((
                    RelayPtyErrorCode::Failed,
                    "existing surface cwd is outside allowed roots".to_owned(),
                ));
            }
        }

        let stream = Arc::new(TerminalStream::new());
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
        let attached = request_control_with_cancellation(
            &mut control_guard,
            "attach-surface",
            attach_params,
            &context.cancellation,
        )
        .await;
        if attached.as_ref().and_then(|v| v.get("ok")).and_then(Value::as_bool) != Some(true) {
            control_guard.end();
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

        let proxy =
            Arc::new(ControlTerminalControl { control: control_guard.disarm(), surface_id });
        let publication_gate = Arc::new(RouteGate::new());
        let (on_data, _) = self.sinks(pty_id, context, generation, Arc::clone(&publication_gate));
        let relay = Arc::clone(&self);
        let context_for_exit = context.clone();
        let pty_id_for_exit = pty_id.to_owned();
        let stream_for_exit = Arc::clone(&stream);
        let exit_gate = Arc::clone(&publication_gate);
        let on_exit: ExitSink = Arc::new(move |code| {
            if stream_for_exit.overflowed() {
                relay.emit_error_for_generation(
                    &context_for_exit,
                    &pty_id_for_exit,
                    generation,
                    &exit_gate,
                    "overflow",
                    "pty output backlog overflowed; reattach to continue receiving output",
                );
            } else {
                relay.emit_exit_for_generation(
                    &pty_id_for_exit,
                    code,
                    &context_for_exit,
                    generation,
                    &exit_gate,
                );
            }
        });
        let start_stream = Arc::clone(&stream);
        Ok(Some(Opened {
            created: ensured.created,
            surface: Some(surface_ref.to_owned()),
            control: Arc::clone(&proxy),
            closing: Arc::new(AtomicBool::new(false)),
            generation,
            publication_gate,
            cleanup: Arc::new(OpenedCleanup {
                control: Arc::clone(&proxy),
                claimed: AtomicBool::new(false),
            }),
            start: Box::new(move |ready| start_stream.go_live_with_ready(on_data, on_exit, ready)),
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
    #[cfg(unix)]
    use std::os::unix::fs::MetadataExt;
    #[cfg(target_os = "macos")]
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
    use std::sync::{Arc as TestArc, Barrier, Mutex as StdMutex};
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
        write_entered: Option<TestArc<Barrier>>,
        write_release: Option<TestArc<Barrier>>,
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
            let (entered, release) = {
                let state = self.state.lock().unwrap();
                (state.write_entered.clone(), state.write_release.clone())
            };
            if let Some(entered) = entered {
                entered.wait();
            }
            if let Some(release) = release {
                release.wait();
            }
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
        }
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
                spawn_cwd: spec.cwd.path.clone(),
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
            _cwd: &ResolvedCwd,
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
        harness_with_control_and_max_ptys(resolve, read_dir, ensure_socket_path, control, MAX_PTYS)
    }

    fn harness_with_max_ptys(max_ptys: usize) -> Harness {
        harness_with_control_and_max_ptys(None, None, None, None, max_ptys)
    }

    fn harness_with_control_and_max_ptys(
        resolve: Option<CmuxTui>,
        read_dir: Option<Vec<String>>,
        ensure_socket_path: Option<PathBuf>,
        control: Option<Arc<dyn ControlHandle>>,
        max_ptys: usize,
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
            max_ptys,
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
            let sent = Arc::clone(&self.sent);
            let buffered = Arc::clone(&self.buffered);
            let live_trust = trust.to_owned();
            let live_owner = owner.clone();
            FrameContext {
                send: Arc::new(move |frame| sent.lock().unwrap().push(frame)),
                buffered_amount: Arc::new(move || buffered.load(Ordering::SeqCst)),
                trust: trust.to_owned(),
                local_roots: None,
                owner_user_id: owner,
                live_auth: Arc::new(move || LiveAuth {
                    trust: live_trust.clone(),
                    owner_user_id: live_owner.clone(),
                    ..Default::default()
                }),
                transport_id: None,
                cancellation: CancellationToken::new(),
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
    async fn stale_cancellation_marker_cannot_cancel_a_reused_open_generation() {
        let h = harness(None, None);
        let stale_generation = h.manager.inner.next_generation.fetch_add(1, Ordering::Relaxed);
        h.manager
            .inner
            .opening_state
            .lock()
            .unwrap()
            .cancelled
            .insert("p1".to_owned(), stale_generation);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        assert_eq!(h.sent()[0]["type"], "pty_opened");
        assert_eq!(h.manager.opening_count(), 0);
    }

    #[test]
    fn legacy_close_cancels_a_transport_owned_pending_open() {
        let h = harness(None, None);
        let generation = h.manager.inner.next_generation.fetch_add(1, Ordering::Relaxed);
        h.manager.inner.opening_state.lock().unwrap().ids.insert(
            "p1".to_owned(),
            OpeningEntry { transport_id: Some("transport-a".to_owned()), generation },
        );
        let started = TestArc::new(Barrier::new(2));
        let manager = Arc::clone(&h.manager.inner);
        let started_for_thread = TestArc::clone(&started);
        let close = thread::spawn(move || {
            started_for_thread.wait();
            manager.close_if_transport("p1", None, Some(generation));
        });
        started.wait();
        close.join().expect("legacy close callback");
        let state = h.manager.inner.opening_state.lock().unwrap();
        assert_eq!(state.cancelled.get("p1"), Some(&generation));
        assert_eq!(state.ids.get("p1").map(|entry| entry.generation), Some(generation));
    }

    #[tokio::test]
    async fn transport_close_checks_matching_attachment_after_other_open_reservation() {
        let h = harness(None, None);
        h.open_with_transport("p1", "main", "transport-a").await;
        let attachment_generation =
            h.manager.inner.attachments.lock().unwrap().get("p1").expect("attachment").generation;
        let replacement_generation =
            h.manager.inner.next_generation.fetch_add(1, Ordering::Relaxed);
        h.manager.inner.opening_state.lock().unwrap().ids.insert(
            "p1".to_owned(),
            OpeningEntry {
                transport_id: Some("transport-b".to_owned()),
                generation: replacement_generation,
            },
        );

        h.manager.inner.close_if_transport("p1", Some("transport-a"), Some(attachment_generation));

        assert!(!h.manager.has_attachment("p1"));
        let opening = h.manager.inner.opening_state.lock().unwrap();
        assert!(!opening.cancelled.contains_key("p1"));
        assert_eq!(
            opening.ids.get("p1").map(|entry| entry.generation),
            Some(replacement_generation)
        );
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
    async fn output_after_live_trust_downgrade_is_not_forwarded() {
        let h = harness(None, None);
        let live_auth = Arc::new(StdMutex::new(LiveAuth {
            trust: "supervised".to_owned(),
            owner_user_id: h.owner.clone(),
            ..Default::default()
        }));
        let mut context = h.context("supervised", h.owner.clone());
        let live_auth_for_context = Arc::clone(&live_auth);
        context.live_auth = Arc::new(move || live_auth_for_context.lock().unwrap().clone());
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_other",
            "trust": "supervised",
            "allowedRoots": Value::Null,
        });
        h.manager.handle_frame(&frame, &context).await;
        let pty = h.spawned()[0].clone();
        live_auth.lock().unwrap().trust = "observe".to_owned();
        pty.emit("secret");
        assert!(!h.sent().iter().any(|f| f["type"] == "pty_output"));
    }

    #[tokio::test]
    async fn output_rechecks_live_auth_after_route_admission() {
        let h = harness(None, None);
        let calls = Arc::new(AtomicUsize::new(0));
        let mut context = h.context("supervised", h.owner.clone());
        let calls_for_context = Arc::clone(&calls);
        let owner = h.owner.clone();
        context.live_auth = Arc::new(move || {
            let call = calls_for_context.fetch_add(1, Ordering::SeqCst);
            if call >= 2 {
                LiveAuth {
                    trust: "observe".to_owned(),
                    owner_user_id: owner.clone(),
                    ..Default::default()
                }
            } else {
                LiveAuth {
                    trust: "supervised".to_owned(),
                    owner_user_id: owner.clone(),
                    ..Default::default()
                }
            }
        });
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_other",
        });
        h.manager.handle_frame(&frame, &context).await;
        let pty = h.spawned()[0].clone();
        pty.emit("secret");
        assert!(!h.sent().iter().any(|f| f["type"] == "pty_output"));
        assert!(h.sent().iter().any(|f| f["code"] == "trust_revoked"));
    }

    #[tokio::test]
    async fn live_trust_rejection_clears_open_reservation() {
        let h = harness(None, None);
        let mut context = h.context("supervised", h.owner.clone());
        context.live_auth = Arc::new(|| LiveAuth {
            trust: "observe".to_owned(),
            owner_user_id: Some("user_owner".to_owned()),
            ..Default::default()
        });
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_other",
        });
        h.manager.handle_frame(&frame, &context).await;
        assert_eq!(h.manager.opening_count(), 0);
        assert!(!h.manager.has_attachment("p1"));
        assert!(h.sent().iter().any(|frame| frame["code"] == "trust_revoked"));
    }

    #[tokio::test]
    async fn live_root_restriction_rejects_open_before_publication() {
        let h = harness(None, None);
        let allowed = h.home.join("allowed");
        std::fs::create_dir(&allowed).expect("create allowed root");
        let mut context = h.context("supervised", h.owner.clone());
        let owner = h.owner.clone();
        context.live_auth = Arc::new(move || LiveAuth {
            trust: "supervised".to_owned(),
            roots: Some(vec![allowed.to_string_lossy().into_owned()]),
            owner_user_id: owner.clone(),
            version: 1,
        });
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });

        h.manager.handle_frame(&frame, &context).await;

        assert_eq!(h.manager.opening_count(), 0);
        assert!(!h.manager.has_attachment("p1"));
        assert!(h.sent().iter().any(|frame| frame["code"] == "trust_revoked"));
    }

    #[tokio::test]
    async fn close_requires_current_trust() {
        let h = harness(None, None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let mut revoked = h.context("", h.owner.clone());
        let owner = h.owner.clone();
        revoked.live_auth = Arc::new(move || LiveAuth {
            trust: String::new(),
            owner_user_id: owner.clone(),
            version: 1,
            ..Default::default()
        });
        h.manager
            .handle_frame(&serde_json::json!({"type":"pty_close","ptyId":"p1"}), &revoked)
            .await;
        assert!(h.sent().iter().any(|f| f["code"] == "trust_revoked"));
        assert!(!h.manager.has_attachment("p1"));
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
    async fn large_scrollback_replay_is_split_into_bounded_frames() {
        let home = TestDirectory::new("large-scrollback");
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
        let manager = PtyManager::with_limits(
            deps,
            home_path.clone(),
            env,
            MAX_PTYS,
            MAX_OUTPUT_CHUNK_BYTES * 2 + 5,
            OUTPUT_BUFFER_CAP,
        );
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
        pty.emit(&"x".repeat(MAX_OUTPUT_CHUNK_BYTES * 2 + 5));
        let before = h.sent().len();
        h.open("p2", "main", Value::Null, "supervised", h.owner.clone()).await;
        let frames: Vec<Value> = h.sent()[before..]
            .iter()
            .filter(|frame| frame["type"] == "pty_output")
            .cloned()
            .collect();
        assert!(frames.len() >= 2);
        assert!(frames.iter().all(|frame| {
            BASE64
                .decode(frame["dataB64"].as_str().unwrap_or_default())
                .map(|bytes| bytes.len() <= MAX_OUTPUT_CHUNK_BYTES)
                .unwrap_or(false)
        }));
        assert!(!h.sent().iter().any(|frame| frame["code"] == "failed"));
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

    struct HangingControl {
        ended: Arc<AtomicUsize>,
    }

    impl ControlHandle for HangingControl {
        fn request(
            &self,
            _cmd: &str,
            _params: Value,
        ) -> std::pin::Pin<Box<dyn Future<Output = Option<Value>> + Send + '_>> {
            Box::pin(std::future::pending())
        }
        fn send(&self, _cmd: &str, _params: Value) {}
        fn on_event(&self, _handler: EventHandler) {}
        fn on_close(&self, _handler: CloseHandler) {}
        fn pause(&self) {}
        fn resume(&self) {}
        fn end(&self) {
            self.ended.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[tokio::test]
    async fn cancelled_control_request_ends_guard_once() {
        let ended = Arc::new(AtomicUsize::new(0));
        let control: Arc<dyn ControlHandle> =
            Arc::new(HangingControl { ended: Arc::clone(&ended) });
        let mut guard = ControlGuard::new(control);
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        assert!(
            request_control_with_cancellation(&mut guard, "identify", Value::Null, &cancellation)
                .await
                .is_none()
        );
        assert_eq!(ended.load(Ordering::SeqCst), 1);
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
        assert!(error["message"].as_str().unwrap_or_default().contains("not found in session"),);
        // A gone terminal must NOT degrade to a whole-session attach.
        assert!(!sent.iter().any(|f| ty(f) == "pty_opened"));
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
    async fn denied_close_does_not_remove_attachment() {
        let h = harness(None, None);
        h.open_with_transport("p1", "main", "transport-a").await;
        let denied =
            h.context_with_transport("observe", Some("other-user".to_owned()), Some("transport-a"));
        let close = serde_json::json!({ "version": 4, "type": "pty_close", "ptyId": "p1" });
        h.manager.handle_frame(&close, &denied).await;
        assert!(h.manager.has_attachment("p1"));
        assert!(!h.spawned()[0].state.lock().unwrap().killed);
        assert!(
            h.sent()
                .iter()
                .any(|frame| { frame["type"] == "pty_error" && frame["code"] == "trust_revoked" })
        );
    }

    #[tokio::test]
    async fn stale_viewer_output_cannot_reach_a_replacement_attachment() {
        let cmux = CmuxTui { file: "/opt/cmux-tui".to_owned(), prefix: Vec::new() };
        let h = harness(Some(cmux), None);
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let stale_viewer = h.spawned()[0].clone();

        h.frame(serde_json::json!({ "type": "pty_close", "ptyId": "p1" })).await;
        h.open("p1", "main", Value::Null, "supervised", h.owner.clone()).await;
        let before = h.sent().len();

        stale_viewer.emit("stale output");

        assert_eq!(h.sent().len(), before, "a detached viewer must not write to its replacement");
        assert!(h.manager.has_attachment("p1"), "the replacement attachment must remain live");
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
            scoped_cwd(Some(&home), Path::new(&home), None, None).unwrap().path,
            std::fs::canonicalize(&root.path).unwrap()
        );
        assert_eq!(
            scoped_cwd(Some("~/nested"), Path::new(&home), None, None).unwrap().path,
            std::fs::canonicalize(nested).unwrap()
        );
    }

    #[test]
    fn scoped_cwd_rejects_relative_requests_and_defaults_null_or_empty() {
        let root = TestDirectory::new("cwd-default");
        assert_eq!(
            match scoped_cwd(Some("relative"), &root.path, None, None) {
                Ok(_) => panic!("relative cwd must be rejected"),
                Err(error) => error,
            },
            "cwd must be absolute or home-relative"
        );
        assert_eq!(
            scoped_cwd(None, &root.path, None, None).unwrap().path,
            std::fs::canonicalize(&root.path).unwrap()
        );
        assert_eq!(
            scoped_cwd(Some(""), &root.path, None, None).unwrap().path,
            std::fs::canonicalize(&root.path).unwrap()
        );
    }

    #[cfg(unix)]
    #[test]
    fn scoped_cwd_descriptor_remains_pinned_after_path_rebind() {
        let root = TestDirectory::new("cwd-pinned");
        let scope = root.path.join("scope");
        let checked = scope.join("checked");
        let outside = root.path.join("outside");
        std::fs::create_dir(&scope).unwrap();
        std::fs::create_dir(&checked).unwrap();
        std::fs::create_dir_all(outside.join("checked")).unwrap();
        let resolved = scoped_cwd(Some(checked.to_str().unwrap()), &root.path, None, None).unwrap();
        let before = resolved.directory.metadata().unwrap();
        std::fs::rename(&scope, root.path.join("moved")).unwrap();
        std::os::unix::fs::symlink(&outside, &scope).unwrap();
        let after = resolved.directory.metadata().unwrap();
        assert_eq!(before.dev(), after.dev());
        assert_eq!(before.ino(), after.ino());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn scoped_cwd_accepts_execute_only_directory() {
        let root = TestDirectory::new("cwd-search-only");
        let directory = root.path.join("search-only");
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o111)).unwrap();

        // `open_pinned_directory` intentionally rejects symlink components.
        // Canonicalize the temporary path because macOS commonly exposes /var
        // through a symlink, while preserving the execute-only target.
        let canonical = std::fs::canonicalize(&directory).unwrap();
        open_pinned_directory(&canonical).expect("O_EXEC|O_DIRECTORY must open search-only cwd");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn scoped_cwd_resolves_execute_only_directory() {
        let root = TestDirectory::new("cwd-search-only-scoped");
        let directory = root.path.join("search-only");
        std::fs::create_dir(&directory).unwrap();
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o111)).unwrap();

        let resolved = scoped_cwd(Some(directory.to_str().unwrap()), &root.path, None, None)
            .expect("execute-only cwd must resolve through its pinned descriptor");
        assert_eq!(resolved.path, std::fs::canonicalize(directory).unwrap());
    }

    #[cfg(unix)]
    #[test]
    fn scoped_cwd_resolves_symlink_components_before_spawn() {
        let root = TestDirectory::new("cwd-symlink");
        let target = root.path.join("target");
        let link = root.path.join("link");
        std::fs::create_dir(&target).unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let resolved = scoped_cwd(Some(link.to_str().unwrap()), &root.path, None, None).unwrap();
        assert_eq!(resolved.path, std::fs::canonicalize(target).unwrap());
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
    }

    fn blocking_terminal_context(
        harness: &Harness,
        entered: TestArc<Barrier>,
        release: TestArc<Barrier>,
    ) -> FrameContext {
        let mut context = harness.context("supervised", harness.owner.clone());
        let sent = TestArc::clone(&harness.sent);
        context.send = TestArc::new(move |frame| {
            if matches!(
                frame.get("type").and_then(Value::as_str),
                Some("pty_output" | "pty_exit" | "pty_error")
            ) {
                entered.wait();
                release.wait();
            }
            sent.lock().expect("sent lock").push(frame);
        });
        context
    }

    #[tokio::test]
    async fn exit_publication_retains_closing_id_until_frame_is_sent() {
        let h = harness(None, None);
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));
        let context =
            blocking_terminal_context(&h, TestArc::clone(&entered), TestArc::clone(&release));
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });
        h.manager.handle_frame(&frame, &context).await;
        let pty = h.spawned()[0].clone();
        let exit = thread::spawn(move || pty.exit(7));
        entered.wait();

        let replacement = h.context("supervised", h.owner.clone());
        let manager = PtyManager { inner: Arc::clone(&h.manager.inner) };
        let replacement_for_task = replacement.clone();
        let frame_for_replacement = frame.clone();
        let (started, started_rx) = tokio::sync::oneshot::channel();
        let replacement_task = tokio::spawn(async move {
            let _ = started.send(());
            manager.handle_frame(&frame_for_replacement, &replacement_for_task).await;
        });
        started_rx.await.expect("replacement task started");
        assert!(
            !replacement_task.is_finished(),
            "same-ID replacement must wait for the closing publication"
        );
        assert!(!h.sent().iter().any(|frame| {
            frame["type"] == "pty_opened" && frame["ptyId"] == "p1" && frame["created"] == false
        }));

        release.wait();
        exit.join().expect("exit callback");
        replacement_task.await.expect("replacement open");
        h.manager.handle_frame(&frame, &replacement).await;
        assert!(h.sent().iter().any(|frame| {
            frame["type"] == "pty_opened" && frame["ptyId"] == "p1" && frame["created"] == false
        }));
    }

    #[tokio::test]
    async fn closing_attachment_counts_toward_capacity_until_publication_returns() {
        let h = harness_with_max_ptys(1);
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));
        let context =
            blocking_terminal_context(&h, TestArc::clone(&entered), TestArc::clone(&release));
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });
        h.manager.handle_frame(&frame, &context).await;
        let pty = h.spawned()[0].clone();
        let exit = thread::spawn(move || pty.exit(7));
        entered.wait();

        let replacement = h.context("supervised", h.owner.clone());
        h.manager.handle_frame(&frame, &replacement).await;
        assert_eq!(h.manager.attachment_count(), 1);
        assert!(
            h.sent()
                .iter()
                .any(|frame| { frame["type"] == "pty_error" && frame["code"] == "session_limit" })
        );

        release.wait();
        exit.join().expect("exit callback");
        h.manager.handle_frame(&frame, &replacement).await;
        assert_eq!(h.manager.attachment_count(), 1);
        assert!(h.sent().iter().any(|frame| {
            frame["type"] == "pty_opened" && frame["ptyId"] == "p1" && frame["created"] == false
        }));
    }

    #[tokio::test]
    async fn overflow_error_publication_cannot_reach_a_same_id_replacement() {
        let h = harness(None, None);
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));
        let context =
            blocking_terminal_context(&h, TestArc::clone(&entered), TestArc::clone(&release));
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });
        h.manager.handle_frame(&frame, &context).await;
        let pty = h.spawned()[0].clone();
        h.buffered.store(OUTPUT_BUFFER_CAP + 1, Ordering::SeqCst);
        let output = thread::spawn(move || pty.emit("overflow"));
        entered.wait();

        let replacement = h.context("supervised", h.owner.clone());
        let manager = PtyManager { inner: Arc::clone(&h.manager.inner) };
        let replacement_for_task = replacement.clone();
        let frame_for_replacement = frame.clone();
        let (started, started_rx) = tokio::sync::oneshot::channel();
        let replacement_task = tokio::spawn(async move {
            let _ = started.send(());
            manager.handle_frame(&frame_for_replacement, &replacement_for_task).await;
        });
        started_rx.await.expect("replacement task started");
        assert!(!replacement_task.is_finished());
        assert!(!h.sent().iter().any(|frame| {
            frame["type"] == "pty_opened" && frame["ptyId"] == "p1" && frame["created"] == false
        }));

        release.wait();
        output.join().expect("output callback");
        replacement_task.await.expect("replacement open");
        h.buffered.store(0, Ordering::SeqCst);
        h.manager.handle_frame(&frame, &replacement).await;
        assert!(h.sent().iter().any(|frame| {
            frame["type"] == "pty_opened" && frame["ptyId"] == "p1" && frame["created"] == false
        }));
    }

    #[tokio::test]
    async fn direct_close_waits_for_an_in_flight_publication() {
        let h = harness(None, None);
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));
        let context =
            blocking_terminal_context(&h, TestArc::clone(&entered), TestArc::clone(&release));
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });
        h.manager.handle_frame(&frame, &context).await;
        let pty = h.spawned()[0].clone();
        let output = thread::spawn(move || pty.emit("live"));
        entered.wait();

        let close_context = h.context("supervised", h.owner.clone());
        let manager = h.manager.inner.clone();
        let started = TestArc::new(Barrier::new(2));
        let close_started = TestArc::clone(&started);
        let close = thread::spawn(move || {
            close_started.wait();
            manager.close_authorized("p1", &close_context);
        });
        started.wait();
        assert!(!close.is_finished(), "close must wait for the publication gate");

        release.wait();
        output.join().expect("output callback");
        close.join().expect("close callback");
        assert!(!h.manager.has_attachment("p1"));
    }

    #[tokio::test]
    async fn output_sink_can_reenter_detach_without_deadlock() {
        let h = harness(None, None);
        let mut context = h.context("supervised", h.owner.clone());
        let manager = PtyManager { inner: Arc::clone(&h.manager.inner) };
        context.send = TestArc::new(move |frame| {
            if frame["type"] == "pty_output" {
                manager.detach_all();
            }
        });
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });
        h.manager.handle_frame(&frame, &context).await;
        let pty = h.spawned()[0].clone();
        let (done, completed) = std::sync::mpsc::channel();
        thread::spawn(move || {
            pty.emit("reentrant");
            done.send(()).expect("reentrant output completion");
        });
        assert!(
            completed.recv_timeout(Duration::from_secs(1)).is_ok(),
            "a reentrant output sink must not deadlock on the publication gate"
        );
        assert!(!h.manager.has_attachment("p1"));
    }

    #[tokio::test]
    async fn reentrant_same_id_open_is_rejected_until_exit_publication_finishes() {
        let h = harness(None, None);
        let mut context = h.context("supervised", h.owner.clone());
        let nested_context = h.context("supervised", h.owner.clone());
        let manager = PtyManager { inner: Arc::clone(&h.manager.inner) };
        let runtime = tokio::runtime::Handle::current();
        let reentered = Arc::new(AtomicBool::new(false));
        let (done, completed) = std::sync::mpsc::channel();
        let nested_frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });
        let sent = Arc::clone(&h.sent);
        let nested_frame_for_callback = nested_frame.clone();
        let reentered_for_send = Arc::clone(&reentered);
        context.send = TestArc::new(move |frame| {
            if frame["type"] == "pty_exit" && !reentered_for_send.swap(true, Ordering::SeqCst) {
                runtime.block_on(manager.handle_frame(&nested_frame_for_callback, &nested_context));
                done.send(()).expect("nested open completion");
            }
            sent.lock().unwrap().push(frame);
        });
        let frame = nested_frame.clone();
        h.manager.handle_frame(&frame, &context).await;
        let pty = h.spawned()[0].clone();
        let exit = thread::spawn(move || pty.exit(7));
        assert!(
            completed.recv_timeout(Duration::from_secs(1)).is_ok(),
            "reentrant open must return while the exit callback owns the route gate"
        );
        exit.join().expect("exit callback");
        assert!(!h.manager.has_attachment("p1"));
        assert!(!h.sent().iter().any(|frame| {
            frame["type"] == "pty_opened" && frame["ptyId"] == "p1" && frame["created"] == false
        }));
        assert!(h.sent().iter().any(|frame| frame["code"] == "bad_request"));
    }

    #[tokio::test]
    async fn input_operation_waits_before_close_can_retire_its_generation() {
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
        h.manager.handle_frame(&frame, &h.context("supervised", h.owner.clone())).await;
        let pty = h.spawned()[0].clone();
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));
        {
            let mut state = pty.state.lock().unwrap();
            state.write_entered = Some(TestArc::clone(&entered));
            state.write_release = Some(TestArc::clone(&release));
        }

        let input = serde_json::json!({
            "version": 4,
            "type": "pty_input",
            "ptyId": "p1",
            "dataB64": b64("stale"),
        });
        let manager = PtyManager { inner: Arc::clone(&h.manager.inner) };
        let input_context = h.context("supervised", h.owner.clone());
        let runtime = tokio::runtime::Handle::current();
        let input_task =
            thread::spawn(move || runtime.block_on(manager.handle_frame(&input, &input_context)));
        entered.wait();

        let close_context = h.context("supervised", h.owner.clone());
        let manager = PtyManager { inner: Arc::clone(&h.manager.inner) };
        let close_started = TestArc::new(Barrier::new(2));
        let close_started_in_thread = TestArc::clone(&close_started);
        let close = thread::spawn(move || {
            close_started_in_thread.wait();
            manager.inner.close_authorized("p1", &close_context);
        });
        close_started.wait();
        assert!(!close.is_finished(), "close must wait for the in-flight control operation");

        h.manager.handle_frame(&frame, &h.context("supervised", h.owner.clone())).await;
        assert!(!h.sent().iter().any(|frame| {
            frame["type"] == "pty_opened" && frame["ptyId"] == "p1" && frame["created"] == false
        }));

        release.wait();
        input_task.join().expect("input operation");
        close.join().expect("close operation");
        h.manager.handle_frame(&frame, &h.context("supervised", h.owner.clone())).await;
        assert!(h.sent().iter().any(|frame| {
            frame["type"] == "pty_opened" && frame["ptyId"] == "p1" && frame["created"] == false
        }));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn async_close_waits_for_control_operation_across_workers() {
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
        h.manager.handle_frame(&frame, &h.context("supervised", h.owner.clone())).await;
        let pty = h.spawned()[0].clone();
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));
        {
            let mut state = pty.state.lock().unwrap();
            state.write_entered = Some(TestArc::clone(&entered));
            state.write_release = Some(TestArc::clone(&release));
        }
        let input = serde_json::json!({
            "version": 4,
            "type": "pty_input",
            "ptyId": "p1",
            "dataB64": b64("held"),
        });
        let input_task = tokio::spawn({
            let manager = h.manager.clone();
            let context = h.context("supervised", h.owner.clone());
            async move { manager.handle_frame(&input, &context).await }
        });
        entered.wait();
        let (started, started_rx) = tokio::sync::oneshot::channel();
        let close_task = tokio::spawn({
            let manager = h.manager.clone();
            let context = h.context("supervised", h.owner.clone());
            let started = started;
            async move {
                let _ = started.send(());
                manager
                    .handle_frame(
                        &serde_json::json!({ "type": "pty_close", "ptyId": "p1" }),
                        &context,
                    )
                    .await;
            }
        });
        started_rx.await.expect("close task started");
        assert!(!close_task.is_finished(), "close waits for the in-flight control operation");
        release.wait();
        input_task.await.expect("input operation");
        close_task.await.expect("close operation");
        assert!(!h.manager.has_attachment("p1"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn async_route_gate_wait_does_not_block_unrelated_tasks() {
        let gate = Arc::new(RouteGate::new());
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let held_gate = Arc::clone(&gate);
        let owner = thread::spawn(move || {
            let _guard = held_gate.lock();
            entered_tx.send(()).expect("gate owner entered");
            release_rx.recv().expect("gate owner released");
        });
        entered_rx.recv().expect("gate owner entered");

        let waiter_gate = Arc::clone(&gate);
        let waiter = tokio::spawn(async move {
            let _guard = waiter_gate.lock_async().await;
        });
        let tick = tokio::spawn(async { 17_u8 });
        assert_eq!(tick.await.expect("unrelated task"), 17);
        release_tx.send(()).expect("release gate owner");
        waiter.await.expect("async gate waiter");
        owner.join().expect("gate owner");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn async_transport_detach_does_not_block_unrelated_tasks() {
        let h = harness(None, None);
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));
        let mut context =
            blocking_terminal_context(&h, TestArc::clone(&entered), TestArc::clone(&release));
        context.transport_id = Some("transport-a".to_owned());
        let frame = serde_json::json!({
            "version": 4,
            "type": "pty_open",
            "ptyId": "p1",
            "session": "main",
            "cols": 80,
            "rows": 24,
            "actorId": "user_owner",
        });
        h.manager.handle_frame(&frame, &context).await;
        let pty = h.spawned()[0].clone();
        let output = thread::spawn(move || pty.emit("live"));
        entered.wait();

        let manager = h.manager.clone();
        let (started, started_rx) = tokio::sync::oneshot::channel();
        let detach = tokio::spawn(async move {
            let _ = started.send(());
            manager.detach_transport_async("transport-a").await;
        });
        started_rx.await.expect("detach task started");
        assert!(!detach.is_finished(), "detach must wait for the publication gate");

        let tick = tokio::spawn(async { 17_u8 });
        assert_eq!(tick.await.expect("unrelated task"), 17);

        release.wait();
        output.join().expect("output callback");
        detach.await.expect("transport detach");
        assert!(!h.manager.has_attachment("p1"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn long_lived_start_does_not_block_close_or_subsequent_frames() {
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
        h.manager.handle_frame(&frame, &h.context("supervised", h.owner.clone())).await;
        let shell = h.spawned()[0].clone();
        shell.emit("replay");
        h.manager
            .handle_frame(
                &serde_json::json!({ "type": "pty_close", "ptyId": "p1" }),
                &h.context("supervised", h.owner.clone()),
            )
            .await;

        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));
        let context =
            blocking_terminal_context(&h, TestArc::clone(&entered), TestArc::clone(&release));
        let open = tokio::spawn({
            let manager = h.manager.clone();
            let context = context.clone();
            let frame = frame.clone();
            async move { manager.handle_frame(&frame, &context).await }
        });
        open.await.expect("replacement open");
        entered.wait();
        let output_during_start = thread::spawn(move || shell.emit("during-start"));

        let (started, started_rx) = tokio::sync::oneshot::channel();
        let close = tokio::spawn({
            let manager = h.manager.clone();
            let context = h.context("supervised", h.owner.clone());
            async move {
                let _ = started.send(());
                manager
                    .handle_frame(
                        &serde_json::json!({ "type": "pty_close", "ptyId": "p1" }),
                        &context,
                    )
                    .await;
            }
        });
        started_rx.await.expect("close task started");
        assert!(!close.is_finished(), "close must wait for the replay callback");

        release.wait();
        output_during_start.join().expect("output during start");
        close.await.expect("close after replay");
        assert!(!h.manager.has_attachment("p1"));
        assert!(h.sent().iter().any(|frame| {
            frame["type"] == "pty_output"
                && from_b64(frame["dataB64"].as_str().unwrap_or_default()) == "during-start"
        }));
    }
}
