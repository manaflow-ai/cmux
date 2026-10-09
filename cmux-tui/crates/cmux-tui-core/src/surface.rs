//! Surface runtime: one tab inside a pane.
//!
//! A surface is either a PTY backed by libghostty-vt state or a local CDP
//! browser surface. PTY-only methods stay available for existing callers;
//! browser-aware frontends should branch on [`SurfaceKind`] before using
//! VT operations.

mod adopt;
mod attach;
mod browser_ops;
mod clear_history;
mod color_overrides;
mod construct;
mod directory;
mod exit_state;
mod frame_producer;
mod geometry;
mod input;
mod metadata;
mod mouse_input;
mod options;
mod pty_surface;
mod render_tap;
mod render_view;
mod scrolling;
mod shutdown;
pub(crate) mod spawn;
mod stream_progress;
mod terminal_stream;
pub use color_overrides::apply_terminal_color_overrides;
// Hosted (unix) code and the unit tests are the only callers.
use clear_history::LOCAL_PASTE_WRITE_TIMEOUT;
pub use clear_history::{
    CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR, CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR,
    CLEAR_HISTORY_PRESERVATION_ERROR, CLEAR_HISTORY_STREAM_TIMEOUT_ERROR, ClearHistoryDelivery,
    ClearHistoryFailure,
};
pub(crate) use clear_history::{
    CLEAR_HISTORY_KEY_TEXT_MAX_BYTES, CLEAR_HISTORY_STREAM_WAIT_TIMEOUT, ClearHistoryTransition,
    apply_clear_history_transition, write_clear_history_fallback,
};
#[cfg(any(unix, test))]
use color_overrides::{
    terminal_color_override_delta, terminal_color_override_full_state,
    terminal_color_overrides_match_applied,
};
use frame_producer::spawn_frame_producer;
use scrolling::{
    broadcast_render_scroll_locked, set_terminal_scroll_offset, terminal_scroll_position,
};
#[cfg(unix)]
mod hosted_stager;
#[cfg(unix)]
use hosted_stager::{HostedFrameStager, HostedTransition};
#[cfg(test)]
use options::child_term_for;
pub(crate) use options::replace_ghostty_cursor_defaults;
pub use options::{DefaultColors, SurfaceOptions, TerminalColors, default_child_term};
#[cfg(unix)]
mod reconnect_backoff;
#[cfg(all(unix, test))]
use reconnect_backoff::TERMINAL_HOST_RECONNECT_MAX_FAILURES;
#[cfg(unix)]
use reconnect_backoff::{
    TERMINAL_HOST_HEALTHY_CONNECTION, TERMINAL_HOST_RECONNECT_MAX_DELAY,
    TerminalHostReconnectBackoff, wait_for_reconnect_after_geometry_failure,
};
#[cfg(test)]
use render_tap::FrameProducerTestHook;
pub use render_tap::{
    RenderAttachFrame, RenderAttachFrameReceiver, RenderAttachStream, SurfaceRenderFrame,
};
use render_tap::{RenderHub, RenderTap};
use spawn::{LocalLaunch, LocalSpawn};
pub(crate) use stream_progress::{TerminalStreamProgress, TerminalStreamSubscription};
#[cfg(test)]
mod test_pty;
#[cfg(test)]
mod test_spawn;
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
