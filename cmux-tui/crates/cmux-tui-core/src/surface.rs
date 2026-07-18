//! Surface runtime: one tab inside a pane.
//!
//! A surface is either a PTY backed by libghostty-vt state or a local CDP
//! browser surface. PTY-only methods stay available for existing callers;
//! browser-aware frontends should branch on [`SurfaceKind`] before using
//! VT operations.

use std::collections::VecDeque;
use std::io::{Read, Write};
use std::mem::size_of;
use std::ops::Deref;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{
    Receiver, RecvError, RecvTimeoutError, SyncSender, TryRecvError, TrySendError, sync_channel,
};
use std::sync::{Arc, Condvar, Mutex, TryLockError, Weak};
use std::time::{Duration, Instant};

use anyhow::Context;
use ghostty_vt::{
    Callbacks, CursorShape, MouseEncoders, MouseInput, RenderFrame, RenderSceneHighlight,
    RenderSceneHighlightKind, RenderState, Rgb, Scrollbar, SearchSelection, SelectionAdjustment,
    SelectionPoint, SelectionSnapshot, Terminal,
};
use portable_pty::{Child, ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};
use sha2::{Digest, Sha256};

use crate::accessibility::{
    TerminalAccessibilityIdentity, TerminalAccessibilitySnapshot,
    build_terminal_accessibility_snapshot,
};
use crate::platform;
use crate::semantic_scene::{
    SemanticSceneAttachError, SemanticSceneAttachment, SemanticSceneAttachmentOptions,
    SemanticSceneHub, SemanticSceneTerminalIdentity,
};
use crate::{Mux, MuxEvent, SurfaceId};

use crate::browser::BrowserSurface;
pub use crate::browser::{
    BrowserAttachState, BrowserFrame, BrowserFrameStream, BrowserSource, BrowserStatus,
};
use cmux_tui_cdp::BrowserMode;

/// How to spawn surface children.
#[derive(Debug, Clone)]
pub struct SurfaceOptions {
    /// Command argv; defaults to the platform shell.
    pub command: Option<Vec<String>>,
    pub cwd: Option<String>,
    /// TERM value for children. xterm-256color is the compatible default;
    /// set xterm-ghostty when the ghostty terminfo is installed.
    pub term: String,
    pub cols: u16,
    pub rows: u16,
    pub scrollback: usize,
    /// Keep the terminal surface and final VT state after the child exits.
    pub wait_after_command: bool,
    /// Extra environment for children (e.g. CMUX_TUI_SOCKET).
    pub extra_env: Vec<(String, String)>,
    /// Optional Chrome/Chromium binary for browser surfaces.
    pub chrome_binary: Option<String>,
    /// Optional existing Chrome CDP endpoint, as ws://... or http://host:port.
    pub cdp_url: Option<String>,
    /// Whether browser panes should probe local debuggable Chrome ports.
    pub browser_discover: bool,
    /// Local ports to probe for /json/version when discovery is enabled.
    pub browser_discover_ports: Vec<u16>,
    /// Optional Chrome user data directory for launched browser runtime.
    pub browser_user_data_dir: Option<String>,
    /// Whether launched Chrome should show a visible window or run headless.
    pub browser_mode: BrowserMode,
    /// Session component for the default launched Chrome profile path.
    pub browser_session_name: String,
    /// Use a temporary launched Chrome profile and delete it on shutdown.
    pub browser_ephemeral: bool,
    /// Maximum browser capture size before downscaling, in megapixels.
    pub browser_max_capture_megapixels: f64,
    /// Optional maximum browser capture scale, further reduced to honor the megapixel cap.
    pub browser_capture_scale: Option<f64>,
}

impl Default for SurfaceOptions {
    fn default() -> Self {
        SurfaceOptions {
            command: None,
            cwd: None,
            term: std::env::var("CMUX_TUI_TERM")
                .or_else(|_| std::env::var("CMUX_MUX_TERM"))
                .unwrap_or_else(|_| "xterm-256color".into()),
            cols: 80,
            rows: 24,
            scrollback: 10_000,
            wait_after_command: false,
            extra_env: Vec::new(),
            chrome_binary: None,
            cdp_url: None,
            browser_discover: false,
            browser_discover_ports: vec![9222],
            browser_user_data_dir: None,
            browser_mode: BrowserMode::Headful,
            browser_session_name: "default".to_string(),
            browser_ephemeral: false,
            browser_max_capture_megapixels: crate::browser::TRANSPORT_SAFE_CAPTURE_MEGAPIXELS,
            browser_capture_scale: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DefaultColors {
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub cursor: Option<Rgb>,
    pub selection_bg: Option<Rgb>,
    pub selection_fg: Option<Rgb>,
    pub cursor_style: Option<CursorShape>,
    pub cursor_blink: Option<bool>,
    pub palette: [Option<Rgb>; 256],
}

impl Default for DefaultColors {
    fn default() -> Self {
        Self {
            fg: None,
            bg: None,
            cursor: None,
            selection_bg: None,
            selection_fg: None,
            cursor_style: None,
            cursor_blink: None,
            palette: [None; 256],
        }
    }
}

/// Effective colors exposed to attached terminal clients.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalColors {
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub cursor: Option<Rgb>,
    pub selection_bg: Option<Rgb>,
    pub selection_fg: Option<Rgb>,
    /// Palette entries explicitly changed by the PTY with OSC 4. Unset
    /// entries remain presentation-owned theme colors.
    pub palette: [Option<Rgb>; 256],
    pub cursor_style: Option<CursorShape>,
    pub cursor_blink: Option<bool>,
}

impl Default for TerminalColors {
    fn default() -> Self {
        Self {
            fg: None,
            bg: None,
            cursor: None,
            selection_bg: None,
            selection_fg: None,
            palette: [None; 256],
            cursor_style: None,
            cursor_blink: None,
        }
    }
}

impl TerminalColors {
    fn from_terminal(term: &mut Terminal, defaults: DefaultColors) -> Self {
        let (fg, bg, cursor) = term.effective_colors();
        let render_state = RenderState::new()
            .and_then(|mut state| {
                state.update(term)?;
                Ok(state)
            })
            .ok();
        let cursor_visual = term
            .cursor_overridden()
            .then(|| render_state.as_ref().and_then(|state| state.cursor_visual().ok()))
            .flatten();
        let palette = std::array::from_fn(|index| {
            render_state.as_ref().and_then(|state| {
                let index = index as u8;
                state.palette_overridden(index).then(|| state.palette_color(index))
            })
        });
        TerminalColors {
            fg,
            bg,
            cursor,
            selection_bg: defaults.selection_bg,
            selection_fg: defaults.selection_fg,
            palette,
            cursor_style: cursor_visual.map(|(style, _)| style).or(defaults.cursor_style),
            cursor_blink: cursor_visual.map(|(_, blink)| blink).or(defaults.cursor_blink),
        }
    }
}

/// Everything an attaching frontend needs to adopt a PTY surface: its
/// size, a VT replay of the current state, and a live stream of every pty
/// byte applied after the replay snapshot.
pub struct AttachStream {
    pub cols: u16,
    pub rows: u16,
    pub replay: Vec<u8>,
    pub colors: TerminalColors,
    pub stream: AttachFrameReceiver,
    pub(crate) lifecycle: AttachLifecycle,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachFrame {
    Output(Vec<u8>),
    Resized { cols: u16, rows: u16, replay: Vec<u8> },
    ColorsChanged(TerminalColors),
}

const ATTACH_STREAM_CAPACITY: usize = 256;
const ATTACH_STREAM_MAX_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const VT_REPLAY_MAX_BYTES: usize = 8 * 1024 * 1024;

pub struct AttachFrameReceiver {
    receiver: Receiver<AttachFrame>,
    queued_bytes: Arc<AtomicUsize>,
}

impl AttachFrameReceiver {
    fn account_received(&self, frame: &AttachFrame) {
        self.queued_bytes.fetch_sub(frame.retained_bytes(), Ordering::AcqRel);
    }

    pub fn recv(&self) -> Result<AttachFrame, RecvError> {
        let frame = self.receiver.recv()?;
        self.account_received(&frame);
        Ok(frame)
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<AttachFrame, RecvTimeoutError> {
        let frame = self.receiver.recv_timeout(timeout)?;
        self.account_received(&frame);
        Ok(frame)
    }

    pub fn try_recv(&self) -> Result<AttachFrame, TryRecvError> {
        let frame = self.receiver.try_recv()?;
        self.account_received(&frame);
        Ok(frame)
    }
}

impl AttachFrame {
    fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + match self {
                Self::Output(bytes) => bytes.capacity(),
                Self::Resized { replay, .. } => replay.capacity(),
                Self::ColorsChanged(_) => 0,
            }
    }
}

#[derive(Clone, Default)]
pub(crate) struct AttachLifecycle {
    state: Arc<AttachLifecycleState>,
}

#[derive(Default)]
struct AttachLifecycleState {
    canceled: AtomicBool,
    overflowed: AtomicBool,
    overflow_reported: AtomicBool,
}

impl AttachLifecycle {
    pub(crate) fn cancel(&self) {
        self.state.canceled.store(true, Ordering::Release);
    }

    pub(crate) fn mark_overflow(&self) {
        self.state.overflowed.store(true, Ordering::Release);
        self.cancel();
    }

    pub(crate) fn is_canceled(&self) -> bool {
        self.state.canceled.load(Ordering::Acquire)
    }

    pub(crate) fn overflowed(&self) -> bool {
        self.state.overflowed.load(Ordering::Acquire)
    }

    pub(crate) fn claim_overflow_report(&self) -> bool {
        self.overflowed()
            && self
                .state
                .overflow_reported
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
    }
}

struct AttachTap {
    sender: SyncSender<AttachFrame>,
    lifecycle: AttachLifecycle,
    queued_bytes: Arc<AtomicUsize>,
    max_queued_bytes: usize,
}

impl AttachTap {
    fn try_send(&self, frame: AttachFrame) -> bool {
        if self.lifecycle.is_canceled() {
            return false;
        }
        let frame_bytes = frame.retained_bytes();
        if self
            .queued_bytes
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |queued| {
                queued.checked_add(frame_bytes).filter(|next| *next <= self.max_queued_bytes)
            })
            .is_err()
        {
            self.lifecycle.mark_overflow();
            return false;
        }
        match self.sender.try_send(frame) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) => {
                self.queued_bytes.fetch_sub(frame_bytes, Ordering::AcqRel);
                self.lifecycle.mark_overflow();
                false
            }
            Err(TrySendError::Disconnected(_)) => {
                self.queued_bytes.fetch_sub(frame_bytes, Ordering::AcqRel);
                self.lifecycle.cancel();
                false
            }
        }
    }
}

/// One immutable terminal frame plus the scrollback count captured with it.
#[derive(Debug, Clone)]
pub struct SurfaceRenderFrame {
    pub frame: RenderFrame,
    pub scrollback_rows: u32,
    pub palette_colors: [Rgb; 256],
    pub palette_overridden: [bool; 256],
}

/// Live events delivered to one protocol-v7 render attachment.
#[derive(Debug, Clone)]
pub enum RenderAttachFrame {
    Frame(Arc<SurfaceRenderFrame>),
    ScrollChanged { offset: u64, at_bottom: bool },
}

/// Initial render snapshot and the ordered live stream registered with it.
pub struct RenderAttachStream {
    pub initial: Arc<SurfaceRenderFrame>,
    pub stream: Receiver<RenderAttachFrame>,
}

struct RenderHub {
    state: Box<RenderState>,
    built_generation: u64,
    latest: Option<Arc<SurfaceRenderFrame>>,
    taps: Vec<std::sync::mpsc::Sender<RenderAttachFrame>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SurfaceKind {
    Pty,
    Browser,
}

const EXTERNAL_TERMINAL_EGRESS_MAX_BYTES: usize = 1024 * 1024;

/// Registered process identity allowed to feed and drain one parser-only
/// terminal. A replacement connection must claim a new generation before any
/// output is accepted, fencing late work from a dead Swift shell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ExternalTerminalOwner {
    pub client_uuid: uuid::Uuid,
    pub process_instance_uuid: uuid::Uuid,
    pub connection_id: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExternalTerminalClaimReceipt {
    pub request_id: uuid::Uuid,
    pub owner_generation: u64,
    pub required_output_generation: u64,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExternalTerminalOutputReceipt {
    pub request_id: uuid::Uuid,
    pub owner_generation: u64,
    pub output_generation: u64,
    pub accepted_sequence: u64,
    pub next_sequence: u64,
    pub egress: Vec<u8>,
    pub replayed: bool,
}

#[derive(Debug, Clone)]
struct ExternalClaimReplay {
    owner: ExternalTerminalOwner,
    receipt: ExternalTerminalClaimReceipt,
}

#[derive(Debug, Clone)]
struct ExternalOutputReplay {
    digest: [u8; 32],
    receipt: ExternalTerminalOutputReceipt,
}

#[derive(Debug, Default)]
struct ExternalTerminalState {
    owner: Option<ExternalTerminalOwner>,
    owner_generation: u64,
    output_generation: u64,
    next_output_sequence: u64,
    requires_reset: bool,
    egress: Vec<u8>,
    overflowed: bool,
    last_claim: Option<ExternalClaimReplay>,
    last_reset: Option<ExternalOutputReplay>,
    last_output: Option<ExternalOutputReplay>,
}

struct ExternalTerminalRuntime {
    /// Serializes claims, generation resets, and ordered output parsing.
    operation: Mutex<()>,
    state: Mutex<ExternalTerminalState>,
    no_reflow: bool,
    scrollback: usize,
}

impl ExternalTerminalRuntime {
    fn new(no_reflow: bool, scrollback: usize) -> Self {
        Self {
            operation: Mutex::new(()),
            state: Mutex::new(ExternalTerminalState {
                requires_reset: true,
                next_output_sequence: 1,
                ..ExternalTerminalState::default()
            }),
            no_reflow,
            scrollback,
        }
    }

    fn append_egress(&self, bytes: &[u8]) -> std::io::Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        let mut state = self.state.lock().unwrap();
        let Some(next_len) = state.egress.len().checked_add(bytes.len()) else {
            state.egress.clear();
            state.overflowed = true;
            state.requires_reset = true;
            return Err(std::io::Error::new(
                std::io::ErrorKind::OutOfMemory,
                "external terminal egress size overflow",
            ));
        };
        if next_len > EXTERNAL_TERMINAL_EGRESS_MAX_BYTES {
            state.egress.clear();
            state.overflowed = true;
            state.requires_reset = true;
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "external terminal egress queue overflow",
            ));
        }
        state.egress.extend_from_slice(bytes);
        Ok(())
    }

    fn write_input(&self, bytes: &[u8]) -> std::io::Result<()> {
        let _operation = self.operation.lock().unwrap();
        {
            let state = self.state.lock().unwrap();
            if state.owner.is_none() || state.requires_reset || state.overflowed {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::NotConnected,
                    "external terminal owner must claim and reset before input",
                ));
            }
        }
        self.append_egress(bytes)
    }
}

impl std::fmt::Debug for ExternalTerminalRuntime {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ExternalTerminalRuntime")
            .field("no_reflow", &self.no_reflow)
            .field("scrollback", &self.scrollback)
            .finish_non_exhaustive()
    }
}

fn validate_external_owner(
    state: &ExternalTerminalState,
    owner: ExternalTerminalOwner,
    owner_generation: u64,
) -> anyhow::Result<()> {
    if state.owner != Some(owner) || state.owner_generation != owner_generation {
        anyhow::bail!(
            "external terminal owner changed: expected generation {}, got {owner_generation}",
            state.owner_generation
        );
    }
    Ok(())
}

fn external_request_digest(domain: &[u8], fields: &[&[u8]]) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update((domain.len() as u64).to_be_bytes());
    digest.update(domain);
    for field in fields {
        digest.update((field.len() as u64).to_be_bytes());
        digest.update(field);
    }
    digest.finalize().into()
}

impl SurfaceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            SurfaceKind::Pty => "pty",
            SurfaceKind::Browser => "browser",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalSearchSnapshot {
    pub active: bool,
    pub query: String,
    pub selected_match: Option<usize>,
    pub total_matches: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalInteractionSnapshot {
    pub copy_mode: bool,
    pub copy_cursor: Option<SelectionPoint>,
    pub selection: Option<SelectionSnapshot>,
    pub search: TerminalSearchSnapshot,
    pub viewport: Option<Scrollbar>,
    pub mouse_tracking: bool,
    pub cursor: Option<SelectionPoint>,
    pub cursor_visible: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalHyperlinkHit {
    pub surface_uuid: crate::SurfaceUuid,
    pub presentation_id: crate::PresentationId,
    pub presentation_generation: u64,
    pub content_sequence: u64,
    pub terminal_revision: u64,
    pub content_revision: u64,
    pub viewport_revision: u64,
    pub column: u16,
    pub row: u64,
    pub target: String,
}

#[derive(Debug, Default)]
struct TerminalSearchState {
    query: String,
    selected_match: Option<usize>,
    total_matches: usize,
}

#[derive(Debug, Default)]
struct TerminalInteractionState {
    copy_mode: bool,
    copy_cursor: Option<SelectionPoint>,
    search: Option<TerminalSearchState>,
    mouse_selection_anchor: Option<SelectionPoint>,
    mouse_autoscroll: Option<MouseSelectionAutoscrollState>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MouseSelectionAutoscrollDirection {
    Up,
    Down,
}

struct MouseSelectionAutoscrollState {
    generation: u64,
    direction: MouseSelectionAutoscrollDirection,
    column: u16,
    cancel: SyncSender<()>,
}

impl std::fmt::Debug for MouseSelectionAutoscrollState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MouseSelectionAutoscrollState")
            .field("generation", &self.generation)
            .field("direction", &self.direction)
            .field("column", &self.column)
            .finish_non_exhaustive()
    }
}

pub struct SurfaceMeta {
    pub id: SurfaceId,
    pub uuid: crate::SurfaceUuid,
    /// User-assigned tab name (rename tab); shared by every surface kind.
    pub(crate) name: Mutex<Option<String>>,
    pub(crate) selection: Mutex<Option<String>>,
}

/// A pane tab runtime.
pub enum Surface {
    Pty(PtySurface),
    Browser(BrowserSurface),
}

impl Deref for Surface {
    type Target = SurfaceMeta;

    fn deref(&self) -> &Self::Target {
        match self {
            Surface::Pty(surface) => &surface.meta,
            Surface::Browser(surface) => &surface.meta,
        }
    }
}

/// A single terminal surface: PTY child plus ghostty VT state.
///
/// The terminal is behind a mutex; the pty reader thread holds it only
/// while feeding bytes, renderers hold it only while snapshotting into a
/// [`RenderState`].
pub struct PtySurface {
    pub(crate) meta: SurfaceMeta,
    term: Mutex<Terminal>,
    mouse_encoders: Mutex<MouseEncoders>,
    interaction: Mutex<TerminalInteractionState>,
    input_authority: Arc<InputAuthority>,
    writer: Mutex<Box<dyn Write + Send>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send>>,
    /// Present only when Ghostty state is fed by an external producer and no
    /// local PTY or child process exists.
    external: Option<Arc<ExternalTerminalRuntime>>,
    pid: Option<u32>,
    command: Vec<String>,
    tty_name: Option<PathBuf>,
    cwd: Option<String>,
    wait_after_command: bool,
    dead: AtomicBool,
    /// Set when output arrived since the last render; cleared by the
    /// frontend when it draws.
    dirty: AtomicBool,
    title: Mutex<String>,
    pwd: Mutex<Option<String>>,
    size: Mutex<(u16, u16)>,
    mux: Weak<Mux>,
    /// Live output subscribers (attach streams). Guarded by the terminal
    /// lock ordering: the reader thread broadcasts while holding the
    /// terminal lock, and [`Surface::attach_stream`] registers taps under
    /// the same lock, so a subscriber sees exactly the bytes applied
    /// after its replay snapshot — no gap, no duplication.
    taps: Mutex<Vec<AttachTap>>,
    /// Single consume-once Ghostty render state shared by the local TUI and
    /// every protocol-v7 render attachment.
    render: Mutex<RenderHub>,
    /// Per-renderer semantic encoders. Every attachment owns an independent
    /// canonical cache because overflow can invalidate only that consumer.
    semantic_scenes: Mutex<SemanticSceneHub>,
    semantic_attachment_count: AtomicUsize,
    semantic_identity: SemanticSceneTerminalIdentity,
    render_generation: AtomicU64,
    accessibility_content_revision: AtomicU64,
    accessibility_viewport_revision: AtomicU64,
    accessibility_focus_revision: AtomicU64,
    /// AX reads are opt-in. Once requested for a rendered terminal, retain a
    /// short exact-sequence history until the semantic renderer detaches.
    accessibility_demanded: AtomicBool,
    accessibility_frames: Mutex<VecDeque<TerminalAccessibilitySnapshot>>,
    frame_requests: SyncSender<u64>,
}

#[derive(Default)]
struct InputAuthority {
    held: Mutex<bool>,
    available: Condvar,
}

/// An owned terminal-input reservation that can cross into the bounded
/// launch-completion thread without exposing the writer itself.
pub(crate) struct InputAuthorityPermit {
    authority: Arc<InputAuthority>,
}

impl InputAuthority {
    fn acquire(self: &Arc<Self>) -> InputAuthorityPermit {
        let mut held = self.held.lock().unwrap();
        while *held {
            held = self.available.wait(held).unwrap();
        }
        *held = true;
        drop(held);
        InputAuthorityPermit { authority: self.clone() }
    }
}

impl Drop for InputAuthorityPermit {
    fn drop(&mut self) {
        let mut held = self.authority.held.lock().unwrap();
        debug_assert!(*held);
        *held = false;
        self.authority.available.notify_one();
    }
}

#[cfg(target_os = "macos")]
fn terminate_unready_launch_helper(
    child: &mut (dyn Child + Send + Sync),
    expected_process_id: Option<u32>,
) -> anyhow::Result<()> {
    const HUP_GRACE: Duration = Duration::from_millis(100);
    const KILL_GRACE: Duration = Duration::from_secs(1);

    let process_id = child
        .process_id()
        .ok_or_else(|| anyhow::anyhow!("unready launch helper has no process identity"))?;
    if Some(process_id) != expected_process_id {
        anyhow::bail!(
            "unready launch helper identity changed: expected {expected_process_id:?}, got {process_id}"
        );
    }
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return Err(std::io::Error::last_os_error()).context("create launch-helper exit watcher");
    }
    struct Queue(libc::c_int);
    impl Drop for Queue {
        fn drop(&mut self) {
            unsafe {
                libc::close(self.0);
            }
        }
    }
    let queue = Queue(queue);
    let change = libc::kevent {
        ident: process_id as libc::uintptr_t,
        filter: libc::EVFILT_PROC,
        flags: libc::EV_ADD | libc::EV_ONESHOT,
        fflags: libc::NOTE_EXIT,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    if unsafe { libc::kevent(queue.0, &change, 1, std::ptr::null_mut(), 0, std::ptr::null()) } < 0 {
        return Err(std::io::Error::last_os_error()).context("watch unready launch helper");
    }

    let mut killer = child.clone_killer();
    let _ = killer.kill();
    if !wait_for_launch_helper_exit(queue.0, HUP_GRACE)? {
        let status = unsafe { libc::kill(process_id as libc::pid_t, libc::SIGKILL) };
        if status != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error).context("kill unready launch helper");
            }
        }
        if !wait_for_launch_helper_exit(queue.0, KILL_GRACE)? {
            anyhow::bail!("unready launch helper {process_id} did not exit after SIGKILL");
        }
    }
    match child.try_wait()? {
        Some(_) => Ok(()),
        None => anyhow::bail!("unready launch helper exit was signaled but could not be reaped"),
    }
}

#[cfg(target_os = "macos")]
fn wait_for_launch_helper_exit(queue: libc::c_int, timeout: Duration) -> std::io::Result<bool> {
    let timeout = libc::timespec {
        tv_sec: timeout.as_secs().try_into().unwrap_or(libc::time_t::MAX),
        tv_nsec: timeout.subsec_nanos().into(),
    };
    let mut event = std::mem::MaybeUninit::<libc::kevent>::zeroed();
    let count =
        unsafe { libc::kevent(queue, std::ptr::null(), 0, event.as_mut_ptr(), 1, &timeout) };
    if count < 0 {
        return Err(std::io::Error::last_os_error());
    }
    if count == 0 {
        return Ok(false);
    }
    let event = unsafe { event.assume_init() };
    if event.flags & libc::EV_ERROR != 0 && event.data != 0 {
        return Err(std::io::Error::from_raw_os_error(event.data as i32));
    }
    Ok(true)
}

#[cfg(not(target_os = "macos"))]
fn terminate_unready_launch_helper(
    mut child: Box<dyn Child + Send + Sync>,
    expected_process_id: Option<u32>,
) -> anyhow::Result<()> {
    let process_id = child
        .process_id()
        .ok_or_else(|| anyhow::anyhow!("unready launch helper has no process identity"))?;
    if Some(process_id) != expected_process_id {
        anyhow::bail!(
            "unready launch helper identity changed: expected {expected_process_id:?}, got {process_id}"
        );
    }
    child.kill()?;
    let (result_tx, result_rx) = sync_channel(1);
    std::thread::Builder::new().name(format!("launch-helper-{process_id}-reaper")).spawn(
        move || {
            let _ = result_tx.send(child.wait());
        },
    )?;
    match result_rx.recv_timeout(Duration::from_secs(1)) {
        Ok(result) => result.map(|_| ()).map_err(Into::into),
        Err(RecvTimeoutError::Timeout) => {
            anyhow::bail!("unready launch helper {process_id} did not exit before deadline")
        }
        Err(RecvTimeoutError::Disconnected) => {
            anyhow::bail!("unready launch helper reaper disconnected")
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TerminalLaunchCompletionPhase {
    BeforeRelease,
    AfterRelease,
    AfterInitialInput,
}

const TERMINAL_ACCESSIBILITY_FRAME_CACHE_CAPACITY: usize = 3;

impl std::fmt::Debug for Surface {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Surface").field("id", &self.id).field("kind", &self.kind()).finish()
    }
}

impl Surface {
    pub(crate) fn spawn_with_uuid(
        id: SurfaceId,
        uuid: crate::SurfaceUuid,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        let (surface, gate) = Self::spawn_with_uuid_mode(id, uuid, opts, mux, false)?;
        debug_assert!(gate.is_none());
        Ok(surface)
    }

    /// Open the PTY and start a same-PID launch helper without executing the
    /// requested argv. The caller must release the returned gate only after
    /// its canonical topology commit is durable.
    pub(crate) fn prepare_with_uuid(
        id: SurfaceId,
        uuid: crate::SurfaceUuid,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<(Arc<Surface>, crate::launch_gate::TerminalLaunchGate)> {
        let (surface, gate) = Self::spawn_with_uuid_mode(id, uuid, opts, mux, true)?;
        Ok((surface, gate.expect("gated terminal spawn returns a launch gate")))
    }

    fn spawn_with_uuid_mode(
        id: SurfaceId,
        uuid: crate::SurfaceUuid,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        gated: bool,
    ) -> anyhow::Result<(Arc<Surface>, Option<crate::launch_gate::TerminalLaunchGate>)> {
        let semantic_identity = SemanticSceneTerminalIdentity::random(uuid)?;
        let pty = native_pty_system().openpty(PtySize {
            rows: opts.rows,
            cols: opts.cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let argv = opts
            .command
            .clone()
            .filter(|argv| !argv.is_empty())
            .unwrap_or_else(|| vec![platform::default_shell()]);
        if opts
            .extra_env
            .iter()
            .any(|(name, _)| crate::launch_gate::is_reserved_environment_name(name))
        {
            anyhow::bail!("terminal environment uses a reserved launch-gate name");
        }
        let pending_gate =
            gated.then(|| crate::launch_gate::PendingTerminalLaunchGate::new(&argv)).transpose()?;
        let mut cmd = match pending_gate.as_ref() {
            Some(gate) => gate.helper_command()?,
            None => {
                let mut command = CommandBuilder::new(&argv[0]);
                command.args(&argv[1..]);
                command
            }
        };
        cmd.env("TERM", &opts.term);
        for (k, v) in &opts.extra_env {
            cmd.env(k, v);
        }
        if let Some(gate) = &pending_gate {
            // Private gate routing is authoritative even if a lower-level
            // caller bypassed the request validator above.
            gate.apply_private_environment(&mut cmd);
        }
        let cwd = opts
            .cwd
            .clone()
            .or_else(|| platform::home_dir().map(|path| path.to_string_lossy().into_owned()));
        if let Some(cwd) = cwd.as_deref() {
            cmd.cwd(cwd);
        }

        let mut child = pty.slave.spawn_command(cmd)?;
        let pid = child.process_id();
        let gate = match pending_gate.map(|gate| gate.finish(pid)).transpose() {
            Ok(gate) => gate,
            Err(error) => {
                #[cfg(target_os = "macos")]
                let cleanup = terminate_unready_launch_helper(child.as_mut(), pid);
                #[cfg(not(target_os = "macos"))]
                let cleanup = terminate_unready_launch_helper(child, pid);
                if let Err(cleanup) = cleanup {
                    return Err(error).context(format!(
                        "launch gate failed and helper cleanup also failed: {cleanup:#}"
                    ));
                }
                return Err(error);
            }
        };
        drop(pty.slave);
        let killer = child.clone_killer();
        #[cfg(unix)]
        let tty_name = pty.master.tty_name();
        #[cfg(not(unix))]
        let tty_name = None;
        let mut reader = pty.master.try_clone_reader()?;
        let writer = pty.master.take_writer()?;

        // Query responses generated while parsing pty output are queued
        // here and flushed to the pty after each vt_write (the callback
        // runs under the terminal lock; writing to the pty from inside it
        // is fine, but keeping it queued makes the locking obvious).
        let pending_responses: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let title_changed = Arc::new(AtomicBool::new(false));

        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let pending = pending_responses.clone();
                move |bytes| pending.lock().unwrap().extend_from_slice(bytes)
            })),
            on_title_changed: Some(Box::new({
                let flag = title_changed.clone();
                move || flag.store(true, Ordering::Relaxed)
            })),
            on_bell: Some(Box::new({
                let mux = mux.clone();
                move || {
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::Bell(id));
                    }
                }
            })),
        };

        let mut term = Terminal::new(opts.cols, opts.rows, opts.scrollback, callbacks)?;
        // Semantic Kitty capture requires nonzero terminal pixel geometry even
        // before the first renderer-reported resize. Use the same nominal cell
        // metrics as later PTY geometry updates.
        term.resize(opts.cols.max(1), opts.rows.max(1), 8, 16)?;
        if let Some(mux) = mux.upgrade() {
            let colors = mux.default_colors();
            term.set_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            term.set_default_cursor(colors.cursor_style, colors.cursor_blink);
        }
        let mut mouse_encoders = MouseEncoders::new()?;
        mouse_encoders.sync_from_terminal(&term);
        let render_state = RenderState::new()?;
        let (frame_requests, frame_rx) = sync_channel(1);
        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta { id, uuid, name: Mutex::new(None), selection: Mutex::new(None) },
            term: Mutex::new(term),
            mouse_encoders: Mutex::new(mouse_encoders),
            interaction: Mutex::new(TerminalInteractionState::default()),
            input_authority: Arc::new(InputAuthority::default()),
            writer: Mutex::new(writer),
            master: Mutex::new(pty.master),
            killer: Mutex::new(killer),
            external: None,
            pid,
            command: argv,
            tty_name,
            cwd,
            wait_after_command: opts.wait_after_command,
            dead: AtomicBool::new(false),
            dirty: AtomicBool::new(false),
            title: Mutex::new(String::new()),
            pwd: Mutex::new(None),
            size: Mutex::new((opts.cols, opts.rows)),
            mux: mux.clone(),
            taps: Mutex::new(Vec::new()),
            render: Mutex::new(RenderHub {
                state: Box::new(render_state),
                built_generation: 0,
                latest: None,
                taps: Vec::new(),
            }),
            semantic_scenes: Mutex::new(SemanticSceneHub::default()),
            semantic_attachment_count: AtomicUsize::new(0),
            semantic_identity,
            render_generation: AtomicU64::new(1),
            accessibility_content_revision: AtomicU64::new(1),
            accessibility_viewport_revision: AtomicU64::new(1),
            accessibility_focus_revision: AtomicU64::new(1),
            accessibility_demanded: AtomicBool::new(false),
            accessibility_frames: Mutex::new(VecDeque::new()),
            frame_requests,
        }));

        spawn_frame_producer(&surface, frame_rx)?;

        // PTY reader: pty bytes -> terminal state -> SurfaceOutput events.
        std::thread::Builder::new().name(format!("surface-{id}-reader")).spawn({
            let surface = surface.clone();
            move || {
                let mut buf = [0u8; 64 * 1024];
                loop {
                    let n = match reader.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    let pty = surface.as_pty().expect("surface reader got non-pty surface");
                    let mut scroll_changed = None;
                    let generation = {
                        let mut term = pty.term.lock().unwrap();
                        let before = terminal_scroll_position(&term);
                        term.vt_write(&buf[..n]);
                        // Active-search ranges are presentation state over
                        // canonical content. Refresh them before publishing
                        // the next scene so output cannot leave stale ranges.
                        let _ = pty.refresh_active_search_locked(&mut term);
                        pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                        let after = terminal_scroll_position(&term);
                        pty.broadcast_attach_output(&buf[..n]);
                        if title_changed.swap(false, Ordering::Relaxed) {
                            let title = term.title().unwrap_or_default();
                            *pty.title.lock().unwrap() = title.clone();
                            if let Some(mux) = mux.upgrade() {
                                mux.emit(MuxEvent::TitleChanged {
                                    surface: surface.id,
                                    title: title.into(),
                                });
                            }
                        }
                        if let Some(pwd) = term.pwd() {
                            *pty.pwd.lock().unwrap() = Some(pwd);
                        }
                        if before != after {
                            pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
                            scroll_changed = Some(after);
                            broadcast_render_scroll_locked(pty, after);
                        }
                        pty.accessibility_content_revision.fetch_add(1, Ordering::AcqRel);
                        pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
                    };
                    pty.request_frame(generation);
                    if let Some((offset, at_bottom)) = scroll_changed
                        && let Some(mux) = mux.upgrade()
                    {
                        mux.emit(MuxEvent::ScrollChanged {
                            surface: surface.id,
                            offset,
                            at_bottom,
                        });
                    }
                    let responses = std::mem::take(&mut *pending_responses.lock().unwrap());
                    if !responses.is_empty() {
                        let _ = surface.write_bytes(&responses);
                    }
                }
                if let Some(pty) = surface.as_pty() {
                    pty.dead.store(true, Ordering::Release);
                }
                if let Some(mux) = mux.upgrade() {
                    mux.surface_runtime_exited(&surface);
                }
            }
        })?;

        // Child reaper: avoid zombies; the reader thread handles EOF.
        std::thread::Builder::new().name(format!("surface-{id}-wait")).spawn(move || {
            let _ = child.wait();
        })?;

        Ok((surface, gate))
    }

    /// Create Ghostty parser, semantic scene, and renderer state without
    /// opening a PTY or spawning a child. External output must cross the
    /// owner/generation/sequence-fenced APIs below.
    pub(crate) fn spawn_external_with_uuid(
        id: SurfaceId,
        uuid: crate::SurfaceUuid,
        mut opts: SurfaceOptions,
        no_reflow: bool,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        opts.cols = opts.cols.max(1);
        opts.rows = opts.rows.max(1);
        let semantic_identity = SemanticSceneTerminalIdentity::random(uuid)?;
        let external = Arc::new(ExternalTerminalRuntime::new(no_reflow, opts.scrollback));
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let external = external.clone();
                move |bytes| {
                    let _ = external.append_egress(bytes);
                }
            })),
            on_bell: Some(Box::new({
                let mux = mux.clone();
                move || {
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::Bell(id));
                    }
                }
            })),
            ..Callbacks::default()
        };
        let mut term = Terminal::new(opts.cols, opts.rows, opts.scrollback, callbacks)?;
        term.resize(opts.cols, opts.rows, 8, 16)?;
        if let Some(mux) = mux.upgrade() {
            let colors = mux.default_colors();
            term.set_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            term.set_default_cursor(colors.cursor_style, colors.cursor_blink);
        }
        let mut mouse_encoders = MouseEncoders::new()?;
        mouse_encoders.sync_from_terminal(&term);
        let render_state = RenderState::new()?;
        let (frame_requests, frame_rx) = sync_channel(1);
        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta { id, uuid, name: Mutex::new(None), selection: Mutex::new(None) },
            term: Mutex::new(term),
            mouse_encoders: Mutex::new(mouse_encoders),
            interaction: Mutex::new(TerminalInteractionState::default()),
            input_authority: Arc::new(InputAuthority::default()),
            writer: Mutex::new(Box::new(std::io::sink())),
            master: Mutex::new(Box::new(ParserOnlyMasterPty::new(opts.cols, opts.rows))),
            killer: Mutex::new(Box::new(ParserOnlyChildKiller)),
            external: Some(external),
            pid: None,
            command: Vec::new(),
            tty_name: None,
            cwd: None,
            wait_after_command: false,
            dead: AtomicBool::new(false),
            dirty: AtomicBool::new(false),
            title: Mutex::new(String::new()),
            pwd: Mutex::new(None),
            size: Mutex::new((opts.cols, opts.rows)),
            mux,
            taps: Mutex::new(Vec::new()),
            render: Mutex::new(RenderHub {
                state: Box::new(render_state),
                built_generation: 0,
                latest: None,
                taps: Vec::new(),
            }),
            semantic_scenes: Mutex::new(SemanticSceneHub::default()),
            semantic_attachment_count: AtomicUsize::new(0),
            semantic_identity,
            render_generation: AtomicU64::new(1),
            accessibility_content_revision: AtomicU64::new(1),
            accessibility_viewport_revision: AtomicU64::new(1),
            accessibility_focus_revision: AtomicU64::new(1),
            accessibility_demanded: AtomicBool::new(false),
            accessibility_frames: Mutex::new(VecDeque::new()),
            frame_requests,
        }));
        spawn_frame_producer(&surface, frame_rx)?;
        Ok(surface)
    }

    #[cfg(test)]
    pub(crate) fn spawn_for_test(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_for_test_with_uuid(id, crate::SurfaceUuid::new(), opts, mux)
    }

    #[cfg(test)]
    pub(crate) fn spawn_for_test_with_uuid(
        id: SurfaceId,
        uuid: crate::SurfaceUuid,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_for_test_with_frame_producer(id, uuid, opts, mux, false)
    }

    #[cfg(test)]
    fn spawn_for_test_with_frame_producer(
        id: SurfaceId,
        uuid: crate::SurfaceUuid,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        start_frame_producer: bool,
    ) -> anyhow::Result<Arc<Surface>> {
        let semantic_identity = SemanticSceneTerminalIdentity::random(uuid)?;
        let callbacks = Callbacks {
            on_bell: Some(Box::new({
                let mux = mux.clone();
                move || {
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::Bell(id));
                    }
                }
            })),
            ..Callbacks::default()
        };

        let mut term = Terminal::new(opts.cols, opts.rows, opts.scrollback, callbacks)?;
        term.resize(opts.cols.max(1), opts.rows.max(1), 8, 16)?;
        if let Some(mux) = mux.upgrade() {
            let colors = mux.default_colors();
            term.set_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            term.set_default_cursor(colors.cursor_style, colors.cursor_blink);
        }
        let mut mouse_encoders = MouseEncoders::new()?;
        mouse_encoders.sync_from_terminal(&term);

        let render_state = RenderState::new()?;
        let (frame_requests, frame_rx) = sync_channel(1);

        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta { id, uuid, name: Mutex::new(None), selection: Mutex::new(None) },
            term: Mutex::new(term),
            mouse_encoders: Mutex::new(mouse_encoders),
            interaction: Mutex::new(TerminalInteractionState::default()),
            input_authority: Arc::new(InputAuthority::default()),
            writer: Mutex::new(Box::new(std::io::sink())),
            master: Mutex::new(Box::new(TestMasterPty {
                size: Mutex::new(PtySize {
                    rows: opts.rows,
                    cols: opts.cols,
                    pixel_width: 0,
                    pixel_height: 0,
                }),
                tty_name: PathBuf::from(format!("/dev/ttys{id}")),
            })),
            killer: Mutex::new(Box::new(TestChildKiller)),
            external: None,
            pid: Some(id as u32),
            command: opts.command.unwrap_or_else(|| vec![platform::default_shell()]),
            tty_name: Some(PathBuf::from(format!("/dev/ttys{id}"))),
            cwd: opts.cwd,
            wait_after_command: opts.wait_after_command,
            dead: AtomicBool::new(false),
            dirty: AtomicBool::new(false),
            title: Mutex::new(String::new()),
            pwd: Mutex::new(None),
            size: Mutex::new((opts.cols, opts.rows)),
            mux,
            taps: Mutex::new(Vec::new()),
            render: Mutex::new(RenderHub {
                state: Box::new(render_state),
                built_generation: 0,
                latest: None,
                taps: Vec::new(),
            }),
            semantic_scenes: Mutex::new(SemanticSceneHub::default()),
            semantic_attachment_count: AtomicUsize::new(0),
            semantic_identity,
            render_generation: AtomicU64::new(1),
            accessibility_content_revision: AtomicU64::new(1),
            accessibility_viewport_revision: AtomicU64::new(1),
            accessibility_focus_revision: AtomicU64::new(1),
            accessibility_demanded: AtomicBool::new(false),
            accessibility_frames: Mutex::new(VecDeque::new()),
            frame_requests,
        }));
        if start_frame_producer {
            spawn_frame_producer(&surface, frame_rx)?;
        }
        Ok(surface)
    }

    fn as_pty(&self) -> Option<&PtySurface> {
        match self {
            Surface::Pty(surface) => Some(surface),
            Surface::Browser(_) => None,
        }
    }

    pub(crate) fn as_browser(&self) -> Option<&BrowserSurface> {
        match self {
            Surface::Pty(_) => None,
            Surface::Browser(surface) => Some(surface),
        }
    }

    pub fn kind(&self) -> SurfaceKind {
        match self {
            Surface::Pty(_) => SurfaceKind::Pty,
            Surface::Browser(_) => SurfaceKind::Browser,
        }
    }

    pub(crate) fn is_external_terminal(&self) -> bool {
        self.as_pty().is_some_and(|pty| pty.external.is_some())
    }

    pub(crate) fn external_terminal_recipe(&self) -> Option<(u16, u16, usize, bool)> {
        let pty = self.as_pty()?;
        let external = pty.external.as_ref()?;
        let (cols, rows) = *pty.size.lock().unwrap();
        Some((cols, rows, external.scrollback, external.no_reflow))
    }

    pub(crate) fn claim_external_terminal(
        &self,
        owner: ExternalTerminalOwner,
        request_id: uuid::Uuid,
    ) -> anyhow::Result<ExternalTerminalClaimReceipt> {
        if request_id.is_nil() {
            anyhow::bail!("external terminal claim request_id must be nonzero");
        }
        let external = self
            .as_pty()
            .and_then(|pty| pty.external.as_ref())
            .ok_or_else(|| anyhow::anyhow!("surface {} is not an external terminal", self.id))?;
        let _operation = external.operation.lock().unwrap();
        let mut state = external.state.lock().unwrap();
        if let Some(replay) = &state.last_claim
            && replay.receipt.request_id == request_id
        {
            if replay.owner != owner {
                anyhow::bail!("external terminal claim request_id payload changed");
            }
            let mut receipt = replay.receipt.clone();
            receipt.replayed = true;
            return Ok(receipt);
        }
        let owner_generation = state
            .owner_generation
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("external terminal owner generation exhausted"))?;
        let required_output_generation = state
            .output_generation
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("external terminal output generation exhausted"))?;
        state.owner = Some(owner);
        state.owner_generation = owner_generation;
        state.requires_reset = true;
        state.egress.clear();
        state.overflowed = false;
        state.last_reset = None;
        state.last_output = None;
        let receipt = ExternalTerminalClaimReceipt {
            request_id,
            owner_generation,
            required_output_generation,
            replayed: false,
        };
        state.last_claim = Some(ExternalClaimReplay { owner, receipt: receipt.clone() });
        Ok(receipt)
    }

    pub(crate) fn reset_external_terminal(
        &self,
        owner: ExternalTerminalOwner,
        owner_generation: u64,
        request_id: uuid::Uuid,
        output_generation: u64,
        cols: u16,
        rows: u16,
        seed: &[u8],
    ) -> anyhow::Result<ExternalTerminalOutputReceipt> {
        if request_id.is_nil() || output_generation == 0 || cols == 0 || rows == 0 {
            anyhow::bail!("external terminal reset identity, generation, and size must be nonzero");
        }
        let pty = self
            .as_pty()
            .ok_or_else(|| anyhow::anyhow!("surface {} is not a terminal", self.id))?;
        let external = pty
            .external
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("surface {} is not an external terminal", self.id))?;
        let digest = external_request_digest(
            b"reset",
            &[
                &owner_generation.to_be_bytes(),
                &output_generation.to_be_bytes(),
                &cols.to_be_bytes(),
                &rows.to_be_bytes(),
                seed,
            ],
        );
        let _operation = external.operation.lock().unwrap();
        {
            let mut state = external.state.lock().unwrap();
            if let Some(replay) = &state.last_reset
                && replay.receipt.request_id == request_id
            {
                if replay.digest != digest {
                    anyhow::bail!("external terminal reset request_id payload changed");
                }
                let mut receipt = replay.receipt.clone();
                receipt.replayed = true;
                return Ok(receipt);
            }
            validate_external_owner(&state, owner, owner_generation)?;
            let required = state
                .output_generation
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("external terminal output generation exhausted"))?;
            if output_generation != required {
                anyhow::bail!(
                    "external terminal reset generation changed: expected {required}, got {output_generation}"
                );
            }
            state.requires_reset = true;
            state.egress.clear();
            state.overflowed = false;
        }

        let generation = {
            let mut term = pty.term.lock().unwrap();
            term.reset();
            let restore_wraparound = external.no_reflow && term.mode(7, false);
            if restore_wraparound {
                let _ = term.set_mode(7, false, false);
            }
            term.resize(cols, rows, 8, 16)?;
            if restore_wraparound {
                let _ = term.set_mode(7, false, true);
            }
            if !seed.is_empty() {
                term.vt_write(seed);
            }
            pty.refresh_active_search_locked(&mut term)?;
            pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
            *pty.size.lock().unwrap() = (cols, rows);
            let _ = pty.master.lock().unwrap().resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            });
            let replay = term.vt_replay_bounded(VT_REPLAY_MAX_BYTES).unwrap_or_default();
            pty.broadcast_attach_frame(AttachFrame::Resized { cols, rows, replay });
            let title = term.title().unwrap_or_default();
            *pty.title.lock().unwrap() = title;
            *pty.pwd.lock().unwrap() = term.pwd();
            pty.accessibility_content_revision.fetch_add(1, Ordering::AcqRel);
            pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
        };
        pty.request_frame(generation);
        if !pty.dirty.swap(true, Ordering::AcqRel)
            && let Some(mux) = pty.mux.upgrade()
        {
            mux.emit(MuxEvent::SurfaceOutput(self.id));
        }

        let mut state = external.state.lock().unwrap();
        state.output_generation = output_generation;
        state.next_output_sequence = 1;
        if state.overflowed {
            state.requires_reset = true;
            anyhow::bail!("external terminal reset egress overflowed; another reset is required");
        }
        state.requires_reset = false;
        let egress = std::mem::take(&mut state.egress);
        let receipt = ExternalTerminalOutputReceipt {
            request_id,
            owner_generation,
            output_generation,
            accepted_sequence: 0,
            next_sequence: 1,
            egress,
            replayed: false,
        };
        state.last_reset = Some(ExternalOutputReplay { digest, receipt: receipt.clone() });
        state.last_output = None;
        Ok(receipt)
    }

    pub(crate) fn apply_external_terminal_output(
        &self,
        owner: ExternalTerminalOwner,
        owner_generation: u64,
        request_id: uuid::Uuid,
        output_generation: u64,
        sequence: u64,
        bytes: &[u8],
    ) -> anyhow::Result<ExternalTerminalOutputReceipt> {
        if request_id.is_nil() || output_generation == 0 || sequence == 0 {
            anyhow::bail!("external terminal output request and sequence must be nonzero");
        }
        let pty = self
            .as_pty()
            .ok_or_else(|| anyhow::anyhow!("surface {} is not a terminal", self.id))?;
        let external = pty
            .external
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("surface {} is not an external terminal", self.id))?;
        let digest = external_request_digest(
            b"output",
            &[
                &owner_generation.to_be_bytes(),
                &output_generation.to_be_bytes(),
                &sequence.to_be_bytes(),
                bytes,
            ],
        );
        let _operation = external.operation.lock().unwrap();
        {
            let state = external.state.lock().unwrap();
            if let Some(replay) = &state.last_output
                && replay.receipt.request_id == request_id
            {
                if replay.digest != digest {
                    anyhow::bail!("external terminal output request_id payload changed");
                }
                let mut receipt = replay.receipt.clone();
                receipt.replayed = true;
                return Ok(receipt);
            }
            validate_external_owner(&state, owner, owner_generation)?;
            if state.requires_reset {
                anyhow::bail!(
                    "external terminal requires reset-and-seed for this generation before output"
                );
            }
            if output_generation != state.output_generation {
                anyhow::bail!(
                    "external terminal output generation changed: expected {}, got {output_generation}",
                    state.output_generation
                );
            }
            if sequence != state.next_output_sequence {
                anyhow::bail!(
                    "external terminal output sequence changed: expected {}, got {sequence}",
                    state.next_output_sequence
                );
            }
        }

        if let Err(error) = self.inject_terminal_output(bytes) {
            external.state.lock().unwrap().requires_reset = true;
            return Err(error);
        }
        let mut state = external.state.lock().unwrap();
        if state.overflowed {
            state.requires_reset = true;
            anyhow::bail!("external terminal egress overflowed; a generation reset is required");
        }
        let next_sequence = sequence
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("external terminal output sequence exhausted"))?;
        state.next_output_sequence = next_sequence;
        let egress = std::mem::take(&mut state.egress);
        let receipt = ExternalTerminalOutputReceipt {
            request_id,
            owner_generation,
            output_generation,
            accepted_sequence: sequence,
            next_sequence,
            egress,
            replayed: false,
        };
        state.last_output = Some(ExternalOutputReplay { digest, receipt: receipt.clone() });
        Ok(receipt)
    }

    pub(crate) fn drain_external_terminal_egress(
        &self,
        owner: ExternalTerminalOwner,
        owner_generation: u64,
    ) -> anyhow::Result<Vec<u8>> {
        let external = self
            .as_pty()
            .and_then(|pty| pty.external.as_ref())
            .ok_or_else(|| anyhow::anyhow!("surface {} is not an external terminal", self.id))?;
        let _operation = external.operation.lock().unwrap();
        let mut state = external.state.lock().unwrap();
        validate_external_owner(&state, owner, owner_generation)?;
        if state.requires_reset || state.overflowed {
            anyhow::bail!("external terminal requires a generation reset before egress drain");
        }
        Ok(std::mem::take(&mut state.egress))
    }

    /// Write input bytes to the PTY child.
    pub fn write_bytes(&self, bytes: &[u8]) -> std::io::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "browser surface does not accept PTY bytes",
            ));
        };
        if let Some(external) = &pty.external {
            return external.write_input(bytes);
        }
        let _authority = pty.input_authority.acquire();
        let mut writer = pty.writer.lock().unwrap();
        writer.write_all(bytes)?;
        writer.flush()
    }

    /// Write a protocol input payload, conditionally applying bracketed-paste
    /// markers from a terminal-mode snapshot taken before the PTY write.
    pub fn write_paste(&self, bytes: &[u8]) -> std::io::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "browser surface does not accept PTY bytes",
            ));
        };
        if bytes.is_empty() {
            return Ok(());
        }
        let bracketed = {
            let term = pty.term.lock().unwrap();
            term.mode(2004, false)
        };
        if let Some(external) = &pty.external {
            let mut encoded =
                Vec::with_capacity(bytes.len().saturating_add(if bracketed { 12 } else { 0 }));
            if bracketed {
                encoded.extend_from_slice(b"\x1b[200~");
            }
            encoded.extend_from_slice(bytes);
            if bracketed {
                encoded.extend_from_slice(b"\x1b[201~");
            }
            return external.write_input(&encoded);
        }
        let _authority = pty.input_authority.acquire();
        let mut writer = pty.writer.lock().unwrap();
        if bracketed {
            writer.write_all(b"\x1b[200~")?;
        }
        writer.write_all(bytes)?;
        if bracketed {
            writer.write_all(b"\x1b[201~")?;
        }
        writer.flush()
    }

    pub(crate) fn reserve_input_authority(&self) -> anyhow::Result<InputAuthorityPermit> {
        let pty = self
            .as_pty()
            .ok_or_else(|| anyhow::anyhow!("surface {} is not a terminal", self.id))?;
        if pty.external.is_some() {
            anyhow::bail!("external terminal does not own a launch gate");
        }
        Ok(pty.input_authority.acquire())
    }

    /// Complete one durable launch while retaining exclusive input order.
    ///
    /// The same writer lock remains held while the helper execs and while the
    /// complete startup payload is written afterward, so protocol input cannot
    /// interleave with one-time startup input. The caller treats any error or
    /// deadline as fail-stop because the topology commit already crossed its
    /// durability boundary.
    pub(crate) fn complete_gated_launch(
        self: &Arc<Self>,
        permit: InputAuthorityPermit,
        gate: crate::launch_gate::TerminalLaunchGate,
        initial_input: Vec<u8>,
        deadline: Duration,
        phase: Option<Arc<dyn Fn(TerminalLaunchCompletionPhase) + Send + Sync>>,
    ) -> anyhow::Result<()> {
        let pty = self
            .as_pty()
            .ok_or_else(|| anyhow::anyhow!("surface {} is not a terminal", self.id))?;
        if !Arc::ptr_eq(&permit.authority, &pty.input_authority) {
            anyhow::bail!("terminal launch input reservation belongs to another surface");
        }
        let surface = self.clone();
        let (result_tx, result_rx) = sync_channel(1);
        std::thread::Builder::new().name(format!("surface-{}-launch", self.id)).spawn(
            move || {
                let result = (|| -> anyhow::Result<()> {
                    let pty =
                        surface.as_pty().expect("gated terminal launch retained its PTY surface");
                    let mut writer = pty.writer.lock().unwrap();
                    if let Some(phase) = &phase {
                        phase(TerminalLaunchCompletionPhase::BeforeRelease);
                    }
                    gate.release()?;
                    if let Some(phase) = &phase {
                        phase(TerminalLaunchCompletionPhase::AfterRelease);
                    }
                    if !initial_input.is_empty() {
                        writer.write_all(&initial_input)?;
                    }
                    writer.flush()?;
                    if let Some(phase) = &phase {
                        phase(TerminalLaunchCompletionPhase::AfterInitialInput);
                    }
                    Ok(())
                })();
                drop(permit);
                let _ = result_tx.send(result);
            },
        )?;
        match result_rx.recv_timeout(deadline) {
            Ok(result) => result,
            Err(RecvTimeoutError::Timeout) => {
                anyhow::bail!("terminal initial-input delivery deadline elapsed")
            }
            Err(RecvTimeoutError::Disconnected) => {
                anyhow::bail!("terminal launch completion thread disconnected")
            }
        }
    }

    /// Run `f` with exclusive access to the terminal state.
    ///
    /// Browser-aware code should call [`Surface::kind`] first. This
    /// method is kept for existing PTY call sites.
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> Option<R> {
        let pty = self.as_pty()?;
        let mut term = pty.term.lock().unwrap();
        let result = f(&mut term);
        pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
        Some(result)
    }

    pub fn encode_mouse(
        &self,
        input: MouseInput,
        output: &mut Vec<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        let pty = self.as_pty()?;
        match pty.mouse_encoders.try_lock() {
            Ok(mut encoders) => Some(encoders.encode(input, output)),
            Err(TryLockError::Poisoned(error)) => Some(error.into_inner().encode(input, output)),
            Err(TryLockError::WouldBlock) => None,
        }
    }

    pub fn encode_mouse_release(
        &self,
        input: MouseInput,
        output: &mut Vec<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        let pty = self.as_pty()?;
        match pty.mouse_encoders.try_lock() {
            Ok(mut encoders) => Some(encoders.encode_release(input, output)),
            Err(TryLockError::Poisoned(error)) => {
                Some(error.into_inner().encode_release(input, output))
            }
            Err(TryLockError::WouldBlock) => None,
        }
    }

    pub fn encode_mouse_press_pair(
        &self,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut Vec<u8>,
        release_output: &mut Vec<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        let pty = self.as_pty()?;
        match pty.mouse_encoders.try_lock() {
            Ok(mut encoders) => {
                Some(encoders.encode_press_pair(press, release, press_output, release_output))
            }
            Err(TryLockError::Poisoned(error)) => Some(error.into_inner().encode_press_pair(
                press,
                release,
                press_output,
                release_output,
            )),
            Err(TryLockError::WouldBlock) => None,
        }
    }

    pub fn reset_mouse_motion_dedupe(&self) {
        let Some(pty) = self.as_pty() else { return };
        pty.mouse_encoders.lock().unwrap().reset_motion_dedupe();
    }

    pub fn try_with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> anyhow::Result<R> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        Ok(f(&mut pty.term.lock().unwrap()))
    }

    /// Apply daemon-authored recovery output to canonical terminal state.
    /// This intentionally bypasses the PTY writer so the restarted child
    /// cannot interpret the notice as input.
    pub(crate) fn inject_terminal_output(&self, bytes: &[u8]) -> anyhow::Result<()> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let (generation, scroll_changed, title_changed) = {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            term.vt_write(bytes);
            pty.refresh_active_search_locked(&mut term)?;
            pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
            pty.broadcast_attach_output(bytes);
            let after = terminal_scroll_position(&term);
            if after != before {
                pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
                broadcast_render_scroll_locked(pty, after);
            }
            let title = term.title().unwrap_or_default();
            let title_changed = *pty.title.lock().unwrap() != title;
            if title_changed {
                *pty.title.lock().unwrap() = title;
            }
            *pty.pwd.lock().unwrap() = term.pwd();
            pty.accessibility_content_revision.fetch_add(1, Ordering::AcqRel);
            (
                pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1,
                (after != before).then_some(after),
                title_changed,
            )
        };
        pty.request_frame(generation);
        if let Some(mux) = pty.mux.upgrade() {
            if !pty.dirty.swap(true, Ordering::AcqRel) {
                mux.emit(MuxEvent::SurfaceOutput(self.id));
            }
            if let Some((offset, at_bottom)) = scroll_changed {
                mux.emit(MuxEvent::ScrollChanged { surface: self.id, offset, at_bottom });
            }
            if title_changed {
                mux.emit(MuxEvent::TitleChanged { surface: self.id, title: self.title().into() });
            }
        }
        Ok(())
    }

    pub(crate) fn terminal_interaction_snapshot(
        &self,
    ) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have terminal interaction state");
        };
        let mut term = pty.term.lock().unwrap();
        let interaction = pty.interaction.lock().unwrap();
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_accessibility_snapshot(
        &self,
        presentation_id: crate::PresentationId,
        presentation_generation: u64,
        focused: bool,
    ) -> anyhow::Result<TerminalAccessibilitySnapshot> {
        let expected_content_sequence = self
            .as_pty()
            .ok_or_else(|| {
                anyhow::anyhow!("browser surface does not have terminal accessibility state")
            })?
            .render_generation
            .load(Ordering::Acquire);
        self.terminal_accessibility_snapshot_at(
            presentation_id,
            presentation_generation,
            focused,
            expected_content_sequence,
        )
    }

    pub(crate) fn terminal_accessibility_snapshot_at(
        &self,
        presentation_id: crate::PresentationId,
        presentation_generation: u64,
        focused: bool,
        expected_content_sequence: u64,
    ) -> anyhow::Result<TerminalAccessibilitySnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have terminal accessibility state");
        };
        let mut terminal = pty.term.lock().unwrap();
        pty.accessibility_demanded.store(true, Ordering::Release);
        let render_revision = pty.render_generation.load(Ordering::Acquire);
        if expected_content_sequence == 0 {
            anyhow::bail!("terminal accessibility content sequence must be nonzero");
        }
        let mut snapshot = pty
            .accessibility_frames
            .lock()
            .unwrap()
            .iter()
            .find(|snapshot| snapshot.content_sequence == expected_content_sequence)
            .cloned();
        if snapshot.is_none() && render_revision == expected_content_sequence {
            let identity = TerminalAccessibilityIdentity {
                surface_uuid: self.uuid,
                presentation_id,
                presentation_generation,
                content_sequence: expected_content_sequence,
                terminal_revision: render_revision,
                content_revision: pty.accessibility_content_revision.load(Ordering::Acquire),
                viewport_revision: pty.accessibility_viewport_revision.load(Ordering::Acquire),
                focused,
            };
            let built = build_terminal_accessibility_snapshot(&mut terminal, identity)?;
            pty.cache_accessibility_frame(built.clone());
            snapshot = Some(built);
        }
        let Some(mut snapshot) = snapshot else {
            anyhow::bail!(
                "terminal accessibility frame sequence {expected_content_sequence} is unavailable; current sequence is {render_revision}"
            );
        };
        let focus_revision = pty.accessibility_focus_revision.load(Ordering::Acquire);
        snapshot.presentation_id = presentation_id;
        snapshot.presentation_generation = presentation_generation;
        snapshot.terminal_revision = expected_content_sequence.saturating_add(focus_revision);
        snapshot.focused = focused;
        Ok(snapshot)
    }

    pub(crate) fn terminal_hyperlink_at_viewport_cell(
        &self,
        presentation_id: crate::PresentationId,
        presentation_generation: u64,
        focused: bool,
        expected_content_sequence: u64,
        column: u16,
        viewport_row: u16,
    ) -> anyhow::Result<TerminalHyperlinkHit> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have terminal hyperlink state");
        };
        let mut terminal = pty.term.lock().unwrap();
        let content_sequence = pty.render_generation.load(Ordering::Acquire);
        if expected_content_sequence == 0 || content_sequence != expected_content_sequence {
            anyhow::bail!(
                "stale terminal frame sequence {expected_content_sequence}; current sequence is {content_sequence}"
            );
        }
        let focus_revision = pty.accessibility_focus_revision.load(Ordering::Acquire);
        let identity = TerminalAccessibilityIdentity {
            surface_uuid: self.uuid,
            presentation_id,
            presentation_generation,
            content_sequence,
            terminal_revision: content_sequence.saturating_add(focus_revision),
            content_revision: pty.accessibility_content_revision.load(Ordering::Acquire),
            viewport_revision: pty.accessibility_viewport_revision.load(Ordering::Acquire),
            focused,
        };
        let snapshot = build_terminal_accessibility_snapshot(&mut terminal, identity)?;
        if column >= snapshot.columns || viewport_row >= snapshot.rows {
            anyhow::bail!("terminal hyperlink cell is outside the rendered viewport");
        }
        let absolute_row = snapshot.viewport_offset.saturating_add(u64::from(viewport_row));
        let link = snapshot
            .links
            .into_iter()
            .find(|link| {
                link.row == absolute_row && column >= link.start_column && column <= link.end_column
            })
            .ok_or_else(|| anyhow::anyhow!("terminal cell has no hyperlink"))?;
        Ok(TerminalHyperlinkHit {
            surface_uuid: self.uuid,
            presentation_id,
            presentation_generation,
            content_sequence,
            terminal_revision: snapshot.terminal_revision,
            content_revision: snapshot.content_revision,
            viewport_revision: snapshot.viewport_revision,
            column,
            row: absolute_row,
            target: link.target,
        })
    }

    pub(crate) fn activate_terminal_accessibility_link(
        &self,
        presentation_id: crate::PresentationId,
        presentation_generation: u64,
        focused: bool,
        terminal_revision: u64,
        content_revision: u64,
        viewport_revision: u64,
        link_id: &str,
    ) -> anyhow::Result<String> {
        let snapshot = self.terminal_accessibility_snapshot(
            presentation_id,
            presentation_generation,
            focused,
        )?;
        if snapshot.terminal_revision != terminal_revision
            || snapshot.content_revision != content_revision
            || snapshot.viewport_revision != viewport_revision
        {
            anyhow::bail!("stale terminal accessibility snapshot");
        }
        snapshot
            .links
            .into_iter()
            .find(|link| link.id == link_id)
            .map(|link| link.target)
            .ok_or_else(|| anyhow::anyhow!("stale terminal accessibility link"))
    }

    pub(crate) fn terminal_accessibility_focus_changed(&self) {
        if let Some(pty) = self.as_pty() {
            pty.accessibility_focus_revision.fetch_add(1, Ordering::AcqRel);
        }
    }

    pub(crate) fn terminal_selection_clear(&self) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have terminal selection state");
        };
        let mut term = pty.term.lock().unwrap();
        term.clear_selection();
        let mut interaction = pty.interaction.lock().unwrap();
        if let Some(search) = interaction.search.as_mut() {
            search.selected_match = None;
        }
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_selection_select_all(
        &self,
    ) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have terminal selection state");
        };
        let mut term = pty.term.lock().unwrap();
        let selected = term.select_all()?;
        let mut interaction = pty.interaction.lock().unwrap();
        if let Some(selection) = selected {
            interaction.copy_cursor = Some(selection.end);
        }
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_copy_mode_enter(&self) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal copy mode");
        };
        let mut term = pty.term.lock().unwrap();
        let cursor = term.select_cursor()?.end;
        term.clear_selection();
        let mut interaction = pty.interaction.lock().unwrap();
        interaction.copy_mode = true;
        interaction.copy_cursor = Some(cursor);
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_copy_mode_exit(&self) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal copy mode");
        };
        let mut term = pty.term.lock().unwrap();
        term.clear_selection();
        let mut interaction = pty.interaction.lock().unwrap();
        interaction.copy_mode = false;
        interaction.copy_cursor = None;
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_copy_mode_start_selection(
        &self,
        line: bool,
        count: usize,
    ) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal copy mode");
        };
        let mut term = pty.term.lock().unwrap();
        let mut interaction = pty.interaction.lock().unwrap();
        if !interaction.copy_mode {
            anyhow::bail!("terminal copy mode is not active");
        }
        let cursor = match interaction.copy_cursor {
            Some(cursor) => cursor,
            None => term.select_cursor()?.end,
        };
        let mut selection = if line {
            term.select_line_screen(cursor)?
        } else {
            Some(term.select_point_screen(cursor)?)
        };
        if line {
            for _ in 1..count.max(1) {
                let _ = term.adjust_selection(SelectionAdjustment::Down)?;
                selection = term.adjust_selection(SelectionAdjustment::EndOfLine)?;
            }
        }
        if let Some(selection) = selection {
            interaction.copy_cursor = Some(selection.end);
        }
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_copy_mode_adjust(
        &self,
        adjustment: SelectionAdjustment,
        count: usize,
    ) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal copy mode");
        };
        let mut term = pty.term.lock().unwrap();
        let mut interaction = pty.interaction.lock().unwrap();
        if !interaction.copy_mode {
            anyhow::bail!("terminal copy mode is not active");
        }
        let extends_selection = term.current_selection()?.is_some();
        if !extends_selection {
            let cursor = match interaction.copy_cursor {
                Some(cursor) => cursor,
                None => term.select_cursor()?.end,
            };
            term.select_point_screen(cursor)?;
        }
        for _ in 0..count.max(1) {
            if let Some(selection) = term.adjust_selection(adjustment)? {
                interaction.copy_cursor = Some(selection.end);
            }
        }
        if !extends_selection {
            term.clear_selection();
        }
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_copy_mode_clear_selection(
        &self,
    ) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal copy mode");
        };
        let mut term = pty.term.lock().unwrap();
        let mut interaction = pty.interaction.lock().unwrap();
        if !interaction.copy_mode {
            anyhow::bail!("terminal copy mode is not active");
        }
        if let Some(selection) = term.current_selection()? {
            interaction.copy_cursor = Some(selection.end);
        }
        term.clear_selection();
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_copy_mode_copy_and_exit(
        &self,
    ) -> anyhow::Result<(Option<String>, TerminalInteractionSnapshot)> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal copy mode");
        };
        let mut term = pty.term.lock().unwrap();
        let text = term.current_selection()?.map(|selection| selection.text);
        term.clear_selection();
        let mut interaction = pty.interaction.lock().unwrap();
        interaction.copy_mode = false;
        interaction.copy_cursor = None;
        pty.terminal_visual_changed_locked(&mut term)?;
        let snapshot = terminal_interaction_snapshot_locked(&mut term, &interaction)?;
        Ok((text, snapshot))
    }

    pub(crate) fn terminal_search_start(&self) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal search");
        };
        let mut term = pty.term.lock().unwrap();
        let mut interaction = pty.interaction.lock().unwrap();
        interaction.search = Some(TerminalSearchState::default());
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_search_update(
        &self,
        query: String,
    ) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal search");
        };
        let mut term = pty.term.lock().unwrap();
        let mut interaction = pty.interaction.lock().unwrap();
        let search = interaction.search.get_or_insert_with(TerminalSearchState::default);
        search.query = query;
        search.selected_match = None;
        search.total_matches = 0;
        if search.query.is_empty() {
            pty.semantic_scenes.lock().unwrap().set_presentation_highlights_locked(Vec::new());
        } else {
            let result = term.search_select(&search.query, 0)?;
            search.total_matches = result.total_matches;
            search.selected_match = result.selection.is_some().then_some(0);
            pty.semantic_scenes
                .lock()
                .unwrap()
                .set_presentation_highlights_locked(search_scene_highlights(&result));
        }
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_search_navigate(
        &self,
        forward: bool,
    ) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal search");
        };
        let mut term = pty.term.lock().unwrap();
        let mut interaction = pty.interaction.lock().unwrap();
        let search = interaction
            .search
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("terminal search is not active"))?;
        if search.query.is_empty() {
            return Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?);
        }
        let desired = match (search.selected_match, search.total_matches, forward) {
            (_, 0, _) | (None, _, _) => 0,
            (Some(index), total, true) => (index + 1) % total,
            (Some(0), total, false) => total - 1,
            (Some(index), _, false) => index - 1,
        };
        let result = term.search_select(&search.query, desired)?;
        search.total_matches = result.total_matches;
        search.selected_match = result.selection.is_some().then_some(desired);
        pty.semantic_scenes
            .lock()
            .unwrap()
            .set_presentation_highlights_locked(search_scene_highlights(&result));
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_search_end(&self) -> anyhow::Result<TerminalInteractionSnapshot> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal search");
        };
        let mut term = pty.term.lock().unwrap();
        let mut interaction = pty.interaction.lock().unwrap();
        interaction.search = None;
        pty.semantic_scenes.lock().unwrap().set_presentation_highlights_locked(Vec::new());
        pty.terminal_visual_changed_locked(&mut term)?;
        Ok(terminal_interaction_snapshot_locked(&mut term, &interaction)?)
    }

    pub(crate) fn terminal_mouse_selection(
        self: &Arc<Self>,
        action: ghostty_vt::MouseAction,
        point: SelectionPoint,
        click_count: u8,
        autoscroll: Option<MouseSelectionAutoscrollDirection>,
    ) -> anyhow::Result<(bool, TerminalInteractionSnapshot)> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not support terminal selection");
        };
        let mut term = pty.term.lock().unwrap();
        let mut interaction = pty.interaction.lock().unwrap();
        let mut start_autoscroll = None;
        let handled = match action {
            ghostty_vt::MouseAction::Press => {
                cancel_mouse_selection_autoscroll_locked(&mut interaction);
                let selection = match click_count {
                    1 => Some(term.select_point_screen(point)?),
                    2 => term.select_word_screen(point)?,
                    3 => term.select_line_screen(point)?,
                    _ => unreachable!("terminal mouse click count validated by server"),
                };
                interaction.mouse_selection_anchor =
                    selection.as_ref().map(|selection| selection.start);
                selection.is_some()
            }
            ghostty_vt::MouseAction::Motion => match interaction.mouse_selection_anchor {
                Some(anchor) => {
                    term.select_range_screen(anchor, point, false)?;
                    match autoscroll {
                        Some(direction) => {
                            if let Some(active) = interaction.mouse_autoscroll.as_mut() {
                                active.direction = direction;
                                active.column = point.column;
                            } else {
                                let generation =
                                    pty.render_generation.load(Ordering::Acquire).saturating_add(1);
                                let (cancel, canceled) = sync_channel(1);
                                interaction.mouse_autoscroll =
                                    Some(MouseSelectionAutoscrollState {
                                        generation,
                                        direction,
                                        column: point.column,
                                        cancel,
                                    });
                                start_autoscroll = Some((generation, canceled));
                            }
                        }
                        None => cancel_mouse_selection_autoscroll_locked(&mut interaction),
                    }
                    true
                }
                None => false,
            },
            ghostty_vt::MouseAction::Release => {
                cancel_mouse_selection_autoscroll_locked(&mut interaction);
                let anchor = interaction.mouse_selection_anchor.take();
                if let Some(anchor) = anchor {
                    term.select_range_screen(anchor, point, false)?;
                    true
                } else {
                    false
                }
            }
        };
        if handled {
            pty.terminal_visual_changed_locked(&mut term)?;
        }
        let snapshot = terminal_interaction_snapshot_locked(&mut term, &interaction)?;
        drop(interaction);
        drop(term);
        if let Some((generation, canceled)) = start_autoscroll {
            spawn_mouse_selection_autoscroll(self, generation, canceled)?;
        }
        Ok((handled, snapshot))
    }

    fn terminal_mouse_selection_autoscroll_tick(&self, generation: u64) -> anyhow::Result<bool> {
        let Some(pty) = self.as_pty() else { return Ok(false) };
        let mut term = pty.term.lock().unwrap();
        let mut interaction = pty.interaction.lock().unwrap();
        let Some(active) = interaction.mouse_autoscroll.as_ref() else {
            return Ok(false);
        };
        if active.generation != generation || interaction.mouse_selection_anchor.is_none() {
            return Ok(false);
        }
        let anchor = interaction.mouse_selection_anchor.unwrap();
        let direction = active.direction;
        let column = active.column;
        let before = terminal_scroll_position(&term);
        term.scroll_delta(match direction {
            MouseSelectionAutoscrollDirection::Up => -1,
            MouseSelectionAutoscrollDirection::Down => 1,
        });
        let after = terminal_scroll_position(&term);
        let rows = u32::from(self.size().1.max(1));
        let endpoint = SelectionPoint {
            column,
            row: u32::try_from(after.0).unwrap_or(u32::MAX).saturating_add(match direction {
                MouseSelectionAutoscrollDirection::Up => 0,
                MouseSelectionAutoscrollDirection::Down => rows.saturating_sub(1),
            }),
        };
        term.select_range_screen(anchor, endpoint, false)?;
        pty.refresh_active_search_with_interaction_locked(&mut term, &mut interaction)?;
        if before != after {
            pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
            broadcast_render_scroll_locked(pty, after);
        }
        pty.terminal_visual_changed_locked(&mut term)?;
        drop(interaction);
        drop(term);
        if before != after
            && let Some(mux) = pty.mux.upgrade()
        {
            mux.emit(MuxEvent::ScrollChanged {
                surface: self.id,
                offset: after.0,
                at_bottom: after.1,
            });
        }
        Ok(true)
    }

    pub fn scroll_delta(&self, delta: isize) -> anyhow::Result<()> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let changed = {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            term.scroll_delta(delta);
            let after = terminal_scroll_position(&term);
            if before == after {
                None
            } else {
                pty.refresh_active_search_locked(&mut term)?;
                broadcast_render_scroll_locked(pty, after);
                pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
                let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                let _ = pty.build_frame_locked(&mut term, generation, false);
                Some(after)
            }
        };
        if let Some((offset, at_bottom)) = changed
            && let Some(mux) = pty.mux.upgrade()
        {
            mux.emit(MuxEvent::ScrollChanged { surface: self.id, offset, at_bottom });
        }
        Ok(())
    }

    pub fn scroll_to_bottom(&self) -> anyhow::Result<()> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let changed = {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            term.scroll_to_bottom();
            let after = terminal_scroll_position(&term);
            if before == after {
                None
            } else {
                pty.refresh_active_search_locked(&mut term)?;
                broadcast_render_scroll_locked(pty, after);
                pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
                let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                let _ = pty.build_frame_locked(&mut term, generation, false);
                Some(after)
            }
        };
        if let Some((offset, at_bottom)) = changed
            && let Some(mux) = pty.mux.upgrade()
        {
            mux.emit(MuxEvent::ScrollChanged { surface: self.id, offset, at_bottom });
        }
        Ok(())
    }

    pub fn scroll_to_top(&self) -> anyhow::Result<()> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let changed = {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            term.scroll_to_top();
            let after = terminal_scroll_position(&term);
            if before == after {
                None
            } else {
                pty.refresh_active_search_locked(&mut term)?;
                broadcast_render_scroll_locked(pty, after);
                pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
                let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                let _ = pty.build_frame_locked(&mut term, generation, false);
                Some(after)
            }
        };
        if let Some((offset, at_bottom)) = changed
            && let Some(mux) = pty.mux.upgrade()
        {
            mux.emit(MuxEvent::ScrollChanged { surface: self.id, offset, at_bottom });
        }
        Ok(())
    }

    pub fn scroll_to_row(&self, row: u64) -> anyhow::Result<()> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let changed = {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            term.scroll_to_row(row);
            let after = terminal_scroll_position(&term);
            if before == after {
                None
            } else {
                pty.refresh_active_search_locked(&mut term)?;
                broadcast_render_scroll_locked(pty, after);
                pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
                let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                let _ = pty.build_frame_locked(&mut term, generation, false);
                Some(after)
            }
        };
        if let Some((offset, at_bottom)) = changed
            && let Some(mux) = pty.mux.upgrade()
        {
            mux.emit(MuxEvent::ScrollChanged { surface: self.id, offset, at_bottom });
        }
        Ok(())
    }

    pub fn scroll_pages(&self, pages: isize) -> anyhow::Result<()> {
        let rows = isize::try_from(self.size().1).unwrap_or(isize::MAX);
        self.scroll_delta(pages.saturating_mul(rows))
    }

    pub fn set_default_colors(&self, colors: DefaultColors) {
        if let Some(pty) = self.as_pty() {
            let mut term = pty.term.lock().unwrap();
            term.set_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            term.set_default_cursor(colors.cursor_style, colors.cursor_blink);
            let colors = TerminalColors::from_terminal(&mut term, colors);
            let mut taps = pty.taps.lock().unwrap();
            if !taps.is_empty() {
                taps.retain(|tap| tap.try_send(AttachFrame::ColorsChanged(colors)));
            }
            drop(taps);
            let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
            let _ = pty.build_frame_locked(&mut term, generation, false);
            pty.dirty.store(true, Ordering::Release);
        }
    }

    pub fn set_name(&self, name: Option<String>) {
        *self.name.lock().unwrap() = name;
    }

    pub fn name(&self) -> Option<String> {
        self.name.lock().unwrap().clone()
    }

    pub fn set_selection_text(&self, text: Option<String>) {
        *self.selection.lock().unwrap() = text;
    }

    pub fn selection_text(&self) -> Option<String> {
        self.selection.lock().unwrap().clone()
    }

    /// Snapshot the terminal into `rs` (holds the terminal lock only for
    /// the duration of the update).
    pub fn snapshot(&self, rs: &mut RenderState) -> ghostty_vt::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        rs.update(&mut pty.term.lock().unwrap())
    }

    /// Latest immutable frame from the surface's shared render producer.
    pub fn render_frame(&self) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let mut term = pty.term.lock().unwrap();
        let generation = pty.render_generation.load(Ordering::Acquire);
        let _ = pty.build_frame_locked(&mut term, generation, false)?;
        pty.render.lock().unwrap().latest.clone().ok_or(ghostty_vt::Error::NoValue)
    }

    /// Resize this surface. PTYs receive cell dimensions; browsers also
    /// use the last configured cell pixel size for CDP device metrics.
    /// Returns whether a clamped size change was applied or accepted. Browser
    /// reconfiguration completes on its worker and emits the final size there.
    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        match self {
            Surface::Pty(pty) => Ok(pty.resize(cols, rows)),
            Surface::Browser(browser) => browser.resize(cols, rows),
        }
    }

    pub fn resize_reporting_acceptance(
        &self,
        cols: u16,
        rows: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        match self {
            Surface::Pty(pty) => {
                let accepted = pty.resize(cols, rows);
                report(accepted.then_some(0));
                Ok(accepted.then_some(0))
            }
            Surface::Browser(browser) => browser.resize_reporting_acceptance(cols, rows, report),
        }
    }

    pub fn resize_needed(&self, cols: u16, rows: u16) -> bool {
        let desired = (cols.max(1), rows.max(1));
        match self {
            Surface::Pty(pty) => *pty.size.lock().unwrap() != desired,
            Surface::Browser(browser) => browser.resize_needed(desired.0, desired.1),
        }
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<bool> {
        self.set_cell_pixel_size_reporting(width_px, height_px, Box::new(|_| {}))
            .map(|reservation_id| reservation_id.is_some())
    }

    pub fn set_cell_pixel_size_reporting(
        &self,
        width_px: u16,
        height_px: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        if let Some(browser) = self.as_browser() {
            browser.set_cell_pixel_size_reporting(width_px, height_px, report)
        } else {
            report(None);
            Ok(None)
        }
    }

    pub fn size(&self) -> (u16, u16) {
        match self {
            Surface::Pty(pty) => *pty.size.lock().unwrap(),
            Surface::Browser(browser) => browser.size(),
        }
    }

    pub fn title(&self) -> String {
        match self {
            Surface::Pty(pty) => pty.title.lock().unwrap().clone(),
            Surface::Browser(browser) => browser.title(),
        }
    }

    pub fn pwd(&self) -> Option<String> {
        self.as_pty().and_then(|pty| pty.pwd.lock().unwrap().clone())
    }

    pub fn process_id(&self) -> Option<u32> {
        self.as_pty().and_then(|pty| pty.pid)
    }

    pub fn spawn_command(&self) -> Option<String> {
        self.as_pty().map(|pty| pty.command.join(" "))
    }

    pub fn spawn_argv(&self) -> Option<Vec<String>> {
        self.as_pty().map(|pty| pty.command.clone())
    }

    pub fn tty_name(&self) -> Option<PathBuf> {
        self.as_pty().and_then(|pty| pty.tty_name.clone())
    }

    pub fn spawn_cwd(&self) -> Option<String> {
        self.as_pty().and_then(|pty| pty.cwd.clone())
    }

    pub fn wait_after_command(&self) -> bool {
        self.as_pty().is_some_and(|pty| pty.wait_after_command)
    }

    pub fn is_dead(&self) -> bool {
        match self {
            Surface::Pty(pty) => pty.dead.load(Ordering::Acquire),
            Surface::Browser(browser) => browser.is_dead(),
        }
    }

    #[cfg(test)]
    pub(crate) fn mark_dead_for_test(&self) {
        match self {
            Surface::Pty(pty) => pty.dead.store(true, Ordering::Release),
            Surface::Browser(browser) => browser.mark_failed("test exit".to_string()),
        }
    }

    /// Clear the coalesced output flag; returns whether output was pending.
    pub fn take_dirty(&self) -> bool {
        match self {
            Surface::Pty(pty) => pty.dirty.swap(false, Ordering::AcqRel),
            Surface::Browser(browser) => browser.take_dirty(),
        }
    }

    /// Attach to a PTY surface: a VT replay plus a live byte stream.
    pub fn attach_stream(&self) -> ghostty_vt::Result<AttachStream> {
        self.attach_stream_with_lifecycle(AttachLifecycle::default())
    }

    pub(crate) fn attach_stream_with_lifecycle(
        &self,
        lifecycle: AttachLifecycle,
    ) -> ghostty_vt::Result<AttachStream> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let mut term = pty.term.lock().unwrap();
        let (tx, rx) = sync_channel(ATTACH_STREAM_CAPACITY);
        let queued_bytes = Arc::new(AtomicUsize::new(0));
        // Snapshot and tap registration under the same terminal lock:
        // the reader thread cannot apply bytes between the two.
        let replay = term.vt_replay_bounded(VT_REPLAY_MAX_BYTES)?;
        let (cols, rows) = (term.cols(), term.rows());
        let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let colors = TerminalColors::from_terminal(&mut term, defaults);
        pty.taps.lock().unwrap().push(AttachTap {
            sender: tx,
            lifecycle: lifecycle.clone(),
            queued_bytes: queued_bytes.clone(),
            max_queued_bytes: ATTACH_STREAM_MAX_BYTES,
        });
        Ok(AttachStream {
            cols,
            rows,
            replay,
            colors,
            stream: AttachFrameReceiver { receiver: rx, queued_bytes },
            lifecycle,
        })
    }

    /// Attach to the shared protocol-v7 render stream without consuming
    /// terminal damage a second time.
    pub fn attach_render_stream(&self) -> ghostty_vt::Result<RenderAttachStream> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let mut term = pty.term.lock().unwrap();
        let generation = pty.render_generation.load(Ordering::Acquire);
        let _ = pty.build_frame_locked(&mut term, generation, false)?;
        let (tx, rx) = std::sync::mpsc::channel();
        let initial = {
            let mut render = pty.render.lock().unwrap();
            let initial = render.latest.clone().ok_or(ghostty_vt::Error::NoValue)?;
            render.taps.push(tx);
            initial
        };
        Ok(RenderAttachStream { initial, stream: rx })
    }

    /// Return the exact identity of this PTY terminal state lifetime.
    pub fn semantic_scene_terminal_identity(&self) -> Option<SemanticSceneTerminalIdentity> {
        self.as_pty().map(|pty| pty.semantic_identity)
    }

    /// Attach a bounded full-first semantic scene stream for one renderer.
    ///
    /// The initial capture and live registration share the terminal lock, so
    /// PTY output cannot land between the full snapshot and its first delta.
    pub fn attach_semantic_scene(
        &self,
        options: SemanticSceneAttachmentOptions,
    ) -> Result<SemanticSceneAttachment, SemanticSceneAttachError> {
        let Some(pty) = self.as_pty() else {
            return Err(SemanticSceneAttachError::NotPty);
        };
        let mut term = pty.term.lock().unwrap();
        let content_sequence = pty.render_generation.load(Ordering::Acquire);
        let attachment = pty.semantic_scenes.lock().unwrap().attach_locked(
            &mut term,
            pty.semantic_identity,
            content_sequence,
            options,
            pty.frame_requests.clone(),
        )?;
        pty.semantic_attachment_count.fetch_add(1, Ordering::AcqRel);
        Ok(attachment)
    }

    pub fn kill(&self) {
        match self {
            Surface::Pty(pty) => {
                if let Some(external) = &pty.external {
                    let _operation = external.operation.lock().unwrap();
                    let mut state = external.state.lock().unwrap();
                    state.owner = None;
                    state.requires_reset = true;
                    state.egress.clear();
                    pty.dead.store(true, Ordering::Release);
                }
                let _ = pty.killer.lock().unwrap().kill();
            }
            Surface::Browser(browser) => browser.kill(),
        }
    }

    pub fn browser_frame(&self) -> Option<BrowserFrame> {
        self.as_browser().and_then(BrowserSurface::latest_frame)
    }

    pub fn browser_url(&self) -> Option<String> {
        self.as_browser().map(BrowserSurface::url)
    }

    pub fn browser_source(&self) -> Option<BrowserSource> {
        self.as_browser().and_then(BrowserSurface::source)
    }

    pub fn browser_status(&self) -> Option<BrowserStatus> {
        self.as_browser().map(BrowserSurface::status)
    }

    pub fn browser_frames_stalled(&self) -> Option<bool> {
        self.as_browser().map(BrowserSurface::frames_stalled)
    }

    pub fn attach_frames(&self) -> anyhow::Result<(BrowserAttachState, BrowserFrameStream)> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        Ok(browser.attach_frames())
    }

    pub fn browser_insert_text(&self, text: &str) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.insert_text(text)
    }

    pub fn browser_key_event(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.key_event(event_type, key, code, windows_virtual_key_code, modifiers, text)
    }

    pub fn browser_mouse_event(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.mouse_event(event_type, x, y, button, click_count)
    }

    pub fn browser_wheel(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.wheel(x, y, delta_y)
    }

    pub fn browser_navigate(&self, url: &str) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.navigate(url)
    }

    pub fn browser_back(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.back()
    }

    pub fn browser_forward(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.forward()
    }

    pub fn browser_reload(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.reload()
    }

    pub fn browser_activate(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.activate()
    }
}

fn search_scene_highlights(result: &SearchSelection) -> Vec<RenderSceneHighlight> {
    let selected = result.selection.as_ref().map(|selection| {
        (
            selection.top_left.row,
            selection.top_left.column,
            selection.bottom_right.row,
            selection.bottom_right.column,
        )
    });
    result
        .viewport_matches
        .iter()
        .map(|range| {
            let coordinates = (
                range.top_left.row,
                range.top_left.column,
                range.bottom_right.row,
                range.bottom_right.column,
            );
            RenderSceneHighlight {
                start_row: u64::from(range.top_left.row),
                start_column: u32::from(range.top_left.column),
                end_row: u64::from(range.bottom_right.row),
                end_column: u32::from(range.bottom_right.column),
                kind: if Some(coordinates) == selected {
                    RenderSceneHighlightKind::SearchMatchSelected
                } else {
                    RenderSceneHighlightKind::SearchMatch
                },
            }
        })
        .collect()
}

struct ParserOnlyMasterPty {
    size: Mutex<PtySize>,
}

impl ParserOnlyMasterPty {
    fn new(cols: u16, rows: u16) -> Self {
        Self { size: Mutex::new(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }) }
    }
}

impl MasterPty for ParserOnlyMasterPty {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        *self.size.lock().unwrap() = size;
        Ok(())
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        Ok(*self.size.lock().unwrap())
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
        Ok(Box::new(std::io::empty()))
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
        Ok(Box::new(std::io::sink()))
    }

    #[cfg(unix)]
    fn process_group_leader(&self) -> Option<libc::pid_t> {
        None
    }

    #[cfg(unix)]
    fn as_raw_fd(&self) -> Option<std::os::unix::io::RawFd> {
        None
    }

    #[cfg(unix)]
    fn tty_name(&self) -> Option<PathBuf> {
        None
    }
}

#[derive(Debug)]
struct ParserOnlyChildKiller;

impl ChildKiller for ParserOnlyChildKiller {
    fn kill(&mut self) -> std::io::Result<()> {
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(Self)
    }
}

#[cfg(test)]
struct TestMasterPty {
    size: Mutex<PtySize>,
    tty_name: PathBuf,
}

#[cfg(test)]
impl MasterPty for TestMasterPty {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        *self.size.lock().unwrap() = size;
        Ok(())
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        Ok(*self.size.lock().unwrap())
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
        Ok(Box::new(std::io::empty()))
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
        Ok(Box::new(std::io::sink()))
    }

    #[cfg(unix)]
    fn process_group_leader(&self) -> Option<libc::pid_t> {
        None
    }

    #[cfg(unix)]
    fn as_raw_fd(&self) -> Option<std::os::unix::io::RawFd> {
        None
    }

    #[cfg(unix)]
    fn tty_name(&self) -> Option<PathBuf> {
        Some(self.tty_name.clone())
    }
}

#[cfg(test)]
#[derive(Debug)]
struct TestChildKiller;

#[cfg(test)]
impl ChildKiller for TestChildKiller {
    fn kill(&mut self) -> std::io::Result<()> {
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(TestChildKiller)
    }
}

fn terminal_interaction_snapshot_locked(
    term: &mut Terminal,
    interaction: &TerminalInteractionState,
) -> ghostty_vt::Result<TerminalInteractionSnapshot> {
    let search = match interaction.search.as_ref() {
        Some(search) => TerminalSearchSnapshot {
            active: true,
            query: search.query.clone(),
            selected_match: search.selected_match,
            total_matches: search.total_matches,
        },
        None => TerminalSearchSnapshot {
            active: false,
            query: String::new(),
            selected_match: None,
            total_matches: 0,
        },
    };
    let viewport = term.scrollbar();
    let cursor = term.cursor_screen_point();
    let cursor_visible = cursor.zip(viewport).is_some_and(|(cursor, viewport)| {
        u64::from(cursor.row) >= viewport.offset
            && u64::from(cursor.row) < viewport.offset.saturating_add(viewport.len)
    });
    Ok(TerminalInteractionSnapshot {
        copy_mode: interaction.copy_mode,
        copy_cursor: interaction.copy_cursor,
        selection: term.current_selection()?,
        search,
        viewport,
        mouse_tracking: term.mouse_tracking(),
        cursor,
        cursor_visible,
    })
}

impl PtySurface {
    fn refresh_active_search_locked(&self, term: &mut Terminal) -> ghostty_vt::Result<()> {
        let mut interaction = self.interaction.lock().unwrap();
        self.refresh_active_search_with_interaction_locked(term, &mut interaction)
    }

    fn refresh_active_search_with_interaction_locked(
        &self,
        term: &mut Terminal,
        interaction: &mut TerminalInteractionState,
    ) -> ghostty_vt::Result<()> {
        let Some(search) = interaction.search.as_mut() else { return Ok(()) };
        if search.query.is_empty() {
            self.semantic_scenes.lock().unwrap().set_presentation_highlights_locked(Vec::new());
            search.selected_match = None;
            search.total_matches = 0;
            return Ok(());
        }

        let requested = search.selected_match.unwrap_or(0);
        let mut result = term.search_snapshot(&search.query, requested)?;
        if result.selection.is_none() && result.total_matches > 0 {
            result =
                term.search_snapshot(&search.query, requested.min(result.total_matches - 1))?;
        }
        search.total_matches = result.total_matches;
        search.selected_match = result
            .selection
            .as_ref()
            .map(|_| requested.min(result.total_matches.saturating_sub(1)));
        self.semantic_scenes
            .lock()
            .unwrap()
            .set_presentation_highlights_locked(search_scene_highlights(&result));
        Ok(())
    }

    fn cache_accessibility_frame(&self, snapshot: TerminalAccessibilitySnapshot) {
        let mut frames = self.accessibility_frames.lock().unwrap();
        if frames
            .back()
            .is_some_and(|existing| existing.content_sequence >= snapshot.content_sequence)
        {
            return;
        }
        frames.push_back(snapshot);
        while frames.len() > TERMINAL_ACCESSIBILITY_FRAME_CACHE_CAPACITY {
            frames.pop_front();
        }
    }

    fn terminal_visual_changed_locked(&self, term: &mut Terminal) -> ghostty_vt::Result<()> {
        let generation = self.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let _ = self.build_frame_locked(term, generation, true)?;
        Ok(())
    }

    fn broadcast_attach_output(&self, bytes: &[u8]) {
        let mut taps = self.taps.lock().unwrap();
        if taps.is_empty() {
            return;
        }
        let frame = AttachFrame::Output(bytes.to_vec());
        taps.retain(|tap| tap.try_send(frame.clone()));
    }

    fn broadcast_attach_frame(&self, frame: AttachFrame) {
        self.taps.lock().unwrap().retain(|tap| tap.try_send(frame.clone()));
    }

    fn request_frame(&self, generation: u64) {
        match self.frame_requests.try_send(generation) {
            Ok(()) | Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {}
        }
    }

    /// Build and fan out one immutable frame while the caller holds `term`.
    fn build_frame_locked(
        &self,
        term: &mut Terminal,
        generation: u64,
        producer_driven: bool,
    ) -> ghostty_vt::Result<bool> {
        let semantic_attachment_count = self.semantic_attachment_count.load(Ordering::Acquire);
        let semantic_work = if semantic_attachment_count == 0 {
            self.accessibility_demanded.store(false, Ordering::Release);
            self.accessibility_frames.lock().unwrap().clear();
            false
        } else {
            let mut scenes = self.semantic_scenes.lock().unwrap();
            let worked = scenes.capture_locked(term, self.semantic_identity, generation);
            self.semantic_attachment_count.store(scenes.attachment_count(), Ordering::Release);
            worked
        };
        if semantic_attachment_count > 0 && self.accessibility_demanded.load(Ordering::Acquire) {
            let focus_revision = self.accessibility_focus_revision.load(Ordering::Acquire);
            let identity = TerminalAccessibilityIdentity {
                surface_uuid: self.meta.uuid,
                presentation_id: crate::PresentationId::new(),
                presentation_generation: 1,
                content_sequence: generation,
                terminal_revision: generation.saturating_add(focus_revision),
                content_revision: self.accessibility_content_revision.load(Ordering::Acquire),
                viewport_revision: self.accessibility_viewport_revision.load(Ordering::Acquire),
                focused: false,
            };
            if let Ok(snapshot) = build_terminal_accessibility_snapshot(term, identity) {
                self.cache_accessibility_frame(snapshot);
            }
        }
        let built = {
            let mut render = self.render.lock().unwrap();
            if (producer_driven && render.taps.is_empty()) || render.built_generation >= generation
            {
                false
            } else {
                render.state.update(term)?;
                let palette_colors =
                    std::array::from_fn(|idx| render.state.palette_color(idx as u8));
                let palette_overridden =
                    std::array::from_fn(|idx| render.state.palette_overridden(idx as u8));
                let frame = Arc::new(SurfaceRenderFrame {
                    frame: render.state.build_frame()?,
                    scrollback_rows: term.history_rows(),
                    palette_colors,
                    palette_overridden,
                });
                render.built_generation = generation;
                render.latest = Some(frame.clone());
                render.taps.retain(|tap| tap.send(RenderAttachFrame::Frame(frame.clone())).is_ok());
                true
            }
        };

        if producer_driven
            && !self.dirty.swap(true, Ordering::AcqRel)
            && let Some(mux) = self.mux.upgrade()
        {
            mux.emit(MuxEvent::SurfaceOutput(self.meta.id));
        }
        Ok(built || semantic_work)
    }

    /// Resize both the PTY and the terminal state. Returns whether the
    /// final clamped size actually changed.
    fn resize(&self, cols: u16, rows: u16) -> bool {
        let (cols, rows) = (cols.max(1), rows.max(1));
        {
            let mut size = self.size.lock().unwrap();
            if *size == (cols, rows) {
                return false;
            }
            *size = (cols, rows);
        }
        // Hold the terminal lock while resizing and while sending the
        // attach marker, so attach mirrors observe bytes and resizes in
        // the exact order the server terminal applied them.
        let mut term = self.term.lock().unwrap();
        let _ = self.master.lock().unwrap().resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        });
        // Nominal cell metrics; only pixel size reports observe these.
        let suppress_reflow = self.external.as_ref().is_some_and(|external| external.no_reflow);
        let restore_wraparound = suppress_reflow && term.mode(7, false);
        if restore_wraparound {
            let _ = term.set_mode(7, false, false);
        }
        let _ = term.resize(cols, rows, 8, 16);
        if restore_wraparound {
            let _ = term.set_mode(7, false, true);
        }
        let _ = self.refresh_active_search_locked(&mut term);
        let replay = term.vt_replay_bounded(VT_REPLAY_MAX_BYTES).unwrap_or_default();
        self.broadcast_attach_frame(AttachFrame::Resized { cols, rows, replay });
        self.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
        let generation = self.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let _ = self.build_frame_locked(&mut term, generation, false);
        true
    }
}

const RENDER_FRAME_CADENCE: Duration = Duration::from_millis(8);
const MOUSE_SELECTION_AUTOSCROLL_CADENCE: Duration = Duration::from_millis(50);
const SYNCHRONIZED_OUTPUT_SAFETY_TIMEOUT: Duration = Duration::from_secs(1);
const SYNCHRONIZED_OUTPUT_MODE: u16 = 2026;

fn spawn_frame_producer(surface: &Arc<Surface>, requests: Receiver<u64>) -> anyhow::Result<()> {
    let weak = Arc::downgrade(surface);
    let id = surface.id;
    std::thread::Builder::new().name(format!("surface-{id}-frames")).spawn(move || {
        let mut last_frame = Instant::now() - RENDER_FRAME_CADENCE;
        let mut synchronized_output_started: Option<Instant> = None;
        while let Ok(mut requested) = requests.recv() {
            let deadline = last_frame + RENDER_FRAME_CADENCE;
            loop {
                let now = Instant::now();
                if now >= deadline {
                    break;
                }
                match requests.recv_timeout(deadline.saturating_duration_since(now)) {
                    Ok(next) => requested = requested.max(next),
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            loop {
                let Some(surface) = weak.upgrade() else { return };
                let Some(pty) = surface.as_pty() else { return };
                let mut term = pty.term.lock().unwrap();
                let synchronized = term.mode(SYNCHRONIZED_OUTPUT_MODE, false);

                if synchronized {
                    let started = *synchronized_output_started.get_or_insert_with(Instant::now);
                    let deadline = started + SYNCHRONIZED_OUTPUT_SAFETY_TIMEOUT;
                    let now = Instant::now();
                    if now < deadline {
                        drop(term);
                        match requests.recv_timeout(deadline.saturating_duration_since(now)) {
                            Ok(next) => {
                                requested = requested.max(next);
                                continue;
                            }
                            Err(RecvTimeoutError::Timeout) => continue,
                            Err(RecvTimeoutError::Disconnected) => return,
                        }
                    }

                    // Match Ghostty's synchronized-output safety valve. A client
                    // that never sends DECRST 2026 cannot freeze its renderer.
                    let _ = term.set_mode(SYNCHRONIZED_OUTPUT_MODE, false, false);
                }

                if synchronized_output_started.take().is_some() {
                    pty.semantic_scenes.lock().unwrap().force_full_locked();
                }
                let generation = requested.max(pty.render_generation.load(Ordering::Acquire));
                if pty.build_frame_locked(&mut term, generation, true).unwrap_or(false) {
                    last_frame = Instant::now();
                }
                break;
            }
        }
    })?;
    Ok(())
}

fn cancel_mouse_selection_autoscroll_locked(interaction: &mut TerminalInteractionState) {
    if let Some(active) = interaction.mouse_autoscroll.take() {
        match active.cancel.try_send(()) {
            Ok(()) | Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {}
        }
    }
}

fn spawn_mouse_selection_autoscroll(
    surface: &Arc<Surface>,
    generation: u64,
    canceled: Receiver<()>,
) -> anyhow::Result<()> {
    let weak = Arc::downgrade(surface);
    let id = surface.id;
    std::thread::Builder::new().name(format!("surface-{id}-selection-autoscroll")).spawn(
        move || loop {
            match canceled.recv_timeout(MOUSE_SELECTION_AUTOSCROLL_CADENCE) {
                Ok(()) | Err(RecvTimeoutError::Disconnected) => return,
                Err(RecvTimeoutError::Timeout) => {}
            }
            let Some(surface) = weak.upgrade() else { return };
            if !surface.terminal_mouse_selection_autoscroll_tick(generation).unwrap_or(false) {
                return;
            }
        },
    )?;
    Ok(())
}

fn broadcast_render_scroll_locked(pty: &PtySurface, position: (u64, bool)) {
    let (offset, at_bottom) = position;
    let mut render = pty.render.lock().unwrap();
    render
        .taps
        .retain(|tap| tap.send(RenderAttachFrame::ScrollChanged { offset, at_bottom }).is_ok());
}

fn terminal_scroll_position(term: &Terminal) -> (u64, bool) {
    match term.scrollbar() {
        Some(scrollbar) => (scrollbar.offset, !scrollbar.scrolled_back()),
        None => (0, true),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ghostty_vt::{SceneSectionKind, SelectionRangeSnapshot};
    use sha2::{Digest, Sha256};

    fn semantic_options(
        surface: &Surface,
        event_capacity: usize,
    ) -> SemanticSceneAttachmentOptions {
        let terminal = surface.semantic_scene_terminal_identity().unwrap();
        let presentation = crate::SemanticScenePresentationIdentity {
            presentation_id: crate::PresentationId::new(),
            generation: 7,
        };
        let mut options = SemanticSceneAttachmentOptions::new(terminal, presentation);
        options.event_capacity = event_capacity;
        options
    }

    fn apply_terminal_output(surface: &Surface, bytes: &[u8]) -> (u64, bool) {
        let pty = surface.as_pty().unwrap();
        let mut term = pty.term.lock().unwrap();
        term.vt_write(bytes);
        pty.accessibility_content_revision.fetch_add(1, Ordering::AcqRel);
        let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let worked = pty.build_frame_locked(&mut term, generation, true).unwrap();
        (generation, worked)
    }

    fn expect_semantic_scene(event: crate::SemanticSceneEvent) -> crate::SemanticSceneFrame {
        match event {
            crate::SemanticSceneEvent::Scene(frame) => frame,
            crate::SemanticSceneEvent::Failed(error) => {
                panic!("expected semantic scene, got failure: {error}")
            }
        }
    }

    fn external_owner(connection_id: u64) -> ExternalTerminalOwner {
        ExternalTerminalOwner {
            client_uuid: uuid::Uuid::from_u128(11),
            process_instance_uuid: uuid::Uuid::from_u128(12),
            connection_id,
        }
    }

    #[test]
    fn external_terminal_has_no_child_and_fences_ordered_output() {
        let surface = Surface::spawn_external_with_uuid(
            71,
            crate::SurfaceUuid::new(),
            SurfaceOptions { cols: 8, rows: 2, ..SurfaceOptions::default() },
            true,
            Weak::new(),
        )
        .unwrap();
        assert!(surface.is_external_terminal());
        assert_eq!(surface.process_id(), None);
        assert_eq!(surface.tty_name(), None);
        assert!(surface.write_bytes(b"input-before-reset").is_err());

        let owner = external_owner(9);
        let claim = surface.claim_external_terminal(owner, uuid::Uuid::from_u128(21)).unwrap();
        assert_eq!(claim.owner_generation, 1);
        assert_eq!(claim.required_output_generation, 1);
        let reset = surface
            .reset_external_terminal(
                owner,
                claim.owner_generation,
                uuid::Uuid::from_u128(22),
                claim.required_output_generation,
                8,
                2,
                b"seed",
            )
            .unwrap();
        assert_eq!(reset.next_sequence, 1);

        let output_request = uuid::Uuid::from_u128(23);
        let first = surface
            .apply_external_terminal_output(
                owner,
                claim.owner_generation,
                output_request,
                claim.required_output_generation,
                1,
                b"\x1b[6n",
            )
            .unwrap();
        assert_eq!(first.accepted_sequence, 1);
        assert_eq!(first.next_sequence, 2);
        assert!(!first.egress.is_empty(), "cursor report must route back to the external owner");
        let replay = surface
            .apply_external_terminal_output(
                owner,
                claim.owner_generation,
                output_request,
                claim.required_output_generation,
                1,
                b"\x1b[6n",
            )
            .unwrap();
        assert!(replay.replayed);
        assert_eq!(replay.egress, first.egress);
        assert!(
            surface
                .apply_external_terminal_output(
                    owner,
                    claim.owner_generation,
                    uuid::Uuid::from_u128(24),
                    claim.required_output_generation,
                    1,
                    b"late",
                )
                .unwrap_err()
                .to_string()
                .contains("expected 2")
        );

        surface.write_bytes(b"hello").unwrap();
        assert_eq!(
            surface.drain_external_terminal_egress(owner, claim.owner_generation).unwrap(),
            b"hello"
        );
    }

    #[test]
    fn replacing_external_owner_requires_a_new_reset_generation() {
        let surface = Surface::spawn_external_with_uuid(
            72,
            crate::SurfaceUuid::new(),
            SurfaceOptions::default(),
            false,
            Weak::new(),
        )
        .unwrap();
        let first_owner = external_owner(1);
        let first =
            surface.claim_external_terminal(first_owner, uuid::Uuid::from_u128(31)).unwrap();
        surface
            .reset_external_terminal(
                first_owner,
                first.owner_generation,
                uuid::Uuid::from_u128(32),
                first.required_output_generation,
                80,
                24,
                b"old",
            )
            .unwrap();

        let replacement = external_owner(2);
        let second =
            surface.claim_external_terminal(replacement, uuid::Uuid::from_u128(33)).unwrap();
        assert_eq!(second.owner_generation, first.owner_generation + 1);
        assert_eq!(second.required_output_generation, first.required_output_generation + 1);
        assert!(
            surface
                .apply_external_terminal_output(
                    first_owner,
                    first.owner_generation,
                    uuid::Uuid::from_u128(34),
                    first.required_output_generation,
                    1,
                    b"stale",
                )
                .is_err()
        );
        assert!(surface.write_bytes(b"before-new-seed").is_err());
    }

    #[test]
    fn search_scene_marks_all_visible_matches_and_only_the_selected_match() {
        let selected_range = SelectionRangeSnapshot {
            start: SelectionPoint { column: 2, row: 3 },
            end: SelectionPoint { column: 4, row: 3 },
            top_left: SelectionPoint { column: 2, row: 3 },
            bottom_right: SelectionPoint { column: 4, row: 3 },
            rectangle: false,
        };
        let other_range = SelectionRangeSnapshot {
            start: SelectionPoint { column: 6, row: 5 },
            end: SelectionPoint { column: 8, row: 5 },
            top_left: SelectionPoint { column: 6, row: 5 },
            bottom_right: SelectionPoint { column: 8, row: 5 },
            rectangle: false,
        };
        let result = SearchSelection {
            total_matches: 2,
            selection: Some(SelectionSnapshot {
                text: "hit".into(),
                start: selected_range.start,
                end: selected_range.end,
                top_left: selected_range.top_left,
                bottom_right: selected_range.bottom_right,
                rectangle: false,
            }),
            viewport_matches: vec![selected_range, other_range],
        };

        let highlights = search_scene_highlights(&result);
        assert_eq!(highlights.len(), 2);
        assert_eq!(highlights[0].kind, RenderSceneHighlightKind::SearchMatchSelected);
        assert_eq!(highlights[1].kind, RenderSceneHighlightKind::SearchMatch);
        assert_eq!((highlights[1].start_row, highlights[1].start_column), (5, 6));
    }

    #[test]
    fn active_search_refreshes_after_output_and_viewport_movement() {
        let mut options = SurfaceOptions::default();
        options.cols = 24;
        options.rows = 4;
        let mux = Mux::new_for_test("search-refresh", options.clone());
        let surface = Surface::spawn_for_test(1, options, Arc::downgrade(&mux)).unwrap();
        surface
            .inject_terminal_output(
                b"cmux-search-0\r\nrow\r\nrow\r\nrow\r\ncmux-search-1\r\nrow\r\n",
            )
            .unwrap();
        let started = surface.terminal_search_update("cmux-search".into()).unwrap();
        assert_eq!(started.search.total_matches, 2);
        let centered_rows = {
            let pty = surface.as_pty().unwrap();
            pty.semantic_scenes
                .lock()
                .unwrap()
                .presentation_highlights_for_test()
                .iter()
                .map(|highlight| highlight.start_row)
                .collect::<Vec<_>>()
        };

        surface.scroll_to_top().unwrap();
        let top_rows = {
            let pty = surface.as_pty().unwrap();
            pty.semantic_scenes
                .lock()
                .unwrap()
                .presentation_highlights_for_test()
                .iter()
                .map(|highlight| highlight.start_row)
                .collect::<Vec<_>>()
        };
        assert_ne!(top_rows, centered_rows);

        surface.inject_terminal_output(b"cmux-search-2\r\n").unwrap();
        let refreshed = surface.terminal_interaction_snapshot().unwrap();
        assert_eq!(refreshed.search.total_matches, 3);
        assert!(refreshed.search.selected_match.is_some());
    }

    #[test]
    fn selection_drag_autoscroll_ticks_the_viewport_and_release_cancels_it() {
        let mut options = SurfaceOptions::default();
        options.cols = 12;
        options.rows = 4;
        let mux = Mux::new_for_test("selection-autoscroll", options.clone());
        let surface = Surface::spawn_for_test(1, options, Arc::downgrade(&mux)).unwrap();
        surface
            .try_with_terminal(|terminal| {
                for row in 0..12 {
                    terminal.vt_write(format!("row-{row:02}\r\n").as_bytes());
                }
            })
            .unwrap();

        let before = surface.terminal_interaction_snapshot().unwrap().viewport.unwrap();
        assert!(before.offset > 0);
        let anchor = SelectionPoint { column: 1, row: u32::try_from(before.offset + 2).unwrap() };
        assert!(
            surface
                .terminal_mouse_selection(ghostty_vt::MouseAction::Press, anchor, 1, None)
                .unwrap()
                .0
        );
        let edge = SelectionPoint { column: 1, row: u32::try_from(before.offset).unwrap() };
        assert!(
            surface
                .terminal_mouse_selection(
                    ghostty_vt::MouseAction::Motion,
                    edge,
                    1,
                    Some(MouseSelectionAutoscrollDirection::Up),
                )
                .unwrap()
                .0
        );

        let generation = surface
            .as_pty()
            .unwrap()
            .interaction
            .lock()
            .unwrap()
            .mouse_autoscroll
            .as_ref()
            .unwrap()
            .generation;
        assert!(surface.terminal_mouse_selection_autoscroll_tick(generation).unwrap());
        let after = surface.terminal_interaction_snapshot().unwrap().viewport.unwrap();
        assert_eq!(after.offset, before.offset - 1);

        assert!(
            surface
                .terminal_mouse_selection(ghostty_vt::MouseAction::Release, edge, 1, None)
                .unwrap()
                .0
        );
        assert!(surface.as_pty().unwrap().interaction.lock().unwrap().mouse_autoscroll.is_none());
        assert!(!surface.terminal_mouse_selection_autoscroll_tick(generation).unwrap());
    }

    #[test]
    fn terminal_accessibility_link_activation_rejects_stale_revisions() {
        let mux = Mux::new_for_test("accessibility-link-fence", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let presentation_id = crate::PresentationId::new();
        apply_terminal_output(&surface, b"\x1b]8;;https://example.com/a\x1b\\link\x1b]8;;\x1b\\");
        let snapshot = surface.terminal_accessibility_snapshot(presentation_id, 7, true).unwrap();
        let link = snapshot.links.first().unwrap();
        assert_eq!(
            surface
                .activate_terminal_accessibility_link(
                    presentation_id,
                    7,
                    true,
                    snapshot.terminal_revision,
                    snapshot.content_revision,
                    snapshot.viewport_revision,
                    &link.id,
                )
                .unwrap(),
            "https://example.com/a"
        );

        apply_terminal_output(&surface, b"x");
        assert!(
            surface
                .activate_terminal_accessibility_link(
                    presentation_id,
                    7,
                    true,
                    snapshot.terminal_revision,
                    snapshot.content_revision,
                    snapshot.viewport_revision,
                    &link.id,
                )
                .unwrap_err()
                .to_string()
                .contains("stale terminal accessibility snapshot")
        );
    }

    #[test]
    fn terminal_accessibility_focus_change_advances_only_terminal_revision() {
        let mux = Mux::new_for_test("accessibility-focus", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let presentation_id = crate::PresentationId::new();
        let unfocused = surface.terminal_accessibility_snapshot(presentation_id, 7, false).unwrap();
        surface.terminal_accessibility_focus_changed();
        let focused = surface.terminal_accessibility_snapshot(presentation_id, 7, true).unwrap();
        assert!(!unfocused.focused);
        assert!(focused.focused);
        assert!(focused.terminal_revision > unfocused.terminal_revision);
        assert_eq!(focused.content_revision, unfocused.content_revision);
        assert_eq!(focused.viewport_revision, unfocused.viewport_revision);
    }

    #[test]
    fn terminal_accessibility_reads_the_exact_displayed_sequence_after_canonical_state_advances() {
        let mux = Mux::new_for_test("accessibility-displayed-sequence", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();
        let presentation_id = crate::PresentationId::new();

        // Enable bounded AX capture, then build the frame that a renderer can display.
        let initial = pty.render_generation.load(Ordering::Acquire);
        surface.terminal_accessibility_snapshot_at(presentation_id, 7, true, initial).unwrap();
        pty.semantic_attachment_count.store(1, Ordering::Release);
        let (displayed_sequence, _) = apply_terminal_output(&surface, b"displayed");

        // Canonical state can advance before Swift reports that frame as presented.
        {
            let mut terminal = pty.term.lock().unwrap();
            terminal.vt_write(b"future");
            pty.accessibility_content_revision.fetch_add(1, Ordering::AcqRel);
            pty.render_generation.fetch_add(1, Ordering::AcqRel);
        }

        let displayed = surface
            .terminal_accessibility_snapshot_at(presentation_id, 7, true, displayed_sequence)
            .unwrap();
        assert_eq!(displayed.content_sequence, displayed_sequence);
        assert!(displayed.text.contains("displayed"));
        assert!(!displayed.text.contains("future"));
    }

    #[test]
    fn attach_tap_overflow_cancels_the_shared_lifecycle_once() {
        let lifecycle = AttachLifecycle::default();
        let (sender, _receiver) = sync_channel(1);
        let tap = AttachTap {
            sender,
            lifecycle: lifecycle.clone(),
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            max_queued_bytes: usize::MAX,
        };

        assert!(tap.try_send(AttachFrame::Output(vec![1])));
        assert!(!tap.try_send(AttachFrame::Output(vec![2])));
        assert!(lifecycle.is_canceled());
        assert!(lifecycle.overflowed());
        assert!(lifecycle.claim_overflow_report());
        assert!(!lifecycle.claim_overflow_report());
    }

    #[test]
    fn attach_tap_overflow_is_bounded_by_retained_bytes() {
        let lifecycle = AttachLifecycle::default();
        let (sender, _receiver) = sync_channel(4);
        let frame_bytes = AttachFrame::Output(vec![1]).retained_bytes();
        let tap = AttachTap {
            sender,
            lifecycle: lifecycle.clone(),
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            max_queued_bytes: frame_bytes,
        };

        assert!(tap.try_send(AttachFrame::Output(vec![1])));
        assert!(!tap.try_send(AttachFrame::Output(vec![2])));
        assert!(lifecycle.overflowed());
    }

    #[test]
    fn producer_without_render_taps_skips_frame_but_emits_output() {
        let mux = Mux::new_for_test("producer-skip", SurfaceOptions::default());
        let events = mux.subscribe();
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();

        let mut term = pty.term.lock().unwrap();
        assert!(!pty.build_frame_locked(&mut term, 2, true).unwrap());
        drop(term);

        let render = pty.render.lock().unwrap();
        assert_eq!(render.built_generation, 0);
        assert!(render.latest.is_none());
        drop(render);
        assert!(pty.dirty.load(Ordering::Acquire));
        assert!(matches!(events.try_recv(), Ok(MuxEvent::SurfaceOutput(1))));
    }

    #[test]
    fn semantic_scene_attachment_is_full_first_and_then_contiguous_delta() {
        let mux = Mux::new_for_test("semantic-full-first", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let options = semantic_options(&surface, 2);
        let attachment = surface.attach_semantic_scene(options.clone()).unwrap();

        assert_eq!(attachment.initial.canonical_kind, SceneSectionKind::Full);
        assert_eq!(attachment.initial.terminal, options.terminal);
        assert_eq!(attachment.initial.content_sequence, 1);
        assert_eq!(attachment.initial.presentation, options.presentation);
        assert_eq!(attachment.initial.presentation_sequence, 1);
        assert_eq!(&attachment.initial.as_bytes()[0..4], b"GSCN");
        assert_eq!(attachment.initial.as_bytes()[16], 1);
        assert_eq!(
            &attachment.initial.as_bytes()[24..40],
            options.terminal.terminal_id.as_uuid().as_bytes()
        );
        assert_eq!(
            u64::from_le_bytes(attachment.initial.as_bytes()[40..48].try_into().unwrap()),
            options.terminal.runtime_epoch
        );
        assert_eq!(
            &attachment.initial.as_bytes()[80..96],
            options.presentation.presentation_id.as_uuid().as_bytes()
        );
        assert_eq!(
            u64::from_le_bytes(attachment.initial.as_bytes()[96..104].try_into().unwrap()),
            options.presentation.generation
        );

        let (generation, worked) = apply_terminal_output(&surface, b"first delta");
        assert!(worked);
        let delta = expect_semantic_scene(attachment.events.try_recv().unwrap());
        assert_eq!(delta.canonical_kind, SceneSectionKind::Delta);
        assert_eq!(delta.content_sequence, generation);
        assert_eq!(delta.presentation_sequence, 2);
        assert_eq!(delta.as_bytes()[16], 2);
        assert_eq!(u64::from_le_bytes(delta.as_bytes()[48..56].try_into().unwrap()), generation);
        assert_eq!(u64::from_le_bytes(delta.as_bytes()[104..112].try_into().unwrap()), 2);
    }

    #[test]
    fn synchronized_output_withholds_scenes_then_releases_one_full_scene() {
        let mux = Mux::new_for_test("semantic-synchronized-output", SurfaceOptions::default());
        let surface = Surface::spawn_for_test_with_frame_producer(
            1,
            crate::SurfaceUuid::new(),
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
            true,
        )
        .unwrap();
        let attachment = surface.attach_semantic_scene(semantic_options(&surface, 2)).unwrap();
        let pty = surface.as_pty().unwrap();

        let held_generation = {
            let mut terminal = pty.term.lock().unwrap();
            terminal.vt_write(b"\x1b[?2026hfirst");
            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
        };
        pty.request_frame(held_generation);
        assert!(matches!(
            attachment.events.recv_timeout(Duration::from_millis(100)),
            Err(RecvTimeoutError::Timeout)
        ));

        let released_generation = {
            let mut terminal = pty.term.lock().unwrap();
            terminal.vt_write(b"second\x1b[?2026l");
            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
        };
        pty.request_frame(released_generation);
        let released =
            expect_semantic_scene(attachment.events.recv_timeout(Duration::from_secs(2)).unwrap());
        assert_eq!(released.content_sequence, released_generation);
        assert_eq!(released.canonical_kind, SceneSectionKind::Full);
        assert!(matches!(attachment.events.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn synchronized_output_safety_timeout_resets_mode_and_emits_full_scene() {
        let mux = Mux::new_for_test("semantic-synchronized-timeout", SurfaceOptions::default());
        let surface = Surface::spawn_for_test_with_frame_producer(
            1,
            crate::SurfaceUuid::new(),
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
            true,
        )
        .unwrap();
        let attachment = surface.attach_semantic_scene(semantic_options(&surface, 1)).unwrap();
        let pty = surface.as_pty().unwrap();

        let held_generation = {
            let mut terminal = pty.term.lock().unwrap();
            terminal.vt_write(b"\x1b[?2026hstuck");
            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
        };
        pty.request_frame(held_generation);
        let released = expect_semantic_scene(
            attachment.events.recv_timeout(Duration::from_millis(1_500)).unwrap(),
        );
        assert_eq!(released.content_sequence, held_generation);
        assert_eq!(released.canonical_kind, SceneSectionKind::Full);
        assert!(!pty.term.lock().unwrap().mode(SYNCHRONIZED_OUTPUT_MODE, false));
    }

    #[test]
    fn semantic_scene_overflow_recovers_full_without_invalidating_other_consumer() {
        let mux = Mux::new_for_test("semantic-overflow", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let slow = surface.attach_semantic_scene(semantic_options(&surface, 1)).unwrap();
        let steady = surface.attach_semantic_scene(semantic_options(&surface, 3)).unwrap();

        let (generation_two, _) = apply_terminal_output(&surface, b"two");
        let (generation_three, _) = apply_terminal_output(&surface, b"three");
        let (latest_generation, _) = apply_terminal_output(&surface, b"four");
        assert!(slow.control.needs_full_scene());
        assert!(!steady.control.needs_full_scene());

        let slow_delta = expect_semantic_scene(slow.events.try_recv().unwrap());
        assert_eq!(slow_delta.canonical_kind, SceneSectionKind::Delta);
        assert_eq!(slow_delta.content_sequence, generation_two);

        let pty = surface.as_pty().unwrap();
        let mut term = pty.term.lock().unwrap();
        assert!(pty.build_frame_locked(&mut term, latest_generation, true).unwrap());
        drop(term);

        let slow_recovery = expect_semantic_scene(slow.events.try_recv().unwrap());
        assert_eq!(slow_recovery.canonical_kind, SceneSectionKind::Full);
        assert_eq!(slow_recovery.content_sequence, latest_generation);
        assert_eq!(slow_recovery.presentation_sequence, 3);
        assert!(!slow.control.needs_full_scene());

        let steady_two = expect_semantic_scene(steady.events.try_recv().unwrap());
        let steady_three = expect_semantic_scene(steady.events.try_recv().unwrap());
        let steady_four = expect_semantic_scene(steady.events.try_recv().unwrap());
        assert_eq!(steady_two.canonical_kind, SceneSectionKind::Delta);
        assert_eq!(steady_two.content_sequence, generation_two);
        assert_eq!(steady_two.presentation_sequence, 2);
        assert_eq!(steady_three.canonical_kind, SceneSectionKind::Delta);
        assert_eq!(steady_three.content_sequence, generation_three);
        assert_eq!(steady_three.presentation_sequence, 3);
        assert_eq!(steady_four.canonical_kind, SceneSectionKind::Delta);
        assert_eq!(steady_four.content_sequence, latest_generation);
        assert_eq!(steady_four.presentation_sequence, 4);
    }

    #[test]
    fn semantic_scene_force_full_works_without_new_terminal_output() {
        let mux = Mux::new_for_test("semantic-force-full", SurfaceOptions::default());
        let surface = Surface::spawn_for_test_with_frame_producer(
            1,
            crate::SurfaceUuid::new(),
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
            true,
        )
        .unwrap();
        let attachment = surface.attach_semantic_scene(semantic_options(&surface, 1)).unwrap();
        let worker_control = attachment.control.clone();
        worker_control.request_full_scene();

        let pty = surface.as_pty().unwrap();
        let generation = pty.render_generation.load(Ordering::Acquire);
        let forced =
            expect_semantic_scene(attachment.events.recv_timeout(Duration::from_secs(2)).unwrap());
        assert_eq!(forced.canonical_kind, SceneSectionKind::Full);
        assert_eq!(forced.content_sequence, generation);
        assert_eq!(forced.presentation_sequence, 2);
    }

    #[test]
    fn semantic_scene_preedit_is_presentation_only_and_never_advances_terminal_content() {
        let mux = Mux::new_for_test("semantic-preedit", SurfaceOptions::default());
        let surface = Surface::spawn_for_test_with_frame_producer(
            1,
            crate::SurfaceUuid::new(),
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
            true,
        )
        .unwrap();
        let attachment = surface.attach_semantic_scene(semantic_options(&surface, 1)).unwrap();
        let generation = surface.as_pty().unwrap().render_generation.load(Ordering::Acquire);

        attachment.control.set_preedit(Some("かな".to_owned()));
        let preedit =
            expect_semantic_scene(attachment.events.recv_timeout(Duration::from_secs(2)).unwrap());
        assert_eq!(preedit.canonical_kind, SceneSectionKind::Unchanged);
        assert_eq!(preedit.content_sequence, generation);
        assert_eq!(preedit.presentation_sequence, 2);

        // Setting the same marked text is idempotent and emits no scene.
        attachment.control.set_preedit(Some("かな".to_owned()));
        assert!(matches!(attachment.events.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn semantic_scene_resize_promotes_unencodable_delta_to_full() {
        let mux = Mux::new_for_test("semantic-resize", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attachment = surface.attach_semantic_scene(semantic_options(&surface, 1)).unwrap();

        assert!(surface.resize(81, 25).unwrap());
        let resized = expect_semantic_scene(attachment.events.try_recv().unwrap());
        assert_eq!(resized.canonical_kind, SceneSectionKind::Full);
        assert_eq!(resized.content_sequence, 2);
        assert_eq!(resized.presentation_sequence, 2);
        assert!(!attachment.control.is_detached());
    }

    #[test]
    fn semantic_scene_detach_prunes_cache_and_skips_capture() {
        let mux = Mux::new_for_test("semantic-detach", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attachment = surface.attach_semantic_scene(semantic_options(&surface, 1)).unwrap();
        attachment.events.detach();

        let (_, worked) = apply_terminal_output(&surface, b"detached");
        assert!(!worked);
        assert!(attachment.events.is_detached());
        assert_eq!(surface.as_pty().unwrap().semantic_scenes.lock().unwrap().attachment_count(), 0);
        assert!(matches!(attachment.events.try_recv(), Err(TryRecvError::Disconnected)));
    }

    #[test]
    fn semantic_scene_live_limit_failure_is_typed_and_closes_attachment() {
        let options = SurfaceOptions { cols: 8, rows: 1, ..SurfaceOptions::default() };
        let mux = Mux::new_for_test("semantic-limit", options.clone());
        let surface = Surface::spawn_for_test(1, options, Arc::downgrade(&mux)).unwrap();
        let mut attach_options = semantic_options(&surface, 1);
        attach_options.capture.limits.max_rows = 1;
        let attachment = surface.attach_semantic_scene(attach_options).unwrap();

        assert!(surface.resize(8, 2).unwrap());
        assert!(matches!(
            attachment.events.try_recv(),
            Ok(crate::SemanticSceneEvent::Failed(crate::SemanticSceneFailure::LimitExceeded))
        ));
        assert!(attachment.events.is_detached());
        assert_eq!(surface.as_pty().unwrap().semantic_scenes.lock().unwrap().attachment_count(), 0);
    }

    #[test]
    fn semantic_scene_static_kitty_is_content_addressed_and_keeps_attachment_open() {
        let mux = Mux::new_for_test("semantic-kitty", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attachment = surface.attach_semantic_scene(semantic_options(&surface, 1)).unwrap();

        let (_, worked) = apply_terminal_output(
            &surface,
            b"\x1b_Ga=T,t=d,f=32,i=1,p=1,s=1,v=1,c=1,r=1,z=1;/wAA/w==\x1b\\",
        );
        assert!(worked);
        let scene = expect_semantic_scene(attachment.events.try_recv().unwrap());
        assert_eq!(scene.canonical_kind, SceneSectionKind::Delta);
        assert_eq!(scene.content_sequence, 2);

        let pixels = [0xff, 0x00, 0x00, 0xff];
        let mut digest = Sha256::new();
        digest.update(b"ghostty-kitty-static-v1\0");
        digest.update(1_u32.to_le_bytes());
        digest.update(1_u32.to_le_bytes());
        digest.update([3]);
        digest.update(pixels);
        let digest = digest.finalize();
        assert!(scene.as_bytes().windows(digest.len()).any(|window| window == digest.as_slice()));
        assert!(scene.as_bytes().windows(pixels.len()).any(|window| window == pixels));
        assert!(!attachment.events.is_detached());
        assert_eq!(surface.as_pty().unwrap().semantic_scenes.lock().unwrap().attachment_count(), 1);
    }

    #[test]
    fn semantic_scene_failure_remains_bounded_when_event_channel_is_full() {
        let mux = Mux::new_for_test("semantic-failure-overflow", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attachment = surface.attach_semantic_scene(semantic_options(&surface, 1)).unwrap();
        let (queued_generation, _) = apply_terminal_output(&surface, b"queued");

        let pty = surface.as_pty().unwrap();
        let mut wrong_identity = pty.semantic_identity;
        wrong_identity.runtime_epoch = wrong_identity.runtime_epoch.wrapping_add(1).max(1);
        let mut term = pty.term.lock().unwrap();
        assert!(pty.semantic_scenes.lock().unwrap().capture_locked(
            &mut term,
            wrong_identity,
            queued_generation,
        ));
        drop(term);

        let queued = expect_semantic_scene(attachment.events.try_recv().unwrap());
        assert_eq!(queued.content_sequence, queued_generation);
        assert!(matches!(
            attachment.events.try_recv(),
            Ok(crate::SemanticSceneEvent::Failed(crate::SemanticSceneFailure::InvalidInput))
        ));
        assert!(attachment.events.is_detached());
    }

    #[test]
    fn semantic_scene_custom_shader_negotiates_before_stale_identity_rejection() {
        let mux = Mux::new_for_test("semantic-invalid", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();

        let mut shader_options = semantic_options(&surface, 1);
        shader_options.capture.custom_shader_count = 1;
        let shader_attachment = surface.attach_semantic_scene(shader_options).unwrap();
        assert!(!shader_attachment.initial.is_empty());
        drop(shader_attachment);
        let _ = apply_terminal_output(&surface, b"prune detached shader presentation");

        let mut stale_options = semantic_options(&surface, 1);
        stale_options.terminal.runtime_epoch =
            stale_options.terminal.runtime_epoch.wrapping_add(1).max(1);
        assert!(matches!(
            surface.attach_semantic_scene(stale_options),
            Err(SemanticSceneAttachError::TerminalIdentityMismatch)
        ));
        assert_eq!(surface.as_pty().unwrap().semantic_scenes.lock().unwrap().attachment_count(), 0);
    }
}
