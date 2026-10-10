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
mod host_state;
mod input;
mod metadata;
mod mouse_input;
mod options;
mod pending_bells;
mod pty_surface;
mod render_tap;
mod render_view;
mod scrolling;
mod shutdown;
pub(crate) mod spawn;
mod stream_progress;
mod terminal_runtime;
mod terminal_stream;
pub use color_overrides::apply_terminal_color_overrides;
pub use host_state::{TerminalHostConnectionState, TerminalHostFallback};
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
#[cfg(any(unix, windows, test))]
use color_overrides::{
    terminal_color_override_delta, terminal_color_override_full_state,
    terminal_color_overrides_match_applied,
};
use frame_producer::spawn_frame_producer;
use scrolling::{
    broadcast_render_scroll_locked, set_terminal_scroll_offset, terminal_scroll_position,
};
#[cfg(any(unix, windows))]
mod hosted_stager;
#[cfg(any(unix, windows))]
use hosted_stager::{HostedFrameStager, HostedTransition};
#[cfg(test)]
use options::child_term_for;
use options::configure_agent_browser_session;
pub(crate) use options::replace_ghostty_cursor_defaults;
pub use options::{DefaultColors, SurfaceOptions, TerminalColors, default_child_term};
use pending_bells::PendingBells;
#[cfg(any(unix, windows))]
mod reconnect_backoff;
#[cfg(any(unix, windows))]
use exit_state::mark_hosted_runtime_exited;
use exit_state::{close_local_terminal_master_after_exit, publish_local_exit_if_ready};
#[cfg(all(unix, test))]
use reconnect_backoff::TERMINAL_HOST_RECONNECT_MAX_FAILURES;
#[cfg(any(unix, windows))]
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
pub use terminal_runtime::PtyTerminalRuntime;
pub(crate) use terminal_runtime::TerminalJournalGap;
use terminal_runtime::{PtyChildStartupGuard, PtyRuntime, ReaderCompletion, ReaderCompletionGuard};
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
#[cfg(any(unix, windows))]
mod clipboard_read;
#[cfg(all(unix, test))]
pub(crate) use clipboard_read::test_fixture::hosted_surface_for_clipboard_test;
#[cfg(any(unix, windows))]
mod host_frames;
#[cfg(any(unix, windows))]
mod hosted_callbacks;
#[cfg(any(unix, windows))]
mod hosted_reader;
#[cfg(any(unix, windows))]
use hosted_callbacks::hosted_terminal_callbacks;
#[cfg(any(unix, windows))]
use hosted_reader::HostedReader;
#[cfg(any(unix, windows))]
mod host_kitty_limits;
#[cfg(all(test, unix))]
mod journal_failure_tests;
#[cfg(any(unix, windows))]
mod journal_reconnect;
#[cfg(any(unix, windows))]
mod prelaunch;
#[cfg(any(unix, windows))]
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
use crate::lock_rank::{LockRank, RankedGuard, RankedMutex};
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
#[cfg(any(unix, windows))]
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
#[cfg(any(unix, windows))]
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PtyLifetime {
    SessionOwned,
    DaemonOwned,
}

/// When a new terminal surface takes its share of the Kitty image budget.
#[derive(Clone, Copy)]
#[cfg_attr(not(any(unix, windows)), allow(dead_code))]
enum KittyQuota {
    /// Before its host launches, waiting for other surfaces to shrink.
    AtLaunch,
    /// Once the surface commits (`Mux::reserve_kitty_image_surface_without_quota`).
    AfterCommit,
}

/// A launched terminal host whose surface is not built yet
/// ([`Surface::prelaunch_hosted`]).
#[cfg(any(unix, windows))]
pub(crate) struct PrelaunchedHost {
    id: SurfaceId,
    terminal_id: crate::terminal_host::TerminalId,
    opts: SurfaceOptions,
    attachment: crate::terminal_host_runtime::HostAttachment,
    kitty_reservation: Option<crate::mux::KittyImageBudgetReservation>,
    terminal_public_id: Option<TerminalPublicId>,
    resource_identity: TabResourceIdentity,
}

#[cfg(any(unix, windows))]
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

#[cfg(any(unix, windows))]
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

    #[cfg(any(unix, windows))]
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
        let host_fallback = attachment
            .launch_ends_with_daemon_job()
            .then_some(TerminalHostFallback::BreakawayDenied);
        let initial_defaults = mux.upgrade().map(|mux| mux.default_colors()).unwrap_or_default();
        attachment.send_default_colors(initial_defaults)?;
        let reader = attachment.take_reader()?;
        if let Ok(delay_ms) = std::env::var("CMUX_TUI_TEST_HOSTED_SPAWN_FAIL_AFTER_CONNECT")
            && let Ok(delay_ms) = delay_ms.parse::<u64>()
        {
            std::thread::sleep(Duration::from_millis(delay_ms));
            anyhow::bail!("injected hosted surface setup failure after attachment");
        }
        let control_responses = attachment.control_responses();
        let smart_renderer = attachment.is_smart_renderer();
        let snapshot = attachment.snapshot.clone();
        let applied_color_overrides = snapshot.colors.clone();
        let title_changed = Arc::new(AtomicBool::new(false));
        let pending_bells = PendingBells::default();
        let mut terminal_metadata = crate::terminal_metadata::TerminalMetadata::default();
        let records = terminal_metadata.program_status();
        let callbacks = hosted_terminal_callbacks(&pending_bells, title_changed.clone(), records);
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
                term: RankedMutex::new(LockRank::Terminal, "pty.term", Box::new(term)),
                stream_progress: Box::new(TerminalStreamProgress::default()),
                terminal_metadata: Mutex::new(terminal_metadata),
                command_tracker: Mutex::new(Default::default()),
                mouse_encoders: RankedMutex::new(
                    LockRank::Leaf,
                    "pty.mouse_encoders",
                    Box::new(mouse_encoders),
                ),
                runtime: RankedMutex::new(
                    LockRank::Runtime,
                    "pty.runtime",
                    PtyRuntime::Hosted(Box::new(attachment)),
                ),
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
                host_fallback: host_fallback.map(std::sync::OnceLock::from).unwrap_or_default(),
                dirty: AtomicBool::new(true),
                title: RankedMutex::new(LockRank::Leaf, "pty.title", title),
                directory_reported: AtomicBool::new(pwd.is_some()),
                pwd: Mutex::new(pwd),
                published_directory: Mutex::new(PublishedDirectory::Unreported),
                directory_pending: AtomicBool::new(true),
                geometry: RankedMutex::new(
                    LockRank::Geometry,
                    "pty.geometry",
                    PtyGeometry {
                        cols: snapshot.cols,
                        rows: snapshot.rows,
                        cell_width: snapshot.cell_pixels.0,
                        cell_height: snapshot.cell_pixels.1,
                    },
                ),
                kitty_graphics_limits: Box::new(RankedMutex::new(
                    LockRank::KittyLimits,
                    "pty.kitty_graphics_limits",
                    snapshot.kitty_state.limits,
                )),
                kitty_limits_request: RankedMutex::new(
                    LockRank::KittyLimitsRequest,
                    "pty.kitty_limits_request",
                    (),
                ),
                #[cfg(test)]
                geometry_test_hook: Mutex::new(None),
                #[cfg(test)]
                deferred_cell_pixel_ack_test_hook: Mutex::new(None),
                #[cfg(test)]
                test_master_control: None,
                #[cfg(test)]
                vt_replay_builds: AtomicUsize::new(0),
                mux: mux.clone(),
                taps: RankedMutex::new(LockRank::AttachTaps, "pty.taps", Vec::new()),
                attach_colors_pending: AtomicBool::new(false),
                attach_colors_force_pending: AtomicBool::new(false),
                snapshot_position: Default::default(),
                last_attach_colors: RankedMutex::new(
                    LockRank::Leaf,
                    "pty.last_attach_colors",
                    None,
                ),
                render: Arc::new(RankedMutex::new(
                    LockRank::Leaf,
                    "pty.render",
                    RenderHub {
                        state: Box::new(render_state),
                        built_generation: 0,
                        latest: None,
                        initial_graphics: None,
                        final_initial: None,
                        taps: Vec::new(),
                    },
                )),
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
        let hosted_reader = HostedReader {
            id,
            mux,
            scrollback: opts.scrollback,
            control_responses,
            sequence_boundary,
            protocol_version,
            smart_renderer,
            applied_color_overrides,
            applied_color_revision: initial_color_revision,
            applied_cursor_activity: initial_cursor_activity,
            title_changed,
            pending_bells,
            output_apply_delay: HostedReader::output_apply_delay_from_env(),
            flap_backoff: TerminalHostReconnectBackoff::default(),
            resync_backoff: TerminalHostReconnectBackoff::default(),
            connected_at: None,
        };
        let reader_thread =
            std::thread::Builder::new().name(format!("surface-{id}-host")).spawn({
                let surface = surface.clone();
                move || hosted_reader.run(surface, reader)
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
        if let Some(delay) = surface
            .as_pty()
            .and_then(|pty| pty.mux.upgrade())
            .and_then(|mux| mux.take_test_terminal_host_disconnect_after_spawn())
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

#[cfg(test)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PtyGeometryTestStep {
    ResizeStarted,
    ResizeCommitBoundary,
    CellPixelStarted,
    CellPixelCommitBoundary,
    ReconnectBackoffStarted,
    /// `mark_output_dirty` is about to publish `SurfaceOutput` to the mux.
    OutputEventStarted,
}

#[cfg(test)]
mod tests;
