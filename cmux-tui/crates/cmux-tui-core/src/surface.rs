//! Surface runtime: one tab inside a pane.
//!
//! A surface is either a PTY backed by libghostty-vt state or a local CDP
//! browser surface. PTY-only methods stay available for existing callers;
//! browser-aware frontends should branch on [`SurfaceKind`] before using
//! VT operations.

use std::io::{Read, Write};
use std::mem::size_of;
use std::ops::Deref;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{
    Receiver, RecvError, RecvTimeoutError, SyncSender, TryRecvError, TrySendError, sync_channel,
};
use std::sync::{Arc, Condvar, Mutex, TryLockError, Weak};
use std::time::{Duration, Instant};

use ghostty_vt::{
    Callbacks, CursorShape, MouseEncoders, MouseInput, RenderFrame, RenderState, Rgb, Terminal,
};
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};

use crate::platform;
use crate::{Mux, MuxEvent, SurfaceId};

pub use crate::browser::{
    BrowserAttachState, BrowserFrame, BrowserFrameStream, BrowserSource, BrowserStatus,
};
use crate::browser::{BrowserResizeWaiter, BrowserSurface, PendingBrowserResize};
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
    /// Palette entries actively authored by the PTY with OSC 4. Unauthored
    /// entries stay `None` so an attached renderer can preserve its own
    /// configured theme.
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
    fn from_terminal(
        term: &Terminal,
        defaults: DefaultColors,
        cursor_visual: Option<(CursorShape, bool)>,
    ) -> Self {
        let (fg, bg, cursor) = term.effective_colors();
        let effective_palette = term.effective_palette().ok();
        let palette = std::array::from_fn(|index| {
            effective_palette.as_ref().and_then(|palette| {
                let index = index as u8;
                term.palette_overridden(index).then(|| palette[index as usize])
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

    /// Snapshot a live palette update without touching the shared renderer.
    /// Palette OSC commands leave cursor state authoritative in the attached
    /// frontend's existing xterm state.
    fn from_pty_output(term: &Terminal, defaults: DefaultColors) -> Self {
        let mut colors = Self::from_terminal(term, defaults, None);
        colors.cursor_style = None;
        colors.cursor_blink = None;
        colors
    }
}

/// Everything an attaching frontend needs to adopt a PTY surface: its
/// size, a VT replay of the current state, and a live stream of every pty
/// byte applied after the replay snapshot.
pub struct AttachStream {
    pub cols: u16,
    pub rows: u16,
    pub replay: Vec<u8>,
    pub kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
    pub colors: TerminalColors,
    pub stream: AttachFrameReceiver,
    pub(crate) lifecycle: AttachLifecycle,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachFrame {
    Output(Vec<u8>),
    Resized {
        cols: u16,
        rows: u16,
        replay: Vec<u8>,
        kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
        colors: Box<TerminalColors>,
    },
    ColorsChanged(Arc<TerminalColors>),
}

const ATTACH_STREAM_CAPACITY: usize = 256;
const ATTACH_STREAM_MAX_BYTES: usize = 16 * 1024 * 1024;
pub(crate) const VT_REPLAY_MAX_BYTES: usize = 8 * 1024 * 1024;

pub struct AttachFrameReceiver {
    receiver: Receiver<AttachFrame>,
    queued_bytes: Arc<AtomicUsize>,
    lifecycle: AttachLifecycle,
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

impl Drop for AttachFrameReceiver {
    fn drop(&mut self) {
        self.lifecycle.cancel();
    }
}

impl AttachFrame {
    fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + match self {
                Self::Output(bytes) => bytes.capacity(),
                Self::Resized { replay, kitty_image_aliases, .. } => {
                    replay.capacity()
                        + kitty_image_aliases.capacity() * size_of::<ghostty_vt::KittyImageAlias>()
                        + size_of::<TerminalColors>()
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

#[derive(Clone, Copy, PartialEq, Eq)]
enum PendingRenderKind {
    Frame,
    Scroll,
}

struct RenderTapQueue {
    pending_frame: Option<Arc<SurfaceRenderFrame>>,
    pending_scroll: Option<(u64, bool)>,
    latest_kind: Option<PendingRenderKind>,
    sender_alive: bool,
    receiver_alive: bool,
}

impl RenderTapQueue {
    fn push(&mut self, event: RenderAttachFrame) {
        match event {
            RenderAttachFrame::Frame(frame) => {
                self.pending_frame = Some(frame);
                self.latest_kind = Some(PendingRenderKind::Frame);
            }
            RenderAttachFrame::ScrollChanged { offset, at_bottom } => {
                self.pending_scroll = Some((offset, at_bottom));
                self.latest_kind = Some(PendingRenderKind::Scroll);
            }
        }
    }

    fn pop(&mut self) -> Option<RenderAttachFrame> {
        let next =
            match (self.pending_frame.is_some(), self.pending_scroll.is_some(), self.latest_kind) {
                (true, true, Some(PendingRenderKind::Frame)) => {
                    let (offset, at_bottom) = self.pending_scroll.take().unwrap();
                    RenderAttachFrame::ScrollChanged { offset, at_bottom }
                }
                (true, true, Some(PendingRenderKind::Scroll)) => {
                    RenderAttachFrame::Frame(self.pending_frame.take().unwrap())
                }
                (true, true, None) => unreachable!("pending render events have an ordering"),
                (true, false, _) => RenderAttachFrame::Frame(self.pending_frame.take().unwrap()),
                (false, true, _) => {
                    let (offset, at_bottom) = self.pending_scroll.take().unwrap();
                    RenderAttachFrame::ScrollChanged { offset, at_bottom }
                }
                (false, false, _) => return None,
            };
        if self.pending_frame.is_none() && self.pending_scroll.is_none() {
            self.latest_kind = None;
        }
        Some(next)
    }
}

struct RenderTapState {
    queue: Mutex<RenderTapQueue>,
    ready: Condvar,
}

struct RenderTap {
    state: Arc<RenderTapState>,
}

impl RenderTap {
    fn pair() -> (Self, RenderAttachFrameReceiver) {
        let state = Arc::new(RenderTapState {
            queue: Mutex::new(RenderTapQueue {
                pending_frame: None,
                pending_scroll: None,
                latest_kind: None,
                sender_alive: true,
                receiver_alive: true,
            }),
            ready: Condvar::new(),
        });
        (Self { state: state.clone() }, RenderAttachFrameReceiver { state })
    }

    fn send(&self, event: RenderAttachFrame) -> bool {
        let mut queue = self.state.queue.lock().unwrap();
        if !queue.receiver_alive {
            return false;
        }
        queue.push(event);
        drop(queue);
        self.state.ready.notify_one();
        true
    }
}

impl Drop for RenderTap {
    fn drop(&mut self) {
        self.state.queue.lock().unwrap().sender_alive = false;
        self.state.ready.notify_all();
    }
}

/// Bounded receiver for one render attachment.
pub struct RenderAttachFrameReceiver {
    state: Arc<RenderTapState>,
}

impl RenderAttachFrameReceiver {
    pub fn recv(&self) -> Result<RenderAttachFrame, RecvError> {
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if let Some(event) = queue.pop() {
                return Ok(event);
            }
            if !queue.sender_alive {
                return Err(RecvError);
            }
            queue = self.state.ready.wait(queue).unwrap();
        }
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<RenderAttachFrame, RecvTimeoutError> {
        let started = Instant::now();
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if let Some(event) = queue.pop() {
                return Ok(event);
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            let Some(remaining) = timeout.checked_sub(started.elapsed()) else {
                return Err(RecvTimeoutError::Timeout);
            };
            let (next, result) = self.state.ready.wait_timeout(queue, remaining).unwrap();
            queue = next;
            if result.timed_out() && queue.pending_frame.is_none() && queue.pending_scroll.is_none()
            {
                return Err(RecvTimeoutError::Timeout);
            }
        }
    }

    pub fn try_recv(&self) -> Result<RenderAttachFrame, TryRecvError> {
        let mut queue = self.state.queue.lock().unwrap();
        if let Some(event) = queue.pop() {
            Ok(event)
        } else if queue.sender_alive {
            Err(TryRecvError::Empty)
        } else {
            Err(TryRecvError::Disconnected)
        }
    }
}

impl Drop for RenderAttachFrameReceiver {
    fn drop(&mut self) {
        let mut queue = self.state.queue.lock().unwrap();
        queue.receiver_alive = false;
        queue.pending_frame = None;
        queue.pending_scroll = None;
    }
}

/// Initial render snapshot and the ordered live stream registered with it.
pub struct RenderAttachStream {
    pub initial: Arc<SurfaceRenderFrame>,
    pub stream: RenderAttachFrameReceiver,
}

struct RenderHub {
    state: Box<RenderState>,
    built_generation: u64,
    latest: Option<Arc<SurfaceRenderFrame>>,
    taps: Vec<RenderTap>,
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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PtyGeometry {
    cols: u16,
    rows: u16,
    cell_width: u16,
    cell_height: u16,
}

impl PtyGeometry {
    fn pty_size(self) -> PtySize {
        PtySize {
            rows: self.rows,
            cols: self.cols,
            pixel_width: total_pixels(self.cols, self.cell_width),
            pixel_height: total_pixels(self.rows, self.cell_height),
        }
    }
}

pub struct PtySurface {
    pub(crate) meta: SurfaceMeta,
    term: Mutex<Terminal>,
    mouse_encoders: Mutex<MouseEncoders>,
    writer: Mutex<Box<dyn Write + Send>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send>>,
    pid: Option<u32>,
    command: Vec<String>,
    cwd: Option<String>,
    dead: AtomicBool,
    /// Set when output arrived since the last render; cleared by the
    /// frontend when it draws.
    dirty: AtomicBool,
    title: Mutex<String>,
    pwd: Mutex<Option<String>>,
    geometry: Mutex<PtyGeometry>,
    #[cfg(test)]
    geometry_test_hook: Mutex<Option<Arc<dyn Fn(PtyGeometryTestStep) + Send + Sync>>>,
    #[cfg(test)]
    test_master_control: Option<Arc<TestMasterPtyControl>>,
    #[cfg(test)]
    vt_replay_builds: AtomicUsize,
    mux: Weak<Mux>,
    /// Live output subscribers (attach streams). Guarded by the terminal
    /// lock ordering: the reader thread broadcasts while holding the
    /// terminal lock, and [`Surface::attach_stream`] registers taps under
    /// the same lock, so a subscriber sees exactly the bytes applied
    /// after its replay snapshot — no gap, no duplication.
    taps: Mutex<Vec<AttachTap>>,
    /// A PTY color mutation awaiting bounded attach-stream fan-out.
    attach_colors_pending: AtomicBool,
    /// A terminal reset requires reapplying equal palette values because byte
    /// frontends reset their local palette while Ghostty preserves overrides.
    attach_colors_force_pending: AtomicBool,
    /// Last effective color state emitted to attach streams. This suppresses
    /// repeated OSC sets that advance Ghostty's revision without changing the
    /// frontend-visible state.
    last_attach_colors: Mutex<Option<Box<TerminalColors>>>,
    /// Single consume-once Ghostty render state shared by the local TUI and
    /// every protocol-v7 render attachment.
    render: Mutex<RenderHub>,
    render_generation: AtomicU64,
    frame_requests: SyncSender<u64>,
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
        let cell_pixels = mux.upgrade().map(|mux| mux.cell_pixel_size()).unwrap_or((8, 16));
        let pty = native_pty_system().openpty(PtySize {
            rows: opts.rows,
            cols: opts.cols,
            pixel_width: total_pixels(opts.cols, cell_pixels.0),
            pixel_height: total_pixels(opts.rows, cell_pixels.1),
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
        term.resize(opts.cols, opts.rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
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
            writer: Mutex::new(writer),
            master: Mutex::new(pty.master),
            killer: Mutex::new(killer),
            pid,
            command: argv,
            cwd,
            dead: AtomicBool::new(false),
            dirty: AtomicBool::new(false),
            title: Mutex::new(String::new()),
            pwd: Mutex::new(None),
            geometry: Mutex::new(PtyGeometry {
                cols: opts.cols,
                rows: opts.rows,
                cell_width: cell_pixels.0,
                cell_height: cell_pixels.1,
            }),
            #[cfg(test)]
            geometry_test_hook: Mutex::new(None),
            #[cfg(test)]
            test_master_control: None,
            #[cfg(test)]
            vt_replay_builds: AtomicUsize::new(0),
            mux: mux.clone(),
            taps: Mutex::new(Vec::new()),
            attach_colors_pending: AtomicBool::new(false),
            attach_colors_force_pending: AtomicBool::new(false),
            last_attach_colors: Mutex::new(None),
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
                    let generation = {
                        let mut term = pty.term.lock().unwrap();
                        let before = terminal_scroll_position(&term);
                        let color_revision = term.color_revision();
                        let color_reapply_revision = term.color_reapply_revision();
                        term.vt_write(&buf[..n]);
                        pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                        let after = terminal_scroll_position(&term);
                        let has_attach_taps = pty.broadcast_attach_output(&buf[..n]);
                        if has_attach_taps && term.color_revision() != color_revision {
                            pty.attach_colors_pending.store(true, Ordering::Release);
                            if term.color_reapply_revision() != color_reapply_revision {
                                pty.attach_colors_force_pending.store(true, Ordering::Release);
                            }
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

    #[cfg(test)]
    pub(crate) fn spawn_for_test(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels = mux.upgrade().map(|mux| mux.cell_pixel_size()).unwrap_or((8, 16));
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
        term.resize(opts.cols, opts.rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
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
        let test_master_control = Arc::new(TestMasterPtyControl::default());

        Ok(Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta { id, name: Mutex::new(None), selection: Mutex::new(None) },
            term: Mutex::new(term),
            mouse_encoders: Mutex::new(mouse_encoders),
            writer: Mutex::new(Box::new(std::io::sink())),
            master: Mutex::new(Box::new(TestMasterPty {
                size: Mutex::new(PtySize {
                    rows: opts.rows,
                    cols: opts.cols,
                    pixel_width: total_pixels(opts.cols, cell_pixels.0),
                    pixel_height: total_pixels(opts.rows, cell_pixels.1),
                }),
                control: test_master_control.clone(),
            })),
            killer: Mutex::new(Box::new(TestChildKiller)),
            pid: Some(id as u32),
            command: opts.command.unwrap_or_else(|| vec![platform::default_shell()]),
            cwd: opts.cwd,
            dead: AtomicBool::new(false),
            dirty: AtomicBool::new(false),
            title: Mutex::new(String::new()),
            pwd: Mutex::new(None),
            geometry: Mutex::new(PtyGeometry {
                cols: opts.cols,
                rows: opts.rows,
                cell_width: cell_pixels.0,
                cell_height: cell_pixels.1,
            }),
            geometry_test_hook: Mutex::new(None),
            test_master_control: Some(test_master_control),
            vt_replay_builds: AtomicUsize::new(0),
            mux,
            taps: Mutex::new(Vec::new()),
            attach_colors_pending: AtomicBool::new(false),
            attach_colors_force_pending: AtomicBool::new(false),
            last_attach_colors: Mutex::new(None),
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
            let live_colors = TerminalColors::from_pty_output(&term, colors);
            let colors = pty.terminal_colors_locked(&mut term, colors);
            pty.attach_colors_pending.store(false, Ordering::Release);
            pty.attach_colors_force_pending.store(false, Ordering::Release);
            *pty.last_attach_colors.lock().unwrap() = Some(Box::new(live_colors));
            pty.broadcast_attach_frame(AttachFrame::ColorsChanged(Arc::new(colors)));
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
            Surface::Pty(pty) => pty.resize(cols, rows),
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
            Surface::Pty(pty) => match pty.resize(cols, rows) {
                Ok(accepted) => {
                    report(accepted.then_some(0));
                    Ok(accepted.then_some(0))
                }
                Err(error) => {
                    report(None);
                    Err(error)
                }
            },
            Surface::Browser(browser) => browser.resize_reporting_acceptance(cols, rows, report),
        }
    }

    pub(crate) fn resize_reporting_completion(
        &self,
        cols: u16,
        rows: u16,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
        completion: Option<BrowserResizeWaiter>,
    ) -> anyhow::Result<Option<u64>> {
        match self {
            Surface::Pty(pty) => match pty.resize(cols, rows) {
                Ok(accepted) => {
                    report(accepted.then_some(0));
                    if let Some(completion) = completion {
                        let _ = completion.send(Ok(()));
                    }
                    Ok(accepted.then_some(0))
                }
                Err(error) => {
                    report(None);
                    if let Some(completion) = completion {
                        let _ = completion.send(Err(error.to_string().into()));
                    }
                    Err(error)
                }
            },
            Surface::Browser(browser) => {
                browser.resize_reporting_completion(cols, rows, report, completion)
            }
        }
    }

    pub fn resize_needed(&self, cols: u16, rows: u16) -> bool {
        let desired = (cols.max(1), rows.max(1));
        match self {
            Surface::Pty(pty) => {
                let geometry = *pty.geometry.lock().unwrap();
                (geometry.cols, geometry.rows) != desired
            }
            Surface::Browser(browser) => browser.resize_needed(desired.0, desired.1),
        }
    }

    pub(crate) fn pending_resize_completion(
        &self,
        cols: u16,
        rows: u16,
    ) -> anyhow::Result<Option<PendingBrowserResize>> {
        match self {
            Surface::Pty(_) => Ok(None),
            Surface::Browser(browser) => browser.pending_resize_completion(cols, rows),
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
        match self {
            Surface::Pty(pty) => match pty.set_cell_pixel_size(width_px, height_px) {
                Ok(changed) => {
                    report(changed.then_some(0));
                    Ok(changed.then_some(0))
                }
                Err(error) => {
                    report(None);
                    Err(error)
                }
            },
            Surface::Browser(browser) => {
                browser.set_cell_pixel_size_reporting(width_px, height_px, report)
            }
        }
    }

    pub fn size(&self) -> (u16, u16) {
        match self {
            Surface::Pty(pty) => {
                let geometry = *pty.geometry.lock().unwrap();
                (geometry.cols, geometry.rows)
            }
            Surface::Browser(browser) => browser.size(),
        }
    }

    #[cfg(test)]
    pub(crate) fn fail_next_test_master_resize(&self) {
        self.as_pty()
            .and_then(|pty| pty.test_master_control.as_ref())
            .expect("test PTY surface")
            .fail_next_resize
            .store(true, Ordering::Release);
    }

    #[cfg(test)]
    pub(crate) fn test_master_size(&self) -> PtySize {
        self.as_pty().expect("test PTY surface").master.lock().unwrap().get_size().unwrap()
    }

    #[cfg(test)]
    pub(crate) fn test_cell_pixel_size(&self) -> (u16, u16) {
        let geometry = *self.as_pty().expect("test PTY surface").geometry.lock().unwrap();
        (geometry.cell_width, geometry.cell_height)
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
        #[cfg(test)]
        pty.vt_replay_builds.fetch_add(1, Ordering::AcqRel);
        let replay = term.vt_replay_bounded(VT_REPLAY_MAX_BYTES)?;
        let (cols, rows) = (term.cols(), term.rows());
        let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let colors = pty.terminal_colors_locked(&mut term, defaults);
        let mut taps = pty.taps.lock().unwrap();
        if taps.is_empty() {
            *pty.last_attach_colors.lock().unwrap() =
                Some(Box::new(TerminalColors::from_pty_output(&term, defaults)));
        }
        taps.push(AttachTap {
            sender: tx,
            lifecycle: lifecycle.clone(),
            queued_bytes: queued_bytes.clone(),
            max_queued_bytes: ATTACH_STREAM_MAX_BYTES,
        });
        Ok(AttachStream {
            cols,
            rows,
            replay: replay.bytes,
            kitty_image_aliases: replay.kitty_image_aliases,
            colors,
            stream: AttachFrameReceiver {
                receiver: rx,
                queued_bytes,
                lifecycle: lifecycle.clone(),
            },
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
        let initial_graphics = term.kitty_graphics_snapshot()?;
        let (tap, stream) = RenderTap::pair();
        let initial = {
            let mut render = pty.render.lock().unwrap();
            let shared = render.latest.clone().ok_or(ghostty_vt::Error::NoValue)?;
            let mut initial = (*shared).clone();
            initial.frame.kitty_graphics = initial_graphics;
            render.taps.push(tap);
            Arc::new(initial)
        };
        Ok(RenderAttachStream { initial, stream })
    }

    pub fn kill(&self) {
        match self {
            Surface::Pty(pty) => {
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

#[cfg(test)]
struct TestMasterPty {
    size: Mutex<PtySize>,
    control: Arc<TestMasterPtyControl>,
}

#[cfg(test)]
#[derive(Default)]
struct TestMasterPtyControl {
    fail_next_resize: AtomicBool,
}

#[cfg(test)]
impl MasterPty for TestMasterPty {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        if self.control.fail_next_resize.swap(false, Ordering::AcqRel) {
            anyhow::bail!("injected PTY master resize failure");
        }
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
    fn tty_name(&self) -> Option<std::path::PathBuf> {
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
    #[cfg(test)]
    fn run_geometry_test_hook(&self, step: PtyGeometryTestStep) {
        let hook = self.geometry_test_hook.lock().unwrap().clone();
        if let Some(hook) = hook {
            hook(step);
        }
    }

    /// Snapshot colors from the terminal and the owning shared render state.
    /// Updating that state keeps Ghostty damage owned by the renderer without
    /// inventing a generation, building a viewport, or notifying subscribers.
    fn terminal_colors_locked(
        &self,
        term: &mut Terminal,
        defaults: DefaultColors,
    ) -> TerminalColors {
        let cursor_visual = {
            let mut render = self.render.lock().unwrap();
            let _ = render.state.update(term);
            render.state.cursor_visual().ok()
        };
        TerminalColors::from_terminal(term, defaults, cursor_visual)
    }

    fn broadcast_attach_output(&self, bytes: &[u8]) -> bool {
        let mut taps = self.taps.lock().unwrap();
        if taps.is_empty() {
            return false;
        }
        let frame = AttachFrame::Output(bytes.to_vec());
        taps.retain(|tap| tap.try_send(frame.clone()));
        !taps.is_empty()
    }

    fn broadcast_attach_frame(&self, frame: AttachFrame) {
        self.taps.lock().unwrap().retain(|tap| tap.try_send(frame.clone()));
    }

    /// Emit at most one latest effective palette snapshot per frame cadence.
    /// The caller holds `term`, so attach registration cannot interleave with
    /// the snapshot or miss a state transition.
    fn flush_attach_colors_locked(&self, term: &Terminal, defaults: DefaultColors) -> bool {
        if !self.attach_colors_pending.swap(false, Ordering::AcqRel) {
            return false;
        }
        let force = self.attach_colors_force_pending.swap(false, Ordering::AcqRel);
        {
            let mut taps = self.taps.lock().unwrap();
            taps.retain(|tap| !tap.lifecycle.is_canceled());
            if taps.is_empty() {
                return false;
            }
        }

        let colors = TerminalColors::from_pty_output(term, defaults);
        let mut last = self.last_attach_colors.lock().unwrap();
        if !force && last.as_deref() == Some(&colors) {
            return false;
        }
        *last = Some(Box::new(colors));
        drop(last);
        self.broadcast_attach_frame(AttachFrame::ColorsChanged(Arc::new(colors)));
        true
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
                render.taps.retain(|tap| tap.send(RenderAttachFrame::Frame(frame.clone())));
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
    fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        #[cfg(test)]
        self.run_geometry_test_hook(PtyGeometryTestStep::ResizeStarted);
        let (cols, rows) = (cols.max(1), rows.max(1));
        let mut geometry = self.geometry.lock().unwrap();
        let next = PtyGeometry { cols, rows, ..*geometry };
        self.commit_geometry(&mut geometry, next, true)
    }

    fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<bool> {
        #[cfg(test)]
        self.run_geometry_test_hook(PtyGeometryTestStep::CellPixelStarted);
        let mut geometry = self.geometry.lock().unwrap();
        let next =
            PtyGeometry { cell_width: width_px.max(1), cell_height: height_px.max(1), ..*geometry };
        self.commit_geometry(&mut geometry, next, false)
    }

    /// Commit the PTY ioctl, Ghostty geometry, and the published logical tuple
    /// while holding the single geometry transaction lock.
    fn commit_geometry(
        &self,
        geometry: &mut PtyGeometry,
        next: PtyGeometry,
        refresh_attach_colors: bool,
    ) -> anyhow::Result<bool> {
        if *geometry == next {
            return Ok(false);
        }
        let previous = *geometry;
        // Hold the terminal lock while resizing and while sending the attach
        // marker, so mirrors observe bytes and geometry in server order.
        let mut term = self.term.lock().unwrap();
        let master = self.master.lock().unwrap();
        master.resize(next.pty_size()).map_err(|error| {
            anyhow::anyhow!(
                "could not resize PTY master to {}x{} at {}x{} px per cell: {error}",
                next.cols,
                next.rows,
                next.cell_width,
                next.cell_height
            )
        })?;
        if let Err(error) = term.resize(
            next.cols,
            next.rows,
            u32::from(next.cell_width),
            u32::from(next.cell_height),
        ) {
            let rollback = master.resize(previous.pty_size());
            return match rollback {
                Ok(()) => Err(anyhow::anyhow!(
                    "could not resize Ghostty terminal to {}x{} at {}x{} px per cell: {error}",
                    next.cols,
                    next.rows,
                    next.cell_width,
                    next.cell_height
                )),
                Err(rollback_error) => Err(anyhow::anyhow!(
                    "could not resize Ghostty terminal to {}x{} at {}x{} px per cell: {error}; \
                     PTY master rollback also failed: {rollback_error}",
                    next.cols,
                    next.rows,
                    next.cell_width,
                    next.cell_height
                )),
            };
        }
        drop(master);
        *geometry = next;
        #[cfg(test)]
        self.run_geometry_test_hook(if refresh_attach_colors {
            PtyGeometryTestStep::ResizeCommitBoundary
        } else {
            PtyGeometryTestStep::CellPixelCommitBoundary
        });
        let has_attach_taps = {
            let mut taps = self.taps.lock().unwrap();
            taps.retain(|tap| !tap.lifecycle.is_canceled());
            !taps.is_empty()
        };
        let replay = if has_attach_taps {
            #[cfg(test)]
            self.vt_replay_builds.fetch_add(1, Ordering::AcqRel);
            Some(term.vt_replay_bounded(VT_REPLAY_MAX_BYTES).unwrap_or_default())
        } else {
            None
        };
        let generation = self.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let _ = self.build_frame_locked(&mut term, generation, false);
        if let Some(replay) = replay {
            let defaults = self.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
            let colors = Box::new(self.terminal_colors_locked(&mut term, defaults));
            if refresh_attach_colors {
                let live_colors = TerminalColors::from_pty_output(&term, defaults);
                self.attach_colors_pending.store(false, Ordering::Release);
                self.attach_colors_force_pending.store(false, Ordering::Release);
                *self.last_attach_colors.lock().unwrap() = Some(Box::new(live_colors));
            }
            self.broadcast_attach_frame(AttachFrame::Resized {
                cols: next.cols,
                rows: next.rows,
                replay: replay.bytes,
                kitty_image_aliases: replay.kitty_image_aliases,
                colors,
            });
        }
        Ok(true)
    }
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PtyGeometryTestStep {
    ResizeStarted,
    ResizeCommitBoundary,
    CellPixelStarted,
    CellPixelCommitBoundary,
}

fn total_pixels(cells: u16, cell_pixels: u16) -> u16 {
    cells.saturating_mul(cell_pixels.max(1))
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
            let colors_pending = pty.attach_colors_pending.load(Ordering::Acquire);
            if colors_pending {
                let defaults =
                    pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
                let _ = pty.flush_attach_colors_locked(&term, defaults);
            }
            if pty.build_frame_locked(&mut term, generation, true).unwrap_or(false)
                || colors_pending
            {
                last_frame = Instant::now();
            }
        }
    })?;
    Ok(())
}

fn broadcast_render_scroll_locked(pty: &PtySurface, position: (u64, bool)) {
    let (offset, at_bottom) = position;
    let mut render = pty.render.lock().unwrap();
    render.taps.retain(|tap| tap.send(RenderAttachFrame::ScrollChanged { offset, at_bottom }));
}

fn terminal_scroll_position(term: &Terminal) -> (u64, bool) {
    match term.scrollbar() {
        Some(scrollbar) => (scrollbar.offset, !scrollbar.scrolled_back()),
        None => (0, true),
    }
}

#[cfg(test)]
mod tests {
    use base64::Engine as _;

    use super::*;

    #[test]
    fn attach_colors_preserve_same_valued_authored_palette_override() {
        let color = Rgb { r: 0x44, g: 0x55, b: 0x66 };
        let mut defaults = DefaultColors::default();
        defaults.palette[4] = Some(color);
        let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
        term.set_default_palette(&defaults.palette);

        term.vt_write(b"\x1b]4;4;#445566\x07");
        let colors = TerminalColors::from_terminal(&term, defaults, None);
        assert_eq!(colors.palette[4], Some(color));
        assert!(
            colors
                .palette
                .iter()
                .enumerate()
                .all(|(index, entry)| { index == 4 || entry.is_none() })
        );

        term.vt_write(b"\x1b]104;4\x07");
        let colors = TerminalColors::from_terminal(&term, defaults, None);
        assert_eq!(colors.palette[4], None);
    }

    #[test]
    fn attach_colors_do_not_consume_shared_render_damage() {
        let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
        let mut shared_render = RenderState::new().unwrap();
        shared_render.update(&mut term).unwrap();
        shared_render.set_clean();

        term.vt_write(b"changed");
        let _ = TerminalColors::from_terminal(&term, DefaultColors::default(), None);

        shared_render.update(&mut term).unwrap();
        assert_ne!(shared_render.dirty(), ghostty_vt::Dirty::Clean);
    }

    #[test]
    fn pty_output_colors_do_not_include_cursor_metadata() {
        let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        let defaults = DefaultColors {
            cursor_style: Some(CursorShape::Bar),
            cursor_blink: Some(true),
            ..DefaultColors::default()
        };

        term.vt_write(b"\x1b]4;4;#445566\x07");
        let colors = TerminalColors::from_pty_output(&term, defaults);

        assert_eq!(colors.palette[4], Some(Rgb { r: 0x44, g: 0x55, b: 0x66 }));
        assert_eq!(colors.cursor_style, None);
        assert_eq!(colors.cursor_blink, None);
    }

    #[test]
    fn live_palette_snapshots_skip_absent_taps_and_coalesce_effective_state() {
        let mux = Mux::new_for_test("palette-coalescing", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();

        {
            let mut term = pty.term.lock().unwrap();
            term.vt_write(b"\x1b]4;1;#112233\x07");
            pty.attach_colors_pending.store(true, Ordering::Release);
            assert!(!pty.flush_attach_colors_locked(&term, mux.default_colors()));
            assert!(pty.last_attach_colors.lock().unwrap().is_none());
        }

        let attach = surface.attach_stream().unwrap();
        let attach_two = surface.attach_stream().unwrap();
        {
            let mut term = pty.term.lock().unwrap();
            term.vt_write(b"\x1b]4;1;#223344\x07\x1b]4;1;#334455\x07");
            pty.attach_colors_pending.store(true, Ordering::Release);
            assert!(pty.flush_attach_colors_locked(&term, mux.default_colors()));
        }
        let AttachFrame::ColorsChanged(colors) =
            attach.stream.recv_timeout(Duration::from_secs(1)).unwrap()
        else {
            panic!("expected coalesced colors update");
        };
        let AttachFrame::ColorsChanged(colors_two) =
            attach_two.stream.recv_timeout(Duration::from_secs(1)).unwrap()
        else {
            panic!("expected coalesced colors update for second tap");
        };
        assert!(Arc::ptr_eq(&colors, &colors_two));
        assert_eq!(colors.palette[1], Some(Rgb { r: 0x33, g: 0x44, b: 0x55 }));
        assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Empty)));
        assert!(matches!(attach_two.stream.try_recv(), Err(TryRecvError::Empty)));

        {
            let mut term = pty.term.lock().unwrap();
            term.vt_write(b"\x1b]4;1;#334455\x07");
            pty.attach_colors_pending.store(true, Ordering::Release);
            assert!(!pty.flush_attach_colors_locked(&term, mux.default_colors()));
        }
        assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Empty)));
        assert!(matches!(attach_two.stream.try_recv(), Err(TryRecvError::Empty)));

        {
            let term = pty.term.lock().unwrap();
            pty.attach_colors_pending.store(true, Ordering::Release);
            pty.attach_colors_force_pending.store(true, Ordering::Release);
            assert!(pty.flush_attach_colors_locked(&term, mux.default_colors()));
        }
        for stream in [&attach.stream, &attach_two.stream] {
            assert!(matches!(
                stream.recv_timeout(Duration::from_secs(1)),
                Ok(AttachFrame::ColorsChanged(_))
            ));
        }

        {
            let mut term = pty.term.lock().unwrap();
            term.vt_write(b"\x1b]4;1;#445566\x07");
            pty.attach_colors_pending.store(true, Ordering::Release);
        }
        let attach_three = surface.attach_stream().unwrap();
        {
            let term = pty.term.lock().unwrap();
            assert!(pty.flush_attach_colors_locked(&term, mux.default_colors()));
        }
        for stream in [&attach.stream, &attach_two.stream, &attach_three.stream] {
            let AttachFrame::ColorsChanged(colors) =
                stream.recv_timeout(Duration::from_secs(1)).unwrap()
            else {
                panic!("an existing tap missed a palette update during another attach");
            };
            assert_eq!(colors.palette[1], Some(Rgb { r: 0x44, g: 0x55, b: 0x66 }));
        }
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
    fn stalled_render_tap_retains_only_latest_frame_and_scroll_state_in_order() {
        let mux = Mux::new_for_test("render-tap-latest", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();
        let attach = surface.attach_render_stream().unwrap();

        {
            let mut term = pty.term.lock().unwrap();
            term.vt_write(b"a");
            pty.build_frame_locked(&mut term, 2, false).unwrap();
            broadcast_render_scroll_locked(pty, (4, false));
            term.vt_write(b"b");
            pty.build_frame_locked(&mut term, 3, false).unwrap();
            broadcast_render_scroll_locked(pty, (9, true));
            term.vt_write(b"c");
            pty.build_frame_locked(&mut term, 4, false).unwrap();
        }

        let mut pending = Vec::new();
        while let Ok(frame) = attach.stream.try_recv() {
            pending.push(frame);
        }
        assert_eq!(
            pending.len(),
            2,
            "a stalled render consumer retained more than one frame plus final scroll state"
        );
        assert!(matches!(
            pending[0],
            RenderAttachFrame::ScrollChanged { offset: 9, at_bottom: true }
        ));
        let RenderAttachFrame::Frame(frame) = &pending[1] else {
            panic!("final render frame must follow the final preceding scroll state");
        };
        let latest = pty.render.lock().unwrap().latest.clone().unwrap();
        assert!(Arc::ptr_eq(frame, &latest));

        {
            let mut term = pty.term.lock().unwrap();
            term.vt_write(b"d");
            pty.build_frame_locked(&mut term, 5, false).unwrap();
            broadcast_render_scroll_locked(pty, (11, false));
        }
        let first = attach.stream.try_recv().unwrap();
        let second = attach.stream.try_recv().unwrap();
        assert!(matches!(first, RenderAttachFrame::Frame(_)));
        assert!(matches!(
            second,
            RenderAttachFrame::ScrollChanged { offset: 11, at_bottom: false }
        ));
        assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn geometry_updates_skip_vt_replay_without_byte_attach_subscribers() {
        let mux = Mux::new_for_test("resize-without-byte-attach", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();
        let render = surface.attach_render_stream().unwrap();

        surface.resize(100, 30).unwrap();
        surface.set_cell_pixel_size(9, 18).unwrap();

        assert_eq!(
            pty.vt_replay_builds.load(Ordering::Acquire),
            0,
            "render-only geometry updates must not construct byte-attach replay"
        );
        assert!(matches!(render.stream.try_recv(), Ok(RenderAttachFrame::Frame(_))));

        let byte_attach = surface.attach_stream().unwrap();
        pty.vt_replay_builds.store(0, Ordering::Release);
        surface.resize(101, 31).unwrap();
        assert_eq!(pty.vt_replay_builds.load(Ordering::Acquire), 1);

        drop(byte_attach);
        pty.vt_replay_builds.store(0, Ordering::Release);
        surface.resize(102, 31).unwrap();
        assert_eq!(
            pty.vt_replay_builds.load(Ordering::Acquire),
            0,
            "dropping the final byte attach must suppress the next resize replay"
        );
    }

    #[test]
    fn resize_replay_preserves_a_valid_large_inflight_kitty_upload() {
        const IMAGE_WIDTH: usize = 2_048;
        const IMAGE_HEIGHT: usize = 1_024;
        const IMAGE_ID: u32 = 196;

        let pixels = vec![0xff; IMAGE_WIDTH * IMAGE_HEIGHT * 3];
        let payload = base64::engine::general_purpose::STANDARD.encode(&pixels);
        let final_payload = payload.split_at(payload.len() - 4);
        let first_chunk = format!(
            "\x1b_Ga=t,t=d,f=24,i={IMAGE_ID},s={IMAGE_WIDTH},v={IMAGE_HEIGHT},m=1,q=2;{}\x1b\\",
            final_payload.0
        )
        .into_bytes();
        let final_chunk = format!("\x1b_Gm=0,q=2;{}\x1b\\", final_payload.1).into_bytes();
        assert!(
            first_chunk.len() > VT_REPLAY_MAX_BYTES,
            "fixture must exceed the old {VT_REPLAY_MAX_BYTES}-byte resize replay budget"
        );

        let mux = Mux::new_for_test("large-inflight-resize", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attach = surface.attach_stream().unwrap();
        let pty = surface.as_pty().unwrap();
        {
            let mut terminal = pty.term.lock().unwrap();
            terminal.vt_write(&first_chunk);
            assert!(terminal.kitty_graphics_snapshot().unwrap().image(IMAGE_ID).is_none());
        }

        surface.resize(81, 24).unwrap();
        let AttachFrame::Resized { cols, rows, replay, kitty_image_aliases, .. } =
            attach.stream.recv_timeout(Duration::from_secs(2)).unwrap()
        else {
            panic!("resize must publish replacement terminal state");
        };
        assert!(
            replay.len() >= first_chunk.len(),
            "{}-byte resize replay omitted the {}-byte in-flight prefix",
            replay.len(),
            first_chunk.len()
        );

        let mut mirror = Terminal::new(cols, rows, 10_000, Callbacks::default()).unwrap();
        mirror.resize(cols, rows, 8, 16).unwrap();
        mirror.vt_write(&replay);
        mirror.restore_kitty_image_aliases(&kitty_image_aliases).unwrap();
        mirror.vt_write(&final_chunk);

        assert_eq!(
            mirror
                .kitty_graphics_snapshot()
                .unwrap()
                .image(IMAGE_ID)
                .expect("resize replay must let a fresh terminal accept the final upload chunk")
                .data
                .len(),
            pixels.len()
        );
    }

    #[test]
    fn concurrent_pty_resize_and_cell_pixel_update_publish_one_geometry_transaction_at_a_time() {
        let mux = Mux::new_for_test("pty-geometry-transaction", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();
        let (resize_entered_tx, resize_entered_rx) = std::sync::mpsc::channel();
        let (release_resize_tx, release_resize_rx) = std::sync::mpsc::channel();
        let (cell_started_tx, cell_started_rx) = std::sync::mpsc::channel();
        let release_resize_rx = Arc::new(Mutex::new(release_resize_rx));
        *pty.geometry_test_hook.lock().unwrap() = Some(Arc::new({
            let release_resize_rx = release_resize_rx.clone();
            move |step| match step {
                PtyGeometryTestStep::ResizeCommitBoundary => {
                    resize_entered_tx.send(()).unwrap();
                    release_resize_rx.lock().unwrap().recv().unwrap();
                }
                PtyGeometryTestStep::CellPixelStarted => {
                    cell_started_tx.send(()).unwrap();
                }
                _ => {}
            }
        }));

        let resizing_surface = surface.clone();
        let resizing = std::thread::spawn(move || resizing_surface.resize(100, 30));
        resize_entered_rx.recv().unwrap();

        let updating_surface = surface.clone();
        let (cell_done_tx, cell_done_rx) = std::sync::mpsc::channel();
        let updating = std::thread::spawn(move || {
            let result = updating_surface.set_cell_pixel_size(9, 18);
            cell_done_tx.send(result).unwrap();
        });
        cell_started_rx.recv().unwrap();
        let cell_completed_while_resize_was_uncommitted =
            cell_done_rx.recv_timeout(Duration::from_millis(100)).is_ok();

        release_resize_tx.send(()).unwrap();
        resizing.join().unwrap().unwrap();
        updating.join().unwrap();

        assert!(
            !cell_completed_while_resize_was_uncommitted,
            "cell pixels published while the resize transaction was paused before its backend commit"
        );
        assert_eq!(surface.size(), (100, 30));
        let master = surface.test_master_size();
        assert_eq!(
            (master.cols, master.rows, master.pixel_width, master.pixel_height),
            (100, 30, 900, 540)
        );
    }

    #[test]
    fn failed_pty_master_resize_commits_nothing_and_the_same_request_retries() {
        let mux = Mux::new_for_test("pty-resize-failure", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        surface.fail_next_test_master_resize();

        let failed = surface.resize(100, 30);

        assert!(failed.is_err(), "PTY master resize failure must reach the caller");
        assert_eq!(surface.size(), (80, 24));
        {
            let term = surface.as_pty().unwrap().term.lock().unwrap();
            assert_eq!((term.cols(), term.rows()), (80, 24));
        }
        let master = surface.test_master_size();
        assert_eq!(
            (master.cols, master.rows, master.pixel_width, master.pixel_height),
            (80, 24, 640, 384)
        );

        assert_eq!(surface.resize(100, 30).unwrap(), true);
        assert_eq!(surface.size(), (100, 30));
        let master = surface.test_master_size();
        assert_eq!(
            (master.cols, master.rows, master.pixel_width, master.pixel_height),
            (100, 30, 800, 480)
        );
    }
}
