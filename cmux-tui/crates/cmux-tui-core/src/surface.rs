//! Surface runtime: one tab inside a pane.
//!
//! A surface is either a PTY backed by libghostty-vt state or a local CDP
//! browser surface. PTY-only methods stay available for existing callers;
//! browser-aware frontends should branch on [`SurfaceKind`] before using
//! VT operations.

mod attach;
mod browser_ops;
mod clear_history;
mod color_overrides;
mod directory;
mod exit_state;
mod frame_producer;
mod geometry;
mod input;
mod metadata;
mod mouse_input;
mod pty_surface;
mod render_view;
mod scrolling;
mod shutdown;
pub(crate) mod spawn;
mod terminal_stream;
pub use color_overrides::apply_terminal_color_overrides;
// Hosted (unix) code and the unit tests are the only callers.
#[cfg(any(unix, test))]
use color_overrides::{
    terminal_color_override_delta, terminal_color_override_full_state,
    terminal_color_overrides_match_applied,
};
use frame_producer::spawn_frame_producer;
use scrolling::{
    broadcast_render_scroll_locked, set_terminal_scroll_offset, terminal_scroll_position,
};
use spawn::{LocalLaunch, LocalSpawn};
#[cfg(test)]
mod test_pty;
#[cfg(all(test, unix))]
use test_pty::FdMasterPty;
#[cfg(test)]
use test_pty::{
    StartupChild, StartupChildState, TestChildKiller, TestMasterPty, TestMasterPtyControl,
};
#[cfg(unix)]
mod clipboard_read;
#[cfg(all(unix, test))]
pub(crate) use clipboard_read::test_fixture::hosted_surface_for_clipboard_test;
#[cfg(unix)]
mod host_frames;
#[cfg(unix)]
mod hosted_callbacks;
#[cfg(unix)]
use hosted_callbacks::hosted_terminal_callbacks;
#[cfg(unix)]
mod host_kitty_limits;
#[cfg(all(test, unix))]
mod journal_failure_tests;
#[cfg(unix)]
mod journal_reconnect;
#[cfg(unix)]
mod prelaunch;
#[cfg(unix)]
mod rehost;
use directory::PublishedDirectory;

use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
#[cfg(test)]
use std::io::Read;
use std::io::Write;
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

use crate::daemon_env::set_env;
use crate::mux::ResourceWaitWake;
use crate::platform;
use crate::resource::{ContentPublicId, TabResourceIdentity, TerminalPublicId};
use crate::terminal_end::TerminalEnd;
use crate::terminal_host_protocol::{TerminalExit, wait_for_native_child_status_with_reap_result};
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

/// Ghostty's default maximum retained scrollback backing storage.
pub const DEFAULT_SCROLLBACK_LIMIT_BYTES: usize = 50_000_000;

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

/// Delivery classification for receipted terminal input.
///
/// `Known` means the implementation proved no bytes were submitted to the
/// authoritative PTY owner. `Indeterminate` means bytes may have crossed a
/// local writer or terminal-host socket before the failure became visible.
#[derive(Debug)]
pub(crate) enum ConfirmedInputFailure {
    Known(std::io::Error),
    Indeterminate(std::io::Error),
}

/// A terminal viewport and its output watermark captured at one parser
/// boundary. The stream writers advance their revision while holding the
/// terminal lock, so a reader cannot pair text from one boundary with a
/// revision from another.
pub(crate) struct TerminalScreenSnapshot {
    pub(crate) text: String,
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) cursor_col: u16,
    pub(crate) cursor_row: u16,
    pub(crate) cursor_visible: bool,
    pub(crate) revision: u64,
    pub(crate) osc_progress: String,
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

/// A hosted terminal that was asked to exit and has not yet been observed
/// exiting.
#[cfg(unix)]
pub(crate) struct HostTermination {
    identity: crate::terminal_host_runtime::TerminalHostIdentity,
    path: PathBuf,
    observed: u64,
    already_exited: bool,
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
    /// Maximum retained scrollback storage in bytes, matching Ghostty's
    /// `max_scrollback` API. This is not a line count.
    pub scrollback: usize,
    /// Extra environment for children (e.g. CMUX_TUI_SOCKET).
    pub extra_env: Vec<(String, String)>,
    /// The `claude` shim directory, kept first on every child's PATH.
    pub claude_shim_dir: Option<String>,
    /// The app's bundled CLI (`CMUX_BUNDLED_CLI_PATH` in the daemon's own
    /// environment): its dir stays first on every child's PATH after the
    /// shim, also over a caller PATH, and the value wins over a caller's.
    pub bundled_cli: Option<String>,
    /// Optional existing Chrome CDP endpoint, as ws://... or http://host:port.
    pub cdp_url: Option<String>,
    /// Maximum browser capture size before downscaling, in megapixels.
    pub browser_max_capture_megapixels: f64,
    /// Optional maximum browser capture scale, further reduced to honor the megapixel cap.
    pub browser_capture_scale: Option<f64>,
    /// Durable per-terminal host records. When set, PTYs are created in a
    /// dedicated process and this surface becomes an adoptable mirror.
    pub terminal_host_root: Option<PathBuf>,
    /// Adopt a live terminal host found under `terminal_host_root` into a
    /// fresh registry (one with no workspaces) instead of terminating it.
    ///
    /// Cloud VM snapshots keep the first terminal's host process, and its
    /// already-initialized shell, running while the daemon is parked and
    /// every per-machine file (machine id, receipt pepper, session registry,
    /// remote identity) is wiped. A clone's daemon then creates all of those
    /// fresh and imports the warm host as its first terminal, so no identity
    /// is shared between clones while the shell survives the snapshot.
    pub adopt_template_terminal: bool,
    /// Where to publish the adopted template terminal's new session and
    /// terminal ids (`KEY=value` lines) once adoption commits.
    pub template_bound_file: Option<PathBuf>,
    /// Name of the workspace created for the adopted template terminal. The
    /// template's own registry was wiped with the snapshot, so its name is
    /// not recoverable from the host record. `None` uses the default name.
    pub template_workspace_name: Option<String>,
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
            scrollback: DEFAULT_SCROLLBACK_LIMIT_BYTES,
            extra_env: Vec::new(),
            claude_shim_dir: None,
            bundled_cli: None,
            cdp_url: None,
            browser_max_capture_megapixels: crate::browser::TRANSPORT_SAFE_CAPTURE_MEGAPIXELS,
            browser_capture_scale: None,
            terminal_host_root: None,
            adopt_template_terminal: false,
            template_bound_file: None,
            template_workspace_name: None,
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
    /// Application-authored special colors, separate from shared embedder
    /// defaults so byte viewers can retain their own configured themes.
    pub fg_override: Option<Rgb>,
    pub bg_override: Option<Rgb>,
    pub cursor_override: Option<Rgb>,
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
            fg_override: None,
            bg_override: None,
            cursor_override: None,
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
            fg_override: overrides.foreground,
            bg_override: overrides.background,
            cursor_override: overrides.cursor,
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
    /// The incomplete sequence the parser is inside. `replay` ends at a
    /// parser boundary; write this after it and after the colors, right
    /// before the live stream that completes it.
    pub pending_sequence: Arc<[u8]>,
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
    /// `pending_sequence` has the meaning documented on [`AttachStream`].
    Resized {
        cols: u16,
        rows: u16,
        replay: Arc<[u8]>,
        kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
        kitty_state: KittyReplayState,
        pending_sequence: Arc<[u8]>,
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
        pending_sequence: Arc<[u8]>,
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
    /// A smart host's quota change that evicted nothing (host_kitty_limits.rs).
    KittyGraphicsLimits(KittyGraphicsLimits),
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
            MessageKind::ResyncRequired if frame.flags == 0 => Ok(Some(
                match crate::terminal_host_runtime::decode_resync_kitty_graphics_limits(
                    &frame.payload,
                ) {
                    Some(limits) if self.smart_renderer => {
                        HostedTransition::KittyGraphicsLimits(limits)
                    }
                    _ => HostedTransition::ResyncRequired,
                },
            )),
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

mod attach_tap;
#[cfg(test)]
use attach_tap::AttachFrameMerge;
pub use attach_tap::AttachFrameReceiver;
pub(crate) use attach_tap::AttachLifecycle;
use attach_tap::AttachTap;
pub(crate) use attach_tap::ViewerEvent;
pub(crate) mod snapshot_attach;

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

    /// Wakes a blocked `recv_until_interrupted` when `interrupt` fires.
    pub(crate) fn wake_on(&self, interrupt: &crate::stream_interrupt::StreamInterrupt) {
        let state = Arc::downgrade(&self.state);
        interrupt.on_fire(move || {
            if let Some(state) = state.upgrade() {
                let _queue = state.queue.lock().unwrap_or_else(|error| error.into_inner());
                state.ready.notify_all();
            }
        });
    }

    /// Blocks for an event. Returns `Timeout` once `interrupt` has fired
    /// and nothing is queued.
    pub(crate) fn recv_until_interrupted(
        &self,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> Result<RenderAttachFrame, RecvTimeoutError> {
        let mut queue = self.state.queue.lock().unwrap();
        loop {
            if let Some(event) = queue.pop() {
                return Ok(event);
            }
            if !queue.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            if interrupt.is_fired() {
                return Err(RecvTimeoutError::Timeout);
            }
            queue = self.state.ready.wait(queue).unwrap();
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
    _permit: Option<crate::mux::RenderAttachmentPermit>,
}

struct RenderHub {
    state: Box<RenderState>,
    built_generation: u64,
    latest: Option<Arc<SurfaceRenderFrame>>,
    initial_graphics: Option<InitialGraphicsSnapshot>,
    final_initial: Option<Arc<SurfaceRenderFrame>>,
    taps: Vec<RenderTap>,
}

impl RenderHub {
    fn build_attach_initial(
        &mut self,
        term: &Terminal,
    ) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        let shared = self.latest.clone().ok_or(ghostty_vt::Error::NoValue)?;
        let initial_graphics = match self.initial_graphics.as_ref() {
            Some(cached) if Arc::ptr_eq(&cached.source, &shared.frame.kitty_graphics) => {
                cached.snapshot.clone()
            }
            _ => {
                let snapshot = self.state.snapshot_kitty_graphics(term, true)?;
                self.initial_graphics = Some(InitialGraphicsSnapshot {
                    source: shared.frame.kitty_graphics.clone(),
                    snapshot: snapshot.clone(),
                });
                snapshot
            }
        };
        let mut initial = (*shared).clone();
        initial.frame.kitty_graphics = initial_graphics;
        Ok(Arc::new(initial))
    }

    fn final_attach_initial(
        &mut self,
        term: &Terminal,
    ) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        if let Some(initial) = self.final_initial.as_ref() {
            return Ok(initial.clone());
        }
        let initial = self.build_attach_initial(term)?;
        self.final_initial = Some(initial.clone());
        Ok(initial)
    }
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
/// A host connection that lasted this long was healthy: the next loss starts
/// its reconnect spacing from zero again.
#[cfg(unix)]
const TERMINAL_HOST_HEALTHY_CONNECTION: Duration = Duration::from_secs(10);

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
pub(crate) struct PtyGeometry {
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
    /// Feed raw child output to the generic terminal metadata parser. The
    /// parser has no knowledge of agents or plugins and keeps only bounded
    /// terminal protocol state. Returns the desktop notifications (OSC 9,
    /// OSC 777, OSC 99) the output asked for that pass Ghostty's rate limit;
    /// the caller posts them after it releases the terminal lock.
    fn observe_terminal_output(
        &self,
        bytes: &[u8],
    ) -> Vec<crate::terminal_metadata::TerminalNotification> {
        let mut metadata = self.terminal_metadata.lock().unwrap();
        metadata.observe_output(bytes);
        metadata.take_admitted_notifications(Instant::now())
    }

    /// Applies the OSC 133 marks of the output just written to `term`. With
    /// `recording` false (the default) marks are dropped, any running command
    /// is forgotten, and nothing is read from the screen. The command line
    /// comes from Ghostty's semantic input cells, so a command typed before
    /// recording turned on is still read whole at `C`.
    fn observe_shell_marks(
        &self,
        term: &mut Terminal,
        recording: impl FnOnce() -> bool,
    ) -> Vec<crate::shell_history::FinishedCommand> {
        let marks = self.terminal_metadata.lock().unwrap().take_shell_marks();
        if marks.is_empty() {
            return Vec::new();
        }
        let mut tracker = self.command_tracker.lock().unwrap();
        if !recording() {
            tracker.reset();
            return Vec::new();
        }
        let mut screen = crate::shell_history::TerminalCommandScreen(term);
        let now_ms = crate::workspace_registry::unix_epoch_ms().unwrap_or(0);
        marks.into_iter().filter_map(|mark| tracker.apply(mark, now_ms, &mut screen)).collect()
    }

    fn terminal_osc_progress(&self) -> String {
        self.terminal_metadata.lock().unwrap().osc_progress().to_string()
    }

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
    /// Owned child-reaper join fence. Shutdown uses the same bounded deadline
    /// as the reader so the child wait cannot outlive terminal teardown.
    reaper_thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    reaper_completion: Arc<ReaderCompletion>,
    term: Mutex<Box<Terminal>>,
    stream_progress: Box<TerminalStreamProgress>,
    /// Generic metadata parsed from raw PTY output. This field has no agent
    /// or roster knowledge, so userland plugins can consume it through the
    /// resource API without moving detection policy into core.
    terminal_metadata: Mutex<crate::terminal_metadata::TerminalMetadata>,
    /// OSC 133 command tracking (`terminal-command-journal-v1`); idle unless
    /// the daemon records terminal commands.
    command_tracker: Mutex<crate::shell_history::CommandTracker>,
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
    /// How this incarnation ended, with its provenance (process end versus
    /// host loss); see [`TerminalEnd`].
    exit: Mutex<Option<TerminalEnd>>,
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
    published_directory: Mutex<PublishedDirectory>,
    directory_pending: AtomicBool,
    /// A shell has reported a directory at least once; only then is a later
    /// absent report a clear rather than the still-unreported launch directory.
    directory_reported: AtomicBool,
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
    /// Published byte offset and grid generation for snapshot viewers.
    snapshot_position: snapshot_attach::SnapshotStreamPosition,
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

/// Owns a freshly spawned PTY child until the child reaper has taken over.
///
/// `portable_pty::Child` does not stop or reap a process when its handle is
/// dropped. Startup performs several fallible operations after spawning, so a
/// guard keeps every error path terminating and reaping the child. The guard
/// moves into the reaper closure; if thread creation fails, dropping that
/// closure runs this cleanup instead.
struct PtyChildStartupGuard {
    child: Box<dyn cmux_pty::Child + Send + Sync>,
    reaped: bool,
}

impl PtyChildStartupGuard {
    fn new(child: Box<dyn cmux_pty::Child + Send + Sync>) -> Self {
        Self { child, reaped: false }
    }

    fn process_id(&self) -> Option<u32> {
        self.child.process_id()
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        self.child.clone_killer()
    }

    fn wait_for_exit(&mut self) -> TerminalExit {
        let (exit, reaped) = wait_for_native_child_status_with_reap_result(self.child.as_mut());
        self.reaped = reaped;
        exit
    }
}

impl Drop for PtyChildStartupGuard {
    fn drop(&mut self) {
        if self.reaped {
            return;
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PtyLifetime {
    SessionOwned,
    DaemonOwned,
}

/// When a new terminal surface takes its share of the Kitty image budget.
#[derive(Clone, Copy)]
#[cfg_attr(not(unix), allow(dead_code))]
enum KittyQuota {
    /// Before its host launches, waiting for other surfaces to shrink.
    AtLaunch,
    /// Once the surface commits (`Mux::reserve_kitty_image_surface_without_quota`).
    AfterCommit,
}

/// A launched terminal host whose surface is not built yet
/// ([`Surface::prelaunch_hosted`]).
#[cfg(unix)]
pub(crate) struct PrelaunchedHost {
    id: SurfaceId,
    terminal_id: crate::terminal_host::TerminalId,
    opts: SurfaceOptions,
    attachment: crate::terminal_host_runtime::HostAttachment,
    kitty_reservation: Option<crate::mux::KittyImageBudgetReservation>,
    terminal_public_id: Option<TerminalPublicId>,
    resource_identity: TabResourceIdentity,
}

#[cfg(unix)]
impl PrelaunchedHost {
    pub(crate) fn terminal_id(&self) -> crate::terminal_host::TerminalId {
        self.terminal_id
    }

    /// Write the workspace key into the host's recovery record now, so the
    /// creation transaction finds it current and skips the synced write
    /// (`Surface::persist_host_workspace`).
    pub(crate) fn persist_workspace(&mut self, workspace_key: &str) -> anyhow::Result<()> {
        self.attachment.persist_workspace(workspace_key)
    }
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
const LOCAL_PASTE_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
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
        return crate::pty_write::write_bounded(
            fd,
            bytes,
            CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT,
            CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR,
        )
        .map_err(|failure| clear_history_write_failure(failure.error, failure.delivered));
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
    #[cfg(test)]
    test_before_notify: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
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
            #[cfg(test)]
            test_before_notify: Mutex::new(None),
        }
    }
}

impl TerminalStreamProgress {
    pub(crate) fn revision(&self) -> u64 {
        self.state.lock().unwrap().revision
    }

    pub(crate) fn notify(&self) {
        #[cfg(test)]
        if let Some(hook) = self.test_before_notify.lock().unwrap().clone() {
            hook();
        }
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

    #[cfg(test)]
    fn set_before_notify_hook(&self, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.test_before_notify.lock().unwrap() = hook;
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
            (None, &[]),
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
            (None, &[]),
            Some(TabResourceIdentity::terminal(None)?),
            PtyLifetime::SessionOwned,
            cell_pixels,
        )
    }

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
            (None, &[]),
            resource_identity,
            PtyLifetime::SessionOwned,
            cell_pixels,
        )
    }

    /// The identity environment and Kitty image budget every terminal
    /// surface gets before its process starts.
    fn spawn_prelude(
        id: SurfaceId,
        mut opts: SurfaceOptions,
        mux: &Weak<Mux>,
        resource_identity: Option<&TabResourceIdentity>,
        kitty_quota: KittyQuota,
    ) -> anyhow::Result<(
        SurfaceOptions,
        Option<TerminalPublicId>,
        Option<crate::mux::KittyImageBudgetReservation>,
    )> {
        let terminal_public_id = resource_identity
            .map(|identity| {
                terminal_public_id_from_resource_identity(
                    identity,
                    "terminal surface cannot use a browser resource identity",
                )
            })
            .transpose()?;
        if let Some(terminal_public_id) = terminal_public_id.as_ref() {
            set_env(&mut opts.extra_env, "CMUX_TUI_TERMINAL_ID", terminal_public_id.as_str());
            configure_agent_browser_session(&mut opts, terminal_public_id.as_str());
        }
        if let Some(mux) = mux.upgrade() {
            set_env(&mut opts.extra_env, "CMUX_TUI_SESSION_ID", mux.session_public_id().as_str());
        }
        let kitty_reservation = mux
            .upgrade()
            .map(|mux| match kitty_quota {
                KittyQuota::AtLaunch => mux.reserve_kitty_image_surface(id),
                KittyQuota::AfterCommit => mux.reserve_kitty_image_surface_without_quota(id),
            })
            .transpose()?;
        Ok((opts, terminal_public_id, kitty_reservation))
    }

    /// Build the surface of a host from [`Surface::prelaunch_hosted`].
    #[cfg(unix)]
    pub(crate) fn spawn_prelaunched(
        host: PrelaunchedHost,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Surface>> {
        let PrelaunchedHost {
            id,
            terminal_id: _,
            opts,
            attachment,
            kitty_reservation,
            terminal_public_id,
            resource_identity,
        } = host;
        Self::spawn_hosted(
            id,
            opts,
            mux,
            HostedSurfaceLaunch {
                attachment,
                kitty_reservation,
                terminate_on_error: true,
                defer_launch_activation: true,
                lifetime: PtyLifetime::SessionOwned,
                terminal_public_id,
                resource_identity: Some(resource_identity),
            },
        )
    }

    /// `launch` is the reserved terminal id, and the VT replay its host
    /// applies before the child's first byte (a hosted launch with an id
    /// only; empty: none).
    pub(crate) fn spawn_with_terminal_id_and_resource_identity_at_cell_pixels(
        id: SurfaceId,
        opts: SurfaceOptions,
        mux: Weak<Mux>,
        (terminal_id, seed): (Option<crate::terminal_host::TerminalId>, &[u8]),
        resource_identity: Option<TabResourceIdentity>,
        lifetime: PtyLifetime,
        cell_pixels: (u16, u16),
    ) -> anyhow::Result<Arc<Surface>> {
        let (opts, terminal_public_id, kitty_reservation) =
            Self::spawn_prelude(id, opts, &mux, resource_identity.as_ref(), KittyQuota::AtLaunch)?;
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
                Some(terminal_id) => crate::terminal_host_runtime::launch_terminal_host_seeded(
                    &opts,
                    &root,
                    (default_colors, cell_pixels, initial_kitty_limits),
                    terminal_id,
                    None,
                    seed,
                )?,
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
        let _ = (terminal_id, seed);
        let initial_geometry = PtyGeometry {
            cols: opts.cols,
            rows: opts.rows,
            cell_width: cell_pixels.0,
            cell_height: cell_pixels.1,
        };
        let pty = cmux_pty::open(initial_geometry.pty_size()?)?;

        let launch = match opts.command.clone().filter(|argv| !argv.is_empty()) {
            Some(argv) => {
                crate::shell_integration::ShellLaunch { command: argv, env: opts.extra_env.clone() }
            }
            None => crate::shell_integration::integrate_default_shell(
                vec![platform::default_shell()],
                opts.extra_env.clone(),
            ),
        };
        let argv = launch.command;
        let mut cmd = PtyCommand::new(&argv[0]);
        cmd.args(argv[1..].iter().cloned());
        cmd.env("TERM", &opts.term);
        // The embedded ghostty-vt terminal always parses 24-bit SGR and every
        // frontend forwards RGB cells losslessly, so children can rely on
        // truecolor regardless of where the session server was started
        // (launchd, ssh, cron strip COLORTERM). Set before extra_env so a
        // caller can still override it.
        cmd.env("COLORTERM", "truecolor");
        for (k, v) in &launch.env {
            cmd.env(k, v);
        }
        let cwd = opts.cwd.clone().or_else(platform::default_terminal_cwd);
        if let Some(cwd) = cwd.as_deref() {
            cmd.cwd(cwd);
        }

        let cmux_pty::SpawnedPty { master, child } = pty.spawn(cmd)?;
        let mut child = PtyChildStartupGuard::new(child);
        let pid = child.process_id();
        let killer = child.clone_killer();
        #[cfg(unix)]
        let supports_clear_history_key_fallback = master.as_raw_fd().is_some();
        #[cfg(not(unix))]
        let supports_clear_history_key_fallback = false;
        let reader = master.try_clone_reader()?;
        let writer = master.take_writer()?;
        let launch = LocalLaunch {
            master,
            reader,
            writer,
            killer,
            wait: Box::new(move || TerminalEnd::ProcessEnded(child.wait_for_exit())),
            pid,
            command: argv,
            cwd,
            supports_clear_history_key_fallback,
        };
        let spawn = LocalSpawn {
            id,
            opts,
            mux,
            terminal_public_id,
            kitty_reservation,
            initial_kitty_limits,
            resource_identity,
            lifetime,
            cell_pixels,
            initial_geometry,
        };
        Self::spawn_local(spawn, launch)
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
            pty.stream_progress.notify();
            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
        };
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
        let mut terminal_metadata = crate::terminal_metadata::TerminalMetadata::default();
        let records = terminal_metadata.program_status();
        let callbacks = hosted_terminal_callbacks(id, mux.clone(), title_changed.clone(), records);
        let mut term = Terminal::new(snapshot.cols, snapshot.rows, opts.scrollback, callbacks)?;
        anyhow::ensure!(
            terminal_metadata.set_osc_progress(&snapshot.osc_progress),
            "terminal host returned invalid OSC progress metadata"
        );
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
        // Snapshot CWD values are terminal-reported metadata, including for
        // legacy protocol versions. Reject ambiguous plain paths instead of
        // silently inheriting them as a local spawn directory. A current host
        // fallback carries its authenticated provenance token.
        let snapshot_cwd = snapshot.cwd.as_deref().and_then(|cwd| {
            platform::snapshot_cwd_to_local_path(cwd, Some(attachment.record.owner_token.as_str()))
        });
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
                reaper_thread: Mutex::new(None),
                reaper_completion: Arc::new(ReaderCompletion::default()),
                term: Mutex::new(Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                terminal_metadata: Mutex::new(terminal_metadata),
                command_tracker: Mutex::new(Default::default()),
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
                cwd: snapshot_cwd.map(|path| path.to_string_lossy().into_owned()),
                exit: Mutex::new(None),
                local_pty_drained: AtomicBool::new(true),
                exit_notified: AtomicBool::new(false),
                dead: AtomicBool::new(false),
                owner_detaching: AtomicBool::new(false),
                host_connection_state: AtomicU8::new(TerminalHostConnectionState::Connected as u8),
                dirty: AtomicBool::new(true),
                title: Mutex::new(title),
                directory_reported: AtomicBool::new(pwd.is_some()),
                pwd: Mutex::new(pwd),
                published_directory: Mutex::new(PublishedDirectory::Unreported),
                directory_pending: AtomicBool::new(true),
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
                snapshot_position: Default::default(),
                last_attach_colors: Mutex::new(None),
                render: Arc::new(Mutex::new(RenderHub {
                    state: Box::new(render_state),
                    built_generation: 0,
                    latest: None,
                    initial_graphics: None,
                    final_initial: None,
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
        Self::install_clipboard_read_handler(&surface);
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
                // Test seam: slows applying each output frame so tests can
                // build an output backlog ahead of a targeted host response.
                let output_apply_delay = std::env::var("CMUX_TUI_TEST_HOSTED_OUTPUT_APPLY_DELAY_MS")
                    .ok()
                    .and_then(|value| value.parse::<u64>().ok())
                    .map(|ms| Duration::from_millis(ms.min(5_000)));
                // One backoff across consecutive losses: a host that accepts
                // and then drops at once (or keeps asking for a resync) used
                // to be reconnected with no delay and no limit, because each
                // loss started a fresh backoff. It resets only after a
                // connection stayed up for TERMINAL_HOST_HEALTHY_CONNECTION.
                let mut flap_backoff = TerminalHostReconnectBackoff::default();
                // Spaces back-to-back resyncs of a live host without spending
                // the failure budget that decides whether a real loss fails.
                let mut resync_backoff = TerminalHostReconnectBackoff::default();
                // `None` until the first reconnect: the first loss of a
                // connection keeps its immediate reconnect.
                let mut connected_at: Option<Instant> = None;
                'connection: loop {
                    let pty = surface.as_pty().expect("host reader owns a PTY surface");
                    rehost::request_custody(&surface);
                    let mut stager = HostedFrameStager::new_for_version(
                        sequence_boundary,
                        protocol_version,
                        smart_renderer,
                    );
                    let mut received_exit = None;
                    let mut resync_requested = false;
                    let mut journal_target = None;
                    let mut journal_update = None;
                    // `reader` moves into the demultiplexer; a reconnect reassigns it.
                    let frames = match host_frames::HostFrames::spawn(
                        format!("surface-{id}-host-frames"),
                        reader,
                        control_responses.clone(),
                        protocol_version,
                        smart_renderer,
                    ) {
                        Ok(frames) => frames,
                        Err(_) => break 'connection,
                    };
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
                        let frame = match frames.recv() {
                            host_frames::HostFrame::Frame(frame) => frame,
                            host_frames::HostFrame::End => break,
                        };
                        // Targeted responses must be consumed before live staging:
                        // HostedFrameStager intentionally rejects every nonzero request id.
                        if host_frames::is_targeted_host_response(frame.kind) && frame.request_id != 0
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
                                if let Some(delay) = output_apply_delay {
                                    std::thread::sleep(delay);
                                }
                                let (output, colors) = match transition {
                                    HostedTransition::Output(output) => (output, None),
                                    HostedTransition::OutputWithColors { output, colors } => {
                                        (output, Some(colors))
                                    }
                                    _ => unreachable!(),
                                };
                                let mut scroll_changed = None;
                                let mut title_update = None;
                                let terminal_notifications;
                                let finished_commands;
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
                                    terminal_notifications = pty.observe_terminal_output(&output);
                                    finished_commands = pty.observe_shell_marks(&mut term, || {
                                        mux.upgrade()
                                            .is_some_and(|mux| mux.terminal_command_history_enabled())
                                    });
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
                                    pty.record_directory(term.pwd());
                                    if before != after {
                                        scroll_changed = Some(after);
                                        broadcast_render_scroll_locked(pty, after);
                                    }
                                    // Advance the output watermark while the
                                    // parser lock is held. A screen snapshot
                                    // cannot then pair this text with an old
                                    // revision.
                                    pty.stream_progress.notify();
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
                                surface.publish_pending_directory();
                        surface.publish_pending_progress();
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
                                if !terminal_notifications.is_empty()
                                    && let Some(mux) = mux.upgrade()
                                {
                                    mux.post_terminal_notifications(
                                        surface.id,
                                        terminal_notifications,
                                    );
                                }
                                if !finished_commands.is_empty()
                                    && let Some(mux) = mux.upgrade()
                                    && let Some(terminal) = surface.terminal_public_id()
                                {
                                    mux.append_shell_commands(terminal.clone(), finished_commands);
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
                                let records = pty.program_status_records();
                                let callbacks = hosted_terminal_callbacks(
                                    id,
                                    mux.clone(),
                                    title_changed.clone(),
                                    records,
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
                                let generation = pty.with_terminal_stream_update(|term| {
                                    let before = terminal_scroll_position(term);
                                    *term = replacement;
                                    pty.mouse_encoders.lock().unwrap().sync_from_terminal(term);
                                    *geometry = next_geometry;
                                    pty.journal_geometry(next_geometry);
                                    *pty.title.lock().unwrap() = title.clone();
                                    pty.record_directory(pwd);
                                    *pty.kitty_graphics_limits.lock().unwrap() = kitty_state.limits;
                                    applied_color_overrides = colors;
                                    applied_color_revision = term.color_revision();
                                    applied_cursor_activity = term.cursor_activity().ok();
                                    let after = terminal_scroll_position(term);
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
                                            pty.terminal_colors_locked(term, defaults),
                                        ),
                                        // Terminal hosts replay only at a
                                        // parser boundary.
                                        pending_sequence: Arc::from([]),
                                    });
                                    pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
                                });
                                drop(geometry);
                                surface.publish_pending_directory();
                        surface.publish_pending_progress();
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
                            HostedTransition::KittyGraphicsLimits(limits) => {
                                if !pty.apply_host_kitty_graphics_limits(limits) {
                                    resync_requested = true;
                                    break;
                                }
                            }
                        }
                        drop(journal_update.take());
                        journal_target = None;
                    }
                    frames.abandon();
                    let Some(pty) = surface.as_pty() else { return };
                    if pty.owner_detaching.load(Ordering::Acquire) {
                        return;
                    }
                    let Some(identity) = pty.host_identity.clone() else { return };
                    if let Some(exit) = received_exit {
                        // The host's Exit frame is its report that the child
                        // ended, even when an older host omits the status.
                        *pty.exit.lock().unwrap() = Some(TerminalEnd::ProcessEnded(exit));
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

                    if connected_at
                        .is_none_or(|at| at.elapsed() >= TERMINAL_HOST_HEALTHY_CONNECTION)
                    {
                        flap_backoff = TerminalHostReconnectBackoff::default();
                        resync_backoff = TerminalHostReconnectBackoff::default();
                    } else if resync_requested {
                        // A live host's resync never fails the terminal, but
                        // back-to-back resyncs are spaced.
                        let delay = resync_backoff.next_delay();
                        std::thread::sleep(delay.unwrap_or(TERMINAL_HOST_RECONNECT_MAX_DELAY));
                    } else if !flap_backoff.wait_or_fail(pty) {
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
                        let replaced = match crate::terminal_host_runtime::terminal_host_record_liveness(
                            &record_path,
                            &record,
                        ) {
                            Ok(crate::terminal_host_runtime::TerminalHostLiveness::Dead) => {
                                match rehost::after_host_death(&surface, &mux, &identity, &record, &record_path, scrollback) {
                                    rehost::DeadHost::Replaced(attachment) => Some(*attachment),
                                    rehost::DeadHost::Retry if retry.wait_or_fail(pty) => continue,
                                    rehost::DeadHost::Retry | rehost::DeadHost::Stop => return,
                                }
                            }
                            Ok(crate::terminal_host_runtime::TerminalHostLiveness::Live)
                            | Ok(
                                crate::terminal_host_runtime::TerminalHostLiveness::Indeterminate,
                            )
                            | Err(_) => None,
                        };

                        let Some(reconnect_mux) = mux.upgrade() else { return };
                        let Ok(kitty_limits) =
                            reconnect_mux.kitty_image_limits_for_reconnect(&surface)
                        else {
                            return;
                        };
                        let replacement = match replaced.map_or_else(|| crate::terminal_host_runtime::adopt_terminal_host_with_kitty_limits(
                            record,
                            record_path,
                            kitty_limits,
                        ), Ok) {
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
                        Self::install_clipboard_read_handler(&surface);

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
                        let records = pty.program_status_records();
                        let callbacks = hosted_terminal_callbacks(
                            id,
                            mux.clone(),
                            title_changed.clone(),
                            records.clone(),
                        );
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
                        let mut replacement_metadata =
                            crate::terminal_metadata::TerminalMetadata::with_program_status(
                                records,
                            );
                        if !replacement_metadata
                            .set_osc_progress(&replacement_snapshot.osc_progress)
                        {
                            if !retry.wait_or_fail(pty) {
                                return;
                            }
                            continue;
                        }
                        title_changed.store(false, Ordering::Relaxed);
                        let title = replacement_term.title().unwrap_or_default();
                        let pwd = replacement_term.pwd();
                        let generation = {
                            let mut term = pty.term.lock().unwrap();
                            **term = replacement_term;
                            *pty.terminal_metadata.lock().unwrap() = replacement_metadata;
                            pty.mouse_encoders.lock().unwrap().sync_from_terminal(&term);
                            *geometry = next_geometry;
                            *pty.title.lock().unwrap() = title.clone();
                            pty.record_directory(pwd);
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
                                pending_sequence: Arc::from([]),
                            });
                            pty.stream_progress.notify_reconnect();
                            pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1
                        };
                        drop(geometry);
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
                        // Bytes the host wrote while no daemon tap existed are
                        // not in the journal: record that gap before any new
                        // output (surface/journal_reconnect.rs).
                        pty.journal_host_reconnect_gap(&reconnect_mux);
                        reconnect_mux.reconcile_deferred_cell_pixel_ack(
                            surface.id,
                            replacement_snapshot.cell_pixels,
                        );
                        surface.publish_pending_directory();
                        surface.publish_pending_progress();
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
                        connected_at = Some(Instant::now());
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
        let terminal_metadata = crate::terminal_metadata::TerminalMetadata::default();
        let records = terminal_metadata.program_status();
        let callbacks = hosted_terminal_callbacks(id, mux.clone(), title_changed, records);
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
                reaper_thread: Mutex::new(None),
                reaper_completion: Arc::new(ReaderCompletion::default()),
                term: Mutex::new(Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                terminal_metadata: Mutex::new(terminal_metadata),
                command_tracker: Mutex::new(Default::default()),
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
                published_directory: Mutex::new(PublishedDirectory::Reported(None)),
                directory_pending: AtomicBool::new(true),
                directory_reported: AtomicBool::new(false),
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
                snapshot_position: Default::default(),
                last_attach_colors: Mutex::new(None),
                render: Arc::new(Mutex::new(RenderHub {
                    state: Box::new(render_state),
                    built_generation: 0,
                    latest: None,
                    initial_graphics: None,
                    final_initial: None,
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
                reaper_thread: Mutex::new(None),
                reaper_completion: Arc::new(ReaderCompletion::default()),
                term: Mutex::new(Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                terminal_metadata: Mutex::new(Default::default()),
                command_tracker: Mutex::new(Default::default()),
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
                published_directory: Mutex::new(PublishedDirectory::Reported(None)),
                directory_pending: AtomicBool::new(true),
                directory_reported: AtomicBool::new(false),
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
                snapshot_position: Default::default(),
                last_attach_colors: Mutex::new(None),
                render: Arc::new(Mutex::new(RenderHub {
                    state: Box::new(render_state),
                    built_generation: 0,
                    latest: None,
                    initial_graphics: None,
                    final_initial: None,
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
        set_env(&mut options.extra_env, "AGENT_BROWSER_SESSION", &format!("cmux-{terminal_id}"));
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

#[cfg(test)]
mod tests;
