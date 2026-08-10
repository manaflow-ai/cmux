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
use crate::remote_tmux_producer::ExternalTerminalProvenance;
use crate::semantic_scene::{
    SemanticSceneAttachError, SemanticSceneAttachment, SemanticSceneAttachmentOptions,
    SemanticSceneHub, SemanticSceneTerminalIdentity,
};
use crate::{Mux, MuxEvent, SurfaceId};

pub use crate::browser::{
    BrowserAttachState, BrowserFrame, BrowserFrameStream, BrowserFrameUpdate, BrowserSource,
    BrowserStatus,
};
use crate::browser::{
    BrowserMouseDispatch, BrowserPointerOwner, BrowserResizeWaiter, BrowserSurface,
    PendingBrowserResize,
};
#[cfg(all(unix, test))]
use crate::terminal_host_protocol::PROTOCOL_VERSION;
#[cfg(unix)]
use crate::terminal_host_protocol::{
    CLEAR_HISTORY_ACK_OK, FLAG_COLORS_FOLLOW, Frame, MessageKind, decode_terminal_exit,
};
use cmux_tui_cdp::BrowserMode;

/// Result of encoding terminal mouse input against a previously observed
/// pointer snapshot without blocking on terminal parsing.
#[derive(Debug)]
pub enum GuardedMouseEncode {
    /// The guards still matched and the encoder returned this result.
    Encoded(ghostty_vt::Result<()>),
    /// The terminal's mouse protocol or reporting mode changed.
    SemanticsChanged,
    /// Terminal output changed the content generation used by the route.
    ContentChanged,
    /// Terminal parsing currently owns a required lock. The caller may retry
    /// after the next surface update without changing the pointer route.
    Contended,
}

/// Nonblocking probe for the terminal mouse protocol and reporting mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PointerSemanticProbe {
    /// The semantic snapshot was read consistently.
    Ready(TerminalPointerSemanticSnapshot),
    /// Terminal parsing currently owns the semantic state lock.
    Contended,
}

/// Terminal pointer state captured from one consistent rendered generation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerminalPointerSnapshot {
    /// Mouse protocol and reporting mode used to encode pointer input.
    pub semantics: TerminalPointerSemanticSnapshot,
    /// Terminal content generation that produced the rendered hit route.
    pub content_generation: u64,
}

/// Nonblocking probe for a complete terminal pointer snapshot.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PointerSnapshotProbe {
    /// Semantic and content-generation state were read consistently.
    Ready(TerminalPointerSnapshot),
    /// Terminal parsing currently owns a required state lock.
    Contended,
}

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

/// Install Ghostty configuration cursor defaults without collapsing the
/// nullable blink setting in [`DefaultColors`]. Ghostty starts an unspecified
/// cursor blinking, while still allowing DEC mode 12 to change the live mode;
/// the low-level VT engine needs that initial visual supplied explicitly.
/// Explicit `true` and `false` values pass through unchanged.
pub(crate) fn replace_ghostty_cursor_defaults(term: &mut Terminal, colors: DefaultColors) {
    term.replace_default_cursor(colors.cursor_style, Some(colors.cursor_blink.unwrap_or(true)));
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
    /// Palette entries actively authored by the PTY with OSC 4. Unauthored
    /// entries stay `None` so an attached renderer can preserve its own
    /// configured theme.
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
    fn from_terminal(term: &Terminal, defaults: DefaultColors) -> Self {
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

    /// Snapshot a live palette update without touching the shared renderer.
    /// Palette OSC commands leave cursor state authoritative in the attached
    /// frontend's existing xterm state.
    fn from_pty_output(term: &Terminal, defaults: DefaultColors) -> Self {
        let mut colors = Self::from_terminal(term, defaults);
        colors.cursor_style = None;
        colors.cursor_blink = None;
        colors
    }
}

/// Everything an attaching frontend needs to adopt a PTY surface: its
/// size, a VT replay of the current state, and a live stream of every pty
/// byte applied after the replay snapshot.
pub struct AttachStream {
    /// Stable canonical identity. A replacement runtime for this surface keeps
    /// this UUID but receives a different `runtime_epoch`.
    pub surface_uuid: crate::SurfaceUuid,
    /// Canonical terminal runtime identity shared with semantic scene streams.
    pub runtime_epoch: u64,
    /// Reset generation for this byte-stream compatibility lifetime.
    pub generation: u64,
    /// Monotonic byte cursor at the replay snapshot boundary.
    pub sequence: u64,
    pub cols: u16,
    pub rows: u16,
    pub replay: Arc<[u8]>,
    pub kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
    pub kitty_state: KittyReplayState,
    pub colors: TerminalColors,
    pub stream: AttachFrameReceiver,
    pub(crate) lifecycle: AttachLifecycle,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachFrame {
    Output {
        surface_uuid: crate::SurfaceUuid,
        runtime_epoch: u64,
        generation: u64,
        start_sequence: u64,
        next_sequence: u64,
        data: Vec<u8>,
    },
    Resized {
        surface_uuid: crate::SurfaceUuid,
        runtime_epoch: u64,
        generation: u64,
        sequence: u64,
        cols: u16,
        rows: u16,
        replay: Vec<u8>,
    },
    ColorsChanged {
        surface_uuid: crate::SurfaceUuid,
        runtime_epoch: u64,
        generation: u64,
        sequence: u64,
        colors: TerminalColors,
    },
}

const ATTACH_STREAM_CAPACITY: usize = 256;
const ATTACH_STREAM_MAX_BYTES: usize = 16 * 1024 * 1024;
// Preserve every valid upload prefix plus enough recent text while fitting
// both the raw attach queue and its 32 MiB base64-encoded transport.
const VT_REPLAY_TEXT_HEADROOM_BYTES: usize = 2 * 1024 * 1024;
pub(crate) const VT_REPLAY_MAX_BYTES: usize =
    ghostty_vt::KITTY_INFLIGHT_REPLAY_MAX_BYTES + VT_REPLAY_TEXT_HEADROOM_BYTES;
const VT_REPLAY_FRAME_METADATA_HEADROOM_BYTES: usize = 64 * 1024;
const VT_REPLAY_ENCODED_TRANSPORT_MAX_BYTES: usize = 32 * 1024 * 1024;
const _: () = assert!(
    VT_REPLAY_MAX_BYTES + VT_REPLAY_FRAME_METADATA_HEADROOM_BYTES <= ATTACH_STREAM_MAX_BYTES
);
const _: () = assert!(VT_REPLAY_MAX_BYTES.div_ceil(3) * 4 < VT_REPLAY_ENCODED_TRANSPORT_MAX_BYTES);

pub struct AttachFrameReceiver {
    state: Arc<AttachTapState>,
    lifecycle: AttachLifecycle,
}

impl AttachFrameReceiver {
    fn pop(queue: &mut AttachTapQueue) -> Option<AttachFrame> {
        let frame = queue.frames.pop_front()?;
        queue.retained_bytes = queue.retained_bytes.saturating_sub(frame.retained_bytes());
        Some(frame)
    }

    pub fn recv(&self) -> Result<AttachFrame, RecvError> {
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if let Some(frame) = Self::pop(&mut queue) {
                return Ok(frame);
            }
            if !queue.sender_alive {
                return Err(RecvError);
            }
            queue = self.state.ready.wait(queue).unwrap();
        }
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<AttachFrame, RecvTimeoutError> {
        let started = Instant::now();
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if let Some(frame) = Self::pop(&mut queue) {
                return Ok(frame);
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            let Some(remaining) = timeout.checked_sub(started.elapsed()) else {
                return Err(RecvTimeoutError::Timeout);
            };
            let (next, result) = self.state.ready.wait_timeout(queue, remaining).unwrap();
            queue = next;
            if result.timed_out() && queue.frames.is_empty() {
                return Err(RecvTimeoutError::Timeout);
            }
        }
    }

    pub fn try_recv(&self) -> Result<AttachFrame, TryRecvError> {
        let mut queue = self.state.queue.lock().unwrap();
        if let Some(frame) = Self::pop(&mut queue) {
            Ok(frame)
        } else if queue.sender_alive {
            Err(TryRecvError::Empty)
        } else {
            Err(TryRecvError::Disconnected)
        }
    }
}

impl Drop for AttachFrameReceiver {
    fn drop(&mut self) {
        let mut queue = self.state.queue.lock().unwrap();
        queue.receiver_alive = false;
        queue.frames.clear();
        queue.retained_bytes = 0;
        drop(queue);
        self.lifecycle.cancel();
        self.state.ready.notify_all();
    }
}

impl AttachFrame {
    fn merge_adjacent_output(
        &mut self,
        next: AttachFrame,
        max_retained_bytes: usize,
    ) -> AttachFrameMerge {
        let mut next = match next {
            AttachFrame::Output(next) => next,
            other => return AttachFrameMerge::Unmerged(other),
        };
        let AttachFrame::Output(pending) = self else {
            return AttachFrameMerge::Unmerged(AttachFrame::Output(next));
        };
        let Some(max_capacity) = max_retained_bytes.checked_sub(size_of::<Self>()) else {
            return AttachFrameMerge::Overflow;
        };
        let Some(required) = pending.len().checked_add(next.len()) else {
            return AttachFrameMerge::Overflow;
        };
        if required > max_capacity {
            return AttachFrameMerge::Overflow;
        }
        if required > pending.capacity() {
            let desired = pending.capacity().saturating_mul(2).max(required).min(max_capacity);
            let mut merged = Vec::new();
            if merged.try_reserve_exact(desired).is_err() || merged.capacity() > max_capacity {
                return AttachFrameMerge::Overflow;
            }
            merged.extend_from_slice(pending);
            merged.append(&mut next);
            *pending = merged;
        } else {
            pending.append(&mut next);
        }
        AttachFrameMerge::Merged
    }

    fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + match self {
                Self::Output { data, .. } => data.capacity(),
                Self::Resized { replay, .. } => replay.capacity(),
                Self::ColorsChanged { .. } => 0,
            }
    }
}

enum AttachFrameMerge {
    Merged,
    Unmerged(AttachFrame),
    Overflow,
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
    state: Arc<AttachTapState>,
    lifecycle: AttachLifecycle,
    queued_bytes: Arc<AtomicUsize>,
    max_queued_bytes: usize,
    replay_max_bytes: usize,
}

impl AttachTap {
    fn pair(
        lifecycle: AttachLifecycle,
        max_frames: usize,
        max_retained_bytes: usize,
    ) -> (Self, AttachFrameReceiver) {
        let state = Arc::new(AttachTapState {
            queue: Mutex::new(AttachTapQueue {
                frames: VecDeque::new(),
                retained_bytes: 0,
                max_frames,
                max_retained_bytes,
                sender_alive: true,
                receiver_alive: true,
            }),
            ready: Condvar::new(),
        });
        (
            Self { state: state.clone(), lifecycle: lifecycle.clone() },
            AttachFrameReceiver { state, lifecycle },
        )
    }

    fn try_send(&self, mut frame: AttachFrame) -> bool {
        if self.lifecycle.is_canceled() {
            return false;
        }
        let mut queue = self.state.queue.lock().unwrap();
        if !queue.receiver_alive {
            self.lifecycle.cancel();
            return false;
        }
        let queue_retained_bytes = queue.retained_bytes;
        let queue_max_retained_bytes = queue.max_retained_bytes;
        if let Some(pending) = queue.frames.back_mut() {
            let previous_bytes = pending.retained_bytes();
            let max_frame_bytes = queue_max_retained_bytes
                .saturating_sub(queue_retained_bytes.saturating_sub(previous_bytes));
            match pending.merge_adjacent_output(frame, max_frame_bytes) {
                AttachFrameMerge::Merged => {
                    let merged_bytes = pending.retained_bytes();
                    queue.retained_bytes = queue
                        .retained_bytes
                        .saturating_sub(previous_bytes)
                        .saturating_add(merged_bytes);
                    drop(queue);
                    self.state.ready.notify_one();
                    return true;
                }
                AttachFrameMerge::Unmerged(unmerged) => frame = unmerged,
                AttachFrameMerge::Overflow => {
                    drop(queue);
                    self.lifecycle.mark_overflow();
                    return false;
                }
            }
        }
        let frame_bytes = frame.retained_bytes();
        if frame_bytes > queue.max_retained_bytes.saturating_sub(queue.retained_bytes) {
            drop(queue);
            self.lifecycle.mark_overflow();
            return false;
        }
        if queue.frames.len() >= queue.max_frames {
            drop(queue);
            self.lifecycle.mark_overflow();
            return false;
        }
        queue.retained_bytes = queue.retained_bytes.saturating_add(frame_bytes);
        queue.frames.push_back(frame);
        drop(queue);
        self.state.ready.notify_one();
        true
    }
}

impl Drop for AttachTap {
    fn drop(&mut self) {
        self.state.queue.lock().unwrap().sender_alive = false;
        self.state.ready.notify_all();
    }
}

/// One immutable terminal frame plus retained-history metadata captured with it.
#[derive(Debug, Clone)]
pub struct SurfaceRenderFrame {
    pub frame: RenderFrame,
    pub content_generation: u64,
    pub scrollback_rows: u32,
    pub history_epoch: u64,
    pub pointer_semantics: TerminalPointerSemanticSnapshot,
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
    pending_frame: Option<PendingRenderFrame>,
    pending_scroll: Option<(u64, bool)>,
    latest_kind: Option<PendingRenderKind>,
    sender_alive: bool,
    receiver_alive: bool,
}

struct PendingRenderFrame {
    latest: Arc<SurfaceRenderFrame>,
    dirty: Dirty,
    dirty_rows: Vec<u16>,
}

impl PendingRenderFrame {
    fn new(latest: Arc<SurfaceRenderFrame>) -> Self {
        Self { dirty: latest.frame.dirty, dirty_rows: latest.frame.dirty_rows.clone(), latest }
    }

    /// Replace the immutable snapshot while retaining every row damaged since
    /// the tap last drained. Only damage metadata is copied on this hot path.
    fn coalesce(&mut self, latest: Arc<SurfaceRenderFrame>) {
        if self.dirty == Dirty::Full
            || latest.frame.dirty == Dirty::Full
            || self.latest.frame.size != latest.frame.size
        {
            self.dirty = Dirty::Full;
            self.dirty_rows = (0..latest.frame.size.1).collect();
        } else {
            self.dirty_rows.extend(latest.frame.dirty_rows.iter().copied());
            self.dirty_rows.sort_unstable();
            self.dirty_rows.dedup();
            self.dirty =
                if self.dirty_rows.is_empty() { latest.frame.dirty } else { Dirty::Partial };
        }
        self.latest = latest;
    }

    /// Materialize one coalesced frame when the receiver drains. A tap that
    /// keeps up returns the original shared frame without cloning row state.
    fn into_frame(self) -> Arc<SurfaceRenderFrame> {
        if self.dirty == self.latest.frame.dirty && self.dirty_rows == self.latest.frame.dirty_rows
        {
            return self.latest;
        }
        let mut combined = (*self.latest).clone();
        combined.frame.dirty = self.dirty;
        combined.frame.dirty_rows = self.dirty_rows;
        Arc::new(combined)
    }
}

impl RenderTapQueue {
    fn push(&mut self, event: RenderAttachFrame) {
        match event {
            RenderAttachFrame::Frame(frame) => {
                match &mut self.pending_frame {
                    Some(pending) => pending.coalesce(frame),
                    None => self.pending_frame = Some(PendingRenderFrame::new(frame)),
                }
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
                    RenderAttachFrame::Frame(self.pending_frame.take().unwrap().into_frame())
                }
                (true, true, None) => unreachable!("pending render events have an ordering"),
                (true, false, _) => {
                    RenderAttachFrame::Frame(self.pending_frame.take().unwrap().into_frame())
                }
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
    fn pair(render: &Arc<Mutex<RenderHub>>) -> (Self, RenderAttachFrameReceiver) {
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
        (
            Self { state: state.clone() },
            RenderAttachFrameReceiver { state, render: Arc::downgrade(render) },
        )
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
    render: Weak<Mutex<RenderHub>>,
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
        // Frame fan-out holds the hub before this queue. Release the queue
        // before taking the hub so receiver teardown cannot invert that order.
        {
            let mut queue = self.state.queue.lock().unwrap();
            queue.receiver_alive = false;
            queue.pending_frame = None;
            queue.pending_scroll = None;
        }
        if let Some(render) = self.render.upgrade() {
            render.lock().unwrap().taps.retain(|tap| !Arc::ptr_eq(&tap.state, &self.state));
        }
    }
}

/// Initial render snapshot and the ordered live stream registered with it.
pub struct RenderAttachStream {
    pub initial: Arc<SurfaceRenderFrame>,
    pub stream: RenderAttachFrameReceiver,
    _permit: crate::mux::RenderAttachmentPermit,
}

struct RenderHub {
    state: Box<RenderState>,
    built_generation: u64,
    latest: Option<Arc<SurfaceRenderFrame>>,
    initial_graphics: Option<InitialGraphicsSnapshot>,
    taps: Vec<RenderTap>,
}

struct InitialGraphicsSnapshot {
    source: Arc<ghostty_vt::KittyGraphicsSnapshot>,
    snapshot: Arc<ghostty_vt::KittyGraphicsSnapshot>,
}

#[cfg(test)]
type FrameProducerTestHook = Arc<Mutex<Option<Arc<dyn Fn() + Send + Sync>>>>;

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
    pub no_reflow: bool,
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
    no_reflow: AtomicBool,
    scrollback: usize,
    provenance: Option<ExternalTerminalProvenance>,
}

impl ExternalTerminalRuntime {
    fn new(
        no_reflow: bool,
        scrollback: usize,
        provenance: Option<ExternalTerminalProvenance>,
    ) -> Self {
        Self {
            operation: Mutex::new(()),
            state: Mutex::new(ExternalTerminalState {
                requires_reset: true,
                next_output_sequence: 1,
                ..ExternalTerminalState::default()
            }),
            no_reflow: AtomicBool::new(no_reflow),
            scrollback,
            provenance,
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
            .field("no_reflow", &self.no_reflow.load(Ordering::Acquire))
            .field("scrollback", &self.scrollback)
            .field("provenance", &self.provenance)
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
    /// Public tab/content identities. Auxiliary surfaces have no identity.
    pub(crate) resource_identity: Option<TabResourceIdentity>,
    /// User-assigned tab name (rename tab); shared by every surface kind.
    pub(crate) name: Mutex<Option<String>>,
    pub(crate) selection: Mutex<Option<String>>,
}

/// A pane tab runtime.
// Surface values are always stored behind Arc, so boxing one variant would add
// a second allocation and pointer chase without shrinking their owning state.
#[allow(clippy::large_enum_variant)]
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
    fn pty_size(self) -> anyhow::Result<PtySize> {
        let pixel_width = self.cols.checked_mul(self.cell_width.max(1)).ok_or_else(|| {
            anyhow::anyhow!(
                "PTY pixel width exceeds {}: {} columns at {} pixels per cell",
                u16::MAX,
                self.cols,
                self.cell_width.max(1)
            )
        })?;
        let pixel_height = self.rows.checked_mul(self.cell_height.max(1)).ok_or_else(|| {
            anyhow::anyhow!(
                "PTY pixel height exceeds {}: {} rows at {} pixels per cell",
                u16::MAX,
                self.rows,
                self.cell_height.max(1)
            )
        })?;
        Ok(PtySize { rows: self.rows, cols: self.cols, pixel_width, pixel_height })
    }
}

#[cfg(test)]
type PtyGeometryTestHook = Arc<dyn Fn(PtyGeometryTestStep) + Send + Sync>;

#[cfg(test)]
type DeferredCellPixelAckTestHook = Arc<dyn Fn() + Send + Sync>;

pub struct PtySurface {
    pub(crate) meta: SurfaceMeta,
    terminal: Arc<PtyTerminalRuntime>,
    viewport: Mutex<TerminalViewportState>,
}

#[derive(Default)]
struct TerminalViewportState {
    primary: Option<TrackedScreenPoint>,
    alternate: Option<TrackedScreenPoint>,
}

impl TerminalViewportState {
    fn anchor(&self, screen: Screen) -> Option<&TrackedScreenPoint> {
        match screen {
            Screen::Primary => self.primary.as_ref(),
            Screen::Alternate => self.alternate.as_ref(),
        }
    }

    fn anchor_mut(&mut self, screen: Screen) -> &mut Option<TrackedScreenPoint> {
        match screen {
            Screen::Primary => &mut self.primary,
            Screen::Alternate => &mut self.alternate,
        }
    }
}

impl Deref for PtySurface {
    type Target = PtyTerminalRuntime;

    fn deref(&self) -> &Self::Target {
        &self.terminal
    }
}

/// Content runtime shared by every view placement of one terminal.
///
/// A [`PtySurface`] is a lightweight placement carrying tab-local metadata.
/// This object owns the process, terminal emulator, ordered input/output, and
/// canonical geometry. Keeping the two identities distinct makes a terminal
/// projectable into any number of panes without cloning its PTY or VT state.
pub struct PtyTerminalRuntime {
    event_surface_id: SurfaceId,
    /// Stable public content identity. This belongs to the terminal runtime,
    /// while `SurfaceMeta::resource_identity` belongs to one view placement.
    terminal_public_id: Option<TerminalPublicId>,
    /// Stable protocol-v8 terminal identity.
    semantic_identity: SemanticSceneTerminalIdentity,
    term: Mutex<Box<Terminal>>,
    stream_progress: Box<TerminalStreamProgress>,
    interaction: Mutex<TerminalInteractionState>,
    input_authority: Arc<InputAuthority>,
    /// Present only for a protocol-v8 parser runtime with no local child.
    external: Option<Arc<ExternalTerminalRuntime>>,
    mouse_encoders: Mutex<Box<MouseEncoders>>,
    runtime: Mutex<PtyRuntime>,
    /// Explicit lifecycle authority for this process. Session content may
    /// survive a daemon replacement through a durable host; daemon-owned
    /// auxiliaries must terminate with the backend that created them.
    lifetime: PtyLifetime,
    supports_clear_history_key_fallback: AtomicBool,
    host_identity: Option<crate::terminal_host_runtime::TerminalHostIdentity>,
    #[cfg(unix)]
    host_exit_record_path: Option<PathBuf>,
    pid: Option<u32>,
    command: Vec<String>,
    tty_name: Option<PathBuf>,
    wait_after_command: bool,
    cwd: Option<String>,
    exit: Mutex<Option<TerminalExit>>,
    local_pty_drained: AtomicBool,
    exit_notified: AtomicBool,
    dead: AtomicBool,
    /// The daemon is intentionally dropping its compatibility proxy while
    /// leaving the terminal host alive for a later daemon to adopt.
    owner_detaching: AtomicBool,
    /// The host socket ended without a sequenced Exit. Closing this proxy
    /// must retain the host record so a fresh snapshot can recover it.
    host_connection_state: AtomicU8,
    /// Set when output arrived since the last render; cleared by the
    /// frontend when it draws.
    dirty: AtomicBool,
    title: Mutex<String>,
    pwd: Mutex<Option<String>>,
    geometry: Mutex<PtyGeometry>,
    kitty_graphics_limits: Box<Mutex<KittyGraphicsLimits>>,
    #[cfg(test)]
    geometry_test_hook: Mutex<Option<PtyGeometryTestHook>>,
    #[cfg(test)]
    deferred_cell_pixel_ack_test_hook: Mutex<Option<DeferredCellPixelAckTestHook>>,
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
    /// A reset or cursor-semantic transition requires reapplying equal state:
    /// byte frontends may reset palettes or switch per-screen cursor storage
    /// even when the final effective values compare equal.
    attach_colors_force_pending: AtomicBool,
    /// Last effective color state emitted to attach streams. This suppresses
    /// repeated OSC sets that advance Ghostty's revision without changing the
    /// frontend-visible state.
    last_attach_colors: Mutex<Option<Box<TerminalColors>>>,
    /// Single consume-once Ghostty render state shared by the local TUI and
    /// every protocol-v7 render attachment.
    render: Arc<Mutex<RenderHub>>,
    /// Per-renderer semantic encoders with independent canonical caches.
    semantic_scenes: Mutex<SemanticSceneHub>,
    semantic_attachment_count: AtomicUsize,
    attach_generation: AtomicU64,
    attach_sequence: AtomicU64,
    accessibility_content_revision: AtomicU64,
    accessibility_viewport_revision: AtomicU64,
    accessibility_focus_revision: AtomicU64,
    accessibility_demanded: AtomicBool,
    accessibility_frames: Mutex<VecDeque<TerminalAccessibilitySnapshot>>,
    render_generation: AtomicU64,
    frame_requests: SyncSender<u64>,
    #[cfg(test)]
    frame_producer_before_upgrade: FrameProducerTestHook,
}

enum PtyRuntime {
    Local {
        writer: Box<dyn Write + Send>,
        master: Box<dyn MasterPty + Send>,
        killer: Box<dyn ChildKiller + Send>,
    },
    #[cfg(unix)]
    Hosted(Box<crate::terminal_host_runtime::HostAttachment>),
    #[cfg(unix)]
    ExitedHosted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PtyLifetime {
    SessionOwned,
    DaemonOwned,
}

#[cfg(unix)]
struct HostedSurfaceLaunch {
    attachment: crate::terminal_host_runtime::HostAttachment,
    kitty_reservation: Option<crate::mux::KittyImageBudgetReservation>,
    terminate_on_error: bool,
    lifetime: PtyLifetime,
    terminal_public_id: Option<TerminalPublicId>,
    resource_identity: Option<TabResourceIdentity>,
}

pub const CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR: &str =
    "terminal keyboard mode cannot encode clear-history fallback key";
pub const CLEAR_HISTORY_PRESERVATION_ERROR: &str =
    "active terminal input extends into retained history";
pub const CLEAR_HISTORY_STREAM_TIMEOUT_ERROR: &str =
    "terminal output did not reach a safe clear-history boundary";
pub const CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR: &str =
    "terminal input did not accept clear-history fallback before timeout";
pub(crate) const CLEAR_HISTORY_STREAM_WAIT_TIMEOUT: Duration = Duration::from_millis(250);
pub(crate) const CLEAR_HISTORY_KEY_TEXT_MAX_BYTES: usize = 4 * 1024;
const CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT: Duration = Duration::from_millis(250);
// Kitty associated-text encoding can expand each ASCII input byte to a
// three-digit codepoint plus one separator. The extra key-text budget covers
// the fixed CSI-u fields without making fallback writes unbounded.
const CLEAR_HISTORY_FALLBACK_MAX_BYTES: usize = CLEAR_HISTORY_KEY_TEXT_MAX_BYTES * 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClearHistoryDelivery {
    KnownNotDelivered,
    Ambiguous,
}

#[derive(Debug)]
pub struct ClearHistoryFailure {
    error: anyhow::Error,
    delivery: ClearHistoryDelivery,
}

impl ClearHistoryFailure {
    pub fn known_not_delivered(error: anyhow::Error) -> Self {
        Self { error, delivery: ClearHistoryDelivery::KnownNotDelivered }
    }

    pub fn ambiguous(error: anyhow::Error) -> Self {
        Self { error, delivery: ClearHistoryDelivery::Ambiguous }
    }

    pub fn delivery(&self) -> ClearHistoryDelivery {
        self.delivery
    }

    pub fn error(&self) -> &anyhow::Error {
        &self.error
    }

    pub fn into_error(self) -> anyhow::Error {
        self.error
    }
}

#[cfg(unix)]
struct NonblockingFdGuard {
    fd: std::os::fd::RawFd,
    original_flags: libc::c_int,
    restored: bool,
}

#[cfg(unix)]
impl NonblockingFdGuard {
    fn install(fd: std::os::fd::RawFd) -> std::io::Result<Self> {
        let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if original_flags < 0 {
            return Err(std::io::Error::last_os_error());
        }
        if unsafe { libc::fcntl(fd, libc::F_SETFL, original_flags | libc::O_NONBLOCK) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Self { fd, original_flags, restored: false })
    }

    fn restore(&mut self) -> std::io::Result<()> {
        if self.restored {
            return Ok(());
        }
        if unsafe { libc::fcntl(self.fd, libc::F_SETFL, self.original_flags) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
        self.restored = true;
        Ok(())
    }
}

#[cfg(unix)]
impl Drop for NonblockingFdGuard {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

#[cfg(unix)]
fn clear_history_write_failure(error: std::io::Error, delivered: usize) -> ClearHistoryFailure {
    let error = anyhow::Error::from(error);
    if delivered == 0 {
        ClearHistoryFailure::known_not_delivered(error)
    } else {
        ClearHistoryFailure::ambiguous(error)
    }
}

pub(crate) fn write_clear_history_fallback(
    master: &dyn MasterPty,
    writer: &mut dyn Write,
    bytes: &[u8],
) -> Result<(), ClearHistoryFailure> {
    if bytes.len() > CLEAR_HISTORY_FALLBACK_MAX_BYTES {
        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
            "encoded clear-history fallback exceeds {CLEAR_HISTORY_FALLBACK_MAX_BYTES} bytes"
        )));
    }

    #[cfg(unix)]
    if let Some(fd) = master.as_raw_fd() {
        let mut nonblocking = NonblockingFdGuard::install(fd)
            .map_err(|error| clear_history_write_failure(error, 0))?;
        let deadline = Instant::now() + CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT;
        let mut delivered = 0;
        while delivered < bytes.len() {
            let written = unsafe {
                libc::write(
                    fd,
                    bytes[delivered..].as_ptr().cast(),
                    bytes.len().saturating_sub(delivered),
                )
            };
            if written > 0 {
                delivered = delivered.saturating_add(written as usize);
                continue;
            }
            if written == 0 {
                let error =
                    std::io::Error::new(std::io::ErrorKind::WriteZero, "PTY write returned zero");
                return Err(clear_history_write_failure(error, delivered));
            }
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            if error.kind() != std::io::ErrorKind::WouldBlock {
                return Err(clear_history_write_failure(error, delivered));
            }

            let now = Instant::now();
            if now >= deadline {
                let error = anyhow::anyhow!(CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR);
                return Err(if delivered == 0 {
                    ClearHistoryFailure::known_not_delivered(error)
                } else {
                    ClearHistoryFailure::ambiguous(error)
                });
            }
            let remaining = deadline.saturating_duration_since(now);
            let timeout_ms = remaining
                .as_nanos()
                .saturating_add(999_999)
                .checked_div(1_000_000)
                .unwrap_or(u128::MAX)
                .clamp(1, i32::MAX as u128) as libc::c_int;
            let mut poll_fd = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
            let ready = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
            if ready > 0 {
                if poll_fd.revents & libc::POLLNVAL != 0 {
                    let error =
                        std::io::Error::new(std::io::ErrorKind::BrokenPipe, "PTY fd is invalid");
                    return Err(clear_history_write_failure(error, delivered));
                }
                continue;
            }
            if ready < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(clear_history_write_failure(error, delivered));
            }
        }
        if let Err(error) = nonblocking.restore() {
            return Err(ClearHistoryFailure::ambiguous(error.into()));
        }
        return Ok(());
    }

    #[cfg(test)]
    {
        writer
            .write_all(bytes)
            .and_then(|()| writer.flush())
            .map_err(anyhow::Error::from)
            .map_err(ClearHistoryFailure::ambiguous)
    }

    #[cfg(not(test))]
    {
        let _ = writer;
        Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
            "bounded clear-history fallback writes are unavailable for this PTY"
        )))
    }
}

pub(crate) enum ClearHistoryTransition {
    Cleared(Vec<u8>),
    Blocked,
    EncodedFallback(Vec<u8>),
    Noop,
}

pub(crate) fn apply_clear_history_transition(
    term: &mut Terminal,
    fallback_key: Option<&KeyInput>,
) -> anyhow::Result<ClearHistoryTransition> {
    if term.active_screen() != Screen::Alternate {
        return Ok(match term.clear_history_preserving_prompt() {
            ClearHistoryOutcome::Cleared(clear) => ClearHistoryTransition::Cleared(clear),
            ClearHistoryOutcome::Blocked => ClearHistoryTransition::Blocked,
            ClearHistoryOutcome::Unchanged => {
                anyhow::bail!(CLEAR_HISTORY_PRESERVATION_ERROR)
            }
        });
    }
    let Some(input) = fallback_key else {
        return Ok(ClearHistoryTransition::Noop);
    };
    let encoded = encode_key_from_terminal(term, input)?;
    Ok(ClearHistoryTransition::EncodedFallback(encoded))
}

pub(crate) struct TerminalStreamProgress {
    next_resource_waiter_id: AtomicU64,
    state: Mutex<TerminalStreamProgressState>,
    changed: Condvar,
}

#[derive(Default)]
struct TerminalStreamProgressState {
    revision: u64,
    waiters: usize,
    resource_waiters: HashMap<u64, Weak<ResourceWaitWake>>,
    #[cfg(test)]
    resource_subscriptions: u64,
    clear_history_wait: Option<ClearHistoryWaitState>,
}

struct ClearHistoryWaitState {
    deadline: Instant,
    revision: u64,
    // Timed-out waits leave this state latched at zero only while the stream
    // revision is unchanged. Queued repeats then fail without restarting the
    // full timeout, while concurrent callers share one deadline.
    waiters: usize,
}

pub(crate) struct ClearHistoryWaitLease<'a> {
    progress: &'a TerminalStreamProgress,
    deadline: Instant,
    timed_out: bool,
}

/// One-shot terminal-stream wakeup. Registering before reading the viewport
/// closes the read/wait race, while cancellation and writer shutdown can wake
/// the same blocking primitive without a polling deadline.
pub(crate) struct TerminalStreamSubscription<'a> {
    progress: &'a TerminalStreamProgress,
    waiter_id: u64,
    wake: Arc<ResourceWaitWake>,
}

impl ClearHistoryWaitLease<'_> {
    pub(crate) fn deadline(&self) -> Instant {
        self.deadline
    }

    pub(crate) fn mark_timed_out(&mut self) {
        self.timed_out = true;
    }
}

impl Drop for ClearHistoryWaitLease<'_> {
    fn drop(&mut self) {
        self.progress.finish_clear_history_wait(self.timed_out);
    }
}

impl Default for TerminalStreamProgress {
    fn default() -> Self {
        Self {
            next_resource_waiter_id: AtomicU64::new(1),
            state: Mutex::new(TerminalStreamProgressState::default()),
            changed: Condvar::new(),
        }
    }
}

impl TerminalStreamProgress {
    pub(crate) fn revision(&self) -> u64 {
        self.state.lock().unwrap().revision
    }

    pub(crate) fn notify(&self) {
        let mut state = self.state.lock().unwrap();
        state.revision = state.revision.wrapping_add(1);
        // An expired budget is retained only while the stream is unchanged.
        // Active waiters keep their original deadline across fragmented output.
        if state.clear_history_wait.as_ref().is_some_and(|wait| wait.waiters == 0) {
            state.clear_history_wait = None;
        }
        let resource_waiters = std::mem::take(&mut state.resource_waiters);
        self.changed.notify_all();
        drop(state);
        for wake in resource_waiters.into_values().filter_map(|waiter| waiter.upgrade()) {
            wake.notify();
        }
    }

    fn notify_reconnect(&self) {
        self.notify();
    }

    pub(crate) fn subscribe(&self) -> TerminalStreamSubscription<'_> {
        let waiter_id = self.next_resource_waiter_id.fetch_add(1, Ordering::Relaxed);
        let wake = Arc::new(ResourceWaitWake::default());
        let mut state = self.state.lock().unwrap();
        state.resource_waiters.insert(waiter_id, Arc::downgrade(&wake));
        #[cfg(test)]
        {
            state.resource_subscriptions = state.resource_subscriptions.wrapping_add(1);
        }
        TerminalStreamSubscription { progress: self, waiter_id, wake }
    }

    pub(crate) fn begin_clear_history_wait(&self, timeout: Duration) -> ClearHistoryWaitLease<'_> {
        let mut state = self.state.lock().unwrap();
        let revision = state.revision;
        let wait = state.clear_history_wait.get_or_insert_with(|| ClearHistoryWaitState {
            deadline: Instant::now() + timeout,
            revision,
            waiters: 0,
        });
        wait.waiters += 1;
        ClearHistoryWaitLease { progress: self, deadline: wait.deadline, timed_out: false }
    }

    fn finish_clear_history_wait(&self, timed_out: bool) {
        let mut state = self.state.lock().unwrap();
        let current_revision = state.revision;
        let clear_wait = {
            let Some(wait) = state.clear_history_wait.as_mut() else {
                return;
            };
            debug_assert!(wait.waiters > 0);
            wait.waiters -= 1;
            wait.waiters == 0 && (!timed_out || wait.revision != current_revision)
        };
        if clear_wait {
            state.clear_history_wait = None;
        }
    }

    pub(crate) fn wait_for_change(&self, observed: u64, deadline: Instant) -> Option<u64> {
        self.wait_for_change_until(observed, Some(deadline))
    }

    fn wait_for_change_until(&self, observed: u64, deadline: Option<Instant>) -> Option<u64> {
        let mut state = self.state.lock().unwrap();
        if state.revision != observed {
            return Some(state.revision);
        }
        state.waiters += 1;
        while state.revision == observed {
            match deadline {
                Some(deadline) => {
                    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                        state.waiters -= 1;
                        return None;
                    };
                    let (next, timeout) = self.changed.wait_timeout(state, remaining).unwrap();
                    state = next;
                    if timeout.timed_out() && state.revision == observed {
                        state.waiters -= 1;
                        return None;
                    }
                }
                None => state = self.changed.wait(state).unwrap(),
            }
        }
        let revision = state.revision;
        state.waiters -= 1;
        Some(revision)
    }

    #[cfg(test)]
    fn waiter_count(&self) -> usize {
        let state = self.state.lock().unwrap();
        state.waiters + state.resource_waiters.len()
    }

    #[cfg(test)]
    fn resource_subscription_count(&self) -> u64 {
        self.state.lock().unwrap().resource_subscriptions
    }
}

impl TerminalStreamSubscription<'_> {
    pub(crate) fn wake(&self) -> Arc<ResourceWaitWake> {
        self.wake.clone()
    }

    pub(crate) fn wait_until(&self, deadline: Option<Instant>) -> bool {
        self.wake.wait_until(deadline)
    }
}

impl Drop for TerminalStreamSubscription<'_> {
    fn drop(&mut self) {
        self.progress.state.lock().unwrap().resource_waiters.remove(&self.waiter_id);
    }
}

fn encode_key_from_terminal(term: &Terminal, input: &KeyInput) -> anyhow::Result<Vec<u8>> {
    let mut encoder = KeyEncoder::new()?;
    let mut encoded = Vec::new();
    encoder.sync_from_terminal(term);
    encoder.encode(input, &mut encoded)?;
    if encoded.is_empty() {
        anyhow::bail!(CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR);
    }
    Ok(encoded)
}

#[cfg(unix)]
fn hosted_terminal_callbacks(
    id: SurfaceId,
    mux: Weak<Mux>,
    title_changed: Arc<AtomicBool>,
) -> Callbacks {
    Callbacks {
        // The terminal-host parser is authoritative and already writes query
        // responses (DA/DSR, Kitty graphics, OSC colors, ...) to the PTY. A
        // hosted Surface is only a mirror: answering here would inject one
        // duplicate reply per server/frontend mirror into the child input.
        on_pty_write: None,
        on_title_changed: Some(Box::new(move || {
            title_changed.store(true, Ordering::Relaxed);
        })),
        on_bell: Some(Box::new(move || {
            if let Some(mux) = mux.upgrade() {
                mux.emit_terminal_bell(id);
            }
        })),
    }
}

#[cfg(unix)]
fn mark_hosted_runtime_exited(
    pty: &PtySurface,
    identity: &crate::terminal_host_runtime::TerminalHostIdentity,
) {
    let mut runtime = pty.runtime.lock().unwrap();
    let matches = match &*runtime {
        PtyRuntime::Hosted(host) => host.identity() == *identity,
        PtyRuntime::ExitedHosted | PtyRuntime::Local { .. } => false,
    };
    if matches {
        if let PtyRuntime::Hosted(host) = &*runtime {
            host.disconnect();
        }
        *runtime = PtyRuntime::ExitedHosted;
        pty.supports_clear_history_key_fallback.store(false, Ordering::Release);
        drop(runtime);
        pty.finish_hosted_exit();
    }
}

fn publish_local_exit_if_ready(surface: &Arc<Surface>) {
    let Some(pty) = surface.as_pty() else { return };
    if !pty.local_pty_drained.load(Ordering::Acquire) || pty.exit.lock().unwrap().is_none() {
        return;
    }
    if pty.exit_notified.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err()
    {
        return;
    }
    pty.dead.store(true, Ordering::Release);
    if let Some(mux) = pty.mux.upgrade() {
        mux.surface_exited(surface.id);
    }
}

fn terminal_public_id_from_resource_identity(
    identity: &TabResourceIdentity,
    invalid_context: &str,
) -> anyhow::Result<TerminalPublicId> {
    match &identity.content_id {
        ContentPublicId::Terminal(terminal_id) => Ok(terminal_id.clone()),
        ContentPublicId::Browser(_) => anyhow::bail!("{invalid_context}"),
    }
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
    if !wait_for_launch_helper_exit(queue.0, process_id, HUP_GRACE)? {
        let status = unsafe { libc::kill(process_id as libc::pid_t, libc::SIGKILL) };
        if status != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error).context("kill unready launch helper");
            }
        }
        if !wait_for_launch_helper_exit(queue.0, process_id, KILL_GRACE)? {
            anyhow::bail!("unready launch helper {process_id} did not exit after SIGKILL");
        }
    }
    match child.try_wait()? {
        Some(_) => Ok(()),
        None => anyhow::bail!("unready launch helper exit was signaled but could not be reaped"),
    }
}

#[cfg(target_os = "macos")]
fn wait_for_launch_helper_exit(
    queue: libc::c_int,
    process_id: u32,
    timeout: Duration,
) -> std::io::Result<bool> {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let timeout = libc::timespec {
            tv_sec: remaining.as_secs().try_into().unwrap_or(libc::time_t::MAX),
            tv_nsec: remaining.subsec_nanos().into(),
        };
        let mut event = std::mem::MaybeUninit::<libc::kevent>::zeroed();
        let count =
            unsafe { libc::kevent(queue, std::ptr::null(), 0, event.as_mut_ptr(), 1, &timeout) };
        if count < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if count == 0 {
            return Ok(false);
        }
        let event = unsafe { event.assume_init() };
        if event.ident != process_id as libc::uintptr_t || event.filter != libc::EVFILT_PROC {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "launch-helper watcher received an event for another process",
            ));
        }
        if event.flags & libc::EV_ERROR != 0 && event.data != 0 {
            return Err(std::io::Error::from_raw_os_error(event.data as i32));
        }
        if event.fflags & libc::NOTE_EXIT == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "launch-helper watcher received a non-exit process event",
            ));
        }
        return Ok(true);
    }
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

type SurfaceChild = Box<dyn Child + Send + Sync>;

/// Transfer the child into its exact-owner wait thread before any later
/// surface setup can fail. If the OS cannot create the thread, return the
/// still-owned child so the caller can terminate and reap it synchronously.
fn install_child_reaper(
    surface_id: SurfaceId,
    child: SurfaceChild,
) -> Result<(), (std::io::Error, SurfaceChild)> {
    let child = Arc::new(Mutex::new(Some(child)));
    let reaper_child = child.clone();
    match std::thread::Builder::new().name(format!("surface-{surface_id}-wait")).spawn(move || {
        let child = reaper_child.lock().unwrap().take();
        if let Some(mut child) = child {
            let _ = child.wait();
        }
    }) {
        Ok(_) => Ok(()),
        Err(error) => {
            let child =
                child.lock().unwrap().take().expect("failed reaper spawn retains child ownership");
            Err((error, child))
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
        if let Err((error, mut child)) = install_child_reaper(id, child) {
            // Closing the gate first guarantees that a gated helper cannot
            // execute user code while its fallback cleanup runs.
            drop(gate);
            #[cfg(target_os = "macos")]
            let cleanup = terminate_unready_launch_helper(child.as_mut(), pid);
            #[cfg(not(target_os = "macos"))]
            let cleanup = terminate_unready_launch_helper(child, pid);
            if let Err(cleanup) = cleanup {
                return Err(error).context(format!(
                    "install child reaper failed and helper cleanup also failed: {cleanup:#}"
                ));
            }
            return Err(error).context("install terminal child reaper");
        }
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
            attach_generation: AtomicU64::new(1),
            attach_sequence: AtomicU64::new(0),
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

        Ok((surface, gate))
    }

    /// Create Ghostty parser, semantic scene, and renderer state without
    /// opening a PTY or spawning a child. External output must cross the
    /// owner/generation/sequence-fenced APIs below.
    pub(crate) fn spawn_external_with_uuid(
        id: SurfaceId,
        uuid: crate::SurfaceUuid,
        opts: SurfaceOptions,
        no_reflow: bool,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_external_with_uuid_and_provenance(id, uuid, opts, no_reflow, None, mux)
    }

    pub(crate) fn spawn_external_with_uuid_and_provenance(
        id: SurfaceId,
        uuid: crate::SurfaceUuid,
        mut opts: SurfaceOptions,
        no_reflow: bool,
        provenance: Option<ExternalTerminalProvenance>,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        opts.cols = opts.cols.max(1);
        opts.rows = opts.rows.max(1);
        let semantic_identity = SemanticSceneTerminalIdentity::random(uuid)?;
        let external =
            Arc::new(ExternalTerminalRuntime::new(no_reflow, opts.scrollback, provenance));
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
                        mux.emit_terminal_bell(id);
                    }
                }
            })),
            ..Callbacks::default()
        };
        let mut term = Terminal::new(opts.cols, opts.rows, opts.scrollback, callbacks)?;
        term.resize(opts.cols, opts.rows, 8, 16)?;
        if let Some(mux) = mux.upgrade() {
            let colors = mux.default_colors();
            term.replace_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            replace_ghostty_cursor_defaults(&mut term, colors);
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
            attach_generation: AtomicU64::new(1),
            attach_sequence: AtomicU64::new(0),
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
            attach_generation: AtomicU64::new(1),
            attach_sequence: AtomicU64::new(0),
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
        let _operation = external.operation.lock().unwrap();
        let (cols, rows) = *pty.size.lock().unwrap();
        Some((cols, rows, external.scrollback, external.no_reflow.load(Ordering::Acquire)))
    }

    pub(crate) fn external_terminal_provenance(&self) -> Option<ExternalTerminalProvenance> {
        self.as_pty()?.external.as_ref()?.provenance
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
        no_reflow: bool,
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
                &[u8::from(no_reflow)],
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

        let previous_no_reflow = external.no_reflow.swap(no_reflow, Ordering::AcqRel);
        let reset_result = (|| -> anyhow::Result<u64> {
            let mut term = pty.term.lock().unwrap();
            term.reset();
            let restore_wraparound = no_reflow && term.mode(7, false);
            if restore_wraparound {
                let _ = term.set_mode(7, false, false);
            }
            term.resize(cols, rows, 8, 16)?;
            if restore_wraparound {
                let _ = term.set_mode(7, false, true);
            }
            if !seed.is_empty() {
                term.vt_write(seed);
                let _ = pty.advance_attach_sequence_locked(seed.len());
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
            if let Err(error) = pty.broadcast_attach_replay_locked(&mut term, cols, rows) {
                return Err(error.into());
            }
            let title = term.title().unwrap_or_default();
            *pty.title.lock().unwrap() = title;
            *pty.pwd.lock().unwrap() = term.pwd();
            pty.accessibility_content_revision.fetch_add(1, Ordering::AcqRel);
            pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
            Ok(pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1)
        })();
        let generation = match reset_result {
            Ok(generation) => generation,
            Err(error) => {
                external.no_reflow.store(previous_no_reflow, Ordering::Release);
                external.state.lock().unwrap().requires_reset = true;
                return Err(error);
            }
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
            external.no_reflow.store(previous_no_reflow, Ordering::Release);
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
            no_reflow,
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
            no_reflow: external.no_reflow.load(Ordering::Acquire),
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
        #[cfg(unix)]
        {
            let runtime = pty.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                return host.send(MessageKind::Paste, bytes);
            }
            if matches!(&*runtime, PtyRuntime::ExitedHosted) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "terminal host has exited",
                ));
            }
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
    /// method is kept for existing PTY call sites. Access through this
    /// method is not terminal-stream progress; the local and hosted PTY
    /// readers signal progress only after applying actual output bytes.
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> Option<R> {
        let pty = self.as_pty()?;
        let mut term = pty.term.lock().unwrap();
        let result = f(&mut term);
        pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
        Some(result)
    }

    fn configure_terminal_kitty_graphics_limits(
        terminal: &mut Terminal,
        limits: KittyGraphicsLimits,
    ) -> anyhow::Result<bool> {
        terminal.set_kitty_graphics_limits(limits).map_err(Into::into)
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn set_kitty_graphics_limits(
        &self,
        bytes: u64,
        inflight_bytes: u64,
        images: u64,
        placements: u64,
    ) -> anyhow::Result<()> {
        let requested =
            KittyGraphicsLimits { image_bytes: bytes, inflight_bytes, images, placements };
        self.set_kitty_graphics_limits_until(
            requested,
            Instant::now() + crate::terminal_host_runtime::CONTROL_RESPONSE_TIMEOUT,
        )
    }

    pub(crate) fn set_kitty_graphics_limits_until(
        &self,
        requested: KittyGraphicsLimits,
        deadline: Instant,
    ) -> anyhow::Result<()> {
        let Some(pty) = self.as_pty() else {
            return Ok(());
        };
        let requested = requested
            .validate()
            .map_err(|_| anyhow::anyhow!("Kitty graphics limits are out of range"))?;
        #[cfg(unix)]
        let next = {
            let runtime = pty.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                if *pty.kitty_graphics_limits.lock().unwrap() == requested {
                    return Ok(());
                }
                if host.send_kitty_graphics_limits_until(requested, deadline)? {
                    // The host publishes a complete replacement before its
                    // acknowledgement. The reader has therefore committed the
                    // authoritative parser and cache before this returns.
                    return Ok(());
                }
                // Older hosts cannot carry Kitty sidecar state. Keep the
                // disposable mirror disabled so it cannot silently diverge.
                KittyGraphicsLimits::disabled()
            } else {
                requested
            }
        };
        #[cfg(not(unix))]
        let next = requested;
        let graphics_changed = {
            let mut term = pty.term.lock().unwrap();
            let mut limits = pty.kitty_graphics_limits.lock().unwrap();
            if *limits == next {
                return Ok(());
            }
            let graphics_changed = Self::configure_terminal_kitty_graphics_limits(&mut term, next)?;
            *limits = next;
            pty.resynchronize_attach_taps_locked(&mut term);
            if graphics_changed {
                let mut render = pty.render.lock().unwrap();
                render.state.clear_kitty_graphics_cache();
                render.latest = None;
                render.initial_graphics = None;
            }
            graphics_changed
        };
        if !graphics_changed {
            return Ok(());
        }
        let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        pty.request_frame(generation);
        Ok(())
    }

    /// Return the coalesced revision advanced after terminal output or another
    /// viewport-text transition is applied. Callers can snapshot terminal
    /// state after reading this value, then wait on the same revision without
    /// losing an intervening update.
    pub(crate) fn terminal_stream_revision(&self) -> ghostty_vt::Result<u64> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        Ok(pty.stream_progress.revision())
    }

    pub(crate) fn subscribe_terminal_stream_change(
        &self,
    ) -> ghostty_vt::Result<TerminalStreamSubscription<'_>> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        Ok(pty.stream_progress.subscribe())
    }

    /// Wait until PTY output advances beyond `observed`, or until `deadline`.
    /// Unlike an attach stream, this wakeup is coalesced and cannot overflow.
    pub(crate) fn wait_for_terminal_stream_change(
        &self,
        observed: u64,
        deadline: Option<Instant>,
    ) -> ghostty_vt::Result<Option<u64>> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        Ok(pty.stream_progress.wait_for_change_until(observed, deadline))
    }

    #[cfg(test)]
    pub(crate) fn apply_stream_output_for_test(&self, bytes: &[u8]) -> Option<()> {
        let pty = self.as_pty()?;
        let mut term = pty.term.lock().unwrap();
        term.vt_write(bytes);
        pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
        drop(term);
        pty.stream_progress.notify();
        Some(())
    }

    #[cfg(test)]
    pub(crate) fn terminal_stream_waiter_count_for_test(&self) -> Option<usize> {
        Some(self.as_pty()?.stream_progress.waiter_count())
    }

    #[cfg(test)]
    pub(crate) fn terminal_stream_subscription_count_for_test(&self) -> Option<u64> {
        Some(self.as_pty()?.stream_progress.resource_subscription_count())
    }

    pub fn encode_mouse(
        &self,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        let pty = self.as_pty()?;
        match pty.mouse_encoders.try_lock() {
            Ok(mut encoders) => Some(encoders.encode(input, output)),
            Err(TryLockError::Poisoned(error)) => Some(error.into_inner().encode(input, output)),
            Err(TryLockError::WouldBlock) => None,
        }
    }

    /// Encode only when the terminal still matches the semantics captured
    /// with the rendered frame. The terminal and encoder locks stay held
    /// across comparison and encoding so parser updates cannot interleave.
    pub fn encode_mouse_if_semantics(
        &self,
        expected: TerminalPointerSemanticSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        let pty = self.as_pty()?;
        let term = match pty.term.try_lock() {
            Ok(term) => term,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        if term.pointer_semantic_snapshot() != expected {
            return Some(GuardedMouseEncode::SemanticsChanged);
        }
        let mut encoders = match pty.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        encoders.sync_from_terminal(&term);
        Some(GuardedMouseEncode::Encoded(encoders.encode(input, output)))
    }

    /// Encode only when both terminal semantics and content still match the
    /// immutable frame that admitted this uncaptured pointer event.
    pub fn encode_mouse_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        let pty = self.as_pty()?;
        let term = match pty.term.try_lock() {
            Ok(term) => term,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        if term.pointer_semantic_snapshot() != expected.semantics {
            return Some(GuardedMouseEncode::SemanticsChanged);
        }
        if pty.render_generation.load(Ordering::Acquire) != expected.content_generation {
            return Some(GuardedMouseEncode::ContentChanged);
        }
        let mut encoders = match pty.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        encoders.sync_from_terminal(&term);
        Some(GuardedMouseEncode::Encoded(encoders.encode(input, output)))
    }

    pub fn encode_mouse_release(
        &self,
        input: MouseInput,
        output: &mut impl Extend<u8>,
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
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
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

    /// Encode a press and its matching release against one rendered terminal
    /// semantic snapshot, without a parser update between validation and
    /// encoding either half.
    pub fn encode_mouse_press_pair_if_semantics(
        &self,
        expected: TerminalPointerSemanticSnapshot,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        let pty = self.as_pty()?;
        let term = match pty.term.try_lock() {
            Ok(term) => term,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        if term.pointer_semantic_snapshot() != expected {
            return Some(GuardedMouseEncode::SemanticsChanged);
        }
        let mut encoders = match pty.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        encoders.sync_from_terminal(&term);
        Some(GuardedMouseEncode::Encoded(encoders.encode_press_pair(
            press,
            release,
            press_output,
            release_output,
        )))
    }

    /// Encode a press and its matching release only while the terminal still
    /// matches the immutable content frame that admitted the press.
    pub fn encode_mouse_press_pair_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        let pty = self.as_pty()?;
        let term = match pty.term.try_lock() {
            Ok(term) => term,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        if term.pointer_semantic_snapshot() != expected.semantics {
            return Some(GuardedMouseEncode::SemanticsChanged);
        }
        if pty.render_generation.load(Ordering::Acquire) != expected.content_generation {
            return Some(GuardedMouseEncode::ContentChanged);
        }
        let mut encoders = match pty.mouse_encoders.try_lock() {
            Ok(encoders) => encoders,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => return Some(GuardedMouseEncode::Contended),
        };
        encoders.sync_from_terminal(&term);
        Some(GuardedMouseEncode::Encoded(encoders.encode_press_pair(
            press,
            release,
            press_output,
            release_output,
        )))
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
        let _ = self.apply_scroll_delta(None, delta)?;
        Ok(())
    }

    /// Scroll only this placement's in-process frontend viewport. Byte-mode
    /// frontends own the equivalent state in their terminal mirror.
    pub fn view_scroll_delta(&self, delta: isize) -> anyhow::Result<Option<Scrollbar>> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let mut term = pty.term.lock().unwrap();
        let Some(scrollbar) = pty.view_scrollbar_locked(&mut term) else { return Ok(None) };
        let target = if delta < 0 {
            scrollbar.offset.saturating_sub(delta.unsigned_abs() as u64)
        } else {
            scrollbar.offset.saturating_add(delta as u64)
        }
        .min(scrollbar.total.saturating_sub(scrollbar.len));
        if target == scrollbar.offset {
            return Ok(Some(scrollbar));
        }
        pty.set_view_scroll_offset_locked(&mut term, target);
        Ok(Some(Scrollbar { offset: target, ..scrollbar }))
    }

    pub fn view_scroll_delta_if_scrollbar(
        &self,
        expected: Scrollbar,
        delta: isize,
    ) -> anyhow::Result<Option<Scrollbar>> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let mut term = pty.term.lock().unwrap();
        let Some(scrollbar) = pty.view_scrollbar_locked(&mut term) else { return Ok(None) };
        if scrollbar != expected {
            return Ok(None);
        }
        let target = if delta < 0 {
            scrollbar.offset.saturating_sub(delta.unsigned_abs() as u64)
        } else {
            scrollbar.offset.saturating_add(delta as u64)
        }
        .min(scrollbar.total.saturating_sub(scrollbar.len));
        pty.set_view_scroll_offset_locked(&mut term, target);
        Ok(Some(Scrollbar { offset: target, ..scrollbar }))
    }

    pub fn view_scrollbar(&self) -> Option<Scrollbar> {
        let pty = self.as_pty()?;
        let mut term = pty.term.lock().unwrap();
        pty.view_scrollbar_locked(&mut term)
    }

    pub fn view_scroll_to_bottom(&self) -> anyhow::Result<bool> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let mut term = pty.term.lock().unwrap();
        let Some(scrollbar) = pty.view_scrollbar_locked(&mut term) else { return Ok(false) };
        let bottom = scrollbar.total.saturating_sub(scrollbar.len);
        let changed = scrollbar.offset != bottom;
        pty.set_view_scroll_offset_locked(&mut term, bottom);
        Ok(changed)
    }

    /// Apply a scroll only while the terminal still matches the rendered
    /// scrollbar geometry that admitted the pointer gesture.
    pub fn scroll_delta_if_scrollbar(
        &self,
        expected: Scrollbar,
        delta: isize,
    ) -> anyhow::Result<Option<Scrollbar>> {
        self.apply_scroll_delta(Some(expected), delta)
    }

    fn apply_scroll_delta(
        &self,
        expected: Option<Scrollbar>,
        delta: isize,
    ) -> anyhow::Result<Option<Scrollbar>> {
        let Some(pty) = self.as_pty() else {
            anyhow::bail!("browser surface does not have a VT terminal");
        };
        let (scrollbar, changed) = {
            let mut term = pty.term.lock().unwrap();
            if expected.is_some_and(|expected| term.scrollbar() != Some(expected)) {
                return Ok(None);
            }
            let before = terminal_scroll_position(&term);
            term.scroll_delta(delta);
            let after = terminal_scroll_position(&term);
            let changed = if before == after {
                None
            } else {
                pty.refresh_active_search_locked(&mut term)?;
                broadcast_render_scroll_locked(pty, after);
                pty.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
                let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                let _ = pty.build_frame_locked(&mut term, generation, false);
                Some(after)
            };
            (term.scrollbar(), changed)
        };
        if let Some((offset, at_bottom)) = changed
            && let Some(mux) = pty.mux.upgrade()
        {
            mux.emit_terminal_scroll(pty.event_surface_id, offset, at_bottom);
        }
        Ok(scrollbar)
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
            mux.emit_terminal_scroll(pty.event_surface_id, offset, at_bottom);
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
                let frame = AttachFrame::ColorsChanged {
                    surface_uuid: pty.meta.uuid,
                    runtime_epoch: pty.semantic_identity.runtime_epoch,
                    generation: pty.attach_generation.load(Ordering::Acquire),
                    sequence: pty.attach_sequence.load(Ordering::Acquire),
                    colors,
                };
                taps.retain(|tap| tap.try_send(frame.clone()));
            }
            let mut term = pty.term.lock().unwrap();
            term.replace_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            replace_ghostty_cursor_defaults(&mut term, colors);
            let live_colors = TerminalColors::from_pty_output(&term, colors);
            let colors = pty.terminal_colors_locked(&term, colors);
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

    /// Render this placement's frontend-local viewport without changing the
    /// session compatibility viewport used by backend render projections.
    pub fn render_view_frame(
        &self,
        render: &mut RenderState,
    ) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let mut term = pty.term.lock().unwrap();
        let original_offset = term.scrollbar().map(|scrollbar| scrollbar.offset);
        let view_offset = pty.view_scrollbar_locked(&mut term).map(|scrollbar| scrollbar.offset);
        let applied =
            view_offset.is_none_or(|offset| set_terminal_scroll_offset(&mut term, offset));
        let result = if applied {
            (|| {
                render.update(&mut term)?;
                let palette_colors = std::array::from_fn(|index| render.palette_color(index as u8));
                let palette_overridden =
                    std::array::from_fn(|index| render.palette_overridden(index as u8));
                Ok(Arc::new(SurfaceRenderFrame {
                    frame: render.build_frame()?,
                    content_generation: pty.render_generation.load(Ordering::Acquire),
                    scrollback_rows: term.history_rows(),
                    history_epoch: term.history_epoch(),
                    pointer_semantics: term.pointer_semantic_snapshot(),
                    palette_colors,
                    palette_overridden,
                }))
            })()
        } else {
            Err(ghostty_vt::Error::NoValue)
        };
        let restored =
            original_offset.is_none_or(|offset| set_terminal_scroll_offset(&mut term, offset));
        if !restored {
            // Cleanup errors take precedence because a successful-looking
            // frame would conceal mutation of the shared compatibility view.
            return Err(ghostty_vt::Error::NoValue);
        }
        result
    }

    /// Read current pointer-routing state without waiting behind terminal parsing.
    /// Contention is distinct so discrete input can be retained for replay.
    pub fn try_pointer_semantics(&self) -> Option<PointerSemanticProbe> {
        let pty = self.as_pty()?;
        match pty.term.try_lock() {
            Ok(term) => Some(PointerSemanticProbe::Ready(term.pointer_semantic_snapshot())),
            Err(TryLockError::Poisoned(error)) => {
                Some(PointerSemanticProbe::Ready(error.into_inner().pointer_semantic_snapshot()))
            }
            Err(TryLockError::WouldBlock) => Some(PointerSemanticProbe::Contended),
        }
    }

    /// Read terminal pointer semantics and content generation without waiting
    /// behind terminal parsing. Returns `None` for non-PTY surfaces.
    pub fn try_pointer_snapshot(&self) -> Option<PointerSnapshotProbe> {
        let pty = self.as_pty()?;
        match pty.term.try_lock() {
            Ok(term) => Some(PointerSnapshotProbe::Ready(TerminalPointerSnapshot {
                semantics: term.pointer_semantic_snapshot(),
                content_generation: pty.render_generation.load(Ordering::Acquire),
            })),
            Err(TryLockError::Poisoned(error)) => {
                Some(PointerSnapshotProbe::Ready(TerminalPointerSnapshot {
                    semantics: error.into_inner().pointer_semantic_snapshot(),
                    content_generation: pty.render_generation.load(Ordering::Acquire),
                }))
            }
            Err(TryLockError::WouldBlock) => Some(PointerSnapshotProbe::Contended),
        }
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

    pub(crate) fn set_cell_pixel_size_reporting_until(
        &self,
        width_px: u16,
        height_px: u16,
        deadline: Instant,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<Option<u64>> {
        match self {
            Surface::Pty(pty) => {
                match pty.set_cell_pixel_size_until(width_px, height_px, Some(deadline)) {
                    Ok(changed) => {
                        report(changed.then_some(0));
                        Ok(changed.then_some(0))
                    }
                    Err(error) => {
                        report(None);
                        Err(error)
                    }
                }
            }
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

    pub(crate) fn cell_pixel_size(&self) -> (u16, u16) {
        match self {
            Surface::Pty(pty) => {
                let geometry = *pty.geometry.lock().unwrap();
                (geometry.cell_width, geometry.cell_height)
            }
            Surface::Browser(browser) => browser.cell_pixel_size(),
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
        let runtime = self.as_pty().expect("test PTY surface").runtime.lock().unwrap();
        let PtyRuntime::Local { master, .. } = &*runtime else {
            panic!("test PTY surface uses a local runtime");
        };
        master.get_size().unwrap()
    }

    #[cfg(test)]
    pub(crate) fn test_cell_pixel_size(&self) -> (u16, u16) {
        let geometry = *self.as_pty().expect("test PTY surface").geometry.lock().unwrap();
        (geometry.cell_width, geometry.cell_height)
    }

    /// Stop the daemon's durable hosted-terminal mirror from constraining the
    /// host grid when the mux has no size-participating viewer for this
    /// surface. A later viewer report re-registers through `resize`.
    pub(crate) fn release_viewer_size(&self) -> anyhow::Result<bool> {
        let Surface::Pty(pty) = self else { return Ok(false) };
        #[cfg(unix)]
        {
            let runtime = pty.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                return Ok(host.release_viewer_size()?);
            }
        }
        Ok(false)
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

    pub fn local_cwd(&self) -> Option<String> {
        self.pwd()
            .as_deref()
            .and_then(platform::terminal_pwd_to_local_path)
            .map(|path| path.to_string_lossy().into_owned())
            .or_else(|| self.spawn_cwd())
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
        self.attach_stream_with_lifecycle_and_replay_limit(lifecycle, VT_REPLAY_MAX_BYTES)
    }

    pub(crate) fn attach_stream_with_lifecycle_and_replay_limit(
        &self,
        lifecycle: AttachLifecycle,
        replay_max_bytes: usize,
    ) -> ghostty_vt::Result<AttachStream> {
        if replay_max_bytes == 0 || replay_max_bytes > VT_REPLAY_MAX_BYTES {
            return Err(ghostty_vt::Error::InvalidValue);
        }
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let mut term = pty.term.lock().unwrap();
        let (tap, stream) =
            AttachTap::pair(lifecycle.clone(), ATTACH_STREAM_CAPACITY, ATTACH_STREAM_MAX_BYTES);
        // Snapshot and tap registration under the same terminal lock:
        // the reader thread cannot apply bytes between the two.
        let replay = term.vt_replay_bounded(replay_max_bytes)?;
        let (cols, rows) = (term.cols(), term.rows());
        let generation = pty.attach_generation.load(Ordering::Acquire);
        let sequence = pty.attach_sequence.load(Ordering::Acquire);
        let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let colors = TerminalColors::from_terminal(&mut term, defaults);
        pty.taps.lock().unwrap().push(AttachTap {
            sender: tx,
            lifecycle: lifecycle.clone(),
            queued_bytes: queued_bytes.clone(),
            max_queued_bytes: ATTACH_STREAM_MAX_BYTES,
            replay_max_bytes,
        });
        Ok(AttachStream {
            surface_uuid: pty.meta.uuid,
            runtime_epoch: pty.semantic_identity.runtime_epoch,
            generation,
            sequence,
            cols,
            rows,
            replay: replay.bytes.into(),
            kitty_image_aliases: replay.kitty_image_aliases,
            kitty_state: replay.kitty_state,
            colors,
            stream,
            lifecycle,
        })
    }

    /// Attach to the shared protocol-v7 render stream without consuming
    /// terminal damage a second time.
    pub fn attach_render_stream(&self) -> ghostty_vt::Result<RenderAttachStream> {
        let Some(pty) = self.as_pty() else {
            return Err(ghostty_vt::Error::InvalidValue);
        };
        let permit = pty
            .mux
            .upgrade()
            .and_then(|mux| mux.claim_render_attachment())
            .ok_or(ghostty_vt::Error::OutOfSpace)?;
        let mut term = pty.term.lock().unwrap();
        let generation = pty.render_generation.load(Ordering::Acquire);
        let _ = pty.build_frame_locked(&mut term, generation, false)?;
        let (tap, stream) = RenderTap::pair(&pty.render);
        let initial = {
            let mut render = pty.render.lock().unwrap();
            let shared = render.latest.clone().ok_or(ghostty_vt::Error::NoValue)?;
            let initial_graphics = match render.initial_graphics.as_ref() {
                Some(cached) if Arc::ptr_eq(&cached.source, &shared.frame.kitty_graphics) => {
                    cached.snapshot.clone()
                }
                _ => {
                    let snapshot = render.state.snapshot_kitty_graphics(&term, true)?;
                    render.initial_graphics = Some(InitialGraphicsSnapshot {
                        source: shared.frame.kitty_graphics.clone(),
                        snapshot: snapshot.clone(),
                    });
                    snapshot
                }
            };
            let mut initial = (*shared).clone();
            initial.frame.kitty_graphics = initial_graphics;
            if !pty.dead.load(Ordering::Acquire) {
                render.taps.push(tap);
            }
            Arc::new(initial)
        };
        Ok(RenderAttachStream { initial, stream, _permit: permit })
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

    pub(crate) fn disconnect_for_daemon_shutdown(&self) {
        match self {
            #[cfg(unix)]
            Surface::Pty(pty) => {
                if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                    pty.owner_detaching.store(true, Ordering::Release);
                    host.disconnect();
                    return;
                }
                if matches!(&*pty.runtime.lock().unwrap(), PtyRuntime::ExitedHosted) {
                    return;
                }
                self.kill();
            }
            #[cfg(not(unix))]
            Surface::Pty(_) => self.kill(),
            Surface::Browser(browser) => browser.kill(),
        }
    }

    pub(crate) fn shutdown_for_daemon(&self) {
        if self.as_pty().is_some_and(|pty| pty.lifetime == PtyLifetime::DaemonOwned) {
            self.kill();
            return;
        }
        self.disconnect_for_daemon_shutdown();
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
        self.browser_frame_shared().map(|frame| frame.as_ref().clone())
    }

    pub fn browser_frame_shared(&self) -> Option<Arc<BrowserFrame>> {
        self.as_browser().and_then(BrowserSurface::latest_frame)
    }

    pub fn browser_frame_metadata(&self) -> Option<(u64, u32, u32, Option<u64>)> {
        self.as_browser().and_then(BrowserSurface::latest_frame_metadata)
    }

    pub fn browser_frame_update(&self) -> Option<BrowserFrameUpdate> {
        self.as_browser().and_then(BrowserSurface::latest_frame_update)
    }

    /// Return the opaque browser pointer-authority token for guarded input.
    pub fn browser_frame_seq(&self) -> Option<u64> {
        self.as_browser().and_then(BrowserSurface::latest_frame_seq)
    }

    /// Return whether the local renderer acknowledged this exact browser
    /// bitmap as its current presentation.
    pub fn browser_accepts_pointer_frame(&self, frame_seq: u64) -> bool {
        self.as_browser().is_some_and(|browser| browser.accepts_pointer_frame(frame_seq))
    }

    /// Return whether a browser bitmap belongs to the current document and
    /// coordinate mapping without granting it input authority.
    pub fn browser_pointer_frame_is_in_current_route(&self, frame_seq: u64) -> bool {
        self.as_browser()
            .is_some_and(|browser| browser.pointer_frame_is_in_current_route(frame_seq))
    }

    pub fn browser_acknowledge_pointer_frame(&self, frame_seq: u64) -> bool {
        self.as_browser().is_some_and(|browser| browser.acknowledge_pointer_frame(frame_seq))
    }

    pub(crate) fn browser_acknowledge_pointer_frame_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: u64,
    ) -> bool {
        self.as_browser()
            .is_some_and(|browser| browser.acknowledge_pointer_frame_from(owner, frame_seq))
    }

    pub(crate) fn forget_browser_pointer_owner(&self, owner: BrowserPointerOwner) {
        if let Some(browser) = self.as_browser() {
            browser.forget_pointer_owner(owner);
        }
    }

    pub fn has_browser_frame(&self) -> bool {
        self.as_browser().is_some_and(BrowserSurface::has_latest_frame)
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
        if browser.presentation_mode() == crate::browser::BrowserPresentationMode::FrontendNative {
            anyhow::bail!("frontend-native browser does not expose a daemon frame stream");
        }
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

    pub fn browser_key_press(
        &self,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.key_press(key, code, windows_virtual_key_code, modifiers, text)
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

    /// Queue browser mouse input admitted by a rendered frame sequence.
    /// Returns `None` for non-browser surfaces.
    pub fn browser_mouse_event_for_frame(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.mouse_event_for_frame(event_type, x, y, button, click_count, frame_seq)
    }

    pub(crate) fn browser_mouse_event_for_frame_from(
        &self,
        dispatch: BrowserMouseDispatch<'_>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.mouse_event_for_frame_from(dispatch)
    }

    pub(crate) fn wake_browser_pointer_cleanup(&self) {
        if let Some(browser) = self.as_browser() {
            browser.wake_pointer_cleanup();
        }
    }

    pub fn browser_wheel(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        self.browser_wheel_2d(x, y, 0.0, delta_y)
    }

    pub fn browser_wheel_2d(
        &self,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.wheel_2d(x, y, delta_x, delta_y)
    }

    /// Queue browser wheel input only while its rendered frame remains live.
    /// Returns `None` for non-browser surfaces.
    pub fn browser_wheel_for_frame(
        &self,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.wheel_for_frame(x, y, delta_y, frame_seq)
    }

    pub(crate) fn browser_wheel_for_frame_from(
        &self,
        owner: BrowserPointerOwner,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.wheel_for_frame_from(owner, x, y, delta_y, frame_seq)
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

    pub(crate) fn browser_insert_text_confirmed(&self, text: &str) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.insert_text_confirmed(text)
    }

    pub(crate) fn browser_key_event_confirmed(
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
        browser.key_event_confirmed(
            event_type,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        )
    }

    pub(crate) fn browser_mouse_event_confirmed(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: u64,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.mouse_event_confirmed(event_type, x, y, button, click_count, frame_seq)
    }

    pub(crate) fn browser_wheel_confirmed(
        &self,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        frame_seq: u64,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.wheel_confirmed(x, y, delta_x, delta_y, frame_seq)
    }

    pub(crate) fn browser_navigate_confirmed(&self, url: &str) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.navigate_confirmed(url)
    }

    pub(crate) fn browser_back_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.back_confirmed()
    }

    pub(crate) fn browser_forward_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.forward_confirmed()
    }

    pub(crate) fn browser_reload_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.reload_confirmed()
    }

    pub(crate) fn browser_activate_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.activate_confirmed()
    }

    pub(crate) fn browser_close_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.close_confirmed()
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

    fn cancel_attach_taps_for_resnapshot(&self) {
        let mut taps = self.taps.lock().unwrap();
        for tap in taps.iter() {
            tap.lifecycle.mark_overflow();
        }
        taps.clear();
    }

    /// Advance the compatibility byte cursor while `term` is held. Every
    /// canonical output path calls this even when there are no subscribers,
    /// so a later replay declares the exact boundary after all earlier bytes.
    fn advance_attach_sequence_locked(&self, byte_count: usize) -> Option<(u64, u64)> {
        if byte_count == 0 {
            let sequence = self.attach_sequence.load(Ordering::Acquire);
            return Some((sequence, sequence));
        }
        let byte_count = match u64::try_from(byte_count) {
            Ok(byte_count) => byte_count,
            Err(_) => {
                self.cancel_attach_taps_for_resnapshot();
                return None;
            }
        };
        match self.attach_sequence.fetch_update(Ordering::AcqRel, Ordering::Acquire, |sequence| {
            sequence.checked_add(byte_count)
        }) {
            Ok(start_sequence) => Some((start_sequence, start_sequence + byte_count)),
            Err(_) => {
                self.cancel_attach_taps_for_resnapshot();
                None
            }
        }
    }

    /// Start a new replay generation while `term` is held. A generation is
    /// published only together with the complete replay captured at its byte
    /// cursor boundary.
    fn advance_attach_generation_locked(&self) -> Option<(u64, u64)> {
        let generation = match self.attach_generation.fetch_update(
            Ordering::AcqRel,
            Ordering::Acquire,
            |generation| generation.checked_add(1),
        ) {
            Ok(previous) => previous + 1,
            Err(_) => {
                self.cancel_attach_taps_for_resnapshot();
                return None;
            }
        };
        let sequence = self.attach_sequence.load(Ordering::Acquire);
        Some((generation, sequence))
    }

    fn broadcast_attach_output(&self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        let Some((start_sequence, next_sequence)) =
            self.advance_attach_sequence_locked(bytes.len())
        else {
            return;
        };
        let mut taps = self.taps.lock().unwrap();
        if taps.is_empty() {
            return false;
        }
        let frame = AttachFrame::Output {
            surface_uuid: self.meta.uuid,
            runtime_epoch: self.semantic_identity.runtime_epoch,
            generation: self.attach_generation.load(Ordering::Acquire),
            start_sequence,
            next_sequence,
            data: bytes.to_vec(),
        };
        taps.retain(|tap| tap.try_send(frame.clone()));
        !taps.is_empty()
    }

    fn broadcast_attach_replay_locked(
        &self,
        term: &mut Terminal,
        cols: u16,
        rows: u16,
    ) -> ghostty_vt::Result<()> {
        let Some((generation, sequence)) = self.advance_attach_generation_locked() else {
            return Ok(());
        };
        let mut taps = self.taps.lock().unwrap();
        let mut replay_limits = Vec::new();
        for tap in taps.iter() {
            if !replay_limits.contains(&tap.replay_max_bytes) {
                replay_limits.push(tap.replay_max_bytes);
            }
        }
        let mut replays: Vec<(usize, Vec<u8>)> = Vec::new();
        for replay_max_bytes in replay_limits {
            if let Ok(replay) = term.vt_replay_bounded(replay_max_bytes) {
                replays.push((replay_max_bytes, replay));
            }
        }
        taps.retain(|tap| {
            let Some(replay) = replays
                .iter()
                .find(|(limit, _)| *limit == tap.replay_max_bytes)
                .map(|(_, replay)| replay)
            else {
                tap.lifecycle.mark_overflow();
                return false;
            };
            tap.try_send(AttachFrame::Resized {
                surface_uuid: self.meta.uuid,
                runtime_epoch: self.semantic_identity.runtime_epoch,
                generation,
                sequence,
                cols,
                rows,
                replay: replay.clone(),
            })
        });
        Ok(())
    }

    /// Replace every byte-stream mirror after a sidecar-only state change.
    /// Limit eviction has no PTY bytes, so continuing the old stream without
    /// this replay would leave mirrors on a different Kitty scene.
    fn resynchronize_attach_taps_locked(&self, term: &mut Terminal) {
        {
            let mut taps = self.taps.lock().unwrap();
            taps.retain(|tap| !tap.lifecycle.is_canceled());
            if taps.is_empty() {
                return;
            }
        }
        let replay = match term.vt_replay_bounded(VT_REPLAY_MAX_BYTES) {
            Ok(replay) => replay,
            Err(_) => {
                let mut taps = self.taps.lock().unwrap();
                for tap in &*taps {
                    tap.lifecycle.cancel();
                }
                taps.clear();
                return;
            }
        };
        let defaults = self.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let colors = Box::new(self.terminal_colors_locked(term, defaults));
        self.attach_colors_pending.store(false, Ordering::Release);
        self.attach_colors_force_pending.store(false, Ordering::Release);
        *self.last_attach_colors.lock().unwrap() =
            Some(Box::new(TerminalColors::from_pty_output(term, defaults)));
        self.broadcast_attach_frame(AttachFrame::ResizedWithColors {
            cols: term.cols(),
            rows: term.rows(),
            replay: replay.bytes.into(),
            kitty_image_aliases: replay.kitty_image_aliases,
            kitty_state: replay.kitty_state,
            colors,
        });
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

        let live_colors = TerminalColors::from_pty_output(term, defaults);
        let mut last = self.last_attach_colors.lock().unwrap();
        if !force && last.as_deref() == Some(&live_colors) {
            return false;
        }
        *last = Some(Box::new(live_colors));
        drop(last);
        let colors =
            if force { TerminalColors::from_terminal(term, defaults) } else { live_colors };
        self.broadcast_attach_frame(AttachFrame::ColorsChanged(Arc::new(colors)));
        true
    }

    fn request_frame(&self, generation: u64) {
        match self.frame_requests.try_send(generation) {
            Ok(()) | Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {}
        }
    }

    /// Publish the last PTY generation before the mux drops this surface.
    ///
    /// A normal frame request may still be waiting for the cadence deadline,
    /// and the frame worker holds only a weak reference. Building here keeps
    /// the final render frame ordered after the byte taps and before detach.
    fn publish_final_frame(&self) {
        let mut term = self.term.lock().unwrap();
        let generation = self.render_generation.load(Ordering::Acquire);
        let _ = self.build_frame_locked(&mut term, generation, true);
    }

    /// Preserve the last hosted frame, then end every live attachment while
    /// retaining the exited surface as a stable, snapshot-renderable tab.
    fn finish_hosted_exit(&self) {
        let mut term = self.term.lock().unwrap();
        if self.dead.swap(true, Ordering::AcqRel) {
            return;
        }
        let generation = self.render_generation.load(Ordering::Acquire);
        let _ = self.build_frame_locked(&mut term, generation, true);
        self.taps.lock().unwrap().clear();
        self.render.lock().unwrap().taps.clear();
    }

    fn mark_output_dirty(&self) {
        if !self.dirty.swap(true, Ordering::AcqRel)
            && let Some(mux) = self.mux.upgrade()
        {
            mux.emit_terminal_output(self.event_surface_id);
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
                    content_generation: generation,
                    scrollback_rows: term.history_rows(),
                    history_epoch: term.history_epoch(),
                    pointer_semantics: term.pointer_semantic_snapshot(),
                    palette_colors,
                    palette_overridden,
                });
                if render
                    .initial_graphics
                    .as_ref()
                    .is_some_and(|cached| !Arc::ptr_eq(&cached.source, &frame.frame.kitty_graphics))
                {
                    render.initial_graphics = None;
                }
                render.built_generation = generation;
                render.latest = Some(frame.clone());
                render.taps.retain(|tap| tap.send(RenderAttachFrame::Frame(frame.clone())));
                true
            }
        };

        if producer_driven {
            self.mark_output_dirty();
        }
        Ok(built || semantic_work)
    }

    /// Resize both the PTY and the terminal state. Returns whether the
    /// final clamped size actually changed.
    fn resize(&self, cols: u16, rows: u16) -> bool {
        if let Some(external) = &self.external {
            let _operation = external.operation.lock().unwrap();
            return self.resize_under_external_operation(cols, rows);
        }
        self.resize_under_external_operation(cols, rows)
    }

    fn resize_under_external_operation(&self, cols: u16, rows: u16) -> bool {
        let (cols, rows) = (cols.max(1), rows.max(1));
        let mut geometry = self.geometry.lock().unwrap();
        let next = PtyGeometry { cols, rows, ..*geometry };
        next.pty_size()?;
        #[cfg(unix)]
        {
            let runtime = self.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                if *geometry == next && host.viewer_size() == Some((cols, rows)) {
                    return Ok(false);
                }
                // Do not speculatively reflow the mirror. The host orders
                // either a compact smart-renderer marker or a legacy
                // Resized+Colors replay on its authoritative byte stream.
                return Ok(host.send_viewer_size(cols, rows).is_ok());
            }
            if matches!(&*runtime, PtyRuntime::ExitedHosted) {
                return Ok(false);
            }
        }
        self.commit_geometry(&mut geometry, next, true)
    }

    fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) -> anyhow::Result<bool> {
        self.set_cell_pixel_size_until(width_px, height_px, None)
    }

    fn set_cell_pixel_size_until(
        &self,
        width_px: u16,
        height_px: u16,
        deadline: Option<Instant>,
    ) -> anyhow::Result<bool> {
        #[cfg(test)]
        self.run_geometry_test_hook(PtyGeometryTestStep::CellPixelStarted);
        let requested = (width_px.max(1), height_px.max(1));
        {
            let geometry = self.geometry.lock().unwrap();
            if (geometry.cell_width, geometry.cell_height) == requested {
                return Ok(false);
            }
            PtyGeometry { cell_width: requested.0, cell_height: requested.1, ..*geometry }
                .pty_size()?;
        }
        #[cfg(unix)]
        {
            let runtime = self.runtime.lock().unwrap();
            match &*runtime {
                PtyRuntime::Hosted(host) => {
                    let accepted = match deadline {
                        Some(deadline) => {
                            host.send_cell_pixel_size_until(requested.0, requested.1, deadline)?
                        }
                        None => host.send_cell_pixel_size(requested.0, requested.1)?,
                    };
                    if !accepted {
                        return Ok(false);
                    }
                    drop(runtime);
                    // The host publishes Resized+Colors before its targeted
                    // acknowledgement. The reader therefore installs the
                    // canonical parser and metrics before this wait returns.
                    let geometry = self.geometry.lock().unwrap();
                    if (geometry.cell_width, geometry.cell_height) != requested {
                        drop(geometry);
                        if let PtyRuntime::Hosted(host) = &*self.runtime.lock().unwrap() {
                            host.disconnect();
                        }
                        anyhow::bail!(
                            "terminal host acknowledged cell metrics without publishing \
                             the canonical geometry transition"
                        );
                    }
                    return Ok(true);
                }
                PtyRuntime::ExitedHosted => return Ok(false),
                PtyRuntime::Local { .. } => {}
            }
        }
        let mut geometry = self.geometry.lock().unwrap();
        let next = PtyGeometry { cell_width: requested.0, cell_height: requested.1, ..*geometry };
        next.pty_size()?;
        self.commit_geometry(&mut geometry, next, false)
    }

    /// Commit the PTY ioctl or hosted mirror metrics, Ghostty geometry, and
    /// the published logical tuple while holding one geometry transaction.
    fn commit_geometry(
        &self,
        geometry: &mut PtyGeometry,
        next: PtyGeometry,
        refresh_attach_colors: bool,
    ) -> anyhow::Result<bool> {
        self.commit_geometry_for_runtime(geometry, next, refresh_attach_colors, false)
    }

    #[cfg(unix)]
    fn commit_hosted_geometry(
        &self,
        geometry: &mut PtyGeometry,
        next: PtyGeometry,
        refresh_attach_colors: bool,
    ) -> anyhow::Result<bool> {
        // The authoritative host has already resized its PTY. Avoid taking
        // the attachment lock while applying its ordered mirror transition:
        // a control caller can be holding that lock while it waits for the
        // acknowledgement queued immediately after this frame.
        self.commit_geometry_for_runtime(geometry, next, refresh_attach_colors, true)
    }

    fn commit_geometry_for_runtime(
        &self,
        geometry: &mut PtyGeometry,
        next: PtyGeometry,
        refresh_attach_colors: bool,
        hosted_mirror: bool,
    ) -> anyhow::Result<bool> {
        if *geometry == next {
            return Ok(false);
        }
        let previous = *geometry;
        let next_pty_size = next.pty_size()?;
        let previous_pty_size = previous.pty_size()?;
        // Hold the terminal lock while resizing and while sending the attach
        // marker, so mirrors observe bytes and geometry in server order.
        let mut term = self.term.lock().unwrap();
        let runtime = (!hosted_mirror).then(|| self.runtime.lock().unwrap());
        let master = match runtime.as_deref() {
            Some(PtyRuntime::Local { master, .. }) => Some(master.as_ref()),
            #[cfg(unix)]
            Some(PtyRuntime::Hosted(_)) => None,
            #[cfg(unix)]
            Some(PtyRuntime::ExitedHosted) => return Ok(false),
            None => None,
        };
        let mut has_attach_taps = {
            let mut taps = self.taps.lock().unwrap();
            taps.retain(|tap| !tap.lifecycle.is_canceled());
            !taps.is_empty()
        };
        // A replacement replay cannot represent a parser that is between
        // UTF-8 bytes or escape-sequence states. Smart mirrors resize in
        // place, while compatibility mirrors reconnect from a fresh safe
        // snapshot instead of consuming a corrupt replay.
        if has_attach_taps && !term.vt_stream_is_ground() {
            let mut taps = self.taps.lock().unwrap();
            for tap in taps.drain(..) {
                tap.lifecycle.cancel();
            }
            has_attach_taps = false;
        }
        // The only replay state that cannot be bounded by dropping old text
        // and completed graphics is an oversized in-flight Kitty upload.
        // Reject it before resize mutates Ghostty's reflow and scrollback.
        if has_attach_taps {
            term.preflight_vt_replay_bounded(VT_REPLAY_MAX_BYTES).map_err(|error| {
                anyhow::anyhow!(
                    "could not preflight attach replay before resizing PTY surface to {}x{} at \
                     {}x{} px per cell: {error}; geometry unchanged",
                    next.cols,
                    next.rows,
                    next.cell_width,
                    next.cell_height
                )
            })?;
        }
        if let Some(master) = master {
            master.resize(next_pty_size).map_err(|error| {
                anyhow::anyhow!(
                    "could not resize PTY master to {}x{} at {}x{} px per cell: {error}",
                    next.cols,
                    next.rows,
                    next.cell_width,
                    next.cell_height
                )
            })?;
        }
        if let Err(error) = term.resize(
            next.cols,
            next.rows,
            u32::from(next.cell_width),
            u32::from(next.cell_height),
        ) {
            let rollback = master.map_or(Ok(()), |master| master.resize(previous_pty_size));
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
        let replay = if has_attach_taps {
            #[cfg(test)]
            self.vt_replay_builds.fetch_add(1, Ordering::AcqRel);
            match term.vt_replay_bounded(VT_REPLAY_MAX_BYTES) {
                Ok(replay) => Some(replay),
                Err(_) => {
                    // Budget failure was already ruled out under this same
                    // terminal lock. A formatter/backend failure must not be
                    // answered with a destructive inverse resize. Disconnect
                    // byte mirrors so they reattach from fresh state.
                    let mut taps = self.taps.lock().unwrap();
                    for tap in &*taps {
                        tap.lifecycle.cancel();
                    }
                    taps.clear();
                    None
                }
            }
        } else {
            None
        };
        drop(runtime);
        *geometry = next;
        #[cfg(test)]
        self.run_geometry_test_hook(if refresh_attach_colors {
            PtyGeometryTestStep::ResizeCommitBoundary
        } else {
            PtyGeometryTestStep::CellPixelCommitBoundary
        });
        // Nominal cell metrics; only pixel size reports observe these.
        let suppress_reflow = self
            .external
            .as_ref()
            .is_some_and(|external| external.no_reflow.load(Ordering::Acquire));
        let restore_wraparound = suppress_reflow && term.mode(7, false);
        if restore_wraparound {
            let _ = term.set_mode(7, false, false);
        }
        let _ = term.resize(cols, rows, 8, 16);
        if restore_wraparound {
            let _ = term.set_mode(7, false, true);
        }
        let _ = self.refresh_active_search_locked(&mut term);
        let _ = self.broadcast_attach_replay_locked(&mut term, cols, rows);
        self.accessibility_viewport_revision.fetch_add(1, Ordering::AcqRel);
        let generation = self.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
        let _ = self.build_frame_locked(&mut term, generation, false);
        if let Some(replay) = replay {
            let defaults = self.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
            let colors = Box::new(self.terminal_colors_locked(&term, defaults));
            if refresh_attach_colors {
                let live_colors = TerminalColors::from_pty_output(&term, defaults);
                self.attach_colors_pending.store(false, Ordering::Release);
                self.attach_colors_force_pending.store(false, Ordering::Release);
                *self.last_attach_colors.lock().unwrap() = Some(Box::new(live_colors));
            }
            self.broadcast_attach_frame(AttachFrame::ResizedWithColors {
                cols: next.cols,
                rows: next.rows,
                replay: replay.bytes.into(),
                kitty_image_aliases: replay.kitty_image_aliases,
                kitty_state: replay.kitty_state,
                colors,
            });
        }
        self.stream_progress.notify();
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
    ReconnectBackoffStarted,
}

fn terminal_color_override_full_state(next: &TerminalColorOverrides) -> Vec<u8> {
    let mut output = if next.cursor_visual.is_some() { b"\x1b[0 q".to_vec() } else { Vec::new() };
    output.extend_from_slice(&terminal_color_override_delta(&Default::default(), next));
    output
}

/// Apply one complete terminal-host Colors state to a local libghostty parser.
/// Snapshot replay intentionally leaves embedder defaults local while this
/// helper restores application-authored dynamic colors, palette entries, and
/// cursor semantics at the advertised sequence boundary.
pub fn apply_terminal_color_overrides(terminal: &mut Terminal, colors: &TerminalColorOverrides) {
    let transition = terminal_color_override_full_state(colors);
    if !transition.is_empty() {
        terminal.vt_write(&transition);
    }
}

fn terminal_color_overrides_match_applied(
    mut observed: TerminalColorOverrides,
    applied: &TerminalColorOverrides,
) -> bool {
    // Version 1 has no cursor metadata. Its cursor state is carried only by
    // ordinary VT output, so it must not trip the sparse-color iff contract.
    if applied.cursor_visual.is_none() {
        observed.cursor_visual = None;
    }
    observed == *applied
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
    // Version 1 has no cursor metadata, so absence means unknown/preserve for
    // live deltas. Every v2 pair is force-applied even when byte-identical:
    // cursor activity may have switched/reset per-screen storage in between.
    if let Some(cursor_visual) = next.cursor_visual {
        let value = match cursor_visual {
            (CursorShape::Block | CursorShape::BlockHollow, true) => 1,
            (CursorShape::Block | CursorShape::BlockHollow, false) => 2,
            (CursorShape::Underline, true) => 3,
            (CursorShape::Underline, false) => 4,
            (CursorShape::Bar, true) => 5,
            (CursorShape::Bar, false) => 6,
        };
        output.extend_from_slice(format!("\x1b[{value} q").as_bytes());
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
const MOUSE_SELECTION_AUTOSCROLL_CADENCE: Duration = Duration::from_millis(50);
const SYNCHRONIZED_OUTPUT_SAFETY_TIMEOUT: Duration = Duration::from_secs(1);
const SYNCHRONIZED_OUTPUT_MODE: u16 = 2026;

fn spawn_frame_producer(surface: &Arc<Surface>, requests: Receiver<u64>) -> anyhow::Result<()> {
    let weak = Arc::downgrade(surface);
    let id = surface.id;
    #[cfg(test)]
    let before_upgrade = surface
        .as_pty()
        .expect("frame producer got non-pty surface")
        .frame_producer_before_upgrade
        .clone();
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
    render.taps.retain(|tap| tap.send(RenderAttachFrame::ScrollChanged { offset, at_bottom }));
}

fn terminal_scroll_position(term: &Terminal) -> (u64, bool) {
    match term.scrollbar() {
        Some(scrollbar) => (scrollbar.offset, !scrollbar.scrolled_back()),
        None => (0, true),
    }
}

fn set_terminal_scroll_offset(term: &mut Terminal, target: u64) -> bool {
    let Some(scrollbar) = term.scrollbar() else { return target == 0 };
    let bottom = scrollbar.total.saturating_sub(scrollbar.len);
    let target = target.min(bottom);
    if target == bottom {
        term.scroll_to_bottom();
        return term.scrollbar().is_some_and(|scrollbar| scrollbar.offset == target);
    }
    let mut current = scrollbar.offset;
    let mut remaining = current.abs_diff(target);
    while current != target {
        let difference = i128::from(target) - i128::from(current);
        let step = difference.clamp(isize::MIN as i128, isize::MAX as i128) as isize;
        term.scroll_delta(step);
        let Some(next) = term.scrollbar().map(|scrollbar| scrollbar.offset) else { return false };
        let next_remaining = next.abs_diff(target);
        if next_remaining >= remaining {
            return false;
        }
        current = next;
        remaining = next_remaining;
    }
    true
}

#[cfg(test)]
mod tests {
    use base64::Engine as _;

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

    fn attach_output_frame(data: Vec<u8>, start_sequence: u64) -> AttachFrame {
        let next_sequence = start_sequence + u64::try_from(data.len()).unwrap();
        AttachFrame::Output {
            surface_uuid: crate::SurfaceUuid::new(),
            runtime_epoch: 1,
            generation: 1,
            start_sequence,
            next_sequence,
            data,
        }
    }

    fn replay_text(attach: &AttachStream) -> String {
        let mut mirror =
            Terminal::new(attach.cols, attach.rows, 100, Callbacks::default()).unwrap();
        mirror.vt_write(&attach.replay);
        mirror.plain_text().unwrap()
    }

    #[test]
    fn compatibility_attach_snapshot_boundary_and_live_cursors_are_gapless() {
        let mux = Mux::new_for_test("attach-cursor", SurfaceOptions::default());
        let surface_uuid = crate::SurfaceUuid::new();
        let surface = Surface::spawn_for_test_with_uuid(
            1,
            surface_uuid,
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
        )
        .unwrap();
        surface.inject_terminal_output(b"before").unwrap();

        let attach = surface.attach_stream().unwrap();
        assert_eq!(attach.surface_uuid, surface_uuid);
        assert_eq!(
            attach.runtime_epoch,
            surface.semantic_scene_terminal_identity().unwrap().runtime_epoch
        );
        assert_eq!(attach.generation, 1);
        assert_eq!(attach.sequence, 6);
        assert!(replay_text(&attach).contains("before"));

        surface.inject_terminal_output(b"A").unwrap();
        surface.inject_terminal_output(b"BC").unwrap();
        let first = attach.stream.recv_timeout(Duration::from_secs(1)).unwrap();
        let second = attach.stream.recv_timeout(Duration::from_secs(1)).unwrap();
        let assert_output =
            |frame: AttachFrame, expected_start: u64, expected_next: u64, expected_data: &[u8]| {
                let AttachFrame::Output {
                    surface_uuid: frame_uuid,
                    runtime_epoch,
                    generation,
                    start_sequence,
                    next_sequence,
                    data,
                } = frame
                else {
                    panic!("expected output frame");
                };
                assert_eq!(frame_uuid, surface_uuid);
                assert_eq!(runtime_epoch, attach.runtime_epoch);
                assert_eq!(generation, attach.generation);
                assert_eq!(start_sequence, expected_start);
                assert_eq!(next_sequence, expected_next);
                assert_eq!(data, expected_data);
            };
        assert_output(first, attach.sequence, attach.sequence + 1, b"A");
        assert_output(second, attach.sequence + 1, attach.sequence + 3, b"BC");
    }

    #[test]
    fn compatibility_resize_starts_new_generation_at_complete_replay_boundary() {
        let mux = Mux::new_for_test("attach-resize-generation", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attach = surface.attach_stream().unwrap();

        surface.inject_terminal_output(b"x").unwrap();
        let output = attach.stream.recv_timeout(Duration::from_secs(1)).unwrap();
        let AttachFrame::Output { next_sequence, generation, .. } = output else {
            panic!("expected output before resize");
        };
        assert_eq!(generation, attach.generation);
        assert_eq!(next_sequence, attach.sequence + 1);

        assert!(surface.resize(100, 30).unwrap());
        let resized = attach.stream.recv_timeout(Duration::from_secs(1)).unwrap();
        let AttachFrame::Resized {
            surface_uuid,
            runtime_epoch,
            generation,
            sequence,
            cols,
            rows,
            replay,
        } = resized
        else {
            panic!("expected resize replay");
        };
        assert_eq!(surface_uuid, attach.surface_uuid);
        assert_eq!(runtime_epoch, attach.runtime_epoch);
        assert_eq!(generation, attach.generation + 1);
        assert_eq!(sequence, next_sequence);
        assert_eq!((cols, rows), (100, 30));
        assert!(!replay.is_empty());

        surface.inject_terminal_output(b"y").unwrap();
        let output = attach.stream.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            output,
            AttachFrame::Output {
                generation: output_generation,
                start_sequence,
                next_sequence: output_next,
                data,
                ..
            } if output_generation == generation
                && start_sequence == sequence
                && output_next == sequence + 1
                && data == b"y"
        ));
    }

    #[test]
    fn compatibility_resize_respects_each_tap_replay_limit() {
        let mux = Mux::new_for_test("attach-resize-per-tap-limit", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let small_lifecycle = AttachLifecycle::default();
        let small = surface
            .attach_stream_with_lifecycle_and_replay_limit(small_lifecycle.clone(), 64)
            .unwrap();
        let large = surface.attach_stream().unwrap();
        let output = (0..1_000)
            .map(|index| {
                format!(
                    "\u{1b}[38;2;{};{};{}m{:04X}",
                    index % 251,
                    (index * 17) % 251,
                    (index * 47) % 251,
                    index
                )
            })
            .collect::<String>()
            .into_bytes();

        surface.inject_terminal_output(&output).unwrap();
        assert!(matches!(
            small.stream.recv_timeout(Duration::from_secs(1)).unwrap(),
            AttachFrame::Output { .. }
        ));
        assert!(matches!(
            large.stream.recv_timeout(Duration::from_secs(1)).unwrap(),
            AttachFrame::Output { .. }
        ));
        assert!(surface.resize(100, 30).unwrap());
        let AttachFrame::Resized { replay: small_replay, .. } =
            small.stream.recv_timeout(Duration::from_secs(1)).unwrap()
        else {
            panic!("expected bounded resize replay");
        };
        let AttachFrame::Resized { replay: large_replay, .. } =
            large.stream.recv_timeout(Duration::from_secs(1)).unwrap()
        else {
            panic!("expected default resize replay");
        };
        assert!(small_replay.len() <= 64);
        assert!(large_replay.len() > small_replay.len());
        assert!(!small_lifecycle.is_canceled());
    }

    #[test]
    fn compatibility_external_reset_advances_seed_cursor_and_generation() {
        let surface = Surface::spawn_external_with_uuid(
            1,
            crate::SurfaceUuid::new(),
            SurfaceOptions::default(),
            true,
            Weak::new(),
        )
        .unwrap();
        let owner = external_owner(41);
        let claim = surface.claim_external_terminal(owner, uuid::Uuid::new_v4()).unwrap();
        let attach = surface.attach_stream().unwrap();
        let seed = b"remote-seed";

        surface
            .reset_external_terminal(
                owner,
                claim.owner_generation,
                uuid::Uuid::new_v4(),
                claim.required_output_generation,
                90,
                25,
                true,
                seed,
            )
            .unwrap();
        let frame = attach.stream.recv_timeout(Duration::from_secs(1)).unwrap();
        let AttachFrame::Resized {
            surface_uuid,
            runtime_epoch,
            generation,
            sequence,
            cols,
            rows,
            replay,
        } = frame
        else {
            panic!("expected external reset replay");
        };
        assert_eq!(surface_uuid, attach.surface_uuid);
        assert_eq!(runtime_epoch, attach.runtime_epoch);
        assert_eq!(generation, attach.generation + 1);
        assert_eq!(sequence, attach.sequence + seed.len() as u64);
        assert_eq!((cols, rows), (90, 25));
        let mut mirror = Terminal::new(cols, rows, 100, Callbacks::default()).unwrap();
        mirror.vt_write(&replay);
        assert!(mirror.plain_text().unwrap().contains("remote-seed"));
    }

    #[test]
    fn compatibility_respawn_keeps_surface_uuid_and_changes_runtime_epoch() {
        let mux = Mux::new_for_test("attach-respawn-epoch", SurfaceOptions::default());
        let surface_uuid = crate::SurfaceUuid::new();
        let first = Surface::spawn_for_test_with_uuid(
            1,
            surface_uuid,
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
        )
        .unwrap();
        let replacement = Surface::spawn_for_test_with_uuid(
            1,
            surface_uuid,
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
        )
        .unwrap();
        let before = first.attach_stream().unwrap();
        let after = replacement.attach_stream().unwrap();

        assert_eq!(before.surface_uuid, surface_uuid);
        assert_eq!(after.surface_uuid, surface_uuid);
        assert_ne!(before.runtime_epoch, after.runtime_epoch);
        assert_eq!((before.generation, before.sequence), (1, 0));
        assert_eq!((after.generation, after.sequence), (1, 0));

        first.inject_terminal_output(b"late-old-runtime").unwrap();
        let stale = before.stream.recv_timeout(Duration::from_secs(1)).unwrap();
        let AttachFrame::Output { surface_uuid: stale_uuid, runtime_epoch: stale_epoch, .. } =
            stale
        else {
            panic!("expected stale-runtime output");
        };
        assert_eq!(stale_uuid, after.surface_uuid);
        assert_ne!(
            stale_epoch, after.runtime_epoch,
            "the replacement client must reject a late frame from the old runtime"
        );
    }

    #[test]
    fn compatibility_overflow_ends_at_accepted_prefix_and_reattach_resnapshots_gap() {
        let mux = Mux::new_for_test("attach-overflow-gap", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();
        let lifecycle = AttachLifecycle::default();
        let (sender, receiver) = sync_channel(4);
        let queued_bytes = Arc::new(AtomicUsize::new(0));
        let one_frame_bytes = attach_output_frame(vec![b'a'], 0).retained_bytes();
        pty.taps.lock().unwrap().push(AttachTap {
            sender,
            lifecycle: lifecycle.clone(),
            queued_bytes,
            max_queued_bytes: one_frame_bytes,
            replay_max_bytes: VT_REPLAY_MAX_BYTES,
        });

        surface.inject_terminal_output(b"a").unwrap();
        surface.inject_terminal_output(b"b").unwrap();
        let accepted = receiver.recv_timeout(Duration::from_secs(1)).unwrap();
        let AttachFrame::Output { start_sequence, next_sequence, data, .. } = accepted else {
            panic!("expected accepted output prefix");
        };
        assert_eq!((start_sequence, next_sequence, data), (0, 1, vec![b'a']));
        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(1)),
            Err(RecvTimeoutError::Disconnected)
        ));
        assert!(lifecycle.is_canceled());
        assert!(lifecycle.overflowed());

        let replacement = surface.attach_stream().unwrap();
        assert_eq!(replacement.sequence, 2);
        assert!(replacement.sequence > next_sequence, "lost suffix must be detectable");
        assert!(replay_text(&replacement).contains("ab"));
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
                true,
                b"seed",
            )
            .unwrap();
        assert_eq!(reset.next_sequence, 1);
        assert!(reset.no_reflow);

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
                false,
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
            replay_max_bytes: VT_REPLAY_MAX_BYTES,
        };

        assert!(tap.try_send(attach_output_frame(vec![1], 0)));
        assert!(!tap.try_send(attach_output_frame(vec![2], 1)));
        assert!(lifecycle.is_canceled());
        assert!(lifecycle.overflowed());
        assert!(lifecycle.claim_overflow_report());
        assert!(!lifecycle.claim_overflow_report());
    }

    #[test]
    fn attach_tap_overflow_is_bounded_by_retained_bytes() {
        let lifecycle = AttachLifecycle::default();
        let (sender, _receiver) = sync_channel(4);
        let frame_bytes = attach_output_frame(vec![1], 0).retained_bytes();
        let tap = AttachTap {
            sender,
            lifecycle: lifecycle.clone(),
            queued_bytes: Arc::new(AtomicUsize::new(0)),
            max_queued_bytes: frame_bytes,
            replay_max_bytes: VT_REPLAY_MAX_BYTES,
        };

        assert!(tap.try_send(attach_output_frame(vec![1], 0)));
        assert!(!tap.try_send(attach_output_frame(vec![2], 1)));
        assert!(lifecycle.overflowed());
    }

    #[test]
    fn adjacent_output_merge_respects_the_exact_retained_budget() {
        let mut bytes = Vec::with_capacity(1_024);
        bytes.resize(1_024, 1);
        let mut frame = AttachFrame::Output(bytes);
        let max_retained_bytes = size_of::<AttachFrame>() + 1_025;

        assert!(matches!(
            frame.merge_adjacent_output(AttachFrame::Output(vec![2]), max_retained_bytes),
            AttachFrameMerge::Merged
        ));
        let AttachFrame::Output(merged) = frame else { unreachable!() };
        assert_eq!(merged.len(), 1_025);
        assert!(merged.capacity() <= 1_025);

        let mut full = AttachFrame::Output(merged);
        assert!(matches!(
            full.merge_adjacent_output(AttachFrame::Output(vec![3]), max_retained_bytes),
            AttachFrameMerge::Overflow
        ));
        let AttachFrame::Output(full) = full else { unreachable!() };
        assert_eq!(full.len(), 1_025, "overflow must not append rejected bytes");
    }

    #[test]
    fn slow_attach_coalesces_adjacent_output_without_losing_bytes() {
        let mux = Mux::new_for_test("attach-output-coalescing", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attach = surface.attach_stream().unwrap();
        let pty = surface.as_pty().unwrap();
        let expected =
            (0..ATTACH_STREAM_CAPACITY * 4).map(|index| (index % 251) as u8).collect::<Vec<_>>();

        for (index, byte) in expected.iter().copied().enumerate() {
            assert!(
                pty.broadcast_attach_output(&[byte]),
                "lossless attach disconnected at small output chunk {index}"
            );
        }

        assert!(!attach.lifecycle.overflowed());
        let mut received = Vec::new();
        while let Ok(frame) = attach.stream.try_recv() {
            match frame {
                AttachFrame::Output(bytes) => received.extend(bytes),
                other => panic!("unexpected frame in output-only stream: {other:?}"),
            }
        }
        assert_eq!(received, expected);
    }

    #[test]
    fn resized_replay_payload_is_shared_across_attach_taps() {
        let mux = Mux::new("shared-resize-replay", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let first = surface.attach_stream().unwrap();
        let second = surface.attach_stream().unwrap();
        let pty = surface.as_pty().unwrap();

        pty.broadcast_attach_frame(AttachFrame::ResizedWithColors {
            cols: 80,
            rows: 24,
            replay: vec![7; 1024].into(),
            kitty_image_aliases: Vec::new(),
            kitty_state: KittyReplayState::disabled(),
            colors: Box::new(TerminalColors::default()),
        });

        let first_replay = match first.stream.recv_timeout(Duration::from_secs(1)).unwrap() {
            AttachFrame::ResizedWithColors { replay, .. } => replay,
            frame => panic!("unexpected first attach frame: {frame:?}"),
        };
        let second_replay = match second.stream.recv_timeout(Duration::from_secs(1)).unwrap() {
            AttachFrame::ResizedWithColors { replay, .. } => replay,
            frame => panic!("unexpected second attach frame: {frame:?}"),
        };
        assert_eq!(
            first_replay.as_ptr(),
            second_replay.as_ptr(),
            "resize replay bytes were deep-cloned for each attach subscriber"
        );
    }

    #[test]
    fn unsafe_legacy_resize_disconnects_the_byte_attachment() {
        let mux = Mux::new("legacy-resize-disconnect", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(73, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attachment = surface.attach_stream().unwrap();
        let pty = surface.as_pty().unwrap();
        pty.term.lock().unwrap().vt_write(b"partial \xce");
        assert!(!pty.term.lock().unwrap().vt_stream_is_ground());

        assert!(surface.resize(100, 30).unwrap());
        assert!(matches!(
            attachment.stream.recv_timeout(Duration::from_secs(1)),
            Err(RecvTimeoutError::Disconnected)
        ));
        assert!(attachment.lifecycle.is_canceled());
    }

    #[cfg(unix)]
    #[test]
    fn hosted_stager_exposes_coupled_state_only_after_colors() {
        let mut stager = HostedFrameStager::new(40, false);
        let mut resize = Frame::new(MessageKind::Resized, {
            let mut payload = Vec::from([101, 0, 37, 0]);
            payload.extend_from_slice(&(b"authoritative replay".len() as u32).to_le_bytes());
            payload.extend_from_slice(b"authoritative replay");
            payload.extend_from_slice(&0u16.to_le_bytes());
            payload.extend_from_slice(&9u16.to_le_bytes());
            payload.extend_from_slice(&18u16.to_le_bytes());
            append_disabled_kitty_replay_state(&mut payload);
            payload
        });
        resize.flags = FLAG_COLORS_FOLLOW;
        resize.sequence = 41;

        // A delayed Colors frame cannot expose a resize attach callback or a
        // renderable transition with the old theme.
        assert!(stager.push(resize).unwrap().is_none());

        let colors = TerminalColorOverrides {
            foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
            cursor_visual: Some((CursorShape::Bar, true)),
            ..Default::default()
        };
        let mut colors_frame = Frame::new(
            MessageKind::Colors,
            crate::terminal_host_runtime::encode_terminal_color_overrides(&colors),
        );
        colors_frame.sequence = 42;
        match stager.push(colors_frame).unwrap().unwrap() {
            HostedTransition::ResizedWithColors {
                cols,
                rows,
                cell_pixels,
                replay,
                kitty_image_aliases,
                colors: received,
                ..
            } => {
                assert_eq!((cols, rows), (101, 37));
                assert_eq!(cell_pixels, (9, 18));
                assert_eq!(replay, b"authoritative replay");
                assert!(kitty_image_aliases.is_empty());
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
    fn hosted_stager_excludes_resize_framing_and_aliases_from_vt_replay() {
        let replay = b"\x1b[2Jhost replay";
        let mut payload = Vec::from([101, 0, 37, 0]);
        payload.extend_from_slice(&(replay.len() as u32).to_le_bytes());
        payload.extend_from_slice(replay);
        payload.extend_from_slice(&1u16.to_le_bytes());
        payload.extend_from_slice(&41u32.to_le_bytes());
        payload.extend_from_slice(&77u32.to_le_bytes());
        payload.extend_from_slice(&9u16.to_le_bytes());
        payload.extend_from_slice(&18u16.to_le_bytes());
        append_disabled_kitty_replay_state(&mut payload);

        let mut stager = HostedFrameStager::new(8, false);
        let mut resize = Frame::new(MessageKind::Resized, payload);
        resize.flags = FLAG_COLORS_FOLLOW;
        resize.sequence = 9;
        assert!(stager.push(resize).unwrap().is_none());

        let colors = TerminalColorOverrides {
            cursor_visual: Some((CursorShape::Block, true)),
            ..Default::default()
        };
        let mut colors = Frame::new(
            MessageKind::Colors,
            crate::terminal_host_runtime::encode_terminal_color_overrides(&colors),
        );
        colors.sequence = 10;
        match stager.push(colors).unwrap().unwrap() {
            HostedTransition::ResizedWithColors {
                replay: received, kitty_image_aliases, ..
            } => {
                assert_eq!(
                    received, replay,
                    "resize length and alias metadata leaked into VT replay bytes"
                );
                assert_eq!(
                    kitty_image_aliases,
                    vec![ghostty_vt::KittyImageAlias { image_id: 41, image_number: 77 }]
                );
            }
            other => panic!("unexpected staged transition: {other:?}"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn hosted_stager_accepts_protocol_one_resize_without_alias_metadata() {
        let replay = b"legacy host replay";
        let mut payload = Vec::from([81, 0, 25, 0]);
        payload.extend_from_slice(&(replay.len() as u32).to_le_bytes());
        payload.extend_from_slice(replay);

        let mut stager = HostedFrameStager::new_for_version(0, 1, false);
        let mut resize = Frame::new(MessageKind::Resized, payload);
        resize.version = 1;
        resize.flags = FLAG_COLORS_FOLLOW;
        resize.sequence = 1;
        assert!(stager.push(resize).unwrap().is_none());

        let colors = TerminalColorOverrides {
            cursor_visual: Some((CursorShape::Block, true)),
            ..Default::default()
        };
        let mut colors = Frame::new(
            MessageKind::Colors,
            crate::terminal_host_runtime::encode_terminal_color_overrides(&colors),
        );
        colors.version = 1;
        colors.sequence = 2;
        match stager.push(colors).unwrap().unwrap() {
            HostedTransition::ResizedWithColors {
                cols,
                rows,
                replay: received,
                kitty_image_aliases,
                ..
            } => {
                assert_eq!((cols, rows), (81, 25));
                assert_eq!(received, replay);
                assert!(kitty_image_aliases.is_empty());
            }
            other => panic!("unexpected staged transition: {other:?}"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn smart_hosted_stager_orders_raw_output_and_incremental_resize() {
        let mut stager = HostedFrameStager::new(7, true);
        let mut prefix = Frame::new(MessageKind::Output, vec![0xce]);
        prefix.sequence = 8;
        assert!(matches!(
            stager.push(prefix).unwrap(),
            Some(HostedTransition::Output(bytes)) if bytes == vec![0xce]
        ));

        let mut resized = Frame::new(MessageKind::Resized, vec![100, 0, 30, 0]);
        resized.sequence = 9;
        assert!(matches!(
            stager.push(resized).unwrap(),
            Some(HostedTransition::Resized { cols: 100, rows: 30, cell_pixels: None })
        ));

        let mut metrics = Frame::new(MessageKind::Resized, vec![100, 0, 30, 0, 9, 0, 18, 0]);
        metrics.sequence = 10;
        assert!(matches!(
            stager.push(metrics).unwrap(),
            Some(HostedTransition::Resized { cols: 100, rows: 30, cell_pixels: Some((9, 18)) })
        ));

        let mut suffix = Frame::new(MessageKind::Output, vec![0xbb]);
        suffix.sequence = 11;
        assert!(matches!(
            stager.push(suffix).unwrap(),
            Some(HostedTransition::Output(bytes)) if bytes == vec![0xbb]
        ));
    }

    #[cfg(unix)]
    #[test]
    fn hosted_stager_decodes_authoritative_exit_payload() {
        let exit = TerminalExit {
            outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
            exited_at_ms: 1_234_567,
        };
        let mut frame = Frame::new(
            MessageKind::Exit,
            crate::terminal_host_protocol::encode_terminal_exit(&exit),
        );
        frame.sequence = 1;
        let mut stager = HostedFrameStager::new(0, false);
        match stager.push(frame).unwrap() {
            Some(HostedTransition::Exit(observed)) => assert_eq!(observed, exit),
            other => panic!("unexpected staged transition: {other:?}"),
        }

        let mut malformed = Frame::new(MessageKind::Exit, vec![1, 0, 2]);
        malformed.sequence = 1;
        assert!(HostedFrameStager::new(0, false).push(malformed).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn hosted_stager_fails_closed_on_invalid_flags_and_pairing() {
        let mut stager = HostedFrameStager::new(0, false);
        let mut resized = Frame::new(MessageKind::Resized, vec![80, 0, 24, 0]);
        resized.sequence = 1;
        assert!(stager.push(resized).is_err(), "Resized must declare Colors follow");

        let mut stager = HostedFrameStager::new(0, false);
        let mut output = Frame::new(MessageKind::Output, vec![]);
        output.flags = FLAG_COLORS_FOLLOW | (1 << 7);
        output.sequence = 1;
        assert!(stager.push(output).is_err(), "unknown flags must fail closed");

        let mut stager = HostedFrameStager::new(0, false);
        let mut output = Frame::new(MessageKind::Output, vec![]);
        output.flags = FLAG_COLORS_FOLLOW;
        output.sequence = 1;
        assert!(stager.push(output).unwrap().is_none());
        let mut exit = Frame::new(MessageKind::Exit, vec![]);
        exit.sequence = 2;
        assert!(stager.push(exit).is_err(), "a coupled frame requires Colors exactly next");

        let mut stager = HostedFrameStager::new(0, false);
        let mut malformed = Frame::new(MessageKind::Resized, {
            let mut payload = vec![80, 0, 24, 0, 0, 0, 0, 0];
            payload.extend_from_slice(&1u16.to_le_bytes());
            payload.extend_from_slice(&41u32.to_le_bytes());
            payload
        });
        malformed.flags = FLAG_COLORS_FOLLOW;
        malformed.sequence = 1;
        assert!(stager.push(malformed).is_err(), "truncated aliases must fail closed");
    }

    #[cfg(unix)]
    #[test]
    fn exited_host_placeholder_preserves_identity_and_rejects_input() {
        let mux = Mux::new_for_test("exited-host-placeholder", SurfaceOptions::default());
        let identity = crate::terminal_host_runtime::TerminalHostIdentity {
            terminal_id: crate::terminal_host::TerminalId::random().unwrap().to_hex(),
            incarnation: crate::terminal_host::HostIncarnation::random().unwrap().to_hex(),
        };
        let surface = Surface::exited_terminal_placeholder(
            91,
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
            identity.clone(),
        )
        .unwrap();

        assert_eq!(surface.terminal_host_identity(), Some(identity));
        assert_eq!(
            surface.terminal_host_connection_state(),
            Some(TerminalHostConnectionState::Exited)
        );
        assert!(surface.is_dead());
        assert_eq!(
            surface.write_bytes(b"must not reach a dead host").unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
    }

    #[test]
    fn terminal_reconnect_failure_state_never_decodes_as_connected() {
        assert_ne!(TerminalHostConnectionState::from_u8(3), TerminalHostConnectionState::Connected);
    }

    #[cfg(unix)]
    #[test]
    fn terminal_reconnect_backoff_advances_and_reaches_a_terminal_bound() {
        let mut backoff = TerminalHostReconnectBackoff::default();
        let delays = (0..TERMINAL_HOST_RECONNECT_MAX_FAILURES)
            .map(|_| backoff.next_delay().expect("retry within failure bound"))
            .collect::<Vec<_>>();

        assert_eq!(
            &delays[..7],
            &[
                Duration::from_millis(25),
                Duration::from_millis(50),
                Duration::from_millis(100),
                Duration::from_millis(200),
                Duration::from_millis(400),
                Duration::from_millis(800),
                Duration::from_secs(1),
            ]
        );
        assert!(delays[7..].iter().all(|delay| *delay == Duration::from_secs(1)));
        assert_eq!(backoff.next_delay(), None);
    }

    #[cfg(unix)]
    #[test]
    fn hosted_reconnect_backoff_releases_geometry_before_waiting() {
        let mux = Mux::new_for_test("reconnect-geometry-release", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();
        let (backoff_started_tx, backoff_started_rx) = std::sync::mpsc::channel();
        let (release_backoff_tx, release_backoff_rx) = std::sync::mpsc::channel();
        let release_backoff_rx = Arc::new(Mutex::new(release_backoff_rx));
        *pty.geometry_test_hook.lock().unwrap() = Some(Arc::new({
            move |step| {
                if step == PtyGeometryTestStep::ReconnectBackoffStarted {
                    backoff_started_tx.send(()).unwrap();
                    release_backoff_rx.lock().unwrap().recv().unwrap();
                }
            }
        }));

        let reconnect_surface = surface.clone();
        let reconnect = std::thread::spawn(move || {
            let pty = reconnect_surface.as_pty().unwrap();
            let geometry = pty.geometry.lock().unwrap();
            let mut retry = TerminalHostReconnectBackoff::default();
            wait_for_reconnect_after_geometry_failure(&mut retry, pty, geometry)
        });
        backoff_started_rx.recv().unwrap();

        let probing_surface = surface.clone();
        let (geometry_acquired_tx, geometry_acquired_rx) = std::sync::mpsc::channel();
        let geometry_probe = std::thread::spawn(move || {
            let size = probing_surface.test_cell_pixel_size();
            geometry_acquired_tx.send(size).unwrap();
        });
        let geometry_released_before_backoff =
            geometry_acquired_rx.recv_timeout(Duration::from_millis(100)).is_ok();

        release_backoff_tx.send(()).unwrap();
        assert!(reconnect.join().unwrap());
        geometry_probe.join().unwrap();
        assert!(
            geometry_released_before_backoff,
            "host reconnect backoff held the geometry transaction lock"
        );
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
