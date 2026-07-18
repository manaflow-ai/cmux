//! Surface runtime: one tab inside a pane.
//!
//! A surface is either a PTY backed by libghostty-vt state or a local CDP
//! browser surface. PTY-only methods stay available for existing callers;
//! browser-aware frontends should branch on [`SurfaceKind`] before using
//! VT operations.

use std::io::{Read, Write};
use std::mem::size_of;
use std::ops::Deref;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{
    Receiver, RecvError, RecvTimeoutError, SyncSender, TryRecvError, TrySendError, sync_channel,
};
use std::sync::{Arc, Mutex, TryLockError, Weak};
use std::time::{Duration, Instant};

use ghostty_vt::{
    Callbacks, CursorShape, MouseEncoders, MouseInput, RenderFrame, RenderState, Rgb, Terminal,
    TerminalColorOverrides,
};
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};

use crate::platform;
use crate::{Mux, MuxEvent, SurfaceId};

use crate::browser::BrowserSurface;
pub use crate::browser::{
    BrowserAttachState, BrowserFrame, BrowserFrameStream, BrowserSource, BrowserStatus,
};
#[cfg(unix)]
use crate::terminal_host_protocol::{FLAG_COLORS_FOLLOW, Frame, MessageKind, PROTOCOL_VERSION};
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
    /// Durable per-terminal host records. When set, PTYs are created in a
    /// dedicated process and this surface becomes an adoptable mirror.
    pub terminal_host_root: Option<PathBuf>,
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
            terminal_host_root: None,
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
    pub cursor_style: Option<CursorShape>,
    pub cursor_blink: Option<bool>,
    /// Complete sparse application-authored OSC 4 state. Missing entries
    /// mean reset to the receiving frontend's palette defaults.
    pub palette: [Option<Rgb>; 256],
}

impl Default for TerminalColors {
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

impl TerminalColors {
    fn from_terminal(term: &mut Terminal, defaults: DefaultColors) -> Self {
        let (fg, bg, cursor) = term.effective_colors();
        let palette = term.color_overrides().palette;
        let cursor_visual = term.cursor_overridden().then(|| {
            RenderState::new()
                .and_then(|mut state| {
                    state.update(term)?;
                    state.cursor_visual()
                })
                .ok()
        });
        let cursor_visual = cursor_visual.flatten();
        TerminalColors {
            fg,
            bg,
            cursor,
            selection_bg: defaults.selection_bg,
            selection_fg: defaults.selection_fg,
            cursor_style: cursor_visual.map(|(style, _)| style).or(defaults.cursor_style),
            cursor_blink: cursor_visual.map(|(_, blink)| blink).or(defaults.cursor_blink),
            palette,
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
    /// One parser transition: consumers must apply `output` and replace the
    /// complete color state before rendering or notifying observers.
    OutputWithColors {
        output: Vec<u8>,
        colors: Box<TerminalColors>,
    },
    Resized {
        cols: u16,
        rows: u16,
        replay: Vec<u8>,
    },
    /// One parser transition: `replay` is theme-portable, so `colors` is part
    /// of the same replacement snapshot rather than a subsequent callback.
    ResizedWithColors {
        cols: u16,
        rows: u16,
        replay: Vec<u8>,
        colors: Box<TerminalColors>,
    },
    ColorsChanged(Box<TerminalColors>),
}

/// A host frame is not actionable until its wire-level atomicity contract is
/// satisfied. In particular, a renderer must never expose output or a resize
/// whose authoritative color state is still sitting in the socket.
#[cfg(unix)]
#[derive(Debug)]
enum HostedTransition {
    Output(Vec<u8>),
    OutputWithColors { output: Vec<u8>, colors: TerminalColorOverrides },
    ResizedWithColors { cols: u16, rows: u16, replay: Vec<u8>, colors: TerminalColorOverrides },
    Metadata(MessageKind),
    Exit,
    ResyncRequired,
}

#[cfg(unix)]
#[derive(Debug)]
enum PendingHostedTransition {
    Output(Vec<u8>),
    Resized { cols: u16, rows: u16, replay: Vec<u8> },
}

#[cfg(unix)]
struct HostedFrameStager {
    expected_sequence: u64,
    pending: Option<PendingHostedTransition>,
}

#[cfg(unix)]
impl HostedFrameStager {
    fn new(sequence_boundary: u64) -> Self {
        Self { expected_sequence: sequence_boundary.wrapping_add(1), pending: None }
    }

    fn push(&mut self, frame: Frame) -> Result<Option<HostedTransition>, &'static str> {
        if frame.version != PROTOCOL_VERSION || frame.request_id != 0 {
            return Err("invalid live-frame envelope");
        }
        if frame.sequence != self.expected_sequence {
            return Err("non-contiguous live-frame sequence");
        }
        self.expected_sequence = self.expected_sequence.wrapping_add(1);

        if let Some(pending) = self.pending.take() {
            if frame.kind != MessageKind::Colors || frame.flags != 0 {
                return Err("coupled frame was not followed by Colors");
            }
            let colors =
                crate::terminal_host_runtime::decode_terminal_color_overrides(&frame.payload)
                    .map_err(|_| "invalid Colors payload")?;
            return Ok(Some(match pending {
                PendingHostedTransition::Output(output) => {
                    HostedTransition::OutputWithColors { output, colors }
                }
                PendingHostedTransition::Resized { cols, rows, replay } => {
                    HostedTransition::ResizedWithColors { cols, rows, replay, colors }
                }
            }));
        }

        match frame.kind {
            MessageKind::Output => match frame.flags {
                0 => Ok(Some(HostedTransition::Output(frame.payload))),
                FLAG_COLORS_FOLLOW => {
                    self.pending = Some(PendingHostedTransition::Output(frame.payload));
                    Ok(None)
                }
                _ => Err("unknown Output flags"),
            },
            MessageKind::Resized => {
                if frame.flags != FLAG_COLORS_FOLLOW || frame.payload.len() < 4 {
                    return Err("invalid Resized frame");
                }
                let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]).max(1);
                let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]).max(1);
                self.pending = Some(PendingHostedTransition::Resized {
                    cols,
                    rows,
                    replay: frame.payload[4..].to_vec(),
                });
                Ok(None)
            }
            MessageKind::Title | MessageKind::Pwd | MessageKind::Bell if frame.flags == 0 => {
                Ok(Some(HostedTransition::Metadata(frame.kind)))
            }
            MessageKind::Exit if frame.flags == 0 => Ok(Some(HostedTransition::Exit)),
            MessageKind::ResyncRequired if frame.flags == 0 => {
                Ok(Some(HostedTransition::ResyncRequired))
            }
            MessageKind::Colors => Err("unpaired Colors frame"),
            _ if frame.flags != 0 => Err("flags are not valid for this message kind"),
            _ => Err("message kind is not valid on the live stream"),
        }
    }
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
                Self::OutputWithColors { output, .. } => {
                    output.capacity() + size_of::<TerminalColors>()
                }
                Self::Resized { replay, .. } => replay.capacity(),
                Self::ResizedWithColors { replay, .. } => {
                    replay.capacity() + size_of::<TerminalColors>()
                }
                Self::ColorsChanged(_) => size_of::<TerminalColors>(),
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

impl SurfaceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            SurfaceKind::Pty => "pty",
            SurfaceKind::Browser => "browser",
        }
    }
}

pub struct SurfaceMeta {
    pub id: SurfaceId,
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
    runtime: Mutex<PtyRuntime>,
    pid: Option<u32>,
    command: Vec<String>,
    cwd: Option<String>,
    dead: AtomicBool,
    /// The daemon is intentionally dropping its compatibility proxy while
    /// leaving the terminal host alive for a later daemon to adopt.
    owner_detaching: AtomicBool,
    /// The host socket ended without a sequenced Exit. Closing this proxy
    /// must retain the host record so a fresh snapshot can recover it.
    host_connection_lost: AtomicBool,
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
    render_generation: AtomicU64,
    frame_requests: SyncSender<u64>,
}

enum PtyRuntime {
    Local {
        writer: Box<dyn Write + Send>,
        master: Box<dyn MasterPty + Send>,
        killer: Box<dyn ChildKiller + Send>,
    },
    #[cfg(unix)]
    Hosted(Box<crate::terminal_host_runtime::HostAttachment>),
}

#[cfg(unix)]
fn hosted_terminal_callbacks(
    id: SurfaceId,
    mux: Weak<Mux>,
    pending_responses: Arc<Mutex<Vec<u8>>>,
    title_changed: Arc<AtomicBool>,
) -> Callbacks {
    Callbacks {
        on_pty_write: Some(Box::new(move |bytes| {
            pending_responses.lock().unwrap().extend_from_slice(bytes);
        })),
        on_title_changed: Some(Box::new(move || {
            title_changed.store(true, Ordering::Relaxed);
        })),
        on_bell: Some(Box::new(move || {
            if let Some(mux) = mux.upgrade() {
                mux.emit(MuxEvent::Bell(id));
            }
        })),
    }
}

impl std::fmt::Debug for Surface {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Surface").field("id", &self.id).field("kind", &self.kind()).finish()
    }
}

impl Surface {
    pub(crate) fn spawn(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        #[cfg(unix)]
        if let Some(root) = opts.terminal_host_root.clone() {
            let default_colors = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
            let attachment =
                crate::terminal_host_runtime::launch_terminal_host(&opts, &root, default_colors)?;
            return Self::spawn_hosted(id, opts, mux, attachment);
        }
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
        let mut cmd = CommandBuilder::new(&argv[0]);
        cmd.args(&argv[1..]);
        cmd.env("TERM", &opts.term);
        for (k, v) in &opts.extra_env {
            cmd.env(k, v);
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
        drop(pty.slave);
        let killer = child.clone_killer();
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
            meta: SurfaceMeta { id, name: Mutex::new(None), selection: Mutex::new(None) },
            term: Mutex::new(term),
            mouse_encoders: Mutex::new(mouse_encoders),
            runtime: Mutex::new(PtyRuntime::Local { writer, master: pty.master, killer }),
            pid,
            command: argv,
            cwd,
            dead: AtomicBool::new(false),
            owner_detaching: AtomicBool::new(false),
            host_connection_lost: AtomicBool::new(false),
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
            render_generation: AtomicU64::new(1),
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
                    let defaults =
                        mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
                    let generation = {
                        let mut term = pty.term.lock().unwrap();
                        let before = terminal_scroll_position(&term);
                        let colors_before = term.color_overrides();
                        term.vt_write(&buf[..n]);
                        pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                        let after = terminal_scroll_position(&term);
                        pty.broadcast_attach_output(&buf[..n]);
                        if term.color_overrides() != colors_before {
                            pty.broadcast_attach_frame(AttachFrame::ColorsChanged(Box::new(
                                TerminalColors::from_terminal(&mut term, defaults),
                            )));
                        }
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
                            scroll_changed = Some(after);
                            broadcast_render_scroll_locked(pty, after);
                        }
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
                    mux.surface_exited(surface.id);
                }
            }
        })?;

        // Child reaper: avoid zombies; the reader thread handles EOF.
        std::thread::Builder::new().name(format!("surface-{id}-wait")).spawn(move || {
            let _ = child.wait();
        })?;

        Ok(surface)
    }

    #[cfg(unix)]
    fn spawn_hosted(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        mut attachment: crate::terminal_host_runtime::HostAttachment,
    ) -> anyhow::Result<Arc<Surface>> {
        let mut reader = attachment.take_reader()?;
        let capability_responses = attachment.capability_responses();
        let snapshot = attachment.snapshot.clone();
        let mut applied_color_overrides = snapshot.colors.clone();
        let pending_responses: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let title_changed = Arc::new(AtomicBool::new(false));
        let callbacks = hosted_terminal_callbacks(
            id,
            mux.clone(),
            pending_responses.clone(),
            title_changed.clone(),
        );
        let mut term = Terminal::new(snapshot.cols, snapshot.rows, opts.scrollback, callbacks)?;
        if let Some(mux) = mux.upgrade() {
            let colors = mux.default_colors();
            term.set_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            term.set_default_cursor(colors.cursor_style, colors.cursor_blink);
        }
        term.vt_write(&snapshot.replay);
        let initial_color_delta =
            terminal_color_override_delta(&Default::default(), &snapshot.colors);
        if !initial_color_delta.is_empty() {
            term.vt_write(&initial_color_delta);
        }
        // Query replies represented in a replay have already been answered by
        // the authoritative host; never send them a second time on adoption.
        pending_responses.lock().unwrap().clear();
        let title = term.title().unwrap_or_default();
        let pwd = term.pwd();
        let mut mouse_encoders = MouseEncoders::new()?;
        mouse_encoders.sync_from_terminal(&term);
        let sequence_boundary = snapshot.sequence_boundary;
        let render_state = RenderState::new()?;
        let (frame_requests, frame_rx) = sync_channel(1);
        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta { id, name: Mutex::new(None), selection: Mutex::new(None) },
            term: Mutex::new(term),
            mouse_encoders: Mutex::new(mouse_encoders),
            runtime: Mutex::new(PtyRuntime::Hosted(Box::new(attachment))),
            pid: snapshot.pid,
            command: snapshot.command,
            cwd: snapshot.cwd,
            dead: AtomicBool::new(false),
            owner_detaching: AtomicBool::new(false),
            host_connection_lost: AtomicBool::new(false),
            dirty: AtomicBool::new(true),
            title: Mutex::new(title),
            pwd: Mutex::new(pwd),
            size: Mutex::new((snapshot.cols, snapshot.rows)),
            mux: mux.clone(),
            taps: Mutex::new(Vec::new()),
            render: Mutex::new(RenderHub {
                state: Box::new(render_state),
                built_generation: 0,
                latest: None,
                taps: Vec::new(),
            }),
            render_generation: AtomicU64::new(1),
            frame_requests,
        }));
        spawn_frame_producer(&surface, frame_rx)?;

        std::thread::Builder::new().name(format!("surface-{id}-host")).spawn({
            let surface = surface.clone();
            let scrollback = opts.scrollback;
            move || {
                let mut stager = HostedFrameStager::new(sequence_boundary);
                let mut received_exit = false;
                'host_stream: while let Ok(Some(frame)) = crate::terminal_host_protocol::read_frame(
                    &mut reader,
                    crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
                ) {
                    let Some(pty) = surface.as_pty() else { break };
                    if frame.kind == MessageKind::Capability && frame.request_id != 0 {
                        if frame.version != PROTOCOL_VERSION
                            || frame.flags != 0
                            || frame.sequence != 0
                        {
                            break;
                        }
                        capability_responses.resolve(&frame);
                        continue;
                    }
                    let Ok(transition) = stager.push(frame) else {
                        break;
                    };
                    let Some(transition) = transition else { continue };
                    match transition {
                        transition @ (HostedTransition::Output(_)
                        | HostedTransition::OutputWithColors { .. }) => {
                            let (output, colors) = match transition {
                                HostedTransition::Output(output) => (output, None),
                                HostedTransition::OutputWithColors { output, colors } => {
                                    (output, Some(colors))
                                }
                                _ => unreachable!(),
                            };
                            let mut scroll_changed = None;
                            let mut title_update = None;
                            let defaults =
                                mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
                            let generation = {
                                let mut term = pty.term.lock().unwrap();
                                let before = terminal_scroll_position(&term);
                                term.vt_write(&output);
                                if let Some(colors) = colors.as_ref() {
                                    let delta = terminal_color_override_delta(
                                        &applied_color_overrides,
                                        colors,
                                    );
                                    if !delta.is_empty() {
                                        term.vt_write(&delta);
                                    }
                                    applied_color_overrides = colors.clone();
                                } else if term.color_overrides() != applied_color_overrides {
                                    // An unflagged Output that changed colors
                                    // violated the producer's iff contract.
                                    break 'host_stream;
                                }
                                pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                                let after = terminal_scroll_position(&term);
                                // The parser already contains the complete
                                // coupled state before any attach observer can
                                // see the Output or ColorsChanged callback.
                                if colors.is_some() {
                                    pty.broadcast_attach_frame(AttachFrame::OutputWithColors {
                                        output,
                                        colors: Box::new(TerminalColors::from_terminal(
                                            &mut term, defaults,
                                        )),
                                    });
                                } else {
                                    pty.broadcast_attach_output(&output);
                                }
                                if title_changed.swap(false, Ordering::Relaxed) {
                                    let title = term.title().unwrap_or_default();
                                    *pty.title.lock().unwrap() = title.clone();
                                    title_update = Some(title);
                                }
                                if let Some(pwd) = term.pwd() {
                                    *pty.pwd.lock().unwrap() = Some(pwd);
                                }
                                if before != after {
                                    scroll_changed = Some(after);
                                    broadcast_render_scroll_locked(pty, after);
                                }
                                pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
                            };
                            pty.request_frame(generation);
                            if let Some(title) = title_update
                                && let Some(mux) = mux.upgrade()
                            {
                                mux.emit(MuxEvent::TitleChanged {
                                    surface: surface.id,
                                    title: title.into(),
                                });
                            }
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
                        HostedTransition::ResizedWithColors { cols, rows, replay, colors } => {
                            let defaults =
                                mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
                            let callbacks = hosted_terminal_callbacks(
                                id,
                                mux.clone(),
                                pending_responses.clone(),
                                title_changed.clone(),
                            );
                            let Ok(mut replacement) =
                                Terminal::new(cols, rows, scrollback, callbacks)
                            else {
                                break;
                            };
                            replacement.set_default_colors(
                                defaults.fg,
                                defaults.bg,
                                defaults.cursor,
                            );
                            replacement.set_default_palette(&defaults.palette);
                            replacement
                                .set_default_cursor(defaults.cursor_style, defaults.cursor_blink);
                            replacement.vt_write(&replay);
                            let delta = terminal_color_override_delta(&Default::default(), &colors);
                            if !delta.is_empty() {
                                replacement.vt_write(&delta);
                            }
                            // Replay query responses were already answered by
                            // the host; never send them again from the mirror.
                            pending_responses.lock().unwrap().clear();
                            title_changed.store(false, Ordering::Relaxed);
                            let title = replacement.title().unwrap_or_default();
                            let pwd = replacement.pwd();
                            let mut scroll_changed = None;
                            let generation = {
                                let mut term = pty.term.lock().unwrap();
                                let before = terminal_scroll_position(&term);
                                *term = replacement;
                                pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                                *pty.size.lock().unwrap() = (cols, rows);
                                *pty.title.lock().unwrap() = title.clone();
                                *pty.pwd.lock().unwrap() = pwd;
                                applied_color_overrides = colors;
                                let after = terminal_scroll_position(&term);
                                if before != after {
                                    scroll_changed = Some(after);
                                    broadcast_render_scroll_locked(pty, after);
                                }
                                // Both attach notifications are queued only
                                // after the authoritative replay and complete
                                // color state have replaced the old parser.
                                pty.broadcast_attach_frame(AttachFrame::ResizedWithColors {
                                    cols,
                                    rows,
                                    replay,
                                    colors: Box::new(TerminalColors::from_terminal(
                                        &mut term, defaults,
                                    )),
                                });
                                pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
                            };
                            pty.request_frame(generation);
                            if let Some(mux) = mux.upgrade() {
                                mux.emit(MuxEvent::TitleChanged {
                                    surface: surface.id,
                                    title: title.into(),
                                });
                                mux.emit(MuxEvent::SurfaceResized {
                                    surface: surface.id,
                                    cols,
                                    rows,
                                    reservation_id: None,
                                });
                                if let Some((offset, at_bottom)) = scroll_changed {
                                    mux.emit(MuxEvent::ScrollChanged {
                                        surface: surface.id,
                                        offset,
                                        at_bottom,
                                    });
                                }
                            }
                        }
                        // The mirror derives these from the preceding Output;
                        // the sequenced metadata frames are still consumed so
                        // they cannot hide a stream gap.
                        HostedTransition::Metadata(_kind) => {}
                        HostedTransition::Exit => {
                            received_exit = true;
                            break;
                        }
                        HostedTransition::ResyncRequired => break,
                    }
                }
                if surface.as_pty().is_some_and(|pty| pty.owner_detaching.load(Ordering::Acquire)) {
                    return;
                }
                if let Some(pty) = surface.as_pty() {
                    if !received_exit {
                        pty.host_connection_lost.store(true, Ordering::Release);
                    }
                    pty.dead.store(true, Ordering::Release);
                }
                if let Some(mux) = mux.upgrade() {
                    mux.surface_exited(surface.id);
                }
            }
        })?;
        Ok(surface)
    }

    #[cfg(unix)]
    pub(crate) fn adopt_hosted(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: PathBuf,
    ) -> anyhow::Result<Arc<Surface>> {
        let attachment = crate::terminal_host_runtime::adopt_terminal_host(record, record_path)?;
        Self::spawn_hosted(id, opts, mux, attachment)
    }

    #[cfg(test)]
    pub(crate) fn spawn_for_test(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
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
        if let Some(mux) = mux.upgrade() {
            let colors = mux.default_colors();
            term.set_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            term.set_default_cursor(colors.cursor_style, colors.cursor_blink);
        }
        let mut mouse_encoders = MouseEncoders::new()?;
        mouse_encoders.sync_from_terminal(&term);

        let render_state = RenderState::new()?;
        let (frame_requests, _frame_rx) = sync_channel(1);

        Ok(Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta { id, name: Mutex::new(None), selection: Mutex::new(None) },
            term: Mutex::new(term),
            mouse_encoders: Mutex::new(mouse_encoders),
            runtime: Mutex::new(PtyRuntime::Local {
                writer: Box::new(std::io::sink()),
                master: Box::new(TestMasterPty {
                    size: Mutex::new(PtySize {
                        rows: opts.rows,
                        cols: opts.cols,
                        pixel_width: 0,
                        pixel_height: 0,
                    }),
                }),
                killer: Box::new(TestChildKiller),
            }),
            pid: Some(id as u32),
            command: opts.command.unwrap_or_else(|| vec![platform::default_shell()]),
            cwd: opts.cwd,
            dead: AtomicBool::new(false),
            owner_detaching: AtomicBool::new(false),
            host_connection_lost: AtomicBool::new(false),
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
            render_generation: AtomicU64::new(1),
            frame_requests,
        })))
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

    /// Write input bytes to the PTY child.
    pub fn write_bytes(&self, bytes: &[u8]) -> std::io::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "browser surface does not accept PTY bytes",
            ));
        };
        let mut runtime = pty.runtime.lock().unwrap();
        match &mut *runtime {
            PtyRuntime::Local { writer, .. } => {
                writer.write_all(bytes)?;
                writer.flush()
            }
            #[cfg(unix)]
            PtyRuntime::Hosted(host) => host.send(MessageKind::Input, bytes),
        }
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
        #[cfg(unix)]
        {
            let runtime = pty.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                return host.send(MessageKind::Paste, bytes);
            }
        }
        let bracketed = {
            let term = pty.term.lock().unwrap();
            term.mode(2004, false)
        };
        let mut runtime = pty.runtime.lock().unwrap();
        let PtyRuntime::Local { writer, .. } = &mut *runtime else {
            unreachable!("hosted paste returned above")
        };
        if bracketed {
            writer.write_all(b"\x1b[200~")?;
        }
        writer.write_all(bytes)?;
        if bracketed {
            writer.write_all(b"\x1b[201~")?;
        }
        writer.flush()
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
                broadcast_render_scroll_locked(pty, after);
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
                broadcast_render_scroll_locked(pty, after);
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

    pub fn set_default_colors(&self, colors: DefaultColors) {
        if let Some(pty) = self.as_pty() {
            let mut term = pty.term.lock().unwrap();
            term.set_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            term.set_default_cursor(colors.cursor_style, colors.cursor_blink);
            let colors = TerminalColors::from_terminal(&mut term, colors);
            let mut taps = pty.taps.lock().unwrap();
            if !taps.is_empty() {
                taps.retain(|tap| tap.try_send(AttachFrame::ColorsChanged(Box::new(colors))));
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

    /// Hosted PTYs acknowledge a resize with an authoritative replay/color
    /// pair. The mux must wait for that pair before publishing the new grid.
    pub(crate) fn resize_reports_asynchronously(&self) -> bool {
        match self {
            Surface::Pty(pty) => {
                #[cfg(unix)]
                {
                    matches!(&*pty.runtime.lock().unwrap(), PtyRuntime::Hosted(_))
                }
                #[cfg(not(unix))]
                {
                    false
                }
            }
            Surface::Browser(_) => true,
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

    pub fn spawn_cwd(&self) -> Option<String> {
        self.as_pty().and_then(|pty| pty.cwd.clone())
    }

    /// Process-stable identity for hosted terminals. Surface ids remain
    /// daemon-local compatibility handles and may change after adoption.
    pub fn terminal_host_identity(
        &self,
    ) -> Option<crate::terminal_host_runtime::TerminalHostIdentity> {
        #[cfg(unix)]
        if let Some(pty) = self.as_pty()
            && let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap()
        {
            return Some(host.identity());
        }
        None
    }

    /// Ask the host to mint a one-use renderer credential. The durable owner
    /// secret remains confined to the daemon and its private state record.
    pub fn mint_renderer_grant(
        &self,
        ttl: Duration,
    ) -> anyhow::Result<crate::terminal_host_runtime::RendererGrant> {
        #[cfg(unix)]
        if let Some(pty) = self.as_pty()
            && let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap()
        {
            return host.mint_renderer_grant(ttl);
        }
        let _ = ttl;
        anyhow::bail!("surface is not backed by a terminal host")
    }

    pub fn is_dead(&self) -> bool {
        match self {
            Surface::Pty(pty) => pty.dead.load(Ordering::Acquire),
            Surface::Browser(browser) => browser.is_dead(),
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

    pub fn kill(&self) {
        match self {
            Surface::Pty(pty) => {
                let mut runtime = pty.runtime.lock().unwrap();
                match &mut *runtime {
                    PtyRuntime::Local { killer, .. } => {
                        let _ = killer.kill();
                    }
                    #[cfg(unix)]
                    PtyRuntime::Hosted(host) => {
                        if pty.host_connection_lost.load(Ordering::Acquire) {
                            host.disconnect();
                            return;
                        }
                        let _ = host.terminate();
                        crate::terminal_host_runtime::remove_terminal_host_record(
                            &host.record_path,
                        );
                    }
                }
            }
            Surface::Browser(browser) => browser.kill(),
        }
    }

    pub(crate) fn disconnect_for_daemon_shutdown(&self) {
        match self {
            #[cfg(unix)]
            Surface::Pty(pty) => {
                if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                    pty.owner_detaching.store(true, Ordering::Release);
                    host.disconnect();
                    return;
                }
                self.kill();
            }
            #[cfg(not(unix))]
            Surface::Pty(_) => self.kill(),
            Surface::Browser(browser) => browser.kill(),
        }
    }

    pub(crate) fn persist_host_workspace(&self, workspace_key: &str) -> anyhow::Result<()> {
        #[cfg(unix)]
        if let Some(pty) = self.as_pty()
            && let PtyRuntime::Hosted(host) = &mut *pty.runtime.lock().unwrap()
        {
            return host.persist_workspace(workspace_key);
        }
        Ok(())
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

#[cfg(test)]
struct TestMasterPty {
    size: Mutex<PtySize>,
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
        None
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

impl PtySurface {
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
        Ok(built)
    }

    /// Resize both the PTY and the terminal state. Returns whether the
    /// final clamped size actually changed.
    fn resize(&self, cols: u16, rows: u16) -> bool {
        let (cols, rows) = (cols.max(1), rows.max(1));
        #[cfg(unix)]
        {
            let runtime = self.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                if *self.size.lock().unwrap() == (cols, rows) {
                    return false;
                }
                // Do not speculatively reflow the mirror. The host returns a
                // Resized+Colors pair containing the canonical post-resize
                // replay, which the reader installs as one transition.
                return host.send_viewer_size(cols, rows).is_ok();
            }
        }
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
        {
            let mut runtime = self.runtime.lock().unwrap();
            match &mut *runtime {
                PtyRuntime::Local { master, .. } => {
                    let _ = master.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 });
                }
                #[cfg(unix)]
                PtyRuntime::Hosted(_) => unreachable!("hosted resize returned above"),
            }
        }
        // Nominal cell metrics; only pixel size reports observe these.
        let _ = term.resize(cols, rows, 8, 16);
        let replay = term.vt_replay_bounded(VT_REPLAY_MAX_BYTES).unwrap_or_default();
        self.broadcast_attach_frame(AttachFrame::Resized { cols, rows, replay });
        let generation = self.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let _ = self.build_frame_locked(&mut term, generation, false);
        true
    }
}

fn terminal_color_override_delta(
    previous: &TerminalColorOverrides,
    next: &TerminalColorOverrides,
) -> Vec<u8> {
    fn dynamic_color(output: &mut Vec<u8>, set_code: u16, reset_code: u16, color: Option<Rgb>) {
        match color {
            Some(color) => output.extend_from_slice(
                format!(
                    "\x1b]{set_code};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
                    color.r, color.g, color.b
                )
                .as_bytes(),
            ),
            None => output.extend_from_slice(format!("\x1b]{reset_code}\x1b\\").as_bytes()),
        }
    }

    let mut output = Vec::new();
    if previous.foreground != next.foreground {
        dynamic_color(&mut output, 10, 110, next.foreground);
    }
    if previous.background != next.background {
        dynamic_color(&mut output, 11, 111, next.background);
    }
    if previous.cursor != next.cursor {
        dynamic_color(&mut output, 12, 112, next.cursor);
    }
    for index in 0..256 {
        if previous.palette[index] == next.palette[index] {
            continue;
        }
        match next.palette[index] {
            Some(color) => output.extend_from_slice(
                format!("\x1b]4;{index};rgb:{:02x}/{:02x}/{:02x}\x1b\\", color.r, color.g, color.b)
                    .as_bytes(),
            ),
            None => output.extend_from_slice(format!("\x1b]104;{index}\x1b\\").as_bytes()),
        }
    }
    output
}

const RENDER_FRAME_CADENCE: Duration = Duration::from_millis(8);

fn spawn_frame_producer(surface: &Arc<Surface>, requests: Receiver<u64>) -> anyhow::Result<()> {
    let weak = Arc::downgrade(surface);
    let id = surface.id;
    std::thread::Builder::new().name(format!("surface-{id}-frames")).spawn(move || {
        let mut last_frame = Instant::now() - RENDER_FRAME_CADENCE;
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
            let Some(surface) = weak.upgrade() else { break };
            let Some(pty) = surface.as_pty() else { break };
            let mut term = pty.term.lock().unwrap();
            let generation = requested.max(pty.render_generation.load(Ordering::Acquire));
            if pty.build_frame_locked(&mut term, generation, true).unwrap_or(false) {
                last_frame = Instant::now();
            }
        }
    })?;
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

    #[test]
    fn terminal_color_override_delta_sets_and_resets_sparse_state() {
        let mut colors = TerminalColorOverrides {
            foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
            background: Some(Rgb { r: 4, g: 5, b: 6 }),
            cursor: Some(Rgb { r: 7, g: 8, b: 9 }),
            ..Default::default()
        };
        colors.palette[42] = Some(Rgb { r: 10, g: 11, b: 12 });
        let mut terminal = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
        terminal.vt_write(&terminal_color_override_delta(&Default::default(), &colors));
        assert_eq!(terminal.color_overrides(), colors);

        terminal.vt_write(&terminal_color_override_delta(&colors, &Default::default()));
        assert_eq!(terminal.color_overrides(), Default::default());
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

    #[cfg(unix)]
    #[test]
    fn hosted_stager_exposes_coupled_state_only_after_colors() {
        let mut stager = HostedFrameStager::new(40);
        let mut resize = Frame::new(MessageKind::Resized, {
            let mut payload = Vec::from([101, 0, 37, 0]);
            payload.extend_from_slice(b"authoritative replay");
            payload
        });
        resize.flags = FLAG_COLORS_FOLLOW;
        resize.sequence = 41;

        // A delayed Colors frame cannot expose a resize attach callback or a
        // renderable transition with the old theme.
        assert!(stager.push(resize).unwrap().is_none());

        let colors = TerminalColorOverrides {
            foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
            ..Default::default()
        };
        let mut colors_frame = Frame::new(
            MessageKind::Colors,
            crate::terminal_host_runtime::encode_terminal_color_overrides(&colors),
        );
        colors_frame.sequence = 42;
        match stager.push(colors_frame).unwrap().unwrap() {
            HostedTransition::ResizedWithColors { cols, rows, replay, colors: received } => {
                assert_eq!((cols, rows), (101, 37));
                assert_eq!(replay, b"authoritative replay");
                assert_eq!(received, colors);
            }
            other => panic!("unexpected staged transition: {other:?}"),
        }

        let mut output = Frame::new(MessageKind::Output, b"\x1b]10;red\x1b\\".to_vec());
        output.flags = FLAG_COLORS_FOLLOW;
        output.sequence = 43;
        assert!(stager.push(output).unwrap().is_none());
        let mut colors_frame = Frame::new(
            MessageKind::Colors,
            crate::terminal_host_runtime::encode_terminal_color_overrides(&colors),
        );
        colors_frame.sequence = 44;
        assert!(matches!(
            stager.push(colors_frame).unwrap(),
            Some(HostedTransition::OutputWithColors { .. })
        ));
    }

    #[cfg(unix)]
    #[test]
    fn hosted_stager_fails_closed_on_invalid_flags_and_pairing() {
        let mut stager = HostedFrameStager::new(0);
        let mut resized = Frame::new(MessageKind::Resized, vec![80, 0, 24, 0]);
        resized.sequence = 1;
        assert!(stager.push(resized).is_err(), "Resized must declare Colors follow");

        let mut stager = HostedFrameStager::new(0);
        let mut output = Frame::new(MessageKind::Output, vec![]);
        output.flags = FLAG_COLORS_FOLLOW | (1 << 7);
        output.sequence = 1;
        assert!(stager.push(output).is_err(), "unknown flags must fail closed");

        let mut stager = HostedFrameStager::new(0);
        let mut output = Frame::new(MessageKind::Output, vec![]);
        output.flags = FLAG_COLORS_FOLLOW;
        output.sequence = 1;
        assert!(stager.push(output).unwrap().is_none());
        let mut exit = Frame::new(MessageKind::Exit, vec![]);
        exit.sequence = 2;
        assert!(stager.push(exit).is_err(), "a coupled frame requires Colors exactly next");
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
}
