//! Surface runtime: one tab inside a pane.
//!
//! A surface is either a PTY backed by libghostty-vt state or a local CDP
//! browser surface. PTY-only methods stay available for existing callers;
//! browser-aware frontends should branch on [`SurfaceKind`] before using
//! VT operations.

use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::mem::size_of;
use std::ops::Deref;
use std::path::PathBuf;
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::mpsc::{
    Receiver, RecvError, RecvTimeoutError, SyncSender, TryRecvError, TrySendError, sync_channel,
};
use std::sync::{Arc, Condvar, Mutex, TryLockError, Weak};
use std::time::{Duration, Instant};

use cmux_pty::{ChildKiller, MasterPty, PtyCommand, PtySize};
use ghostty_vt::{
    Callbacks, ClearHistoryOutcome, CursorShape, Dirty, KeyEncoder, KeyInput, KittyGraphicsLimits,
    KittyReplayState, MouseEncoders, MouseInput, RenderFrame, RenderState, Rgb, Screen, Scrollbar,
    Terminal, TerminalColorOverrides, TerminalPointerSemanticSnapshot, TrackedScreenPoint,
};

use crate::mux::ResourceWaitWake;
use crate::platform;
use crate::resource::{ContentPublicId, TabResourceIdentity, TerminalPublicId};
use crate::terminal_host_protocol::{TerminalExit, wait_for_native_child_status};
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
    /// TERM value for children: the outer terminal's xterm-ghostty when it
    /// advertised that (see [`default_child_term`]), else the compatible
    /// xterm-256color. CMUX_TUI_TERM/CMUX_MUX_TERM override.
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

/// Default TERM for child shells.
///
/// `xterm-ghostty` when the OUTER terminal advertised it (this process's
/// own TERM), else the compatible `xterm-256color`. No terminfo probing:
/// a Ghostty session that sets TERM=xterm-ghostty also exports TERMINFO
/// pointing at its bundled database, and children inherit that variable
/// through cmux-tui untouched, so the entry resolves for them exactly as
/// it does for programs in the raw Ghostty pane. Children — local and
/// remote (ssh forwards TERM, not terminfo) — therefore see precisely the
/// TERM they would have seen without the multiplexer, never a less
/// compatible one, and TERM-name-sniffing prompts (oh-my-zsh themes
/// matching `*256color`) take the same branch inside cmux-tui as in raw
/// Ghostty, so colors match. Only xterm-ghostty passes through: the inner
/// terminal IS ghostty-vt, so that name is truthful regardless of which
/// client later attaches; any other outer TERM would misdescribe it.
/// Servers started outside a Ghostty session (launchd, ssh, cron) keep
/// xterm-256color. CMUX_TUI_TERM, CMUX_MUX_TERM, and --term override.
pub fn default_child_term() -> String {
    child_term_for(std::env::var("TERM").ok().as_deref()).into()
}

/// Pure selection rule for [`default_child_term`].
fn child_term_for(outer_term: Option<&str>) -> &'static str {
    if outer_term == Some("xterm-ghostty") { "xterm-ghostty" } else { "xterm-256color" }
}

impl Default for SurfaceOptions {
    fn default() -> Self {
        SurfaceOptions {
            command: None,
            cwd: None,
            term: std::env::var("CMUX_TUI_TERM")
                .or_else(|_| std::env::var("CMUX_MUX_TERM"))
                .unwrap_or_else(|_| default_child_term()),
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

impl TerminalColors {
    fn from_terminal(term: &Terminal, defaults: DefaultColors) -> Self {
        let (fg, bg, cursor) = term.effective_colors();
        let overrides = term.color_overrides();
        let cursor_visual = overrides.cursor_visual;
        TerminalColors {
            fg,
            bg,
            cursor,
            selection_bg: defaults.selection_bg,
            selection_fg: defaults.selection_fg,
            palette: overrides.palette,
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
        replay: Arc<[u8]>,
        kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
        kitty_state: KittyReplayState,
    },
    /// One parser transition: `replay` is theme-portable, so `colors` is part
    /// of the same replacement snapshot rather than a subsequent callback.
    ResizedWithColors {
        cols: u16,
        rows: u16,
        replay: Arc<[u8]>,
        kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
        kitty_state: KittyReplayState,
        colors: Box<TerminalColors>,
    },
    ColorsChanged(Arc<TerminalColors>),
}

/// A host frame is not actionable until its wire-level atomicity contract is
/// satisfied. In particular, a renderer must never expose output or a resize
/// whose authoritative color state is still sitting in the socket.
#[cfg(unix)]
#[derive(Debug)]
enum HostedTransition {
    Output(Vec<u8>),
    OutputWithColors {
        output: Vec<u8>,
        colors: TerminalColorOverrides,
    },
    Resized {
        cols: u16,
        rows: u16,
        cell_pixels: Option<(u16, u16)>,
    },
    ResizedWithColors {
        cols: u16,
        rows: u16,
        cell_pixels: (u16, u16),
        replay: Vec<u8>,
        kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
        kitty_state: KittyReplayState,
        colors: TerminalColorOverrides,
    },
    Metadata(MessageKind),
    Exit(TerminalExit),
    ResyncRequired,
}

#[cfg(unix)]
#[derive(Debug)]
enum PendingHostedTransition {
    Output(Vec<u8>),
    Resized {
        cols: u16,
        rows: u16,
        cell_pixels: (u16, u16),
        replay: Vec<u8>,
        kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
        kitty_state: KittyReplayState,
    },
}

#[cfg(unix)]
struct HostedFrameStager {
    protocol_version: u16,
    expected_sequence: u64,
    smart_renderer: bool,
    pending: Option<PendingHostedTransition>,
}

#[cfg(unix)]
impl HostedFrameStager {
    #[cfg(test)]
    fn new(sequence_boundary: u64, smart_renderer: bool) -> Self {
        Self::new_for_version(sequence_boundary, PROTOCOL_VERSION, smart_renderer)
    }

    fn new_for_version(
        sequence_boundary: u64,
        protocol_version: u16,
        smart_renderer: bool,
    ) -> Self {
        Self {
            protocol_version,
            expected_sequence: sequence_boundary.wrapping_add(1),
            smart_renderer,
            pending: None,
        }
    }

    fn push(&mut self, frame: Frame) -> Result<Option<HostedTransition>, &'static str> {
        if frame.version != self.protocol_version || frame.request_id != 0 {
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
                PendingHostedTransition::Resized {
                    cols,
                    rows,
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                } => HostedTransition::ResizedWithColors {
                    cols,
                    rows,
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                    colors,
                },
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
                let valid_smart =
                    self.smart_renderer && frame.flags == 0 && matches!(frame.payload.len(), 4 | 8);
                let valid_legacy = !self.smart_renderer
                    && frame.flags == FLAG_COLORS_FOLLOW
                    && frame.payload.len() >= 4
                    && frame.payload.len() - 4 <= VT_REPLAY_MAX_BYTES;
                if !valid_smart && !valid_legacy {
                    return Err("invalid Resized frame");
                }
                if valid_smart {
                    let cols = u16::from_le_bytes([frame.payload[0], frame.payload[1]]);
                    let rows = u16::from_le_bytes([frame.payload[2], frame.payload[3]]);
                    let (cols, rows) =
                        crate::terminal_host_runtime::normalize_terminal_geometry(cols, rows)
                            .map_err(|_| "invalid Resized geometry")?;
                    let cell_pixels = (frame.payload.len() == 8).then(|| {
                        (
                            u16::from_le_bytes([frame.payload[4], frame.payload[5]]).max(1),
                            u16::from_le_bytes([frame.payload[6], frame.payload[7]]).max(1),
                        )
                    });
                    return Ok(Some(HostedTransition::Resized { cols, rows, cell_pixels }));
                }
                let crate::terminal_host_runtime::DecodedHostResize {
                    cols,
                    rows,
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                } = crate::terminal_host_runtime::decode_host_resize_payload_for_version(
                    &frame.payload,
                    self.protocol_version,
                )
                .map_err(|_| "invalid Resized geometry")?;
                self.pending = Some(PendingHostedTransition::Resized {
                    cols,
                    rows,
                    cell_pixels,
                    replay,
                    kitty_image_aliases,
                    kitty_state,
                });
                Ok(None)
            }
            MessageKind::Title | MessageKind::Pwd | MessageKind::Bell if frame.flags == 0 => {
                Ok(Some(HostedTransition::Metadata(frame.kind)))
            }
            MessageKind::Exit if frame.flags == 0 => {
                let exit = if frame.payload.is_empty() {
                    TerminalExit::unknown("terminal host omitted exit status")
                } else {
                    decode_terminal_exit(&frame.payload).map_err(|_| "invalid Exit payload")?
                };
                Ok(Some(HostedTransition::Exit(exit)))
            }
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
                Self::Output(bytes) => bytes.capacity(),
                Self::Resized { replay, kitty_image_aliases, .. } => {
                    replay.len()
                        + kitty_image_aliases.capacity() * size_of::<ghostty_vt::KittyImageAlias>()
                }
                Self::OutputWithColors { output, .. } => {
                    output.capacity() + size_of::<TerminalColors>()
                }
                Self::ResizedWithColors { replay, kitty_image_aliases, .. } => {
                    replay.len()
                        + kitty_image_aliases.capacity() * size_of::<ghostty_vt::KittyImageAlias>()
                        + size_of::<TerminalColors>()
                }
                Self::ColorsChanged(_) => size_of::<TerminalColors>(),
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
}

struct AttachTapState {
    queue: Mutex<AttachTapQueue>,
    ready: Condvar,
}

struct AttachTapQueue {
    frames: VecDeque<AttachFrame>,
    retained_bytes: usize,
    max_frames: usize,
    max_retained_bytes: usize,
    sender_alive: bool,
    receiver_alive: bool,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TerminalHostConnectionState {
    Connected = 0,
    Reconnecting = 1,
    Exited = 2,
    Failed = 3,
}

impl TerminalHostConnectionState {
    fn from_u8(value: u8) -> Self {
        match value {
            1 => Self::Reconnecting,
            2 => Self::Exited,
            3 => Self::Failed,
            _ => Self::Connected,
        }
    }
}

#[cfg(unix)]
const TERMINAL_HOST_RECONNECT_MAX_FAILURES: u8 = 16;
#[cfg(unix)]
const TERMINAL_HOST_RECONNECT_MAX_DELAY: Duration = Duration::from_secs(1);

#[cfg(unix)]
#[derive(Default)]
struct TerminalHostReconnectBackoff {
    failures: u8,
}

#[cfg(unix)]
impl TerminalHostReconnectBackoff {
    fn next_delay(&mut self) -> Option<Duration> {
        if self.failures >= TERMINAL_HOST_RECONNECT_MAX_FAILURES {
            return None;
        }
        let multiplier = 1_u32 << self.failures.min(6);
        self.failures += 1;
        Some((Duration::from_millis(25) * multiplier).min(TERMINAL_HOST_RECONNECT_MAX_DELAY))
    }

    fn wait_or_fail(&mut self, pty: &PtySurface) -> bool {
        let Some(delay) = self.next_delay() else {
            pty.host_connection_state
                .store(TerminalHostConnectionState::Failed as u8, Ordering::Release);
            if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                host.disconnect();
            }
            return false;
        };
        #[cfg(test)]
        pty.run_geometry_test_hook(PtyGeometryTestStep::ReconnectBackoffStarted);
        std::thread::sleep(delay);
        true
    }
}

#[cfg(unix)]
fn wait_for_reconnect_after_geometry_failure(
    retry: &mut TerminalHostReconnectBackoff,
    pty: &PtySurface,
    geometry: std::sync::MutexGuard<'_, PtyGeometry>,
) -> bool {
    drop(geometry);
    retry.wait_or_fail(pty)
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
    /// Public tab/content identities. Auxiliary surfaces, including sidebar
    /// runtimes, deliberately carry no tab identity.
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

pub(crate) struct TerminalJournalUpdateGuard<'a> {
    owner: &'a PtyTerminalRuntime,
}

impl TerminalJournalUpdateGuard<'_> {
    pub(crate) fn activate(&mut self) -> bool {
        let _gate = self.owner.journal_capture_gate.lock().unwrap();
        if !self.owner.journal_capture_open.load(Ordering::Acquire) {
            return false;
        }
        let reserved = self.owner.journal_capture_reserved.swap(false, Ordering::AcqRel);
        debug_assert!(reserved, "terminal journal update activated without a read reservation");
        self.owner.journal_capture_active.store(true, Ordering::Release);
        let previous = self.owner.journal_capture_epoch.fetch_add(1, Ordering::AcqRel);
        debug_assert_eq!(previous & 1, 0, "terminal journal updates must not overlap");
        true
    }
}

impl Drop for TerminalJournalUpdateGuard<'_> {
    fn drop(&mut self) {
        let _gate = self.owner.journal_capture_gate.lock().unwrap();
        self.owner.journal_capture_reserved.store(false, Ordering::Release);
        if self.owner.journal_capture_active.swap(false, Ordering::AcqRel) {
            self.owner.journal_capture_epoch.fetch_add(1, Ordering::Release);
        }
        self.owner.journal_capture_idle.notify_all();
    }
}

#[derive(Default)]
struct ReaderCompletion {
    finished: Mutex<bool>,
    changed: Condvar,
}

impl ReaderCompletion {
    #[cfg(test)]
    fn reset(&self) {
        *self.finished.lock().unwrap() = false;
    }

    fn complete(&self) {
        let mut finished = self.finished.lock().unwrap();
        *finished = true;
        self.changed.notify_all();
    }

    fn wait_until(&self, deadline: Instant) -> bool {
        let mut finished = self.finished.lock().unwrap();
        while !*finished {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let (next, result) = self.changed.wait_timeout(finished, remaining).unwrap();
            finished = next;
            if result.timed_out() && !*finished {
                return false;
            }
        }
        true
    }
}

struct ReaderCompletionGuard(Arc<ReaderCompletion>);

impl Drop for ReaderCompletionGuard {
    fn drop(&mut self) {
        self.0.complete();
    }
}

impl PtyTerminalRuntime {
    fn begin_terminal_journal_update(&self) -> Option<TerminalJournalUpdateGuard<'_>> {
        let _gate = self.journal_capture_gate.lock().unwrap();
        if !self.journal_capture_open.load(Ordering::Acquire) {
            return None;
        }
        let reserved = self.journal_capture_reserved.swap(true, Ordering::AcqRel);
        debug_assert!(!reserved, "terminal journal reads must not overlap");
        Some(TerminalJournalUpdateGuard { owner: self })
    }

    fn close_terminal_journal_capture_when_idle(&self, deadline: Instant) -> bool {
        let mut gate = self.journal_capture_gate.lock().unwrap();
        let active_deadline = deadline + Duration::from_secs(2);
        loop {
            if !self.journal_capture_reserved.load(Ordering::Acquire)
                && self.journal_capture_epoch.load(Ordering::Acquire) & 1 == 0
            {
                self.journal_capture_open.store(false, Ordering::Release);
                return false;
            }
            if Instant::now() >= deadline {
                if !self.journal_capture_active.load(Ordering::Acquire) {
                    // A read is still blocked or has not started terminal
                    // mutation. Revoke its reservation. The reader checks the
                    // gate before parsing and exits without changing state.
                    self.journal_capture_open.store(false, Ordering::Release);
                    return false;
                }
                let remaining = active_deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    // Keep shutdown bounded if a source-owned parser or
                    // callback violates the active-update time contract. The
                    // closed gate prevents a late journal insert after the
                    // final barrier, and the daemon is already stopping.
                    self.journal_capture_open.store(false, Ordering::Release);
                    eprintln!(
                        "cmux-tui: active terminal journal update exceeded shutdown grace; closing capture and recording an output gap"
                    );
                    return true;
                }
                let (next, _) = self.journal_capture_idle.wait_timeout(gate, remaining).unwrap();
                gate = next;
            } else {
                let remaining = deadline.saturating_duration_since(Instant::now());
                let (next, _) = self.journal_capture_idle.wait_timeout(gate, remaining).unwrap();
                gate = next;
            }
        }
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
    terminal_public_id: Option<Arc<TerminalPublicId>>,
    journal_generation: Arc<str>,
    /// Legacy terminal hosts remain attachable, but cannot source-fence
    /// output at daemon shutdown and therefore never enter journal capture.
    journal_capture_supported: bool,
    /// Even while the emulator and terminal journal agree, odd while one
    /// output frame has updated one side but not yet reached the other.
    journal_capture_epoch: AtomicU64,
    journal_capture_gate: Mutex<()>,
    journal_capture_idle: Condvar,
    journal_capture_open: AtomicBool,
    journal_capture_reserved: AtomicBool,
    journal_capture_active: AtomicBool,
    /// Owned reader join fence. Shutdown gives this reader a bounded drain
    /// interval, then closes journal capture before it inserts the final
    /// journal barrier.
    reader_thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    reader_completion: Arc<ReaderCompletion>,
    term: Mutex<Box<Terminal>>,
    stream_progress: Box<TerminalStreamProgress>,
    mouse_encoders: Mutex<Box<MouseEncoders>>,
    runtime: Mutex<PtyRuntime>,
    /// Explicit lifecycle authority for this process. Session content may
    /// survive a daemon replacement through a durable host; daemon-owned
    /// auxiliaries must terminate with the backend that created them.
    lifetime: PtyLifetime,
    supports_clear_history_key_fallback: AtomicBool,
    host_identity: Option<crate::terminal_host_runtime::TerminalHostIdentity>,
    #[cfg(unix)]
    pending_host_binding: Mutex<Option<crate::mux::PendingTerminalHostBinding>>,
    #[cfg(unix)]
    host_exit_record_path: Option<PathBuf>,
    pid: Option<u32>,
    command: Vec<String>,
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
    render_generation: AtomicU64,
    frame_requests: SyncSender<u64>,
    #[cfg(test)]
    frame_producer_before_upgrade: FrameProducerTestHook,
}

pub(crate) struct TerminalJournalGap {
    pub(crate) terminal_id: Arc<TerminalPublicId>,
    pub(crate) generation: Arc<str>,
    pub(crate) reason: &'static str,
}

enum PtyRuntime {
    Local {
        writer: Box<dyn Write + Send>,
        master: Option<Box<dyn MasterPty + Send>>,
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
    defer_launch_activation: bool,
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

#[cfg(windows)]
fn close_local_terminal_master_after_exit(surface: &Arc<Surface>) {
    let Some(pty) = surface.as_pty() else { return };
    let master = {
        let mut runtime = pty.runtime.lock().unwrap();
        let PtyRuntime::Local { master, .. } = &mut *runtime;
        master.take()
    };
    // portable-pty's ConPTY reader keeps a separate output handle. Closing
    // the master closes the pseudoconsole, which lets that reader drain the
    // final bytes and then observe EOF.
    drop(master);
}

#[cfg(not(windows))]
fn close_local_terminal_master_after_exit(_surface: &Arc<Surface>) {}

fn terminal_public_id_from_resource_identity(
    identity: &TabResourceIdentity,
    invalid_context: &str,
) -> anyhow::Result<TerminalPublicId> {
    match &identity.content_id {
        ContentPublicId::Terminal(terminal_id) => Ok(terminal_id.clone()),
        ContentPublicId::Browser(_) => anyhow::bail!("{invalid_context}"),
    }
}

impl std::fmt::Debug for Surface {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Surface").field("id", &self.id).field("kind", &self.kind()).finish()
    }
}

impl Surface {
    pub fn resource_identity(&self) -> Option<&TabResourceIdentity> {
        match self {
            Self::Pty(surface) => surface.meta.resource_identity.as_ref(),
            Self::Browser(surface) => surface.meta.resource_identity.as_ref(),
        }
    }

    pub fn terminal_public_id(&self) -> Option<&TerminalPublicId> {
        match self {
            Self::Pty(surface) => surface.terminal_public_id.as_deref(),
            Self::Browser(_) => None,
        }
    }

    /// Create another view placement for this terminal without creating a
    /// second process or terminal emulator.
    pub(crate) fn project_terminal(
        &self,
        id: SurfaceId,
        resource_identity: TabResourceIdentity,
    ) -> anyhow::Result<Arc<Surface>> {
        let projected_id = terminal_public_id_from_resource_identity(
            &resource_identity,
            "terminal placement requires a terminal content identity",
        )?;
        anyhow::ensure!(
            self.terminal_public_id() == Some(&projected_id),
            "terminal placement cannot change content identity"
        );
        let Surface::Pty(surface) = self else {
            anyhow::bail!("browser content cannot be projected as a terminal");
        };
        Ok(Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta {
                id,
                resource_identity: Some(resource_identity),
                name: Mutex::new(None),
                selection: Mutex::new(None),
            },
            terminal: surface.terminal.clone(),
            viewport: Mutex::new(TerminalViewportState::default()),
        })))
    }

    pub(crate) fn shares_terminal_runtime(&self, other: &Surface) -> bool {
        match (self, other) {
            (Surface::Pty(left), Surface::Pty(right)) => {
                Arc::ptr_eq(&left.terminal, &right.terminal)
            }
            _ => false,
        }
    }

    pub(crate) fn terminal_runtime_id(&self) -> Option<SurfaceId> {
        match self {
            Surface::Pty(surface) => Some(surface.event_surface_id),
            Surface::Browser(_) => None,
        }
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn spawn(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_at_cell_pixels(id, opts, mux, cell_pixels)
    }

    /// Spawn runtime-only terminal content which is not part of the public
    /// resource tree, such as a sidebar view process.
    #[allow(dead_code)]
    pub(crate) fn spawn_auxiliary(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_auxiliary_at_cell_pixels(id, opts, mux, cell_pixels)
    }

    pub(crate) fn spawn_auxiliary_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            None,
            None,
            PtyLifetime::DaemonOwned,
            cell_pixels,
        )
    }

    pub(crate) fn spawn_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            None,
            Some(TabResourceIdentity::terminal(None)?),
            PtyLifetime::SessionOwned,
            cell_pixels,
        )
    }

    pub(crate) fn spawn_with_terminal_id_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        terminal_id: Option<crate::terminal_host::TerminalId>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        let identity = Some(TabResourceIdentity::terminal(None)?);
        Self::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            terminal_id,
            identity,
            PtyLifetime::SessionOwned,
            cell_pixels,
        )
    }

    #[allow(dead_code)]
    pub(crate) fn spawn_with_resource_identity(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            None,
            resource_identity,
            PtyLifetime::SessionOwned,
            cell_pixels,
        )
    }

    fn spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
        id: SurfaceId,
        mut opts: SurfaceOptions,
        mux: Weak<Mux>,
        terminal_id: Option<crate::terminal_host::TerminalId>,
        resource_identity: Option<TabResourceIdentity>,
        lifetime: PtyLifetime,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        let terminal_public_id = resource_identity
            .as_ref()
            .map(|identity| {
                terminal_public_id_from_resource_identity(
                    identity,
                    "terminal surface cannot use a browser resource identity",
                )
            })
            .transpose()?;
        if let Some(terminal_public_id) = terminal_public_id.as_ref() {
            set_surface_environment(&mut opts, "CMUX_TUI_TERMINAL_ID", terminal_public_id.as_str());
            configure_agent_browser_session(&mut opts, terminal_public_id.as_str());
        }
        if let Some(mux) = mux.upgrade() {
            set_surface_environment(
                &mut opts,
                "CMUX_TUI_SESSION_ID",
                mux.session_public_id().as_str(),
            );
        }
        let kitty_reservation =
            mux.upgrade().map(|mux| mux.reserve_kitty_image_surface(id)).transpose()?;
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        #[cfg(unix)]
        if lifetime == PtyLifetime::SessionOwned
            && let Some(root) = opts.terminal_host_root.clone()
        {
            let default_colors = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
            let attachment = match terminal_id {
                Some(terminal_id) => {
                    crate::terminal_host_runtime::launch_terminal_host_with_identity(
                        &opts,
                        &root,
                        default_colors,
                        cell_pixels,
                        initial_kitty_limits,
                        terminal_id,
                    )?
                }
                None => crate::terminal_host_runtime::launch_terminal_host(
                    &opts,
                    &root,
                    default_colors,
                    cell_pixels,
                    initial_kitty_limits,
                )?,
            };
            let defer_launch_activation = terminal_public_id.is_some();
            return Self::spawn_hosted(
                id,
                opts,
                mux,
                HostedSurfaceLaunch {
                    attachment,
                    kitty_reservation,
                    terminate_on_error: true,
                    defer_launch_activation,
                    lifetime,
                    terminal_public_id,
                    resource_identity,
                },
            );
        }
        let _ = terminal_id;
        let initial_geometry = PtyGeometry {
            cols: opts.cols,
            rows: opts.rows,
            cell_width: cell_pixels.0,
            cell_height: cell_pixels.1,
        };
        let pty = cmux_pty::open(initial_geometry.pty_size()?)?;

        let argv = opts
            .command
            .clone()
            .filter(|argv| !argv.is_empty())
            .unwrap_or_else(|| vec![platform::default_shell()]);
        let mut cmd = PtyCommand::new(&argv[0]);
        cmd.args(argv[1..].iter().cloned());
        cmd.env("TERM", &opts.term);
        // The embedded ghostty-vt terminal always parses 24-bit SGR and every
        // frontend forwards RGB cells losslessly, so children can rely on
        // truecolor regardless of where the session server was started
        // (launchd, ssh, cron strip COLORTERM). Set before extra_env so a
        // caller can still override it.
        cmd.env("COLORTERM", "truecolor");
        for (k, v) in &opts.extra_env {
            cmd.env(k, v);
        }
        let cwd = opts.cwd.clone().or_else(platform::default_terminal_cwd);
        if let Some(cwd) = cwd.as_deref() {
            cmd.cwd(cwd);
        }

        let cmux_pty::SpawnedPty { master, mut child } = pty.spawn(cmd)?;
        let pid = child.process_id();
        let killer = child.clone_killer();
        #[cfg(unix)]
        let supports_clear_history_key_fallback = master.as_raw_fd().is_some();
        #[cfg(not(unix))]
        let supports_clear_history_key_fallback = false;
        let mut reader = master.try_clone_reader()?;
        let writer = master.take_writer()?;

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
                        mux.emit_terminal_bell(id);
                    }
                }
            })),
        };

        let mut term = Terminal::new(opts.cols, opts.rows, opts.scrollback, callbacks)?;
        term.resize(opts.cols, opts.rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
        term.set_kitty_graphics_limits(initial_kitty_limits)?;
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
        #[cfg(test)]
        let frame_producer_before_upgrade = Arc::new(Mutex::new(None));
        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta {
                id,
                resource_identity,
                name: Mutex::new(None),
                selection: Mutex::new(None),
            },
            terminal: Arc::new(PtyTerminalRuntime {
                event_surface_id: id,
                terminal_public_id: terminal_public_id.map(Arc::new),
                journal_generation: Arc::from(format!(
                    "local-{}",
                    crate::workspace_registry::new_uuid_v4()
                )),
                journal_capture_supported: true,
                journal_capture_epoch: AtomicU64::new(0),
                journal_capture_gate: Mutex::new(()),
                journal_capture_idle: Condvar::new(),
                journal_capture_open: AtomicBool::new(true),
                journal_capture_reserved: AtomicBool::new(false),
                journal_capture_active: AtomicBool::new(false),
                reader_thread: Mutex::new(None),
                reader_completion: Arc::new(ReaderCompletion::default()),
                term: Mutex::new(Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                mouse_encoders: Mutex::new(Box::new(mouse_encoders)),
                runtime: Mutex::new(PtyRuntime::Local { writer, master: Some(master), killer }),
                lifetime,
                supports_clear_history_key_fallback: AtomicBool::new(
                    supports_clear_history_key_fallback,
                ),
                host_identity: None,
                #[cfg(unix)]
                pending_host_binding: Mutex::new(None),
                #[cfg(unix)]
                host_exit_record_path: None,
                pid,
                command: argv,
                cwd,
                exit: Mutex::new(None),
                local_pty_drained: AtomicBool::new(false),
                exit_notified: AtomicBool::new(false),
                dead: AtomicBool::new(false),
                owner_detaching: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Connected as u8),
                dirty: AtomicBool::new(false),
                title: Mutex::new(String::new()),
                pwd: Mutex::new(None),
                geometry: Mutex::new(initial_geometry),
                kitty_graphics_limits: Box::new(Mutex::new(initial_kitty_limits)),
                #[cfg(test)]
                geometry_test_hook: Mutex::new(None),
                #[cfg(test)]
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                #[cfg(test)]
                test_master_control: None,
                #[cfg(test)]
                vt_replay_builds: AtomicUsize::new(0),
                mux: mux.clone(),
                taps: Mutex::new(Vec::new()),
                attach_colors_pending: AtomicBool::new(false),
                attach_colors_force_pending: AtomicBool::new(false),
                last_attach_colors: Mutex::new(None),
                render: Arc::new(Mutex::new(RenderHub {
                    state: Box::new(render_state),
                    built_generation: 0,
                    latest: None,
                    initial_graphics: None,
                    taps: Vec::new(),
                })),
                render_generation: AtomicU64::new(1),
                frame_requests,
                #[cfg(test)]
                frame_producer_before_upgrade,
            }),
            viewport: Mutex::new(TerminalViewportState::default()),
        }));

        if let Some(reservation) = kitty_reservation
            && let Err(error) = reservation.commit(&surface, initial_kitty_limits)
        {
            surface.kill();
            return Err(error);
        }
        spawn_frame_producer(&surface, frame_rx)?;

        // PTY reader: pty bytes -> terminal state -> SurfaceOutput events.
        let reader_thread =
            std::thread::Builder::new().name(format!("surface-{id}-reader")).spawn({
                let surface = surface.clone();
                move || {
                    let _reader_completion = ReaderCompletionGuard(
                        surface
                            .as_pty()
                            .expect("local PTY reader owns a PTY surface")
                            .reader_completion
                            .clone(),
                    );
                    let mut buf = [0u8; 64 * 1024];
                    loop {
                        let pty = surface.as_pty().expect("surface reader got non-pty surface");
                        let journal_target = pty.journal_target();
                        // Reserve the capture epoch before read(2). Shutdown
                        // can revoke a blocked reservation, but it cannot place
                        // its final barrier in the read-to-parser gap.
                        let mut journal_update = journal_target
                            .as_ref()
                            .and_then(|_| pty.begin_terminal_journal_update());
                        if journal_target.is_some() && journal_update.is_none() {
                            break;
                        }
                        let n = match reader.read(&mut buf) {
                            Ok(0) => break,
                            Ok(n) => n,
                            Err(error)
                                if matches!(
                                    error.kind(),
                                    std::io::ErrorKind::Interrupted
                                        | std::io::ErrorKind::WouldBlock
                                ) =>
                            {
                                std::thread::sleep(Duration::from_millis(1));
                                continue;
                            }
                            Err(_) => break,
                        };
                        let mut scroll_changed = None;
                        let generation = {
                            let mut term = pty.term.lock().unwrap();
                            if let Some(update) = journal_update.as_mut()
                                && !update.activate()
                            {
                                break;
                            }
                            let journal_enabled = journal_update.is_some();
                            let before = terminal_scroll_position(&term);
                            let color_revision = term.color_revision();
                            let color_reapply_revision = term.color_reapply_revision();
                            let cursor_activity = term
                                .cursor_activity()
                                .expect("valid local terminals expose cursor activity");
                            let normalized = term.vt_write_with_normalized(&buf[..n]);
                            let cursor_changed = term
                                .cursor_activity()
                                .expect("valid local terminals expose cursor activity")
                                != cursor_activity;
                            pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                            let after = terminal_scroll_position(&term);
                            let has_attach_taps = pty.broadcast_attach_output(normalized.as_ref());
                            if has_attach_taps
                                && (term.color_revision() != color_revision || cursor_changed)
                            {
                                pty.attach_colors_pending.store(true, Ordering::Release);
                                if term.color_reapply_revision() != color_reapply_revision
                                    || cursor_changed
                                {
                                    pty.attach_colors_force_pending.store(true, Ordering::Release);
                                }
                            }
                            if title_changed.swap(false, Ordering::Relaxed) {
                                let title = term.title().unwrap_or_default();
                                *pty.title.lock().unwrap() = title.clone();
                                if let Some(mux) = mux.upgrade() {
                                    mux.emit_terminal_title(surface.id, title.into());
                                }
                            }
                            if let Some(pwd) = term.pwd() {
                                *pty.pwd.lock().unwrap() = Some(pwd);
                            }
                            if before != after {
                                scroll_changed = Some(after);
                                broadcast_render_scroll_locked(pty, after);
                            }
                            // Keep the terminal lock scoped to parser and observer work. A
                            // borrowed normalized frame still points into `buf`, which lives
                            // for the reader loop, so any journal allocation can happen after
                            // releasing the lock.
                            let journal_output = journal_enabled.then_some(normalized);
                            (
                                pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1,
                                journal_output,
                            )
                        };
                        let (generation, journal_output) = generation;
                        if let (Some(journal_target), Some(journal_output)) =
                            (journal_target, journal_output)
                        {
                            pty.journal_output_if_open(journal_target, journal_output.into_owned());
                        }
                        drop(journal_update);
                        pty.stream_progress.notify();
                        pty.request_frame(generation);
                        if let Some((offset, at_bottom)) = scroll_changed
                            && let Some(mux) = mux.upgrade()
                        {
                            mux.emit_terminal_scroll(surface.id, offset, at_bottom);
                        }
                        let responses = std::mem::take(&mut *pending_responses.lock().unwrap());
                        if !responses.is_empty() {
                            let _ = surface.write_bytes(&responses);
                        }
                    }
                    if let Some(pty) = surface.as_pty() {
                        pty.publish_final_frame();
                        pty.local_pty_drained.store(true, Ordering::Release);
                    }
                    publish_local_exit_if_ready(&surface);
                }
            })?;
        *surface
            .as_pty()
            .expect("local PTY surface owns its reader")
            .reader_thread
            .lock()
            .unwrap() = Some(reader_thread);

        // Child reaper: retain the native status and rendezvous with PTY EOF
        // so final output is visible before the mux observes completion.
        std::thread::Builder::new().name(format!("surface-{id}-wait")).spawn({
            let surface = surface.clone();
            move || {
                let exit = wait_for_native_child_status(child.as_mut());
                if let Some(pty) = surface.as_pty() {
                    *pty.exit.lock().unwrap() = Some(exit);
                }
                close_local_terminal_master_after_exit(&surface);
                publish_local_exit_if_ready(&surface);
            }
        })?;

        Ok(surface)
    }

    #[cfg(unix)]
    fn install_deferred_cell_pixel_handler(
        surface: &Arc<Surface>,
        responses: &Arc<crate::terminal_host_runtime::ControlResponses>,
    ) {
        let surface = Arc::downgrade(surface);
        let responses = Arc::downgrade(responses);
        responses
            .upgrade()
            .expect("control responses are live while installing their handler")
            .set_deferred_cell_pixel_handler(Arc::new(move |request_id, expected, resolution| {
                if matches!(
                    &resolution,
                    crate::terminal_host_runtime::DeferredCellPixelResolution::Disconnected
                ) {
                    return;
                }
                let (Some(surface), Some(responses)) = (surface.upgrade(), responses.upgrade())
                else {
                    return;
                };
                let Some(mux) = surface.as_pty().and_then(|pty| pty.mux.upgrade()) else {
                    return;
                };
                let queued_surface = surface.clone();
                let queued_responses = responses.clone();
                let queued_resolution = resolution.clone();
                if !mux.submit_deferred_cell_pixel_ack(move || {
                    queued_surface.reconcile_deferred_cell_pixel_ack(
                        &queued_responses,
                        request_id,
                        expected,
                        queued_resolution,
                    );
                }) {
                    // The bounded pool is saturated or cannot create its first
                    // worker. Reconcile on the already-owned host reader
                    // instead of dropping a valid acknowledgement.
                    surface.reconcile_deferred_cell_pixel_ack(
                        &responses, request_id, expected, resolution,
                    );
                }
            }));
    }

    #[cfg(unix)]
    fn reconcile_deferred_cell_pixel_ack(
        &self,
        responses: &Arc<crate::terminal_host_runtime::ControlResponses>,
        request_id: u64,
        expected: (u16, u16),
        resolution: crate::terminal_host_runtime::DeferredCellPixelResolution,
    ) {
        #[cfg(test)]
        if let Some(pty) = self.as_pty()
            && let Some(hook) = pty.deferred_cell_pixel_ack_test_hook.lock().unwrap().clone()
        {
            hook();
        }
        let crate::terminal_host_runtime::DeferredCellPixelResolution::Response(frame) = resolution
        else {
            // The replacement host snapshot is authoritative for an
            // acknowledgement whose delivery raced a broken admin stream.
            return;
        };
        let Some(pty) = self.as_pty() else { return };
        let owns_response = {
            let runtime = pty.runtime.lock().unwrap();
            matches!(
                &*runtime,
                PtyRuntime::Hosted(host)
                    if Arc::ptr_eq(&host.control_responses(), responses)
            )
        };
        if !owns_response || responses.latest_cell_pixel_ack() > request_id {
            return;
        }
        let expected_payload = [expected.0.to_le_bytes(), expected.1.to_le_bytes()].concat();
        if frame.kind != MessageKind::CellPixelSizeAck
            || frame.payload.as_slice() != expected_payload
        {
            if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                host.disconnect();
            }
            return;
        }

        let mut geometry = pty.geometry.lock().unwrap();
        let still_owns_response = {
            let runtime = pty.runtime.lock().unwrap();
            matches!(
                &*runtime,
                PtyRuntime::Hosted(host)
                    if Arc::ptr_eq(&host.control_responses(), responses)
            )
        };
        if !still_owns_response || responses.latest_cell_pixel_ack() > request_id {
            return;
        }
        let next = PtyGeometry { cell_width: expected.0, cell_height: expected.1, ..*geometry };
        let committed = pty.commit_geometry(&mut geometry, next, false);
        drop(geometry);
        match committed {
            Ok(changed) => {
                if let Some(mux) = pty.mux.upgrade() {
                    if changed {
                        mux.emit_terminal_output(pty.event_surface_id);
                    }
                    mux.reconcile_deferred_cell_pixel_ack(self.id, expected);
                }
            }
            Err(_) => {
                if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                    host.disconnect();
                }
            }
        }
    }

    #[cfg(unix)]
    fn apply_hosted_clear_history_replay(
        surface: &Arc<Surface>,
        pty: &PtySurface,
        replay: &[u8],
        mux: &Weak<Mux>,
    ) {
        let mut scroll_changed = None;
        let generation = {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            let normalized = term.vt_write_with_normalized(replay);
            let output = match normalized {
                Cow::Borrowed(_) => replay.to_vec(),
                Cow::Owned(normalized) => normalized,
            };
            pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
            pty.broadcast_attach_output(&output);
            let after = terminal_scroll_position(&term);
            if before != after {
                scroll_changed = Some(after);
                broadcast_render_scroll_locked(pty, after);
            }
            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
        };
        pty.stream_progress.notify();
        pty.request_frame(generation);
        if let Some((offset, at_bottom)) = scroll_changed
            && let Some(mux) = mux.upgrade()
        {
            mux.emit(MuxEvent::ScrollChanged { surface: surface.id, offset, at_bottom });
        }
    }

    #[cfg(unix)]
    fn spawn_hosted(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        launch: HostedSurfaceLaunch,
    ) -> anyhow::Result<Arc<Surface>> {
        let HostedSurfaceLaunch {
            mut attachment,
            kitty_reservation,
            terminate_on_error,
            defer_launch_activation,
            lifetime,
            terminal_public_id,
            resource_identity,
        } = launch;
        anyhow::ensure!(
            lifetime == PtyLifetime::SessionOwned,
            "daemon-owned PTYs cannot use durable terminal hosts"
        );
        if let Some(identity) = resource_identity.as_ref() {
            let content_id = terminal_public_id_from_resource_identity(
                identity,
                "hosted terminal cannot use a browser resource identity",
            )?;
            anyhow::ensure!(
                terminal_public_id.as_ref() == Some(&content_id),
                "terminal runtime identity does not match its placement"
            );
        }
        let initial_defaults = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        attachment.send_default_colors(initial_defaults)?;
        let mut reader = attachment.take_reader()?;
        if let Ok(delay_ms) = std::env::var("CMUX_TUI_TEST_HOSTED_SPAWN_FAIL_AFTER_CONNECT")
            && let Ok(delay_ms) = delay_ms.parse::<u64>()
        {
            std::thread::sleep(Duration::from_millis(delay_ms));
            anyhow::bail!("injected hosted surface setup failure after attachment");
        }
        let mut control_responses = attachment.control_responses();
        let smart_renderer = attachment.is_smart_renderer();
        let snapshot = attachment.snapshot.clone();
        let mut applied_color_overrides = snapshot.colors.clone();
        let title_changed = Arc::new(AtomicBool::new(false));
        let callbacks = hosted_terminal_callbacks(id, mux.clone(), title_changed.clone());
        let mut term = Terminal::new(snapshot.cols, snapshot.rows, opts.scrollback, callbacks)?;
        term.resize(
            snapshot.cols,
            snapshot.rows,
            u32::from(snapshot.cell_pixels.0),
            u32::from(snapshot.cell_pixels.1),
        )?;
        if let Some(mux) = mux.upgrade() {
            let colors = mux.default_colors();
            term.replace_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            replace_ghostty_cursor_defaults(&mut term, colors);
        }
        term.apply_vt_replay_parts(
            &snapshot.replay,
            &snapshot.kitty_image_aliases,
            snapshot.kitty_state,
        )?;
        let initial_color_delta = terminal_color_override_full_state(&snapshot.colors);
        if !initial_color_delta.is_empty() {
            term.vt_write(&initial_color_delta);
        }
        let initial_color_revision = term.color_revision();
        let initial_cursor_activity = term.cursor_activity().ok();
        let title = term.title().unwrap_or_default();
        let pwd = term.pwd();
        let mut mouse_encoders = MouseEncoders::new()?;
        mouse_encoders.sync_from_terminal(&term);
        let sequence_boundary = snapshot.sequence_boundary;
        let protocol_version = attachment.protocol_version();
        let host_identity = attachment.identity();
        let mux_owner =
            mux.upgrade().ok_or_else(|| anyhow::anyhow!("terminal host has no mux owner"))?;
        let pending_host_binding =
            mux_owner.register_pending_terminal_host(id, host_identity.clone())?;
        drop(mux_owner);
        let journal_generation = Arc::from(host_identity.incarnation.clone());
        let host_exit_record_path = attachment.exit_record_path();
        let supports_clear_history_key_fallback = attachment.supports_clear_history();
        let journal_capture_supported = attachment.supports_journal_detach_fence();
        let render_state = RenderState::new()?;
        let (frame_requests, frame_rx) = sync_channel(1);
        #[cfg(test)]
        let frame_producer_before_upgrade = Arc::new(Mutex::new(None));
        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta {
                id,
                resource_identity,
                name: Mutex::new(None),
                selection: Mutex::new(None),
            },
            terminal: Arc::new(PtyTerminalRuntime {
                event_surface_id: id,
                terminal_public_id: terminal_public_id.map(Arc::new),
                journal_generation,
                journal_capture_supported,
                journal_capture_epoch: AtomicU64::new(0),
                journal_capture_gate: Mutex::new(()),
                journal_capture_idle: Condvar::new(),
                journal_capture_open: AtomicBool::new(true),
                journal_capture_reserved: AtomicBool::new(false),
                journal_capture_active: AtomicBool::new(false),
                reader_thread: Mutex::new(None),
                reader_completion: Arc::new(ReaderCompletion::default()),
                term: Mutex::new(Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                mouse_encoders: Mutex::new(Box::new(mouse_encoders)),
                runtime: Mutex::new(PtyRuntime::Hosted(Box::new(attachment))),
                lifetime,
                supports_clear_history_key_fallback: AtomicBool::new(
                    supports_clear_history_key_fallback,
                ),
                host_identity: Some(host_identity),
                pending_host_binding: Mutex::new(Some(pending_host_binding)),
                host_exit_record_path: Some(host_exit_record_path),
                pid: snapshot.pid,
                command: snapshot.command,
                cwd: snapshot.cwd,
                exit: Mutex::new(None),
                local_pty_drained: AtomicBool::new(true),
                exit_notified: AtomicBool::new(false),
                dead: AtomicBool::new(false),
                owner_detaching: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Connected as u8),
                dirty: AtomicBool::new(true),
                title: Mutex::new(title),
                pwd: Mutex::new(pwd),
                geometry: Mutex::new(PtyGeometry {
                    cols: snapshot.cols,
                    rows: snapshot.rows,
                    cell_width: snapshot.cell_pixels.0,
                    cell_height: snapshot.cell_pixels.1,
                }),
                kitty_graphics_limits: Box::new(Mutex::new(snapshot.kitty_state.limits)),
                #[cfg(test)]
                geometry_test_hook: Mutex::new(None),
                #[cfg(test)]
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                #[cfg(test)]
                test_master_control: None,
                #[cfg(test)]
                vt_replay_builds: AtomicUsize::new(0),
                mux: mux.clone(),
                taps: Mutex::new(Vec::new()),
                attach_colors_pending: AtomicBool::new(false),
                attach_colors_force_pending: AtomicBool::new(false),
                last_attach_colors: Mutex::new(None),
                render: Arc::new(Mutex::new(RenderHub {
                    state: Box::new(render_state),
                    built_generation: 0,
                    latest: None,
                    initial_graphics: None,
                    taps: Vec::new(),
                })),
                render_generation: AtomicU64::new(1),
                frame_requests,
                #[cfg(test)]
                frame_producer_before_upgrade,
            }),
            viewport: Mutex::new(TerminalViewportState::default()),
        }));
        Self::install_deferred_cell_pixel_handler(&surface, &control_responses);
        spawn_frame_producer(&surface, frame_rx)?;

        // Keep exact-child rollback ownership armed through the final thread
        // spawn. If Builder::spawn fails, dropping the closure clone and
        // function-local Surface drops the still-armed attachment, so no
        // control-write failure can convert this Err into a live orphan.
        let reader_thread = std::thread::Builder::new().name(format!("surface-{id}-host")).spawn({
            let surface = surface.clone();
            let mux = mux.clone();
            let scrollback = opts.scrollback;
            move || {
                let _reader_completion = ReaderCompletionGuard(
                    surface
                        .as_pty()
                        .expect("host reader owns a PTY surface")
                        .reader_completion
                        .clone(),
                );
                let mut sequence_boundary = sequence_boundary;
                let mut protocol_version = protocol_version;
                let mut smart_renderer = smart_renderer;
                let mut applied_color_revision = initial_color_revision;
                let mut applied_cursor_activity = initial_cursor_activity;
                'connection: loop {
                    let pty = surface.as_pty().expect("host reader owns a PTY surface");
                    let mut stager = HostedFrameStager::new_for_version(
                        sequence_boundary,
                        protocol_version,
                        smart_renderer,
                    );
                    let mut received_exit = None;
                    let mut resync_requested = false;
                    let mut journal_target = None;
                    let mut journal_update = None;
                    'host_stream: loop {
                        if journal_update.is_none() {
                            journal_target = pty.journal_target();
                            journal_update = journal_target
                                .as_ref()
                                .and_then(|_| pty.begin_terminal_journal_update());
                            if journal_target.is_some() && journal_update.is_none() {
                                break;
                            }
                        }
                        let frame = match crate::terminal_host_protocol::read_frame(
                            &mut reader,
                            crate::terminal_host_protocol::MAX_FRAME_PAYLOAD,
                        ) {
                            Ok(Some(frame)) => frame,
                            Ok(None) | Err(_) => break,
                        };
                        if matches!(
                            frame.kind,
                            MessageKind::Capability
                                | MessageKind::CellPixelSizeAck
                                | MessageKind::KittyGraphicsLimitsAck
                                | MessageKind::ClearHistoryAck
                                | MessageKind::TerminateAck
                                | MessageKind::DetachAck
                        ) && frame.request_id != 0
                        {
                            if frame.version != protocol_version
                                || frame.flags != 0
                                || frame.sequence != 0
                            {
                                break;
                            }
                            let clear_replay = if frame.kind == MessageKind::ClearHistoryAck
                                && frame.payload.len() > 1
                            {
                                if !smart_renderer
                                    || frame.payload.first() != Some(&CLEAR_HISTORY_ACK_OK)
                                {
                                    break;
                                }
                                Some(&frame.payload[1..])
                            } else {
                                None
                            };
                            if !control_responses.resolve_after(&frame, || {
                                if let Some(replay) = clear_replay {
                                    Self::apply_hosted_clear_history_replay(
                                        &surface, pty, replay, &mux,
                                    );
                                }
                            }) {
                                break;
                            }
                            drop(journal_update.take());
                            journal_target = None;
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
                                let defaults = mux
                                    .upgrade()
                                    .map(|mux| mux.default_colors())
                                    .unwrap_or_default();
                                let generation = {
                                    let mut term = pty.term.lock().unwrap();
                                    if let Some(update) = journal_update.as_mut()
                                        && !update.activate()
                                    {
                                        break 'host_stream;
                                    }
                                    let journal_enabled = journal_update.is_some();
                                    let before = terminal_scroll_position(&term);
                                    let normalized = term.vt_write_with_normalized(&output);
                                    let output = match normalized {
                                        Cow::Borrowed(_) => output,
                                        Cow::Owned(normalized) => normalized,
                                    };
                                    if let Some(colors) = colors.as_ref() {
                                        let delta = terminal_color_override_delta(
                                            &applied_color_overrides,
                                            colors,
                                        );
                                        if !delta.is_empty() {
                                            term.vt_write(&delta);
                                        }
                                        applied_color_overrides = colors.clone();
                                        applied_color_revision = term.color_revision();
                                        applied_cursor_activity = term.cursor_activity().ok();
                                    } else if smart_renderer {
                                        let color_revision = term.color_revision();
                                        let cursor_activity = term.cursor_activity().ok();
                                        if color_revision != applied_color_revision
                                            || cursor_activity != applied_cursor_activity
                                        {
                                            applied_color_overrides = term.color_overrides();
                                            applied_color_revision = color_revision;
                                            applied_cursor_activity = cursor_activity;
                                        }
                                    } else if !terminal_color_overrides_match_applied(
                                        term.color_overrides(),
                                        &applied_color_overrides,
                                    ) {
                                        // An unflagged Output that changed colors
                                        // violated the producer's iff contract.
                                        break 'host_stream;
                                    }
                                    pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                                    let after = terminal_scroll_position(&term);
                                    // The parser already contains the complete
                                    // coupled state before any attach observer can
                                    // see the Output or ColorsChanged callback.
                                    let journal_output = if colors.is_some() {
                                        let journal_output =
                                            journal_enabled.then(|| output.clone());
                                        pty.broadcast_attach_frame(AttachFrame::OutputWithColors {
                                            output,
                                            colors: Box::new(
                                                pty.terminal_colors_locked(&term, defaults),
                                            ),
                                        });
                                        journal_output
                                    } else {
                                        pty.broadcast_attach_output(&output);
                                        journal_enabled.then_some(output)
                                    };
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
                                    (
                                        pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1,
                                        journal_output,
                                    )
                                };
                                let (generation, journal_output) = generation;
                                if let (Some(journal_target), Some(journal_output)) =
                                    (journal_target, journal_output)
                                {
                                    pty.journal_output_if_open(journal_target, journal_output);
                                }
                                drop(journal_update.take());
                                pty.stream_progress.notify();
                                pty.request_frame(generation);
                                if let Some(title) = title_update
                                    && let Some(mux) = mux.upgrade()
                                {
                                    mux.emit_terminal_title(surface.id, title.into());
                                }
                                if let Some((offset, at_bottom)) = scroll_changed
                                    && let Some(mux) = mux.upgrade()
                                {
                                    mux.emit_terminal_scroll(surface.id, offset, at_bottom);
                                }
                            }
                            HostedTransition::Resized { cols, rows, cell_pixels } => {
                                let mut geometry = pty.geometry.lock().unwrap();
                                let next_geometry = PtyGeometry {
                                    cols,
                                    rows,
                                    cell_width: cell_pixels
                                        .map(|pixels| pixels.0)
                                        .unwrap_or(geometry.cell_width),
                                    cell_height: cell_pixels
                                        .map(|pixels| pixels.1)
                                        .unwrap_or(geometry.cell_height),
                                };
                                let changed = match pty.commit_hosted_geometry(
                                    &mut geometry,
                                    next_geometry,
                                    false,
                                ) {
                                    Ok(changed) => changed,
                                    Err(_) => break 'host_stream,
                                };
                                drop(geometry);
                                if changed
                                    && let Some(mux) = mux.upgrade()
                                {
                                    mux.emit(MuxEvent::SurfaceResized {
                                        surface: surface.id,
                                        cols,
                                        rows,
                                        reservation_id: None,
                                    });
                                }
                            }
                            HostedTransition::ResizedWithColors {
                                cols,
                                rows,
                                cell_pixels,
                                replay,
                                kitty_image_aliases,
                                kitty_state,
                                colors,
                            } => {
                                let mut geometry = pty.geometry.lock().unwrap();
                                let next_geometry = PtyGeometry {
                                    cols,
                                    rows,
                                    cell_width: cell_pixels.0,
                                    cell_height: cell_pixels.1,
                                };
                                let defaults = mux
                                    .upgrade()
                                    .map(|mux| mux.default_colors())
                                    .unwrap_or_default();
                                let callbacks = hosted_terminal_callbacks(
                                    id,
                                    mux.clone(),
                                    title_changed.clone(),
                                );
                                let Ok(mut replacement) =
                                    Terminal::new(cols, rows, scrollback, callbacks)
                                else {
                                    break;
                                };
                                if replacement
                                    .resize(
                                        cols,
                                        rows,
                                        u32::from(next_geometry.cell_width),
                                        u32::from(next_geometry.cell_height),
                                    )
                                    .is_err()
                                {
                                    break;
                                }
                                replacement.replace_default_colors(
                                    defaults.fg,
                                    defaults.bg,
                                    defaults.cursor,
                                );
                                replacement.set_default_palette(&defaults.palette);
                                replace_ghostty_cursor_defaults(&mut replacement, defaults);
                                if replacement
                                    .apply_vt_replay_parts(
                                        &replay,
                                        &kitty_image_aliases,
                                        kitty_state,
                                    )
                                    .is_err()
                                {
                                    break;
                                }
                                let delta = terminal_color_override_full_state(&colors);
                                if !delta.is_empty() {
                                    replacement.vt_write(&delta);
                                }
                                title_changed.store(false, Ordering::Relaxed);
                                let title = replacement.title().unwrap_or_default();
                                let pwd = replacement.pwd();
                                let mut scroll_changed = None;
                                let generation = {
                                    let mut term = pty.term.lock().unwrap();
                                    let before = terminal_scroll_position(&term);
                                    **term = replacement;
                                    pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                                    *geometry = next_geometry;
                                    pty.journal_geometry(next_geometry);
                                    *pty.title.lock().unwrap() = title.clone();
                                    *pty.pwd.lock().unwrap() = pwd;
                                    *pty.kitty_graphics_limits.lock().unwrap() = kitty_state.limits;
                                    applied_color_overrides = colors;
                                    applied_color_revision = term.color_revision();
                                    applied_cursor_activity = term.cursor_activity().ok();
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
                                        replay: replay.into(),
                                        kitty_image_aliases,
                                        kitty_state,
                                        colors: Box::new(
                                            pty.terminal_colors_locked(&term, defaults),
                                        ),
                                    });
                                    pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
                                };
                                drop(geometry);
                                pty.stream_progress.notify();
                                pty.request_frame(generation);
                                if let Some(mux) = mux.upgrade() {
                                    mux.emit_terminal_title(surface.id, title.into());
                                    mux.emit_terminal_resized(surface.id, cols, rows, None);
                                    if let Some((offset, at_bottom)) = scroll_changed {
                                        mux.emit_terminal_scroll(surface.id, offset, at_bottom);
                                    }
                                }
                            }
                            // The mirror derives these from the preceding Output;
                            // the sequenced metadata frames are still consumed so
                            // they cannot hide a stream gap.
                            HostedTransition::Metadata(_kind) => {}
                            HostedTransition::Exit(exit) => {
                                received_exit = Some(exit);
                                break;
                            }
                            HostedTransition::ResyncRequired => {
                                resync_requested = true;
                                break;
                            }
                        }
                        drop(journal_update.take());
                        journal_target = None;
                    }
                    control_responses.fail_all();
                    let Some(pty) = surface.as_pty() else { return };
                    if pty.owner_detaching.load(Ordering::Acquire) {
                        return;
                    }
                    let Some(identity) = pty.host_identity.clone() else { return };
                    if let Some(exit) = received_exit {
                        *pty.exit.lock().unwrap() = Some(exit);
                        mark_hosted_runtime_exited(pty, &identity);
                        pty.host_connection_state
                            .store(TerminalHostConnectionState::Exited as u8, Ordering::Release);
                        pty.stream_progress.notify();
                        if let Some(mux) = mux.upgrade() {
                            mux.surface_exited(surface.id);
                        }
                        return;
                    }

                    // ResyncRequired is an ordered renderer reset from a live
                    // host, not evidence that its admin stream or PTY was
                    // lost. Reconnect from a fresh snapshot without moving
                    // either the observable connection state or the durable
                    // lifecycle through Adopting. This also keeps initial
                    // topology binding valid if defaults legitimately change
                    // while a new hosted surface is being installed.
                    let first_loss = !resync_requested
                        && pty
                            .host_connection_state
                            .swap(
                                TerminalHostConnectionState::Reconnecting as u8,
                                Ordering::AcqRel,
                            )
                            != TerminalHostConnectionState::Reconnecting as u8;
                    if first_loss
                        && let Some(mux) = mux.upgrade()
                        && !mux.terminal_host_connection_lost(surface.id, &identity)
                    {
                        return;
                    }

                    let mut retry = TerminalHostReconnectBackoff::default();
                    loop {
                        if pty.owner_detaching.load(Ordering::Acquire) {
                            return;
                        }
                        let discovery = {
                            let runtime = pty.runtime.lock().unwrap();
                            match &*runtime {
                                PtyRuntime::Hosted(host) => Some(host.discovery_record()),
                                PtyRuntime::ExitedHosted | PtyRuntime::Local { .. } => None,
                            }
                        };
                        let Some((record, record_path)) = discovery else { return };
                        match crate::terminal_host_runtime::terminal_host_record_liveness(
                            &record_path,
                            &record,
                        ) {
                            Ok(crate::terminal_host_runtime::TerminalHostLiveness::Dead) => {
                                let exit = crate::terminal_host_runtime::terminal_host_exit_record(
                                    &record_path,
                                )
                                .ok()
                                .flatten()
                                .filter(|(_, exit)| {
                                    exit.terminal_id == identity.terminal_id
                                        && exit.incarnation == identity.incarnation
                                })
                                .map(|(_, exit)| exit.exit)
                                .unwrap_or_else(|| {
                                    TerminalExit::unknown(
                                        "terminal host ended without a durable exit sidecar",
                                    )
                                });
                                *pty.exit.lock().unwrap() = Some(exit);
                                mark_hosted_runtime_exited(pty, &identity);
                                pty.host_connection_state.store(
                                    TerminalHostConnectionState::Exited as u8,
                                    Ordering::Release,
                                );
                                pty.stream_progress.notify();
                                if let Some(mux) = mux.upgrade() {
                                    mux.surface_exited(surface.id);
                                }
                                return;
                            }
                            Ok(crate::terminal_host_runtime::TerminalHostLiveness::Live)
                            | Ok(
                                crate::terminal_host_runtime::TerminalHostLiveness::Indeterminate,
                            )
                            | Err(_) => {}
                        }

                        let Some(reconnect_mux) = mux.upgrade() else { return };
                        let Ok(kitty_limits) =
                            reconnect_mux.kitty_image_limits_for_reconnect(&surface)
                        else {
                            return;
                        };
                        let replacement = match crate::terminal_host_runtime::adopt_terminal_host_with_kitty_limits(
                            record,
                            record_path,
                            kitty_limits,
                        ) {
                            Ok(replacement) if replacement.identity() == identity => replacement,
                            Ok(_) | Err(_) => {
                                if !retry.wait_or_fail(pty) {
                                    return;
                                }
                                continue;
                            }
                        };
                        let replacement_protocol_version = replacement.protocol_version();
                        let replacement_smart_renderer = replacement.is_smart_renderer();
                        let replacement_snapshot = replacement.snapshot.clone();
                        let replacement_sequence_boundary = replacement_snapshot.sequence_boundary;
                        let replacement_control_responses = replacement.control_responses();
                        let installed = {
                            let mut runtime = pty.runtime.lock().unwrap();
                            if pty.owner_detaching.load(Ordering::Acquire) {
                                replacement.disconnect();
                                return;
                            }
                            let viewer_size = match &*runtime {
                                PtyRuntime::Hosted(current) if current.identity() == identity => {
                                    current.viewer_size()
                                }
                                PtyRuntime::Hosted(_)
                                | PtyRuntime::ExitedHosted
                                | PtyRuntime::Local { .. } => return,
                            };
                            let defaults =
                                mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
                            if (if let Some((cols, rows)) = viewer_size {
                                replacement.send_viewer_size(cols, rows).map(|_| ())
                            } else {
                                Ok(())
                            })
                            .and_then(|()| replacement.send_default_colors(defaults).map(|_| ()))
                            .is_err()
                            {
                                false
                            } else {
                                // Keep desired-lease capture, replay, and the
                                // runtime swap atomic with respect to mux
                                // resize/release operations.
                                let supports_clear_history = replacement.supports_clear_history();
                                *runtime = PtyRuntime::Hosted(Box::new(replacement));
                                pty.supports_clear_history_key_fallback
                                    .store(supports_clear_history, Ordering::Release);
                                true
                            }
                        };
                        if !installed {
                            if !retry.wait_or_fail(pty) {
                                return;
                            }
                            continue;
                        }
                        Self::install_deferred_cell_pixel_handler(
                            &surface,
                            &replacement_control_responses,
                        );

                        let replacement_reader = {
                            let mut runtime = pty.runtime.lock().unwrap();
                            let PtyRuntime::Hosted(replacement) = &mut *runtime else { return };
                            replacement.take_reader().ok()
                        };
                        let Some(replacement_reader) = replacement_reader else {
                            if !retry.wait_or_fail(pty) {
                                return;
                            }
                            continue;
                        };

                        let defaults =
                            mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
                        let mut geometry = pty.geometry.lock().unwrap();
                        let next_geometry = PtyGeometry {
                            cols: replacement_snapshot.cols,
                            rows: replacement_snapshot.rows,
                            cell_width: replacement_snapshot.cell_pixels.0,
                            cell_height: replacement_snapshot.cell_pixels.1,
                        };
                        let callbacks =
                            hosted_terminal_callbacks(id, mux.clone(), title_changed.clone());
                        let Ok(mut replacement_term) = Terminal::new(
                            replacement_snapshot.cols,
                            replacement_snapshot.rows,
                            scrollback,
                            callbacks,
                        ) else {
                            if !wait_for_reconnect_after_geometry_failure(&mut retry, pty, geometry)
                            {
                                return;
                            }
                            continue;
                        };
                        if replacement_term
                            .resize(
                                next_geometry.cols,
                                next_geometry.rows,
                                u32::from(next_geometry.cell_width),
                                u32::from(next_geometry.cell_height),
                            )
                            .is_err()
                        {
                            if !wait_for_reconnect_after_geometry_failure(&mut retry, pty, geometry)
                            {
                                return;
                            }
                            continue;
                        }
                        replacement_term.replace_default_colors(
                            defaults.fg,
                            defaults.bg,
                            defaults.cursor,
                        );
                        replacement_term.set_default_palette(&defaults.palette);
                        replace_ghostty_cursor_defaults(&mut replacement_term, defaults);
                        if replacement_term
                            .apply_vt_replay_parts(
                                &replacement_snapshot.replay,
                                &replacement_snapshot.kitty_image_aliases,
                                replacement_snapshot.kitty_state,
                            )
                            .is_err()
                        {
                            if !wait_for_reconnect_after_geometry_failure(&mut retry, pty, geometry)
                            {
                                return;
                            }
                            continue;
                        }
                        let color_delta =
                            terminal_color_override_full_state(&replacement_snapshot.colors);
                        if !color_delta.is_empty() {
                            replacement_term.vt_write(&color_delta);
                        }
                        title_changed.store(false, Ordering::Relaxed);
                        let title = replacement_term.title().unwrap_or_default();
                        let pwd = replacement_term.pwd();
                        let generation = {
                            let mut term = pty.term.lock().unwrap();
                            **term = replacement_term;
                            pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                            *geometry = next_geometry;
                            *pty.title.lock().unwrap() = title.clone();
                            *pty.pwd.lock().unwrap() = pwd;
                            *pty.kitty_graphics_limits.lock().unwrap() =
                                replacement_snapshot.kitty_state.limits;
                            applied_color_overrides = replacement_snapshot.colors;
                            applied_color_revision = term.color_revision();
                            applied_cursor_activity = term.cursor_activity().ok();
                            pty.broadcast_attach_frame(AttachFrame::ResizedWithColors {
                                cols: replacement_snapshot.cols,
                                rows: replacement_snapshot.rows,
                                replay: replacement_snapshot.replay.into(),
                                kitty_image_aliases: replacement_snapshot.kitty_image_aliases,
                                kitty_state: replacement_snapshot.kitty_state,
                                colors: Box::new(pty.terminal_colors_locked(&term, defaults)),
                            });
                            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
                        };
                        drop(geometry);
                        pty.stream_progress.notify_reconnect();
                        pty.request_frame(generation);
                        if !reconnect_mux.terminal_host_reconnected(
                            surface.id,
                            &identity,
                            replacement_snapshot.kitty_state.limits,
                        ) {
                            replacement_control_responses.fail_all();
                            if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap()
                                && host.identity() == identity
                            {
                                host.disconnect();
                            }
                            pty.host_connection_state.store(
                                TerminalHostConnectionState::Reconnecting as u8,
                                Ordering::Release,
                            );
                            if !reconnect_mux.terminal_host_connection_lost(surface.id, &identity) {
                                pty.host_connection_state.store(
                                    TerminalHostConnectionState::Failed as u8,
                                    Ordering::Release,
                                );
                                return;
                            }
                            if !retry.wait_or_fail(pty) {
                                return;
                            }
                            continue;
                        }
                        if reconnect_mux.terminal_journal_enabled()
                            && pty.journal_capture_supported
                        {
                            let checkpoint_key = format!(
                                "host-reconnect:{}:{}:{}",
                                identity.terminal_id,
                                identity.incarnation,
                                replacement_sequence_boundary
                            );
                            // The checkpoint is a journal-replay optimization:
                            // failing to capture one only means the next replay
                            // starts from an older boundary. Capture races with
                            // every other terminal's concurrent reconnect
                            // appends, so retry it in place a few times - and
                            // never tear down the freshly reconnected, healthy
                            // host over it. The old path disconnected and re-ran
                            // the full reconnect up to 16 times per terminal,
                            // each attempt's journal writes re-poisoning the
                            // other terminals' captures.
                            let mut checkpoint = reconnect_mux.create_journal_checkpoint(
                                "terminal_host_reconnect",
                                &checkpoint_key,
                            );
                            for attempt in 1u32..4 {
                                if checkpoint.is_ok() {
                                    break;
                                }
                                std::thread::sleep(Duration::from_millis(25 << attempt));
                                checkpoint = reconnect_mux.create_journal_checkpoint(
                                    "terminal_host_reconnect",
                                    &checkpoint_key,
                                );
                            }
                            match checkpoint {
                                Ok(_) => reconnect_mux.note_reconnect_checkpoint_captured(),
                                Err(error) => reconnect_mux.report_skipped_reconnect_checkpoint(
                                    &identity.terminal_id,
                                    &error,
                                ),
                            }
                        }
                        reconnect_mux.reconcile_deferred_cell_pixel_ack(
                            surface.id,
                            replacement_snapshot.cell_pixels,
                        );
                        reconnect_mux.emit_terminal_title(pty.event_surface_id, title.into());
                        reconnect_mux.emit_terminal_resized(
                            pty.event_surface_id,
                            replacement_snapshot.cols,
                            replacement_snapshot.rows,
                            None,
                        );
                        reader = replacement_reader;
                        control_responses = replacement_control_responses;
                        sequence_boundary = replacement_snapshot.sequence_boundary;
                        protocol_version = replacement_protocol_version;
                        smart_renderer = replacement_smart_renderer;
                        pty.host_connection_state
                            .store(TerminalHostConnectionState::Connected as u8, Ordering::Release);
                        continue 'connection;
                    }
                }
            }
        })?;
        *surface
            .as_pty()
            .expect("hosted PTY surface owns its reader")
            .reader_thread
            .lock()
            .unwrap() = Some(reader_thread);
        let kitty_registration = kitty_reservation.map_or(Ok(()), |reservation| {
            reservation.commit(&surface, snapshot.kitty_state.limits)
        });
        if let Err(error) = kitty_registration {
            if let Some(pty) = surface.as_pty()
                && let PtyRuntime::Hosted(host) = &mut *pty.runtime.lock().unwrap()
            {
                if terminate_on_error {
                    let _ = host.terminate();
                }
                host.disconnect();
            }
            return Err(error);
        }
        if terminate_on_error
            && let Some(pty) = surface.as_pty()
            && let PtyRuntime::Hosted(host) = &mut *pty.runtime.lock().unwrap()
        {
            if !defer_launch_activation && let Err(error) = host.activate_launched_host() {
                let _ = host.terminate();
                host.disconnect();
                return Err(error.into());
            }
            host.commit_launched_host();
        }
        #[cfg(debug_assertions)]
        if let Some(delay) =
            mux.upgrade().and_then(|mux| mux.take_test_terminal_host_disconnect_after_spawn())
        {
            let test_surface = surface.clone();
            let _ = std::thread::Builder::new().name("terminal-host-test-disconnect".into()).spawn(
                move || {
                    std::thread::sleep(delay);
                    if let Some(pty) = test_surface.as_pty()
                        && let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap()
                    {
                        host.disconnect();
                    }
                },
            );
        }
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
        Self::adopt_hosted_with_resource_identity(
            id,
            opts,
            mux,
            record,
            record_path,
            TabResourceIdentity::terminal(None)?,
        )
    }

    #[cfg(unix)]
    pub(crate) fn adopt_hosted_with_resource_identity(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: PathBuf,
        resource_identity: TabResourceIdentity,
    ) -> anyhow::Result<Arc<Surface>> {
        let terminal_public_id = terminal_public_id_from_resource_identity(
            &resource_identity,
            "hosted terminal cannot use a browser resource identity",
        )?;
        let kitty_reservation =
            mux.upgrade().map(|mux| mux.reserve_kitty_image_surface(id)).transpose()?;
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        let attachment = crate::terminal_host_runtime::adopt_terminal_host_with_kitty_limits(
            record,
            record_path,
            initial_kitty_limits,
        )?;
        Self::spawn_hosted(
            id,
            opts,
            mux,
            HostedSurfaceLaunch {
                attachment,
                kitty_reservation,
                terminate_on_error: false,
                defer_launch_activation: false,
                lifetime: PtyLifetime::SessionOwned,
                terminal_public_id: Some(terminal_public_id),
                resource_identity: Some(resource_identity),
            },
        )
    }

    #[cfg(unix)]
    pub(crate) fn adopt_hosted_with_terminal_public_id(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        record: crate::terminal_host_runtime::TerminalHostRecord,
        record_path: PathBuf,
        terminal_public_id: TerminalPublicId,
    ) -> anyhow::Result<Arc<Surface>> {
        let kitty_reservation =
            mux.upgrade().map(|mux| mux.reserve_kitty_image_surface(id)).transpose()?;
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        let attachment = crate::terminal_host_runtime::adopt_terminal_host_with_kitty_limits(
            record,
            record_path,
            initial_kitty_limits,
        )?;
        Self::spawn_hosted(
            id,
            opts,
            mux,
            HostedSurfaceLaunch {
                attachment,
                kitty_reservation,
                terminate_on_error: false,
                defer_launch_activation: false,
                lifetime: PtyLifetime::SessionOwned,
                terminal_public_id: Some(terminal_public_id),
                resource_identity: None,
            },
        )
    }

    /// Construct a dead hosted surface for lifecycle tests without inventing
    /// a live host connection. Production keeps exit receipts in the registry.
    #[cfg(all(unix, test))]
    pub(crate) fn exited_terminal_placeholder(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
    ) -> anyhow::Result<Arc<Surface>> {
        Self::exited_terminal_placeholder_with_resource_identity(
            id,
            opts,
            mux,
            identity,
            TabResourceIdentity::terminal(None)?,
        )
    }

    #[cfg(all(unix, test))]
    pub(crate) fn exited_terminal_placeholder_with_resource_identity(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
        resource_identity: TabResourceIdentity,
    ) -> anyhow::Result<Arc<Surface>> {
        let terminal_public_id = terminal_public_id_from_resource_identity(
            &resource_identity,
            "exited terminal cannot use a browser resource identity",
        )?;
        Self::exited_terminal_placeholder_with_identities(
            id,
            opts,
            mux,
            identity,
            terminal_public_id,
            Some(resource_identity),
        )
    }

    #[cfg(all(unix, test))]
    pub(crate) fn exited_terminal_placeholder_with_terminal_public_id(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
        terminal_public_id: TerminalPublicId,
    ) -> anyhow::Result<Arc<Surface>> {
        Self::exited_terminal_placeholder_with_identities(
            id,
            opts,
            mux,
            identity,
            terminal_public_id,
            None,
        )
    }

    #[cfg(all(unix, test))]
    fn exited_terminal_placeholder_with_identities(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        identity: crate::terminal_host_runtime::TerminalHostIdentity,
        terminal_public_id: TerminalPublicId,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let journal_generation = Arc::from(identity.incarnation.clone());
        let initial_kitty_limits = KittyGraphicsLimits::disabled();
        let title_changed = Arc::new(AtomicBool::new(false));
        let callbacks = hosted_terminal_callbacks(id, mux.clone(), title_changed);
        let (cols, rows) = (opts.cols.max(1), opts.rows.max(1));
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        let mut term = Terminal::new(cols, rows, opts.scrollback, callbacks)?;
        term.resize(cols, rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
        term.set_kitty_graphics_limits(initial_kitty_limits)?;
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
        #[cfg(test)]
        let frame_producer_before_upgrade = Arc::new(Mutex::new(None));
        let command = opts
            .command
            .clone()
            .filter(|command| !command.is_empty())
            .unwrap_or_else(|| vec![platform::default_shell()]);
        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta {
                id,
                resource_identity,
                name: Mutex::new(None),
                selection: Mutex::new(None),
            },
            terminal: Arc::new(PtyTerminalRuntime {
                event_surface_id: id,
                terminal_public_id: Some(Arc::new(terminal_public_id)),
                journal_generation,
                journal_capture_supported: true,
                journal_capture_epoch: AtomicU64::new(0),
                journal_capture_gate: Mutex::new(()),
                journal_capture_idle: Condvar::new(),
                journal_capture_open: AtomicBool::new(true),
                journal_capture_reserved: AtomicBool::new(false),
                journal_capture_active: AtomicBool::new(false),
                reader_thread: Mutex::new(None),
                reader_completion: Arc::new(ReaderCompletion::default()),
                term: Mutex::new(Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                mouse_encoders: Mutex::new(Box::new(mouse_encoders)),
                runtime: Mutex::new(PtyRuntime::ExitedHosted),
                lifetime: PtyLifetime::SessionOwned,
                supports_clear_history_key_fallback: AtomicBool::new(false),
                host_identity: Some(identity),
                pending_host_binding: Mutex::new(None),
                host_exit_record_path: None,
                pid: None,
                command,
                cwd: opts.cwd,
                exit: Mutex::new(None),
                local_pty_drained: AtomicBool::new(true),
                exit_notified: AtomicBool::new(true),
                dead: AtomicBool::new(true),
                owner_detaching: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Exited as u8),
                dirty: AtomicBool::new(true),
                title: Mutex::new(String::new()),
                pwd: Mutex::new(None),
                geometry: Mutex::new(PtyGeometry {
                    cols,
                    rows,
                    cell_width: cell_pixels.0,
                    cell_height: cell_pixels.1,
                }),
                kitty_graphics_limits: Box::new(Mutex::new(initial_kitty_limits)),
                #[cfg(test)]
                geometry_test_hook: Mutex::new(None),
                #[cfg(test)]
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                #[cfg(test)]
                test_master_control: None,
                #[cfg(test)]
                vt_replay_builds: AtomicUsize::new(0),
                mux,
                taps: Mutex::new(Vec::new()),
                attach_colors_pending: AtomicBool::new(false),
                attach_colors_force_pending: AtomicBool::new(false),
                last_attach_colors: Mutex::new(None),
                render: Arc::new(Mutex::new(RenderHub {
                    state: Box::new(render_state),
                    built_generation: 0,
                    latest: None,
                    initial_graphics: None,
                    taps: Vec::new(),
                })),
                render_generation: AtomicU64::new(1),
                frame_requests,
                #[cfg(test)]
                frame_producer_before_upgrade,
            }),
            viewport: Mutex::new(TerminalViewportState::default()),
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
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_for_test_with_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            Some(TabResourceIdentity::terminal(None)?),
            cell_pixels,
        )
    }

    #[cfg(test)]
    pub(crate) fn spawn_for_test_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_for_test_with_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            Some(TabResourceIdentity::terminal(None)?),
            cell_pixels,
        )
    }

    #[cfg(test)]
    pub(crate) fn spawn_for_test_with_resource_identity(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        resource_identity: Option<TabResourceIdentity>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cell_pixels =
            mux.upgrade().map(|mux| mux.cell_pixel_creation_size()).unwrap_or((8, 16));
        Self::spawn_for_test_with_resource_identity_at_cell_pixels(
            id,
            opts,
            mux,
            resource_identity,
            cell_pixels,
        )
    }

    #[cfg(test)]
    pub(crate) fn spawn_for_test_with_resource_identity_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        resource_identity: Option<TabResourceIdentity>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_for_test_with_lifetime_at_cell_pixels(
            id,
            opts,
            mux,
            resource_identity,
            PtyLifetime::SessionOwned,
            cell_pixels,
        )
    }

    #[cfg(test)]
    pub(crate) fn spawn_auxiliary_for_test_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        Self::spawn_for_test_with_lifetime_at_cell_pixels(
            id,
            opts,
            mux,
            None,
            PtyLifetime::DaemonOwned,
            cell_pixels,
        )
    }

    #[cfg(test)]
    fn spawn_for_test_with_lifetime_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        resource_identity: Option<TabResourceIdentity>,
        lifetime: PtyLifetime,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        let terminal_public_id = resource_identity
            .as_ref()
            .map(|identity| {
                terminal_public_id_from_resource_identity(
                    identity,
                    "terminal surface cannot use a browser resource identity",
                )
            })
            .transpose()?;
        let kitty_reservation =
            mux.upgrade().map(|mux| mux.reserve_kitty_image_surface(id)).transpose()?;
        let initial_kitty_limits = kitty_reservation
            .as_ref()
            .map(crate::mux::KittyImageBudgetReservation::initial_limits)
            .unwrap_or_default();
        let initial_geometry = PtyGeometry {
            cols: opts.cols,
            rows: opts.rows,
            cell_width: cell_pixels.0,
            cell_height: cell_pixels.1,
        };
        let initial_pty_size = initial_geometry.pty_size()?;
        let callbacks = Callbacks {
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
        term.resize(opts.cols, opts.rows, u32::from(cell_pixels.0), u32::from(cell_pixels.1))?;
        term.set_kitty_graphics_limits(initial_kitty_limits)?;
        if let Some(mux) = mux.upgrade() {
            let colors = mux.default_colors();
            term.replace_default_colors(colors.fg, colors.bg, colors.cursor);
            term.set_default_palette(&colors.palette);
            replace_ghostty_cursor_defaults(&mut term, colors);
        }
        let mut mouse_encoders = MouseEncoders::new()?;
        mouse_encoders.sync_from_terminal(&term);

        let render_state = RenderState::new()?;
        let (frame_requests, _frame_rx) = sync_channel(1);
        let test_master_control = Arc::new(TestMasterPtyControl::default());
        let frame_producer_before_upgrade = Arc::new(Mutex::new(None));

        let surface = Arc::new(Surface::Pty(PtySurface {
            meta: SurfaceMeta {
                id,
                resource_identity,
                name: Mutex::new(None),
                selection: Mutex::new(None),
            },
            terminal: Arc::new(PtyTerminalRuntime {
                event_surface_id: id,
                terminal_public_id: terminal_public_id.map(Arc::new),
                journal_generation: Arc::from(format!("test-{id}")),
                journal_capture_supported: true,
                journal_capture_epoch: AtomicU64::new(0),
                journal_capture_gate: Mutex::new(()),
                journal_capture_idle: Condvar::new(),
                journal_capture_open: AtomicBool::new(true),
                journal_capture_reserved: AtomicBool::new(false),
                journal_capture_active: AtomicBool::new(false),
                reader_thread: Mutex::new(None),
                reader_completion: Arc::new(ReaderCompletion::default()),
                term: Mutex::new(Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                mouse_encoders: Mutex::new(Box::new(mouse_encoders)),
                runtime: Mutex::new(PtyRuntime::Local {
                    writer: Box::new(std::io::sink()),
                    master: Some(Box::new(TestMasterPty {
                        size: Mutex::new(initial_pty_size),
                        control: test_master_control.clone(),
                    })),
                    killer: Box::new(TestChildKiller),
                }),
                lifetime,
                supports_clear_history_key_fallback: AtomicBool::new(false),
                host_identity: None,
                #[cfg(unix)]
                pending_host_binding: Mutex::new(None),
                #[cfg(unix)]
                host_exit_record_path: None,
                pid: Some(id as u32),
                command: opts.command.unwrap_or_else(|| vec![platform::default_shell()]),
                cwd: opts.cwd,
                exit: Mutex::new(None),
                local_pty_drained: AtomicBool::new(false),
                exit_notified: AtomicBool::new(false),
                dead: AtomicBool::new(false),
                owner_detaching: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Connected as u8),
                dirty: AtomicBool::new(false),
                title: Mutex::new(String::new()),
                pwd: Mutex::new(None),
                geometry: Mutex::new(initial_geometry),
                kitty_graphics_limits: Box::new(Mutex::new(initial_kitty_limits)),
                geometry_test_hook: Mutex::new(None),
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                test_master_control: Some(test_master_control),
                vt_replay_builds: AtomicUsize::new(0),
                mux,
                taps: Mutex::new(Vec::new()),
                attach_colors_pending: AtomicBool::new(false),
                attach_colors_force_pending: AtomicBool::new(false),
                last_attach_colors: Mutex::new(None),
                render: Arc::new(Mutex::new(RenderHub {
                    state: Box::new(render_state),
                    built_generation: 0,
                    latest: None,
                    initial_graphics: None,
                    taps: Vec::new(),
                })),
                render_generation: AtomicU64::new(1),
                frame_requests,
                frame_producer_before_upgrade,
            }),
            viewport: Mutex::new(TerminalViewportState::default()),
        }));
        if let Some(reservation) = kitty_reservation {
            reservation.commit(&surface, initial_kitty_limits)?;
        }
        Ok(surface)
    }

    fn as_pty(&self) -> Option<&PtySurface> {
        match self {
            Surface::Pty(surface) => Some(surface),
            Surface::Browser(_) => None,
        }
    }

    pub(crate) fn terminal_journal_capture_epoch(&self) -> Option<u64> {
        self.as_pty().map(|pty| pty.journal_capture_epoch.load(Ordering::Acquire))
    }

    pub(crate) fn finish_terminal_reader(&self, deadline: Instant) -> Option<TerminalJournalGap> {
        let pty = self.as_pty()?;
        if let Some(reader) = pty.reader_thread.lock().unwrap().take() {
            if pty.reader_completion.wait_until(deadline) {
                if reader.join().is_err() {
                    eprintln!("cmux-tui: terminal reader thread panicked during shutdown");
                }
            } else {
                eprintln!(
                    "cmux-tui: terminal reader did not stop before the shared shutdown deadline; closing journal capture"
                );
            }
        }
        // A reader that is blocked in the PTY has an even capture epoch and
        // does not delay shutdown. Close the gate between updates. If one
        // update crossed the reader deadline, wait through the active-update
        // grace. Report a gap if that update still did not complete.
        let output_gap = pty.close_terminal_journal_capture_when_idle(deadline);
        if !output_gap || !pty.journal_capture_supported {
            return None;
        }
        pty.terminal_public_id.clone().map(|terminal_id| TerminalJournalGap {
            terminal_id,
            generation: pty.journal_generation.clone(),
            reason: "active_update_timeout",
        })
    }

    #[cfg(test)]
    pub(crate) fn install_terminal_reader_for_test(&self, reader: std::thread::JoinHandle<()>) {
        let pty = self.as_pty().expect("test reader requires a PTY surface");
        pty.reader_completion.reset();
        let completion = pty.reader_completion.clone();
        let reader = std::thread::spawn(move || {
            let result = reader.join();
            completion.complete();
            result.expect("installed test terminal reader panicked");
        });
        let previous = pty.reader_thread.lock().unwrap().replace(reader);
        assert!(previous.is_none(), "test PTY already owns a reader thread");
    }

    #[cfg(test)]
    pub(crate) fn wait_for_terminal_reader_for_test(&self, deadline: Instant) -> bool {
        self.as_pty().is_some_and(|pty| pty.reader_completion.wait_until(deadline))
    }

    #[cfg(test)]
    pub(crate) fn begin_terminal_journal_update_for_test(
        &self,
    ) -> Option<TerminalJournalUpdateGuard<'_>> {
        self.as_pty().and_then(|pty| pty.begin_terminal_journal_update())
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
            // A keep-on-exit terminal outlives its child, so typing into the
            // dead PTY is an expected interaction: drop the bytes silently
            // instead of failing every keystroke on the final screen.
            #[cfg(unix)]
            PtyRuntime::ExitedHosted => Ok(()),
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
            // Keep-on-exit terminals accept and drop paste input the same
            // way as keystrokes: the final screen is read-only, not broken.
            if matches!(&*runtime, PtyRuntime::ExitedHosted) {
                return Ok(());
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
                broadcast_render_scroll_locked(pty, after);
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
                broadcast_render_scroll_locked(pty, after);
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

    /// Clear retained primary-screen output inside the emulator without
    /// writing to the child process. Complete rows before an OSC 133 prompt are
    /// erased when the cursor can be restored exactly; otherwise the request
    /// fails without changing terminal state. Attached byte frontends receive
    /// the same VT erase sequence. Alternate-screen applications are left
    /// untouched.
    pub fn clear_history(&self) -> anyhow::Result<()> {
        self.clear_history_or_encode_key(None)
    }

    /// Clear primary-screen history, or encode `fallback_key` when the
    /// authoritative terminal is in the alternate screen. The PTY writer
    /// serializes input while the screen decision and keyboard encoding use
    /// one terminal snapshot. The terminal lock is released before PTY I/O.
    pub fn clear_history_or_encode_key(
        &self,
        fallback_key: Option<&KeyInput>,
    ) -> anyhow::Result<()> {
        self.clear_history_or_encode_key_classified(fallback_key)
            .map_err(ClearHistoryFailure::into_error)
    }

    pub fn supports_clear_history_key_fallback(&self) -> bool {
        self.as_pty()
            .is_some_and(|pty| pty.supports_clear_history_key_fallback.load(Ordering::Acquire))
    }

    pub fn clear_history_or_encode_key_classified(
        &self,
        fallback_key: Option<&KeyInput>,
    ) -> Result<(), ClearHistoryFailure> {
        let Some(pty) = self.as_pty() else {
            return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                "browser surface does not have a VT terminal"
            )));
        };
        #[cfg(unix)]
        {
            {
                let runtime = pty.runtime.lock().unwrap();
                match &*runtime {
                    PtyRuntime::Hosted(host) => {
                        if host.send_clear_history(fallback_key)? {
                            return Ok(());
                        }
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            "terminal host does not support clear-history"
                        )));
                    }
                    PtyRuntime::ExitedHosted => {
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            "terminal host has exited"
                        )));
                    }
                    PtyRuntime::Local { .. } => {}
                }
            }
        }

        // Local resize takes terminal before runtime. Keep the same order for
        // alternate-screen fallback so resize and Command-K cannot deadlock.
        let mut observed_progress = pty.stream_progress.revision();
        let mut stream_wait = None;
        loop {
            let mut term = pty.term.lock().unwrap();
            let before = terminal_scroll_position(&term);
            let scroll_changed = match apply_clear_history_transition(&mut term, fallback_key)
                .map_err(ClearHistoryFailure::known_not_delivered)?
            {
                ClearHistoryTransition::Blocked => {
                    drop(term);
                    let deadline = stream_wait
                        .get_or_insert_with(|| {
                            pty.stream_progress
                                .begin_clear_history_wait(CLEAR_HISTORY_STREAM_WAIT_TIMEOUT)
                        })
                        .deadline();
                    let Some(progress) =
                        pty.stream_progress.wait_for_change(observed_progress, deadline)
                    else {
                        stream_wait.as_mut().unwrap().mark_timed_out();
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            CLEAR_HISTORY_STREAM_TIMEOUT_ERROR
                        )));
                    };
                    observed_progress = progress;
                    continue;
                }
                ClearHistoryTransition::EncodedFallback(encoded) => {
                    let mut runtime = pty.runtime.lock().unwrap();
                    let PtyRuntime::Local { writer, master, .. } = &mut *runtime else {
                        unreachable!("a local PTY runtime cannot become hosted")
                    };
                    let Some(master) = master.as_deref() else {
                        return Err(ClearHistoryFailure::known_not_delivered(anyhow::anyhow!(
                            "terminal process has exited"
                        )));
                    };
                    drop(term);
                    return write_clear_history_fallback(master, writer.as_mut(), &encoded);
                }
                ClearHistoryTransition::Noop => return Ok(()),
                ClearHistoryTransition::Cleared(clear) => {
                    pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                    pty.broadcast_attach_output(&clear);
                    pty.stream_progress.notify();
                    let after = terminal_scroll_position(&term);
                    if before != after {
                        broadcast_render_scroll_locked(pty, after);
                    }
                    let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
                    let _ = pty.build_frame_locked(&mut term, generation, false);
                    (before != after).then_some(after)
                }
            };
            drop(term);
            if let Some((offset, at_bottom)) = scroll_changed
                && let Some(mux) = pty.mux.upgrade()
            {
                mux.emit_terminal_scroll(pty.event_surface_id, offset, at_bottom);
            }
            pty.mark_output_dirty();
            return Ok(());
        }
    }

    pub fn set_default_colors(&self, colors: DefaultColors) {
        if let Some(pty) = self.as_pty() {
            #[cfg(unix)]
            if let PtyRuntime::Hosted(host) = &*pty.runtime.lock().unwrap() {
                // The local mirror updates immediately below. A v2 durable
                // host also receives the same complete defaults so later
                // output, resize snapshots, and reconnects cannot restore the
                // launch-time theme. Legacy hosts are feature-gated by record.
                let _ = host.send_default_colors(colors);
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
        master.as_deref().expect("test PTY master is open").get_size().unwrap()
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

    pub fn spawn_cwd(&self) -> Option<String> {
        self.as_pty().and_then(|pty| pty.cwd.clone())
    }

    pub fn terminal_exit(&self) -> Option<TerminalExit> {
        self.as_pty().and_then(|pty| pty.exit.lock().unwrap().clone())
    }

    /// Terminate a hosted terminal through its existing owner connection and
    /// wait for that same ordered stream to publish the durable exit receipt.
    /// Local terminals return `None` and keep their existing kill path.
    #[cfg(unix)]
    pub(crate) fn terminate_host_and_wait_for_exit(
        &self,
        deadline: Instant,
    ) -> anyhow::Result<Option<(PathBuf, crate::terminal_host_runtime::TerminalHostExitRecord)>>
    {
        let Some(pty) = self.as_pty() else { return Ok(None) };
        let Some(identity) = pty.host_identity.clone() else { return Ok(None) };
        let Some(path) = pty.host_exit_record_path.clone() else { return Ok(None) };
        let mut observed = pty.stream_progress.revision();
        let already_exited = {
            let mut runtime = pty.runtime.lock().unwrap();
            match &mut *runtime {
                PtyRuntime::Hosted(host) => {
                    host.terminate().map_err(|error| {
                        anyhow::anyhow!("send terminal-host termination: {error}")
                    })?;
                    false
                }
                PtyRuntime::ExitedHosted => true,
                PtyRuntime::Local { .. } => return Ok(None),
            }
        };
        loop {
            if let Some(exit) = pty.exit.lock().unwrap().clone() {
                return Ok(Some((
                    path,
                    crate::terminal_host_runtime::TerminalHostExitRecord::new(&identity, exit),
                )));
            }
            anyhow::ensure!(
                !already_exited,
                "terminal host exited without publishing an exit outcome"
            );
            observed =
                pty.stream_progress.wait_for_change(observed, deadline).ok_or_else(|| {
                    anyhow::anyhow!("terminal host did not exit before the close deadline")
                })?;
        }
    }

    #[cfg(unix)]
    pub(crate) fn terminal_host_exit_sidecar(
        &self,
    ) -> Option<(PathBuf, crate::terminal_host_runtime::TerminalHostExitRecord)> {
        let pty = self.as_pty()?;
        let path = pty.host_exit_record_path.clone()?;
        let identity = pty.host_identity.as_ref()?;
        let exit = pty.exit.lock().unwrap().clone()?;
        Some((path, crate::terminal_host_runtime::TerminalHostExitRecord::new(identity, exit)))
    }

    /// Process-stable identity for hosted terminals. Surface ids remain
    /// daemon-local compatibility handles and may change after adoption.
    pub fn terminal_host_identity(
        &self,
    ) -> Option<crate::terminal_host_runtime::TerminalHostIdentity> {
        self.as_pty().and_then(|pty| pty.host_identity.clone())
    }

    #[cfg(unix)]
    pub(crate) fn release_pending_terminal_host_binding(&self) {
        if let Some(pty) = self.as_pty() {
            pty.pending_host_binding.lock().unwrap().take();
        }
    }

    pub fn terminal_host_connection_state(&self) -> Option<TerminalHostConnectionState> {
        let pty = self.as_pty()?;
        pty.host_identity.as_ref()?;
        Some(TerminalHostConnectionState::from_u8(
            pty.host_connection_state.load(Ordering::Acquire),
        ))
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
        if pty.dead.load(Ordering::Acquire) {
            return Err(ghostty_vt::Error::NoValue);
        }
        let (tap, stream) =
            AttachTap::pair(lifecycle.clone(), ATTACH_STREAM_CAPACITY, ATTACH_STREAM_MAX_BYTES);
        // Snapshot and tap registration under the same terminal lock:
        // the reader thread cannot apply bytes between the two.
        #[cfg(test)]
        pty.vt_replay_builds.fetch_add(1, Ordering::AcqRel);
        let replay = term.vt_replay_bounded(VT_REPLAY_MAX_BYTES)?;
        let (cols, rows) = (term.cols(), term.rows());
        let defaults = pty.mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        let colors = pty.terminal_colors_locked(&term, defaults);
        if !pty.dead.load(Ordering::Acquire) {
            let mut taps = pty.taps.lock().unwrap();
            if taps.is_empty() {
                *pty.last_attach_colors.lock().unwrap() =
                    Some(Box::new(TerminalColors::from_pty_output(&term, defaults)));
            }
            taps.push(tap);
        }
        Ok(AttachStream {
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
        if pty.dead.load(Ordering::Acquire) {
            return Err(ghostty_vt::Error::NoValue);
        }
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

    pub fn kill(&self) {
        match self {
            Surface::Pty(pty) => {
                #[cfg(unix)]
                let mut terminate_fallback = None;
                // Removal is authoritative. Prevent the mirror reader from
                // racing termination by reconnecting a Surface that no longer
                // exists in the mux topology.
                pty.owner_detaching.store(true, Ordering::Release);
                {
                    let mut runtime = pty.runtime.lock().unwrap();
                    match &mut *runtime {
                        PtyRuntime::Local { killer, .. } => {
                            let _ = killer.kill();
                        }
                        #[cfg(unix)]
                        PtyRuntime::Hosted(host) => {
                            // The host owns record cleanup and removes it only
                            // after the PTY process has actually exited. Unlinking
                            // here would make a failed Terminate write turn a live
                            // shell into an undiscoverable orphan.
                            if host.terminate().is_err() {
                                terminate_fallback = Some(host.identity());
                            }
                        }
                        #[cfg(unix)]
                        PtyRuntime::ExitedHosted => {}
                    }
                }
                if let Some(mux) = pty.mux.upgrade() {
                    #[cfg(unix)]
                    if let Some(identity) = terminate_fallback {
                        mux.terminate_discovered_terminal_host(
                            &identity.terminal_id,
                            Some(&identity.incarnation),
                        );
                    }
                    let _ = mux.unregister_kitty_image_surface(self);
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

    pub(crate) fn shutdown_for_daemon(&self, deadline: Instant) -> Option<TerminalJournalGap> {
        if self.as_pty().is_some_and(|pty| pty.lifetime == PtyLifetime::DaemonOwned) {
            self.kill();
            return None;
        }
        #[cfg(unix)]
        if let Some(pty) = self.as_pty() {
            let runtime = pty.runtime.lock().unwrap();
            if let PtyRuntime::Hosted(host) = &*runtime {
                pty.owner_detaching.store(true, Ordering::Release);
                let mut gap = None;
                if host.supports_journal_detach_fence()
                    && let Err(error) = host.detach_for_daemon_shutdown_until(deadline)
                {
                    eprintln!(
                        "cmux-tui: terminal host {} detach fence failed: {error:#}",
                        pty.event_surface_id
                    );
                    gap = pty.terminal_public_id.clone().map(|terminal_id| TerminalJournalGap {
                        terminal_id,
                        generation: pty.journal_generation.clone(),
                        reason: "detach_fence_failed",
                    });
                }
                host.disconnect();
                return gap;
            }
            if matches!(&*runtime, PtyRuntime::ExitedHosted) {
                return None;
            }
        }
        self.disconnect_for_daemon_shutdown();
        None
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

    /// Release a newly launched host after the caller commits the terminal's
    /// public topology. Adoption and local PTYs are already active, making
    /// this idempotent for shared creation paths.
    pub(crate) fn activate_hosted_launch_stream(&self) -> anyhow::Result<bool> {
        #[cfg(unix)]
        {
            let Some(pty) = self.as_pty() else { return Ok(false) };
            let mut runtime = pty.runtime.lock().unwrap();
            let PtyRuntime::Hosted(host) = &mut *runtime else { return Ok(false) };
            host.activate_launched_host().map_err(anyhow::Error::new)
        }
        #[cfg(not(unix))]
        Ok(false)
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

fn set_surface_environment(options: &mut SurfaceOptions, key: &str, value: &str) {
    if let Some((_, current)) = options.extra_env.iter_mut().find(|(candidate, _)| candidate == key)
    {
        *current = value.into();
    } else {
        options.extra_env.push((key.into(), value.into()));
    }
}

fn configure_agent_browser_session(options: &mut SurfaceOptions, terminal_id: &str) {
    let enabled = options
        .extra_env
        .iter()
        .any(|(key, value)| key == "CMUX_TUI_AGENT_BROWSER_PROVIDER" && value == "1");
    if enabled {
        // agent-browser daemons are keyed by session. A distinct caller
        // session prevents a command from another workspace from silently
        // reusing the first workspace's page-scoped CDP connection.
        set_surface_environment(options, "AGENT_BROWSER_SESSION", &format!("cmux-{terminal_id}"));
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
    fn tty_name(&self) -> Option<PathBuf> {
        None
    }
}

#[cfg(all(test, unix))]
struct FdMasterPty {
    file: std::fs::File,
    size: Mutex<PtySize>,
}

#[cfg(all(test, unix))]
impl MasterPty for FdMasterPty {
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

    fn process_group_leader(&self) -> Option<libc::pid_t> {
        None
    }

    fn as_raw_fd(&self) -> Option<std::os::unix::io::RawFd> {
        use std::os::fd::AsRawFd;
        Some(self.file.as_raw_fd())
    }

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
    fn journal_target(&self) -> Option<(Arc<Mux>, Arc<TerminalPublicId>)> {
        let terminal_id = self.terminal_public_id.clone()?;
        let mux = self.mux.upgrade()?;
        (mux.terminal_journal_enabled() && self.journal_capture_supported)
            .then_some((mux, terminal_id))
    }

    fn journal_output_if_open(
        &self,
        (mux, terminal_id): (Arc<Mux>, Arc<TerminalPublicId>),
        bytes: Vec<u8>,
    ) {
        let occurred_at_ms = crate::workspace_registry::unix_epoch_ms().unwrap_or(0);
        for chunk in bytes.chunks(crate::journal_ingress::TERMINAL_OUTPUT_INGRESS_BYTES) {
            let mut pending = chunk.to_vec();
            loop {
                let space_epoch = {
                    let _gate = self.journal_capture_gate.lock().unwrap();
                    if !self.journal_capture_open.load(Ordering::Acquire) {
                        return;
                    }
                    let retry = match mux.try_journal_terminal_output(
                        terminal_id.clone(),
                        self.journal_generation.clone(),
                        occurred_at_ms,
                        pending,
                    ) {
                        Ok(retry) => retry,
                        Err(error) => {
                            self.journal_capture_open.store(false, Ordering::Release);
                            mux.request_daemon_shutdown();
                            eprintln!(
                                "cmux-tui: terminal journal capture failed; stopping daemon: {error}"
                            );
                            return;
                        }
                    };
                    let Some((retry, space_epoch)) = retry else { break };
                    pending = retry;
                    space_epoch
                };
                if let Err(error) = mux.wait_for_terminal_journal_space(space_epoch) {
                    self.journal_capture_open.store(false, Ordering::Release);
                    mux.request_daemon_shutdown();
                    eprintln!(
                        "cmux-tui: terminal journal capture failed; stopping daemon: {error}"
                    );
                    return;
                }
            }
        }
    }

    fn journal_geometry(&self, geometry: PtyGeometry) {
        let (Some(terminal_id), Some(mux)) = (self.terminal_public_id.clone(), self.mux.upgrade())
        else {
            return;
        };
        mux.journal_terminal_resize(
            terminal_id,
            self.journal_generation.clone(),
            geometry.cols,
            geometry.rows,
            geometry.cell_width,
            geometry.cell_height,
        );
    }

    fn view_scrollbar_locked(&self, term: &mut Terminal) -> Option<Scrollbar> {
        let scrollbar = term.scrollbar()?;
        let bottom = scrollbar.total.saturating_sub(scrollbar.len);
        let screen = term.active_screen();
        let mut viewport = self.viewport.lock().unwrap();
        let had_anchor = viewport.anchor(screen).is_some();
        let resolved = viewport
            .anchor(screen)
            .and_then(|anchor| term.tracked_screen_point(anchor))
            .map(|(_, row)| u64::from(row).min(bottom));
        let offset = match (had_anchor, resolved) {
            (_, Some(offset)) => offset,
            (false, None) => bottom,
            (true, None) if bottom > 0 => {
                *viewport.anchor_mut(screen) = term.track_screen_point(0, 0).ok();
                if viewport.anchor(screen).is_some() { 0 } else { bottom }
            }
            (true, None) => {
                *viewport.anchor_mut(screen) = None;
                bottom
            }
        };
        if offset == bottom {
            *viewport.anchor_mut(screen) = None;
        }
        Some(Scrollbar { offset, ..scrollbar })
    }

    fn set_view_scroll_offset_locked(&self, term: &mut Terminal, offset: u64) {
        let Some(scrollbar) = term.scrollbar() else { return };
        let bottom = scrollbar.total.saturating_sub(scrollbar.len);
        let target = offset.min(bottom);
        let screen = term.active_screen();
        let mut viewport = self.viewport.lock().unwrap();
        let anchor = viewport.anchor_mut(screen);
        if target == bottom {
            *anchor = None;
            return;
        }
        let Ok(target) = u32::try_from(target) else {
            *anchor = None;
            return;
        };
        if anchor
            .as_mut()
            .is_some_and(|anchor| term.set_tracked_screen_point(anchor, 0, target).is_ok())
        {
            return;
        }
        *anchor = term.track_screen_point(0, target).ok();
    }

    #[cfg(test)]
    fn run_geometry_test_hook(&self, step: PtyGeometryTestStep) {
        let hook = self.geometry_test_hook.lock().unwrap().clone();
        if let Some(hook) = hook {
            hook(step);
        }
    }

    /// Snapshot sparse colors and the host-resolved cursor visual without
    /// touching the shared renderer or consuming its damage.
    fn terminal_colors_locked(&self, term: &Terminal, defaults: DefaultColors) -> TerminalColors {
        TerminalColors::from_terminal(term, defaults)
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
            Some(PtyRuntime::Local { master, .. }) => master.as_deref(),
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
        self.journal_geometry(next);
        #[cfg(test)]
        self.run_geometry_test_hook(if refresh_attach_colors {
            PtyGeometryTestStep::ResizeCommitBoundary
        } else {
            PtyGeometryTestStep::CellPixelCommitBoundary
        });
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
            #[cfg(test)]
            if let Some(hook) = before_upgrade.lock().unwrap().clone() {
                hook();
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
    use crate::MuxEvent;

    #[test]
    fn agent_browser_provider_uses_a_terminal_local_daemon_session() {
        let mut options = SurfaceOptions {
            extra_env: vec![
                ("CMUX_TUI_AGENT_BROWSER_PROVIDER".into(), "1".into()),
                ("AGENT_BROWSER_SESSION".into(), "unsafe-shared-session".into()),
            ],
            ..SurfaceOptions::default()
        };
        configure_agent_browser_session(&mut options, "term_0123456789abcdef");
        assert_eq!(
            options
                .extra_env
                .iter()
                .find(|(key, _)| key == "AGENT_BROWSER_SESSION")
                .map(|(_, value)| value.as_str()),
            Some("cmux-term_0123456789abcdef")
        );
    }

    #[test]
    fn terminal_projection_has_distinct_view_identity_and_shared_runtime() {
        let mux = Mux::new_for_test("terminal-projection", SurfaceOptions::default());
        let source =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let source_identity = source.resource_identity().unwrap().clone();
        let projection = source
            .project_terminal(
                2,
                TabResourceIdentity::new(
                    crate::resource::TabPublicId::random().unwrap(),
                    source_identity.content_id,
                ),
            )
            .unwrap();

        assert_eq!(source.id, 1);
        assert_eq!(projection.id, 2);
        assert!(source.shares_terminal_runtime(&projection));
        let foreign_identity = TabResourceIdentity::new(
            crate::resource::TabPublicId::random().unwrap(),
            ContentPublicId::Terminal(TerminalPublicId::random().unwrap()),
        );
        assert!(source.project_terminal(3, foreign_identity).is_err());

        source.set_name(Some("source".into()));
        projection.set_name(Some("projection".into()));
        assert_eq!(source.name().as_deref(), Some("source"));
        assert_eq!(projection.name().as_deref(), Some("projection"));

        projection.resize(91, 37).unwrap();
        assert_eq!(source.size(), (91, 37));
        source.with_terminal(|terminal| terminal.vt_write(b"shared-output"));
        let projected_text =
            projection.with_terminal(|terminal| terminal.viewport_text().unwrap()).unwrap();
        assert!(projected_text.contains("shared-output"));

        source.with_terminal(|terminal| {
            for line in 0..48 {
                terminal.vt_write(format!("\r\nline-{line:02}").as_bytes());
            }
        });
        let bottom = projection.view_scrollbar().unwrap();
        assert!(!bottom.scrolled_back());
        source.view_scroll_delta(-5).unwrap();
        let source_scrollbar = source.view_scrollbar().unwrap();
        let projection_scrollbar = projection.view_scrollbar().unwrap();
        assert!(source_scrollbar.scrolled_back());
        assert_eq!(projection_scrollbar, bottom);
        let compatibility_scrollbar =
            source.with_terminal(|terminal| terminal.scrollbar().unwrap()).unwrap();
        assert_eq!(compatibility_scrollbar, bottom);

        let mut source_render = RenderState::new().unwrap();
        let mut projection_render = RenderState::new().unwrap();
        let source_frame = source.render_view_frame(&mut source_render).unwrap();
        let projection_frame = projection.render_view_frame(&mut projection_render).unwrap();
        assert_ne!(source_frame.frame.runs(), projection_frame.frame.runs());
        assert_eq!(projection.view_scrollbar().unwrap(), bottom);
        let compatibility_after_render =
            source.with_terminal(|terminal| terminal.scrollbar().unwrap()).unwrap();
        assert_eq!(compatibility_after_render, bottom);

        let writer = CapturingWriter::default();
        replace_local_writer(&source, Box::new(writer.clone()));
        source.write_bytes(b"first").unwrap();
        projection.write_bytes(b"second").unwrap();
        assert_eq!(&*writer.0.lock().unwrap(), b"firstsecond");
    }

    fn append_disabled_kitty_replay_state(payload: &mut Vec<u8>) {
        for _ in 0..4 {
            payload.extend_from_slice(&0u64.to_le_bytes());
        }
        payload.extend_from_slice(&0u32.to_le_bytes());
        for _ in 0..4 {
            payload.extend_from_slice(
                &ghostty_vt::KittyImageIdCursors::DEFAULT_NEXT_IMAGE_ID.to_le_bytes(),
            );
        }
    }

    #[test]
    fn surface_enum_keeps_terminal_state_out_of_line() {
        // Test-only geometry and PTY hooks add fields that release builds omit.
        const MAX_TEST_SURFACE_BYTES: usize = 800;
        assert!(
            size_of::<Surface>() <= MAX_TEST_SURFACE_BYTES,
            "Surface grew to {} bytes (PTY {}, browser {}); keep large runtime state out of line",
            size_of::<Surface>(),
            size_of::<PtySurface>(),
            size_of::<BrowserSurface>()
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_surface_spawn_returns_within_deadline() {
        let (result_tx, result_rx) = sync_channel(1);
        std::thread::spawn(move || {
            let mux = Mux::new_for_test("macos-pty-deadline", SurfaceOptions::default());
            let options = SurfaceOptions {
                command: Some(vec!["/bin/sh".into(), "-c".into(), "exit 0".into()]),
                ..SurfaceOptions::default()
            };
            let result = Surface::spawn(9_001, options, Arc::downgrade(&mux))
                .map(drop)
                .map_err(|error| error.to_string());
            let _ = result_tx.send(result);
        });

        result_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("macOS surface PTY spawn blocked past its five-second deadline")
            .expect("macOS surface PTY spawn failed");
    }

    #[derive(Clone, Default)]
    struct CapturingWriter(Arc<Mutex<Vec<u8>>>);

    impl Write for CapturingWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    struct TerminalProbeDuringWrite {
        written: Arc<Mutex<Vec<u8>>>,
        surface: Weak<Surface>,
    }

    impl Write for TerminalProbeDuringWrite {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            let Some(surface) = self.surface.upgrade() else {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "surface was dropped",
                ));
            };
            surface.with_terminal(|_| ());
            self.written.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn replace_local_writer(surface: &Surface, replacement: Box<dyn Write + Send>) {
        let pty = surface.as_pty().unwrap();
        let mut runtime = pty.runtime.lock().unwrap();
        let PtyRuntime::Local { writer, .. } = &mut *runtime else {
            panic!("test surface unexpectedly uses a terminal host");
        };
        *writer = replacement;
    }

    #[test]
    fn test_surface_accepts_non_uuid_public_terminal_identity() {
        let mux = Mux::new_for_test("opaque-terminal-id", SurfaceOptions::default());
        let terminal = TerminalPublicId::parse("term_ffffffffffffffffffffffffffffffff").unwrap();
        let tab =
            crate::resource::TabPublicId::parse("tab_00000000000000000000000000000001").unwrap();
        let identity = TabResourceIdentity::persisted_terminal(tab, terminal);
        let surface = Surface::spawn_for_test_with_resource_identity(
            1,
            SurfaceOptions::default(),
            Arc::downgrade(&mux),
            Some(identity.clone()),
        )
        .unwrap();
        assert_eq!(surface.resource_identity(), Some(&identity));
    }

    #[cfg(unix)]
    #[test]
    fn hosted_mirror_never_answers_terminal_queries() {
        let mux = Mux::new_for_test("hosted-query-authority", SurfaceOptions::default());
        let callbacks =
            hosted_terminal_callbacks(1, Arc::downgrade(&mux), Arc::new(AtomicBool::new(false)));

        assert!(
            callbacks.on_pty_write.is_none(),
            "only the durable terminal host may answer Kitty/DA/DSR queries"
        );

        // Exercise the exact query that cmux-tui uses for Kitty graphics
        // detection. The mirror still parses it for screen state, but with no
        // PTY callback it cannot inject a duplicate `ESC_Gi=31;OK ESC\\` into
        // the child input after the authoritative host has already replied.
        let mut term = Terminal::new(80, 24, 0, callbacks).unwrap();
        term.vt_write(b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c");
    }

    #[cfg(unix)]
    #[test]
    fn deferred_cell_pixel_responses_run_on_the_bounded_mux_pool() {
        let mux = Mux::new_for_test("bounded-deferred-cell-pixel", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let responses = Arc::new(crate::terminal_host_runtime::ControlResponses::new_for_test());
        Surface::install_deferred_cell_pixel_handler(&surface, &responses);
        let (thread_name_tx, thread_name_rx) = std::sync::mpsc::channel();
        surface.as_pty().unwrap().deferred_cell_pixel_ack_test_hook.lock().unwrap().replace(
            Arc::new(move || {
                let name = std::thread::current().name().unwrap_or_default().to_owned();
                let _ = thread_name_tx.send(name);
            }),
        );

        let mut frame = Frame::new(MessageKind::CellPixelSizeAck, vec![8, 0, 16, 0]);
        frame.request_id = 1;
        responses.invoke_deferred_cell_pixel_handler_for_test(
            1,
            (8, 16),
            crate::terminal_host_runtime::DeferredCellPixelResolution::Response(frame),
        );

        let thread_name = thread_name_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(
            thread_name.starts_with("mux-deadline-"),
            "deferred acknowledgement ran on unbounded worker {thread_name:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn disconnected_deferred_cell_pixel_resolutions_do_not_schedule_work() {
        let mux = Mux::new_for_test("disconnected-deferred-cell-pixel", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let responses = Arc::new(crate::terminal_host_runtime::ControlResponses::new_for_test());
        Surface::install_deferred_cell_pixel_handler(&surface, &responses);
        let (called_tx, called_rx) = std::sync::mpsc::channel();
        surface.as_pty().unwrap().deferred_cell_pixel_ack_test_hook.lock().unwrap().replace(
            Arc::new(move || {
                let _ = called_tx.send(());
            }),
        );

        responses.invoke_deferred_cell_pixel_handler_for_test(
            1,
            (8, 16),
            crate::terminal_host_runtime::DeferredCellPixelResolution::Disconnected,
        );

        assert!(
            called_rx.recv_timeout(Duration::from_millis(100)).is_err(),
            "a disconnect-only resolution spawned reconciliation work"
        );
    }

    #[test]
    fn attach_colors_preserve_same_valued_authored_palette_override() {
        let color = Rgb { r: 0x44, g: 0x55, b: 0x66 };
        let mut defaults = DefaultColors::default();
        defaults.palette[4] = Some(color);
        let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
        term.set_default_palette(&defaults.palette);

        term.vt_write(b"\x1b]4;4;#445566\x07");
        let colors = TerminalColors::from_terminal(&term, defaults);
        assert_eq!(colors.palette[4], Some(color));
        assert!(
            colors
                .palette
                .iter()
                .enumerate()
                .all(|(index, entry)| { index == 4 || entry.is_none() })
        );

        term.vt_write(b"\x1b]104;4\x07");
        let colors = TerminalColors::from_terminal(&term, defaults);
        assert_eq!(colors.palette[4], None);
    }

    #[test]
    fn attach_colors_do_not_consume_shared_render_damage() {
        let mut term = Terminal::new(5, 1, 0, Callbacks::default()).unwrap();
        let mut shared_render = RenderState::new().unwrap();
        shared_render.update(&mut term).unwrap();
        shared_render.set_clean();

        term.vt_write(b"changed");
        let _ = TerminalColors::from_terminal(&term, DefaultColors::default());

        shared_render.update(&mut term).unwrap();
        assert_ne!(shared_render.dirty(), Dirty::Clean);
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
    fn unspecified_ghostty_cursor_blink_stays_mode_12_authoritative_in_local_and_mirror() {
        let defaults = DefaultColors {
            cursor_style: Some(CursorShape::Bar),
            cursor_blink: None,
            ..DefaultColors::default()
        };
        let mut local = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        replace_ghostty_cursor_defaults(&mut local, defaults);

        assert_eq!(local.effective_cursor_visual().unwrap(), (CursorShape::Bar, true));
        let initial_colors = TerminalColors::from_terminal(&local, defaults);
        assert_eq!(initial_colors.cursor_style, Some(CursorShape::Bar));
        assert_eq!(initial_colors.cursor_blink, Some(true));

        // A process-separated renderer starts from the resolved cursor pair
        // carried beside its replay, then consumes the same subsequent VT
        // bytes as the authoritative parser.
        let mut mirror = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        replace_ghostty_cursor_defaults(&mut mirror, defaults);
        mirror.vt_write(&terminal_color_override_full_state(&local.color_overrides()));

        let mut local_render = RenderState::new().unwrap();
        let mut mirror_render = RenderState::new().unwrap();
        for (sequence, expected_blink) in [
            (b"".as_slice(), true),
            (b"\x1b[?12l".as_slice(), false),
            (b"\x1b[?12h".as_slice(), true),
        ] {
            local.vt_write(sequence);
            mirror.vt_write(sequence);
            local_render.update(&mut local).unwrap();
            mirror_render.update(&mut mirror).unwrap();
            let expected = (CursorShape::Bar, expected_blink);
            assert_eq!(local_render.cursor_visual().unwrap(), expected);
            assert_eq!(mirror_render.cursor_visual().unwrap(), expected);
            assert_eq!(
                TerminalColors::from_terminal(&local, defaults).cursor_blink,
                Some(expected_blink)
            );
        }
    }

    #[test]
    fn explicit_ghostty_cursor_blink_defaults_pass_through_unchanged() {
        for configured in [false, true] {
            let defaults = DefaultColors {
                cursor_style: Some(CursorShape::Underline),
                cursor_blink: Some(configured),
                ..DefaultColors::default()
            };
            let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
            replace_ghostty_cursor_defaults(&mut term, defaults);
            assert_eq!(
                term.effective_cursor_visual().unwrap(),
                (CursorShape::Underline, configured)
            );
            term.vt_write(b"\x1b[0 q");
            assert_eq!(
                term.effective_cursor_visual().unwrap(),
                (CursorShape::Underline, configured)
            );
        }
    }

    #[test]
    fn attach_colors_use_decscusr_visual_then_restore_cursor_defaults() {
        let mut term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        let defaults = DefaultColors {
            cursor_style: Some(CursorShape::Bar),
            cursor_blink: Some(false),
            ..DefaultColors::default()
        };
        term.set_default_cursor(defaults.cursor_style, defaults.cursor_blink);

        term.vt_write(b"\x1b[3 q");
        let colors = TerminalColors::from_terminal(&term, defaults);
        assert_eq!(colors.cursor_style, Some(CursorShape::Underline));
        assert_eq!(colors.cursor_blink, Some(true));

        term.vt_write(b"\x1b[0 q");
        let colors = TerminalColors::from_terminal(&term, defaults);
        assert_eq!(colors.cursor_style, Some(CursorShape::Bar));
        assert_eq!(colors.cursor_blink, Some(false));
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

    #[cfg(unix)]
    #[test]
    fn local_same_pair_alt_screen_roundtrip_forces_resolved_cursor_colors() {
        let mux = Mux::new_for_test("local-cursor-activity", SurfaceOptions::default());
        let options = SurfaceOptions {
            command: Some(vec![
                "/bin/sh".into(),
                "-c".into(),
                "sleep 0.2; printf '\\033[?1049h\\033[?1049l'; sleep 0.2".into(),
            ]),
            ..SurfaceOptions::default()
        };
        let surface = Surface::spawn(1, options, Arc::downgrade(&mux)).unwrap();
        let attach = surface.attach_stream().unwrap();
        let expected = (attach.colors.cursor_style, attach.colors.cursor_blink);
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut output = Vec::new();
        let colors = loop {
            assert!(Instant::now() < deadline, "local cursor activity was not published");
            match attach.stream.recv_timeout(Duration::from_millis(250)) {
                Ok(AttachFrame::Output(bytes)) => output.extend_from_slice(&bytes),
                Ok(AttachFrame::ColorsChanged(colors)) => break colors,
                Ok(AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. }) => {}
                Ok(AttachFrame::OutputWithColors { .. }) => {
                    panic!("local PTYs must use ordered Output then ColorsChanged")
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    panic!("local cursor activity stream disconnected")
                }
            }
        };

        assert!(
            output.windows(16).any(|window| window == b"\x1b[?1049h\x1b[?1049l"),
            "same-chunk alt-screen roundtrip was not mirrored"
        );
        assert_eq!((colors.cursor_style, colors.cursor_blink), expected);
        assert!(colors.cursor_style.is_some() && colors.cursor_blink.is_some());
    }

    #[cfg(unix)]
    #[test]
    fn local_surface_retains_real_status_after_final_pty_bytes() {
        fn run(mux: &Arc<Mux>, id: SurfaceId, script: &str, final_text: &str) -> TerminalExit {
            let surface = Surface::spawn(
                id,
                SurfaceOptions {
                    command: Some(vec!["/bin/sh".into(), "-c".into(), script.into()]),
                    ..SurfaceOptions::default()
                },
                Arc::downgrade(mux),
            )
            .unwrap();
            let deadline = Instant::now() + Duration::from_secs(2);
            let exit = loop {
                if let Some(exit) = surface.terminal_exit()
                    && surface.is_dead()
                {
                    break exit;
                }
                assert!(Instant::now() < deadline, "local PTY did not publish its exit");
                std::thread::sleep(Duration::from_millis(5));
            };
            let text =
                surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
            assert!(
                text.contains(final_text),
                "exit became visible before final PTY bytes: {text:?}"
            );
            exit
        }

        let mux = Mux::new_for_test("local-exit-status", SurfaceOptions::default());
        assert_eq!(
            run(&mux, 101, "printf final-exit; exit 17", "final-exit").outcome,
            crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 }
        );
        assert_eq!(
            run(&mux, 102, "printf final-signal; kill -TERM $$", "final-signal").outcome,
            crate::terminal_host_protocol::TerminalExitOutcome::Signal {
                signal: libc::SIGTERM,
                core_dumped: false,
            }
        );
    }

    /// The selection rule: pass xterm-ghostty through only when the outer
    /// terminal already advertised it. Prompts that sniff the TERM name
    /// then take the same branch inside cmux-tui as in the host terminal
    /// (colors match), and children never get a less compatible TERM than
    /// the host terminal gave the user.
    #[test]
    fn child_term_passes_ghostty_through_and_nothing_else() {
        assert_eq!(child_term_for(Some("xterm-ghostty")), "xterm-ghostty");
        assert_eq!(child_term_for(Some("xterm-256color")), "xterm-256color");
        assert_eq!(child_term_for(Some("screen")), "xterm-256color");
        assert_eq!(child_term_for(Some("alacritty")), "xterm-256color");
        assert_eq!(child_term_for(Some("")), "xterm-256color");
        assert_eq!(child_term_for(None), "xterm-256color");
    }

    /// default_child_term composes the rule with this process's real TERM
    /// and must agree with it.
    #[test]
    fn default_child_term_matches_selection_rule() {
        let outer = std::env::var("TERM").ok();
        assert_eq!(default_child_term(), child_term_for(outer.as_deref()));
    }

    #[cfg(unix)]
    fn spawn_and_read_colorterm(id: SurfaceId, extra_env: Vec<(String, String)>) -> String {
        let mux = Mux::new_for_test("colorterm-env", SurfaceOptions::default());
        let surface = Surface::spawn(
            id,
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    "printf 'CT=[%s]' \"$COLORTERM\"".into(),
                ]),
                extra_env,
                ..SurfaceOptions::default()
            },
            Arc::downgrade(&mux),
        )
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let text =
                surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
            if let Some(start) = text.find("CT=[")
                && let Some(len) = text[start..].find(']')
            {
                return text[start..=start + len].to_string();
            }
            assert!(Instant::now() < deadline, "child never printed COLORTERM: {text:?}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// The embedded ghostty-vt terminal always parses 24-bit SGR and the
    /// frontends forward RGB cells losslessly, so children must be able to
    /// rely on truecolor even when the session server itself was started from
    /// an environment without COLORTERM (launchd, ssh, cron). Without the
    /// guarantee, truecolor-capable programs quantize to the 256-color cube
    /// and render visibly different colors than the same program run directly
    /// in the host terminal.
    #[cfg(unix)]
    #[test]
    fn child_env_advertises_truecolor_colorterm() {
        assert_eq!(spawn_and_read_colorterm(151, Vec::new()), "CT=[truecolor]");
    }

    /// extra_env stays authoritative: a caller that sets COLORTERM explicitly
    /// wins over the built-in truecolor advertisement.
    #[cfg(unix)]
    #[test]
    fn child_env_colorterm_yields_to_extra_env() {
        assert_eq!(
            spawn_and_read_colorterm(152, vec![("COLORTERM".into(), "24bit".into())]),
            "CT=[24bit]"
        );
    }

    #[test]
    fn terminal_color_override_delta_sets_and_resets_sparse_state() {
        let mut colors = TerminalColorOverrides {
            foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
            background: Some(Rgb { r: 4, g: 5, b: 6 }),
            cursor: Some(Rgb { r: 7, g: 8, b: 9 }),
            cursor_visual: Some((CursorShape::Underline, true)),
            ..Default::default()
        };
        colors.palette[42] = Some(Rgb { r: 10, g: 11, b: 12 });
        let mut terminal = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
        terminal.vt_write(&terminal_color_override_delta(&Default::default(), &colors));
        assert_eq!(terminal.color_overrides(), colors);

        let reset = TerminalColorOverrides {
            cursor_visual: Some((CursorShape::Block, false)),
            ..Default::default()
        };
        terminal.vt_write(&terminal_color_override_delta(&colors, &reset));
        assert_eq!(terminal.color_overrides(), reset);
    }

    #[test]
    fn terminal_color_override_full_state_resets_then_applies_resolved_cursor() {
        let colors = TerminalColorOverrides {
            cursor_visual: Some((CursorShape::Bar, true)),
            ..Default::default()
        };
        assert_eq!(terminal_color_override_full_state(&colors), b"\x1b[0 q\x1b[5 q");
        assert_eq!(terminal_color_override_full_state(&TerminalColorOverrides::default()), b"");
    }

    #[test]
    fn legacy_v1_full_state_preserves_cursor_from_portable_replay() {
        let mut terminal = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[3 q\x1b[?12l");
        let mut legacy = crate::terminal_host_runtime::decode_terminal_color_overrides(&[
            1, 0, 0, 0, 0, 0, 0, 0,
        ])
        .unwrap();
        legacy.palette[9] = Some(Rgb { r: 9, g: 9, b: 9 });

        let metadata = terminal_color_override_full_state(&legacy);
        assert!(!metadata.windows(5).any(|window| window == b"\x1b[0 q"));
        terminal.vt_write(&metadata);
        assert_eq!(terminal.effective_cursor_visual().unwrap(), (CursorShape::Underline, false));
        assert_eq!(terminal.color_overrides().palette[9], Some(Rgb { r: 9, g: 9, b: 9 }));
    }

    #[test]
    fn legacy_v1_host_stream_preserves_raw_cursor_and_sparse_color_contract() {
        let mut terminal = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
        terminal.set_default_cursor(Some(CursorShape::Bar), Some(false));
        let applied = crate::terminal_host_runtime::decode_terminal_color_overrides(&[
            1, 0, 0, 0, 0, 0, 0, 0,
        ])
        .unwrap();

        terminal.vt_write(b"ordinary output");
        assert!(terminal_color_overrides_match_applied(terminal.color_overrides(), &applied));

        // Version 1 carries cursor changes only in ordinary VT output. Both
        // DECSCUSR and mode 12 must survive without looking like an undeclared
        // sparse-color mutation that disconnects the host stream.
        terminal.vt_write(b"\x1b[3 q\x1b[?12l");
        assert_eq!(terminal.effective_cursor_visual().unwrap(), (CursorShape::Underline, false));
        assert!(terminal_color_overrides_match_applied(terminal.color_overrides(), &applied));

        // A later coupled v1 color frame has no cursor pair. Its absence means
        // unknown/preserve, while all legacy sparse colors remain authoritative.
        let next = crate::terminal_host_runtime::decode_terminal_color_overrides(&[
            1, 0, 1, 0, 0, 0, 0, 0, 1, 2, 3,
        ])
        .unwrap();
        terminal.vt_write(b"\x1b]10;#010203\x07");
        let delta = terminal_color_override_delta(&applied, &next);
        assert!(!delta.windows(5).any(|window| window == b"\x1b[0 q"));
        terminal.vt_write(&delta);
        assert_eq!(
            terminal.effective_cursor_visual().unwrap(),
            (CursorShape::Underline, false),
            "legacy v1 cursor absence must preserve raw VT cursor state"
        );
        assert!(terminal_color_overrides_match_applied(terminal.color_overrides(), &next));

        terminal.vt_write(b"stream remains live");
        assert!(terminal_color_overrides_match_applied(terminal.color_overrides(), &next));
    }

    #[test]
    fn legacy_v1_applied_state_ignores_only_cursor_metadata() {
        let applied = TerminalColorOverrides {
            foreground: Some(Rgb { r: 1, g: 2, b: 3 }),
            ..Default::default()
        };
        let observed = TerminalColorOverrides {
            foreground: applied.foreground,
            cursor_visual: Some((CursorShape::Block, true)),
            ..Default::default()
        };

        assert!(terminal_color_overrides_match_applied(observed.clone(), &applied));

        let mut mismatched = observed;
        mismatched.background = Some(Rgb { r: 4, g: 5, b: 6 });
        assert!(!terminal_color_overrides_match_applied(mismatched, &applied));
    }

    #[test]
    fn terminal_color_override_delta_maps_every_v2_cursor_visual_and_preserves_v1_absence() {
        let cases = [
            ((CursorShape::Block, true), b"\x1b[1 q".as_slice()),
            ((CursorShape::Block, false), b"\x1b[2 q".as_slice()),
            ((CursorShape::Underline, true), b"\x1b[3 q".as_slice()),
            ((CursorShape::Underline, false), b"\x1b[4 q".as_slice()),
            ((CursorShape::Bar, true), b"\x1b[5 q".as_slice()),
            ((CursorShape::Bar, false), b"\x1b[6 q".as_slice()),
        ];
        let mut previous = TerminalColorOverrides::default();
        for (cursor_visual, expected) in cases {
            let next =
                TerminalColorOverrides { cursor_visual: Some(cursor_visual), ..Default::default() };
            assert_eq!(terminal_color_override_delta(&previous, &next), expected);
            previous = next;
        }
        assert_eq!(
            terminal_color_override_delta(&previous, &previous),
            b"\x1b[6 q",
            "same-pair v2 metadata must force cursor reapplication"
        );
        assert_eq!(
            terminal_color_override_delta(&previous, &TerminalColorOverrides::default()),
            b""
        );
    }

    #[test]
    fn attach_tap_overflow_cancels_the_shared_lifecycle_once() {
        let lifecycle = AttachLifecycle::default();
        let (tap, _receiver) = AttachTap::pair(lifecycle.clone(), 1, usize::MAX);

        assert!(tap.try_send(AttachFrame::ColorsChanged(Arc::new(TerminalColors::default()))));
        assert!(!tap.try_send(AttachFrame::ColorsChanged(Arc::new(TerminalColors::default()))));
        assert!(lifecycle.is_canceled());
        assert!(lifecycle.overflowed());
        assert!(lifecycle.claim_overflow_report());
        assert!(!lifecycle.claim_overflow_report());
    }

    #[test]
    fn attach_tap_overflow_is_bounded_by_retained_bytes() {
        let lifecycle = AttachLifecycle::default();
        let frame_bytes = AttachFrame::Output(vec![1]).retained_bytes();
        let (tap, _receiver) = AttachTap::pair(lifecycle.clone(), 4, frame_bytes);

        assert!(tap.try_send(AttachFrame::Output(vec![1])));
        assert!(!tap.try_send(AttachFrame::Output(vec![2])));
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
    fn exited_host_placeholder_preserves_identity_and_swallows_input() {
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
        // Keep-on-exit terminals stay interactive surfaces after their child
        // dies, so input to the dead PTY is a harmless no-op, not an error.
        surface.write_bytes(b"must not reach a dead host").unwrap();
        surface.write_paste(b"must not reach a dead host").unwrap();
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
    fn stalled_render_tap_retains_only_latest_frame_and_scroll_state_in_order() {
        let mux = Mux::new_for_test("render-tap-latest", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();
        let attach = surface.attach_render_stream().unwrap();
        let mut generation = pty.render.lock().unwrap().built_generation;

        let mut expected_dirty_rows = std::collections::BTreeSet::new();
        {
            let mut term = pty.term.lock().unwrap();
            term.vt_write(b"\x1b[1;1Ha");
            generation += 1;
            pty.build_frame_locked(&mut term, generation, false).unwrap();
            expected_dirty_rows.extend(
                pty.render
                    .lock()
                    .unwrap()
                    .latest
                    .as_ref()
                    .unwrap()
                    .frame
                    .dirty_rows
                    .iter()
                    .copied(),
            );
            broadcast_render_scroll_locked(pty, (4, false));
            term.vt_write(b"\x1b[2;1Hb");
            generation += 1;
            pty.build_frame_locked(&mut term, generation, false).unwrap();
            expected_dirty_rows.extend(
                pty.render
                    .lock()
                    .unwrap()
                    .latest
                    .as_ref()
                    .unwrap()
                    .frame
                    .dirty_rows
                    .iter()
                    .copied(),
            );
            broadcast_render_scroll_locked(pty, (9, true));
            term.vt_write(b"\x1b[3;1Hc");
            generation += 1;
            pty.build_frame_locked(&mut term, generation, false).unwrap();
            expected_dirty_rows.extend(
                pty.render
                    .lock()
                    .unwrap()
                    .latest
                    .as_ref()
                    .unwrap()
                    .frame
                    .dirty_rows
                    .iter()
                    .copied(),
            );
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
        assert_eq!(frame.frame.seq, latest.frame.seq);
        assert_eq!(
            frame.frame.dirty_rows.iter().copied().collect::<std::collections::BTreeSet<_>>(),
            expected_dirty_rows,
            "coalescing the newest snapshot must preserve every undrained dirty row"
        );
        for row in &expected_dirty_rows {
            assert_eq!(frame.frame.styled_row(*row), latest.frame.styled_row(*row));
        }

        let latest_uncoalesced = {
            let mut term = pty.term.lock().unwrap();
            term.vt_write(b"d");
            generation += 1;
            pty.build_frame_locked(&mut term, generation, false).unwrap();
            let latest = pty.render.lock().unwrap().latest.clone().unwrap();
            broadcast_render_scroll_locked(pty, (11, false));
            latest
        };
        let first = attach.stream.try_recv().unwrap();
        let second = attach.stream.try_recv().unwrap();
        let RenderAttachFrame::Frame(frame) = first else {
            panic!("frame must precede the later scroll state");
        };
        assert!(
            Arc::ptr_eq(&frame, &latest_uncoalesced),
            "a tap that keeps up must reuse the shared immutable frame"
        );
        assert!(matches!(
            second,
            RenderAttachFrame::ScrollChanged { offset: 11, at_bottom: false }
        ));
        assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn render_attachments_are_bounded_across_a_mux() {
        const EXPECTED_MAX_ATTACHMENTS: usize = 64;

        let mux = Mux::new_for_test("render-tap-cap", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let mut attachments = Vec::with_capacity(EXPECTED_MAX_ATTACHMENTS);
        for _ in 0..EXPECTED_MAX_ATTACHMENTS {
            attachments.push(surface.attach_render_stream().unwrap());
        }

        assert!(matches!(surface.attach_render_stream(), Err(ghostty_vt::Error::OutOfSpace)));
        attachments.pop();
        assert!(surface.attach_render_stream().is_ok());
    }

    #[test]
    fn dropped_idle_render_attachments_remove_their_taps_immediately() {
        let mux = Mux::new_for_test("render-tap-drop", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();

        for _ in 0..128 {
            let attachment = surface.attach_render_stream().unwrap();
            assert_eq!(pty.render.lock().unwrap().taps.len(), 1);
            drop(attachment);
            assert!(
                pty.render.lock().unwrap().taps.is_empty(),
                "an idle closed attachment remained registered until later output"
            );
        }
    }

    #[test]
    fn changed_kitty_limits_resynchronize_live_byte_attachments() {
        let mux = Mux::new_for_test("kitty-limit-resync", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attach = surface.attach_stream().unwrap();
        surface
            .with_terminal(|terminal| {
                terminal.vt_write(b"\x1b_Ga=T,t=d,f=24,i=41,p=7,s=1,v=1,c=1,r=1,q=2;AAAA\x1b\\");
            })
            .unwrap();

        surface.set_kitty_graphics_limits(0, 0, 0, 0).unwrap();

        assert!(
            matches!(
                attach.stream.recv_timeout(Duration::from_secs(1)),
                Ok(AttachFrame::Resized { .. } | AttachFrame::ResizedWithColors { .. })
            ),
            "a byte-stream mirror was left on the pre-eviction Kitty scene"
        );
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
        const OLD_VT_REPLAY_MAX_BYTES: usize = 8 * 1024 * 1024;
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
            first_chunk.len() > OLD_VT_REPLAY_MAX_BYTES,
            "fixture must exceed the old {OLD_VT_REPLAY_MAX_BYTES}-byte resize replay budget"
        );
        assert!(first_chunk.len() <= ghostty_vt::KITTY_INFLIGHT_REPLAY_MAX_BYTES);

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
        let (cols, rows, replay, kitty_image_aliases) =
            match attach.stream.recv_timeout(Duration::from_secs(2)).unwrap() {
                AttachFrame::Resized { cols, rows, replay, kitty_image_aliases, .. }
                | AttachFrame::ResizedWithColors {
                    cols, rows, replay, kitty_image_aliases, ..
                } => (cols, rows, replay, kitty_image_aliases),
                _ => panic!("resize must publish replacement terminal state"),
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
    fn resize_replay_budget_covers_inflight_state_and_transport_limits() {
        assert_eq!(ghostty_vt::KITTY_INFLIGHT_REPLAY_MAX_BYTES, 13_595_480);
        assert_eq!(VT_REPLAY_TEXT_HEADROOM_BYTES, 2_097_152);
        assert_eq!(VT_REPLAY_MAX_BYTES, 15_692_632);
        assert_eq!(ATTACH_STREAM_MAX_BYTES - VT_REPLAY_MAX_BYTES, 1_084_584);
        assert_eq!(VT_REPLAY_MAX_BYTES.div_ceil(3) * 4, 20_923_512);
        const {
            assert!(
                VT_REPLAY_MAX_BYTES + VT_REPLAY_FRAME_METADATA_HEADROOM_BYTES
                    <= ATTACH_STREAM_MAX_BYTES
            );
        }
        assert!(VT_REPLAY_MAX_BYTES.div_ceil(3) * 4 < VT_REPLAY_ENCODED_TRANSPORT_MAX_BYTES);
    }

    #[test]
    fn resize_replay_failure_preflights_without_mutating_terminal_or_pty_geometry() {
        let mux = Mux::new_for_test("failed-resize-replay", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let attach = surface.attach_stream().unwrap();
        let pty = surface.as_pty().unwrap();
        let history = (0..40).map(|line| format!("history-{line:02}\r\n")).collect::<String>();
        let mut oversized = b"\x1b_Ga=t,t=d,f=24,i=197,s=1,v=1,m=1,q=2;".to_vec();
        oversized.resize(ghostty_vt::KITTY_INFLIGHT_REPLAY_MAX_BYTES + 1, b'A');
        oversized.extend_from_slice(b"\x1b\\");
        let (text_before, scrollbar_before) = {
            let mut terminal = pty.term.lock().unwrap();
            terminal.vt_write(history.as_bytes());
            terminal.vt_write(&oversized);
            assert_eq!(
                terminal.vt_replay_bounded(VT_REPLAY_MAX_BYTES),
                Err(ghostty_vt::Error::OutOfSpace)
            );
            (terminal.plain_text().unwrap(), terminal.scrollbar())
        };

        let error = surface.resize(100, 30).unwrap_err();

        assert!(error.to_string().contains("geometry unchanged"), "{error:#}");
        assert_eq!(surface.size(), (80, 24));
        {
            let mut terminal = pty.term.lock().unwrap();
            assert_eq!((terminal.cols(), terminal.rows()), (80, 24));
            assert_eq!(terminal.plain_text().unwrap(), text_before);
            assert_eq!(terminal.scrollbar(), scrollbar_before);
        }
        let master = surface.test_master_size();
        assert_eq!(
            (master.cols, master.rows, master.pixel_width, master.pixel_height),
            (80, 24, 640, 384)
        );
        assert!(matches!(attach.stream.try_recv(), Err(TryRecvError::Empty)));
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

        assert!(surface.resize(100, 30).unwrap());
        assert_eq!(surface.size(), (100, 30));
        let master = surface.test_master_size();
        assert_eq!(
            (master.cols, master.rows, master.pixel_width, master.pixel_height),
            (100, 30, 800, 480)
        );
    }

    #[test]
    fn pty_eof_publishes_final_render_frame_before_surface_removal() {
        const FINAL_MARKER: &str = "CMUX_FINAL_RENDER_MARKER";

        let mux = Mux::new("pty-final-render", SurfaceOptions::default());
        let placement = mux
            .run_command_surface(
                vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    format!("IFS= read -r _; printf '{FINAL_MARKER}'"),
                ],
                None,
                true,
                None,
                None,
                Some((80, 24)),
            )
            .unwrap();
        let surface = mux.surface(placement.surface).unwrap();
        let attach = surface.attach_render_stream().unwrap();
        let events = mux.subscribe();

        let (entered_tx, entered_rx) = sync_channel(1);
        let (release_tx, release_rx) = sync_channel(1);
        let release_rx = Mutex::new(release_rx);
        {
            let pty = surface.as_pty().unwrap();
            *pty.frame_producer_before_upgrade.lock().unwrap() = Some(Arc::new(move || {
                let _ = entered_tx.try_send(());
                let _ = release_rx.lock().unwrap().recv_timeout(Duration::from_secs(5));
            }));
        }

        surface.write_bytes(b"go\n").unwrap();
        drop(surface);
        entered_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("frame producer did not receive the final output request");

        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match events.recv_timeout(remaining) {
                Ok(MuxEvent::SurfaceExited(id)) if id == placement.surface => break,
                Ok(_) => {}
                Err(error) => panic!("surface did not exit before frame worker release: {error}"),
            }
        }
        release_tx.send(()).unwrap();

        let frame = attach
            .stream
            .recv_timeout(Duration::from_secs(2))
            .expect("final render frame was dropped with the surface");
        let RenderAttachFrame::Frame(frame) = frame else {
            panic!("expected final render frame");
        };
        let rendered = frame
            .frame
            .styled_rows()
            .iter()
            .flat_map(|row| row.iter())
            .map(|cell| cell.text.as_str())
            .collect::<String>();
        assert!(
            rendered.contains(FINAL_MARKER),
            "final render frame did not contain producer receipt: {rendered:?}"
        );
        mux.shutdown();
    }

    #[test]
    fn clear_history_updates_the_authoritative_terminal_and_attach_mirrors() {
        let mux = Mux::new_for_test("clear-history", SurfaceOptions::default());
        let events = mux.subscribe();
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        surface.with_terminal(|term| {
            term.vt_write(b"\x1b]133;C\x07");
            for line in 0..40 {
                term.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            term.vt_write(b"visible");
        });
        let attach = surface.attach_stream().unwrap();
        let mut mirror =
            Terminal::new(attach.cols, attach.rows, 10_000, Callbacks::default()).unwrap();
        mirror.vt_write(&attach.replay);
        while events.try_recv().is_ok() {}

        surface.clear_history().unwrap();

        let AttachFrame::Output(bytes) =
            attach.stream.recv_timeout(Duration::from_secs(1)).unwrap()
        else {
            panic!("clear did not reach the attach mirror");
        };
        mirror.vt_write(&bytes);
        let authoritative_after = surface
            .with_terminal(|term| {
                assert_eq!(term.history_rows(), 0);
                term.viewport_text().unwrap()
            })
            .unwrap();
        assert!(
            !authoritative_after.contains("history-"),
            "completed visible rows survived clear-history: {authoritative_after:?}"
        );
        assert!(
            authoritative_after.ends_with("visible"),
            "active row did not survive clear-history: {authoritative_after:?}"
        );
        assert_eq!(mirror.history_rows(), 0);
        assert_eq!(mirror.viewport_text().unwrap(), authoritative_after);
        assert!(events.try_iter().any(|event| matches!(event, MuxEvent::SurfaceOutput(1))));
    }

    #[test]
    fn read_only_terminal_access_does_not_signal_stream_progress() {
        let mux = Mux::new_for_test("terminal-read-progress", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let progress = &surface.as_pty().unwrap().stream_progress;
        let revision_before = progress.revision();

        assert_eq!(surface.with_terminal(|term| term.history_rows()), Some(0));
        assert_eq!(surface.try_with_terminal(|term| term.history_rows()).unwrap(), 0);

        assert_eq!(progress.revision(), revision_before);
    }

    #[test]
    fn resource_wait_subscription_wakes_for_output_resize_reconnect_and_clear() {
        let mux = Mux::new_for_test("terminal-resource-progress", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let wake_deadline = || Some(Instant::now() + Duration::from_secs(1));

        let output = surface.subscribe_terminal_stream_change().unwrap();
        surface.apply_stream_output_for_test(b"progress-output").unwrap();
        assert!(
            output.wait_until(wake_deadline()),
            "terminal output did not wake the subscription"
        );

        let resize = surface.subscribe_terminal_stream_change().unwrap();
        assert!(surface.resize(91, 37).unwrap(), "test resize did not change the surface");
        assert!(
            resize.wait_until(wake_deadline()),
            "terminal resize did not wake the subscription"
        );

        let reconnect = surface.subscribe_terminal_stream_change().unwrap();
        surface.as_pty().unwrap().stream_progress.notify_reconnect();
        assert!(
            reconnect.wait_until(wake_deadline()),
            "authoritative reconnect progress did not wake the subscription"
        );

        surface.with_terminal(|term| {
            term.vt_write(b"\x1b]133;C\x07");
            for line in 0..40 {
                term.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            term.vt_write(b"active-command");
        });
        let clear = surface.subscribe_terminal_stream_change().unwrap();
        surface.clear_history().unwrap();
        assert!(clear.wait_until(wake_deadline()), "terminal clear did not wake the subscription");
    }

    #[test]
    fn stream_progress_rearms_expired_wait_when_output_races_final_release() {
        let progress = TerminalStreamProgress::default();
        let observed = progress.revision();
        let mut expired = progress.begin_clear_history_wait(Duration::ZERO);

        assert_eq!(progress.wait_for_change(observed, expired.deadline()), None);
        progress.notify();
        expired.mark_timed_out();
        drop(expired);

        let rearmed = progress.begin_clear_history_wait(Duration::from_secs(1));
        assert!(
            rearmed.deadline() > Instant::now(),
            "stream progress left the expired clear-history wait latched"
        );
    }

    #[test]
    fn pty_pixel_overflow_rejects_creation_and_geometry_updates_without_mutation() {
        let mux = Mux::new_for_test("pty-pixel-overflow", SurfaceOptions::default());
        let oversized = SurfaceOptions { cols: 10_000, ..SurfaceOptions::default() };
        let creation_error =
            Surface::spawn_for_test(1, oversized, Arc::downgrade(&mux)).unwrap_err();
        assert!(creation_error.to_string().contains("PTY pixel width exceeds 65535"));

        let surface =
            Surface::spawn_for_test(2, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let resize_error = surface.resize(10_000, 24).unwrap_err();
        assert!(resize_error.to_string().contains("PTY pixel width exceeds 65535"));
        let cell_error = surface.set_cell_pixel_size(1_000, 16).unwrap_err();
        assert!(cell_error.to_string().contains("PTY pixel width exceeds 65535"));

        assert_eq!(surface.size(), (80, 24));
        assert_eq!(surface.test_cell_pixel_size(), (8, 16));
        {
            let terminal = surface.as_pty().unwrap().term.lock().unwrap();
            assert_eq!((terminal.cols(), terminal.rows()), (80, 24));
        }
        let master = surface.test_master_size();
        assert_eq!(
            (master.cols, master.rows, master.pixel_width, master.pixel_height),
            (80, 24, 640, 384)
        );
    }

    #[test]
    fn clear_history_waits_for_a_partial_vt_sequence_to_finish() {
        let mux = Mux::new_for_test("clear-history-partial-vt", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        surface.with_terminal(|term| {
            for line in 0..40 {
                term.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            term.vt_write(b"\x1b]133;A\x07prompt> ");
            term.vt_write(b"\x1b[31");
        });
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();
        let clear_surface = surface.clone();
        std::thread::spawn(move || {
            let _ = finished_tx.send(clear_surface.clear_history());
        });

        assert!(
            finished_rx.recv_timeout(Duration::from_millis(25)).is_err(),
            "clear-history acknowledged before the partial CSI reached a safe boundary"
        );
        surface.apply_stream_output_for_test(b"m").unwrap();
        finished_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("clear-history did not resume after the CSI completed")
            .unwrap();

        surface.with_terminal(|term| {
            assert_eq!(term.history_rows(), 0);
            let viewport = term.viewport_text().unwrap();
            assert!(viewport.contains("prompt>"));
            assert!(!viewport.contains("history-"));
        });
    }

    #[test]
    fn clear_history_reports_a_partial_vt_sequence_that_does_not_finish() {
        let mux = Mux::new_for_test("clear-history-stalled-vt", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        surface.with_terminal(|term| {
            term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
        });

        let error = surface.clear_history().unwrap_err();

        assert_eq!(error.to_string(), CLEAR_HISTORY_STREAM_TIMEOUT_ERROR);
    }

    #[test]
    fn clear_history_reuses_timeout_until_stream_progress() {
        let mux = Mux::new_for_test("clear-history-shared-timeout", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        surface.with_terminal(|term| {
            term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
        });

        let first_error = surface.clear_history().unwrap_err();
        assert_eq!(first_error.to_string(), CLEAR_HISTORY_STREAM_TIMEOUT_ERROR);

        let second_started = Instant::now();
        let second_error = surface.clear_history().unwrap_err();
        assert_eq!(second_error.to_string(), CLEAR_HISTORY_STREAM_TIMEOUT_ERROR);
        assert!(
            second_started.elapsed() < Duration::from_millis(100),
            "a repeated clear restarted the full stream wait"
        );

        surface.apply_stream_output_for_test(b"m\x1b[31").unwrap();
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();
        let clear_surface = surface.clone();
        std::thread::spawn(move || {
            let _ = finished_tx.send(clear_surface.clear_history());
        });
        assert!(
            finished_rx.recv_timeout(Duration::from_millis(25)).is_err(),
            "new stream progress did not restore the bounded clear wait"
        );
        surface.apply_stream_output_for_test(b"m").unwrap();
        finished_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
    }

    #[test]
    fn clear_history_reports_when_active_input_reaches_retained_history() {
        let mux = Mux::new_for_test("clear-history-spanning-input", SurfaceOptions::default());
        let options = SurfaceOptions { cols: 8, rows: 3, ..SurfaceOptions::default() };
        let surface = Surface::spawn_for_test(1, options, Arc::downgrade(&mux)).unwrap();
        surface.with_terminal(|term| {
            for line in 0..5 {
                term.vt_write(format!("old-{line}\r\n").as_bytes());
            }
            term.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07123456789012345678901234567");
        });
        let (history_before, contents_before) = surface
            .with_terminal(|term| (term.history_rows(), term.plain_text().unwrap()))
            .unwrap();

        let error = surface.clear_history().unwrap_err();

        assert_eq!(error.to_string(), CLEAR_HISTORY_PRESERVATION_ERROR);
        surface.with_terminal(|term| {
            assert!(history_before > 0);
            assert_eq!(term.history_rows(), history_before);
            assert_eq!(term.plain_text().unwrap(), contents_before);
        });
    }

    #[test]
    fn clear_history_encodes_fallback_from_authoritative_keyboard_modes() {
        let mux = Mux::new_for_test("clear-history-key-mode", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let writer = CapturingWriter::default();
        replace_local_writer(&surface, Box::new(writer.clone()));
        surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));
        let input = KeyInput {
            key: ghostty_vt::sys::GHOSTTY_KEY_K,
            mods: ghostty_vt::Mods::SUPER,
            unshifted_codepoint: 'k' as u32,
            action: Some(ghostty_vt::KeyAction::Press),
            ..Default::default()
        };

        surface.clear_history_or_encode_key(Some(&input)).unwrap();

        assert_eq!(&*writer.0.lock().unwrap(), b"\x1b[107;9u");
    }

    #[test]
    fn clear_history_fallback_accepts_maximum_protocol_text_in_associated_text_mode() {
        let mux =
            Mux::new_for_test("clear-history-associated-text-limit", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let writer = CapturingWriter::default();
        replace_local_writer(&surface, Box::new(writer.clone()));
        surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>29u"));
        let input = KeyInput {
            key: ghostty_vt::sys::GHOSTTY_KEY_K,
            utf8: "x".repeat(4 * 1024),
            unshifted_codepoint: 'k' as u32,
            action: Some(ghostty_vt::KeyAction::Press),
            ..Default::default()
        };

        surface.clear_history_or_encode_key(Some(&input)).unwrap();

        assert!(
            writer.0.lock().unwrap().len() > 8 * 1024,
            "associated text did not exercise the encoded fallback bound"
        );
    }

    #[test]
    fn clear_history_reports_unencodable_alternate_screen_fallback() {
        let mux = Mux::new_for_test("clear-history-unencodable-key", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let writer = CapturingWriter::default();
        replace_local_writer(&surface, Box::new(writer.clone()));
        surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h"));
        let input = KeyInput {
            key: ghostty_vt::sys::GHOSTTY_KEY_K,
            mods: ghostty_vt::Mods::SUPER,
            unshifted_codepoint: 'k' as u32,
            action: Some(ghostty_vt::KeyAction::Press),
            ..Default::default()
        };

        assert!(surface.clear_history_or_encode_key(Some(&input)).is_err());
        assert!(writer.0.lock().unwrap().is_empty());
    }

    #[test]
    fn clear_history_enter_fallback_does_not_relock_the_terminal() {
        let mux = Mux::new_for_test("clear-history-enter-lock", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let writer = CapturingWriter::default();
        replace_local_writer(&surface, Box::new(writer.clone()));
        surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));
        let input = KeyInput {
            key: ghostty_vt::sys::GHOSTTY_KEY_ENTER,
            mods: ghostty_vt::Mods::SUPER,
            action: Some(ghostty_vt::KeyAction::Press),
            ..Default::default()
        };
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();

        std::thread::spawn(move || {
            let _ = finished_tx.send(surface.clear_history_or_encode_key(Some(&input)));
        });
        finished_rx
            .recv_timeout(Duration::from_millis(250))
            .expect("alternate-screen Enter fallback deadlocked")
            .unwrap();

        assert_eq!(&*writer.0.lock().unwrap(), b"\x1b[13;9u");
    }

    #[test]
    fn clear_history_fallback_releases_terminal_before_pty_write() {
        let mux = Mux::new_for_test("clear-history-write-lock", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let written = Arc::new(Mutex::new(Vec::new()));
        replace_local_writer(
            &surface,
            Box::new(TerminalProbeDuringWrite {
                written: written.clone(),
                surface: Arc::downgrade(&surface),
            }),
        );
        surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));
        let input = KeyInput {
            key: ghostty_vt::sys::GHOSTTY_KEY_K,
            mods: ghostty_vt::Mods::SUPER,
            unshifted_codepoint: 'k' as u32,
            action: Some(ghostty_vt::KeyAction::Press),
            ..Default::default()
        };
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();

        std::thread::spawn(move || {
            let _ = finished_tx.send(surface.clear_history_or_encode_key(Some(&input)));
        });
        finished_rx
            .recv_timeout(Duration::from_millis(250))
            .expect("alternate-screen fallback blocked terminal updates during the PTY write")
            .unwrap();

        assert_eq!(&*written.lock().unwrap(), b"\x1b[107;9u");
    }

    #[cfg(unix)]
    #[test]
    fn clear_history_fallback_write_has_a_deadline_when_pty_input_is_full() {
        use std::os::fd::{AsRawFd, FromRawFd};

        let mux = Mux::new_for_test("clear-history-full-input", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));

        let mut pipe_fds = [0; 2];
        assert_eq!(unsafe { libc::pipe(pipe_fds.as_mut_ptr()) }, 0);
        let read_end = unsafe { std::fs::File::from_raw_fd(pipe_fds[0]) };
        let write_end = unsafe { std::fs::File::from_raw_fd(pipe_fds[1]) };
        let master_fd = unsafe { libc::dup(write_end.as_raw_fd()) };
        assert!(master_fd >= 0);
        let master_file = unsafe { std::fs::File::from_raw_fd(master_fd) };

        let write_fd = write_end.as_raw_fd();
        let original_flags = unsafe { libc::fcntl(write_fd, libc::F_GETFL) };
        assert!(original_flags >= 0);
        assert_eq!(
            unsafe { libc::fcntl(write_fd, libc::F_SETFL, original_flags | libc::O_NONBLOCK) },
            0
        );
        let fill = [b'x'; 4096];
        loop {
            let written = unsafe { libc::write(write_fd, fill.as_ptr().cast(), fill.len()) };
            if written > 0 {
                continue;
            }
            let error = std::io::Error::last_os_error();
            assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
            break;
        }
        assert_eq!(unsafe { libc::fcntl(write_fd, libc::F_SETFL, original_flags) }, 0);

        {
            let pty = surface.as_pty().unwrap();
            let mut runtime = pty.runtime.lock().unwrap();
            let PtyRuntime::Local { writer, master, .. } = &mut *runtime else {
                panic!("test surface unexpectedly uses a terminal host");
            };
            *writer = Box::new(write_end);
            *master = Some(Box::new(FdMasterPty {
                file: master_file,
                size: Mutex::new(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }),
            }));
        }

        let input = KeyInput {
            key: ghostty_vt::sys::GHOSTTY_KEY_K,
            mods: ghostty_vt::Mods::SUPER,
            unshifted_codepoint: 'k' as u32,
            action: Some(ghostty_vt::KeyAction::Press),
            ..Default::default()
        };
        let clear_surface = surface;
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = finished_tx
                .send(clear_surface.clear_history_or_encode_key_classified(Some(&input)));
        });

        let timely = finished_rx.recv_timeout(Duration::from_millis(600));
        let completed_before_drain = timely.is_ok();
        if !completed_before_drain {
            let mut drain = [0; 4096];
            assert!(
                unsafe { libc::read(read_end.as_raw_fd(), drain.as_mut_ptr().cast(), drain.len()) }
                    > 0
            );
        }
        let result = timely.or_else(|_| finished_rx.recv_timeout(Duration::from_secs(1))).unwrap();

        assert!(completed_before_drain, "fallback write exceeded its deadline");
        assert!(result.is_err(), "a full PTY input queue unexpectedly accepted the fallback key");
        assert_eq!(
            result.as_ref().unwrap_err().delivery(),
            ClearHistoryDelivery::KnownNotDelivered
        );
        assert!(
            result.as_ref().is_err_and(|failure| failure.error().to_string().contains("timeout")),
            "fallback write did not return a stable timeout failure"
        );
    }

    #[test]
    fn clear_history_does_not_hold_runtime_while_waiting_for_terminal() {
        let mux = Mux::new_for_test("clear-history-lock-order", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let pty = surface.as_pty().unwrap();
        let terminal = pty.term.lock().unwrap();
        let runtime = pty.runtime.lock().unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();
        let clear_surface = surface.clone();
        std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            let _ = finished_tx.send(clear_surface.clear_history());
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        drop(runtime);
        std::thread::sleep(Duration::from_millis(25));
        assert!(
            pty.runtime.try_lock().is_ok(),
            "clear-history held runtime while blocked on terminal, inverting resize lock order"
        );
        drop(terminal);
        finished_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
    }

    #[test]
    fn clear_history_fallback_capability_read_never_waits_for_runtime_writer() {
        let mux = Mux::new_for_test("clear-history-capability-lock", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let (locked_tx, locked_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let locked_surface = surface.clone();
        let lock_holder = std::thread::spawn(move || {
            let pty = locked_surface.as_pty().unwrap();
            let _runtime = pty.runtime.lock().unwrap();
            locked_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
        locked_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let (result_tx, result_rx) = std::sync::mpsc::channel();
        let reader = std::thread::spawn(move || {
            result_tx.send(surface.supports_clear_history_key_fallback()).unwrap();
        });
        let result = result_rx.recv_timeout(Duration::from_millis(100));
        release_tx.send(()).unwrap();
        lock_holder.join().unwrap();
        reader.join().unwrap();

        assert!(
            matches!(result, Ok(false)),
            "capability read waited for the PTY writer runtime: {result:?}"
        );
    }

    #[test]
    fn clear_history_preserves_prompt_without_writing_to_the_child() {
        let mux = Mux::new_for_test("clear-prompt-history", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let writer = CapturingWriter::default();
        replace_local_writer(&surface, Box::new(writer.clone()));
        surface.with_terminal(|term| {
            for line in 0..40 {
                term.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            term.vt_write(b"\x1b]133;A\x07prompt> ");
            assert!(term.history_rows() > 0);
        });
        let attach = surface.attach_stream().unwrap();
        let mut mirror =
            Terminal::new(attach.cols, attach.rows, 10_000, Callbacks::default()).unwrap();
        mirror.vt_write(&attach.replay);

        surface.clear_history().unwrap();

        let AttachFrame::Output(clear) =
            attach.stream.recv_timeout(Duration::from_secs(1)).unwrap()
        else {
            panic!("clear did not reach the attach mirror");
        };
        mirror.vt_write(&clear);
        surface.with_terminal(|term| {
            assert_eq!(term.history_rows(), 0);
            let viewport = term.viewport_text().unwrap();
            assert!(viewport.contains("prompt>"));
            assert!(!viewport.contains("history-"));
            assert_eq!(mirror.viewport_text().unwrap(), viewport);
            assert_eq!(mirror.cursor_position(), term.cursor_position());
        });
        assert_eq!(mirror.history_rows(), 0);
        assert!(writer.0.lock().unwrap().is_empty());
    }

    #[test]
    fn terminal_query_response_does_not_change_clear_history_safety() {
        let mux = Mux::new_for_test("clear-after-query-response", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let writer = CapturingWriter::default();
        replace_local_writer(&surface, Box::new(writer.clone()));
        surface.with_terminal(|term| {
            for line in 0..40 {
                term.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            term.vt_write(b"\x1b]133;A\x07prompt> ");
        });

        surface.write_bytes(b"\x1b[?1;2c").unwrap();
        surface.clear_history().unwrap();

        surface.with_terminal(|term| {
            let viewport = term.viewport_text().unwrap();
            assert_eq!(term.history_rows(), 0);
            assert!(viewport.contains("prompt>"));
            assert!(!viewport.contains("history-"));
        });
        assert_eq!(&*writer.0.lock().unwrap(), b"\x1b[?1;2c");
    }

    #[test]
    fn clear_history_with_output_metadata_preserves_current_row_without_child_input() {
        let mux = Mux::new_for_test("clear-non-prompt-history", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let writer = CapturingWriter::default();
        replace_local_writer(&surface, Box::new(writer.clone()));
        surface.with_terminal(|term| {
            term.vt_write(b"\x1b]133;C\x07");
            for line in 0..40 {
                term.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            term.vt_write(b"foreground-input");
            assert!(term.history_rows() > 0);
        });

        surface.clear_history().unwrap();

        surface.with_terminal(|term| {
            assert_eq!(term.history_rows(), 0);
            let viewport = term.viewport_text().unwrap();
            assert!(viewport.contains("foreground-input"));
            assert!(!viewport.contains("history-"));
        });
        assert!(writer.0.lock().unwrap().is_empty());
    }

    #[test]
    fn clear_history_without_prompt_metadata_clears_scrollback_only() {
        let mux = Mux::new_for_test("clear-wrapped-input", SurfaceOptions::default());
        let surface = Surface::spawn_for_test(
            1,
            SurfaceOptions { cols: 10, rows: 5, ..SurfaceOptions::default() },
            Arc::downgrade(&mux),
        )
        .unwrap();
        let writer = CapturingWriter::default();
        replace_local_writer(&surface, Box::new(writer.clone()));
        let (history_before, viewport_before) = surface
            .with_terminal(|term| {
                for line in 0..12 {
                    term.vt_write(format!("history-{line}\r\n").as_bytes());
                }
                term.vt_write(b"wrapped-edit-buffer");
                (term.history_rows(), term.viewport_text().unwrap())
            })
            .unwrap();

        surface.clear_history().unwrap();

        assert!(history_before > 0);
        surface.with_terminal(|term| {
            assert_eq!(term.history_rows(), 0);
            assert_eq!(term.viewport_text().unwrap(), viewport_before);
        });
        assert!(writer.0.lock().unwrap().is_empty());
    }

    #[test]
    fn clear_history_preserves_wrapped_prompt_input() {
        let mux = Mux::new_for_test("clear-wrapped-prompt-input", SurfaceOptions::default());
        let surface = Surface::spawn_for_test(
            1,
            SurfaceOptions { cols: 10, rows: 5, ..SurfaceOptions::default() },
            Arc::downgrade(&mux),
        )
        .unwrap();
        let writer = CapturingWriter::default();
        replace_local_writer(&surface, Box::new(writer.clone()));
        surface.with_terminal(|term| {
            for line in 0..12 {
                term.vt_write(format!("history-{line}\r\n").as_bytes());
            }
            term.vt_write(b"\x1b]133;A\x07prompt> \x1b]133;B\x07wrapped-edit-buffer");
            assert!(term.history_rows() > 0);
        });

        surface.clear_history().unwrap();

        surface.with_terminal(|term| {
            assert_eq!(term.history_rows(), 0);
            let viewport = term.viewport_text().unwrap();
            let compact =
                viewport.chars().filter(|character| !character.is_whitespace()).collect::<String>();
            assert!(compact.contains("prompt>wrapped-edit-buffer"));
            assert!(!viewport.contains("history-"));
        });
        assert!(writer.0.lock().unwrap().is_empty());
    }

    #[test]
    fn clear_history_preserves_alternate_screen_and_primary_history() {
        let mux = Mux::new_for_test("clear-alternate-screen", SurfaceOptions::default());
        let surface =
            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
        let primary_history_rows = surface
            .with_terminal(|term| {
                for line in 0..40 {
                    term.vt_write(format!("primary-{line}\r\n").as_bytes());
                }
                term.vt_write(b"primary-tail");
                let history_rows = term.history_rows();
                term.vt_write(b"\x1b[?1049h");
                term.vt_write(b"alternate-app");
                assert_eq!(term.active_screen(), Screen::Alternate);
                history_rows
            })
            .unwrap();

        surface.clear_history().unwrap();

        surface.with_terminal(|term| {
            assert_eq!(term.active_screen(), Screen::Alternate);
            assert!(term.viewport_text().unwrap().contains("alternate-app"));
            term.vt_write(b"\x1b[?1049l");
            assert_eq!(term.active_screen(), Screen::Primary);
            assert_eq!(term.history_rows(), primary_history_rows);
            assert!(term.viewport_text().unwrap().contains("primary-tail"));
        });
    }
}
