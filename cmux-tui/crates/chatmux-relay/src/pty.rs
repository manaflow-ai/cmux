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
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::Notify;

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
}

#[derive(Clone)]
struct AuthSnapshot {
    trust: String,
    local_roots: Option<Vec<String>>,
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

#[derive(Clone)]
struct Attachment {
    closing: Arc<AtomicBool>,
    /// Releases this attachment (detach a viewer, close a control stream,
    /// kill a viewer PTY) — never kills a shared session.
    control: Arc<dyn PtyControl>,
    actor_id: String,
    /// Transport that opened this attachment (see FrameContext::transport_id).
    transport_id: Option<String>,
}

struct Inner {
    deps: Arc<dyn PtyDeps>,
    home: PathBuf,
    env: HashMap<String, String>,
    max_ptys: usize,
    scrollback_limit: usize,
    output_cap: u64,
    attachments: Mutex<HashMap<String, Attachment>>,
    /// ptyId -> transport that reserved it (None = legacy whole-manager owner).
    opening_ids: Mutex<HashMap<String, Option<String>>>,
    cancelled_openings: Mutex<std::collections::HashSet<String>>,
    shell_sessions: Mutex<HashMap<String, Arc<ShellSession>>>,
    shell_starting: Mutex<HashMap<String, Arc<Notify>>>,
    /// Authentication is scoped to the transport that owns an attachment.
    /// A single manager serves the relay socket and managed tunnel sockets;
    /// one global snapshot would let the last frame on either transport
    /// authorize asynchronous output for every other attachment.
    transport_auth: Mutex<HashMap<Option<String>, AuthSnapshot>>,
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
                opening_ids: Mutex::new(HashMap::new()),
                cancelled_openings: Mutex::new(std::collections::HashSet::new()),
                shell_sessions: Mutex::new(HashMap::new()),
                shell_starting: Mutex::new(HashMap::new()),
                transport_auth: Mutex::new(HashMap::new()),
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
                opening_ids: Mutex::new(HashMap::new()),
                cancelled_openings: Mutex::new(std::collections::HashSet::new()),
                shell_sessions: Mutex::new(HashMap::new()),
                shell_starting: Mutex::new(HashMap::new()),
                transport_auth: Mutex::new(HashMap::new()),
            }),
        }
    }

    /// Handle one Worker -> relay PTY frame.
    pub async fn handle_frame(&self, frame: &Value, context: &FrameContext) {
        self.inner.transport_auth.lock().expect("transport auth lock").insert(
            context.transport_id.clone(),
            AuthSnapshot {
                trust: context.trust.clone(),
                local_roots: context.local_roots.clone(),
                owner_user_id: context.owner_user_id.clone(),
                send: Arc::clone(&context.send),
                buffered_amount: Arc::clone(&context.buffered_amount),
            },
        );
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
                    attachment.control.write(&data);
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
                    attachment.control.resize(cols, rows);
                }
            }
            "pty_flow" => {
                let Some(pty_id) = frame.get("ptyId").and_then(Value::as_str) else { return };
                if !self.inner.transport_owns(pty_id, context.transport_id.as_deref()) {
                    return;
                }
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
                if !self.inner.transport_owns(pty_id, context.transport_id.as_deref()) {
                    return;
                }
                self.inner.close_authorized(pty_id, context);
            }
            "surface_list" => self.inner.clone().list_surfaces(frame, context).await,
            _ => {}
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
        self.detach_matching(|_| true);
    }

    /// One transport dropped: release only its attachments and cancel only
    /// its in-flight opens. Sessions live on either way (docs/TERMINAL.md).
    pub fn detach_transport(&self, transport_id: &str) {
        self.detach_matching(|owner| owner == Some(transport_id));
    }

    /// Release all managed tunnel attachments. The relay connection clears
    /// tunnel authority on disconnect or trust renegotiation; existing tunnel
    /// viewers must lose their attachments at the same boundary.
    pub fn detach_tunnel_transports(&self) {
        self.detach_matching(|owner| owner.is_some_and(|id| id.starts_with("tunnel-")));
    }

    fn detach_matching(&self, owns: impl Fn(Option<&str>) -> bool) {
        // Openings first: close() records cancellation for a reserved id, so
        // a late open cannot install an attachment after its transport died.
        let mut ids: Vec<String> = {
            let opening = self.inner.opening_ids.lock().expect("opening lock");
            opening
                .iter()
                .filter(|(_, owner)| owns(owner.as_deref()))
                .map(|(id, _)| id.clone())
                .collect()
        };
        {
            let attachments = self.inner.attachments.lock().expect("attach lock");
            ids.extend(
                attachments
                    .iter()
                    .filter(|(_, attachment)| owns(attachment.transport_id.as_deref()))
                    .map(|(id, _)| id.clone()),
            );
        }
        for id in ids {
            self.inner.close(&id);
        }
        self.inner
            .transport_auth
            .lock()
            .expect("transport auth lock")
            .retain(|owner, _| !owns(owner.as_deref()));
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
    async fn open(self: Arc<Self>, frame: &Value, context: &FrameContext) {
        let pty_id = frame.get("ptyId").and_then(Value::as_str).unwrap_or_default().to_owned();
        if pty_id.is_empty() {
            return;
        }
        let fail = |code: &str, message: &str| send_pty_error(context, &pty_id, code, message);
        let reservation_result = {
            let mut opening = self.opening_ids.lock().expect("opening lock");
            let attached = self.attachments.lock().expect("attach lock").contains_key(&pty_id);
            if attached || opening.contains_key(&pty_id) {
                Err(("bad_request", "ptyId is already attached".to_owned()))
            } else if self.attachments.lock().expect("attach lock").len() + opening.len()
                >= self.max_ptys
            {
                Err((
                    "session_limit",
                    format!("this relay caps concurrent terminals at {}", self.max_ptys),
                ))
            } else {
                opening.insert(pty_id.clone(), context.transport_id.clone());
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
                        fail("failed", &message);
                        return;
                    }
                }
            }
        };

        // Keep the opening reservation held until the attachment is installed.
        // `close` takes this lock first, so it cannot observe a gap between
        // removing the opening marker and inserting the attachment.
        let mut opening = self.opening_ids.lock().expect("opening lock");
        let cancelled =
            self.cancelled_openings.lock().expect("cancelled openings lock").remove(&pty_id);
        let auth_changed = self
            .transport_auth
            .lock()
            .expect("transport auth lock")
            .get(&context.transport_id)
            .is_none_or(|auth| {
                auth.trust != context.trust
                    || auth.local_roots != context.local_roots
                    || auth.owner_user_id != context.owner_user_id
            });
        if cancelled || auth_changed {
            opening.remove(&pty_id);
            drop(opening);
            reservation.active = false;
            return;
        }
        // The value is now owned by the attachment map. Its Drop handler
        // must not release a live viewer when this local is consumed below.
        opened.cleanup_on_drop = false;
        let previous = self.attachments.lock().expect("attach lock").insert(
            pty_id.clone(),
            Attachment {
                closing: opened.closing,
                control: opened.control,
                actor_id: actor.to_owned(),
                transport_id: context.transport_id.clone(),
            },
        );
        if let Some(previous) = previous {
            previous.closing.store(true, Ordering::SeqCst);
            previous.control.kill();
        }
        opening.remove(&pty_id);
        drop(opening);
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
        (opened.start)();
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
        let Some(auth) = self.auth_for_transport(context.transport_id.as_deref()) else {
            return;
        };
        if self.authorize_snapshot(pty_id, &auth, context, "output").is_none() {
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
            self.close(pty_id);
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
        (auth.send)(json!({
            "version": PTY_PROTOCOL_VERSION,
            "type": "pty_output",
            "ptyId": pty_id,
            "dataB64": BASE64.encode(chunk),
        }));
    }

    fn emit_exit(&self, pty_id: &str, code: i64, context: &FrameContext) {
        let Some(auth) = self.auth_for_transport(context.transport_id.as_deref()) else {
            return;
        };
        if self.authorize_snapshot(pty_id, &auth, context, "exit").is_none() {
            return;
        }
        let mut attachments = self.attachments.lock().expect("attach lock");
        match attachments.get(pty_id) {
            Some(attachment) if !attachment.closing.load(Ordering::SeqCst) => {}
            _ => return,
        }
        attachments.remove(pty_id);
        drop(attachments);
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
        // record cancellation and let it dispose the newly opened PTY.
        let opening = self.opening_ids.lock().expect("opening lock");
        if opening.contains_key(pty_id) {
            self.cancelled_openings
                .lock()
                .expect("cancelled openings lock")
                .insert(pty_id.to_owned());
            return;
        }
        drop(opening);
        let attachment = self.attachments.lock().expect("attach lock").remove(pty_id);
        if let Some(attachment) = attachment {
            attachment.closing.store(true, Ordering::SeqCst);
            attachment.control.kill();
        }
    }

    /// Frame-level transport fence. Unknown ids retain the protocol's silent
    /// no-op behavior; once an id is reserved or attached, a different
    /// transport may not act on it. A `None` caller owns everything (legacy).
    fn transport_owns(&self, pty_id: &str, transport_id: Option<&str>) -> bool {
        let Some(transport_id) = transport_id else { return true };
        if let Some(attachment) = self.attachments.lock().expect("attach lock").get(pty_id) {
            return attachment.transport_id.as_deref() == Some(transport_id);
        }
        if let Some(owner) = self.opening_ids.lock().expect("opening lock").get(pty_id) {
            return owner.as_deref() == Some(transport_id);
        }
        true
    }

    fn authorize(&self, pty_id: &str, context: &FrameContext, action: &str) -> Option<Attachment> {
        let auth = self.auth_for_transport(context.transport_id.as_deref())?;
        self.authorize_snapshot(pty_id, &auth, context, action)
    }

    fn auth_for_transport(&self, transport_id: Option<&str>) -> Option<AuthSnapshot> {
        let key = transport_id.map(str::to_owned);
        self.transport_auth.lock().expect("transport auth lock").get(&key).cloned()
    }

    fn authorize_snapshot(
        &self,
        pty_id: &str,
        auth: &AuthSnapshot,
        context: &FrameContext,
        action: &str,
    ) -> Option<Attachment> {
        let attachment = self.attachments.lock().expect("attach lock").get(pty_id)?.clone();
        let owner = auth.owner_user_id.as_deref();
        let allowed = !auth.trust.is_empty()
            && (auth.trust != "observe"
                || (owner.is_some() && owner == Some(attachment.actor_id.as_str())));
        if allowed {
            Some(attachment)
        } else {
            self.close(pty_id);
            send_pty_error(
                context,
                pty_id,
                "trust_revoked",
                &format!("PTY {action} refused after trust change"),
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
    created: bool,
    surface: Option<String>,
    control: Arc<dyn PtyControl>,
    closing: Arc<AtomicBool>,
    start: Box<dyn FnOnce() + Send>,
    /// A cancelled open can finish after the caller's deadline. Until the
    /// attachment is installed, dropping this value must release the spawned
    /// viewer instead of leaking a PTY and its process group.
    cleanup_on_drop: bool,
}

impl Drop for Opened {
    fn drop(&mut self) {
        if self.cleanup_on_drop {
            self.closing.store(true, Ordering::SeqCst);
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
            let Some(listed) = control.request("list-workspaces", json!({})).await else {
                control.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            };
            if listed.get("ok").and_then(Value::as_bool) != Some(true) {
                control.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            }
            let Some(data) = listed.get("data").and_then(Value::as_object) else {
                control.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            };
            if !data.get("workspaces").is_some_and(Value::is_array) {
                control.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            }
            if !workspace_shape_valid(listed.get("data")) {
                control.end();
                return Err("cannot inspect existing daemon surfaces".to_owned());
            }
            let tabs = match collect_pty_tabs_strict(listed.get("data")) {
                Ok(tabs) => tabs,
                Err(_) => {
                    control.end();
                    return Err("cannot inspect existing daemon surfaces".to_owned());
                }
            };
            if tabs.len() > MAX_ENUM_TERMINALS || (tabs.is_empty() && !ensured.created) {
                control.end();
                return Err("cannot prove existing daemon cwd is within allowed roots".to_owned());
            }
            for tab in tabs {
                let Some(info) =
                    control.request("process-info", json!({ "surface": tab.surface_id })).await
                else {
                    control.end();
                    return Err("cannot inspect existing surface cwd".to_owned());
                };
                if info.get("ok").and_then(Value::as_bool) != Some(true) {
                    control.end();
                    return Err("cannot inspect existing surface cwd".to_owned());
                }
                let Some(actual) =
                    info.get("data").and_then(|v| v.get("cwd")).and_then(Value::as_str)
                else {
                    control.end();
                    return Err(
                        "cannot prove existing surface cwd is within allowed roots".to_owned()
                    );
                };
                if actual.is_empty() || !Path::new(actual).is_absolute() {
                    control.end();
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
                    control.end();
                    return Err("existing surface cwd is outside allowed roots".to_owned());
                }
            }
            control.end();
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
                cwd: cwd.to_path_buf(),
                env: env.clone(),
            })
            .await;
        let control = Arc::clone(&handle.control);
        let output = Arc::clone(&handle.output);
        let banner = handle.banner.clone();
        let (on_data, on_exit) = self.sinks(pty_id, context);
        Ok(Opened {
            created: ensured.created,
            surface: None,
            control,
            closing: Arc::new(AtomicBool::new(false)),
            start: Box::new(move || drive_handle(output, banner, on_data, on_exit)),
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
                        cwd: cwd.to_path_buf(),
                        env: env.clone(),
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
        let (on_data, on_exit) = self.sinks(pty_id, context);

        // The per-attachment control proxies onto the session pty but its
        // kill() only unhooks this viewer (release), never the session.
        let proxy = Arc::new(ShellViewerControl {
            session: Arc::clone(&shell_session),
            viewer_id,
            released: Arc::clone(&released),
        });

        let start_session = Arc::clone(&shell_session);
        let start: Box<dyn FnOnce() + Send> = Box::new(move || {
            let (banner, replay, alive) = {
                let inner = start_session.inner.lock().expect("shell inner lock");
                let banner = created.then(|| start_session.banner.clone()).flatten();
                let replay = (!created && inner.ring_size > 0).then(|| {
                    inner.ring.iter().flat_map(|c| c.iter().copied()).collect::<Vec<u8>>()
                });
                (banner, replay, inner.alive)
            };
            if let Some(banner) = banner {
                on_data(Bytes::from(banner));
            }
            if let Some(replay) = replay {
                on_data(Bytes::from(replay));
            }
            if released.load(Ordering::SeqCst) {
                return;
            }
            if !alive {
                on_exit(0);
                return;
            }
            let mut inner = start_session.inner.lock().expect("shell inner lock");
            if !released.load(Ordering::SeqCst) && inner.alive {
                inner.viewers.push(ViewerSink { id: viewer_id, on_data, on_exit });
            }
        });

        Ok(Opened { created, surface: None, control: proxy, closing, start, cleanup_on_drop: true })
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

        let identify = control.request("identify", json!({})).await;
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
            let listed = control.request("list-workspaces", json!({})).await;
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
            let info = control.request("process-info", json!({ "surface": surface_id })).await;
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
            control: proxy,
            closing: Arc::new(AtomicBool::new(false)),
            start: Box::new(move || start_stream.go_live(on_data, on_exit)),
            cleanup_on_drop: true,
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
            let sent = Arc::clone(&self.sent);
            let buffered = Arc::clone(&self.buffered);
            FrameContext {
                send: Arc::new(move |frame| sent.lock().unwrap().push(frame)),
                buffered_amount: Arc::new(move || buffered.load(Ordering::SeqCst)),
                trust: trust.to_owned(),
                local_roots: None,
                owner_user_id: owner,
                transport_id: None,
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
        };
        let context_a = context(Arc::clone(&sent_a), "transport-a");
        let context_b = context(Arc::clone(&sent_b), "transport-b");
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
    }
}
