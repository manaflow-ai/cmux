//! TUI event loop and tmux-like command handling.
//!
//! Runs against a [`Session`], which is either the in-process mux or a
//! remote session attached over the control socket. All state mutations
//! go through the session; the app only owns presentation state (render
//! snapshots, prefix arming, the current layout, hit map, selection, and
//! menu/prompt overlays).

use std::collections::{HashMap, HashSet, VecDeque};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use cmux_tui_core::{
    BrowserSource, BrowserStatus, Direction, MuxEvent, PairingChallenge, PaneId, Rect, SplitDir,
    SplitEdge, SplitId, SurfaceId, SurfaceKind, WorkspaceId, exact_split_for_pane_edge,
    layout_screen, split_sides, zellij_default_pane_layout,
};
use crossterm::ExecutableCommand;
use crossterm::event::{
    DisableBracketedPaste, DisableFocusChange, DisableMouseCapture, EnableBracketedPaste,
    EnableFocusChange, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers,
    MouseButton, MouseEvent, MouseEventKind,
};
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ghostty_vt::{
    KeyEncoder, Mods, MouseAction, MouseButton as GhosttyMouseButton, MouseInput, RenderState,
    Screen,
};
use ratatui::Terminal as RatatuiTerminal;
use ratatui::backend::CrosstermBackend;

use crate::browser_input::{
    BrowserInputDispatcher, BrowserInputEvent, BrowserInputKind, BrowserResizeFailure,
};
use crate::config::{Action, ChromeTheme, Config, ScrollbarPosition, SidebarView};
use crate::keys;
use crate::pty_input::{
    PtyInputBytes, PtyInputDispatcher, PtyInputEnqueueResult, PtyInputEvent, PtyInputKind,
    PtyInputSender, PtyOperationDelivery, PtyOperationFailure,
};
use crate::session::{
    ClientInfo, Session, SidebarPluginSurface, SurfaceHandle, TreeView, is_remote_timeout,
    is_remote_transport_failure,
};
use crate::sidebar_files::{FileBrowser, FileCommand, file_url, shell_single_quote};
use crate::ui::graphics::GraphicPlacement;
use crate::ui::graphics_writer::GraphicsWriter;
use crate::ui::input::{InputEvent, TextInput};
use crate::ui::thumb_geometry;

const DEFERRED_INPUT_CAPACITY: usize = 512;
const DEFERRED_INPUT_FIXED_BYTES: usize = 64;
const BRACKETED_PASTE_MARKER_BYTES: usize = 12;
const MAX_DEFERRED_INPUT_BYTES: usize = 4 * 1024 * 1024;
const ROUTING_REFRESH_RETRIES: u8 = 1;
const BACKGROUND_REFRESH_RETRIES: u8 = 6;
const APP_EVENT_CAPACITY: usize = 4_096;
const PTY_FAILURE_CAPACITY: usize = 512;

pub enum AppEvent {
    Mux(MuxEvent),
    MuxTitlesReady,
    MuxSubscriptionRecovered {
        recovery_generation: u64,
        routing_generation: u64,
        result: Result<TreeView, String>,
    },
    MuxRecoveryComplete {
        recovery_generation: u64,
    },
    Input(Event),
    BrowserResizeFailed(BrowserResizeFailure),
    PtyFailuresReady,
    PtyOperationFailed(PtyOperationFailure),
    SessionMutationSettled {
        outcome: SessionMutationOutcome,
        routing: bool,
    },
    RemoteTreeUpdated {
        refresh_sequence: u64,
        routing_generation: u64,
        result: Result<TreeView, String>,
    },
    ClientsUpdated {
        generation: u64,
        result: Result<Vec<ClientInfo>, String>,
    },
    SidebarPluginUpdated {
        status: SidebarPluginSurface,
        relaunch: bool,
    },
}

#[derive(Default)]
struct MuxTitleIngress {
    state: Mutex<MuxTitleIngressState>,
}

fn forward_mux_events(
    event_source: Session,
    mut session_events: cmux_tui_core::MuxEventReceiver,
    routing_mutation_committed: Arc<AtomicU64>,
    mux_recovery_generation: Arc<AtomicU64>,
    tx: SyncSender<AppEvent>,
    mux_titles: Arc<MuxTitleIngress>,
) {
    let mut next_recovery_generation = 0_u64;
    loop {
        let needs_recovery = match session_events.recv() {
            Ok(event) => {
                if matches!(forward_mux_event(event, &tx, &mux_titles), ForwardMuxOutcome::Stop) {
                    return;
                }
                false
            }
            Err(_) => {
                if session_events.overflowed() {
                    true
                } else {
                    return;
                }
            }
        };
        // The mailbox may close immediately after yielding its final accepted
        // event. Recover only after that event is forwarded.
        if !needs_recovery && !session_events.overflowed() {
            continue;
        }
        next_recovery_generation = next_recovery_generation.wrapping_add(1).max(1);
        let recovery_generation = next_recovery_generation;
        mux_recovery_generation.store(recovery_generation, Ordering::Release);
        // Subscribe before draining the closed mailbox so new events are
        // retained while every event accepted before overflow is delivered.
        let overflowed_events = std::mem::replace(&mut session_events, event_source.events());
        for event in overflowed_events.try_iter() {
            if matches!(forward_mux_event(event, &tx, &mux_titles), ForwardMuxOutcome::Stop) {
                return;
            }
        }
        if tx
            .send(AppEvent::Mux(MuxEvent::Status(
                "mux event backlog overflowed; transient events beyond the hard limit were rejected"
                    .to_string(),
            )))
            .is_err()
        {
            return;
        }
        let routing_generation = routing_mutation_committed.load(Ordering::Acquire);
        let title_snapshot_epoch = mux_titles.current_epoch();
        let recovered = event_source.refresh_tree().map_err(|error| error.to_string());
        let recovery_succeeded = recovered.is_ok();
        if recovered.is_ok() {
            mux_titles.reconcile_authoritative(title_snapshot_epoch);
        }
        if tx
            .send(AppEvent::MuxSubscriptionRecovered {
                recovery_generation,
                routing_generation,
                result: recovered,
            })
            .is_err()
        {
            return;
        }
        if !recovery_succeeded {
            if mux_titles.rearm_wake() && tx.send(AppEvent::MuxTitlesReady).is_err() {
                return;
            }
            continue;
        }
        for event in session_events.try_iter() {
            if matches!(forward_mux_event(event, &tx, &mux_titles), ForwardMuxOutcome::Stop) {
                return;
            }
        }
        if session_events.overflowed() {
            continue;
        }
        // A prior title wake may precede the authoritative snapshot. Queue a
        // post-snapshot wake so retained title changes cannot be overwritten.
        if tx.send(AppEvent::MuxTitlesReady).is_err()
            || tx.send(AppEvent::MuxRecoveryComplete { recovery_generation }).is_err()
        {
            return;
        }
    }
}

enum ForwardMuxOutcome {
    Continue,
    Stop,
}

fn forward_mux_event(
    event: MuxEvent,
    tx: &SyncSender<AppEvent>,
    mux_titles: &MuxTitleIngress,
) -> ForwardMuxOutcome {
    match event {
        MuxEvent::TitleChanged { surface, title } => {
            if !mux_titles.push(surface, title) {
                return ForwardMuxOutcome::Continue;
            }
            return match tx.send(AppEvent::MuxTitlesReady) {
                Ok(()) => ForwardMuxOutcome::Continue,
                Err(_) => ForwardMuxOutcome::Stop,
            };
        }
        MuxEvent::SurfaceExited(surface) => mux_titles.remove(surface),
        _ => {}
    }
    let terminal = matches!(event, MuxEvent::Empty);
    match tx.send(AppEvent::Mux(event)) {
        Ok(()) if terminal => ForwardMuxOutcome::Stop,
        Ok(()) => ForwardMuxOutcome::Continue,
        Err(_) => ForwardMuxOutcome::Stop,
    }
}

#[derive(Default)]
struct MuxTitleIngressState {
    wake_queued: bool,
    epoch: u64,
    titles: HashMap<SurfaceId, RetainedMuxTitle>,
    dirty: HashSet<SurfaceId>,
}

struct RetainedMuxTitle {
    title: Arc<str>,
    epoch: u64,
}

impl MuxTitleIngress {
    /// Returns true when the app channel needs one wake event.
    fn push(&self, surface: SurfaceId, title: impl Into<Arc<str>>) -> bool {
        let mut state = self.state.lock().unwrap();
        state.epoch = state.epoch.saturating_add(1);
        let epoch = state.epoch;
        state.titles.insert(surface, RetainedMuxTitle { title: title.into(), epoch });
        state.dirty.insert(surface);
        if state.wake_queued {
            false
        } else {
            state.wake_queued = true;
            true
        }
    }

    fn remove(&self, surface: SurfaceId) {
        let mut state = self.state.lock().unwrap();
        state.titles.remove(&surface);
        state.dirty.remove(&surface);
    }

    fn take_dirty(&self) -> HashMap<SurfaceId, Arc<str>> {
        let mut state = self.state.lock().unwrap();
        state.wake_queued = false;
        let dirty = std::mem::take(&mut state.dirty);
        dirty
            .into_iter()
            .filter_map(|surface| {
                state.titles.get(&surface).map(|retained| (surface, retained.title.clone()))
            })
            .collect()
    }

    fn snapshot(&self) -> HashMap<SurfaceId, Arc<str>> {
        let state = self.state.lock().unwrap();
        state.titles.iter().map(|(surface, retained)| (*surface, retained.title.clone())).collect()
    }

    fn current_epoch(&self) -> u64 {
        self.state.lock().unwrap().epoch
    }

    fn rearm_wake(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        state.wake_queued = false;
        if state.dirty.is_empty() {
            false
        } else {
            state.wake_queued = true;
            true
        }
    }

    fn reconcile_authoritative(&self, through_epoch: u64) {
        let mut state = self.state.lock().unwrap();
        state.titles.retain(|_, retained| retained.epoch > through_epoch);
        let retained_surfaces = state.titles.keys().copied().collect::<HashSet<_>>();
        state.dirty.retain(|surface| retained_surfaces.contains(surface));
    }
}

#[derive(Default)]
struct PtyFailureIngress {
    state: Mutex<PtyFailureIngressState>,
}

#[derive(Default)]
struct PtyFailureIngressState {
    wake_queued: bool,
    failures: VecDeque<PtyOperationFailure>,
}

impl PtyFailureIngress {
    /// Returns true when the app channel needs one wake event.
    fn push(&self, failure: PtyOperationFailure) -> bool {
        let mut state = self.state.lock().unwrap();
        if failure.kind == Some(PtyInputKind::Motion)
            && let Some(existing) = state.failures.iter_mut().find(|existing| {
                existing.kind == Some(PtyInputKind::Motion)
                    && existing.surface_id == failure.surface_id
            })
        {
            *existing = failure;
        } else {
            if state.failures.len() >= PTY_FAILURE_CAPACITY {
                if let Some(index) = state
                    .failures
                    .iter()
                    .position(|existing| existing.kind == Some(PtyInputKind::Motion))
                {
                    state.failures.remove(index);
                } else {
                    state.failures.pop_front();
                }
            }
            state.failures.push_back(failure);
        }
        if state.wake_queued {
            false
        } else {
            state.wake_queued = true;
            true
        }
    }

    fn take(&self) -> VecDeque<PtyOperationFailure> {
        let mut state = self.state.lock().unwrap();
        state.wake_queued = false;
        std::mem::take(&mut state.failures)
    }
}

pub enum SessionMutationOutcome {
    Success {
        tree: Option<TreeView>,
    },
    AuthoritativeMutationSucceeded {
        tree: TreeView,
        authoritative_generation: u64,
        routing_generation: u64,
        completion: Option<SessionCompletion>,
    },
    IdentityRefreshSucceeded {
        tree: TreeView,
        authoritative_generation: u64,
        routing_generation: u64,
        refresh_sequence: u64,
    },
    CommittedTreeStale {
        error: Option<String>,
        completion: Option<SessionCompletion>,
    },
    IdentityRefreshFailed {
        error: String,
        refresh_sequence: u64,
    },
    SurfaceSyncFailed {
        surface: SurfaceId,
        operation: &'static str,
        error: String,
        reconnect_required: bool,
    },
    SurfaceSizeReleased {
        surface: SurfaceId,
    },
    SurfaceSizeReleaseFailed {
        surface: SurfaceId,
        error: String,
    },
    SurfaceSizeReleaseCanceled {
        surface: SurfaceId,
    },
    ClientSizingChanged,
    MutationTimedOut(String),
    Failed(String),
    Canceled,
}

pub struct SessionCompletion {
    mutation_generation: u64,
    action: SessionCompletionAction,
}

enum SessionCompletionAction {
    SurfaceCreated { surface: SurfaceId },
    BrowserTabCreated { surface: SurfaceId },
}

struct PendingSessionMutationState {
    events: SyncSender<AppEvent>,
    pending_mutations: Arc<AtomicUsize>,
    pending_routing_mutations: Arc<AtomicUsize>,
    routing: bool,
    cancellation_pending: Arc<AtomicBool>,
    settled: AtomicBool,
    deferred_outcome: Mutex<Option<SessionMutationOutcome>>,
    canceled_outcome: Mutex<Option<SessionMutationOutcome>>,
}

#[derive(Clone)]
struct PendingSessionMutation(Arc<PendingSessionMutationState>);

impl PendingSessionMutation {
    fn settle(self, outcome: SessionMutationOutcome) {
        if !self.0.settled.swap(true, Ordering::AcqRel) {
            let _ = self
                .0
                .events
                .send(AppEvent::SessionMutationSettled { outcome, routing: self.0.routing });
        }
    }

    fn defer(&self, outcome: SessionMutationOutcome) {
        let mut deferred = self.0.deferred_outcome.lock().unwrap();
        debug_assert!(deferred.is_none(), "session mutation outcome deferred twice");
        *deferred = Some(outcome);
    }

    fn cancel_with(&self, outcome: SessionMutationOutcome) {
        *self.0.canceled_outcome.lock().unwrap() = Some(outcome);
    }

    fn publish_deferred(self) {
        let outcome = self.0.deferred_outcome.lock().unwrap().take();
        if let Some(outcome) = outcome {
            self.settle(outcome);
        }
    }

    fn supersede(self) {
        if !self.0.settled.swap(true, Ordering::AcqRel) {
            let _ = self.0.pending_mutations.fetch_update(
                Ordering::AcqRel,
                Ordering::Acquire,
                |pending| pending.checked_sub(1),
            );
            if self.0.routing {
                let _ = self.0.pending_routing_mutations.fetch_update(
                    Ordering::AcqRel,
                    Ordering::Acquire,
                    |pending| pending.checked_sub(1),
                );
            }
        }
    }
}

impl Drop for PendingSessionMutationState {
    fn drop(&mut self) {
        if !self.settled.load(Ordering::Acquire) {
            let outcome = self
                .canceled_outcome
                .lock()
                .unwrap()
                .take()
                .unwrap_or(SessionMutationOutcome::Canceled);
            match self
                .events
                .try_send(AppEvent::SessionMutationSettled { outcome, routing: self.routing })
            {
                Ok(()) => {}
                Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
                    let _ = self.pending_mutations.fetch_update(
                        Ordering::AcqRel,
                        Ordering::Acquire,
                        |pending| pending.checked_sub(1),
                    );
                    if self.routing {
                        let _ = self.pending_routing_mutations.fetch_update(
                            Ordering::AcqRel,
                            Ordering::Acquire,
                            |pending| pending.checked_sub(1),
                        );
                    }
                    self.cancellation_pending.store(true, Ordering::Release);
                }
            }
        }
    }
}

struct RemoteRefreshClaim(Arc<AtomicBool>);

impl Drop for RemoteRefreshClaim {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

struct SurfaceResizeClaim {
    claims: Arc<Mutex<HashMap<SurfaceId, SurfaceResizeClaimState>>>,
    surface: SurfaceId,
    token: u64,
}

struct SurfaceAttachClaim {
    claims: Arc<Mutex<HashSet<SurfaceId>>>,
    surface: SurfaceId,
}

impl Drop for SurfaceAttachClaim {
    fn drop(&mut self) {
        self.claims.lock().unwrap().remove(&self.surface);
    }
}

#[derive(Clone, Copy)]
struct SurfaceResizeClaimState {
    desired: (u16, u16),
    token: u64,
}

#[derive(Clone, Copy)]
struct SurfaceSyncFailureState {
    attempts: u8,
    retry_after: Option<Instant>,
    sticky_until_reconnect: bool,
}

#[derive(Clone, Copy)]
struct SurfaceResizeFailure {
    desired: (u16, u16),
    state: SurfaceSyncFailureState,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SurfaceResizeOwnership {
    desired: (u16, u16),
    reservation_id: Option<u64>,
}

fn next_surface_sync_failure(
    previous: Option<SurfaceSyncFailureState>,
    transient: bool,
    sticky_until_reconnect: bool,
) -> SurfaceSyncFailureState {
    if !transient {
        return SurfaceSyncFailureState { attempts: 0, retry_after: None, sticky_until_reconnect };
    }
    let attempts = previous.map_or(1, |state| state.attempts.saturating_add(1)).min(6);
    let delay_seconds = 1_u64 << u32::from(attempts.saturating_sub(1));
    SurfaceSyncFailureState {
        attempts,
        retry_after: (attempts < 6)
            .then(|| Instant::now() + Duration::from_secs(delay_seconds.min(30))),
        sticky_until_reconnect: sticky_until_reconnect || attempts >= 6,
    }
}

fn surface_sync_failure_blocks(state: SurfaceSyncFailureState) -> bool {
    state.retry_after.is_none_or(|retry_after| Instant::now() < retry_after)
}

enum SurfaceResizeDecision {
    Noop,
    AlreadyClaimed,
    Failed,
    NeedsQueue(SurfaceResizeClaim),
}

#[derive(Default)]
struct SidebarPluginSyncState {
    epoch: u64,
    claimed: Option<((u16, u16), u64, u64)>,
    applied: Option<((u16, u16), u64, u64)>,
}

struct SidebarPluginSyncClaim {
    state: Arc<Mutex<SidebarPluginSyncState>>,
    desired: ((u16, u16), u64, u64),
    applied: bool,
}

fn sidebar_plugin_status_settles_passive_claim(status: &SidebarPluginSurface) -> bool {
    (status.surface_id.is_some() && status.error.is_none()) || status.retry_after_ms.is_none()
}

impl SidebarPluginSyncClaim {
    fn mark_applied(&mut self) {
        let mut state = self.state.lock().unwrap();
        if state.epoch != self.desired.2 {
            self.applied = true;
            return;
        }
        state.applied = Some(self.desired);
        if state.claimed == Some(self.desired) {
            state.claimed = None;
        }
        self.applied = true;
    }
}

impl Drop for SidebarPluginSyncClaim {
    fn drop(&mut self) {
        if self.applied {
            return;
        }
        let mut state = self.state.lock().unwrap();
        if state.claimed == Some(self.desired) {
            state.claimed = None;
        }
    }
}

impl Drop for SurfaceResizeClaim {
    fn drop(&mut self) {
        let mut claims = self.claims.lock().unwrap();
        if claims.get(&self.surface).is_some_and(|claim| claim.token == self.token) {
            claims.remove(&self.surface);
        }
    }
}

fn record_surface_resize_dispatch_result(
    ownership: &Mutex<HashMap<SurfaceId, SurfaceResizeOwnership>>,
    surface: SurfaceId,
    desired: (u16, u16),
    reservation_id: Option<u64>,
) {
    if let Some(reservation_id) = reservation_id {
        ownership.lock().unwrap().insert(
            surface,
            SurfaceResizeOwnership { desired, reservation_id: Some(reservation_id) },
        );
    }
}

/// Read access stays synchronous, while every UI-originated session mutation
/// enters the same ordered worker as PTY input. Accepted keys, mouse releases,
/// resizes, and closes therefore have one execution order without blocking the
/// event loop.
pub struct OrderedSession {
    inner: Session,
    operations: PtyInputSender,
    events: SyncSender<AppEvent>,
    remote: bool,
    pending_mutations: Arc<AtomicUsize>,
    pending_routing_mutations: Arc<AtomicUsize>,
    cancellation_pending: Arc<AtomicBool>,
    committed_mutation_generation: Arc<AtomicU64>,
    routing_mutation_started: Arc<AtomicU64>,
    routing_mutation_committed: Arc<AtomicU64>,
    remote_refresh_queued: Arc<AtomicBool>,
    remote_background_dirty: Arc<AtomicBool>,
    remote_refresh_sequence: Arc<AtomicU64>,
    client_refresh_queued: Arc<AtomicBool>,
    client_refresh_dirty: Arc<AtomicBool>,
    client_refresh_generation: Arc<AtomicU64>,
    surface_resize_claims: Arc<Mutex<HashMap<SurfaceId, SurfaceResizeClaimState>>>,
    surface_resize_claim_sequence: Arc<AtomicU64>,
    surface_resize_ownership: Arc<Mutex<HashMap<SurfaceId, SurfaceResizeOwnership>>>,
    surface_attach_claims: Arc<Mutex<HashSet<SurfaceId>>>,
    surface_attach_failures: Arc<Mutex<HashMap<SurfaceId, SurfaceSyncFailureState>>>,
    surface_resize_failures: Arc<Mutex<HashMap<SurfaceId, SurfaceResizeFailure>>>,
    config_generation: Arc<AtomicU64>,
    sidebar_plugin_sync: Arc<Mutex<SidebarPluginSyncState>>,
    exited_surfaces: Arc<Mutex<HashSet<SurfaceId>>>,
}

impl OrderedSession {
    fn new(inner: Session, operations: PtyInputSender, events: SyncSender<AppEvent>) -> Self {
        let remote = matches!(inner, Session::Remote(_));
        Self {
            inner,
            operations,
            events,
            remote,
            pending_mutations: Arc::new(AtomicUsize::new(0)),
            pending_routing_mutations: Arc::new(AtomicUsize::new(0)),
            cancellation_pending: Arc::new(AtomicBool::new(false)),
            committed_mutation_generation: Arc::new(AtomicU64::new(0)),
            routing_mutation_started: Arc::new(AtomicU64::new(0)),
            routing_mutation_committed: Arc::new(AtomicU64::new(0)),
            remote_refresh_queued: Arc::new(AtomicBool::new(false)),
            remote_background_dirty: Arc::new(AtomicBool::new(false)),
            remote_refresh_sequence: Arc::new(AtomicU64::new(0)),
            client_refresh_queued: Arc::new(AtomicBool::new(false)),
            client_refresh_dirty: Arc::new(AtomicBool::new(false)),
            client_refresh_generation: Arc::new(AtomicU64::new(0)),
            surface_resize_claims: Arc::new(Mutex::new(HashMap::new())),
            surface_resize_claim_sequence: Arc::new(AtomicU64::new(0)),
            surface_resize_ownership: Arc::new(Mutex::new(HashMap::new())),
            surface_attach_claims: Arc::new(Mutex::new(HashSet::new())),
            surface_attach_failures: Arc::new(Mutex::new(HashMap::new())),
            surface_resize_failures: Arc::new(Mutex::new(HashMap::new())),
            config_generation: Arc::new(AtomicU64::new(0)),
            sidebar_plugin_sync: Arc::new(Mutex::new(SidebarPluginSyncState::default())),
            exited_surfaces: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    fn pending_mutation(&self) -> PendingSessionMutation {
        self.pending_mutation_with_routing(false)
    }

    fn pending_mutation_with_routing(&self, routing: bool) -> PendingSessionMutation {
        self.pending_mutations.fetch_add(1, Ordering::AcqRel);
        if routing {
            self.pending_routing_mutations.fetch_add(1, Ordering::AcqRel);
        }
        PendingSessionMutation(Arc::new(PendingSessionMutationState {
            events: self.events.clone(),
            pending_mutations: self.pending_mutations.clone(),
            pending_routing_mutations: self.pending_routing_mutations.clone(),
            routing,
            cancellation_pending: self.cancellation_pending.clone(),
            settled: AtomicBool::new(false),
            deferred_outcome: Mutex::new(None),
            canceled_outcome: Mutex::new(None),
        }))
    }

    fn tree(&self) -> TreeView {
        self.inner.tree()
    }

    fn respond_pairing(&self, request: u64, approve: bool) -> anyhow::Result<()> {
        self.inner.respond_pairing(request, approve)
    }

    fn refresh_clients_background(&self) {
        self.client_refresh_generation.fetch_add(1, Ordering::AcqRel);
        self.client_refresh_dirty.store(true, Ordering::Release);
        if self.client_refresh_queued.swap(true, Ordering::AcqRel) {
            return;
        }
        let session = self.inner.clone();
        let events = self.events.clone();
        let queued = self.client_refresh_queued.clone();
        let dirty = self.client_refresh_dirty.clone();
        let generation = self.client_refresh_generation.clone();
        let spawn =
            std::thread::Builder::new().name("client-list-refresh".into()).spawn(move || {
                loop {
                    dirty.store(false, Ordering::Release);
                    let request_generation = generation.load(Ordering::Acquire);
                    let result = session.clients().map_err(|error| error.to_string());
                    if request_generation != generation.load(Ordering::Acquire) {
                        continue;
                    }
                    if events
                        .send(AppEvent::ClientsUpdated { generation: request_generation, result })
                        .is_err()
                    {
                        queued.store(false, Ordering::Release);
                        break;
                    }
                    if dirty.swap(false, Ordering::AcqRel) {
                        continue;
                    }
                    queued.store(false, Ordering::Release);
                    // Close the race where an event marked the list dirty while
                    // this worker still owned the queued claim.
                    if dirty.swap(false, Ordering::AcqRel) && !queued.swap(true, Ordering::AcqRel) {
                        continue;
                    }
                    break;
                }
            });
        if let Err(error) = spawn {
            self.client_refresh_queued.store(false, Ordering::Release);
            let generation = self.client_refresh_generation.load(Ordering::Acquire);
            let _ = self
                .events
                .send(AppEvent::ClientsUpdated { generation, result: Err(error.to_string()) });
        }
    }

    fn client_refresh_generation(&self) -> u64 {
        self.client_refresh_generation.load(Ordering::Acquire)
    }

    fn set_client_sizing(&self, client: u64, enabled: bool) {
        self.enqueue_client_sizing_mutation(
            "set client sizing",
            ("set client sizing", client),
            move |session| session.set_client_sizing(client, enabled),
        );
    }

    fn use_only_client_sizing(&self, client: u64) {
        self.enqueue_client_sizing_mutation(
            "use only client sizing",
            ("use only client sizing", 0),
            move |session| session.use_only_client_sizing(client),
        );
    }

    fn use_all_client_sizing(&self) {
        self.enqueue_client_sizing_mutation(
            "use all client sizing",
            ("use all client sizing", 0),
            |session| session.use_all_client_sizing(),
        );
    }

    fn disconnect_client(&self, client: u64) {
        self.enqueue_coalescing_session_mutation(
            "disconnect client",
            ("disconnect client", client),
            move |session| match session.disconnect_client(client) {
                Err(error) if error.to_string().contains(&format!("unknown client {client}")) => {
                    // The menu is a snapshot. A peer can disappear before activation, which
                    // makes this an already-completed detach rather than a session failure.
                    Ok(())
                }
                result => result,
            },
        );
    }

    pub(crate) fn surface(&self, id: SurfaceId) -> Option<SurfaceHandle> {
        self.inner.cached_surface(id)
    }

    fn has_surface(&self, id: SurfaceId) -> bool {
        self.inner.has_surface(id)
    }

    fn has_surface_size_report(&self, id: SurfaceId) -> bool {
        self.inner.has_surface_size_report(id)
    }

    fn invalidate_surface_size_report(&self, id: SurfaceId) {
        self.inner.invalidate_surface_size_report(id);
    }

    fn surface_overflow_retry_due(&self) -> bool {
        self.inner.surface_overflow_retry_due()
    }

    fn forget_surface(&self, id: SurfaceId) {
        if self.remote {
            self.exited_surfaces.lock().unwrap().insert(id);
        }
        self.surface_attach_failures.lock().unwrap().remove(&id);
        self.surface_attach_claims.lock().unwrap().remove(&id);
        self.surface_resize_failures.lock().unwrap().remove(&id);
        self.surface_resize_ownership.lock().unwrap().remove(&id);
        self.inner.forget_surface(id);
    }

    fn invalidate_remote_tree(&self) {
        self.inner.invalidate_remote_tree();
    }

    fn clear_surface_sync_failures(&self) {
        self.surface_attach_failures
            .lock()
            .unwrap()
            .retain(|_, failure| failure.sticky_until_reconnect);
        self.surface_resize_failures.lock().unwrap().clear();
    }

    fn begin_shutdown(&self) {
        self.inner.begin_shutdown();
    }

    fn attach_surface(&self, id: SurfaceId, size: Option<(u16, u16)>) {
        if !self.can_attach_surface(id) {
            return;
        }
        self.surface_attach_claims.lock().unwrap().insert(id);
        let claim = SurfaceAttachClaim { claims: self.surface_attach_claims.clone(), surface: id };
        let session = self.inner.clone();
        let exited_surfaces = self.exited_surfaces.clone();
        let attach_failures = self.surface_attach_failures.clone();
        let enqueue_failures = attach_failures.clone();
        let remote = self.remote;
        let pending = self.pending_mutation();
        let superseded = pending.clone();
        let settlement = pending.clone();
        let enqueue_result = self.operations.enqueue_coalescing_mutation_with_settlement(
            "attach surface",
            ("attach surface", id),
            self.remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || {
                let _claim = claim;
                if exited_surfaces.lock().unwrap().contains(&id)
                    || (remote && session.remote_tree_is_stale())
                {
                    pending.defer(SessionMutationOutcome::Success { tree: None });
                    return Ok(());
                }
                match session.try_surface_sized(id, size) {
                    Ok(Some(_)) => {
                        attach_failures.lock().unwrap().remove(&id);
                        pending.defer(SessionMutationOutcome::Success { tree: None });
                        Ok(())
                    }
                    Ok(None) => {
                        let mut failures = attach_failures.lock().unwrap();
                        let state =
                            next_surface_sync_failure(failures.get(&id).copied(), false, false);
                        failures.insert(id, state);
                        drop(failures);
                        pending.defer(SessionMutationOutcome::SurfaceSyncFailed {
                            surface: id,
                            operation: "attach",
                            error: format!("surface {id} is unavailable"),
                            reconnect_required: false,
                        });
                        Ok(())
                    }
                    Err(error) => {
                        let timed_out = is_remote_timeout(&error);
                        let transport_failed = is_remote_transport_failure(&error);
                        let mut failures = attach_failures.lock().unwrap();
                        let state = next_surface_sync_failure(
                            failures.get(&id).copied(),
                            transport_failed,
                            timed_out,
                        );
                        failures.insert(id, state);
                        drop(failures);
                        pending.defer(SessionMutationOutcome::SurfaceSyncFailed {
                            surface: id,
                            operation: "attach",
                            error: error.to_string(),
                            reconnect_required: timed_out,
                        });
                        if timed_out || transport_failed { Err(error) } else { Ok(()) }
                    }
                }
            },
        );
        if enqueue_result != PtyInputEnqueueResult::Accepted {
            let transient = enqueue_result != PtyInputEnqueueResult::Failed;
            let mut failures = enqueue_failures.lock().unwrap();
            let state = next_surface_sync_failure(failures.get(&id).copied(), transient, false);
            failures.insert(id, state);
        }
    }

    fn can_attach_surface(&self, id: SurfaceId) -> bool {
        self.inner.cached_surface(id).is_none()
            && self.inner.can_attach_after_overflow(id)
            && !self.exited_surfaces.lock().unwrap().contains(&id)
            && !self
                .surface_attach_failures
                .lock()
                .unwrap()
                .get(&id)
                .copied()
                .is_some_and(surface_sync_failure_blocks)
            && !self.surface_attach_claims.lock().unwrap().contains(&id)
            && (!self.remote || !self.inner.remote_tree_is_stale())
    }

    fn reconcile_exited_surfaces(&self, tree: &TreeView) {
        if !self.remote {
            return;
        }
        self.exited_surfaces.lock().unwrap().retain(|surface| {
            tree.workspaces
                .iter()
                .flat_map(|workspace| workspace.screens.iter())
                .flat_map(|screen| screen.panes.iter())
                .flat_map(|pane| pane.tabs.iter())
                .any(|tab| tab.surface == *surface)
        });
    }

    fn has_pending_mutations(&self) -> bool {
        self.pending_mutations.load(Ordering::Acquire) > 0
    }

    fn has_pending_routing_mutations(&self) -> bool {
        self.pending_routing_mutations.load(Ordering::Acquire) > 0
    }

    fn routing_mutation_started(&self) -> u64 {
        self.routing_mutation_started.load(Ordering::Acquire)
    }

    fn routing_mutation_committed(&self) -> u64 {
        self.routing_mutation_committed.load(Ordering::Acquire)
    }

    fn settle_pending_mutation(&self, routing: bool) {
        let result =
            self.pending_mutations.fetch_update(Ordering::AcqRel, Ordering::Acquire, |pending| {
                pending.checked_sub(1)
            });
        debug_assert!(result.is_ok(), "session mutation completion without a pending operation");
        if routing {
            let result = self.pending_routing_mutations.fetch_update(
                Ordering::AcqRel,
                Ordering::Acquire,
                |pending| pending.checked_sub(1),
            );
            debug_assert!(
                result.is_ok(),
                "routing mutation completion without a pending operation"
            );
        }
    }

    fn take_cancellation_pending(&self) -> bool {
        self.cancellation_pending.swap(false, Ordering::AcqRel)
    }

    fn defer_cancellation(&self) {
        self.cancellation_pending.store(true, Ordering::Release);
    }

    fn refresh_remote_tree_if_stale(&self) {
        if !self.inner.take_remote_tree_stale() {
            return;
        }
        if self.remote_refresh_queued.swap(true, Ordering::AcqRel) {
            self.inner.invalidate_remote_tree();
            return;
        }
        self.inner.invalidate_remote_tree();
        let session = self.inner.clone();
        let authoritative_generation = self.committed_mutation_generation.load(Ordering::Acquire);
        let routing_generation = self.routing_mutation_committed.load(Ordering::Acquire);
        let refresh_sequence = self.remote_refresh_sequence.fetch_add(1, Ordering::AcqRel) + 1;
        let pending = self.pending_mutation();
        let claim = RemoteRefreshClaim(self.remote_refresh_queued.clone());
        let spawn =
            std::thread::Builder::new().name("remote-tree-refresh".into()).spawn(move || {
                let result = session.refresh_tree();
                drop(claim);
                match result {
                    Ok(tree) => {
                        pending.settle(SessionMutationOutcome::IdentityRefreshSucceeded {
                            tree,
                            authoritative_generation,
                            routing_generation,
                            refresh_sequence,
                        });
                    }
                    Err(error) => {
                        pending.settle(SessionMutationOutcome::IdentityRefreshFailed {
                            error: error.to_string(),
                            refresh_sequence,
                        });
                    }
                }
            });
        if let Err(error) = spawn {
            self.remote_refresh_queued.store(false, Ordering::Release);
            self.inner.invalidate_remote_tree();
            let _ = self.events.send(AppEvent::PtyOperationFailed(PtyOperationFailure {
                surface_id: None,
                kind: None,
                reservation_id: None,
                label: "remote tree refresh",
                error: error.to_string(),
                lane_failed: false,
                delivery: PtyOperationDelivery::KnownNotDelivered,
            }));
        }
    }

    fn refresh_remote_tree_background(&self) {
        if !self.remote {
            return;
        }
        if self.remote_refresh_queued.swap(true, Ordering::AcqRel) {
            self.remote_background_dirty.store(true, Ordering::Release);
            return;
        }
        let session = self.inner.clone();
        let events = self.events.clone();
        let refresh_sequence = self.remote_refresh_sequence.fetch_add(1, Ordering::AcqRel) + 1;
        let routing_generation = self.routing_mutation_committed.load(Ordering::Acquire);
        let claim = RemoteRefreshClaim(self.remote_refresh_queued.clone());
        let spawn =
            std::thread::Builder::new().name("remote-tree-refresh".into()).spawn(move || {
                let result = session.refresh_tree_background().map_err(|error| error.to_string());
                drop(claim);
                let _ = events.send(AppEvent::RemoteTreeUpdated {
                    refresh_sequence,
                    routing_generation,
                    result,
                });
            });
        if let Err(error) = spawn {
            self.remote_refresh_queued.store(false, Ordering::Release);
            let _ = self.events.send(AppEvent::RemoteTreeUpdated {
                refresh_sequence,
                routing_generation,
                result: Err(error.to_string()),
            });
        }
    }

    fn take_background_refresh_dirty(&self) -> bool {
        self.remote_background_dirty.swap(false, Ordering::AcqRel)
    }

    fn remote_tree_is_stale(&self) -> bool {
        self.inner.remote_tree_is_stale()
    }

    fn enqueue(
        &self,
        label: &'static str,
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        self.enqueue_with_completion(label, false, move |session| {
            operation(session)?;
            Ok(None)
        });
    }

    fn enqueue_routing(
        &self,
        label: &'static str,
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        self.enqueue_with_completion(label, true, move |session| {
            operation(session)?;
            Ok(None)
        });
    }

    fn enqueue_with_completion(
        &self,
        label: &'static str,
        routing: bool,
        operation: impl FnOnce(Session) -> anyhow::Result<Option<SessionCompletionAction>>
        + Send
        + 'static,
    ) {
        let session = self.inner.clone();
        let pending = self.pending_mutation_with_routing(routing);
        let remote = self.remote;
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let routing_token =
            routing.then(|| self.routing_mutation_started.fetch_add(1, Ordering::AcqRel) + 1);
        let routing_mutation_committed = self.routing_mutation_committed.clone();
        let settlement = pending.clone();
        self.operations.enqueue_session_mutation_with_settlement(
            label,
            self.remote,
            move || settlement.publish_deferred(),
            move || {
                let completion = match operation(session.clone()) {
                    Ok(completion) => completion,
                    Err(error) => {
                        if remote && is_remote_timeout(&error) {
                            session.invalidate_remote_tree();
                            pending
                                .defer(SessionMutationOutcome::MutationTimedOut(error.to_string()));
                        } else {
                            pending.defer(SessionMutationOutcome::Failed(error.to_string()));
                        }
                        return Err(error);
                    }
                };
                let mutation_generation =
                    committed_mutation_generation.fetch_add(1, Ordering::AcqRel) + 1;
                if let Some(routing_token) = routing_token {
                    routing_mutation_committed.fetch_max(routing_token, Ordering::AcqRel);
                }
                let completion =
                    completion.map(|action| SessionCompletion { mutation_generation, action });
                session.invalidate_remote_tree();
                if remote {
                    pending.defer(SessionMutationOutcome::CommittedTreeStale {
                        error: None,
                        completion,
                    });
                } else {
                    match session.refresh_tree() {
                        Ok(tree) => {
                            let routing_generation =
                                routing_mutation_committed.load(Ordering::Acquire);
                            pending.defer(SessionMutationOutcome::AuthoritativeMutationSucceeded {
                                tree,
                                authoritative_generation: mutation_generation,
                                routing_generation,
                                completion,
                            });
                        }
                        Err(error) => pending.defer(SessionMutationOutcome::CommittedTreeStale {
                            error: Some(error.to_string()),
                            completion,
                        }),
                    }
                }
                Ok(())
            },
        );
    }

    fn enqueue_coalescing_session_mutation(
        &self,
        label: &'static str,
        key: (&'static str, u64),
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        let session = self.inner.clone();
        let pending = self.pending_mutation();
        let remote = self.remote;
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        self.operations.enqueue_coalescing_mutation_with_settlement(
            label,
            key,
            remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || {
                if let Err(error) = operation(session.clone()) {
                    if remote && is_remote_timeout(&error) {
                        session.invalidate_remote_tree();
                        pending.defer(SessionMutationOutcome::MutationTimedOut(error.to_string()));
                    } else {
                        pending.defer(SessionMutationOutcome::Failed(error.to_string()));
                    }
                    return Err(error);
                }
                committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
                pending.defer(SessionMutationOutcome::Success { tree: None });
                Ok(())
            },
        );
    }

    fn enqueue_client_sizing_mutation(
        &self,
        label: &'static str,
        key: (&'static str, u64),
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        let session = self.inner.clone();
        let pending = self.pending_mutation();
        let remote = self.remote;
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        self.operations.enqueue_coalescing_mutation_with_settlement(
            label,
            key,
            remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || {
                if let Err(error) = operation(session.clone()) {
                    if remote && is_remote_timeout(&error) {
                        session.invalidate_remote_tree();
                        pending.defer(SessionMutationOutcome::MutationTimedOut(error.to_string()));
                    } else {
                        pending.defer(SessionMutationOutcome::Failed(error.to_string()));
                    }
                    return Err(error);
                }
                committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
                pending.defer(SessionMutationOutcome::ClientSizingChanged);
                Ok(())
            },
        );
    }

    fn release_surface_size(&self, surface: SurfaceId) -> bool {
        let session = self.inner.clone();
        let pending = self.pending_mutation();
        pending.cancel_with(SessionMutationOutcome::SurfaceSizeReleaseCanceled { surface });
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        let result = self.operations.enqueue_coalescing_mutation_with_settlement(
            "release hidden surface sizing",
            ("surface size release", surface),
            self.remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || match session.release_surface_size(surface) {
                Ok(()) => {
                    committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
                    pending.defer(SessionMutationOutcome::SurfaceSizeReleased { surface });
                    Ok(())
                }
                Err(error) => {
                    pending.defer(SessionMutationOutcome::SurfaceSizeReleaseFailed {
                        surface,
                        error: error.to_string(),
                    });
                    Err(error)
                }
            },
        );
        result == PtyInputEnqueueResult::Accepted
    }

    fn resize_surface(
        &self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        cols: u16,
        rows: u16,
        reassert: bool,
        claim: SurfaceResizeClaim,
    ) {
        let pending = self.pending_mutation();
        let failures = self.surface_resize_failures.clone();
        let enqueue_failures = failures.clone();
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        let enqueue_result = self.operations.enqueue_coalescing_mutation_with_settlement(
            "resize PTY surface",
            ("surface resize", surface_id),
            self.remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || {
                let result = if reassert {
                    surface.reassert_size(cols, rows)
                } else {
                    surface.resize(cols, rows)
                };
                // Release local ownership before the worker publishes its
                // post-operation settlement barrier.
                drop(claim);
                match result {
                    Ok(_) => {
                        failures.lock().unwrap().remove(&surface_id);
                        committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
                        pending.defer(SessionMutationOutcome::Success { tree: None });
                        Ok(())
                    }
                    Err(error) => {
                        let transient =
                            is_remote_timeout(&error) || is_remote_transport_failure(&error);
                        let mut failures = failures.lock().unwrap();
                        let previous = failures.get(&surface_id).map(|failure| failure.state);
                        let state = next_surface_sync_failure(previous, transient, false);
                        failures.insert(
                            surface_id,
                            SurfaceResizeFailure { desired: (cols, rows), state },
                        );
                        drop(failures);
                        pending.defer(SessionMutationOutcome::SurfaceSyncFailed {
                            surface: surface_id,
                            operation: "resize",
                            error: error.to_string(),
                            reconnect_required: state.sticky_until_reconnect,
                        });
                        if transient { Err(error) } else { Ok(()) }
                    }
                }
            },
        );
        if enqueue_result != PtyInputEnqueueResult::Accepted {
            let transient = enqueue_result != PtyInputEnqueueResult::Failed;
            let mut failures = enqueue_failures.lock().unwrap();
            let previous = failures.get(&surface_id).map(|failure| failure.state);
            let state = next_surface_sync_failure(previous, transient, false);
            failures.insert(surface_id, SurfaceResizeFailure { desired: (cols, rows), state });
        }
    }

    fn confirm_surface_resize(
        &self,
        surface: SurfaceId,
        size: (u16, u16),
        reservation_id: Option<u64>,
    ) {
        let mut ownership = self.surface_resize_ownership.lock().unwrap();
        if ownership.get(&surface).is_some_and(|ownership| {
            ownership.desired == size
                && reservation_id.is_none_or(|id| ownership.reservation_id == Some(id))
        }) {
            ownership.remove(&surface);
        }
        drop(ownership);
        let mut failures = self.surface_resize_failures.lock().unwrap();
        if failures.get(&surface).is_some_and(|failure| failure.desired == size) {
            failures.remove(&surface);
        }
    }

    fn note_surface_resize_failure(
        &self,
        surface: SurfaceId,
        desired: (u16, u16),
        retry_after_ms: Option<u64>,
        reservation_id: Option<u64>,
    ) -> bool {
        if self.surface_resize_ownership.lock().unwrap().get(&surface).is_none_or(|ownership| {
            ownership.desired != desired
                || reservation_id.is_some_and(|id| ownership.reservation_id != Some(id))
        }) {
            return false;
        }
        let mut failures = self.surface_resize_failures.lock().unwrap();
        let previous = failures
            .get(&surface)
            .filter(|failure| failure.desired == desired)
            .map(|failure| failure.state);
        let mut state = next_surface_sync_failure(previous, true, retry_after_ms.is_none());
        if let Some(delay) = retry_after_ms {
            state.retry_after = Some(Instant::now() + Duration::from_millis(delay));
            state.sticky_until_reconnect = false;
        }
        failures.insert(surface, SurfaceResizeFailure { desired, state });
        true
    }

    fn surface_resize_retry_due(&self) -> bool {
        let now = Instant::now();
        self.surface_resize_failures.lock().unwrap().values().any(|failure| {
            !failure.state.sticky_until_reconnect
                && failure.state.retry_after.is_some_and(|retry_after| now >= retry_after)
        })
    }

    fn surface_resize_decision(
        &self,
        surface_id: SurfaceId,
        desired: (u16, u16),
        surface_needs_resize: bool,
    ) -> SurfaceResizeDecision {
        let mut failures = self.surface_resize_failures.lock().unwrap();
        if let Some(failure) = failures.get(&surface_id).copied()
            && failure.desired == desired
            && surface_sync_failure_blocks(failure.state)
        {
            return SurfaceResizeDecision::Failed;
        }
        if failures.get(&surface_id).is_some_and(|failure| failure.desired != desired) {
            failures.remove(&surface_id);
        }
        drop(failures);
        let mut claims = self.surface_resize_claims.lock().unwrap();
        if claims.get(&surface_id).is_some_and(|claim| claim.desired == desired) {
            return SurfaceResizeDecision::AlreadyClaimed;
        }
        if !claims.contains_key(&surface_id) && !surface_needs_resize {
            return SurfaceResizeDecision::Noop;
        }
        let token = self.surface_resize_claim_sequence.fetch_add(1, Ordering::AcqRel) + 1;
        claims.insert(surface_id, SurfaceResizeClaimState { desired, token });
        SurfaceResizeDecision::NeedsQueue(SurfaceResizeClaim {
            claims: self.surface_resize_claims.clone(),
            surface: surface_id,
            token,
        })
    }

    fn apply_config(&self, config: Config) {
        let session = self.inner.clone();
        let pending = self.pending_mutation();
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let config_generation = self.config_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        self.operations.enqueue_coalescing_mutation_with_settlement(
            "apply config",
            ("apply config", 0),
            self.remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || {
                session.apply_config(&config);
                config_generation.fetch_add(1, Ordering::AcqRel);
                committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
                pending.defer(SessionMutationOutcome::Success { tree: None });
                Ok(())
            },
        );
    }

    fn sidebar_plugin(&self, size: (u16, u16), relaunch: bool) {
        let config_generation = self.config_generation.load(Ordering::Acquire);
        let claim = if relaunch {
            None
        } else {
            let mut state = self.sidebar_plugin_sync.lock().unwrap();
            let desired = (size, config_generation, state.epoch);
            if state.claimed == Some(desired) || state.applied == Some(desired) {
                return;
            }
            state.claimed = Some(desired);
            Some(SidebarPluginSyncClaim {
                state: self.sidebar_plugin_sync.clone(),
                desired,
                applied: false,
            })
        };
        let session = self.inner.clone();
        let events = self.events.clone();
        let pending = self.pending_mutation();
        let superseded = pending.clone();
        let settlement = pending.clone();
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let operation = move || {
            let mut claim = claim;
            let status = session.sidebar_plugin(size, relaunch);
            let settles_passive_claim = sidebar_plugin_status_settles_passive_claim(&status);
            let _ = events.send(AppEvent::SidebarPluginUpdated { status, relaunch });
            committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
            if settles_passive_claim && let Some(claim) = &mut claim {
                claim.mark_applied();
            }
            pending.defer(SessionMutationOutcome::Success { tree: None });
            Ok(())
        };
        if relaunch {
            self.operations.enqueue_session_mutation_with_settlement(
                "relaunch sidebar plugin",
                self.remote,
                move || settlement.publish_deferred(),
                operation,
            );
        } else {
            self.operations.enqueue_coalescing_mutation_with_settlement(
                "sync sidebar plugin",
                ("sidebar plugin", 0),
                self.remote,
                move || superseded.supersede(),
                move || settlement.publish_deferred(),
                operation,
            );
        }
    }

    fn invalidate_sidebar_plugin_sync(&self) {
        let mut state = self.sidebar_plugin_sync.lock().unwrap();
        if state.claimed.is_none() && state.applied.is_none() {
            return;
        }
        state.epoch = state.epoch.wrapping_add(1);
        state.claimed = None;
        state.applied = None;
    }

    pub fn new_tab(&self, pane: Option<PaneId>, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        self.enqueue_with_completion("create tab", true, move |session| {
            let surface = session.new_tab(pane, size)?;
            Ok(Some(SessionCompletionAction::SurfaceCreated { surface }))
        });
        Ok(())
    }

    pub fn run_command(
        &self,
        argv: Vec<String>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<()> {
        self.enqueue_with_completion("run command", true, move |session| {
            let surface = session.run_command(argv, pane, cwd, size)?;
            Ok(Some(SessionCompletionAction::SurfaceCreated { surface }))
        });
        Ok(())
    }

    pub fn surface_cwd(&self, surface: SurfaceId) -> Option<String> {
        self.inner.surface_cwd(surface)
    }

    pub fn new_browser_tab(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<()> {
        self.enqueue_with_completion("create browser tab", true, move |session| {
            let surface = session.new_browser_tab(url, pane, size)?;
            Ok(Some(SessionCompletionAction::BrowserTabCreated { surface }))
        });
        Ok(())
    }

    pub fn set_cell_pixel_size(&self, width: u16, height: u16) {
        let ownership = self.surface_resize_ownership.clone();
        self.enqueue("set cell pixel size", move |session| {
            session.set_cell_pixel_size(
                width,
                height,
                Arc::new(move |surface, desired, accepted| {
                    record_surface_resize_dispatch_result(&ownership, surface, desired, accepted);
                }),
            )
        });
    }

    pub fn new_workspace(&self, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        self.enqueue_with_completion("create workspace", true, move |session| {
            let surface = session.new_workspace(size)?;
            Ok(Some(SessionCompletionAction::SurfaceCreated { surface }))
        });
        Ok(())
    }

    pub fn new_screen(
        &self,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<()> {
        self.enqueue_with_completion("create screen", true, move |session| {
            let surface = session.new_screen(workspace, size)?;
            Ok(Some(SessionCompletionAction::SurfaceCreated { surface }))
        });
        Ok(())
    }

    pub fn close_screen(&self, screen: cmux_tui_core::ScreenId) {
        self.enqueue_routing("close screen", move |session| session.close_screen(screen));
    }

    pub fn rename_screen(&self, screen: cmux_tui_core::ScreenId, name: String) {
        self.enqueue("rename screen", move |session| session.rename_screen(screen, name));
    }

    pub fn select_screen(&self, index: Option<usize>, delta: Option<isize>) {
        self.enqueue_routing("select screen", move |session| session.select_screen(index, delta));
    }

    pub fn zoom_pane(&self, pane: Option<PaneId>) {
        self.enqueue("zoom pane", move |session| session.zoom_pane(pane));
    }

    pub fn split(
        &self,
        pane: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<()> {
        self.enqueue_with_completion("split pane", true, move |session| {
            let surface = session.split(pane, dir, size)?;
            Ok(Some(SessionCompletionAction::SurfaceCreated { surface }))
        });
        Ok(())
    }

    pub fn new_pane(&self, pane: PaneId, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        self.enqueue_with_completion("create pane", true, move |session| {
            let surface = session.new_pane(pane, size)?;
            Ok(Some(SessionCompletionAction::SurfaceCreated { surface }))
        });
        Ok(())
    }

    pub fn set_split_ratio(&self, split: SplitId, ratio: f32) {
        self.set_split_ratio_deferred(split, ratio);
        self.settle_split_ratio();
    }

    fn set_split_ratio_deferred(&self, split: SplitId, ratio: f32) {
        self.enqueue_coalescing_session_mutation(
            "resize exact pane split",
            ("split id", split),
            move |session| session.set_split_ratio(split, ratio),
        );
    }

    fn settle_split_ratio(&self) {
        self.enqueue("settle split resize", |_| Ok(()));
    }

    pub fn close_surface(&self, surface: SurfaceId) {
        self.enqueue_routing("close tab", move |session| session.close_surface(surface));
    }

    pub fn close_pane(&self, pane: PaneId) {
        self.enqueue_routing("close pane", move |session| session.close_pane(pane));
    }

    pub fn swap_pane(&self, pane: PaneId, target: PaneId) {
        self.enqueue("swap panes", move |session| session.swap_pane(pane, target));
    }

    pub fn close_workspace(&self, workspace: WorkspaceId) {
        self.enqueue_routing("close workspace", move |session| session.close_workspace(workspace));
    }

    pub fn rename_surface(&self, surface: SurfaceId, name: String) {
        self.enqueue("rename tab", move |session| session.rename_surface(surface, name));
    }

    pub fn rename_workspace(&self, workspace: WorkspaceId, name: String) {
        self.enqueue("rename workspace", move |session| session.rename_workspace(workspace, name));
    }

    pub fn focus_pane(&self, pane: PaneId) {
        self.enqueue_routing("focus pane", move |session| session.focus_pane(pane));
    }

    pub fn select_tab(&self, pane: Option<PaneId>, index: Option<usize>, delta: Option<isize>) {
        self.enqueue_routing("select tab", move |session| session.select_tab(pane, index, delta));
    }

    pub fn select_workspace(&self, index: Option<usize>, delta: Option<isize>) {
        self.enqueue_routing("select workspace", move |session| {
            session.select_workspace(index, delta)
        });
    }

    pub fn move_tab(&self, surface: SurfaceId, pane: PaneId, index: usize) {
        self.enqueue_routing("move tab", move |session| session.move_tab(surface, pane, index));
    }

    pub fn move_workspace(&self, workspace: WorkspaceId, index: usize) {
        self.enqueue("move workspace", move |session| session.move_workspace(workspace, index));
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RenderAction {
    None,
    Graphics,
    Paint,
    Draw,
}

impl RenderAction {
    fn merge(self, other: Self) -> Self {
        match (self, other) {
            (RenderAction::Draw, _) | (_, RenderAction::Draw) => RenderAction::Draw,
            (RenderAction::Paint, _) | (_, RenderAction::Paint) => RenderAction::Paint,
            (RenderAction::Graphics, _) | (_, RenderAction::Graphics) => RenderAction::Graphics,
            (RenderAction::None, RenderAction::None) => RenderAction::None,
        }
    }
}

/// A clickable region of the current frame. The renderers rebuild the hit
/// map every draw, so hit-testing always matches what is on screen.
/// Left-click performs the action; right-click opens the matching context
/// menu where one exists (workspace rows, panes).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Hit {
    /// Sidebar workspace entry.
    Workspace {
        index: usize,
        id: WorkspaceId,
    },
    NewWorkspace,
    /// A visible row in the built-in file browser.
    SidebarFile {
        index: usize,
    },
    /// Status-bar screen entry.
    ScreenEntry {
        index: usize,
        id: cmux_tui_core::ScreenId,
    },
    NewScreen,
    /// Pane tab-bar entry.
    Tab {
        pane: PaneId,
        index: usize,
    },
    NewTab {
        pane: PaneId,
    },
    Clients {
        surface: SurfaceId,
    },
    /// A pane's scrollbar column (click/drag jumps the viewport).
    Scrollbar {
        surface: SurfaceId,
        track: Rect,
    },
    /// Sidebar right border.
    SidebarResize,
    /// Pane border resize handle.
    PaneResize {
        horizontal: Option<(PaneId, PaneEdge)>,
        vertical: Option<(PaneId, PaneEdge)>,
    },
    /// Scroll a pane's tab bar left/right (overflow arrows, wheel).
    TabScroll {
        pane: PaneId,
        delta: isize,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaneEdge {
    Left,
    Right,
    Top,
    Bottom,
}

/// One pane's screen real estate for the current frame. Every pane draws
/// a border box in its rect; the top border row doubles as the tab bar
/// and the scrollbar is either inside the box or on the right border.
/// `content` is the terminal area inside the box. Rects too small for a
/// box get `bar: None` and content = rect.
#[derive(Debug, Clone, Copy)]
pub struct PaneArea {
    pub pane: PaneId,
    pub surface: SurfaceId,
    pub rect: Rect,
    pub bar: Option<Rect>,
    pub omnibar: Option<Rect>,
    pub content: Rect,
    /// Scrollbar track (inside the box or on the right border).
    pub track: Option<Rect>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OmnibarHit {
    Back,
    Forward,
    Reload,
    Edit,
}

/// A context-menu entry: what activating it does (the label is derived).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    RenameWorkspace(WorkspaceId),
    CopyWorkspaceId(WorkspaceId),
    CloseWorkspace(WorkspaceId),
    RenameScreen(cmux_tui_core::ScreenId),
    CloseScreen(cmux_tui_core::ScreenId),
    BrowserBack(PaneId),
    BrowserForward(PaneId),
    BrowserReload(PaneId),
    BrowserEditUrl(PaneId),
    BrowserCopyUrl(PaneId),
    BrowserActivate(PaneId),
    RenameTab(PaneId),
    CopyTabId(PaneId),
    CopyPaneId(PaneId),
    NewTab(PaneId),
    NewBrowserTab(PaneId),
    SplitRight(PaneId),
    SplitDown(PaneId),
    CloseTab(PaneId),
    ClosePane(PaneId),
    SetClientSizing { client: u64, enabled: bool },
    UseClientSize(u64),
    RestoreAllClientSizing,
    DisconnectClient(u64),
}

impl MenuAction {
    pub fn label(&self) -> &'static str {
        match self {
            MenuAction::RenameWorkspace(_) => "Rename workspace",
            MenuAction::CopyWorkspaceId(_) => "Copy workspace id",
            MenuAction::CloseWorkspace(_) => "Close workspace",
            MenuAction::RenameScreen(_) => "Rename screen",
            MenuAction::CloseScreen(_) => "Close screen",
            MenuAction::BrowserBack(_) => "Back",
            MenuAction::BrowserForward(_) => "Forward",
            MenuAction::BrowserReload(_) => "Reload",
            MenuAction::BrowserEditUrl(_) => "Edit URL",
            MenuAction::BrowserCopyUrl(_) => "Copy URL",
            MenuAction::BrowserActivate(_) => "Show in Chrome",
            MenuAction::RenameTab(_) => "Rename tab",
            MenuAction::CopyTabId(_) => "Copy tab id",
            MenuAction::CopyPaneId(_) => "Copy pane id",
            MenuAction::NewTab(_) => "New tab",
            MenuAction::NewBrowserTab(_) => "New browser tab",
            MenuAction::SplitRight(_) => "Split right",
            MenuAction::SplitDown(_) => "Split down",
            MenuAction::CloseTab(_) => "Close tab",
            MenuAction::ClosePane(_) => "Close pane",
            MenuAction::SetClientSizing { enabled: true, .. } => "Use for sizing",
            MenuAction::SetClientSizing { enabled: false, .. } => "Exclude from sizing",
            MenuAction::UseClientSize(_) => "Use only this client size",
            MenuAction::RestoreAllClientSizing => "Use all client sizes",
            MenuAction::DisconnectClient(_) => "Disconnect",
        }
    }
}

/// One row in a context menu. Separators divide related action groups and
/// are skipped by keyboard and mouse selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuItem {
    Action(MenuAction),
    Submenu { label: String, items: Vec<MenuItem> },
    Separator,
}

impl MenuItem {
    pub fn action(&self) -> Option<MenuAction> {
        match self {
            MenuItem::Action(action) => Some(*action),
            MenuItem::Submenu { .. } | MenuItem::Separator => None,
        }
    }

    pub fn label(&self) -> Option<&str> {
        match self {
            MenuItem::Action(action) => Some(action.label()),
            MenuItem::Submenu { label, .. } => Some(label),
            MenuItem::Separator => None,
        }
    }

    fn selectable(&self) -> bool {
        !matches!(self, MenuItem::Separator)
    }

    fn submenu(&self) -> Option<&[MenuItem]> {
        match self {
            MenuItem::Submenu { items, .. } => Some(items),
            _ => None,
        }
    }
}

pub struct MenuLevel {
    pub items: Vec<MenuItem>,
    all_items: Vec<MenuItem>,
    pub selected: usize,
    pub scroll_offset: usize,
    visible_rows: usize,
    pub rect: Rect,
}

impl MenuLevel {
    fn new(x: u16, y: u16, items: Vec<MenuItem>) -> Self {
        let label_w = items
            .iter()
            .filter_map(MenuItem::label)
            .map(|label| label.chars().count())
            .max()
            .unwrap_or(0) as u16;
        let width = label_w + 2 + ContextMenu::PAD * 2 + 2;
        let height = items.len() as u16 + 2;
        let selected = items.iter().position(MenuItem::selectable).unwrap_or(0);
        let visible_rows = items.len();
        Self {
            all_items: items.clone(),
            items,
            selected,
            scroll_offset: 0,
            visible_rows,
            rect: Rect { x, y, width, height },
        }
    }

    pub fn fit_to_rows(&mut self, max_rows: usize) {
        let selected_item = self.items.get(self.selected).cloned();
        let selectable_count = self.all_items.iter().filter(|item| item.selectable()).count();
        let mut separator_budget = max_rows.saturating_sub(selectable_count);
        self.items = self
            .all_items
            .iter()
            .filter(|item| match item {
                MenuItem::Separator if separator_budget > 0 => {
                    separator_budget -= 1;
                    true
                }
                MenuItem::Separator => false,
                _ => true,
            })
            .cloned()
            .collect();
        self.selected = selected_item
            .and_then(|selected| self.items.iter().position(|item| *item == selected))
            .or_else(|| self.items.iter().position(MenuItem::selectable))
            .unwrap_or(0);
        self.visible_rows = self.items.len().min(max_rows);
        self.ensure_selection_visible();
        self.rect.height = self.visible_rows as u16 + 2;
    }

    fn ensure_selection_visible(&mut self) {
        if self.visible_rows == 0 || self.items.is_empty() {
            self.scroll_offset = 0;
            return;
        }
        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        } else if self.selected >= self.scroll_offset + self.visible_rows {
            self.scroll_offset = self.selected + 1 - self.visible_rows;
        }
        self.scroll_offset =
            self.scroll_offset.min(self.items.len().saturating_sub(self.visible_rows));
    }
}

/// Right-click context menu overlay. The rect includes the border chrome;
/// action rows get a one-cell padding column on each side inside that border,
/// groups are divided by separator rows, and the hover/selection highlight
/// spans the full inner row including those padding cells.
pub struct ContextMenu {
    pub levels: Vec<MenuLevel>,
    right_press: (u16, u16),
    right_drag_moved: bool,
}

impl ContextMenu {
    /// Horizontal padding between the menu edge and the item labels.
    pub const PAD: u16 = 1;

    fn at(x: u16, y: u16, groups: Vec<Vec<MenuAction>>) -> Self {
        Self::with_groups(
            x,
            y,
            groups
                .into_iter()
                .map(|group| group.into_iter().map(MenuItem::Action).collect())
                .collect(),
        )
    }

    fn with_groups(x: u16, y: u16, groups: Vec<Vec<MenuItem>>) -> Self {
        let mut items = Vec::new();
        for group in groups.into_iter().filter(|group| !group.is_empty()) {
            if !items.is_empty() {
                items.push(MenuItem::Separator);
            }
            items.extend(group);
        }
        ContextMenu {
            levels: vec![MenuLevel::new(x.saturating_sub(1), y.saturating_sub(1), items)],
            right_press: (x, y),
            right_drag_moved: false,
        }
    }

    /// The item row at a screen cell. Border cells are dead chrome and
    /// never activate an item.
    #[cfg(test)]
    pub fn item_at(&self, x: u16, y: u16) -> Option<usize> {
        self.hit_at(x, y).filter(|(depth, _)| *depth == 0).map(|(_, item)| item)
    }

    pub fn hit_at(&self, x: u16, y: u16) -> Option<(usize, usize)> {
        let (depth, level) =
            self.levels.iter().enumerate().rev().find(|(_, level)| level.rect.contains(x, y))?;
        let rect = level.rect;
        let right = rect.x + rect.width.saturating_sub(1);
        let bottom = rect.y + rect.height.saturating_sub(1);
        if x == rect.x || y == rect.y || x == right || y == bottom {
            return None;
        }
        let row = level.scroll_offset + (y - rect.y - 1) as usize;
        level.items.get(row).filter(|item| item.selectable()).map(|_| (depth, row))
    }

    pub fn contains(&self, x: u16, y: u16) -> bool {
        self.levels.iter().any(|level| level.rect.contains(x, y))
    }

    pub fn intersects(&self, rect: Rect) -> bool {
        self.levels.iter().any(|level| rects_intersect(rect, level.rect))
    }

    fn selected_action(&self) -> Option<MenuAction> {
        let level = self.levels.last()?;
        level.items.get(level.selected).and_then(MenuItem::action)
    }

    fn action_at(&self, depth: usize, item: usize) -> Option<MenuAction> {
        self.levels.get(depth)?.items.get(item).and_then(MenuItem::action)
    }

    fn open_selected_submenu(&mut self) -> bool {
        let depth = self.levels.len().saturating_sub(1);
        let Some(parent) = self.levels.get(depth) else {
            return false;
        };
        let Some(items) = parent.items.get(parent.selected).and_then(MenuItem::submenu) else {
            return false;
        };
        let x = parent.rect.x.saturating_add(parent.rect.width.saturating_sub(1));
        let y = parent
            .rect
            .y
            .saturating_add(1)
            .saturating_add(parent.selected.saturating_sub(parent.scroll_offset) as u16);
        self.levels.push(MenuLevel::new(x, y, items.to_vec()));
        true
    }

    fn close_submenu(&mut self) -> bool {
        if self.levels.len() > 1 {
            self.levels.pop();
            true
        } else {
            false
        }
    }

    fn select_at(&mut self, depth: usize, item: usize) -> bool {
        let had_deeper_level = self.levels.len() != depth + 1;
        let Some(level) = self.levels.get_mut(depth) else { return false };
        if !level.items.get(item).is_some_and(MenuItem::selectable) {
            return false;
        }
        let changed = level.selected != item || had_deeper_level;
        level.selected = item;
        level.ensure_selection_visible();
        self.levels.truncate(depth + 1);
        self.open_selected_submenu();
        changed || self.levels.len() > depth + 1
    }

    /// Keep every action row visible when separators are the only reason the
    /// menu exceeds the available height. Full grouping returns after a resize.
    #[cfg(test)]
    pub fn fit_to_rows(&mut self, max_rows: usize) {
        if let Some(level) = self.levels.first_mut() {
            level.fit_to_rows(max_rows);
        }
    }

    fn select_previous(&mut self) {
        let Some(level) = self.levels.last_mut() else { return };
        if let Some(index) = level
            .items
            .get(..level.selected)
            .and_then(|items| items.iter().rposition(MenuItem::selectable))
        {
            level.selected = index;
            level.ensure_selection_visible();
            let depth = self.levels.len();
            self.levels.truncate(depth);
        }
    }

    fn select_next(&mut self) {
        let Some(level) = self.levels.last_mut() else { return };
        let start = level.selected.saturating_add(1);
        if let Some(offset) =
            level.items.get(start..).and_then(|items| items.iter().position(MenuItem::selectable))
        {
            level.selected += offset + 1;
            level.ensure_selection_visible();
        }
    }
}

fn pane_context_menu_groups(
    pane: PaneId,
    is_browser: bool,
    external_browser: bool,
) -> Vec<Vec<MenuAction>> {
    let mut browser_actions = Vec::new();
    if is_browser {
        browser_actions.extend([
            MenuAction::BrowserBack(pane),
            MenuAction::BrowserForward(pane),
            MenuAction::BrowserReload(pane),
            MenuAction::BrowserEditUrl(pane),
            MenuAction::BrowserCopyUrl(pane),
        ]);
        if external_browser {
            browser_actions.push(MenuAction::BrowserActivate(pane));
        }
    }
    vec![
        vec![MenuAction::RenameTab(pane), MenuAction::CloseTab(pane)],
        vec![MenuAction::NewTab(pane), MenuAction::NewBrowserTab(pane)],
        browser_actions,
        vec![
            MenuAction::SplitRight(pane),
            MenuAction::SplitDown(pane),
            MenuAction::ClosePane(pane),
        ],
        vec![MenuAction::CopyTabId(pane), MenuAction::CopyPaneId(pane)],
    ]
}

fn client_menu_item(clients: &[ClientInfo], surface: SurfaceId) -> Option<MenuItem> {
    if clients.is_empty() {
        return None;
    }
    let mut items = Vec::new();
    if let Some(current) = clients.iter().find(|client| {
        client.is_self
            && client
                .sizes
                .iter()
                .any(|size| size.surface == surface && size.cols.is_some() && size.rows.is_some())
    }) {
        items.push(MenuItem::Action(MenuAction::UseClientSize(current.client)));
    }
    items.extend([MenuItem::Action(MenuAction::RestoreAllClientSizing), MenuItem::Separator]);
    for client in clients {
        let reported_size = client
            .sizes
            .iter()
            .find(|size| size.surface == surface)
            .and_then(|size| size.cols.zip(size.rows));
        let identity = client.kind.as_deref().or(client.name.as_deref()).unwrap_or("client");
        let size = reported_size
            .map(|(cols, rows)| format!("{cols}×{rows}"))
            .unwrap_or_else(|| "no grid".to_string());
        let self_label = if client.is_self { " · this client" } else { "" };
        let sizing_label = if client.size_participating { "" } else { " · excluded" };
        let label = format!("#{} {identity} · {size}{self_label}{sizing_label}", client.client);
        let mut actions = Vec::new();
        if reported_size.is_some() {
            actions.extend([
                MenuItem::Action(MenuAction::UseClientSize(client.client)),
                MenuItem::Action(MenuAction::SetClientSizing {
                    client: client.client,
                    enabled: !client.size_participating,
                }),
            ]);
        }
        if client.client != 0 {
            if !actions.is_empty() {
                actions.push(MenuItem::Separator);
            }
            actions.push(MenuItem::Action(MenuAction::DisconnectClient(client.client)));
        }
        items.push(MenuItem::Submenu { label, items: actions });
    }
    Some(MenuItem::Submenu { label: format!("Connected clients ({})", clients.len()), items })
}

/// What a committed rename prompt applies to.
#[derive(Debug, Clone, Copy)]
pub enum PromptTarget {
    Workspace(WorkspaceId),
    Screen(cmux_tui_core::ScreenId),
    Surface(SurfaceId),
}

/// Centered rename dialog: a text input with OK/Cancel buttons. The
/// renderer writes the final geometry back so mouse hit-testing (buttons,
/// dismiss-outside) matches what is drawn.
pub struct Prompt {
    pub label: &'static str,
    pub input: TextInput,
    pub target: PromptTarget,
    /// Dialog rect (set by the renderer each frame).
    pub rect: Rect,
    /// Input / button rects (set by the renderer each frame).
    pub input_rect: Rect,
    pub clear: Rect,
    pub ok: Rect,
    pub cancel: Rect,
}

pub struct PairingDialog {
    pub challenge: PairingChallenge,
    pub rect: Rect,
    pub approve: Rect,
    pub deny: Rect,
}

impl PairingDialog {
    fn new(challenge: PairingChallenge) -> Self {
        Self { challenge, rect: Rect::default(), approve: Rect::default(), deny: Rect::default() }
    }
}

#[derive(Debug, Clone)]
pub struct OmnibarState {
    pub pane: PaneId,
    pub surface: SurfaceId,
    pub input: TextInput,
    pub select_all: bool,
}

pub struct Toast {
    pub text: String,
    deadline: Instant,
}

#[derive(Debug, Clone, Copy)]
struct BrowserMouseDispatch {
    event_type: &'static str,
    button: Option<&'static str>,
    click_count: Option<u32>,
}

impl BrowserMouseDispatch {
    const fn new(
        event_type: &'static str,
        button: Option<&'static str>,
        click_count: Option<u32>,
    ) -> Self {
        Self { event_type, button, click_count }
    }
}

impl Prompt {
    fn new(label: &'static str, buffer: String, target: PromptTarget) -> Self {
        Prompt {
            label,
            input: TextInput::new(buffer),
            target,
            rect: Rect::default(),
            input_rect: Rect::default(),
            clear: Rect::default(),
            ok: Rect::default(),
            cancel: Rect::default(),
        }
    }
}

/// A text selection in one surface. Rows are absolute scrollback rows:
/// viewport row + scrollbar offset at capture time, so the selection
/// remains stable while the viewport scrolls.
#[derive(Debug, Clone, Copy)]
pub struct Selection {
    pub surface: SurfaceId,
    pub anchor: (u16, u64),
    pub head: (u16, u64),
}

impl Selection {
    /// Normalized (start, end) in row-major order, inclusive.
    pub fn range(&self) -> ((u16, u64), (u16, u64)) {
        let a = (self.anchor.1, self.anchor.0);
        let h = (self.head.1, self.head.0);
        if a <= h { (self.anchor, self.head) } else { (self.head, self.anchor) }
    }

    /// Whether a viewport cell is inside the (linear) selection at the
    /// current scrollbar offset.
    pub fn contains_viewport(&self, x: u16, y: u16, offset: u64) -> bool {
        let y = offset + y as u64;
        let ((sx, sy), (ex, ey)) = self.range();
        if y < sy || y > ey {
            return false;
        }
        if sy == ey {
            return x >= sx && x <= ex;
        }
        if y == sy {
            return x >= sx;
        }
        if y == ey {
            return x <= ex;
        }
        true
    }
}

#[derive(Debug, Clone, Copy)]
pub struct TabDragView {
    pub surface: SurfaceId,
    pub target: Option<(PaneId, usize)>,
}

/// Mouse drag in progress.
enum Drag {
    /// Left press on a tab chip; becomes `Tab` after moving cells.
    TabArm { surface: SurfaceId, at: (u16, u16) },
    /// Tab drag with the current drop target.
    Tab { surface: SurfaceId, target: Option<(PaneId, usize)> },
    /// Left press on a workspace entry; becomes `Workspace` after moving cells.
    WorkspaceArm { workspace: WorkspaceId, at: (u16, u16) },
    /// Workspace drag with the current insertion index.
    Workspace { workspace: WorkspaceId, target: Option<usize> },
    /// Text selection inside a pane's content rect.
    Select { content: Rect, auto_scroll: Option<i8>, col: u16 },
    /// Browser mouse drag inside a pane's content rect.
    Browser { surface: SurfaceId, content: Rect },
    /// Mouse reporting owned by the PTY application in this pane.
    PtyMouse {
        surface: SurfaceId,
        handle: Option<SurfaceHandle>,
        reservation_id: u64,
        release_bytes: PtyInputBytes,
        content: Rect,
        button: MouseButton,
        position: (u16, u16),
        modifiers: KeyModifiers,
    },
    /// Scrollbar thumb drag.
    Scrollbar { surface: SurfaceId, track: Rect, anchor_y: u16, anchor_offset: u64 },
    /// Sidebar width override drag.
    SidebarResize,
    /// Pane split resize drag.
    ResizeSplit { horizontal: Option<(PaneId, PaneEdge)>, vertical: Option<(PaneId, PaneEdge)> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PtyMousePressResult {
    NotOwned,
    Consumed,
    Started,
}

#[derive(Debug, Clone, Copy)]
struct PtyInputForwardResult {
    owned: bool,
    accepted: bool,
    reservation_id: Option<u64>,
}

enum PtyMouseReleaseCapture {
    Bytes(PtyInputBytes),
    NotReported,
    Failed,
}

#[derive(Clone)]
struct DeferredInput {
    event: Event,
    destination: Option<SurfaceId>,
    routing_intent: Option<u64>,
    sidebar_focus_intent: bool,
}

#[derive(Default)]
struct PaneFocusHistory {
    next_sequence: u64,
    recency: HashMap<PaneId, u64>,
    baseline: HashMap<PaneId, u64>,
    membership_revision: Option<u64>,
    membership_initialized: bool,
}

impl PaneFocusHistory {
    fn record(&mut self, pane: PaneId) {
        self.next_sequence = self.next_sequence.saturating_add(1);
        self.recency.insert(pane, self.next_sequence);
    }

    fn recency(&self, pane: PaneId) -> (bool, u64) {
        self.recency
            .get(&pane)
            .copied()
            .map(|sequence| (true, sequence))
            .unwrap_or_else(|| (false, self.baseline.get(&pane).copied().unwrap_or_default()))
    }

    fn reconcile_membership(&mut self, tree: &TreeView) {
        let live = tree
            .workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .map(|pane| pane.id)
            .collect::<HashSet<_>>();
        self.recency.retain(|pane, _| live.contains(pane));
        self.baseline.retain(|pane, _| live.contains(pane));
        for pane in tree
            .workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
        {
            self.baseline.entry(pane.id).or_insert(pane.focused_at);
        }
        self.membership_revision = tree.pane_revision;
        self.membership_initialized = true;
    }

    fn sync_membership(&mut self, tree: &TreeView) {
        if !self.membership_initialized
            || tree.pane_revision.is_some() && self.membership_revision != tree.pane_revision
        {
            self.reconcile_membership(tree);
        }
    }
}

pub struct App {
    pub session: OrderedSession,
    pub config: Config,
    pub chrome: ChromeTheme,
    pub tree: TreeView,
    tab_locations: HashMap<SurfaceId, [usize; 4]>,
    pub render_states: HashMap<SurfaceId, RenderState>,
    pub graphics_writer: Option<GraphicsWriter>,
    pub graphics_supported: bool,
    stdout_lock: Arc<Mutex<()>>,
    pub pane_areas: Vec<PaneArea>,
    pane_focus_history: PaneFocusHistory,
    /// Terminal cells actually represented by the last rendered snapshot.
    /// Foreign-viewer padding outside these bounds is display-only.
    pub(crate) rendered_terminal_bounds: HashMap<SurfaceId, Rect>,
    /// Surfaces whose active tabs were visible in the previous layout pass.
    /// Attach streams may outlive this set, but only members hold size leases.
    visible_size_surfaces: HashSet<SurfaceId>,
    /// Hidden leases stay owned until the server confirms their idempotent
    /// release. Failures clear this set so a later layout pass retries them.
    pending_size_releases: HashSet<SurfaceId>,
    pub prefix_armed: bool,
    pub session_label: String,
    pub sidebar_visible: bool,
    pub sidebar_focused: bool,
    pub sidebar_focus_pending: bool,
    pub sidebar_view: SidebarView,
    pub sidebar_files: FileBrowser,
    pub sidebar_workspace_selection: usize,
    sidebar_followed_surface: Option<SurfaceId>,
    /// Width of the sidebar in the current frame (0 when hidden).
    pub sidebar_width: u16,
    pub sidebar_plugin_surface: Option<SurfaceId>,
    pub sidebar_plugin_error: Option<String>,
    pub sidebar_plugin_retry_after_ms: Option<u64>,
    sidebar_plugin_retry_at: Option<Instant>,
    sidebar_width_override: Option<u16>,
    /// Pane region of the current frame (screen minus sidebar/status).
    pub content_area: Rect,
    /// Clickable regions of the current frame, rebuilt by the renderers.
    pub hits: Vec<(Rect, Hit)>,
    /// Per-pane tab-bar scroll offset (first visible tab index), for
    /// panes whose tabs overflow the bar. Presentation state only.
    pub tab_scroll: HashMap<PaneId, usize>,
    /// Last mouse position; tab-bar controls (+, ‹, ›) under it render
    /// a hover highlight.
    pub hover: Option<(u16, u16)>,
    pub menu: Option<ContextMenu>,
    pub clients: Vec<ClientInfo>,
    pub client_border_labels: HashMap<SurfaceId, String>,
    pub prompt: Option<Prompt>,
    pub pairing_dialog: Option<PairingDialog>,
    pairing_queue: VecDeque<PairingChallenge>,
    pub omnibar: Option<OmnibarState>,
    pub toast: Option<Toast>,
    pub(crate) shake_frames: u8,
    pub selection: Option<Selection>,
    pub status_message: Option<String>,
    pub cell_pixels: (u16, u16),
    /// Whether the terminal pointer is currently the hand shape (over a
    /// clickable element); tracked to avoid re-emitting OSC 22.
    pointer_shape: bool,
    last_browser_hover: Option<(SurfaceId, u16, u16)>,
    /// Off-loop forwarder for browser input: CDP/socket round trips must
    /// never run on the event-loop thread (see `browser_input`).
    browser_input: BrowserInputDispatcher,
    pty_input: PtyInputDispatcher,
    deferred_input: VecDeque<DeferredInput>,
    routing_refresh_pending: bool,
    routing_refresh_retries_remaining: u8,
    background_refresh_attempts: u8,
    background_refresh_retry_at: Option<Instant>,
    last_applied_refresh_sequence: u64,
    applied_routing_generation: u64,
    pending_session_completions: VecDeque<SessionCompletion>,
    mux_titles: Arc<MuxTitleIngress>,
    pty_failures: Arc<PtyFailureIngress>,
    mux_recovery_generation: Arc<AtomicU64>,
    drag: Option<Drag>,
    ignored_pty_mouse_buttons: HashSet<MouseButton>,
    encoder: KeyEncoder,
    encode_buf: Vec<u8>,
    quit: bool,
}

fn preserve_client_view(previous: &TreeView, next: &mut TreeView) {
    if let Some(active) = previous.active_workspace().map(|workspace| workspace.id)
        && let Some(index) = next.workspaces.iter().position(|workspace| workspace.id == active)
    {
        next.active_workspace = index;
    }

    for previous_workspace in &previous.workspaces {
        let Some(next_workspace) =
            next.workspaces.iter_mut().find(|workspace| workspace.id == previous_workspace.id)
        else {
            continue;
        };
        if let Some(active) =
            previous_workspace.screens.get(previous_workspace.active_screen).map(|screen| screen.id)
            && let Some(index) =
                next_workspace.screens.iter().position(|screen| screen.id == active)
        {
            next_workspace.active_screen = index;
        }

        for previous_screen in &previous_workspace.screens {
            let Some(next_screen) =
                next_workspace.screens.iter_mut().find(|screen| screen.id == previous_screen.id)
            else {
                continue;
            };
            if next_screen.panes.iter().any(|pane| pane.id == previous_screen.active_pane) {
                next_screen.active_pane = previous_screen.active_pane;
            }

            for previous_pane in &previous_screen.panes {
                let Some(next_pane) =
                    next_screen.panes.iter_mut().find(|pane| pane.id == previous_pane.id)
                else {
                    continue;
                };
                if let Some(active) = previous_pane.active_surface()
                    && let Some(index) = next_pane.tabs.iter().position(|tab| tab.surface == active)
                {
                    next_pane.active_tab = index;
                }
            }
        }
    }
}

/// Sidebar width for a terminal width: the configured width, hidden on
/// terminals too narrow to give panes room next to it.
fn sidebar_width_for(
    config: &Config,
    visible: bool,
    width: u16,
    override_width: Option<u16>,
) -> u16 {
    if !visible {
        return 0;
    }
    clamp_sidebar_width(config, width, override_width.unwrap_or(config.sidebar.width)).unwrap_or(0)
}

fn clamp_sidebar_width(config: &Config, terminal_width: u16, desired: u16) -> Option<u16> {
    let terminal_max = terminal_width.saturating_sub(40);
    let configured_max =
        if config.sidebar.max_width > 0 { config.sidebar.max_width } else { u16::MAX };
    let effective_max = terminal_max.min(configured_max);
    (effective_max >= 10).then_some(desired.clamp(10, effective_max))
}

fn sidebar_drag_width(config: &Config, content: Rect, sidebar_width: u16, x: u16) -> Option<u16> {
    let terminal_width = content.width.saturating_add(sidebar_width);
    clamp_sidebar_width(config, terminal_width, x.saturating_add(1))
}

fn content_size_for_rect(rect: Rect, scrollbar: ScrollbarPosition) -> Option<(u16, u16)> {
    let (_, _, content, _) = pane_parts_for_rect(rect, scrollbar, false);
    (content.width > 0 && content.height > 0).then_some((content.width, content.height))
}

fn browser_content_size_for_rect(rect: Rect, scrollbar: ScrollbarPosition) -> Option<(u16, u16)> {
    let (_, _, content, _) = pane_parts_for_rect(rect, scrollbar, true);
    (content.width > 0 && content.height > 0).then_some((content.width, content.height))
}

fn pane_parts_for_rect(
    rect: Rect,
    scrollbar: ScrollbarPosition,
    browser_omnibar: bool,
) -> (Option<Rect>, Option<Rect>, Rect, Option<Rect>) {
    let (bar, mut content, track) = if rect.width > 2 && rect.height > 2 {
        let reserved_cols = match scrollbar {
            ScrollbarPosition::Column => 3,
            ScrollbarPosition::Border => 2,
        };
        let right_border_x = rect.x + rect.width - 1;
        let track_x = match scrollbar {
            ScrollbarPosition::Column => right_border_x.saturating_sub(1),
            ScrollbarPosition::Border => right_border_x,
        };
        (
            Some(Rect { height: 1, ..rect }),
            Rect {
                x: rect.x + 1,
                y: rect.y + 1,
                width: rect.width.saturating_sub(reserved_cols).max(1),
                height: rect.height - 2,
            },
            Some(Rect { x: track_x, y: rect.y + 1, width: 1, height: rect.height - 2 }),
        )
    } else {
        (None, rect, None)
    };
    let omnibar = if browser_omnibar && content.height >= 2 {
        let row = Rect { height: 1, ..content };
        content.y = content.y.saturating_add(1);
        content.height = content.height.saturating_sub(1);
        Some(row)
    } else {
        None
    };
    (bar, omnibar, content, track)
}

fn stacked_header_parts_for_rect(rect: Rect) -> (Option<Rect>, Option<Rect>, Rect, Option<Rect>) {
    (Some(rect), None, Rect { y: rect.y.saturating_add(rect.height), height: 0, ..rect }, None)
}

pub fn run(
    session: Session,
    session_label: String,
    default_colors: cmux_tui_core::DefaultColors,
) -> anyhow::Result<()> {
    let mut config = crate::config::load();
    let chrome = ChromeTheme::for_defaults(config.chrome, default_colors);
    config.apply_chrome_defaults(chrome);
    // First workspace before the terminal switches modes, so a spawn
    // failure prints a normal error. Spawn at the size the first pane
    // will actually render at (a post-spawn resize makes shells like zsh
    // repaint their prompt, leaving a reverse-video % artifact). The
    // pane's border box eats one cell on every side.
    let initial_size = crossterm::terminal::size().ok().map(|(w, h)| {
        let sidebar = sidebar_width_for(&config, true, w, None);
        let pane = Rect {
            x: sidebar,
            y: 0,
            width: w.saturating_sub(sidebar),
            height: h.saturating_sub(1), // status bar
        };
        content_size_for_rect(pane, config.scrollbar.position).unwrap_or((1, 1))
    });
    session.ensure_initial(initial_size)?;
    let encoder = KeyEncoder::new()?;
    let (tx, rx) = sync_channel::<AppEvent>(APP_EVENT_CAPACITY);
    let browser_failure_tx = tx.clone();
    let browser_control_tx = tx.clone();
    let browser_input = BrowserInputDispatcher::spawn(
        move |failure| {
            let _ = browser_failure_tx.send(AppEvent::BrowserResizeFailed(failure));
        },
        move |message| {
            let _ = browser_control_tx.send(AppEvent::Mux(MuxEvent::Status(message)));
        },
    )?;
    let failure_tx = tx.clone();
    let pty_failures = Arc::new(PtyFailureIngress::default());
    let failure_ingress = pty_failures.clone();
    let pty_input = PtyInputDispatcher::spawn(move |failure| {
        if failure_ingress.push(failure) {
            // This is a latency hint, not the ownership path. The event loop
            // drains the ingress after every batch and timeout, including
            // when this bounded app channel is currently full.
            let _ = failure_tx.try_send(AppEvent::PtyFailuresReady);
        }
    })?;
    let session = OrderedSession::new(session, pty_input.sender(), tx.clone());
    let stdout_lock = Arc::new(Mutex::new(()));
    let mux_titles = Arc::new(MuxTitleIngress::default());
    let mux_recovery_generation = Arc::new(AtomicU64::new(0));

    // Session events → app channel.
    let event_source = session.inner.clone();
    let session_events = event_source.events();
    let routing_mutation_committed = session.routing_mutation_committed.clone();
    let mux_recovery_sequence = mux_recovery_generation.clone();
    std::thread::Builder::new().name("mux-events".into()).spawn({
        let tx = tx.clone();
        let mux_titles = mux_titles.clone();
        move || {
            forward_mux_events(
                event_source,
                session_events,
                routing_mutation_committed,
                mux_recovery_sequence,
                tx,
                mux_titles,
            );
        }
    })?;

    // Crossterm input → app channel.
    enable_raw_mode()?;
    if let Err(e) = (|| -> anyhow::Result<()> {
        let _guard = stdout_lock.lock().unwrap();
        let mut stdout = std::io::stdout();
        stdout.execute(EnterAlternateScreen)?;
        stdout.execute(EnableMouseCapture)?;
        // Ask the host terminal to report Shift-modified mouse events so
        // Shift remains cmux's selection/context-menu escape while the inner
        // application owns ordinary mouse input.
        write!(stdout, "\x1b[>1s")?;
        stdout.execute(EnableFocusChange)?;
        stdout.execute(EnableBracketedPaste)?;
        Ok(())
    })() {
        let _ = restore_terminal(Some(&stdout_lock));
        return Err(e);
    }

    let cell_pixels = crate::ui::graphics::detect_cell_pixels(true);
    session.set_cell_pixel_size(cell_pixels.0, cell_pixels.1);
    let graphics_supported = crate::ui::graphics::probe_kitty_graphics();

    // Crossterm input → app channel. Start this after startup terminal
    // probes so DA / window-size responses are not consumed as key input.
    std::thread::Builder::new().name("input".into()).spawn({
        move || {
            while let Ok(event) = crossterm::event::read() {
                if tx.send(AppEvent::Input(event)).is_err() {
                    break;
                }
            }
        }
    })?;
    // Restore the host terminal even if we panic mid-frame.
    let default_hook = std::panic::take_hook();
    let restore_lock = stdout_lock.clone();
    std::panic::set_hook(Box::new(move |info| {
        let _ = restore_terminal(Some(&restore_lock));
        default_hook(info);
    }));

    let backend = CrosstermBackend::new(std::io::stdout());
    let mut terminal = match RatatuiTerminal::new(backend) {
        Ok(terminal) => terminal,
        Err(e) => {
            let _ = restore_terminal(Some(&stdout_lock));
            return Err(e.into());
        }
    };
    let graphics_writer =
        if graphics_supported { Some(GraphicsWriter::spawn(stdout_lock.clone())?) } else { None };

    let sidebar_view = config.sidebar.view;
    let fallback_cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let mut app = App {
        session,
        config,
        chrome,
        tree: TreeView::default(),
        tab_locations: HashMap::new(),
        render_states: HashMap::new(),
        graphics_writer,
        graphics_supported,
        stdout_lock: stdout_lock.clone(),
        pane_areas: Vec::new(),
        pane_focus_history: PaneFocusHistory::default(),
        rendered_terminal_bounds: HashMap::new(),
        visible_size_surfaces: HashSet::new(),
        pending_size_releases: HashSet::new(),
        prefix_armed: false,
        session_label,
        sidebar_visible: true,
        sidebar_focused: false,
        sidebar_focus_pending: false,
        sidebar_view,
        sidebar_files: FileBrowser::new(fallback_cwd),
        sidebar_workspace_selection: 0,
        sidebar_followed_surface: None,
        sidebar_width: 0,
        sidebar_plugin_surface: None,
        sidebar_plugin_error: None,
        sidebar_plugin_retry_after_ms: None,
        sidebar_plugin_retry_at: None,
        sidebar_width_override: None,
        content_area: Rect::default(),
        hits: Vec::new(),
        tab_scroll: HashMap::new(),
        hover: None,
        menu: None,
        clients: Vec::new(),
        client_border_labels: HashMap::new(),
        prompt: None,
        pairing_dialog: None,
        pairing_queue: VecDeque::new(),
        omnibar: None,
        toast: None,
        shake_frames: 0,
        selection: None,
        status_message: None,
        cell_pixels,
        pointer_shape: false,
        last_browser_hover: None,
        browser_input,
        pty_input,
        deferred_input: VecDeque::new(),
        routing_refresh_pending: false,
        routing_refresh_retries_remaining: 0,
        background_refresh_attempts: 0,
        background_refresh_retry_at: None,
        last_applied_refresh_sequence: 0,
        applied_routing_generation: 0,
        pending_session_completions: VecDeque::new(),
        mux_titles,
        pty_failures,
        mux_recovery_generation,
        drag: None,
        ignored_pty_mouse_buttons: HashSet::new(),
        encoder,
        encode_buf: Vec::with_capacity(64),
        quit: false,
    };
    app.session.refresh_clients_background();

    let result = app.event_loop(&mut terminal, rx);
    app.cancel_pty_mouse_drag();
    app.session.begin_shutdown();
    let _ = app.pty_input.shutdown(Duration::from_secs(3));
    if let Some(writer) = app.graphics_writer.as_mut() {
        writer.shutdown(Duration::from_millis(200));
    }
    let _ = std::panic::take_hook();
    restore_terminal(Some(&stdout_lock))?;
    result
}

fn restore_terminal(stdout_lock: Option<&Arc<Mutex<()>>>) -> anyhow::Result<()> {
    let _guard = stdout_lock.map(|lock| lock.lock().unwrap());
    let mut stdout = std::io::stdout();
    // Reset the mouse pointer shape in case we left it as a hand.
    let _ = write!(stdout, "\x1b]22;default\x07");
    // Restore the conventional host behavior where Shift bypasses capture.
    let _ = write!(stdout, "\x1b[>0s");
    let _ = stdout.execute(DisableBracketedPaste);
    let _ = stdout.execute(DisableFocusChange);
    let _ = stdout.execute(DisableMouseCapture);
    let _ = stdout.execute(LeaveAlternateScreen);
    disable_raw_mode()?;
    Ok(())
}

impl App {
    fn event_loop(
        &mut self,
        terminal: &mut RatatuiTerminal<CrosstermBackend<std::io::Stdout>>,
        rx: Receiver<AppEvent>,
    ) -> anyhow::Result<()> {
        // Initial layout + draw.
        let size = terminal.size()?;
        self.sync_layout((size.width, size.height));
        self.draw_terminal(terminal)?;
        self.emit_graphics()?;

        while !self.quit && !crate::shutdown_requested() {
            // Block for the first event, then drain whatever queued so a
            // torrent of pty output coalesces into one frame.
            let timeout = if self.shake_frames > 0
                || self.selection_auto_scroll_active()
                || self.toast.is_some()
            {
                Duration::from_millis(30)
            } else {
                Duration::from_millis(250)
            };
            let mut action = RenderAction::None;
            let first = match rx.recv_timeout(timeout) {
                Ok(event) => Some(event),
                Err(RecvTimeoutError::Timeout) => {
                    if self.shake_frames > 0 {
                        action = RenderAction::Draw;
                    }
                    if self.auto_scroll_selection_tick() {
                        action = action.merge(RenderAction::Draw);
                    }
                    if self.expire_toast() {
                        action = action.merge(RenderAction::Draw);
                    }
                    if self.tick_sidebar_files() {
                        action = action.merge(RenderAction::Draw);
                    }
                    None
                }
                Err(RecvTimeoutError::Disconnected) => break,
            };
            if let Some(event) = first {
                action = action.merge(self.handle(event)?);
            }
            for _ in 0..256 {
                match rx.try_recv() {
                    Ok(event) => action = action.merge(self.handle(event)?),
                    Err(_) => break,
                }
            }
            // Always drain retained failures. PtyFailuresReady only shortens
            // the idle wait, so a failed try_send cannot create a lost wakeup.
            action = action.merge(self.apply_pty_failures());
            if self.session.take_cancellation_pending() {
                if self.session.has_pending_mutations() {
                    self.session.defer_cancellation();
                } else {
                    self.apply_session_cancellation();
                    action = action.merge(RenderAction::Draw);
                }
            }
            if self.quit {
                break;
            }
            if self.expire_toast() {
                action = action.merge(RenderAction::Draw);
            }
            self.retry_deferred_surface_attach();
            if self.browser_input.resize_retry_due() {
                let mut visible_surfaces =
                    self.pane_areas.iter().map(|area| area.surface).collect::<HashSet<_>>();
                if let Some(surface) = self.sidebar_plugin_surface {
                    visible_surfaces.insert(surface);
                }
                if self.browser_input.visible_resize_retry_due(&visible_surfaces) {
                    self.reassert_visible_surface_sizes();
                }
            }
            if self.session.surface_resize_retry_due() {
                self.reassert_visible_surface_sizes();
            }
            self.retry_sidebar_plugin_if_due();
            self.retry_background_refresh_if_due();
            if self.session.surface_overflow_retry_due() {
                action = action.merge(RenderAction::Draw);
            }
            self.render_action(terminal, action)?;
            if self.routing_refresh_pending {
                self.routing_refresh_pending = false;
                let replay = self.replay_deferred_input()?;
                self.render_action(terminal, replay)?;
            }
        }
        Ok(())
    }

    fn render_action(
        &mut self,
        terminal: &mut RatatuiTerminal<CrosstermBackend<std::io::Stdout>>,
        action: RenderAction,
    ) -> anyhow::Result<()> {
        match action {
            RenderAction::Draw => {
                let size = terminal.size()?;
                self.sync_layout((size.width, size.height));
                self.draw_terminal(terminal)?;
                self.emit_graphics()?;
            }
            RenderAction::Paint => {
                self.draw_terminal(terminal)?;
                self.emit_graphics()?;
            }
            RenderAction::Graphics => self.emit_graphics()?,
            RenderAction::None => {}
        }
        Ok(())
    }

    fn replay_deferred_input(&mut self) -> anyhow::Result<RenderAction> {
        let mut action = RenderAction::None;
        // A replayed event can discover that its destination mirror is still
        // unavailable and append itself again. Only process the queue snapshot
        // that existed at entry so a blocked attach cannot spin this frame.
        let replay_count = self.deferred_input.len();
        for _ in 0..replay_count {
            if self.session.has_pending_mutations() || self.session.remote_tree_is_stale() {
                break;
            }
            let Some(input) = self.deferred_input.pop_front() else { break };
            let follows_pending_route = matches!(&input.event, Event::Key(_) | Event::Paste(_))
                && input.routing_intent.is_some_and(|intent| {
                    self.session.routing_mutation_committed() >= intent
                        && self.session.routing_mutation_started() == intent
                });
            let follows_sidebar_focus = input.sidebar_focus_intent && self.sidebar_focused;
            if !follows_pending_route
                && !follows_sidebar_focus
                && self.input_destination(&input.event) != input.destination
            {
                self.status_message = Some(
                    "Deferred input was discarded because its destination changed".to_string(),
                );
                action = action.merge(RenderAction::Draw);
                continue;
            }
            action = action.merge(self.handle(AppEvent::Input(input.event))?);
        }
        Ok(action)
    }

    fn apply_session_completion(&mut self, completion: SessionCompletion) {
        match completion.action {
            SessionCompletionAction::SurfaceCreated { surface } => {
                self.select_created_surface(surface);
            }
            SessionCompletionAction::BrowserTabCreated { surface } => {
                self.select_created_surface(surface);
                let pane = self
                    .tab_locations
                    .get(&surface)
                    .and_then(|[workspace, screen, pane, _]| {
                        self.tree
                            .workspaces
                            .get(*workspace)
                            .and_then(|workspace| workspace.screens.get(*screen))
                            .and_then(|screen| screen.panes.get(*pane))
                    })
                    .filter(|pane| {
                        pane.active_surface() == Some(surface)
                            && pane
                                .tabs
                                .get(pane.active_tab)
                                .is_some_and(|tab| tab.kind == SurfaceKind::Browser)
                    })
                    .map(|pane| pane.id);
                if let Some(pane) = pane {
                    self.focus_omnibar_with_buffer(pane, String::new(), false);
                }
            }
        }
    }

    fn select_created_surface(&mut self, surface: SurfaceId) {
        let Some([workspace_index, screen_index, pane_index, tab_index]) =
            self.tab_locations.get(&surface).copied()
        else {
            return;
        };
        self.tree.active_workspace = workspace_index;
        let Some(workspace) = self.tree.workspaces.get_mut(workspace_index) else { return };
        workspace.active_screen = screen_index;
        let Some(screen) = workspace.screens.get_mut(screen_index) else { return };
        let Some(pane_id) = screen.panes.get(pane_index).map(|pane| pane.id) else { return };
        screen.active_pane = pane_id;
        if let Some(pane) = screen.panes.get_mut(pane_index) {
            pane.active_tab = tab_index;
        }
        self.pane_focus_history.record(pane_id);
    }

    fn apply_session_cancellation(&mut self) {
        self.deferred_input.clear();
        self.prefix_armed = false;
        self.pending_session_completions.clear();
        self.pending_size_releases.clear();
        self.status_message = Some("session operation was canceled".to_string());
    }

    fn apply_pty_failures(&mut self) -> RenderAction {
        let failures = self.pty_failures.take();
        let mut action = RenderAction::None;
        for failure in failures {
            action = action.merge(self.apply_pty_operation_failure(failure));
        }
        action
    }

    fn apply_pty_operation_failure(&mut self, failure: PtyOperationFailure) -> RenderAction {
        if failure.label == "relaunch sidebar plugin" {
            self.sidebar_focus_pending = false;
        }
        if failure.kind == Some(PtyInputKind::Motion)
            && failure.delivery == PtyOperationDelivery::KnownNotDelivered
            && let Some(surface) = failure.surface_id.and_then(|id| self.session.surface(id))
        {
            surface.reset_mouse_motion_dedupe();
        }
        let failed_active_press = failure.kind == Some(PtyInputKind::Press)
            && failure.delivery == PtyOperationDelivery::KnownNotDelivered
            && failure.surface_id.zip(failure.reservation_id).is_some_and(
                |(surface, reservation_id)| {
                    matches!(&self.drag, Some(Drag::PtyMouse { surface: active_surface, reservation_id: active_reservation, .. }) if *active_surface == surface && *active_reservation == reservation_id)
                },
            );
        if failed_active_press || failure.lane_failed {
            self.drag = None;
        }
        self.status_message = Some(
            if failure.label == "attach surface"
                && failure.delivery == PtyOperationDelivery::Ambiguous
            {
                format!(
                    "surface attach outcome is unknown; detach and reconnect before sending more input: {}",
                    failure.error
                )
            } else {
                format!("{} failed: {}", failure.label, failure.error)
            },
        );
        RenderAction::Draw
    }

    fn apply_mux_titles(&mut self) -> bool {
        let titles = self.mux_titles.take_dirty();
        self.apply_mux_title_snapshot(titles)
    }

    fn reapply_mux_titles(&mut self) -> bool {
        let titles = self.mux_titles.snapshot();
        self.apply_mux_title_snapshot(titles)
    }

    fn apply_mux_title_snapshot(&mut self, titles: HashMap<SurfaceId, Arc<str>>) -> bool {
        if titles.is_empty() {
            return false;
        }
        let mut changed = false;
        for (surface, title) in titles {
            let Some([workspace, screen, pane, tab]) = self.tab_locations.get(&surface).copied()
            else {
                continue;
            };
            let Some(tab) = self
                .tree
                .workspaces
                .get_mut(workspace)
                .and_then(|workspace| workspace.screens.get_mut(screen))
                .and_then(|screen| screen.panes.get_mut(pane))
                .and_then(|pane| pane.tabs.get_mut(tab))
            else {
                continue;
            };
            if tab.title.as_str() != title.as_ref() {
                tab.title = title.to_string();
                changed = true;
            }
        }
        changed
    }

    fn replace_tree(&mut self, mut tree: TreeView) {
        let previous_active = self.active_pane();
        if self.session.remote {
            preserve_client_view(&self.tree, &mut tree);
        }
        let live_browsers = tree
            .workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .filter(|tab| tab.kind == SurfaceKind::Browser)
            .map(|tab| tab.surface)
            .collect::<HashSet<_>>();
        let removed_browsers = self
            .tree
            .workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .filter(|tab| tab.kind == SurfaceKind::Browser)
            .map(|tab| tab.surface)
            .filter(|surface| !live_browsers.contains(surface))
            .collect::<Vec<_>>();
        for surface in removed_browsers {
            self.browser_input.forget_surface(surface);
        }
        self.pane_focus_history.sync_membership(&tree);
        self.tree = tree;
        if self.active_pane() != previous_active
            && let Some(active) = self.active_pane()
        {
            self.pane_focus_history.record(active);
        }
        self.rebuild_tab_locations();
        self.reapply_mux_titles();
    }

    fn replace_authoritative_tree(&mut self, tree: TreeView, routing_generation: u64) {
        if tree.pane_revision.is_none() {
            self.pane_focus_history.reconcile_membership(&tree);
        } else {
            self.pane_focus_history.sync_membership(&tree);
        }
        let live_surfaces = tree
            .workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .map(|tab| tab.surface)
            .collect::<HashSet<_>>();
        let removed_surfaces = self
            .tab_locations
            .keys()
            .copied()
            .filter(|surface| !live_surfaces.contains(surface))
            .collect::<Vec<_>>();
        for surface in removed_surfaces {
            self.retire_surface_state(surface);
        }
        self.replace_tree(tree);
        self.session.reconcile_exited_surfaces(&self.tree);
        self.applied_routing_generation = self.applied_routing_generation.max(routing_generation);
    }

    fn retire_surface_state(&mut self, surface: SurfaceId) {
        if matches!(&self.drag, Some(Drag::PtyMouse { surface: active, .. }) if *active == surface)
        {
            self.cancel_pty_release_reservation();
            self.drag = None;
        }
        self.render_states.remove(&surface);
        self.visible_size_surfaces.remove(&surface);
        self.pending_size_releases.remove(&surface);
        self.mux_titles.remove(surface);
        self.session.forget_surface(surface);
        if self.sidebar_plugin_surface == Some(surface) {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error = Some("sidebar plugin exited".to_string());
            if self.config.sidebar.plugin.is_some() {
                self.sidebar_focused = false;
            }
        }
        if self.selection.is_some_and(|selection| selection.surface == surface) {
            self.selection = None;
        }
        if self.omnibar.as_ref().is_some_and(|state| state.surface == surface) {
            self.omnibar = None;
        }
        if self.last_browser_hover.is_some_and(|(hovered, _, _)| hovered == surface) {
            self.last_browser_hover = None;
        }
        self.browser_input.forget_surface(surface);
    }

    fn rebuild_tab_locations(&mut self) {
        self.tab_locations.clear();
        for (workspace_index, workspace) in self.tree.workspaces.iter().enumerate() {
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                for (pane_index, pane) in screen.panes.iter().enumerate() {
                    for (tab_index, tab) in pane.tabs.iter().enumerate() {
                        self.tab_locations.insert(
                            tab.surface,
                            [workspace_index, screen_index, pane_index, tab_index],
                        );
                    }
                }
            }
        }
    }

    fn remove_surface_from_tree(&mut self, surface: SurfaceId) {
        for workspace in &mut self.tree.workspaces {
            for screen in &mut workspace.screens {
                for pane in &mut screen.panes {
                    let Some(index) = pane.tabs.iter().position(|tab| tab.surface == surface)
                    else {
                        continue;
                    };
                    pane.tabs.remove(index);
                    if pane.active_tab > index {
                        pane.active_tab -= 1;
                    } else if pane.active_tab >= pane.tabs.len() {
                        pane.active_tab = pane.tabs.len().saturating_sub(1);
                    }
                }
            }
        }
        self.rebuild_tab_locations();
    }

    fn apply_session_completions_through(&mut self, authoritative_generation: u64) {
        while self
            .pending_session_completions
            .front()
            .is_some_and(|completion| completion.mutation_generation <= authoritative_generation)
        {
            let completion = self.pending_session_completions.pop_front().unwrap();
            self.apply_session_completion(completion);
        }
    }

    fn complete_remote_tree_refresh(&self, refresh_stale: bool) {
        let background_dirty = self.session.take_background_refresh_dirty();
        if self.session.remote_tree_is_stale() {
            if refresh_stale || background_dirty {
                self.session.refresh_remote_tree_if_stale();
            }
        } else if background_dirty {
            self.session.refresh_remote_tree_background();
        }
    }

    fn accept_refresh_sequence(&mut self, refresh_sequence: u64) -> bool {
        if refresh_sequence <= self.last_applied_refresh_sequence {
            return false;
        }
        self.last_applied_refresh_sequence = refresh_sequence;
        true
    }

    fn complete_routing_after_stale_identity_result(&mut self) {
        if !self.session.has_pending_mutations()
            && !self.session.remote_tree_is_stale()
            && !self.deferred_input.is_empty()
        {
            self.routing_refresh_pending = true;
        }
    }

    fn schedule_background_refresh_retry(&mut self) -> bool {
        if self.background_refresh_attempts >= BACKGROUND_REFRESH_RETRIES {
            self.background_refresh_retry_at = None;
            return false;
        }
        self.background_refresh_attempts += 1;
        let delay_seconds = 1_u64 << u32::from(self.background_refresh_attempts.saturating_sub(1));
        self.background_refresh_retry_at =
            Some(Instant::now() + Duration::from_secs(delay_seconds.min(30)));
        true
    }

    fn retry_background_refresh_if_due(&mut self) {
        if self.background_refresh_retry_at.is_some_and(|retry_at| Instant::now() >= retry_at) {
            self.background_refresh_retry_at = None;
            self.session.refresh_remote_tree_background();
        }
    }

    fn draw_terminal(
        &mut self,
        terminal: &mut RatatuiTerminal<CrosstermBackend<std::io::Stdout>>,
    ) -> anyhow::Result<()> {
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock().unwrap();
        terminal.draw(|f| crate::ui::draw(self, f))?;
        Ok(())
    }

    fn frame_only_browser_update(&self, id: SurfaceId) -> bool {
        if !self.graphics_supported {
            return false;
        }
        let Some(area) = self.pane_areas.iter().find(|area| area.surface == id) else {
            return false;
        };
        let Some(surface) = self.session.surface(id) else {
            return false;
        };
        surface.kind() == SurfaceKind::Browser
            && surface.browser_frame().is_some()
            && area.content.width > 0
            && area.content.height > 0
    }

    fn mark_graphics_clean(&self, placements: &[GraphicPlacement]) {
        for placement in placements {
            if let Some(surface) = self.session.surface(placement.surface) {
                surface.take_dirty();
            }
        }
    }

    fn emit_graphics(&mut self) -> anyhow::Result<()> {
        if !self.graphics_supported {
            return Ok(());
        }
        let placements = self.graphic_placements();
        self.mark_graphics_clean(&placements);
        if let Some(writer) = &self.graphics_writer {
            writer.submit(placements);
        }
        Ok(())
    }

    fn graphic_placements(&self) -> Vec<GraphicPlacement> {
        let mut placements = Vec::new();
        for area in &self.pane_areas {
            let Some(surface) = self.session.surface(area.surface) else { continue };
            if surface.kind() != SurfaceKind::Browser {
                continue;
            }
            if area.content.width == 0 || area.content.height == 0 {
                continue;
            }
            if self.browser_graphic_occluded(area.content) {
                continue;
            }
            let Some(frame) = surface.browser_frame() else { continue };
            placements.push(GraphicPlacement {
                surface: area.surface,
                rect: area.content,
                seq: frame.seq,
                data_b64: frame.data_b64,
            });
        }
        placements
    }

    fn browser_graphic_occluded(&self, rect: Rect) -> bool {
        self.menu.as_ref().is_some_and(|menu| menu.intersects(rect))
            || self.prompt.as_ref().is_some_and(|prompt| rects_intersect(rect, prompt.rect))
    }

    fn refresh_cell_pixels(&mut self, query_fallback: bool) {
        let next = crate::ui::graphics::detect_cell_pixels(query_fallback);
        if self.cell_pixels != next {
            if !self.prepare_pty_input_before_mutation() {
                return;
            }
            self.cell_pixels = next;
            self.browser_input.clear_resize_failures();
            self.session.set_cell_pixel_size(next.0, next.1);
        }
    }

    fn reload_config(&mut self) {
        let mut config = crate::config::load();
        config.apply_chrome_defaults(self.chrome);
        self.sidebar_plugin_error = None;
        self.sidebar_plugin_retry_after_ms = None;
        self.sidebar_plugin_retry_at = None;
        self.session.apply_config(config.clone());
        self.sidebar_view = config.sidebar.view;
        self.config = config;
        self.sidebar_followed_surface = None;
    }

    fn focused_surface_cwd(&self) -> Option<PathBuf> {
        let surface = self.tree.active_surface()?;
        self.session.surface_cwd(surface).map(PathBuf::from)
    }

    fn sync_sidebar_files_to_focus(&mut self, force: bool) -> bool {
        if self.config.sidebar.plugin.is_some()
            || self.sidebar_view != SidebarView::Files
            || self.sidebar_files.is_pinned()
        {
            return false;
        }
        let focused = self.tree.active_surface();
        if !force && focused == self.sidebar_followed_surface {
            return false;
        }
        self.sidebar_followed_surface = focused;
        let Some(cwd) = self.focused_surface_cwd() else { return false };
        self.sidebar_files.follow_focused_cwd(&cwd)
    }

    fn tick_sidebar_files(&mut self) -> bool {
        if self.config.sidebar.plugin.is_some()
            || self.sidebar_view != SidebarView::Files
            || !self.sidebar_visible
        {
            return false;
        }
        // The cwd follow can be a synchronous socket round-trip for remote
        // sessions; the event loop ticks up to ~33x/sec, so gate it behind the
        // same 2s refresh cadence as the directory reload.
        let now = Instant::now();
        let mut changed = false;
        if self.sidebar_files.refresh_due(now)
            && !self.sidebar_files.is_pinned()
            && let Some(cwd) = self.focused_surface_cwd()
        {
            changed |= self.sidebar_files.follow_focused_cwd(&cwd);
        }
        changed | self.sidebar_files.tick(now)
    }

    fn write_window_title(&self, title: &str) -> anyhow::Result<()> {
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock().unwrap();
        let mut stdout = std::io::stdout();
        stdout.write_all(&cmux_tui_core::server::window_title_osc(title))?;
        stdout.flush()?;
        Ok(())
    }

    /// Refresh the tree snapshot, recompute the active screen's layout
    /// (each pane's border box eats one cell on every side), and push
    /// content sizes to surfaces.
    fn sync_layout(&mut self, size: (u16, u16)) {
        let (width, height) = size;
        self.sidebar_width = sidebar_width_for(
            &self.config,
            self.sidebar_visible,
            width,
            self.sidebar_width_override,
        );
        if self.sidebar_width == 0 {
            self.sidebar_focused = false;
        }
        let area = Rect {
            x: self.sidebar_width,
            y: 0,
            width: width.saturating_sub(self.sidebar_width),
            height: height.saturating_sub(1), // status bar
        };
        self.content_area = area;
        let _ = self.sync_sidebar_plugin(false);
        self.replace_tree(self.session.tree());
        self.sidebar_workspace_selection =
            self.sidebar_workspace_selection.min(self.tree.workspaces.len().saturating_sub(1));
        self.sync_sidebar_files_to_focus(false);
        let layout = self
            .tree
            .active_screen()
            .map(|screen| {
                if let Some(pane) = screen.zoomed_pane {
                    layout_screen(&cmux_tui_core::Node::Leaf(pane), area, Some(pane))
                } else {
                    layout_screen(&screen.layout, area, Some(screen.active_pane))
                }
            })
            .unwrap_or_default();

        self.pane_areas.clear();
        let Some(screen) = self.tree.active_screen().cloned() else {
            let hidden = self
                .visible_size_surfaces
                .difference(&self.pending_size_releases)
                .copied()
                .collect::<Vec<_>>();
            if hidden.is_empty() || self.prepare_pty_input_before_mutation() {
                for surface in hidden {
                    if self.session.release_surface_size(surface) {
                        self.pending_size_releases.insert(surface);
                    }
                }
            }
            return;
        };
        let stacked_headers = layout.stacked_headers;
        for (pane_id, rect) in layout.panes {
            let Some(pane) = screen.pane(pane_id) else { continue };
            let Some(surface_id) = pane.active_surface() else { continue };
            let has_browser_omnibar =
                pane.tabs.get(pane.active_tab).is_some_and(|tab| tab.kind == SurfaceKind::Browser);
            let (bar, omnibar, content, track) = if stacked_headers.contains(&pane_id) {
                stacked_header_parts_for_rect(rect)
            } else {
                pane_parts_for_rect(rect, self.config.scrollbar.position, has_browser_omnibar)
            };
            self.pane_areas.push(PaneArea {
                pane: pane_id,
                surface: surface_id,
                rect,
                bar,
                omnibar,
                content,
                track,
            });
        }

        let visible = self
            .pane_areas
            .iter()
            .filter(|area| area.content.width > 0 && area.content.height > 0)
            .map(|area| area.surface)
            .collect::<HashSet<_>>();
        let hidden = self
            .visible_size_surfaces
            .difference(&visible)
            .filter(|surface| !self.pending_size_releases.contains(surface))
            .copied()
            .collect::<Vec<_>>();
        if !hidden.is_empty() && !self.prepare_pty_input_before_mutation() {
            return;
        }
        for surface in hidden {
            if self.session.release_surface_size(surface) {
                self.pending_size_releases.insert(surface);
            }
        }
        let newly_visible =
            visible.difference(&self.visible_size_surfaces).copied().collect::<HashSet<_>>();
        self.visible_size_surfaces.extend(visible);

        // Keep inactive tabs attached for instant rendering, but give only
        // each pane's active tab a sizing lease. This makes visibility, not
        // cached transport state, the shared-size ownership boundary.
        for index in 0..self.pane_areas.len() {
            let area = self.pane_areas[index];
            if area.content.width == 0 || area.content.height == 0 {
                continue;
            }
            let Some(pane) = screen.pane(area.pane) else { continue };
            for tab in &pane.tabs {
                if self.session.has_surface(tab.surface) {
                    continue;
                }
                let size = (tab.surface == area.surface)
                    .then_some((area.content.width, area.content.height))
                    .filter(|(cols, rows)| *cols > 0 && *rows > 0);
                if self.session.can_attach_surface(tab.surface)
                    && self.prepare_pty_input_before_mutation()
                {
                    self.session.attach_surface(tab.surface, size);
                }
            }
            let Some(surface) = self.session.surface(area.surface) else { continue };
            let desired = (area.content.width, area.content.height);
            if surface.kind() == SurfaceKind::Browser
                && self.browser_input.resize_failed(area.surface, desired)
            {
                continue;
            }
            let needs = newly_visible.contains(&area.surface)
                || !self.session.has_surface_size_report(area.surface)
                || surface.resize_needed(area.content.width, area.content.height, false);
            if let SurfaceResizeDecision::NeedsQueue(claim) =
                self.session.surface_resize_decision(area.surface, desired, needs)
                && self.prepare_pty_input_before_mutation()
            {
                self.enqueue_surface_resize(
                    area.surface,
                    surface,
                    area.content.width,
                    area.content.height,
                    false,
                    Some(claim),
                );
            }
        }
    }

    pub fn sidebar_plugin_rect(&self) -> Rect {
        Rect {
            x: 0,
            y: 0,
            width: self.sidebar_width.saturating_sub(1),
            height: self.content_area.height.saturating_add(1),
        }
    }

    fn sync_sidebar_plugin(&mut self, relaunch: bool) -> bool {
        if self.config.sidebar.plugin.is_none() {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error = None;
            self.sidebar_plugin_retry_after_ms = None;
            self.sidebar_plugin_retry_at = None;
            self.sidebar_focus_pending = false;
            return false;
        }
        if self.sidebar_width < 3 || !self.sidebar_visible {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error = None;
            self.sidebar_plugin_retry_after_ms = None;
            self.sidebar_plugin_retry_at = None;
            self.sidebar_focused = false;
            self.sidebar_focus_pending = false;
            return false;
        }
        let rect = self.sidebar_plugin_rect();
        if rect.width == 0 || rect.height == 0 {
            return false;
        }
        let terminal_failure =
            self.sidebar_plugin_error.is_some() && self.sidebar_plugin_retry_after_ms.is_none();
        if !relaunch && (self.sidebar_plugin_retry_at.is_some() || terminal_failure) {
            return false;
        }
        if relaunch && !self.prepare_pty_input_before_mutation() {
            return false;
        }
        self.session.sidebar_plugin((rect.width, rect.height), relaunch);
        true
    }

    fn retry_sidebar_plugin_if_due(&mut self) {
        if self.sidebar_plugin_retry_at.is_none_or(|retry_at| Instant::now() < retry_at) {
            return;
        }
        if matches!(self.drag, Some(Drag::PtyMouse { .. })) {
            self.sidebar_plugin_retry_at = Some(Instant::now() + Duration::from_millis(250));
            return;
        }
        self.sidebar_plugin_retry_at = None;
        self.sidebar_plugin_retry_after_ms = None;
        if !self.sync_sidebar_plugin(true) {
            self.sidebar_plugin_retry_at = Some(Instant::now() + Duration::from_millis(250));
        }
    }

    fn apply_sidebar_plugin_status(&mut self, status: SidebarPluginSurface, relaunch: bool) {
        if self.config.sidebar.plugin.is_none() {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error = None;
            self.sidebar_plugin_retry_after_ms = None;
            self.sidebar_plugin_retry_at = None;
            self.sidebar_focus_pending = false;
            return;
        }
        if !self.sidebar_visible {
            self.session.invalidate_sidebar_plugin_sync();
            self.sidebar_plugin_surface = None;
            self.sidebar_plugin_error = None;
            self.sidebar_plugin_retry_after_ms = None;
            self.sidebar_plugin_retry_at = None;
            self.sidebar_focused = false;
            self.sidebar_focus_pending = false;
            return;
        }
        let had_surface = self.sidebar_plugin_surface.is_some();
        self.sidebar_plugin_surface = status.surface_id;
        self.sidebar_plugin_error = status.error;
        self.sidebar_plugin_retry_after_ms = status.retry_after_ms;
        self.sidebar_plugin_retry_at =
            status.retry_after_ms.map(|delay_ms| Instant::now() + Duration::from_millis(delay_ms));
        if had_surface && self.sidebar_plugin_surface.is_none() {
            self.session.invalidate_sidebar_plugin_sync();
        }
        if self.sidebar_focus_pending && (self.sidebar_plugin_surface.is_some() || relaunch) {
            self.sidebar_focus_pending = false;
            if self.sidebar_plugin_surface.is_some() {
                self.sidebar_focused = true;
                self.menu = None;
                self.prompt = None;
                self.omnibar = None;
                self.selection = None;
            }
        }
        if self.sidebar_focused && self.sidebar_plugin_surface.is_none() {
            self.sidebar_focused = false;
        }
    }

    fn handle(&mut self, event: AppEvent) -> anyhow::Result<RenderAction> {
        if let AppEvent::Input(Event::Paste(text)) = &event
            && deferred_paste_bytes(text) > MAX_DEFERRED_INPUT_BYTES
        {
            self.status_message = Some("Paste exceeds the 4 MiB PTY buffer limit".to_string());
            return Ok(RenderAction::Draw);
        }
        match &event {
            AppEvent::Mux(MuxEvent::SurfaceExited(_) | MuxEvent::LayoutChanged(_))
            | AppEvent::Input(Event::Key(_) | Event::Mouse(_) | Event::Paste(_)) => {
                self.session.refresh_remote_tree_if_stale();
            }
            AppEvent::Mux(MuxEvent::TreeChanged) => {
                if self.session.remote_tree_is_stale() {
                    self.session.refresh_remote_tree_if_stale();
                } else {
                    self.session.refresh_remote_tree_background();
                }
            }
            _ => {}
        }
        if matches!(
            &event,
            AppEvent::Mux(
                MuxEvent::TreeChanged | MuxEvent::LayoutChanged(_) | MuxEvent::SurfaceExited(_)
            )
        ) {
            self.session.clear_surface_sync_failures();
        }
        let event = match event {
            AppEvent::Input(input @ (Event::Key(_) | Event::Mouse(_) | Event::Paste(_)))
                if self.missing_input_surface(&input).is_some()
                    && !self.input_can_update_pending_mutation(&input) =>
            {
                let surface = self.missing_input_surface(&input).unwrap();
                self.queue_surface_attach(surface);
                return Ok(self.defer_input(input));
            }
            AppEvent::Input(input @ Event::Mouse(_))
                if (self.session.has_pending_routing_mutations()
                    || self.session.remote_tree_is_stale()
                    || self.mux_recovery_generation.load(Ordering::Acquire) != 0
                    || self.routing_refresh_pending)
                    && !self.input_can_update_pending_mutation(&input) =>
            {
                self.status_message =
                    Some("Pointer input was discarded while the layout changed".to_string());
                return Ok(RenderAction::Draw);
            }
            AppEvent::Input(input @ (Event::Key(_) | Event::Mouse(_) | Event::Paste(_)))
                if (self.session.has_pending_mutations()
                    || self.session.remote_tree_is_stale()
                    || self.mux_recovery_generation.load(Ordering::Acquire) != 0
                    || self.routing_refresh_pending)
                    && !self.input_can_update_pending_mutation(&input) =>
            {
                return Ok(self.defer_input(input));
            }
            event => event,
        };
        match event {
            AppEvent::MuxTitlesReady => {
                Ok(if self.apply_mux_titles() { RenderAction::Paint } else { RenderAction::None })
            }
            AppEvent::MuxSubscriptionRecovered {
                recovery_generation,
                routing_generation,
                result,
            } => {
                if recovery_generation != self.mux_recovery_generation.load(Ordering::Acquire) {
                    return Ok(RenderAction::None);
                }
                match result {
                    Ok(tree) => {
                        let empty = tree.workspaces.is_empty();
                        self.replace_authoritative_tree(tree, routing_generation);
                        self.session.refresh_clients_background();
                        if empty {
                            self.quit = true;
                            return Ok(RenderAction::None);
                        }
                        self.status_message = Some(
                            "Mux event backlog overflowed; subscription recovered".to_string(),
                        );
                    }
                    Err(error) => {
                        if self
                            .mux_recovery_generation
                            .compare_exchange(
                                recovery_generation,
                                0,
                                Ordering::AcqRel,
                                Ordering::Acquire,
                            )
                            .is_err()
                        {
                            return Ok(RenderAction::None);
                        }
                        self.deferred_input.clear();
                        self.prefix_armed = false;
                        self.session.invalidate_remote_tree();
                        self.session.refresh_remote_tree_if_stale();
                        self.status_message = Some(format!(
                            "Mux event backlog recovery failed; queued input was discarded while retrying: {error}"
                        ));
                    }
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::MuxRecoveryComplete { recovery_generation } => {
                if recovery_generation != self.mux_recovery_generation.load(Ordering::Acquire) {
                    return Ok(RenderAction::None);
                }
                if self
                    .mux_recovery_generation
                    .compare_exchange(recovery_generation, 0, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
                {
                    return Ok(RenderAction::None);
                }
                self.routing_refresh_pending = true;
                Ok(RenderAction::Draw)
            }
            AppEvent::SidebarPluginUpdated { status, relaunch } => {
                self.apply_sidebar_plugin_status(status, relaunch);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::Empty) => {
                self.quit = true;
                Ok(RenderAction::None)
            }
            AppEvent::Mux(MuxEvent::SurfaceExited(id)) => {
                self.retire_surface_state(id);
                self.remove_surface_from_tree(id);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::SurfaceResized { surface, cols, rows, reservation_id }) => {
                self.session.confirm_surface_resize(surface, (cols, rows), reservation_id);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::SurfaceResizeFailed {
                surface,
                cols,
                rows,
                error,
                retry_after_ms,
                reservation_id,
            }) => {
                if self.session.note_surface_resize_failure(
                    surface,
                    (cols, rows),
                    retry_after_ms,
                    reservation_id,
                ) {
                    self.status_message = Some(format!(
                        "browser surface {surface} resize to {cols}x{rows} failed: {error}"
                    ));
                    Ok(RenderAction::Draw)
                } else {
                    Ok(RenderAction::None)
                }
            }
            AppEvent::Mux(MuxEvent::Status(message)) => {
                self.status_message = Some(message);
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::ConfigReloadRequested) => {
                self.reload_config();
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::WindowTitleRequested(title)) => {
                self.write_window_title(&title)?;
                Ok(RenderAction::None)
            }
            AppEvent::Mux(MuxEvent::SurfaceOutput(id)) => {
                if self.sidebar_plugin_surface == Some(id) {
                    return Ok(RenderAction::Paint);
                }
                if self.frame_only_browser_update(id) {
                    Ok(RenderAction::Graphics)
                } else {
                    Ok(RenderAction::Paint)
                }
            }
            AppEvent::Mux(MuxEvent::PairingRequested(challenge)) => {
                let duplicate = self
                    .pairing_dialog
                    .as_ref()
                    .is_some_and(|dialog| dialog.challenge.id == challenge.id)
                    || self.pairing_queue.iter().any(|queued| queued.id == challenge.id);
                if !duplicate {
                    if self.pairing_dialog.is_none() {
                        self.pairing_dialog = Some(PairingDialog::new(challenge));
                    } else {
                        self.pairing_queue.push_back(challenge);
                    }
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(MuxEvent::PairingResolved { request }) => {
                self.pairing_queue.retain(|challenge| challenge.id != request);
                if self.pairing_dialog.as_ref().is_some_and(|dialog| dialog.challenge.id == request)
                {
                    self.pairing_dialog = self.pairing_queue.pop_front().map(PairingDialog::new);
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(
                MuxEvent::ClientAttached { .. }
                | MuxEvent::ClientChanged { .. }
                | MuxEvent::ClientDetached(_)
                | MuxEvent::ClientListInvalidated,
            ) => {
                self.session.refresh_clients_background();
                Ok(RenderAction::Draw)
            }
            AppEvent::Mux(_) => Ok(RenderAction::Draw),
            AppEvent::BrowserResizeFailed(failure) => {
                self.status_message = Some(format!(
                    "browser surface {} resize to {}x{} failed: {}",
                    failure.surface_id, failure.cols, failure.rows, failure.error
                ));
                Ok(RenderAction::Draw)
            }
            AppEvent::PtyFailuresReady => Ok(self.apply_pty_failures()),
            AppEvent::PtyOperationFailed(failure) => Ok(self.apply_pty_operation_failure(failure)),
            AppEvent::SessionMutationSettled { outcome, routing } => {
                self.session.settle_pending_mutation(routing);
                match outcome {
                    SessionMutationOutcome::Success { tree } => {
                        if let Some(tree) = tree {
                            self.replace_tree(tree);
                        }
                        self.routing_refresh_retries_remaining = 0;
                    }
                    SessionMutationOutcome::AuthoritativeMutationSucceeded {
                        tree,
                        authoritative_generation,
                        routing_generation,
                        completion,
                    } => {
                        self.session.clear_surface_sync_failures();
                        self.replace_authoritative_tree(tree, routing_generation);
                        self.routing_refresh_retries_remaining = 0;
                        if let Some(completion) = completion {
                            self.pending_session_completions.push_back(completion);
                        }
                        self.apply_session_completions_through(authoritative_generation);
                    }
                    SessionMutationOutcome::IdentityRefreshSucceeded {
                        tree,
                        authoritative_generation,
                        routing_generation,
                        refresh_sequence,
                    } => {
                        if !self.accept_refresh_sequence(refresh_sequence) {
                            self.apply_session_completions_through(authoritative_generation);
                            self.complete_routing_after_stale_identity_result();
                            return Ok(RenderAction::None);
                        }
                        self.session.clear_surface_sync_failures();
                        self.session.reconcile_exited_surfaces(&tree);
                        self.replace_authoritative_tree(tree, routing_generation);
                        self.routing_refresh_retries_remaining = 0;
                        self.background_refresh_attempts = 0;
                        self.background_refresh_retry_at = None;
                        self.apply_session_completions_through(authoritative_generation);
                        self.complete_remote_tree_refresh(true);
                    }
                    SessionMutationOutcome::CommittedTreeStale { error, completion } => {
                        if let Some(completion) = completion {
                            self.pending_session_completions.push_back(completion);
                        }
                        self.routing_refresh_retries_remaining = ROUTING_REFRESH_RETRIES;
                        if let Some(error) = error {
                            self.status_message = Some(format!(
                                "session changed, but its layout refresh failed: {error}"
                            ));
                        }
                        self.session.invalidate_remote_tree();
                        self.session.refresh_remote_tree_if_stale();
                    }
                    SessionMutationOutcome::IdentityRefreshFailed { error, refresh_sequence } => {
                        if !self.accept_refresh_sequence(refresh_sequence) {
                            self.complete_routing_after_stale_identity_result();
                            return Ok(RenderAction::None);
                        }
                        self.status_message = Some(format!(
                            "session changed, but its layout is still stale: {error}"
                        ));
                        let refresh_stale = self.routing_refresh_retries_remaining > 0;
                        if refresh_stale {
                            self.routing_refresh_retries_remaining -= 1;
                            self.session.invalidate_remote_tree();
                        }
                        self.complete_remote_tree_refresh(refresh_stale);
                        return Ok(RenderAction::Draw);
                    }
                    SessionMutationOutcome::SurfaceSyncFailed {
                        surface,
                        operation,
                        error,
                        reconnect_required,
                    } => {
                        if reconnect_required {
                            self.deferred_input.retain(|input| input.destination != Some(surface));
                            self.status_message = Some(format!(
                                "surface {surface} {operation} outcome is unknown; detach and reconnect before sending more input: {error}"
                            ));
                        } else {
                            self.status_message = Some(format!(
                                "surface {surface} {operation} failed; retries are rate-limited: {error}"
                            ));
                        }
                    }
                    SessionMutationOutcome::SurfaceSizeReleased { surface } => {
                        self.pending_size_releases.remove(&surface);
                        self.visible_size_surfaces.remove(&surface);
                    }
                    SessionMutationOutcome::SurfaceSizeReleaseFailed { surface, error } => {
                        self.pending_size_releases.remove(&surface);
                        self.session.invalidate_surface_size_report(surface);
                        if self.pane_areas.iter().any(|area| area.surface == surface) {
                            self.visible_size_surfaces.remove(&surface);
                        }
                        self.status_message = Some(format!(
                            "surface {surface} size release failed; retrying on the next layout: {error}"
                        ));
                    }
                    SessionMutationOutcome::SurfaceSizeReleaseCanceled { surface } => {
                        self.pending_size_releases.remove(&surface);
                    }
                    SessionMutationOutcome::ClientSizingChanged => {
                        self.session.refresh_clients_background();
                    }
                    SessionMutationOutcome::MutationTimedOut(error) => {
                        self.status_message = Some(format!(
                            "session operation may have committed; refreshing its layout: {error}"
                        ));
                        self.routing_refresh_retries_remaining = ROUTING_REFRESH_RETRIES;
                        self.session.invalidate_remote_tree();
                        self.session.refresh_remote_tree_if_stale();
                        return Ok(RenderAction::Draw);
                    }
                    SessionMutationOutcome::Failed(error) => {
                        self.deferred_input.clear();
                        self.prefix_armed = false;
                        self.pending_session_completions.clear();
                        self.status_message = Some(format!("session operation failed: {error}"));
                        return Ok(RenderAction::Draw);
                    }
                    SessionMutationOutcome::Canceled => {
                        if self.session.has_pending_mutations() {
                            self.session.defer_cancellation();
                            return Ok(RenderAction::None);
                        }
                        self.apply_session_cancellation();
                        return Ok(RenderAction::Draw);
                    }
                }
                self.session.refresh_remote_tree_if_stale();
                if self.session.has_pending_mutations() || self.session.remote_tree_is_stale() {
                    return Ok(RenderAction::Draw);
                }
                self.routing_refresh_pending = true;
                Ok(RenderAction::Draw)
            }
            AppEvent::RemoteTreeUpdated { refresh_sequence, routing_generation, result } => {
                if !self.accept_refresh_sequence(refresh_sequence) {
                    return Ok(RenderAction::None);
                }
                let refreshed = match result {
                    Ok(tree) => {
                        self.session.reconcile_exited_surfaces(&tree);
                        self.replace_authoritative_tree(tree, routing_generation);
                        self.routing_refresh_pending = true;
                        self.routing_refresh_retries_remaining = 0;
                        self.background_refresh_attempts = 0;
                        self.background_refresh_retry_at = None;
                        true
                    }
                    Err(error) => {
                        let retrying = self.schedule_background_refresh_retry();
                        self.status_message = Some(if retrying {
                            format!("refresh remote tree failed; retrying: {error}")
                        } else {
                            format!(
                                "refresh remote tree failed after {BACKGROUND_REFRESH_RETRIES} attempts; automatic retries stopped, reconnect to retry: {error}"
                            )
                        });
                        let _ = self.session.take_background_refresh_dirty();
                        false
                    }
                };
                if refreshed {
                    self.complete_remote_tree_refresh(true);
                }
                if !self.session.has_pending_mutations()
                    && !self.session.remote_tree_is_stale()
                    && !self.deferred_input.is_empty()
                {
                    self.routing_refresh_pending = true;
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::ClientsUpdated { generation, result } => {
                if generation != self.session.client_refresh_generation() {
                    return Ok(RenderAction::None);
                }
                match result {
                    Ok(clients) => self.replace_clients(clients),
                    Err(error) => {
                        self.status_message = Some(format!("Could not list clients: {error}"));
                    }
                }
                Ok(RenderAction::Draw)
            }
            AppEvent::Input(Event::Key(key)) => self.handle_key(key),
            AppEvent::Input(Event::Mouse(mouse)) => self.handle_mouse(mouse),
            AppEvent::Input(Event::Paste(text)) => {
                self.status_message = None;
                if self.pairing_dialog.is_some() {
                    Ok(RenderAction::Draw)
                } else if let Some(prompt) = self.prompt.as_mut() {
                    prompt.input.insert_str(&text);
                    Ok(RenderAction::Draw)
                } else if let Some(state) = self.omnibar.as_mut() {
                    clear_omnibar_selection(state);
                    state.input.insert_str(&text);
                    Ok(RenderAction::Draw)
                } else if self.sidebar_focused {
                    if self.config.sidebar.plugin.is_some() {
                        self.paste_sidebar(&text);
                        Ok(if self.status_message.is_some() {
                            RenderAction::Draw
                        } else {
                            RenderAction::None
                        })
                    } else {
                        if self.sidebar_view == SidebarView::Files {
                            self.sidebar_files.insert_filter_text(&text);
                        }
                        Ok(RenderAction::Draw)
                    }
                } else {
                    self.paste(&text);
                    Ok(if self.status_message.is_some() {
                        RenderAction::Draw
                    } else {
                        RenderAction::None
                    })
                }
            }
            AppEvent::Input(Event::FocusGained) => {
                self.reassert_visible_surface_sizes();
                Ok(RenderAction::Draw)
            }
            AppEvent::Input(Event::FocusLost) => {
                self.cancel_pty_mouse_drag();
                Ok(RenderAction::None)
            }
            AppEvent::Input(Event::Resize(_, _)) => {
                self.refresh_cell_pixels(false);
                self.render_states.clear();
                self.sidebar_plugin_surface = None;
                Ok(RenderAction::Draw)
            }
        }
    }

    fn input_can_update_pending_mutation(&self, input: &Event) -> bool {
        if let Event::Key(key) = input
            && ((self.config.keys.prefix.matches(key) && !self.prefix_armed)
                || self.config.keys.modeless_action_for(key) == Some(Action::Detach)
                || (self.prefix_armed && self.config.keys.action_for(key) == Some(Action::Detach)))
        {
            return true;
        }
        matches!(
            (input, &self.drag),
            (
                Event::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(MouseButton::Left)
                        | MouseEventKind::Up(MouseButton::Left),
                    ..
                }),
                Some(Drag::ResizeSplit { .. })
            ) | (
                Event::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(MouseButton::Left)
                        | MouseEventKind::Up(MouseButton::Left),
                    ..
                }),
                Some(Drag::Select { .. })
            ) | (
                Event::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(MouseButton::Left)
                        | MouseEventKind::Up(MouseButton::Left),
                    ..
                }),
                Some(Drag::Browser { .. })
            ) | (
                Event::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(_) | MouseEventKind::Up(_),
                    ..
                }),
                Some(Drag::PtyMouse { .. })
            )
        )
    }

    fn defer_input(&mut self, input: Event) -> RenderAction {
        let destination = self.input_destination(&input);
        let sidebar_focus_intent =
            self.sidebar_focus_pending && matches!(&input, Event::Key(_) | Event::Paste(_));
        let routing_started = self.session.routing_mutation_started();
        let routing_intent =
            (routing_started > self.applied_routing_generation).then_some(routing_started);
        let replace_motion = match (&input, self.deferred_input.back()) {
            (
                Event::Mouse(MouseEvent { kind: MouseEventKind::Moved, .. }),
                Some(DeferredInput {
                    event: Event::Mouse(MouseEvent { kind: MouseEventKind::Moved, .. }),
                    destination: previous_destination,
                    routing_intent: previous_intent,
                    sidebar_focus_intent: previous_sidebar_intent,
                }),
            ) => {
                *previous_destination == destination
                    && *previous_intent == routing_intent
                    && *previous_sidebar_intent == sidebar_focus_intent
            }
            (
                Event::Mouse(MouseEvent { kind: MouseEventKind::Drag(button), .. }),
                Some(DeferredInput {
                    event: Event::Mouse(MouseEvent { kind: MouseEventKind::Drag(previous), .. }),
                    destination: previous_destination,
                    routing_intent: previous_intent,
                    sidebar_focus_intent: previous_sidebar_intent,
                }),
            ) => {
                button == previous
                    && *previous_destination == destination
                    && *previous_intent == routing_intent
                    && *previous_sidebar_intent == sidebar_focus_intent
            }
            _ => false,
        };
        if replace_motion {
            *self.deferred_input.back_mut().unwrap() =
                DeferredInput { event: input, destination, routing_intent, sidebar_focus_intent };
            return RenderAction::None;
        }
        let input_bytes = deferred_input_bytes(&input);
        let mut queued_bytes = self
            .deferred_input
            .iter()
            .map(|input| deferred_input_bytes(&input.event))
            .sum::<usize>();
        let prioritize_release =
            matches!(&input, Event::Mouse(MouseEvent { kind: MouseEventKind::Up(_), .. }));
        while self.deferred_input.len() >= DEFERRED_INPUT_CAPACITY
            || queued_bytes.saturating_add(input_bytes) > MAX_DEFERRED_INPUT_BYTES
        {
            if !prioritize_release {
                self.status_message = Some(
                    "Input queue byte limit reached while a session change is pending".to_string(),
                );
                return RenderAction::Draw;
            }
            let Some(removed) = self.deferred_input.pop_front() else { break };
            queued_bytes = queued_bytes.saturating_sub(deferred_input_bytes(&removed.event));
        }
        self.deferred_input.push_back(DeferredInput {
            event: input,
            destination,
            routing_intent,
            sidebar_focus_intent,
        });
        RenderAction::None
    }

    fn input_destination(&self, input: &Event) -> Option<SurfaceId> {
        match input {
            Event::Key(_) | Event::Paste(_)
                if self.prompt.is_none() && self.omnibar.is_none() && !self.sidebar_focused =>
            {
                self.active_surface()
            }
            Event::Mouse(mouse) => self
                .pane_area_at(mouse.column, mouse.row)
                .filter(|area| area.content.contains(mouse.column, mouse.row))
                .map(|area| area.surface),
            _ => None,
        }
    }

    fn active_pane(&self) -> Option<PaneId> {
        self.tree.active_screen().map(|screen| screen.active_pane)
    }

    fn active_surface(&self) -> Option<SurfaceId> {
        self.tree.active_surface()
    }

    fn active_surface_handle(&self) -> Option<SurfaceHandle> {
        self.active_surface().and_then(|id| self.session.surface(id))
    }

    fn active_surface_with_handle(&self) -> Option<(SurfaceId, SurfaceHandle)> {
        let id = self.active_surface()?;
        Some((id, self.session.surface(id)?))
    }

    fn missing_input_surface(&self, input: &Event) -> Option<SurfaceId> {
        let surface = match input {
            Event::Key(_) | Event::Paste(_) => self.active_surface()?,
            Event::Mouse(mouse) => {
                let area = self.pane_area_at(mouse.column, mouse.row)?;
                area.content.contains(mouse.column, mouse.row).then_some(area.surface)?
            }
            _ => return None,
        };
        (!self.session.has_surface(surface)).then_some(surface)
    }

    fn queue_surface_attach(&mut self, surface: SurfaceId) {
        if !self.session.can_attach_surface(surface) {
            return;
        }
        let size = self
            .pane_areas
            .iter()
            .find(|area| area.surface == surface)
            .map(|area| (area.content.width, area.content.height))
            .filter(|(cols, rows)| *cols > 0 && *rows > 0);
        self.session.attach_surface(surface, size);
    }

    fn retry_deferred_surface_attach(&mut self) {
        let surface =
            self.deferred_input.iter().find_map(|input| self.missing_input_surface(&input.event));
        if let Some(surface) = surface {
            self.queue_surface_attach(surface);
        }
    }

    fn active_screen_id(&self) -> Option<cmux_tui_core::ScreenId> {
        self.tree.active_screen().map(|screen| screen.id)
    }

    fn reassert_visible_surface_sizes(&mut self) {
        if self.config.sidebar.plugin.is_some()
            && self.sidebar_visible
            && self.sidebar_width >= 3
            && let Some(surface) = self.sidebar_surface_handle()
        {
            let rect = self.sidebar_plugin_rect();
            if rect.width > 0 && rect.height > 0 {
                let desired = (rect.width, rect.height);
                let needs_barrier = surface.resize_needed(rect.width, rect.height, true);
                if let Some(surface_id) = self.sidebar_plugin_surface
                    && !(surface.kind() == SurfaceKind::Browser
                        && self.browser_input.resize_failed(surface_id, desired))
                {
                    match self.session.surface_resize_decision(
                        surface_id,
                        (rect.width, rect.height),
                        needs_barrier,
                    ) {
                        SurfaceResizeDecision::Noop => {
                            if surface.kind() != SurfaceKind::Browser {
                                let _ = surface.reassert_size(rect.width, rect.height);
                            }
                        }
                        SurfaceResizeDecision::AlreadyClaimed | SurfaceResizeDecision::Failed => {}
                        SurfaceResizeDecision::NeedsQueue(claim)
                            if self.prepare_pty_input_before_mutation() =>
                        {
                            self.enqueue_surface_resize(
                                surface_id,
                                surface,
                                rect.width,
                                rect.height,
                                true,
                                Some(claim),
                            );
                        }
                        SurfaceResizeDecision::NeedsQueue(_) => {}
                    }
                }
            }
        }
        for index in 0..self.pane_areas.len() {
            let area = self.pane_areas[index];
            if area.content.width == 0 || area.content.height == 0 {
                continue;
            }
            if !self.session.has_surface(area.surface) && !self.prepare_pty_input_before_mutation()
            {
                return;
            }
            if let Some(surface) = self.session.surface(area.surface) {
                let desired = (area.content.width, area.content.height);
                if surface.kind() == SurfaceKind::Browser
                    && self.browser_input.resize_failed(area.surface, desired)
                {
                    continue;
                }
                let needs_barrier =
                    surface.resize_needed(area.content.width, area.content.height, true);
                match self.session.surface_resize_decision(
                    area.surface,
                    (area.content.width, area.content.height),
                    needs_barrier,
                ) {
                    SurfaceResizeDecision::Noop => {
                        if surface.kind() != SurfaceKind::Browser {
                            let _ = surface.reassert_size(area.content.width, area.content.height);
                        }
                    }
                    SurfaceResizeDecision::AlreadyClaimed | SurfaceResizeDecision::Failed => {}
                    SurfaceResizeDecision::NeedsQueue(claim)
                        if self.prepare_pty_input_before_mutation() =>
                    {
                        self.enqueue_surface_resize(
                            area.surface,
                            surface,
                            area.content.width,
                            area.content.height,
                            true,
                            Some(claim),
                        );
                    }
                    SurfaceResizeDecision::NeedsQueue(_) => {}
                }
            } else if self.session.can_attach_surface(area.surface)
                && self.prepare_pty_input_before_mutation()
            {
                self.session
                    .attach_surface(area.surface, Some((area.content.width, area.content.height)));
            }
        }
    }

    pub fn dragging_scrollbar(&self) -> Option<SurfaceId> {
        match self.drag {
            Some(Drag::Scrollbar { surface, .. }) => Some(surface),
            _ => None,
        }
    }

    fn enqueue_surface_resize(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        cols: u16,
        rows: u16,
        reassert: bool,
        claim: Option<SurfaceResizeClaim>,
    ) {
        if surface.kind() == SurfaceKind::Browser {
            let Some(claim) = claim else { return };
            let ownership = self.session.surface_resize_ownership.clone();
            let _ = self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: BrowserInputKind::Resize {
                    cols,
                    rows,
                    reassert,
                    _claim: Some(Box::new(claim)),
                    on_result: Some(Box::new(move |accepted| {
                        record_surface_resize_dispatch_result(
                            &ownership,
                            surface_id,
                            (cols, rows),
                            accepted,
                        );
                    })),
                },
            });
        } else {
            let Some(claim) = claim else { return };
            self.session.resize_surface(surface_id, surface, cols, rows, reassert, claim);
        }
    }

    pub fn tab_drag(&self) -> Option<TabDragView> {
        match self.drag {
            Some(Drag::Tab { surface, target }) => Some(TabDragView { surface, target }),
            _ => None,
        }
    }

    pub fn workspace_drag(&self) -> Option<(WorkspaceId, Option<usize>)> {
        match self.drag {
            Some(Drag::Workspace { workspace, target }) => Some((workspace, target)),
            _ => None,
        }
    }

    pub fn surface_scroll_offset(&self, surface: SurfaceId) -> u64 {
        self.session
            .surface(surface)
            .and_then(|surface| surface.with_terminal(|t| t.scrollbar().map(|sb| sb.offset)))
            .flatten()
            .unwrap_or(0)
    }

    fn selection_auto_scroll_active(&self) -> bool {
        matches!(self.drag, Some(Drag::Select { auto_scroll: Some(_), .. }))
    }

    fn auto_scroll_selection_tick(&mut self) -> bool {
        let Some(Drag::Select { content, auto_scroll: Some(dir), col }) = self.drag else {
            return false;
        };
        let Some(surface_id) = self.selection.map(|sel| sel.surface) else { return false };
        let Some(surface) = self.session.surface(surface_id) else { return false };
        let moved = surface.scroll_delta(dir as isize).unwrap_or(false);
        let edge_row = if dir < 0 { 0 } else { content.height.saturating_sub(1) };
        let offset = self.surface_scroll_offset(surface_id);
        if let Some(sel) = self.selection.as_mut() {
            sel.head = (col.min(content.width.saturating_sub(1)), offset + edge_row as u64);
        }
        moved
    }

    /// Content size for a pane filling `rect`.
    fn size_of_rect(&self, rect: Rect) -> Option<(u16, u16)> {
        content_size_for_rect(rect, self.config.scrollbar.position)
    }

    /// Size hint for splitting `pane`: the second side of its rect.
    fn split_size_hint(&self, pane: PaneId, dir: SplitDir) -> Option<(u16, u16)> {
        let area = self.pane_areas.iter().find(|a| a.pane == pane)?;
        let (_, b) = split_sides(area.rect, dir, 0.5);
        self.size_of_rect(b)
    }

    fn split_pane(&mut self, pane: PaneId, dir: SplitDir) -> anyhow::Result<()> {
        let hint = self.split_size_hint(pane, dir);
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        self.session.split(pane, dir, hint)
    }

    fn new_terminal_tab(&mut self, pane: Option<PaneId>) -> anyhow::Result<()> {
        let pane = pane.or_else(|| self.active_pane());
        self.session.new_tab(pane, self.terminal_tab_size_hint(pane))
    }

    fn terminal_tab_size_hint(&self, pane: Option<PaneId>) -> Option<(u16, u16)> {
        match pane {
            Some(pane) => self
                .pane_areas
                .iter()
                .find(|area| area.pane == pane)
                .and_then(|area| self.size_of_rect(area.rect)),
            None => self
                .active_pane()
                .and_then(|pane| self.terminal_tab_size_hint(Some(pane)))
                .or_else(|| self.size_of_rect(self.content_area)),
        }
    }

    fn new_pane_smart(&mut self) -> anyhow::Result<()> {
        let Some(pane) = self.active_pane() else {
            return Ok(());
        };
        let Some(hint) = self.tree.active_screen().and_then(|screen| {
            let mut panes = Vec::new();
            screen.layout.pane_ids(&mut panes);
            panes.push(PaneId::MAX);
            let layout = zellij_default_pane_layout(&panes)?;
            let rect = layout_screen(&layout, self.content_area, Some(PaneId::MAX))
                .rect_of(PaneId::MAX)?;
            self.size_of_rect(rect)
        }) else {
            return Ok(());
        };
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        self.session.new_pane(pane, Some(hint))
    }

    fn new_workspace(&mut self) -> anyhow::Result<()> {
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        self.session.new_workspace(self.size_of_rect(self.content_area))
    }

    fn new_screen(&mut self) -> anyhow::Result<()> {
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        let workspace = self.tree.active_workspace().map(|workspace| workspace.id);
        self.session.new_screen(workspace, self.size_of_rect(self.content_area))
    }

    fn handle_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        if key.kind == KeyEventKind::Release {
            return Ok(RenderAction::None);
        }
        self.status_message = None;
        if self.pairing_dialog.is_some() {
            return self.handle_pairing_key(key);
        }
        if self.prompt.is_some() {
            return self.handle_prompt_key(key);
        }
        if self.menu.is_some() {
            return self.handle_menu_key(key);
        }
        if self.omnibar.is_some() {
            return self.handle_omnibar_key(key);
        }
        if self.prefix_armed {
            self.prefix_armed = false;
            return self.handle_prefixed(key);
        }
        if self.config.keys.prefix.matches(&key) {
            self.prefix_armed = true;
            return Ok(RenderAction::Draw);
        }
        if self.sidebar_focused {
            if self.config.sidebar.plugin.is_some() {
                self.forward_sidebar_key(&key);
                return Ok(if self.status_message.is_some() {
                    RenderAction::Draw
                } else {
                    RenderAction::None
                });
            } else {
                return self.handle_builtin_sidebar_key(&key);
            }
        }
        if let Some(action) = self.config.keys.modeless_action_for(&key) {
            return self.run_action(action);
        }
        // Typing replaces any selection highlight.
        self.selection = None;
        self.forward_key(&key);
        Ok(if self.status_message.is_some() { RenderAction::Draw } else { RenderAction::None })
    }

    fn handle_builtin_sidebar_key(&mut self, key: &KeyEvent) -> anyhow::Result<RenderAction> {
        if key.code == KeyCode::Tab {
            return self.run_action(Action::ToggleSidebarView);
        }
        match self.sidebar_view {
            SidebarView::Files => {
                if let Some(command) = self.sidebar_files.handle_key(key) {
                    self.run_file_command(command);
                }
            }
            SidebarView::Workspaces => match key.code {
                KeyCode::Up => {
                    self.sidebar_workspace_selection =
                        self.sidebar_workspace_selection.saturating_sub(1);
                }
                KeyCode::Char('k') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    self.sidebar_workspace_selection =
                        self.sidebar_workspace_selection.saturating_sub(1);
                }
                KeyCode::Down => {
                    self.sidebar_workspace_selection = (self.sidebar_workspace_selection + 1)
                        .min(self.tree.workspaces.len().saturating_sub(1));
                }
                KeyCode::Char('j') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    self.sidebar_workspace_selection = (self.sidebar_workspace_selection + 1)
                        .min(self.tree.workspaces.len().saturating_sub(1));
                }
                KeyCode::Enter => {
                    self.select_workspace_for_client(Some(self.sidebar_workspace_selection), None);
                }
                _ => {}
            },
        }
        Ok(RenderAction::Draw)
    }

    fn run_file_command(&mut self, command: FileCommand) {
        let result = match command {
            FileCommand::Reroot => {
                let cwd = self
                    .focused_surface_cwd()
                    .unwrap_or_else(|| self.sidebar_files.fallback_cwd().to_path_buf());
                self.sidebar_files.reroot(cwd);
                self.sidebar_followed_surface = self.tree.active_surface();
                return;
            }
            FileCommand::Cd(path) => {
                let Some(surface_id) = self.active_surface() else {
                    self.sidebar_files.set_message("no focused pane");
                    return;
                };
                let Some(surface) = self.session.surface(surface_id) else {
                    self.sidebar_files.set_message("focused surface is unavailable");
                    return;
                };
                let quoted = shell_single_quote(&path.to_string_lossy());
                let bytes = format!("cd {quoted}\n");
                if self.write_pty_bytes(
                    surface_id,
                    surface,
                    PtyInputBytes::from_slice(bytes.as_bytes()),
                    PtyInputKind::Ordered,
                ) {
                    Ok(())
                } else {
                    Err(anyhow::anyhow!("input was not queued"))
                }
            }
            FileCommand::OpenEditor(path) => {
                let editor = std::env::var("EDITOR")
                    .ok()
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| "vi".to_string());
                let cwd = path
                    .parent()
                    .unwrap_or_else(|| std::path::Path::new("/"))
                    .to_string_lossy()
                    .into_owned();
                self.session.run_command(
                    vec![editor, path.to_string_lossy().into_owned()],
                    self.active_pane(),
                    Some(cwd),
                    self.terminal_tab_size_hint(self.active_pane()),
                )
            }
            FileCommand::OpenBrowser(path) => self.session.new_browser_tab(
                file_url(&path),
                self.active_pane(),
                self.browser_tab_size_hint(self.active_pane()),
            ),
        };
        match result {
            Ok(()) => self.sidebar_files.set_message("sent to focused pane"),
            Err(error) => self.sidebar_files.set_message(error.to_string()),
        }
    }

    /// Commit the open rename dialog (Enter or the OK button).
    fn commit_prompt(&mut self) {
        let Some(prompt) = self.take_prompt() else { return };
        let input = prompt.input.as_str().to_string();
        if !self.prepare_pty_input_before_mutation() {
            return;
        }
        match prompt.target {
            PromptTarget::Workspace(id) => {
                if !input.is_empty() {
                    self.session.rename_workspace(id, input);
                }
            }
            // Empty screen/tab names clear back to the default.
            PromptTarget::Screen(id) => self.session.rename_screen(id, input),
            PromptTarget::Surface(id) => self.session.rename_surface(id, input),
        }
    }

    fn take_prompt(&mut self) -> Option<Prompt> {
        self.shake_frames = 0;
        self.prompt.take()
    }

    fn close_prompt(&mut self) {
        self.shake_frames = 0;
        self.prompt = None;
    }

    fn handle_prompt_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        let Some(prompt) = self.prompt.as_mut() else { return Ok(RenderAction::None) };
        match prompt.input.handle_key(&key) {
            InputEvent::Commit => self.commit_prompt(),
            InputEvent::Cancel => self.close_prompt(),
            InputEvent::Changed | InputEvent::None => {}
        }
        Ok(RenderAction::Draw)
    }

    fn resolve_pairing(&mut self, approve: bool) {
        let Some(dialog) = self.pairing_dialog.take() else { return };
        if let Err(error) = self.session.respond_pairing(dialog.challenge.id, approve) {
            self.status_message = Some(error.to_string());
        }
        self.pairing_dialog = self.pairing_queue.pop_front().map(PairingDialog::new);
    }

    fn handle_pairing_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        match key.code {
            KeyCode::Enter | KeyCode::Char('y') | KeyCode::Char('Y') => self.resolve_pairing(true),
            KeyCode::Esc | KeyCode::Char('n') | KeyCode::Char('N') => self.resolve_pairing(false),
            _ => {}
        }
        Ok(RenderAction::Draw)
    }

    fn handle_pairing_click(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        let Some(dialog) = self.pairing_dialog.as_ref() else { return Ok(RenderAction::None) };
        if dialog.approve.contains(x, y) {
            self.resolve_pairing(true);
        } else if dialog.deny.contains(x, y) || !dialog.rect.contains(x, y) {
            self.resolve_pairing(false);
        }
        Ok(RenderAction::Draw)
    }

    /// Clicks while the rename dialog is open: OK commits, Cancel (or a
    /// click outside the dialog) dismisses; clicks inside are swallowed.
    fn handle_prompt_click(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        let Some(prompt) = self.prompt.as_mut() else { return Ok(RenderAction::None) };
        if prompt.ok.contains(x, y) {
            self.commit_prompt();
        } else if prompt.clear.contains(x, y) {
            prompt.input.clear();
        } else if prompt.input_rect.contains(x, y) {
            let column = x.saturating_sub(prompt.input_rect.x) as usize;
            prompt.input.set_cursor_from_visible_column(column, prompt.input_rect.width as usize);
        } else if prompt.cancel.contains(x, y) || !prompt.rect.contains(x, y) {
            self.close_prompt();
        }
        Ok(RenderAction::Draw)
    }

    fn handle_omnibar_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        let Some(state) = self.omnibar.as_mut() else { return Ok(RenderAction::None) };
        let replace_selection = state.select_all
            && matches!(
                key.code,
                KeyCode::Backspace
                    | KeyCode::Delete
                    | KeyCode::Char(_)
                        if !key.modifiers.intersects(
                            KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER
                        )
            );
        if replace_selection {
            state.input.clear();
            state.select_all = false;
        } else if matches!(
            key.code,
            KeyCode::Left
                | KeyCode::Right
                | KeyCode::Home
                | KeyCode::End
                | KeyCode::Backspace
                | KeyCode::Delete
        ) {
            state.select_all = false;
        }
        if matches!(key.code, KeyCode::Char('a') | KeyCode::Char('A'))
            && key.modifiers.contains(KeyModifiers::CONTROL)
        {
            state.select_all = true;
            state.input.cursor = state.input.buffer.len();
            return Ok(RenderAction::Draw);
        }
        match state.input.handle_key(&key) {
            InputEvent::Cancel => {
                self.omnibar = None;
            }
            InputEvent::Commit => {
                let Some(state) = self.omnibar.take() else { return Ok(RenderAction::Draw) };
                let input = state.input.as_str().trim();
                if input.is_empty() {
                    return Ok(RenderAction::Draw);
                }
                let url = cmux_tui_core::normalize_url(input);
                if !self.prepare_pty_input_before_mutation() {
                    return Ok(RenderAction::None);
                }
                self.enqueue_browser_command(state.surface, BrowserInputKind::Navigate(url));
            }
            InputEvent::Changed | InputEvent::None => {}
        }
        Ok(RenderAction::Draw)
    }

    fn handle_menu_key(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        let Some(menu) = self.menu.as_mut() else { return Ok(RenderAction::None) };
        match key.code {
            KeyCode::Esc => {
                if !menu.close_submenu() {
                    self.menu = None;
                }
                Ok(RenderAction::Draw)
            }
            KeyCode::Up => {
                menu.select_previous();
                Ok(RenderAction::Draw)
            }
            KeyCode::Down => {
                menu.select_next();
                Ok(RenderAction::Draw)
            }
            KeyCode::Left => {
                menu.close_submenu();
                Ok(RenderAction::Draw)
            }
            KeyCode::Right => {
                menu.open_selected_submenu();
                Ok(RenderAction::Draw)
            }
            KeyCode::Enter => {
                if menu.open_selected_submenu() {
                    return Ok(RenderAction::Draw);
                }
                let Some(action) = menu.selected_action() else { return Ok(RenderAction::Draw) };
                self.menu = None;
                self.activate_menu(action)?;
                Ok(RenderAction::Draw)
            }
            _ => Ok(RenderAction::Draw), // swallow while a menu is open
        }
    }

    fn handle_prefixed(&mut self, key: KeyEvent) -> anyhow::Result<RenderAction> {
        // Prefix twice forwards the prefix chord literally.
        if self.config.keys.prefix.matches(&key) {
            if self.sidebar_focused {
                self.forward_sidebar_key(&key);
            } else {
                self.forward_key(&key);
            }
            return Ok(RenderAction::Draw);
        }
        let Some(action) = self.config.keys.action_for(&key) else {
            if self.sidebar_focused {
                self.sidebar_focused = false;
            }
            return Ok(RenderAction::Draw); // unknown prefix command: swallow, redraw indicator
        };
        let was_sidebar_focused = self.sidebar_focused;
        if self.sidebar_focused {
            self.sidebar_focused = false;
        }
        if was_sidebar_focused && action == Action::FocusSidebar {
            return Ok(RenderAction::Draw);
        }
        if browser_only_action(action)
            && !self
                .active_surface_handle()
                .is_some_and(|surface| surface.kind() == SurfaceKind::Browser)
        {
            self.forward_key(&key);
            return Ok(RenderAction::Draw);
        }
        self.run_action(action)
    }

    /// Execute one bound action. Shared by the (configurable) prefix keys
    /// and any future command surface.
    fn run_action(&mut self, action: Action) -> anyhow::Result<RenderAction> {
        if action_prepares_pty_release(action) && !self.prepare_pty_input_before_mutation() {
            return Ok(RenderAction::None);
        }
        let pane = self.active_pane();
        match action {
            Action::NewTab => {
                self.new_terminal_tab(pane)?;
            }
            Action::NewBrowserTab => self.create_browser_tab_for_edit(pane)?,
            Action::NewPaneSmart => self.new_pane_smart()?,
            Action::NextTab => self.select_tab_for_client(pane, None, Some(1)),
            Action::PrevTab => self.select_tab_for_client(pane, None, Some(-1)),
            Action::SelectTab(_) => {
                if let Some(index) = action.tab_index() {
                    self.select_tab_for_client(pane, Some(index), None);
                }
            }
            Action::SplitRight => {
                if let Some(pane) = pane {
                    self.split_pane(pane, SplitDir::Right)?;
                }
            }
            Action::SplitDown => {
                if let Some(pane) = pane {
                    self.split_pane(pane, SplitDir::Down)?;
                }
            }
            Action::CloseTab => {
                // Close the active tab; the pane collapses with its last
                // tab, so this is also "close pane" for single-tab panes.
                if let Some(surface) = self.active_surface() {
                    self.render_states.remove(&surface);
                    self.session.close_surface(surface);
                }
            }
            Action::ClosePane => {
                if let Some(pane) = pane {
                    self.session.close_pane(pane);
                }
            }
            Action::RenameTab => self.open_rename_tab_prompt(pane),
            Action::RenameScreen => self.open_rename_screen_prompt(),
            Action::RenameWorkspace => self.open_rename_workspace_prompt(),
            Action::CloseScreen => {
                if let Some(screen) = self.active_screen_id() {
                    self.session.close_screen(screen);
                }
            }
            Action::PrevScreen => self.select_screen_for_client(None, Some(-1)),
            Action::NextScreen => self.select_screen_for_client(None, Some(1)),
            Action::SelectScreen(_) => {
                if let Some(index) = action.screen_index() {
                    self.select_screen_for_client(Some(index), None);
                }
            }
            Action::NewScreen => self.new_screen()?,
            Action::NextWorkspace => self.select_workspace_for_client(None, Some(1)),
            Action::NewWorkspace => self.new_workspace()?,
            Action::ToggleSidebar => {
                self.sidebar_visible = !self.sidebar_visible;
                if !self.sidebar_visible {
                    self.session.invalidate_sidebar_plugin_sync();
                    self.sidebar_focused = false;
                }
            }
            Action::ToggleSidebarView => self.toggle_sidebar_view(),
            Action::FocusSidebar => self.toggle_sidebar_focus(),
            Action::FocusLeft => self.move_focus(Direction::Left),
            Action::FocusRight => self.move_focus(Direction::Right),
            Action::FocusUp => self.move_focus(Direction::Up),
            Action::FocusDown => self.move_focus(Direction::Down),
            Action::FocusNextPane => self.focus_next_pane(),
            Action::SwapPanePrev => self.swap_pane_by_order(-1),
            Action::SwapPaneNext => self.swap_pane_by_order(1),
            Action::ZoomPane => self.session.zoom_pane(pane),
            Action::ResizeGrow => self.resize_focused_split(0.05),
            Action::ResizeShrink => self.resize_focused_split(-0.05),
            Action::ScrollUp => self.scroll_active(-10),
            Action::ScrollDown => self.scroll_active(10),
            Action::BrowserBack => {
                self.enqueue_active_browser_command(BrowserInputKind::Back);
                return Ok(RenderAction::Draw);
            }
            Action::BrowserForward => {
                self.enqueue_active_browser_command(BrowserInputKind::Forward);
                return Ok(RenderAction::Draw);
            }
            Action::BrowserReload => {
                self.enqueue_active_browser_command(BrowserInputKind::Reload);
                return Ok(RenderAction::Draw);
            }
            Action::BrowserEditUrl => {
                if let Some(pane) = pane {
                    self.focus_omnibar(pane);
                }
                return Ok(RenderAction::Draw);
            }
            Action::Detach => {
                // Local sessions end with the TUI; remote sessions keep
                // running server-side (detach).
                self.quit = true;
                return Ok(RenderAction::None);
            }
        }
        self.status_message = None;
        Ok(RenderAction::Draw)
    }

    fn open_rename_tab_prompt(&mut self, pane: Option<PaneId>) {
        let Some(pane) = pane else { return };
        let Some(tab) = self.tree.pane(pane).and_then(|p| p.tabs.get(p.active_tab)) else {
            return;
        };
        let buffer = tab.name.clone().unwrap_or_default();
        let prompt = Prompt::new("Rename tab", buffer, PromptTarget::Surface(tab.surface));
        self.cancel_pty_mouse_drag();
        self.prompt = Some(prompt);
    }

    fn open_rename_workspace_prompt(&mut self) {
        let Some(ws) = self.tree.active_workspace() else { return };
        let prompt =
            Prompt::new("Rename workspace", ws.name.clone(), PromptTarget::Workspace(ws.id));
        self.cancel_pty_mouse_drag();
        self.prompt = Some(prompt);
    }

    fn open_rename_screen_prompt(&mut self) {
        let Some(ws) = self.tree.active_workspace() else { return };
        let Some(screen) = ws.active_screen_ref() else { return };
        let buffer = screen.name.clone().unwrap_or_default();
        let prompt = Prompt::new("Rename screen", buffer, PromptTarget::Screen(screen.id));
        self.cancel_pty_mouse_drag();
        self.prompt = Some(prompt);
    }

    fn browser_tab_size_hint(&self, pane: Option<PaneId>) -> Option<(u16, u16)> {
        match pane {
            Some(pane) => self.pane_areas.iter().find(|area| area.pane == pane).and_then(|area| {
                browser_content_size_for_rect(area.rect, self.config.scrollbar.position)
            }),
            None => self
                .active_pane()
                .and_then(|pane| self.browser_tab_size_hint(Some(pane)))
                .or_else(|| {
                    browser_content_size_for_rect(self.content_area, self.config.scrollbar.position)
                }),
        }
    }

    fn create_browser_tab_for_edit(&mut self, pane: Option<PaneId>) -> anyhow::Result<()> {
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        let pane = pane.or_else(|| self.active_pane());
        self.session.new_browser_tab(
            "about:blank".to_string(),
            pane,
            self.browser_tab_size_hint(pane),
        )
    }

    fn focus_omnibar(&mut self, pane: PaneId) {
        let Some(surface_id) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            return;
        };
        let Some(surface) = self.session.surface(surface_id) else { return };
        if surface.kind() != SurfaceKind::Browser {
            return;
        }
        let buffer = surface.browser_url().unwrap_or_default();
        self.focus_omnibar_with_buffer(pane, buffer, true);
    }

    fn focus_omnibar_with_buffer(&mut self, pane: PaneId, buffer: String, select_all: bool) {
        let Some(surface) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            return;
        };
        if self.tree.surface_kind(surface) != SurfaceKind::Browser {
            return;
        }
        let Some(area) = self.pane_areas.iter().find(|area| area.pane == pane) else {
            return;
        };
        let has_omnibar = if area.surface == surface {
            area.omnibar.is_some()
        } else {
            let (_, omnibar, _, _) =
                pane_parts_for_rect(area.rect, self.config.scrollbar.position, true);
            omnibar.is_some()
        };
        if !has_omnibar {
            return;
        }
        self.omnibar =
            Some(OmnibarState { pane, surface, input: TextInput::new(buffer), select_all });
    }

    fn browser_surface_for_pane(&self, pane: PaneId) -> anyhow::Result<(SurfaceId, SurfaceHandle)> {
        let Some(surface_id) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            anyhow::bail!("pane has no active surface");
        };
        let Some(surface) = self.session.surface(surface_id) else {
            anyhow::bail!("unknown surface {surface_id}");
        };
        if surface.kind() != SurfaceKind::Browser {
            anyhow::bail!("active surface is not a browser");
        }
        Ok((surface_id, surface))
    }

    /// Dispatch a discrete browser control command (navigate/back/forward/
    /// reload/activate). Unlike disposable input, a full dispatcher queue
    /// (worker wedged in a blocking browser call) must not drop the command
    /// silently: surface backpressure through the status line so the user
    /// knows the action did not take effect.
    fn dispatch_browser_control(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        kind: BrowserInputKind,
    ) {
        if self.browser_input.enqueue(BrowserInputEvent { surface_id, surface, kind }) {
            self.status_message = None;
        } else {
            self.status_message = Some("browser is busy; command dropped".to_string());
        }
    }

    fn enqueue_active_browser_command(&mut self, kind: BrowserInputKind) {
        let Some((surface_id, surface)) = self.active_surface_with_handle() else {
            self.status_message = Some("no active surface".to_string());
            return;
        };
        if surface.kind() != SurfaceKind::Browser {
            self.status_message = Some("active surface is not a browser".to_string());
            return;
        }
        self.dispatch_browser_control(surface_id, surface, kind);
    }

    fn enqueue_browser_command_for_pane(&mut self, pane: PaneId, kind: BrowserInputKind) {
        match self.browser_surface_for_pane(pane) {
            Ok((surface_id, surface)) => {
                self.dispatch_browser_control(surface_id, surface, kind);
            }
            Err(err) => self.status_message = Some(err.to_string()),
        }
    }

    fn enqueue_browser_command(&mut self, surface_id: SurfaceId, kind: BrowserInputKind) {
        let Some(surface) = self.session.surface(surface_id) else {
            self.status_message = Some("unknown browser surface".to_string());
            return;
        };
        if surface.kind() != SurfaceKind::Browser {
            self.status_message = Some("active surface is not a browser".to_string());
            return;
        }
        self.dispatch_browser_control(surface_id, surface, kind);
    }

    fn browser_copy_url(&mut self, pane: PaneId) {
        let Some(surface_id) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            return;
        };
        let Some(url) = self.session.surface(surface_id).and_then(|surface| surface.browser_url())
        else {
            return;
        };
        self.copy_text_to_clipboard(&url);
        self.show_toast("Copied URL".to_string());
    }

    fn activate_menu(&mut self, action: MenuAction) -> anyhow::Result<()> {
        if menu_action_prepares_pty_release(action) && !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        match action {
            MenuAction::RenameWorkspace(id) => {
                let buffer = self
                    .tree
                    .workspaces
                    .iter()
                    .find(|ws| ws.id == id)
                    .map(|ws| ws.name.clone())
                    .unwrap_or_default();
                self.prompt =
                    Some(Prompt::new("Rename workspace", buffer, PromptTarget::Workspace(id)));
            }
            MenuAction::CloseWorkspace(id) => self.session.close_workspace(id),
            MenuAction::CopyWorkspaceId(id) => {
                if let Some(short_id) =
                    self.tree.workspaces.iter().find(|ws| ws.id == id).map(|ws| ws.short_id.clone())
                {
                    self.copy_short_id(short_id);
                }
            }
            MenuAction::RenameScreen(id) => {
                let buffer = self
                    .tree
                    .workspaces
                    .iter()
                    .flat_map(|ws| ws.screens.iter())
                    .find(|s| s.id == id)
                    .and_then(|s| s.name.clone())
                    .unwrap_or_default();
                self.prompt = Some(Prompt::new("Rename screen", buffer, PromptTarget::Screen(id)));
            }
            MenuAction::CloseScreen(id) => self.session.close_screen(id),
            MenuAction::BrowserBack(id) => {
                self.enqueue_browser_command_for_pane(id, BrowserInputKind::Back);
            }
            MenuAction::BrowserForward(id) => {
                self.enqueue_browser_command_for_pane(id, BrowserInputKind::Forward);
            }
            MenuAction::BrowserReload(id) => {
                self.enqueue_browser_command_for_pane(id, BrowserInputKind::Reload);
            }
            MenuAction::BrowserEditUrl(id) => self.focus_omnibar(id),
            MenuAction::BrowserCopyUrl(id) => self.browser_copy_url(id),
            MenuAction::BrowserActivate(id) => {
                self.enqueue_browser_command_for_pane(id, BrowserInputKind::Activate);
            }
            MenuAction::RenameTab(id) => self.open_rename_tab_prompt(Some(id)),
            MenuAction::CopyTabId(id) => {
                if let Some(short_id) = self
                    .tree
                    .pane(id)
                    .and_then(|pane| pane.tabs.get(pane.active_tab))
                    .map(|tab| tab.short_id.clone())
                {
                    self.copy_short_id(short_id);
                }
            }
            MenuAction::CopyPaneId(id) => {
                if let Some(short_id) = self.tree.pane(id).map(|pane| pane.short_id.clone()) {
                    self.copy_short_id(short_id);
                }
            }
            MenuAction::NewTab(id) => {
                self.new_terminal_tab(Some(id))?;
            }
            MenuAction::NewBrowserTab(id) => self.create_browser_tab_for_edit(Some(id))?,
            MenuAction::SplitRight(id) => self.split_pane(id, SplitDir::Right)?,
            MenuAction::SplitDown(id) => self.split_pane(id, SplitDir::Down)?,
            MenuAction::CloseTab(id) => {
                if let Some(surface) = self.tree.pane(id).and_then(|p| p.active_surface()) {
                    self.render_states.remove(&surface);
                    self.session.close_surface(surface);
                }
            }
            MenuAction::ClosePane(id) => self.session.close_pane(id),
            MenuAction::SetClientSizing { client, enabled } => {
                self.session.set_client_sizing(client, enabled);
            }
            MenuAction::UseClientSize(client) => {
                self.session.use_only_client_sizing(client);
            }
            MenuAction::RestoreAllClientSizing => {
                self.session.use_all_client_sizing();
            }
            MenuAction::DisconnectClient(client) => {
                if self.clients.iter().any(|info| info.client == client && info.is_self) {
                    // Disconnecting this control connection would close the socket that must
                    // carry the response. Exit through the same local detach lifecycle as the
                    // keyboard action instead, without another request on that socket.
                    self.run_action(Action::Detach)?;
                } else {
                    // Peer disconnects stay ordered with PTY input but run off the UI thread.
                    // A stale client id therefore becomes a harmless no-op instead of blocking
                    // or terminating the event loop.
                    self.session.disconnect_client(client);
                }
            }
        }
        Ok(())
    }

    fn move_focus(&mut self, direction: Direction) {
        let Some(screen) = self.tree.active_screen() else { return };
        if screen.zoomed_pane.is_some() {
            return;
        }
        let active = screen.active_pane;
        let (dx, dy) = match direction {
            Direction::Left => (-1, 0),
            Direction::Right => (1, 0),
            Direction::Up => (0, -1),
            Direction::Down => (0, 1),
        };
        let layout = cmux_tui_core::LayoutResult {
            panes: self.pane_areas.iter().map(|area| (area.pane, area.rect)).collect(),
            ..Default::default()
        };
        if let Some(next) =
            layout.neighbor_by_recency(active, dx, dy, |pane| self.pane_focus_history.recency(pane))
        {
            self.focus_pane_after_input(next);
        }
    }

    fn active_screen_pane_order(&self) -> Vec<PaneId> {
        self.tree
            .active_screen()
            .map(|screen| screen.panes.iter().map(|pane| pane.id).collect())
            .unwrap_or_default()
    }

    fn adjacent_pane_by_order(&self, delta: isize) -> Option<PaneId> {
        let active = self.active_pane()?;
        let panes = self.active_screen_pane_order();
        let position = panes.iter().position(|pane| *pane == active)?;
        let len = panes.len();
        if len < 2 {
            return None;
        }
        let next = (position as isize + delta).rem_euclid(len as isize) as usize;
        panes.get(next).copied()
    }

    fn focus_next_pane(&mut self) {
        if let Some(next) = self.adjacent_pane_by_order(1) {
            self.focus_pane_after_input(next);
        }
    }

    fn swap_pane_by_order(&mut self, delta: isize) {
        let Some(active) = self.active_pane() else { return };
        if let Some(target) = self.adjacent_pane_by_order(delta)
            && self.prepare_pty_input_before_mutation()
        {
            self.session.swap_pane(active, target);
        }
    }

    fn scroll_active(&mut self, delta: isize) {
        if let Some(surface) = self.active_surface_handle() {
            if surface.kind() == SurfaceKind::Browser {
                return;
            }
            let _ = surface.scroll_delta(delta);
        }
    }

    fn toggle_sidebar_focus(&mut self) {
        if self.sidebar_focused {
            self.sidebar_focused = false;
            self.sidebar_focus_pending = false;
            return;
        }
        if self.sidebar_focus_pending {
            self.sidebar_focus_pending = false;
            return;
        }
        self.sidebar_visible = true;
        let requested = self.config.sidebar.plugin.is_some() && self.sync_sidebar_plugin(true);
        if self.config.sidebar.plugin.is_none() || self.sidebar_plugin_surface.is_some() {
            self.sidebar_focused = true;
            if self.config.sidebar.plugin.is_none() {
                if self.sidebar_view == SidebarView::Workspaces {
                    self.sidebar_workspace_selection = self.tree.active_workspace;
                } else if !self.sync_sidebar_files_to_focus(true) {
                    self.sidebar_files.refresh();
                }
            }
            self.menu = None;
            self.prompt = None;
            self.omnibar = None;
            self.selection = None;
        } else if requested {
            self.sidebar_focus_pending = true;
        }
    }

    fn toggle_sidebar_view(&mut self) {
        self.sidebar_view = self.sidebar_view.toggled();
        if self.config.sidebar.plugin.is_some() {
            return;
        }
        match self.sidebar_view {
            SidebarView::Files => {
                self.sidebar_followed_surface = None;
                if !self.sync_sidebar_files_to_focus(true) {
                    self.sidebar_files.refresh();
                }
            }
            SidebarView::Workspaces => {
                self.sidebar_workspace_selection = self.tree.active_workspace;
            }
        }
    }

    fn sidebar_surface_handle(&self) -> Option<SurfaceHandle> {
        self.sidebar_plugin_surface.and_then(|surface| self.session.surface(surface))
    }

    fn forward_key(&mut self, key: &KeyEvent) {
        if self
            .active_surface_handle()
            .is_some_and(|surface| surface.kind() == SurfaceKind::Browser)
        {
            self.forward_browser_key(key);
            return;
        }
        let Some(input) = keys::key_input_from(key) else { return };
        let Some((surface_id, surface)) = self.active_surface_with_handle() else { return };
        self.encode_buf.clear();
        let _ = surface.scroll_to_bottom();
        let Some(encoded) = surface.with_terminal(|term| {
            self.encoder.sync_from_terminal(term);
            self.encoder.encode(&input, &mut self.encode_buf)
        }) else {
            return;
        };
        if encoded.is_ok() && !self.encode_buf.is_empty() {
            let _ = self.write_encoded_pty_bytes(surface_id, surface, PtyInputKind::Ordered);
        }
    }

    fn forward_sidebar_key(&mut self, key: &KeyEvent) {
        let Some(input) = keys::key_input_from(key) else { return };
        let Some(surface_id) = self.sidebar_plugin_surface else { return };
        let Some(surface) = self.sidebar_surface_handle() else { return };
        self.encode_buf.clear();
        let _ = surface.scroll_to_bottom();
        let Some(encoded) = surface.with_terminal(|term| {
            self.encoder.sync_from_terminal(term);
            self.encoder.encode(&input, &mut self.encode_buf)
        }) else {
            return;
        };
        if encoded.is_ok() && !self.encode_buf.is_empty() {
            let _ = self.write_encoded_pty_bytes(surface_id, surface, PtyInputKind::Ordered);
        }
    }

    fn forward_browser_key(&mut self, key: &KeyEvent) {
        if matches!(key.code, KeyCode::Char('l') | KeyCode::Char('L'))
            && key.modifiers.contains(KeyModifiers::CONTROL)
        {
            if let Some(pane) = self.active_pane() {
                self.focus_omnibar(pane);
            }
            return;
        }
        let Some((surface_id, surface)) = self.active_surface_with_handle() else { return };
        if let KeyCode::Char(c) = key.code
            && !key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER)
        {
            let _ = self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: BrowserInputKind::InsertText(c.to_string()),
            });
            return;
        }
        let Some((key_name, code, vk, text)) = browser_key_mapping(key.code) else { return };
        let modifiers = browser_modifiers(key.modifiers);
        let key_event =
            |event_type: &'static str, text: Option<&'static str>| BrowserInputKind::Key {
                event_type,
                key: key_name,
                code,
                windows_virtual_key_code: vk,
                modifiers,
                text,
            };
        let _ = self.browser_input.enqueue(BrowserInputEvent {
            surface_id,
            surface: surface.clone(),
            kind: key_event("keyDown", text),
        });
        if key.kind == KeyEventKind::Press {
            let _ = self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: key_event("keyUp", None),
            });
        }
    }

    fn paste(&mut self, text: &str) {
        let Some((surface_id, surface)) = self.active_surface_with_handle() else { return };
        if surface.kind() == SurfaceKind::Browser {
            let _ = self.browser_input.enqueue(BrowserInputEvent {
                surface_id,
                surface,
                kind: BrowserInputKind::InsertText(text.to_string()),
            });
            return;
        }
        let Some(bracketed) = surface.with_terminal(|t| t.mode(2004, false)) else {
            return;
        };
        if bracketed {
            let mut bytes = Vec::with_capacity(text.len() + 12);
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(text.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            let _ = self.write_pty_bytes(surface_id, surface, bytes.into(), PtyInputKind::Ordered);
        } else {
            let _ = self.write_pty_bytes(
                surface_id,
                surface,
                PtyInputBytes::from_slice(text.as_bytes()),
                PtyInputKind::Ordered,
            );
        }
    }

    fn paste_sidebar(&mut self, text: &str) {
        let Some(surface_id) = self.sidebar_plugin_surface else { return };
        let Some(surface) = self.sidebar_surface_handle() else { return };
        let Some(bracketed) = surface.with_terminal(|t| t.mode(2004, false)) else {
            return;
        };
        if bracketed {
            let mut bytes = Vec::with_capacity(text.len() + 12);
            bytes.extend_from_slice(b"\x1b[200~");
            bytes.extend_from_slice(text.as_bytes());
            bytes.extend_from_slice(b"\x1b[201~");
            let _ = self.write_pty_bytes(surface_id, surface, bytes.into(), PtyInputKind::Ordered);
        } else {
            let _ = self.write_pty_bytes(
                surface_id,
                surface,
                PtyInputBytes::from_slice(text.as_bytes()),
                PtyInputKind::Ordered,
            );
        }
    }

    fn pane_area_at(&self, x: u16, y: u16) -> Option<&PaneArea> {
        self.pane_areas.iter().find(|a| a.rect.contains(x, y))
    }

    fn hit_at(&self, x: u16, y: u16) -> Option<Hit> {
        self.hits.iter().find(|(rect, _)| rect.contains(x, y)).map(|(_, hit)| *hit)
    }

    fn omnibar_hit_at(&self, x: u16, y: u16) -> Option<(PaneId, OmnibarHit)> {
        self.pane_areas.iter().find_map(|area| {
            let rect = area.omnibar?;
            if self.surface_kind(area.surface) != Some(SurfaceKind::Browser) {
                return None;
            }
            let editing = self
                .omnibar
                .as_ref()
                .is_some_and(|state| state.pane == area.pane && state.surface == area.surface);
            crate::ui::omnibar::hit(rect, x, y, editing).map(|hit| (area.pane, hit))
        })
    }

    fn tab_drop_target_at(&self, x: u16, y: u16) -> Option<(PaneId, usize)> {
        let area = self.pane_areas.iter().find(|area| {
            area.bar.is_some_and(|bar| bar.contains(x, y)) || area.content.contains(x, y)
        })?;
        let pane = self.tree.pane(area.pane)?;
        let len = pane.tabs.len();
        if !area.bar.is_some_and(|bar| bar.contains(x, y)) {
            return Some((area.pane, len));
        }
        let mut tab_hits = self
            .hits
            .iter()
            .filter_map(|(rect, hit)| match hit {
                Hit::Tab { pane, index } if *pane == area.pane => Some((*rect, *index)),
                _ => None,
            })
            .collect::<Vec<_>>();
        tab_hits.sort_by_key(|(rect, index)| (rect.x, *index));
        for (rect, index) in &tab_hits {
            let mid = rect.x + rect.width / 2;
            if x < mid {
                return Some((area.pane, (*index).min(len)));
            }
            if rect.contains(x, y) {
                return Some((area.pane, (index + 1).min(len)));
            }
        }
        Some((area.pane, len))
    }

    fn workspace_drop_target_at(&self, x: u16, y: u16) -> Option<usize> {
        if self.sidebar_width < 3 || x >= self.sidebar_width.saturating_sub(1) {
            return None;
        }
        let len = self.tree.workspaces.len();
        for index in 0..len {
            let start = 2 + index as u16 * 3;
            if y < start {
                return Some(index);
            }
            if y <= start + 1 {
                return Some(if y == start { index } else { index + 1 }.min(len));
            }
        }
        Some(len)
    }

    fn tab_location(&self, surface: SurfaceId) -> Option<(PaneId, usize)> {
        self.tree
            .workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .find_map(|pane| {
                pane.tabs
                    .iter()
                    .position(|tab| tab.surface == surface)
                    .map(|index| (pane.id, index))
            })
    }

    fn workspace_index(&self, workspace: WorkspaceId) -> Option<usize> {
        self.tree.workspaces.iter().position(|ws| ws.id == workspace)
    }

    fn handle_mouse(&mut self, mouse: MouseEvent) -> anyhow::Result<RenderAction> {
        // This TUI tracks one active pointer button. Ignore additional presses
        // until its release so a second button cannot orphan the inner app's
        // pressed state.
        if let MouseEventKind::Down(button) = mouse.kind
            && let Some(Drag::PtyMouse { button: active, .. }) = &self.drag
        {
            if button != *active {
                self.ignored_pty_mouse_buttons.insert(button);
            }
            return Ok(RenderAction::None);
        }
        match mouse.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                self.handle_left_down(mouse.column, mouse.row, mouse.modifiers)
            }
            MouseEventKind::Drag(MouseButton::Left) => {
                if self.forward_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Left,
                    mouse.modifiers,
                ) {
                    Ok(RenderAction::None)
                } else {
                    self.handle_left_drag(mouse.column, mouse.row)
                }
            }
            MouseEventKind::Up(MouseButton::Left) => {
                if self.finish_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Left,
                    mouse.modifiers,
                ) {
                    Ok(RenderAction::Draw)
                } else {
                    self.handle_left_up(mouse.column, mouse.row)
                }
            }
            MouseEventKind::Down(MouseButton::Right) => {
                if self.prompt.is_some() {
                    self.shake_frames = 6;
                    return Ok(RenderAction::Draw);
                }
                if self.begin_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Right,
                    mouse.modifiers,
                ) != PtyMousePressResult::NotOwned
                {
                    return Ok(RenderAction::Draw);
                }
                self.open_context_menu(mouse.column, mouse.row);
                Ok(RenderAction::Draw)
            }
            MouseEventKind::Drag(MouseButton::Right) => {
                if self.forward_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Right,
                    mouse.modifiers,
                ) {
                    Ok(RenderAction::None)
                } else {
                    self.handle_right_drag(mouse.column, mouse.row)
                }
            }
            MouseEventKind::Up(MouseButton::Right) => {
                if self.finish_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Right,
                    mouse.modifiers,
                ) {
                    Ok(RenderAction::Draw)
                } else {
                    self.handle_right_up(mouse.column, mouse.row)
                }
            }
            MouseEventKind::Down(MouseButton::Middle) => Ok(
                if self.begin_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Middle,
                    mouse.modifiers,
                ) != PtyMousePressResult::NotOwned
                {
                    RenderAction::Draw
                } else {
                    RenderAction::None
                },
            ),
            MouseEventKind::Drag(MouseButton::Middle) => {
                self.forward_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Middle,
                    mouse.modifiers,
                );
                Ok(RenderAction::None)
            }
            MouseEventKind::Up(MouseButton::Middle) => Ok(
                if self.finish_pty_mouse_drag(
                    mouse.column,
                    mouse.row,
                    MouseButton::Middle,
                    mouse.modifiers,
                ) {
                    RenderAction::Draw
                } else {
                    RenderAction::None
                },
            ),
            MouseEventKind::Moved => self.handle_hover(mouse.column, mouse.row, mouse.modifiers),
            MouseEventKind::ScrollUp | MouseEventKind::ScrollDown => {
                let down = matches!(mouse.kind, MouseEventKind::ScrollDown);
                self.handle_scroll(mouse.column, mouse.row, down, mouse.modifiers)
            }
            MouseEventKind::ScrollLeft | MouseEventKind::ScrollRight => self
                .handle_horizontal_scroll(
                    mouse.column,
                    mouse.row,
                    matches!(mouse.kind, MouseEventKind::ScrollRight),
                    mouse.modifiers,
                ),
        }
    }

    fn begin_pty_mouse_drag(
        &mut self,
        x: u16,
        y: u16,
        button: MouseButton,
        modifiers: KeyModifiers,
    ) -> PtyMousePressResult {
        if modifiers.contains(KeyModifiers::SHIFT)
            || self.menu.is_some()
            || self.prompt.is_some()
            || self.drag.is_some()
        {
            return PtyMousePressResult::NotOwned;
        }
        let Some(area) = self.pane_area_at(x, y).copied() else {
            return PtyMousePressResult::NotOwned;
        };
        if !area.content.contains(x, y) || self.surface_kind(area.surface) != Some(SurfaceKind::Pty)
        {
            return PtyMousePressResult::NotOwned;
        }
        let Some(content) = self.terminal_input_rect(&area) else {
            return PtyMousePressResult::NotOwned;
        };
        if !content.contains(x, y) {
            return PtyMousePressResult::NotOwned;
        }
        let Some(handle) = self.session.surface(area.surface) else {
            return PtyMousePressResult::Consumed;
        };
        let (release_capture, forwarded) = self.prepare_pty_mouse_press(
            (area.surface, handle.clone()),
            content,
            x,
            y,
            button,
            modifiers,
        );
        if !forwarded.owned {
            return PtyMousePressResult::NotOwned;
        }
        if self.active_pane() != Some(area.pane) {
            self.focus_pane_after_input(area.pane);
        }
        self.sidebar_focused = false;
        self.selection = None;
        if matches!(release_capture, PtyMouseReleaseCapture::Failed) {
            return PtyMousePressResult::Consumed;
        }
        if !forwarded.accepted {
            return PtyMousePressResult::Consumed;
        }
        let Some(reservation_id) = forwarded.reservation_id else {
            return PtyMousePressResult::Consumed;
        };
        let PtyMouseReleaseCapture::Bytes(release_bytes) = release_capture else {
            self.pty_input.cancel_release_reservation(reservation_id);
            return PtyMousePressResult::Consumed;
        };
        self.drag = Some(Drag::PtyMouse {
            surface: area.surface,
            handle: Some(handle),
            reservation_id,
            release_bytes,
            content,
            button,
            position: (x, y),
            modifiers,
        });
        self.ignored_pty_mouse_buttons.clear();
        PtyMousePressResult::Started
    }

    fn prepare_pty_mouse_press(
        &mut self,
        route: (SurfaceId, SurfaceHandle),
        content: Rect,
        x: u16,
        y: u16,
        button: MouseButton,
        modifiers: KeyModifiers,
    ) -> (PtyMouseReleaseCapture, PtyInputForwardResult) {
        let (surface_id, surface) = route;
        let failed =
            || PtyInputForwardResult { owned: true, accepted: false, reservation_id: None };
        let cell_width = u32::from(self.cell_pixels.0.max(1));
        let cell_height = u32::from(self.cell_pixels.1.max(1));
        let position = (
            (x as f32 - content.x as f32 + 0.5) * cell_width as f32,
            (y as f32 - content.y as f32 + 0.5) * cell_height as f32,
        );
        let screen_size = (
            u32::from(content.width).saturating_mul(cell_width),
            u32::from(content.height).saturating_mul(cell_height),
        );
        let press = MouseInput {
            action: MouseAction::Press,
            button: Some(Self::ghostty_mouse_button(button)),
            mods: Self::ghostty_mouse_mods(modifiers),
            position,
            screen_size,
            cell_size: (cell_width, cell_height),
            any_button_pressed: true,
        };
        let release =
            MouseInput { action: MouseAction::Release, any_button_pressed: false, ..press };
        let mut release_output = Vec::new();
        let mut press_output = Vec::new();
        let Some(encoded) =
            surface.encode_mouse_press_pair(press, release, &mut press_output, &mut release_output)
        else {
            return (PtyMouseReleaseCapture::Failed, failed());
        };
        self.encode_buf = press_output;
        if encoded.is_err() {
            return (PtyMouseReleaseCapture::Failed, failed());
        }
        let release_capture = if release_output.is_empty() {
            PtyMouseReleaseCapture::NotReported
        } else {
            PtyMouseReleaseCapture::Bytes(PtyInputBytes::from_slice(&release_output))
        };
        if self.encode_buf.is_empty() {
            return (
                release_capture,
                PtyInputForwardResult { owned: false, accepted: true, reservation_id: None },
            );
        }
        let kind = if matches!(release_capture, PtyMouseReleaseCapture::Bytes(_)) {
            PtyInputKind::Press
        } else {
            PtyInputKind::Ordered
        };
        let bytes = PtyInputBytes::from_slice(&self.encode_buf);
        let forwarded = self.enqueue_pty_bytes(surface_id, surface, bytes, kind);
        (release_capture, forwarded)
    }

    fn forward_pty_mouse_drag(
        &mut self,
        x: u16,
        y: u16,
        _reported_button: MouseButton,
        modifiers: KeyModifiers,
    ) -> bool {
        let Some(Drag::PtyMouse { surface, content, button: active_button, .. }) = self.drag else {
            return false;
        };
        // Some host protocols report a drag as left regardless of the
        // pressed button. This TUI owns one active button, so it is authoritative.
        if self.menu.is_some() || self.prompt.is_some() {
            self.cancel_pty_mouse_drag();
            return true;
        }
        let content = self.current_pty_content(surface).unwrap_or(content);
        if let Some(Drag::PtyMouse { position, modifiers: stored_modifiers, .. }) = &mut self.drag {
            *position = (x, y);
            *stored_modifiers = modifiers;
        }
        let _ = self.forward_pty_mouse_motion_if_uncontended(
            surface,
            content,
            (x, y),
            Some(Self::ghostty_mouse_button(active_button)),
            modifiers,
            true,
        );
        true
    }

    fn finish_pty_mouse_drag(
        &mut self,
        x: u16,
        y: u16,
        reported_button: MouseButton,
        modifiers: KeyModifiers,
    ) -> bool {
        let Some(Drag::PtyMouse {
            surface,
            handle,
            reservation_id,
            release_bytes,
            content,
            button,
            ..
        }) = &self.drag
        else {
            return false;
        };
        let (surface, handle, reservation_id, fallback, content, button) =
            (*surface, handle.clone(), *reservation_id, release_bytes.clone(), *content, *button);
        if reported_button != button {
            self.ignored_pty_mouse_buttons.remove(&reported_button);
            return true;
        }
        let content = self.current_pty_content(surface).unwrap_or(content);
        let release = self.capture_pty_mouse_release(surface, content, x, y, button, modifiers);
        self.drag = None;
        self.ignored_pty_mouse_buttons.clear();
        match release {
            PtyMouseReleaseCapture::Bytes(bytes) => {
                if !self.enqueue_pty_release(surface, handle, reservation_id, bytes) {
                    self.pty_input.cancel_release_reservation(reservation_id);
                }
            }
            PtyMouseReleaseCapture::Failed | PtyMouseReleaseCapture::NotReported => {
                if !self.enqueue_pty_release(surface, handle, reservation_id, fallback) {
                    self.pty_input.cancel_release_reservation(reservation_id);
                }
            }
        }
        true
    }

    fn capture_pty_mouse_release(
        &mut self,
        surface_id: SurfaceId,
        content: Rect,
        x: u16,
        y: u16,
        button: MouseButton,
        modifiers: KeyModifiers,
    ) -> PtyMouseReleaseCapture {
        let Some(surface) = self.session.surface(surface_id) else {
            return PtyMouseReleaseCapture::Failed;
        };
        let cell_width = u32::from(self.cell_pixels.0.max(1));
        let cell_height = u32::from(self.cell_pixels.1.max(1));
        let input = MouseInput {
            action: MouseAction::Release,
            button: Some(Self::ghostty_mouse_button(button)),
            mods: Self::ghostty_mouse_mods(modifiers),
            position: (
                (x as f32 - content.x as f32 + 0.5) * cell_width as f32,
                (y as f32 - content.y as f32 + 0.5) * cell_height as f32,
            ),
            screen_size: (
                u32::from(content.width).saturating_mul(cell_width),
                u32::from(content.height).saturating_mul(cell_height),
            ),
            cell_size: (cell_width, cell_height),
            any_button_pressed: false,
        };
        let mut output = Vec::new();
        let Some(encoded) = surface.encode_mouse_release(input, &mut output) else {
            return PtyMouseReleaseCapture::Failed;
        };
        match encoded {
            Ok(()) if output.is_empty() => PtyMouseReleaseCapture::NotReported,
            Ok(()) => PtyMouseReleaseCapture::Bytes(PtyInputBytes::from_slice(&output)),
            Err(_) => PtyMouseReleaseCapture::Failed,
        }
    }

    fn enqueue_pty_release(
        &mut self,
        surface_id: SurfaceId,
        retained: Option<SurfaceHandle>,
        reservation_id: u64,
        bytes: PtyInputBytes,
    ) -> bool {
        let Some(surface) = retained.or_else(|| self.session.surface(surface_id)) else {
            return false;
        };
        self.encode_buf.clear();
        self.encode_buf.extend_from_slice(bytes.as_ref());
        let (result, _) = self.pty_input.enqueue_with_reservation(PtyInputEvent::release(
            surface_id,
            surface,
            bytes,
            reservation_id,
        ));
        self.handle_pty_enqueue_result(result)
    }

    fn cancel_pty_mouse_drag(&mut self) {
        let Some(Drag::PtyMouse {
            surface,
            handle,
            reservation_id,
            release_bytes,
            content,
            button,
            position,
            modifiers,
        }) = &self.drag
        else {
            return;
        };
        let (surface, handle, reservation_id, fallback, content, button, position, modifiers) = (
            *surface,
            handle.clone(),
            *reservation_id,
            release_bytes.clone(),
            *content,
            *button,
            *position,
            *modifiers,
        );
        let content = self.current_pty_content(surface).unwrap_or(content);
        let release = self
            .capture_pty_mouse_release(surface, content, position.0, position.1, button, modifiers);
        self.drag = None;
        self.ignored_pty_mouse_buttons.clear();
        match release {
            PtyMouseReleaseCapture::Bytes(bytes) => {
                if !self.enqueue_pty_release(surface, handle, reservation_id, bytes) {
                    self.pty_input.cancel_release_reservation(reservation_id);
                }
            }
            PtyMouseReleaseCapture::Failed | PtyMouseReleaseCapture::NotReported => {
                if !self.enqueue_pty_release(surface, handle, reservation_id, fallback) {
                    self.pty_input.cancel_release_reservation(reservation_id);
                }
            }
        }
    }

    fn forward_pty_mouse_at(
        &mut self,
        x: u16,
        y: u16,
        action: MouseAction,
        button: Option<GhosttyMouseButton>,
        modifiers: KeyModifiers,
        any_button_pressed: bool,
    ) -> bool {
        if modifiers.contains(KeyModifiers::SHIFT) || self.menu.is_some() || self.prompt.is_some() {
            return false;
        }
        let Some(area) = self.pane_area_at(x, y).copied() else { return false };
        if !area.content.contains(x, y) || self.surface_kind(area.surface) != Some(SurfaceKind::Pty)
        {
            return false;
        }
        let Some(content) = self.terminal_input_rect(&area) else { return false };
        if !content.contains(x, y) {
            return false;
        }
        if action == MouseAction::Motion {
            return self.forward_pty_mouse_motion_if_uncontended(
                area.surface,
                content,
                (x, y),
                None,
                modifiers,
                any_button_pressed,
            );
        }
        self.forward_pty_mouse_to_surface(
            area.surface,
            content,
            x,
            y,
            action,
            button,
            modifiers,
            any_button_pressed,
        )
        .owned
    }

    fn forward_pty_mouse_motion_if_uncontended(
        &mut self,
        surface_id: SurfaceId,
        content: Rect,
        position: (u16, u16),
        button: Option<GhosttyMouseButton>,
        modifiers: KeyModifiers,
        any_button_pressed: bool,
    ) -> bool {
        let Some(surface) = self.session.surface(surface_id) else { return false };
        let (x, y) = position;
        let cell_width = u32::from(self.cell_pixels.0.max(1));
        let cell_height = u32::from(self.cell_pixels.1.max(1));
        let input = MouseInput {
            action: MouseAction::Motion,
            button,
            mods: Self::ghostty_mouse_mods(modifiers),
            position: (
                (x as f32 - content.x as f32 + 0.5) * cell_width as f32,
                (y as f32 - content.y as f32 + 0.5) * cell_height as f32,
            ),
            screen_size: (
                u32::from(content.width).saturating_mul(cell_width),
                u32::from(content.height).saturating_mul(cell_height),
            ),
            cell_size: (cell_width, cell_height),
            any_button_pressed,
        };

        let mut output = Vec::new();
        let Some(encoded) = surface.encode_mouse(input, &mut output) else {
            // The first sample can race terminal initialization. Motion is
            // coalescible, so consume it without parking the UI loop.
            return true;
        };
        self.encode_buf = output;
        if encoded.is_err() {
            return true;
        }
        if self.encode_buf.is_empty() {
            return false;
        }
        let _ = self.write_encoded_pty_bytes(surface_id, surface, PtyInputKind::Motion);
        true
    }

    #[allow(clippy::too_many_arguments)]
    fn forward_pty_mouse_to_surface(
        &mut self,
        surface_id: SurfaceId,
        content: Rect,
        x: u16,
        y: u16,
        action: MouseAction,
        button: Option<GhosttyMouseButton>,
        modifiers: KeyModifiers,
        any_button_pressed: bool,
    ) -> PtyInputForwardResult {
        let Some(surface) = self.session.surface(surface_id) else {
            return PtyInputForwardResult { owned: false, accepted: false, reservation_id: None };
        };
        let cell_width = u32::from(self.cell_pixels.0.max(1));
        let cell_height = u32::from(self.cell_pixels.1.max(1));
        let position = (
            (x as f32 - content.x as f32 + 0.5) * cell_width as f32,
            (y as f32 - content.y as f32 + 0.5) * cell_height as f32,
        );
        let input = MouseInput {
            action,
            button,
            mods: Self::ghostty_mouse_mods(modifiers),
            position,
            screen_size: (
                u32::from(content.width).saturating_mul(cell_width),
                u32::from(content.height).saturating_mul(cell_height),
            ),
            cell_size: (cell_width, cell_height),
            any_button_pressed,
        };

        let mut output = Vec::new();
        let Some(encoded) = surface.encode_mouse(input, &mut output) else {
            return PtyInputForwardResult { owned: true, accepted: false, reservation_id: None };
        };
        self.encode_buf = output;
        if encoded.is_err() {
            return PtyInputForwardResult { owned: true, accepted: false, reservation_id: None };
        }
        if self.encode_buf.is_empty() {
            if action == MouseAction::Release {
                self.cancel_pty_release_reservation();
            }
            return PtyInputForwardResult { owned: false, accepted: true, reservation_id: None };
        }
        let kind = match action {
            MouseAction::Press
                if matches!(
                    button,
                    Some(
                        GhosttyMouseButton::Left
                            | GhosttyMouseButton::Right
                            | GhosttyMouseButton::Middle
                    )
                ) =>
            {
                PtyInputKind::Press
            }
            MouseAction::Press => PtyInputKind::Ordered,
            MouseAction::Release => PtyInputKind::Release,
            MouseAction::Motion => PtyInputKind::Motion,
        };
        let mut forwarded = self.write_encoded_pty_bytes(surface_id, surface, kind);
        forwarded.owned = true;
        forwarded
    }

    fn write_encoded_pty_bytes(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        kind: PtyInputKind,
    ) -> PtyInputForwardResult {
        let bytes = PtyInputBytes::from_slice(&self.encode_buf);
        self.enqueue_pty_bytes(surface_id, surface, bytes, kind)
    }

    fn write_pty_bytes(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        bytes: PtyInputBytes,
        kind: PtyInputKind,
    ) -> bool {
        self.enqueue_pty_bytes(surface_id, surface, bytes, kind).accepted
    }

    fn enqueue_pty_bytes(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        bytes: PtyInputBytes,
        kind: PtyInputKind,
    ) -> PtyInputForwardResult {
        let (result, reservation_id) = self
            .pty_input
            .enqueue_with_reservation(PtyInputEvent::input(surface_id, surface, bytes, kind));
        self.rollback_mouse_motion_for_enqueue_failure(surface_id, kind, result);
        PtyInputForwardResult {
            owned: true,
            accepted: self.handle_pty_enqueue_result(result),
            reservation_id,
        }
    }

    fn rollback_mouse_motion_for_enqueue_failure(
        &mut self,
        surface_id: SurfaceId,
        kind: PtyInputKind,
        result: PtyInputEnqueueResult,
    ) {
        if kind == PtyInputKind::Motion
            && matches!(result, PtyInputEnqueueResult::Saturated | PtyInputEnqueueResult::Failed)
            && let Some(surface) = self.session.surface(surface_id)
        {
            surface.reset_mouse_motion_dedupe();
        }
    }

    fn handle_pty_enqueue_result(&mut self, result: PtyInputEnqueueResult) -> bool {
        match result {
            PtyInputEnqueueResult::Accepted => true,
            PtyInputEnqueueResult::Oversized => {
                self.status_message = Some("Input exceeds the 4 MiB PTY buffer limit".to_string());
                false
            }
            PtyInputEnqueueResult::Saturated => {
                self.status_message =
                    Some("PTY input queue is full; input was not sent".to_string());
                false
            }
            PtyInputEnqueueResult::Failed => {
                self.status_message =
                    Some("PTY input is unavailable after a transport failure".to_string());
                false
            }
        }
    }

    fn prepare_pty_input_before_mutation(&mut self) -> bool {
        self.cancel_pty_mouse_drag();
        !matches!(self.drag, Some(Drag::PtyMouse { .. }))
    }

    fn focus_pane_after_input(&mut self, pane: PaneId) {
        if self.prepare_pty_input_before_mutation() {
            let focused = if self.session.remote
                && let Some(screen) = self.tree.active_workspace_mut_screen()
                && screen.panes.iter().any(|candidate| candidate.id == pane)
            {
                screen.active_pane = pane;
                true
            } else if !self.session.remote {
                self.session.focus_pane(pane);
                true
            } else {
                false
            };
            if focused {
                self.pane_focus_history.record(pane);
            }
        }
    }

    fn select_tab_for_client(
        &mut self,
        pane: Option<PaneId>,
        index: Option<usize>,
        delta: Option<isize>,
    ) {
        let pane = pane.or_else(|| self.active_pane());
        if self.session.remote
            && let Some(pane_id) = pane
            && let Some(pane) = self.tree.pane_mut(pane_id)
            && !pane.tabs.is_empty()
        {
            if let Some(index) = index.filter(|index| *index < pane.tabs.len()) {
                pane.active_tab = index;
            } else if let Some(delta) = delta {
                pane.active_tab = ((pane.active_tab as isize + delta)
                    .rem_euclid(pane.tabs.len() as isize))
                    as usize;
            }
        }
        if !self.session.remote {
            self.session.select_tab(pane, index, delta);
        }
    }

    fn select_screen_for_client(&mut self, index: Option<usize>, delta: Option<isize>) {
        let mut selected = false;
        if self.session.remote
            && let Some(workspace) = self.tree.active_workspace_mut()
            && !workspace.screens.is_empty()
        {
            if let Some(index) = index.filter(|index| *index < workspace.screens.len()) {
                workspace.active_screen = index;
                selected = true;
            } else if let Some(delta) = delta {
                workspace.active_screen = ((workspace.active_screen as isize + delta)
                    .rem_euclid(workspace.screens.len() as isize))
                    as usize;
                selected = true;
            }
        }
        if selected && let Some(active) = self.active_pane() {
            self.pane_focus_history.record(active);
        }
        if !self.session.remote {
            self.session.select_screen(index, delta);
        }
    }

    fn select_workspace_for_client(&mut self, index: Option<usize>, delta: Option<isize>) {
        let mut selected = false;
        if self.session.remote && !self.tree.workspaces.is_empty() {
            if let Some(index) = index.filter(|index| *index < self.tree.workspaces.len()) {
                self.tree.active_workspace = index;
                selected = true;
            } else if let Some(delta) = delta {
                self.tree.active_workspace = ((self.tree.active_workspace as isize + delta)
                    .rem_euclid(self.tree.workspaces.len() as isize))
                    as usize;
                selected = true;
            }
        }
        if selected && let Some(active) = self.active_pane() {
            self.pane_focus_history.record(active);
        }
        if !self.session.remote {
            self.session.select_workspace(index, delta);
        }
    }

    fn terminal_input_rect(&self, area: &PaneArea) -> Option<Rect> {
        self.rendered_terminal_bounds.get(&area.surface).copied()
    }

    fn current_pty_content(&self, surface: SurfaceId) -> Option<Rect> {
        self.pane_areas
            .iter()
            .find(|area| area.surface == surface)
            .and_then(|area| self.terminal_input_rect(area))
    }

    fn cancel_pty_release_reservation(&self) {
        if let Some(Drag::PtyMouse { reservation_id, .. }) = &self.drag {
            self.pty_input.cancel_release_reservation(*reservation_id);
        }
    }

    fn ghostty_mouse_button(button: MouseButton) -> GhosttyMouseButton {
        match button {
            MouseButton::Left => GhosttyMouseButton::Left,
            MouseButton::Right => GhosttyMouseButton::Right,
            MouseButton::Middle => GhosttyMouseButton::Middle,
        }
    }

    fn ghostty_mouse_mods(modifiers: KeyModifiers) -> Mods {
        let mut mods = Mods::default();
        if modifiers.contains(KeyModifiers::SHIFT) {
            mods = mods | Mods::SHIFT;
        }
        if modifiers.contains(KeyModifiers::CONTROL) {
            mods = mods | Mods::CTRL;
        }
        if modifiers.contains(KeyModifiers::ALT) {
            mods = mods | Mods::ALT;
        }
        if modifiers.contains(KeyModifiers::SUPER) {
            mods = mods | Mods::SUPER;
        }
        mods
    }

    /// Whether the cell is over something clickable (any hit, a menu row,
    /// or a dialog button): these render the hand pointer.
    fn is_clickable(&self, x: u16, y: u16) -> bool {
        if let Some(dialog) = &self.pairing_dialog {
            return dialog.approve.contains(x, y) || dialog.deny.contains(x, y);
        }
        if let Some(prompt) = &self.prompt {
            return prompt.ok.contains(x, y)
                || prompt.cancel.contains(x, y)
                || prompt.clear.contains(x, y)
                || prompt.input_rect.contains(x, y);
        }
        if let Some(menu) = &self.menu {
            // Everything inside the menu rect is menu territory: only item
            // rows are clickable; border cells never inherit clickability
            // from hits underneath.
            if menu.contains(x, y) {
                return menu.hit_at(x, y).is_some();
            }
        }
        if self.omnibar_hit_at(x, y).is_some() {
            return true;
        }
        self.hit_at(x, y).is_some()
    }

    /// Keep the terminal's mouse pointer shape in sync: a hand over
    /// clickable UI, the default elsewhere (OSC 22; terminals without
    /// support ignore it).
    fn sync_pointer_shape(&mut self, x: u16, y: u16) {
        let want_pointer = self.is_clickable(x, y);
        if want_pointer == self.pointer_shape {
            return;
        }
        self.pointer_shape = want_pointer;
        let shape = if want_pointer { "pointer" } else { "default" };
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock().unwrap();
        let mut stdout = std::io::stdout();
        let _ = write!(stdout, "\x1b]22;{shape}\x07");
        let _ = stdout.flush();
    }

    /// Mouse-move: sync the pointer shape, highlight the hovered menu
    /// item, and track the mouse position so tab-bar controls (+, ‹, ›)
    /// and the scrollbar render a hover state. Only redraws when the
    /// hovered element actually changes.
    fn handle_hover(
        &mut self,
        x: u16,
        y: u16,
        modifiers: KeyModifiers,
    ) -> anyhow::Result<RenderAction> {
        self.sync_pointer_shape(x, y);
        if let Some(menu) = self.menu.as_mut()
            && let Some((depth, item)) = menu.hit_at(x, y)
        {
            if menu.select_at(depth, item) {
                return Ok(RenderAction::Draw);
            }
            return Ok(RenderAction::None);
        }
        if self.menu.is_none() && self.prompt.is_none() && self.drag.is_none() {
            let _ = self.forward_pty_mouse_at(x, y, MouseAction::Motion, None, modifiers, false);
            let mut over_browser = false;
            if let Some(area) = self
                .pane_areas
                .iter()
                .find(|area| {
                    area.content.contains(x, y)
                        && self.surface_kind(area.surface) == Some(SurfaceKind::Browser)
                })
                .copied()
            {
                over_browser = true;
                let editing_same_pane =
                    self.omnibar.as_ref().is_some_and(|state| state.pane == area.pane);
                let status = self.session.surface(area.surface).and_then(|surface| {
                    (surface.kind() == SurfaceKind::Browser).then(|| surface.browser_status())
                });
                if browser_hover_forward_allowed(status.flatten(), editing_same_pane) {
                    let cell = (x.saturating_sub(area.content.x), y.saturating_sub(area.content.y));
                    let next = (area.surface, cell.0, cell.1);
                    if self.last_browser_hover != Some(next) {
                        self.send_browser_mouse(
                            area.surface,
                            area.content,
                            x,
                            y,
                            BrowserMouseDispatch::new("mouseMoved", Some("none"), None),
                        );
                        self.last_browser_hover = Some(next);
                    }
                }
            }
            if !over_browser {
                self.last_browser_hover = None;
            }
        }
        let hoverable = |pos: Option<(u16, u16)>| {
            pos.and_then(|(px, py)| {
                self.hit_at(px, py)
                    .filter(|hit| {
                        matches!(
                            hit,
                            Hit::NewTab { .. } | Hit::TabScroll { .. } | Hit::Scrollbar { .. }
                        )
                    })
                    .map(|hit| format!("{hit:?}"))
                    .or_else(|| {
                        self.omnibar_hit_at(px, py)
                            .filter(|(_, hit)| *hit != OmnibarHit::Edit)
                            .map(|(_, hit)| format!("{hit:?}"))
                    })
            })
        };
        let before = hoverable(self.hover);
        let after = hoverable(Some((x, y)));
        self.hover = Some((x, y));
        Ok(if before != after { RenderAction::Draw } else { RenderAction::None })
    }

    fn handle_right_drag(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        self.hover = Some((x, y));
        let Some(menu) = self.menu.as_mut() else { return Ok(RenderAction::None) };
        if (x, y) != menu.right_press {
            menu.right_drag_moved = true;
        }
        if let Some((depth, item)) = menu.hit_at(x, y)
            && menu.select_at(depth, item)
        {
            return Ok(RenderAction::Draw);
        }
        Ok(RenderAction::None)
    }

    fn handle_right_up(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        let Some(mut menu) = self.menu.take() else { return Ok(RenderAction::None) };
        let plain_open_click = !menu.right_drag_moved && (x, y) == menu.right_press;
        if plain_open_click {
            self.menu = Some(menu);
        } else if let Some((depth, item)) = menu.hit_at(x, y) {
            let action = menu.action_at(depth, item);
            menu.select_at(depth, item);
            if let Some(action) = action {
                self.activate_menu(action)?;
            } else {
                self.menu = Some(menu);
            }
        } else {
            self.menu = Some(menu);
        }
        Ok(RenderAction::Draw)
    }

    fn handle_left_down(
        &mut self,
        x: u16,
        y: u16,
        modifiers: KeyModifiers,
    ) -> anyhow::Result<RenderAction> {
        self.selection = None;
        self.drag = None;

        if self.pairing_dialog.is_some() {
            return self.handle_pairing_click(x, y);
        }
        // An open rename dialog captures the click.
        if self.prompt.is_some() {
            return self.handle_prompt_click(x, y);
        }

        // An open menu captures the click: activate or dismiss. Clicks on
        // the border chrome keep it open without activating.
        if let Some(mut menu) = self.menu.take() {
            if let Some((depth, item)) = menu.hit_at(x, y) {
                let action = menu.action_at(depth, item);
                menu.select_at(depth, item);
                if let Some(action) = action {
                    self.activate_menu(action)?;
                } else {
                    self.menu = Some(menu);
                }
            } else if menu.contains(x, y) {
                self.menu = Some(menu); // padding click: keep it open
            }
            return Ok(RenderAction::Draw);
        }

        if let Some((pane, hit)) = self.omnibar_hit_at(x, y) {
            self.focus_pane_after_input(pane);
            if let Some(state) = &self.omnibar {
                if state.pane == pane {
                    return Ok(RenderAction::Draw);
                }
                self.omnibar = None;
            }
            match hit {
                OmnibarHit::Back => {
                    self.enqueue_browser_command_for_pane(pane, BrowserInputKind::Back);
                }
                OmnibarHit::Forward => {
                    self.enqueue_browser_command_for_pane(pane, BrowserInputKind::Forward);
                }
                OmnibarHit::Reload => {
                    self.enqueue_browser_command_for_pane(pane, BrowserInputKind::Reload);
                }
                OmnibarHit::Edit => self.focus_omnibar(pane),
            }
            return Ok(RenderAction::Draw);
        }

        if let Some(state) = &self.omnibar {
            let editing_rect = self
                .pane_areas
                .iter()
                .find(|area| area.pane == state.pane && area.surface == state.surface)
                .and_then(|area| area.omnibar);
            if !editing_rect.is_some_and(|rect| rect.contains(x, y)) {
                self.omnibar = None;
            }
        }

        if self.config.sidebar.plugin.is_some()
            && self.sidebar_plugin_rect().contains(x, y)
            && self.sidebar_visible
        {
            let requested = self.sync_sidebar_plugin(true);
            self.sidebar_focused = self.sidebar_plugin_surface.is_some();
            self.sidebar_focus_pending = requested && self.sidebar_plugin_surface.is_none();
            return Ok(RenderAction::Draw);
        }
        // Any click outside the plugin rect returns keyboard focus to the
        // panes; otherwise typing would keep going to the plugin PTY after
        // the user clicked into a pane.
        self.sidebar_focused = false;
        self.sidebar_focus_pending = false;

        if let Some(hit) = self.hit_at(x, y) {
            match hit {
                Hit::Workspace { index, id } => {
                    self.sidebar_workspace_selection = index;
                    self.drag = Some(Drag::WorkspaceArm { workspace: id, at: (x, y) });
                }
                Hit::NewWorkspace => self.new_workspace()?,
                Hit::SidebarFile { index } => self.sidebar_files.select(index),
                Hit::ScreenEntry { index, .. } => {
                    if self.prepare_pty_input_before_mutation() {
                        self.select_screen_for_client(Some(index), None);
                    }
                }
                Hit::NewScreen => self.new_screen()?,
                Hit::Tab { pane, index } => {
                    if let Some(surface) = self
                        .tree
                        .pane(pane)
                        .and_then(|pane| pane.tabs.get(index))
                        .map(|t| t.surface)
                    {
                        self.drag = Some(Drag::TabArm { surface, at: (x, y) });
                    }
                }
                Hit::NewTab { pane } => {
                    self.focus_pane_after_input(pane);
                    if self.prepare_pty_input_before_mutation() {
                        self.session
                            .new_tab(Some(pane), self.terminal_tab_size_hint(Some(pane)))?;
                    }
                }
                Hit::Clients { surface } => self.open_clients_menu(x, y, surface),
                Hit::Scrollbar { surface, track } => {
                    self.start_scrollbar_drag(surface, track, y);
                }
                Hit::SidebarResize => self.drag = Some(Drag::SidebarResize),
                Hit::PaneResize { horizontal, vertical } => {
                    self.drag = Some(Drag::ResizeSplit { horizontal, vertical });
                }
                Hit::TabScroll { pane, delta } => self.scroll_tabs(pane, delta),
            }
            return Ok(RenderAction::Draw);
        }

        if let Some(area) = self.pane_area_at(x, y).copied() {
            if area.content.contains(x, y) {
                if self.surface_kind(area.surface) == Some(SurfaceKind::Browser) {
                    if self.active_pane() != Some(area.pane) {
                        self.focus_pane_after_input(area.pane);
                    }
                    self.send_browser_mouse(
                        area.surface,
                        area.content,
                        x,
                        y,
                        BrowserMouseDispatch::new("mousePressed", Some("left"), Some(1)),
                    );
                    self.drag =
                        Some(Drag::Browser { surface: area.surface, content: area.content });
                } else if self.begin_pty_mouse_drag(x, y, MouseButton::Left, modifiers)
                    != PtyMousePressResult::NotOwned
                {
                    return Ok(RenderAction::Draw);
                } else {
                    if self.active_pane() != Some(area.pane) {
                        self.focus_pane_after_input(area.pane);
                    }
                    let Some(content) = self.terminal_input_rect(&area) else {
                        return Ok(RenderAction::Draw);
                    };
                    if !content.contains(x, y) {
                        return Ok(RenderAction::Draw);
                    }
                    // Begin a text selection; it becomes visible once the
                    // mouse moves to a second cell.
                    let offset = self.surface_scroll_offset(area.surface);
                    let cell = (x - content.x, offset + (y - content.y) as u64);
                    self.selection =
                        Some(Selection { surface: area.surface, anchor: cell, head: cell });
                    self.drag =
                        Some(Drag::Select { content, auto_scroll: None, col: x - content.x });
                }
            } else if self.active_pane() != Some(area.pane) {
                self.focus_pane_after_input(area.pane);
            }
            return Ok(RenderAction::Draw);
        }
        Ok(RenderAction::None)
    }

    fn handle_left_drag(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        match &self.drag {
            Some(Drag::TabArm { surface, at }) => {
                let (surface, at) = (*surface, *at);
                if (x, y) != at {
                    let target = self.tab_drop_target_at(x, y);
                    self.drag = Some(Drag::Tab { surface, target });
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::Tab { surface, .. }) => {
                let surface = *surface;
                let target = self.tab_drop_target_at(x, y);
                self.drag = Some(Drag::Tab { surface, target });
                Ok(RenderAction::Draw)
            }
            Some(Drag::WorkspaceArm { workspace, at }) => {
                let (workspace, at) = (*workspace, *at);
                if (x, y) != at {
                    let target = self.workspace_drop_target_at(x, y);
                    self.drag = Some(Drag::Workspace { workspace, target });
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::Workspace { workspace, .. }) => {
                let workspace = *workspace;
                let target = self.workspace_drop_target_at(x, y);
                self.drag = Some(Drag::Workspace { workspace, target });
                Ok(RenderAction::Draw)
            }
            Some(Drag::Select { content, .. }) => {
                let content = *content;
                let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
                let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
                let offset =
                    self.selection.map(|sel| self.surface_scroll_offset(sel.surface)).unwrap_or(0);
                if let Some(sel) = self.selection.as_mut() {
                    sel.head = (cx - content.x, offset + (cy - content.y) as u64);
                }
                let auto_scroll = if y <= content.y {
                    Some(-1)
                } else if y >= content.y + content.height.saturating_sub(1) {
                    Some(1)
                } else {
                    None
                };
                self.drag = Some(Drag::Select { content, auto_scroll, col: cx - content.x });
                Ok(RenderAction::Draw)
            }
            Some(Drag::Browser { surface, content }) => {
                let (surface, content) = (*surface, *content);
                let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
                let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
                self.send_browser_mouse(
                    surface,
                    content,
                    cx,
                    cy,
                    BrowserMouseDispatch::new("mouseMoved", Some("left"), Some(1)),
                );
                Ok(RenderAction::Draw)
            }
            Some(Drag::PtyMouse { .. }) => Ok(RenderAction::None),
            Some(Drag::Scrollbar { surface, track, anchor_y, anchor_offset }) => {
                let (surface, track, anchor_y, anchor_offset) =
                    (*surface, *track, *anchor_y, *anchor_offset);
                self.drag_scrollbar(surface, track, anchor_y, anchor_offset, y);
                Ok(RenderAction::Draw)
            }
            Some(Drag::SidebarResize) => {
                if let Some(width) =
                    sidebar_drag_width(&self.config, self.content_area, self.sidebar_width, x)
                {
                    self.sidebar_width_override = Some(width);
                }
                Ok(RenderAction::Draw)
            }
            Some(Drag::ResizeSplit { horizontal, vertical }) => {
                let (horizontal, vertical) = (*horizontal, *vertical);
                if let Some((pane, edge)) = horizontal {
                    self.resize_split(pane, edge, x, y);
                }
                if let Some((pane, edge)) = vertical {
                    self.resize_split(pane, edge, x, y);
                }
                Ok(RenderAction::Draw)
            }
            None => Ok(RenderAction::None),
        }
    }

    fn handle_left_up(&mut self, x: u16, y: u16) -> anyhow::Result<RenderAction> {
        if let Some(Drag::TabArm { surface, .. }) = self.drag {
            self.drag = None;
            if let Some((pane, index)) = self.tab_location(surface) {
                self.focus_pane_after_input(pane);
                if self.prepare_pty_input_before_mutation() {
                    self.select_tab_for_client(Some(pane), Some(index), None);
                }
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::Tab { surface, .. }) = self.drag {
            self.drag = None;
            if let Some((pane, index)) = self.tab_drop_target_at(x, y)
                && self.prepare_pty_input_before_mutation()
            {
                self.session.move_tab(surface, pane, index);
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::WorkspaceArm { workspace, .. }) = self.drag {
            self.drag = None;
            if let Some(index) = self.workspace_index(workspace)
                && self.prepare_pty_input_before_mutation()
            {
                self.select_workspace_for_client(Some(index), None);
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::Workspace { workspace, .. }) = self.drag {
            self.drag = None;
            if let Some(insertion) = self.workspace_drop_target_at(x, y)
                && self.prepare_pty_input_before_mutation()
            {
                self.session.move_workspace(workspace, insertion);
            }
            return Ok(RenderAction::Draw);
        }
        if let Some(Drag::Browser { surface, content }) = self.drag {
            self.drag = None;
            let cx = x.clamp(content.x, content.x + content.width.saturating_sub(1));
            let cy = y.clamp(content.y, content.y + content.height.saturating_sub(1));
            self.send_browser_mouse(
                surface,
                content,
                cx,
                cy,
                BrowserMouseDispatch::new("mouseReleased", Some("left"), Some(1)),
            );
            return Ok(RenderAction::Draw);
        }
        if matches!(self.drag, Some(Drag::ResizeSplit { .. })) {
            self.drag = None;
            self.session.settle_split_ratio();
            return Ok(RenderAction::Draw);
        }
        let was_select = matches!(self.drag, Some(Drag::Select { .. }));
        let was_drag = self.drag.is_some();
        self.drag = None;
        if !was_select {
            return Ok(if was_drag { RenderAction::Draw } else { RenderAction::None });
        }
        match self.selection {
            Some(sel) if sel.anchor != sel.head => {
                self.copy_selection(sel);
                Ok(RenderAction::Draw)
            }
            _ => {
                // A plain click: no selection to keep.
                self.selection = None;
                Ok(RenderAction::Draw)
            }
        }
    }

    /// Copy the selected text to the host clipboard via OSC 52 (the host
    /// terminal owns the clipboard; this works over SSH too).
    fn copy_selection(&mut self, sel: Selection) {
        let Some(surface) = self.session.surface(sel.surface) else { return };
        let (start, end) = sel.range();
        let Some(text) = surface.with_terminal(|t| t.selection_text_absolute(start, end)).flatten()
        else {
            return;
        };
        if text.is_empty() {
            return;
        }
        if let SurfaceHandle::Local(local, _) = &surface {
            local.set_selection_text(Some(text.clone()));
        }
        self.copy_text_to_clipboard(&text);
        self.show_toast("Copied".to_string());
    }

    fn copy_text_to_clipboard(&self, text: &str) {
        let encoded = base64::engine::general_purpose::STANDARD.encode(text.as_bytes());
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock().unwrap();
        let mut stdout = std::io::stdout();
        let _ = write!(stdout, "\x1b]52;c;{encoded}\x07");
        let _ = stdout.flush();
    }

    fn copy_short_id(&mut self, short_id: String) {
        self.copy_text_to_clipboard(&short_id);
        self.show_toast(format!("Copied {short_id}"));
    }

    fn show_toast(&mut self, text: String) {
        self.toast = Some(Toast { text, deadline: Instant::now() + Duration::from_millis(1500) });
    }

    fn expire_toast(&mut self) -> bool {
        if self.toast.as_ref().is_some_and(|toast| Instant::now() >= toast.deadline) {
            self.toast = None;
            true
        } else {
            false
        }
    }

    /// Shift a pane's tab bar left/right. The renderer clamps to the
    /// valid range next frame.
    fn scroll_tabs(&mut self, pane: PaneId, delta: isize) {
        let entry = self.tab_scroll.entry(pane).or_insert(0);
        *entry = entry.saturating_add_signed(delta);
    }

    /// Start a scrollbar drag. Clicking the thumb only anchors; clicking
    /// outside it jumps first, then anchors at the clicked position.
    fn start_scrollbar_drag(&mut self, surface: SurfaceId, track: Rect, y: u16) {
        let Some(handle) = self.session.surface(surface) else { return };
        let jump_delta = handle
            .with_terminal(|t| {
                let sb = t.scrollbar()?;
                let rel_y = y.saturating_sub(track.y).min(track.height.saturating_sub(1));
                let (thumb_y, thumb_len) = thumb_geometry(&sb, track.height);
                let on_thumb = rel_y >= thumb_y && rel_y < thumb_y + thumb_len;
                if on_thumb {
                    return None;
                }
                let denom = track.height.saturating_sub(1).max(1) as f64;
                let frac = (rel_y as f64 / denom).clamp(0.0, 1.0);
                let target = ((sb.total - sb.len) as f64 * frac).round() as i64;
                let delta = target - sb.offset as i64;
                (delta != 0).then_some(delta as isize)
            })
            .flatten();
        if let Some(delta) = jump_delta {
            let _ = handle.scroll_delta(delta);
        }
        let anchor_offset =
            handle.with_terminal(|t| t.scrollbar().map(|scrollbar| scrollbar.offset)).flatten();
        if let Some(anchor_offset) = anchor_offset {
            self.drag = Some(Drag::Scrollbar { surface, track, anchor_y: y, anchor_offset });
        }
    }

    /// Map an anchored scrollbar drag delta to a viewport offset.
    fn drag_scrollbar(
        &mut self,
        surface: SurfaceId,
        track: Rect,
        anchor_y: u16,
        anchor_offset: u64,
        y: u16,
    ) {
        let Some(handle) = self.session.surface(surface) else { return };
        let delta = handle
            .with_terminal(|t| {
                let sb = t.scrollbar()?;
                let (_, thumb_len) = thumb_geometry(&sb, track.height);
                let range = sb.total.saturating_sub(sb.len);
                let travel = track.height.saturating_sub(thumb_len).max(1) as i128;
                let dy = y as i128 - anchor_y as i128;
                let delta = dy * range as i128 / travel;
                let target = (anchor_offset as i128 + delta).clamp(0, range as i128) as i64;
                let current = sb.offset as i64;
                let scroll_delta = target - current;
                (scroll_delta != 0).then_some(scroll_delta as isize)
            })
            .flatten();
        if let Some(delta) = delta {
            let _ = handle.scroll_delta(delta);
        }
    }

    fn resize_focused_split(&mut self, delta: f32) {
        let Some(pane) = self.active_pane() else { return };
        let Some(screen) = self.tree.active_screen() else { return };
        let Some(area) = self.pane_areas.iter().find(|area| area.pane == pane) else {
            return;
        };
        let candidates = [
            (SplitEdge::Right, PaneEdge::Right),
            (SplitEdge::Left, PaneEdge::Left),
            (SplitEdge::Bottom, PaneEdge::Bottom),
            (SplitEdge::Top, PaneEdge::Top),
        ];
        let Some((edge, target)) = candidates
            .into_iter()
            .filter_map(|(split_edge, pane_edge)| {
                exact_split_for_pane_edge(
                    &screen.layout,
                    self.content_area,
                    Some(screen.active_pane),
                    pane,
                    split_edge,
                )
                .map(|target| (pane_edge, target))
            })
            .min_by_key(|(_, target)| target.area.width as u32 * target.area.height as u32)
        else {
            return;
        };
        let (current, sign) = match edge {
            PaneEdge::Left => (
                (area.rect.x.saturating_sub(target.area.x)) as f32
                    / target.area.width.max(1) as f32,
                -1.0,
            ),
            PaneEdge::Right => (
                (area.rect.x + area.rect.width).saturating_sub(target.area.x) as f32
                    / target.area.width.max(1) as f32,
                1.0,
            ),
            PaneEdge::Top => (
                (area.rect.y.saturating_sub(target.area.y)) as f32
                    / target.area.height.max(1) as f32,
                -1.0,
            ),
            PaneEdge::Bottom => (
                (area.rect.y + area.rect.height).saturating_sub(target.area.y) as f32
                    / target.area.height.max(1) as f32,
                1.0,
            ),
        };
        if self.prepare_pty_input_before_mutation() {
            self.session.set_split_ratio(target.split, (current + delta * sign).clamp(0.05, 0.95));
        }
    }

    fn resize_split(&mut self, pane: PaneId, edge: PaneEdge, x: u16, y: u16) {
        let Some(screen) = self.tree.active_screen() else { return };
        let split_edge = match edge {
            PaneEdge::Left => SplitEdge::Left,
            PaneEdge::Right => SplitEdge::Right,
            PaneEdge::Top => SplitEdge::Top,
            PaneEdge::Bottom => SplitEdge::Bottom,
        };
        let Some(target) = exact_split_for_pane_edge(
            &screen.layout,
            self.content_area,
            Some(screen.active_pane),
            pane,
            split_edge,
        ) else {
            return;
        };
        let (coord, start, extent) = match edge {
            PaneEdge::Left => (x, target.area.x, target.area.width),
            PaneEdge::Right => (x.saturating_add(1), target.area.x, target.area.width),
            PaneEdge::Top => (y, target.area.y, target.area.height),
            PaneEdge::Bottom => (y.saturating_add(1), target.area.y, target.area.height),
        };
        if extent == 0 {
            return;
        }
        let ratio = (coord.saturating_sub(start) as f32 / extent as f32).clamp(0.05, 0.95);
        if self.prepare_pty_input_before_mutation() {
            self.session.set_split_ratio_deferred(target.split, ratio);
        }
    }

    fn open_context_menu(&mut self, x: u16, y: u16) {
        self.cancel_pty_mouse_drag();
        self.menu = None;
        self.omnibar = None;
        self.session.refresh_clients_background();
        match self.hit_at(x, y) {
            Some(Hit::Workspace { id, .. }) => {
                self.menu = Some(ContextMenu::at(
                    x,
                    y,
                    vec![
                        vec![MenuAction::RenameWorkspace(id), MenuAction::CloseWorkspace(id)],
                        vec![MenuAction::CopyWorkspaceId(id)],
                    ],
                ));
                return;
            }
            Some(Hit::ScreenEntry { id, .. }) => {
                self.menu = Some(ContextMenu::at(
                    x,
                    y,
                    vec![vec![MenuAction::RenameScreen(id), MenuAction::CloseScreen(id)]],
                ));
                return;
            }
            Some(Hit::Clients { surface }) => {
                self.open_clients_menu(x, y, surface);
                return;
            }
            _ => {}
        }
        if let Some(area) = self.pane_area_at(x, y) {
            let is_browser = self.surface_kind(area.surface) == Some(SurfaceKind::Browser);
            let external_browser =
                self.browser_source(area.surface) == Some(BrowserSource::External);
            let mut groups = pane_context_menu_groups(area.pane, is_browser, external_browser)
                .into_iter()
                .map(|group| group.into_iter().map(MenuItem::Action).collect())
                .collect::<Vec<Vec<MenuItem>>>();
            if let Some(clients) = client_menu_item(&self.clients, area.surface) {
                groups.push(vec![clients]);
            }
            self.menu = Some(ContextMenu::with_groups(x, y, groups));
        }
    }

    fn replace_clients(&mut self, clients: Vec<ClientInfo>) {
        self.client_border_labels = crate::ui::pane::client_border_labels(&clients);
        self.clients = clients;
    }

    fn open_clients_menu(&mut self, x: u16, y: u16, surface: SurfaceId) {
        self.session.refresh_clients_background();
        if let Some(MenuItem::Submenu { items, .. }) = client_menu_item(&self.clients, surface) {
            self.menu = Some(ContextMenu::with_groups(x, y, vec![items]));
        }
    }

    fn handle_scroll(
        &mut self,
        x: u16,
        y: u16,
        down: bool,
        modifiers: KeyModifiers,
    ) -> anyhow::Result<RenderAction> {
        if self.menu.is_some() || self.prompt.is_some() {
            return Ok(RenderAction::None);
        }
        let Some(area) = self.pane_area_at(x, y).copied() else { return Ok(RenderAction::None) };
        if self.surface_kind(area.surface) == Some(SurfaceKind::Pty)
            && area.content.contains(x, y)
            && !self.terminal_input_rect(&area).is_some_and(|rect| rect.contains(x, y))
        {
            return Ok(RenderAction::None);
        }
        if self.active_pane() != Some(area.pane) {
            self.focus_pane_after_input(area.pane);
        }
        // Wheel over the tab bar scrolls the tabs, not the terminal.
        if area.bar.is_some_and(|bar| bar.contains(x, y)) {
            self.scroll_tabs(area.pane, if down { 1 } else { -1 });
            return Ok(RenderAction::Draw);
        }
        let (surface_id, _) = (area.surface, area.pane);
        let Some(surface) = self.session.surface(surface_id) else { return Ok(RenderAction::None) };
        if surface.kind() == SurfaceKind::Browser {
            if area.content.contains(x, y) {
                let (px, py) = self.browser_point(area.content, x, y);
                let delta = if down { 3.0 } else { -3.0 } * f64::from(self.cell_pixels.1);
                let _ = self.browser_input.enqueue(BrowserInputEvent {
                    surface_id,
                    surface,
                    kind: BrowserInputKind::Wheel { x: px, y: py, delta_y: delta },
                });
                return Ok(RenderAction::Draw);
            }
            return Ok(RenderAction::None);
        }
        if area.content.contains(x, y)
            && self.forward_pty_mouse_at(
                x,
                y,
                MouseAction::Press,
                Some(if down {
                    GhosttyMouseButton::WheelDown
                } else {
                    GhosttyMouseButton::WheelUp
                }),
                modifiers,
                false,
            )
        {
            return Ok(RenderAction::Draw);
        }
        let Some(sent_arrows) = surface.with_terminal(|term| {
            term.active_screen() == Screen::Alternate && !term.mouse_tracking()
        }) else {
            return Ok(RenderAction::None);
        };
        if sent_arrows {
            let _ = surface.scroll_to_bottom();
            // Alt-screen apps without mouse support get arrow keys
            // (the usual alternate-scroll behavior).
            let seq: &[u8] = if down { b"\x1b[B\x1b[B\x1b[B" } else { b"\x1b[A\x1b[A\x1b[A" };
            let _ = self.write_pty_bytes(
                surface_id,
                surface,
                PtyInputBytes::from_slice(seq),
                PtyInputKind::Ordered,
            );
        } else {
            let _ = surface.scroll_delta(if down { 3 } else { -3 });
        }
        Ok(RenderAction::Draw)
    }

    fn handle_horizontal_scroll(
        &mut self,
        x: u16,
        y: u16,
        right: bool,
        modifiers: KeyModifiers,
    ) -> anyhow::Result<RenderAction> {
        if self.menu.is_some() || self.prompt.is_some() {
            return Ok(RenderAction::None);
        }
        let Some(area) = self.pane_area_at(x, y).copied() else {
            return Ok(RenderAction::None);
        };
        if self.surface_kind(area.surface) == Some(SurfaceKind::Pty)
            && area.content.contains(x, y)
            && !self.terminal_input_rect(&area).is_some_and(|rect| rect.contains(x, y))
        {
            return Ok(RenderAction::None);
        }
        if self.active_pane() != Some(area.pane) {
            self.focus_pane_after_input(area.pane);
        }
        if area.content.contains(x, y)
            && self.forward_pty_mouse_at(
                x,
                y,
                MouseAction::Press,
                Some(if right {
                    GhosttyMouseButton::WheelRight
                } else {
                    GhosttyMouseButton::WheelLeft
                }),
                modifiers,
                false,
            )
        {
            return Ok(RenderAction::Draw);
        }
        Ok(RenderAction::None)
    }

    fn surface_kind(&self, surface: SurfaceId) -> Option<SurfaceKind> {
        self.tab_locations
            .get(&surface)
            .and_then(|[workspace, screen, pane, tab]| {
                self.tree
                    .workspaces
                    .get(*workspace)
                    .and_then(|workspace| workspace.screens.get(*screen))
                    .and_then(|screen| screen.panes.get(*pane))
                    .and_then(|pane| pane.tabs.get(*tab))
            })
            .map(|tab| tab.kind)
            .or_else(|| self.session.surface(surface).map(|surface| surface.kind()))
    }

    fn browser_source(&self, surface: SurfaceId) -> Option<BrowserSource> {
        self.tree
            .workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .find(|tab| tab.surface == surface)
            .and_then(|tab| tab.browser_source)
    }

    fn browser_point(&self, content: Rect, x: u16, y: u16) -> (f64, f64) {
        let col = x.saturating_sub(content.x) as f64 + 0.5;
        let row = y.saturating_sub(content.y) as f64 + 0.5;
        (col * f64::from(self.cell_pixels.0), row * f64::from(self.cell_pixels.1))
    }

    /// Queue a mouse event for the off-loop browser input worker; the
    /// event loop never waits on the CDP/socket round trip.
    fn send_browser_mouse(
        &self,
        surface_id: SurfaceId,
        content: Rect,
        x: u16,
        y: u16,
        dispatch: BrowserMouseDispatch,
    ) {
        let Some(surface) = self.session.surface(surface_id) else { return };
        let (px, py) = self.browser_point(content, x, y);
        let _ = self.browser_input.enqueue(BrowserInputEvent {
            surface_id,
            surface,
            kind: BrowserInputKind::Mouse {
                event_type: dispatch.event_type,
                x: px,
                y: py,
                button: dispatch.button,
                click_count: dispatch.click_count,
            },
        });
    }
}

fn browser_modifiers(modifiers: KeyModifiers) -> u32 {
    let mut out = 0;
    if modifiers.contains(KeyModifiers::ALT) {
        out |= 1;
    }
    if modifiers.contains(KeyModifiers::CONTROL) {
        out |= 2;
    }
    if modifiers.contains(KeyModifiers::SUPER) {
        out |= 4;
    }
    if modifiers.contains(KeyModifiers::SHIFT) {
        out |= 8;
    }
    out
}

fn browser_only_action(action: Action) -> bool {
    matches!(
        action,
        Action::BrowserBack
            | Action::BrowserForward
            | Action::BrowserReload
            | Action::BrowserEditUrl
    )
}

fn action_prepares_pty_release(action: Action) -> bool {
    !matches!(
        action,
        Action::RenameTab
            | Action::RenameScreen
            | Action::RenameWorkspace
            | Action::ScrollUp
            | Action::ScrollDown
            | Action::BrowserEditUrl
    )
}

fn menu_action_prepares_pty_release(action: MenuAction) -> bool {
    !matches!(
        action,
        MenuAction::RenameWorkspace(_)
            | MenuAction::CopyWorkspaceId(_)
            | MenuAction::RenameScreen(_)
            | MenuAction::BrowserEditUrl(_)
            | MenuAction::BrowserCopyUrl(_)
            | MenuAction::RenameTab(_)
            | MenuAction::CopyTabId(_)
            | MenuAction::CopyPaneId(_)
    )
}

fn deferred_paste_bytes(text: &str) -> usize {
    text.len().saturating_add(BRACKETED_PASTE_MARKER_BYTES)
}

fn deferred_input_bytes(input: &Event) -> usize {
    match input {
        Event::Paste(text) => deferred_paste_bytes(text),
        _ => DEFERRED_INPUT_FIXED_BYTES,
    }
}

fn browser_hover_forward_allowed(status: Option<BrowserStatus>, editing_same_pane: bool) -> bool {
    !editing_same_pane && matches!(status, Some(BrowserStatus::Live))
}

fn clear_omnibar_selection(state: &mut OmnibarState) {
    if state.select_all {
        state.input.clear();
        state.select_all = false;
    }
}

fn rects_intersect(a: Rect, b: Rect) -> bool {
    let ax2 = a.x.saturating_add(a.width);
    let ay2 = a.y.saturating_add(a.height);
    let bx2 = b.x.saturating_add(b.width);
    let by2 = b.y.saturating_add(b.height);
    a.x < bx2 && ax2 > b.x && a.y < by2 && ay2 > b.y
}

fn browser_key_mapping(
    code: KeyCode,
) -> Option<(&'static str, &'static str, u32, Option<&'static str>)> {
    match code {
        KeyCode::Enter => Some(("Enter", "Enter", 13, Some("\r"))),
        KeyCode::Backspace => Some(("Backspace", "Backspace", 8, None)),
        KeyCode::Tab | KeyCode::BackTab => Some(("Tab", "Tab", 9, None)),
        KeyCode::Esc => Some(("Escape", "Escape", 27, None)),
        KeyCode::Left => Some(("ArrowLeft", "ArrowLeft", 37, None)),
        KeyCode::Up => Some(("ArrowUp", "ArrowUp", 38, None)),
        KeyCode::Right => Some(("ArrowRight", "ArrowRight", 39, None)),
        KeyCode::Down => Some(("ArrowDown", "ArrowDown", 40, None)),
        KeyCode::Home => Some(("Home", "Home", 36, None)),
        KeyCode::End => Some(("End", "End", 35, None)),
        KeyCode::PageUp => Some(("PageUp", "PageUp", 33, None)),
        KeyCode::PageDown => Some(("PageDown", "PageDown", 34, None)),
        KeyCode::Delete => Some(("Delete", "Delete", 46, None)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        App, AppEvent, BACKGROUND_REFRESH_RETRIES, ContextMenu, DeferredInput, Drag,
        ForwardMuxOutcome, MenuAction, MenuItem, MuxTitleIngress, OrderedSession, PaneArea,
        PaneFocusHistory, PendingSessionMutation, PendingSessionMutationState, PtyFailureIngress,
        PtyMousePressResult, RenderAction, Selection, SessionCompletion, SessionCompletionAction,
        SidebarPluginSyncClaim, SidebarPluginSyncState, SurfaceResizeDecision,
        SurfaceResizeOwnership, browser_content_size_for_rect, browser_hover_forward_allowed,
        client_menu_item, forward_mux_event, forward_mux_events, pane_context_menu_groups,
        pane_parts_for_rect, preserve_client_view, record_surface_resize_dispatch_result,
        sidebar_plugin_status_settles_passive_claim,
    };
    use std::collections::{HashMap, HashSet, VecDeque};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::mpsc::Receiver;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use cmux_tui_core::{
        BrowserStatus, Direction, Mux, MuxEvent, Node, Rect, SplitDir, SurfaceId, SurfaceKind,
        SurfaceOptions, layout_screen,
    };
    use crossterm::event::{
        Event, KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
    };
    use ghostty_vt::{
        KeyEncoder, Mods, MouseAction, MouseButton as GhosttyMouseButton, MouseInput, RenderState,
    };
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    use crate::browser_input::{BrowserInputDispatcher, BrowserInputEvent, BrowserInputKind};
    use crate::config::{Action, ChromeTheme, Config, ScrollbarPosition, SidebarView};
    use crate::pty_input::{
        PtyInputBytes, PtyInputDispatcher, PtyInputEnqueueResult, PtyInputKind,
        PtyOperationDelivery, PtyOperationFailure,
    };
    use crate::session::tree::{PaneView, ScreenView, TabNotificationView, TabView, WorkspaceView};
    use crate::session::{
        ClientInfo, ClientSizeInfo, Session, SidebarPluginSurface, SurfaceHandle, TreeView,
    };
    use crate::sidebar_files::FileBrowser;

    fn settled(outcome: super::SessionMutationOutcome) -> AppEvent {
        AppEvent::SessionMutationSettled { outcome, routing: false }
    }

    #[test]
    fn pane_context_menu_groups_current_tab_creation_layout_and_ids() {
        let pane = 7;
        let menu = ContextMenu::at(10, 5, pane_context_menu_groups(pane, false, false));

        assert_eq!(
            menu.levels[0].items,
            vec![
                MenuItem::Action(MenuAction::RenameTab(pane)),
                MenuItem::Action(MenuAction::CloseTab(pane)),
                MenuItem::Separator,
                MenuItem::Action(MenuAction::NewTab(pane)),
                MenuItem::Action(MenuAction::NewBrowserTab(pane)),
                MenuItem::Separator,
                MenuItem::Action(MenuAction::SplitRight(pane)),
                MenuItem::Action(MenuAction::SplitDown(pane)),
                MenuItem::Action(MenuAction::ClosePane(pane)),
                MenuItem::Separator,
                MenuItem::Action(MenuAction::CopyTabId(pane)),
                MenuItem::Action(MenuAction::CopyPaneId(pane)),
            ]
        );
    }

    #[test]
    fn pane_focus_history_overlays_authoritative_recency() {
        let mut history = PaneFocusHistory::default();
        let mut tree = notify_tree(1, false);
        tree.workspaces[0].screens[0].panes[0].focused_at = 8;
        history.reconcile_membership(&tree);

        assert_eq!(history.recency(2), (false, 8));
        history.record(2);
        assert_eq!(history.recency(2), (true, 1));
        assert_eq!(history.recency(99), (false, 0));
    }

    #[test]
    fn pane_focus_history_prunes_closed_panes() {
        let mut history = PaneFocusHistory::default();
        history.record(2);
        history.record(99);

        history.reconcile_membership(&notify_tree(1, false));

        assert_eq!(history.recency(2), (true, 1));
        assert_eq!(history.recency(99), (false, 0));
    }

    #[test]
    fn pane_focus_history_freezes_remote_baseline_until_membership_changes() {
        let mut history = PaneFocusHistory::default();
        let mut initial = notify_tree(1, false);
        initial.workspaces[0].screens[0].panes[0].focused_at = 8;
        history.reconcile_membership(&initial);

        let mut peer_refresh = initial.clone();
        peer_refresh.workspaces[0].screens[0].panes[0].focused_at = 99;
        history.sync_membership(&peer_refresh);

        assert_eq!(history.recency(2), (false, 8));
    }

    #[test]
    fn pane_focus_history_reconciles_exact_same_size_membership_changes() {
        let mut history = PaneFocusHistory::default();
        history.record(2);
        history.reconcile_membership(&notify_tree(1, false));

        let mut replacement = notify_tree(2, false);
        let screen = &mut replacement.workspaces[0].screens[0];
        screen.active_pane = 99;
        screen.layout = Node::Leaf(99);
        screen.panes[0].id = 99;
        screen.panes[0].focused_at = 5;
        replacement.pane_revision = Some(2);
        history.sync_membership(&replacement);

        assert_eq!(history.recency(2), (false, 0));
        assert_eq!(history.recency(99), (false, 5));
    }

    #[test]
    fn directional_focus_uses_client_history_and_visible_geometry() {
        let mux = Mux::new("directional-focus-memory-test", SurfaceOptions::default());
        mux.new_workspace(None, Some((80, 30))).unwrap();
        let left = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        mux.split(left, SplitDir::Right, Some((40, 30))).unwrap();
        let top_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        mux.split(top_right, SplitDir::Down, Some((40, 15))).unwrap();
        let bottom_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        assert!(mux.focus_pane(left));

        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.sidebar_visible = false;
        app.replace_tree(app.session.tree());
        app.sync_layout((80, 31));
        while app.session.has_pending_mutations() {
            let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
            app.handle(event).unwrap();
        }
        app.session.remote = true;

        app.move_focus(Direction::Right);
        assert_eq!(app.active_pane(), Some(bottom_right));
        app.move_focus(Direction::Left);
        assert_eq!(app.active_pane(), Some(left));
        app.focus_pane_after_input(top_right);
        app.move_focus(Direction::Left);
        app.move_focus(Direction::Right);
        assert_eq!(app.active_pane(), Some(top_right));

        app.tree.active_workspace_mut_screen().unwrap().zoomed_pane = Some(top_right);
        app.move_focus(Direction::Left);
        assert_eq!(app.active_pane(), Some(top_right));

        app.tree.active_workspace_mut_screen().unwrap().zoomed_pane = None;
        app.focus_pane_after_input(left);
        app.pane_areas.iter_mut().find(|area| area.pane == top_right).unwrap().content.height = 0;
        app.move_focus(Direction::Right);
        assert_eq!(app.active_pane(), Some(top_right));

        app.focus_pane_after_input(left);
        app.pane_areas.iter_mut().find(|area| area.pane == top_right).unwrap().rect.height = 0;
        app.move_focus(Direction::Right);
        assert_eq!(app.active_pane(), Some(bottom_right));
        assert_eq!(Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane, left);
        assert!(!app.session.has_pending_mutations());

        let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
        for surface in surfaces {
            mux.close_surface(surface);
        }
    }

    #[test]
    fn remote_screen_switch_records_the_new_active_pane() {
        let mux = Mux::new("remote-screen-focus-memory-test", SurfaceOptions::default());
        mux.new_workspace(None, Some((80, 30))).unwrap();
        let workspace = Session::Local(mux.clone()).tree().active_workspace().unwrap().id;
        mux.new_screen(Some(workspace), Some((80, 30))).unwrap();
        let left = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        mux.split(left, SplitDir::Right, Some((40, 30))).unwrap();
        let top_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        mux.split(top_right, SplitDir::Down, Some((40, 15))).unwrap();
        let bottom_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        mux.select_screen(Some(0), None);

        let mut app = test_app(Session::Local(mux.clone()));
        app.sidebar_visible = false;
        app.replace_tree(app.session.tree());
        app.session.remote = true;
        app.select_screen_for_client(Some(1), None);
        app.sync_layout((80, 31));

        app.move_focus(Direction::Left);
        assert_eq!(app.active_pane(), Some(left));
        app.move_focus(Direction::Right);
        assert_eq!(app.active_pane(), Some(bottom_right));

        let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
        for surface in surfaces {
            mux.close_surface(surface);
        }
    }

    #[test]
    fn remote_workspace_switch_records_the_new_active_pane() {
        let mux = Mux::new("remote-workspace-focus-memory-test", SurfaceOptions::default());
        mux.new_workspace(None, Some((80, 30))).unwrap();
        mux.new_workspace(None, Some((80, 30))).unwrap();
        let left = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        mux.split(left, SplitDir::Right, Some((40, 30))).unwrap();
        let top_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        mux.split(top_right, SplitDir::Down, Some((40, 15))).unwrap();
        let bottom_right = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        mux.select_workspace(Some(0), None);

        let mut app = test_app(Session::Local(mux.clone()));
        app.sidebar_visible = false;
        app.replace_tree(app.session.tree());
        app.session.remote = true;
        app.select_workspace_for_client(Some(1), None);
        app.sync_layout((80, 31));

        app.move_focus(Direction::Left);
        assert_eq!(app.active_pane(), Some(left));
        app.move_focus(Direction::Right);
        assert_eq!(app.active_pane(), Some(bottom_right));

        let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
        for surface in surfaces {
            mux.close_surface(surface);
        }
    }

    #[test]
    fn alt_n_uses_zellij_default_vertical_distribution() {
        let (mux, _) = test_mux("alt-n-zellij-layout-test", None);
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.sidebar_visible = false;
        app.replace_tree(app.session.tree());

        for _ in 0..4 {
            app.sync_layout((200, 40));
            app.handle_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)).unwrap();
            while app.session.has_pending_mutations() {
                let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
                app.handle(event).unwrap();
            }
        }

        let screen = app.tree.active_screen().unwrap();
        let mut panes = Vec::new();
        screen.layout.pane_ids(&mut panes);
        panes.sort_unstable();
        assert_eq!(panes.len(), 5);

        let layout = layout_screen(
            &screen.layout,
            Rect { x: 0, y: 0, width: 200, height: 40 },
            Some(screen.active_pane),
        );
        assert_eq!(
            layout.panes,
            vec![
                (panes[0], Rect { x: 0, y: 0, width: 100, height: 40 }),
                (panes[1], Rect { x: 100, y: 0, width: 100, height: 10 }),
                (panes[2], Rect { x: 100, y: 10, width: 100, height: 10 }),
                (panes[3], Rect { x: 100, y: 20, width: 100, height: 10 }),
                (panes[4], Rect { x: 100, y: 30, width: 100, height: 10 }),
            ]
        );

        for _ in 0..8 {
            app.sync_layout((200, 40));
            app.handle_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)).unwrap();
            while app.session.has_pending_mutations() {
                let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
                app.handle(event).unwrap();
            }
        }

        let screen = app.tree.active_screen().unwrap();
        let mut panes = Vec::new();
        screen.layout.pane_ids(&mut panes);
        panes.sort_unstable();
        assert_eq!(panes.len(), 13);

        let layout = layout_screen(
            &screen.layout,
            Rect { x: 0, y: 0, width: 200, height: 40 },
            Some(screen.active_pane),
        );
        assert_eq!(layout.panes[0], (panes[0], Rect { x: 0, y: 0, width: 100, height: 40 }));
        for (index, (pane, rect)) in layout.panes[1..12].iter().enumerate() {
            assert_eq!(*pane, panes[index + 1]);
            assert_eq!(*rect, Rect { x: 100, y: index as u16, width: 100, height: 1 });
        }
        assert_eq!(layout.panes[12], (panes[12], Rect { x: 100, y: 11, width: 100, height: 29 }));

        app.sync_layout((200, 41));
        let leading = app.pane_areas.iter().find(|area| area.pane == panes[0]).unwrap();
        assert_eq!(leading.rect, Rect { x: 0, y: 0, width: 100, height: 40 });
        assert_eq!(leading.bar, Some(Rect { x: 0, y: 0, width: 100, height: 1 }));
        assert_eq!(leading.content.height, 38);
        for pane in &panes[1..12] {
            let area = app.pane_areas.iter().find(|area| area.pane == *pane).unwrap();
            assert_eq!(area.bar, Some(area.rect));
            assert_eq!(area.content.height, 0);
        }
        let expanded = app.pane_areas.iter().find(|area| area.pane == panes[12]).unwrap();
        assert_eq!(expanded.rect.height, 29);
        assert_eq!(expanded.content.height, 27);

        let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
        for surface in surfaces {
            mux.close_surface(surface);
        }
    }

    #[test]
    fn alt_n_rejects_a_new_pane_with_no_visible_content() {
        let (mux, _) = test_mux("alt-n-zero-content-test", None);
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.sidebar_visible = false;
        app.replace_tree(app.session.tree());

        for _ in 0..3 {
            app.sync_layout((200, 40));
            app.handle_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)).unwrap();
            while app.session.has_pending_mutations() {
                let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
                app.handle(event).unwrap();
            }
        }
        let before = app.tree.active_screen().unwrap().clone();
        let mut before_panes = Vec::new();
        before.layout.pane_ids(&mut before_panes);
        assert_eq!(before_panes.len(), 4);

        app.sync_layout((200, 4));
        app.handle_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT)).unwrap();
        while app.session.has_pending_mutations() {
            let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
            app.handle(event).unwrap();
        }

        let after = app.tree.active_screen().unwrap();
        let mut after_panes = Vec::new();
        after.layout.pane_ids(&mut after_panes);
        assert_eq!(after_panes, before_panes);
        assert_eq!(after.active_pane, before.active_pane);

        let surfaces = mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
        for surface in surfaces {
            mux.close_surface(surface);
        }
    }

    #[test]
    fn context_menu_selection_and_hit_testing_skip_separators() {
        let mut menu = ContextMenu::at(
            10,
            5,
            vec![
                vec![MenuAction::RenameTab(7), MenuAction::CloseTab(7)],
                Vec::new(),
                vec![MenuAction::NewTab(7)],
            ],
        );

        assert_eq!(menu.item_at(10, 5), Some(0));
        assert_eq!(menu.item_at(10, 7), None);
        assert_eq!(menu.item_at(10, 8), Some(3));
        assert_eq!(menu.selected_action(), Some(MenuAction::RenameTab(7)));

        menu.select_next();
        assert_eq!(menu.selected_action(), Some(MenuAction::CloseTab(7)));
        menu.select_next();
        assert_eq!(menu.selected_action(), Some(MenuAction::NewTab(7)));
        menu.select_next();
        assert_eq!(menu.selected_action(), Some(MenuAction::NewTab(7)));
        menu.select_previous();
        assert_eq!(menu.selected_action(), Some(MenuAction::CloseTab(7)));

        menu.levels[0].selected = usize::MAX;
        menu.select_previous();
        menu.select_next();
        assert_eq!(menu.levels[0].selected, usize::MAX);
        assert_eq!(menu.selected_action(), None);

        let mut empty = ContextMenu::at(10, 5, Vec::new());
        empty.select_previous();
        empty.select_next();
        assert_eq!(empty.selected_action(), None);
    }

    #[test]
    fn context_menu_supports_arbitrarily_nested_submenus() {
        let mut menu = ContextMenu::with_groups(
            10,
            5,
            vec![vec![MenuItem::Submenu {
                label: "Clients".to_string(),
                items: vec![MenuItem::Submenu {
                    label: "client 7 · 80×24".to_string(),
                    items: vec![MenuItem::Action(MenuAction::DisconnectClient(7))],
                }],
            }]],
        );

        assert_eq!(menu.action_at(0, 0), None);
        assert!(menu.open_selected_submenu());
        assert_eq!(menu.levels.len(), 2);
        assert!(menu.open_selected_submenu());
        assert_eq!(menu.levels.len(), 3);
        assert_eq!(menu.selected_action(), Some(MenuAction::DisconnectClient(7)));
        assert!(menu.close_submenu());
        assert_eq!(menu.levels.len(), 2);
        assert!(menu.close_submenu());
        assert_eq!(menu.levels.len(), 1);
        assert!(!menu.close_submenu());
    }

    #[test]
    fn topmost_menu_chrome_blocks_hits_on_overlapped_parent_actions() {
        let mut menu = ContextMenu::with_groups(
            10,
            5,
            vec![vec![MenuItem::Submenu {
                label: "Clients".to_string(),
                items: vec![MenuItem::Action(MenuAction::RestoreAllClientSizing)],
            }]],
        );
        assert!(menu.open_selected_submenu());
        menu.levels[1].rect = Rect { x: 10, y: 5, width: 20, height: 3 };

        assert_eq!(menu.hit_at(10, 5), None);
        assert_eq!(menu.selected_action(), Some(MenuAction::RestoreAllClientSizing));
    }

    #[test]
    fn control_only_client_menu_offers_disconnect_without_sizing_actions() {
        let client = ClientInfo {
            client: 7,
            transport: "unix".to_string(),
            name: Some("control".to_string()),
            kind: Some("web".to_string()),
            connected_seconds: 1,
            attached: Vec::new(),
            sizes: Vec::new(),
            is_self: false,
            size_participating: true,
        };
        let Some(MenuItem::Submenu { items, .. }) = client_menu_item(&[client], 31) else {
            panic!("expected connected clients submenu");
        };
        let MenuItem::Submenu { items, .. } = &items[2] else {
            panic!("expected client submenu");
        };
        assert_eq!(items, &vec![MenuItem::Action(MenuAction::DisconnectClient(7))]);
    }

    #[test]
    fn current_client_size_action_is_immediately_above_restore_all() {
        let current = ClientInfo {
            client: 7,
            transport: "unix".to_string(),
            name: None,
            kind: Some("tui".to_string()),
            connected_seconds: 1,
            attached: vec![31],
            sizes: vec![ClientSizeInfo { surface: 31, cols: Some(80), rows: Some(24) }],
            is_self: true,
            size_participating: true,
        };
        let Some(MenuItem::Submenu { items, .. }) = client_menu_item(&[current], 31) else {
            panic!("expected connected clients submenu");
        };
        assert_eq!(
            &items[..2],
            &[
                MenuItem::Action(MenuAction::UseClientSize(7)),
                MenuItem::Action(MenuAction::RestoreAllClientSizing),
            ]
        );
    }

    #[test]
    fn disconnecting_this_client_uses_clean_detach_without_a_socket_round_trip() {
        let mux = Mux::new("self-disconnect-menu-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.clients = vec![ClientInfo {
            client: 7,
            transport: "unix".to_string(),
            name: Some("this tui".to_string()),
            kind: Some("tui".to_string()),
            connected_seconds: 1,
            attached: vec![],
            sizes: vec![],
            is_self: true,
            size_participating: true,
        }];

        assert!(app.activate_menu(MenuAction::DisconnectClient(7)).is_ok());
        assert!(app.quit, "self-disconnect must take the same clean exit path as Ctrl-b d");

        assert!(app.activate_menu(MenuAction::DisconnectClient(7)).is_ok());
        assert!(app.quit, "repeated self-disconnect must remain idempotent");
    }

    #[test]
    fn stale_peer_disconnect_is_an_idempotent_noop_without_quitting_the_tui() {
        let mux = Mux::new("stale-peer-disconnect-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.clients = vec![ClientInfo {
            client: 7,
            transport: "unix".to_string(),
            name: Some("stale peer".to_string()),
            kind: Some("tui".to_string()),
            connected_seconds: 1,
            attached: vec![],
            sizes: vec![],
            is_self: false,
            size_participating: true,
        }];

        assert!(app.activate_menu(MenuAction::DisconnectClient(7)).is_ok());
        assert!(!app.quit);
        let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            event,
            AppEvent::SessionMutationSettled {
                outcome: super::SessionMutationOutcome::Success { .. },
                ..
            }
        ));
        assert!(app.handle(event).is_ok());
        assert!(!app.quit);
        assert!(app.status_message.is_none());
    }

    #[test]
    fn synthetic_local_client_cannot_be_disconnected_from_the_menu() {
        let local = ClientInfo {
            client: 0,
            transport: "local".to_string(),
            name: Some("local tui".to_string()),
            kind: Some("tui".to_string()),
            connected_seconds: 1,
            attached: vec![31],
            sizes: vec![ClientSizeInfo { surface: 31, cols: Some(80), rows: Some(24) }],
            is_self: true,
            size_participating: true,
        };
        let Some(MenuItem::Submenu { items, .. }) = client_menu_item(&[local], 31) else {
            panic!("expected connected clients submenu");
        };
        assert!(!items.iter().any(|item| matches!(
            item,
            MenuItem::Submenu { items, .. }
                if items.iter().any(|action| matches!(
                    action,
                    MenuItem::Action(MenuAction::DisconnectClient(0))
                ))
        )));
    }

    #[test]
    fn browser_context_menu_keeps_browser_actions_in_their_own_group() {
        let pane = 7;
        let groups = pane_context_menu_groups(pane, true, true);

        assert_eq!(
            groups[2],
            vec![
                MenuAction::BrowserBack(pane),
                MenuAction::BrowserForward(pane),
                MenuAction::BrowserReload(pane),
                MenuAction::BrowserEditUrl(pane),
                MenuAction::BrowserCopyUrl(pane),
                MenuAction::BrowserActivate(pane),
            ]
        );
    }

    #[test]
    fn context_menu_drops_only_overflowing_separators_and_restores_them_after_resize() {
        let pane = 7;
        let mut menu = ContextMenu::at(10, 5, pane_context_menu_groups(pane, true, true));
        menu.levels[0].selected = menu.levels[0]
            .items
            .iter()
            .position(|item| item.action() == Some(MenuAction::CopyPaneId(pane)))
            .unwrap();

        assert_eq!(menu.levels[0].items.len(), 19);
        assert_eq!(
            menu.levels[0].items.iter().filter(|item| **item == MenuItem::Separator).count(),
            4
        );
        menu.fit_to_rows(18);
        assert_eq!(menu.levels[0].items.len(), 18);
        assert_eq!(
            menu.levels[0].items.iter().filter(|item| **item == MenuItem::Separator).count(),
            3
        );
        assert_eq!(menu.selected_action(), Some(MenuAction::CopyPaneId(pane)));
        assert_eq!(menu.levels[0].rect.height, 20);

        menu.fit_to_rows(19);
        assert_eq!(menu.levels[0].items.len(), 19);
        assert_eq!(
            menu.levels[0].items.iter().filter(|item| **item == MenuItem::Separator).count(),
            4
        );
        assert_eq!(menu.selected_action(), Some(MenuAction::CopyPaneId(pane)));
    }

    #[test]
    fn context_menu_scrolls_selection_and_hit_testing_through_tall_client_lists() {
        let mut menu =
            ContextMenu::at(10, 5, vec![(1..=8).map(MenuAction::UseClientSize).collect()]);

        menu.fit_to_rows(3);
        assert_eq!(menu.levels[0].rect.height, 5);
        assert_eq!(menu.levels[0].scroll_offset, 0);

        for _ in 0..4 {
            menu.select_next();
        }

        assert_eq!(menu.selected_action(), Some(MenuAction::UseClientSize(5)));
        assert_eq!(menu.levels[0].scroll_offset, 2);
        assert_eq!(menu.item_at(10, 5), Some(2));
        assert_eq!(menu.item_at(10, 7), Some(4));
    }

    #[test]
    fn browser_omnibar_reduces_content_rect_for_graphics_and_input() {
        let rect = Rect { x: 10, y: 4, width: 80, height: 24 };
        let (_bar, omnibar, content, track) =
            pane_parts_for_rect(rect, ScrollbarPosition::Column, true);
        assert_eq!(omnibar, Some(Rect { x: 11, y: 5, width: 77, height: 1 }));
        assert_eq!(content, Rect { x: 11, y: 6, width: 77, height: 21 });
        assert_eq!(track, Some(Rect { x: 88, y: 5, width: 1, height: 22 }));
    }

    #[test]
    fn browser_omnibar_degrades_gracefully_with_one_content_row() {
        let rect = Rect { x: 0, y: 0, width: 20, height: 3 };
        let (_bar, omnibar, content, _track) =
            pane_parts_for_rect(rect, ScrollbarPosition::Border, true);
        assert_eq!(omnibar, None);
        assert_eq!(content, Rect { x: 1, y: 1, width: 18, height: 1 });
    }

    #[test]
    fn browser_tab_size_hint_uses_omnibar_reduced_content() {
        let rect = Rect { x: 10, y: 4, width: 80, height: 24 };
        assert_eq!(browser_content_size_for_rect(rect, ScrollbarPosition::Column), Some((77, 21)));
    }

    #[test]
    fn hover_forwarding_only_runs_for_live_non_editing_browser() {
        assert!(browser_hover_forward_allowed(Some(BrowserStatus::Live), false));
        assert!(!browser_hover_forward_allowed(Some(BrowserStatus::Live), true));
        assert!(!browser_hover_forward_allowed(Some(BrowserStatus::Starting), false));
        assert!(!browser_hover_forward_allowed(
            Some(BrowserStatus::Failed("boom".to_string())),
            false
        ));
        assert!(!browser_hover_forward_allowed(None, false));
    }

    #[test]
    fn pty_mouse_tracking_forwards_click_release_and_wheel_with_shift_override() {
        let mux = Mux::new(
            "mouse-passthrough-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));

        let mut app = test_app(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        let pane = app.tree.active_screen().unwrap().active_pane;
        let content = Rect { x: 2, y: 3, width: 20, height: 8 };
        app.pane_areas.push(PaneArea {
            pane,
            surface: surface.id,
            rect: Rect { x: 1, y: 2, width: 23, height: 10 },
            bar: Some(Rect { x: 1, y: 2, width: 23, height: 1 }),
            omnibar: None,
            content,
            track: None,
        });
        app.rendered_terminal_bounds.insert(surface.id, content);

        let event = |kind, modifiers| MouseEvent {
            kind,
            column: content.x + 4,
            row: content.y + 2,
            modifiers,
        };

        app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE))
            .unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<0;5;3M");
        assert!(app.selection.is_none());
        assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Left, .. })));

        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002l\x1b[?1006l"));
        app.encode_buf.clear();
        app.handle_mouse(event(MouseEventKind::Up(MouseButton::Left), KeyModifiers::NONE)).unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<0;5;3m");
        assert!(app.drag.is_none());
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));

        app.handle_mouse(event(MouseEventKind::ScrollDown, KeyModifiers::NONE)).unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<65;5;3M");

        app.handle_mouse(event(MouseEventKind::ScrollLeft, KeyModifiers::NONE)).unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<66;5;3M");

        app.handle_mouse(event(MouseEventKind::ScrollRight, KeyModifiers::NONE)).unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<67;5;3M");

        app.encode_buf.clear();
        app.open_context_menu(content.x + 4, content.y + 2);
        app.handle_mouse(event(MouseEventKind::ScrollDown, KeyModifiers::NONE)).unwrap();
        assert!(app.encode_buf.is_empty());
        app.menu = None;

        app.sidebar_focused = true;
        app.handle_mouse(event(MouseEventKind::Down(MouseButton::Right), KeyModifiers::NONE))
            .unwrap();
        assert!(!app.sidebar_focused);
        assert_eq!(app.encode_buf, b"\x1b[<2;5;3M");
        app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE))
            .unwrap();
        assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Right, .. })));
        assert_eq!(app.encode_buf, b"\x1b[<2;5;3M");
        assert_eq!(
            app.handle_mouse(event(MouseEventKind::Drag(MouseButton::Left), KeyModifiers::NONE))
                .unwrap(),
            RenderAction::None
        );
        assert!(app.encode_buf.is_empty());
        app.handle_mouse(event(MouseEventKind::Up(MouseButton::Left), KeyModifiers::NONE)).unwrap();
        assert!(app.encode_buf.is_empty());
        assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Right, .. })));
        app.handle_mouse(event(MouseEventKind::Up(MouseButton::Right), KeyModifiers::NONE))
            .unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<2;5;3m");
        assert!(app.drag.is_none());

        app.handle_mouse(event(MouseEventKind::Down(MouseButton::Right), KeyModifiers::NONE))
            .unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<2;5;3M");
        app.handle_mouse(event(MouseEventKind::Up(MouseButton::Left), KeyModifiers::NONE)).unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<2;5;3M");
        assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Right, .. })));
        app.handle_mouse(event(MouseEventKind::Up(MouseButton::Right), KeyModifiers::NONE))
            .unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<2;5;3m");
        assert!(app.drag.is_none());

        app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE))
            .unwrap();
        app.pane_areas[0].content.x += 3;
        let moved_content = app.pane_areas[0].content;
        app.rendered_terminal_bounds.insert(surface.id, moved_content);
        let moved_event = MouseEvent {
            kind: MouseEventKind::Drag(MouseButton::Left),
            column: moved_content.x + 4,
            row: moved_content.y + 2,
            modifiers: KeyModifiers::NONE,
        };
        app.handle_mouse(moved_event).unwrap();
        assert!(app.encode_buf.is_empty());
        app.handle_mouse(MouseEvent { kind: MouseEventKind::Up(MouseButton::Left), ..moved_event })
            .unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<0;5;3m");
        app.pane_areas[0].content = content;
        app.rendered_terminal_bounds.insert(surface.id, content);

        app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE))
            .unwrap();
        app.open_rename_tab_prompt(Some(pane));
        assert_eq!(app.encode_buf, b"\x1b[<0;5;3m");
        assert!(app.drag.is_none());
        assert!(app.prompt.is_some());
        app.prompt = None;

        app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::NONE))
            .unwrap();
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002l\x1b[?1006l"));
        app.handle(AppEvent::Input(Event::FocusLost)).unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<0;5;3m");
        assert!(app.drag.is_none());

        app.encode_buf.clear();
        app.handle_mouse(event(MouseEventKind::Down(MouseButton::Left), KeyModifiers::SHIFT))
            .unwrap();
        assert!(app.encode_buf.is_empty());
        assert!(app.selection.is_some());
        assert!(matches!(app.drag, Some(Drag::Select { .. })));

        mux.close_surface(surface.id);
    }

    #[test]
    fn foreign_viewport_rejects_pty_mouse_input_outside_rendered_grid() {
        let mux = Mux::new(
            "foreign-viewport-mouse-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(Some("work".to_string()), Some((12, 5))).unwrap();
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));

        let mut app = test_app(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        let pane = app.tree.active_screen().unwrap().active_pane;
        let content = Rect { x: 2, y: 3, width: 20, height: 8 };
        let live = Rect { x: content.x, y: content.y, width: 12, height: 5 };
        app.pane_areas.push(PaneArea {
            pane,
            surface: surface.id,
            rect: Rect { x: 1, y: 2, width: 23, height: 10 },
            bar: Some(Rect { x: 1, y: 2, width: 23, height: 1 }),
            omnibar: None,
            content,
            track: None,
        });
        app.rendered_terminal_bounds.insert(surface.id, live);

        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: live.x + live.width - 1,
            row: live.y + live.height - 1,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
        assert_eq!(app.encode_buf, b"\x1b[<0;12;5M");
        assert!(matches!(app.drag, Some(Drag::PtyMouse { content: rect, .. }) if rect == live));
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: live.x + live.width - 1,
            row: live.y + live.height - 1,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();

        app.encode_buf.clear();
        let dead_column = live.x + live.width;
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: dead_column,
            row: live.y,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
        assert!(app.encode_buf.is_empty());
        assert!(app.drag.is_none());
        assert!(app.selection.is_none());

        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Right),
            column: dead_column,
            row: live.y,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
        assert!(app.menu.is_some());
        app.menu = None;

        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: dead_column,
            row: live.y,
            modifiers: KeyModifiers::SHIFT,
        })
        .unwrap();
        assert!(app.selection.is_none());
        assert!(app.drag.is_none());

        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: live.x + 1,
            row: live.y + 1,
            modifiers: KeyModifiers::SHIFT,
        })
        .unwrap();
        assert!(matches!(app.drag, Some(Drag::Select { content: rect, .. }) if rect == live));
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Drag(MouseButton::Left),
            column: content.x + content.width - 1,
            row: content.y + content.height - 1,
            modifiers: KeyModifiers::SHIFT,
        })
        .unwrap();
        assert_eq!(app.selection.map(|selection| selection.head), Some((11, 4)));
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: content.x + content.width - 1,
            row: content.y + content.height - 1,
            modifiers: KeyModifiers::SHIFT,
        })
        .unwrap();

        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::ScrollDown,
            column: dead_column,
            row: live.y,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
        assert!(app.encode_buf.is_empty());

        app.rendered_terminal_bounds.remove(&surface.id);
        app.handle_mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: live.x,
            row: live.y,
            modifiers: KeyModifiers::NONE,
        })
        .unwrap();
        assert!(app.encode_buf.is_empty());
        assert!(app.selection.is_none());
        assert!(app.drag.is_none());

        mux.close_surface(surface.id);
    }

    #[test]
    fn pointer_motion_does_not_wait_for_terminal_parsing() {
        let mux = Mux::new(
            "mouse-motion-lock-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));
        let held_surface = surface.clone();
        let (locked_tx, locked_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let holder = std::thread::spawn(move || {
            held_surface.with_terminal(|_| {
                locked_tx.send(()).unwrap();
                release_rx.recv().unwrap();
            });
        });
        locked_rx.recv().unwrap();

        let mut app = test_app(Session::Local(mux.clone()));
        assert!(app.forward_pty_mouse_motion_if_uncontended(
            surface.id,
            Rect { x: 2, y: 3, width: 20, height: 8 },
            (6, 5),
            None,
            KeyModifiers::NONE,
            false,
        ));
        assert!(app.forward_pty_mouse_motion_if_uncontended(
            surface.id,
            Rect { x: 2, y: 3, width: 20, height: 8 },
            (7, 5),
            Some(GhosttyMouseButton::Left),
            KeyModifiers::NONE,
            true,
        ));

        release_tx.send(()).unwrap();
        holder.join().unwrap();
        mux.close_surface(surface.id);
    }

    #[test]
    fn pty_mouse_press_does_not_wait_for_terminal_parsing() {
        let mux = Mux::new(
            "mouse-press-lock-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1002h\x1b[?1006h"));
        let mut app = test_app(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        let pane = app.tree.active_screen().unwrap().active_pane;
        let content = Rect { x: 2, y: 3, width: 20, height: 8 };
        app.pane_areas.push(PaneArea {
            pane,
            surface: surface.id,
            rect: Rect { x: 1, y: 2, width: 23, height: 10 },
            bar: Some(Rect { x: 1, y: 2, width: 23, height: 1 }),
            omnibar: None,
            content,
            track: None,
        });
        app.rendered_terminal_bounds.insert(surface.id, content);

        let held_surface = surface.clone();
        let (locked_tx, locked_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let holder = std::thread::spawn(move || {
            held_surface.with_terminal(|_| {
                locked_tx.send(()).unwrap();
                release_rx.recv().unwrap();
            });
        });
        locked_rx.recv().unwrap();

        let (result_tx, result_rx) = std::sync::mpsc::channel();
        let input = std::thread::spawn(move || {
            result_tx
                .send(app.begin_pty_mouse_drag(
                    content.x + 4,
                    content.y + 2,
                    MouseButton::Left,
                    KeyModifiers::NONE,
                ))
                .unwrap();
        });
        let result = result_rx.recv_timeout(Duration::from_millis(250));
        release_tx.send(()).unwrap();
        holder.join().unwrap();
        input.join().unwrap();

        assert_eq!(result.unwrap(), PtyMousePressResult::Started);
        mux.close_surface(surface.id);
    }

    #[test]
    fn disabled_mouse_snapshot_does_not_consume_press() {
        let mux = Mux::new("disabled-mouse-press-test", SurfaceOptions::default());
        let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        let pane = app.tree.active_screen().unwrap().active_pane;
        let content = Rect { x: 2, y: 3, width: 20, height: 8 };
        app.pane_areas.push(PaneArea {
            pane,
            surface: surface.id,
            rect: Rect { x: 1, y: 2, width: 23, height: 10 },
            bar: Some(Rect { x: 1, y: 2, width: 23, height: 1 }),
            omnibar: None,
            content,
            track: None,
        });
        app.rendered_terminal_bounds.insert(surface.id, content);
        app.sidebar_focused = true;

        assert_eq!(
            app.begin_pty_mouse_drag(
                content.x + 4,
                content.y + 2,
                MouseButton::Left,
                KeyModifiers::NONE,
            ),
            PtyMousePressResult::NotOwned
        );
        assert!(app.sidebar_focused);
        assert!(app.drag.is_none());
        assert!(app.encode_buf.is_empty());
        mux.close_surface(surface.id);
    }

    #[test]
    fn rejected_input_shows_an_error_without_disconnecting() {
        let mux = Mux::new("oversized-input-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));

        assert!(!app.handle_pty_enqueue_result(PtyInputEnqueueResult::Oversized));
        assert_eq!(app.status_message.as_deref(), Some("Input exceeds the 4 MiB PTY buffer limit"));
        assert!(!app.quit);

        assert!(!app.handle_pty_enqueue_result(PtyInputEnqueueResult::Saturated));
        assert_eq!(
            app.status_message.as_deref(),
            Some("PTY input queue is full; input was not sent")
        );
        assert!(!app.quit);

        assert!(!app.handle_pty_enqueue_result(PtyInputEnqueueResult::Failed));
        assert_eq!(
            app.status_message.as_deref(),
            Some("PTY input is unavailable after a transport failure")
        );
        assert!(!app.quit);
    }

    #[test]
    fn rejected_release_clears_the_active_pty_drag() {
        let mux = Mux::new("rejected-release-drag-test", SurfaceOptions::default());
        let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1000h\x1b[?1006h"));
        let mut app = test_app(Session::Local(mux));
        app.drag = Some(Drag::PtyMouse {
            surface: surface.id,
            handle: None,
            reservation_id: 41,
            release_bytes: PtyInputBytes::from_slice(b"fallback-release"),
            content: Rect { x: 1, y: 1, width: 20, height: 8 },
            button: MouseButton::Left,
            position: (4, 3),
            modifiers: KeyModifiers::NONE,
        });
        assert!(app.pty_input.shutdown(Duration::from_secs(1)));

        assert!(app.finish_pty_mouse_drag(4, 3, MouseButton::Left, KeyModifiers::NONE));

        assert!(app.drag.is_none());
        assert_eq!(
            app.status_message.as_deref(),
            Some("PTY input queue is full; input was not sent")
        );
    }

    #[test]
    fn mismatched_release_preserves_the_active_pty_drag() {
        let mux = Mux::new("mismatched-release-drag-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.drag = Some(Drag::PtyMouse {
            surface: 42,
            handle: None,
            reservation_id: 41,
            release_bytes: PtyInputBytes::from_slice(b"fallback-release"),
            content: Rect { x: 1, y: 1, width: 20, height: 8 },
            button: MouseButton::Left,
            position: (4, 3),
            modifiers: KeyModifiers::NONE,
        });

        assert!(app.finish_pty_mouse_drag(4, 3, MouseButton::Right, KeyModifiers::NONE));
        assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Left, .. })));
    }

    #[test]
    fn motion_failure_preserves_pty_drag_for_the_physical_release() {
        let mux = Mux::new("motion-failure-drag-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.drag = Some(Drag::PtyMouse {
            surface: 42,
            handle: None,
            reservation_id: 1,
            release_bytes: PtyInputBytes::from_slice(b"release"),
            content: Rect { x: 1, y: 1, width: 20, height: 8 },
            button: MouseButton::Right,
            position: (4, 3),
            modifiers: KeyModifiers::NONE,
        });

        app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
            surface_id: Some(42),
            kind: Some(PtyInputKind::Motion),
            reservation_id: None,
            label: "PTY input",
            error: "write failed".to_string(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        }))
        .unwrap();

        assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Right, .. })));
    }

    #[test]
    fn rejected_motion_enqueue_rolls_back_mouse_encoder_dedupe() {
        let mux = Mux::new("motion-enqueue-rollback-test", SurfaceOptions::default());
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));
        let handle = SurfaceHandle::Local(surface.clone(), mux.clone());
        let mut app = test_app(Session::Local(mux.clone()));
        let input = test_mouse_motion();

        assert!(!encode_test_mouse_motion(&handle, input).is_empty());
        assert!(encode_test_mouse_motion(&handle, input).is_empty());

        app.rollback_mouse_motion_for_enqueue_failure(
            surface.id,
            PtyInputKind::Motion,
            PtyInputEnqueueResult::Saturated,
        );
        assert!(!encode_test_mouse_motion(&handle, input).is_empty());
        assert!(encode_test_mouse_motion(&handle, input).is_empty());

        app.rollback_mouse_motion_for_enqueue_failure(
            surface.id,
            PtyInputKind::Motion,
            PtyInputEnqueueResult::Failed,
        );
        assert!(!encode_test_mouse_motion(&handle, input).is_empty());
        mux.close_surface(surface.id);
    }

    #[test]
    fn evicted_known_undelivered_motion_allows_same_cell_retry() {
        let mux = Mux::new("motion-cancel-rollback-test", SurfaceOptions::default());
        let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1003h\x1b[?1006h"));
        let handle = SurfaceHandle::Local(surface.clone(), mux.clone());
        let mut app = test_app(Session::Local(mux.clone()));
        let input = test_mouse_motion();

        assert!(!encode_test_mouse_motion(&handle, input).is_empty());
        assert!(encode_test_mouse_motion(&handle, input).is_empty());
        app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
            surface_id: Some(surface.id),
            kind: Some(PtyInputKind::Motion),
            reservation_id: None,
            label: "PTY input",
            error: "remote session did not respond".to_string(),
            lane_failed: false,
            delivery: PtyOperationDelivery::Ambiguous,
        }))
        .unwrap();
        assert!(encode_test_mouse_motion(&handle, input).is_empty());

        app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
            surface_id: Some(surface.id),
            kind: Some(PtyInputKind::Motion),
            reservation_id: None,
            label: "PTY input",
            error: "evicted from the bounded PTY queue before delivery".to_string(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        }))
        .unwrap();
        assert!(!encode_test_mouse_motion(&handle, input).is_empty());
        mux.close_surface(surface.id);
    }

    #[test]
    fn lane_failure_clears_pty_drag_after_nonpress_failure() {
        let mux = Mux::new("lane-failure-drag-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.drag = Some(Drag::PtyMouse {
            surface: 42,
            handle: None,
            reservation_id: 1,
            release_bytes: PtyInputBytes::from_slice(b"release"),
            content: Rect { x: 1, y: 1, width: 20, height: 8 },
            button: MouseButton::Right,
            position: (4, 3),
            modifiers: KeyModifiers::NONE,
        });

        app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
            surface_id: Some(42),
            kind: Some(PtyInputKind::Motion),
            reservation_id: None,
            label: "PTY input",
            error: "remote session did not respond".to_string(),
            lane_failed: true,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        }))
        .unwrap();

        assert!(app.drag.is_none());
    }

    #[test]
    fn ambiguous_press_failure_preserves_pty_drag_for_the_physical_release() {
        let mux = Mux::new("ambiguous-press-drag-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.drag = Some(Drag::PtyMouse {
            surface: 42,
            handle: None,
            reservation_id: 7,
            release_bytes: PtyInputBytes::from_slice(b"release"),
            content: Rect { x: 1, y: 1, width: 20, height: 8 },
            button: MouseButton::Left,
            position: (4, 3),
            modifiers: KeyModifiers::NONE,
        });

        app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
            surface_id: Some(42),
            kind: Some(PtyInputKind::Press),
            reservation_id: Some(7),
            label: "PTY input",
            error: "remote session did not respond".to_string(),
            lane_failed: false,
            delivery: PtyOperationDelivery::Ambiguous,
        }))
        .unwrap();

        assert!(matches!(app.drag, Some(Drag::PtyMouse { button: MouseButton::Left, .. })));
    }

    #[test]
    fn old_press_failure_does_not_clear_new_press_on_the_same_surface() {
        let mux = Mux::new("press-reservation-identity-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.drag = Some(Drag::PtyMouse {
            surface: 42,
            handle: None,
            reservation_id: 9,
            release_bytes: PtyInputBytes::from_slice(b"release"),
            content: Rect { x: 1, y: 1, width: 20, height: 8 },
            button: MouseButton::Left,
            position: (4, 3),
            modifiers: KeyModifiers::NONE,
        });

        app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
            surface_id: Some(42),
            kind: Some(PtyInputKind::Press),
            reservation_id: Some(8),
            label: "PTY input",
            error: "old press rejected".to_string(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        }))
        .unwrap();
        assert!(matches!(app.drag, Some(Drag::PtyMouse { reservation_id: 9, .. })));

        app.handle(AppEvent::PtyOperationFailed(PtyOperationFailure {
            surface_id: Some(42),
            kind: Some(PtyInputKind::Press),
            reservation_id: Some(9),
            label: "PTY input",
            error: "current press rejected".to_string(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        }))
        .unwrap();
        assert!(app.drag.is_none());
    }

    #[test]
    fn input_waits_for_prior_session_mutation_to_settle() {
        let mux = Mux::new("pending-mutation-input-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        app.session.enqueue("blocking selection", move |_| {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();

        assert_eq!(app.deferred_input.len(), 1);
        release_tx.send(()).unwrap();
        let settled = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(settled, AppEvent::SessionMutationSettled { .. }));
        app.handle(settled).unwrap();
        assert!(app.routing_refresh_pending);
        app.routing_refresh_pending = false;
        app.replay_deferred_input().unwrap();
        assert!(app.deferred_input.is_empty());
        assert!(!app.session.has_pending_mutations());
    }

    #[test]
    fn input_never_reasserts_a_viewer_size() {
        let mux = Mux::new(
            "input-size-independence-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(None, Some((120, 40))).unwrap();
        mux.resize_surface_for_client(surface.id, 0, 120, 40).unwrap();
        mux.resize_surface_for_client(surface.id, 99, 80, 30).unwrap();

        let mut app = test_app(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        let pane = app.tree.active_screen().unwrap().active_pane;
        let content = Rect { x: 1, y: 1, width: 120, height: 40 };
        app.pane_areas.push(PaneArea {
            pane,
            surface: surface.id,
            rect: content,
            bar: None,
            omnibar: None,
            content,
            track: None,
        });

        let inputs = [
            Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
            Event::Mouse(MouseEvent {
                kind: MouseEventKind::Moved,
                column: 2,
                row: 2,
                modifiers: KeyModifiers::NONE,
            }),
            Event::Paste("pasted".to_string()),
        ];
        for input in inputs {
            mux.record_client_size(99, 33);
            app.handle(AppEvent::Input(input)).unwrap();
            assert_eq!(mux.new_workspace(None, None).unwrap().size(), (99, 33));
        }
    }

    #[test]
    fn canceled_mutation_does_not_block_on_a_full_app_channel() {
        let (events, receiver) = std::sync::mpsc::sync_channel(1);
        events.send(AppEvent::MuxTitlesReady).unwrap();
        let pending_mutations = Arc::new(std::sync::atomic::AtomicUsize::new(1));
        let pending_routing_mutations = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let cancellation_pending = Arc::new(AtomicBool::new(false));

        drop(PendingSessionMutation(Arc::new(PendingSessionMutationState {
            events,
            pending_mutations: pending_mutations.clone(),
            pending_routing_mutations,
            routing: false,
            cancellation_pending: cancellation_pending.clone(),
            settled: AtomicBool::new(false),
            deferred_outcome: Mutex::new(None),
            canceled_outcome: Mutex::new(None),
        })));

        assert_eq!(pending_mutations.load(Ordering::Acquire), 0);
        assert!(cancellation_pending.load(Ordering::Acquire));
        assert!(matches!(receiver.try_recv(), Ok(AppEvent::MuxTitlesReady)));
    }

    #[test]
    fn superseded_mutation_settles_without_canceling_session_input() {
        let (events, receiver) = std::sync::mpsc::sync_channel(1);
        let pending_mutations = Arc::new(std::sync::atomic::AtomicUsize::new(1));
        let pending_routing_mutations = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let cancellation_pending = Arc::new(AtomicBool::new(false));
        let pending = PendingSessionMutation(Arc::new(PendingSessionMutationState {
            events,
            pending_mutations: pending_mutations.clone(),
            pending_routing_mutations,
            routing: false,
            cancellation_pending: cancellation_pending.clone(),
            settled: AtomicBool::new(false),
            deferred_outcome: Mutex::new(None),
            canceled_outcome: Mutex::new(None),
        }));

        pending.clone().supersede();
        drop(pending);

        assert_eq!(pending_mutations.load(Ordering::Acquire), 0);
        assert!(!cancellation_pending.load(Ordering::Acquire));
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn pty_failure_ingress_rearms_after_a_full_app_channel_loses_its_wake() {
        let ingress = PtyFailureIngress::default();
        let (events, receiver) = std::sync::mpsc::sync_channel(1);
        events.send(AppEvent::MuxTitlesReady).unwrap();
        for index in 0..1_000 {
            let wake = ingress.push(PtyOperationFailure {
                surface_id: Some(42),
                kind: Some(PtyInputKind::Motion),
                reservation_id: None,
                label: "PTY input",
                error: format!("motion {index}"),
                lane_failed: false,
                delivery: PtyOperationDelivery::KnownNotDelivered,
            });
            if wake {
                assert!(matches!(
                    events.try_send(AppEvent::PtyFailuresReady),
                    Err(std::sync::mpsc::TrySendError::Full(_))
                ));
            }
        }

        let failures = ingress.take();
        assert_eq!(failures.len(), 1);
        assert_eq!(failures.front().unwrap().error, "motion 999");
        assert!(matches!(receiver.try_recv(), Ok(AppEvent::MuxTitlesReady)));

        assert!(ingress.push(PtyOperationFailure {
            surface_id: Some(42),
            kind: Some(PtyInputKind::Motion),
            reservation_id: None,
            label: "PTY input",
            error: "motion after drain".into(),
            lane_failed: false,
            delivery: PtyOperationDelivery::KnownNotDelivered,
        }));
    }

    #[test]
    fn deferred_input_is_discarded_when_its_destination_changes() {
        let mux = Mux::new("deferred-destination-test", SurfaceOptions::default());
        let surface = mux.new_workspace(None, None).unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());
        app.session.pending_mutations.store(1, Ordering::Release);

        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();
        assert_eq!(
            app.deferred_input.front().and_then(|input| input.destination),
            Some(surface.id)
        );

        app.session.pending_mutations.store(0, Ordering::Release);
        app.replace_tree(notify_tree(surface.id + 1, false));
        app.replay_deferred_input().unwrap();

        assert!(app.deferred_input.is_empty());
        assert_eq!(
            app.status_message.as_deref(),
            Some("Deferred input was discarded because its destination changed")
        );
    }

    #[test]
    fn deferred_input_follows_a_committed_routing_mutation() {
        let mux = Mux::new("deferred-routing-generation-test", SurfaceOptions::default());
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, None).unwrap();
        mux.select_tab(Some(pane), Some(0), None);
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.replace_tree(app.session.tree());

        app.session.select_tab(Some(pane), Some(1), None);
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();
        assert_eq!(app.deferred_input.front().and_then(|input| input.destination), Some(first.id));

        let settled = events.recv_timeout(Duration::from_secs(1)).unwrap();
        app.handle(settled).unwrap();
        app.routing_refresh_pending = false;
        app.replay_deferred_input().unwrap();

        assert_eq!(app.active_surface(), Some(second.id));
        assert!(app.deferred_input.is_empty());
        assert_ne!(
            app.status_message.as_deref(),
            Some("Deferred input was discarded because its destination changed")
        );
    }

    #[test]
    fn tab_switch_moves_size_lease_without_dropping_hidden_surface() {
        let mux = Mux::new("visible-tab-sizing-test", SurfaceOptions::default());
        let first = mux.new_workspace(None, Some((120, 40))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, Some((120, 40))).unwrap();
        mux.select_tab(Some(pane), Some(0), None);
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.sync_layout((160, 50));
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(Duration::from_secs(1)).unwrap()).unwrap();
        }

        assert!(mux.client_surface_size(first.id, 0).is_some());
        assert_eq!(mux.client_surface_size(second.id, 0), None);
        assert!(app.session.has_surface(second.id));

        mux.select_tab(Some(pane), Some(1), None);
        app.sync_layout((160, 50));
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(Duration::from_secs(1)).unwrap()).unwrap();
        }

        assert_eq!(mux.client_surface_size(first.id, 0), None);
        assert!(mux.client_surface_size(second.id, 0).is_some());
        assert!(app.session.has_surface(first.id));
        let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
        mux.close_workspace(workspace);
    }

    #[test]
    fn deferred_input_does_not_follow_a_later_routing_mutation() {
        let mux = Mux::new("deferred-later-routing-test", SurfaceOptions::default());
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let second = mux.new_tab(Some(pane), None, None).unwrap();
        let third = mux.new_tab(Some(pane), None, None).unwrap();
        mux.select_tab(Some(pane), Some(0), None);
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.replace_tree(app.session.tree());

        app.session.select_tab(Some(pane), Some(1), None);
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();
        assert_eq!(app.deferred_input.front().and_then(|input| input.routing_intent), Some(1));
        app.session.select_tab(Some(pane), Some(2), None);

        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(Duration::from_secs(1)).unwrap()).unwrap();
        }
        app.routing_refresh_pending = false;
        app.replay_deferred_input().unwrap();

        assert_eq!(app.active_surface(), Some(third.id));
        assert_ne!(app.active_surface(), Some(second.id));
        assert!(app.deferred_input.is_empty());
        assert_eq!(
            app.status_message.as_deref(),
            Some("Deferred input was discarded because its destination changed")
        );
    }

    #[test]
    fn stale_remote_snapshot_does_not_mark_pending_route_applied() {
        let mux = Mux::new("stale-routing-snapshot-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.session.remote = true;
        app.session.routing_mutation_started.store(1, Ordering::Release);
        app.session.routing_mutation_committed.store(1, Ordering::Release);
        app.replace_tree(notify_tree(41, false));
        app.routing_refresh_pending = true;

        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();

        assert_eq!(app.applied_routing_generation, 0);
        assert_eq!(app.deferred_input.front().and_then(|input| input.routing_intent), Some(1));

        app.handle(AppEvent::RemoteTreeUpdated {
            refresh_sequence: 1,
            routing_generation: 1,
            result: Ok(notify_tree(42, false)),
        })
        .unwrap();
        assert_eq!(app.applied_routing_generation, 1);
    }

    #[test]
    fn identity_refresh_completion_consumes_coalesced_background_refresh() {
        let mux = Mux::new("identity-refresh-dirty-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.session.remote = true;
        app.session.pending_mutations.store(1, Ordering::Release);
        app.session.remote_background_dirty.store(true, Ordering::Release);

        app.handle(settled(super::SessionMutationOutcome::IdentityRefreshSucceeded {
            tree: TreeView::default(),
            authoritative_generation: 0,
            routing_generation: 0,
            refresh_sequence: 1,
        }))
        .unwrap();

        assert!(!app.session.remote_background_dirty.load(Ordering::Acquire));
        assert!(!app.session.has_pending_mutations());
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(1)).unwrap(),
            AppEvent::RemoteTreeUpdated { result: Ok(_), .. }
        ));
    }

    #[test]
    fn title_ingress_keeps_latest_per_surface_with_one_app_wake() {
        let mux = Mux::new("title-ingress-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let updated_surface = 41;
        let untouched_surface = 42;
        app.replace_tree(browser_completion_tree(updated_surface, untouched_surface));
        let (wake_tx, wake_rx) = std::sync::mpsc::channel();

        for index in 0..10_000 {
            if app.mux_titles.push(updated_surface, format!("title-{index}")) {
                wake_tx.send(AppEvent::MuxTitlesReady).unwrap();
            }
            if app.mux_titles.push(99, format!("unknown-{index}")) {
                wake_tx.send(AppEvent::MuxTitlesReady).unwrap();
            }
        }

        let wake = wake_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(wake_rx.try_recv().is_err(), "title churn must queue one app wake");
        assert!(matches!(app.handle(wake).unwrap(), RenderAction::Paint));
        assert_eq!(app.tree.pane(2).unwrap().tabs[0].title, "title-9999");
        assert_eq!(app.tree.pane(2).unwrap().tabs[1].title, "");
        assert!(app.mux_titles.push(updated_surface, "next".to_string()));
        let dirty = app.mux_titles.take_dirty();
        assert_eq!(dirty.len(), 1);
        assert_eq!(dirty.get(&updated_surface).map(AsRef::as_ref), Some("next"));
        assert_eq!(app.mux_titles.snapshot().len(), 2);
    }

    #[test]
    fn title_ingress_reapplies_after_old_and_future_tree_snapshots() {
        let mux = Mux::new("title-snapshot-order-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));

        app.replace_tree(notify_tree(41, false));
        assert!(app.mux_titles.push(41, "live-title".to_string()));
        app.handle(AppEvent::MuxTitlesReady).unwrap();
        assert_eq!(app.tree.pane(2).unwrap().tabs[0].title, "live-title");

        app.replace_tree(notify_tree(41, false));
        assert_eq!(app.tree.pane(2).unwrap().tabs[0].title, "live-title");

        assert!(app.mux_titles.push(42, "future-title".to_string()));
        app.handle(AppEvent::MuxTitlesReady).unwrap();
        app.replace_tree(notify_tree(42, false));
        assert_eq!(app.tree.pane(2).unwrap().tabs[0].title, "future-title");
    }

    #[test]
    fn title_ingress_prunes_all_pre_snapshot_titles_but_keeps_concurrent_updates() {
        let titles = MuxTitleIngress::default();
        titles.push(41, "stale-title");
        let snapshot_epoch = titles.current_epoch();
        titles.push(42, "concurrent-title");

        titles.reconcile_authoritative(snapshot_epoch);

        let retained = titles.snapshot();
        assert!(!retained.contains_key(&41));
        assert_eq!(retained.get(&42).map(AsRef::as_ref), Some("concurrent-title"));
    }

    #[test]
    fn title_ingress_rearms_a_lost_wake_after_failed_recovery() {
        let titles = MuxTitleIngress::default();
        assert!(titles.push(41, "first"));
        assert!(!titles.push(41, "latest"));

        assert!(titles.rearm_wake());
        assert_eq!(titles.take_dirty().get(&41).map(AsRef::as_ref), Some("latest"));
        assert!(!titles.rearm_wake());
        assert!(titles.push(41, "next"));
    }

    #[test]
    fn mux_forwarder_recovers_after_bounded_mailbox_overflow() {
        let mux = Mux::new("mux-forwarder-overflow-test", SurfaceOptions::default());
        let event_source = Session::Local(mux.clone());
        let session_events = event_source.events();
        for surface in 0..5_000 {
            mux.emit(MuxEvent::Bell(surface));
        }
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        let titles = Arc::new(MuxTitleIngress::default());
        let routing_generation = Arc::new(AtomicU64::new(0));
        let recovery_generation = Arc::new(AtomicU64::new(0));
        let forwarder_recovery_generation = recovery_generation.clone();
        let forwarder = std::thread::spawn(move || {
            forward_mux_events(
                event_source,
                session_events,
                routing_generation,
                forwarder_recovery_generation,
                tx,
                titles,
            );
        });

        let first = rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while recovery_generation.load(Ordering::Acquire) == 0 && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(
            recovery_generation.load(Ordering::Acquire) > 0,
            "the routing barrier must rise before the stale app backlog is drained"
        );

        let mut next = Some(first);
        let mut recovered_generations = HashSet::new();
        let mut preserved_bells = 0;
        let final_generation = loop {
            let event =
                next.take().unwrap_or_else(|| rx.recv_timeout(Duration::from_secs(1)).unwrap());
            match event {
                AppEvent::MuxSubscriptionRecovered {
                    recovery_generation, result: Ok(_), ..
                } => {
                    recovered_generations.insert(recovery_generation);
                }
                AppEvent::MuxRecoveryComplete { recovery_generation }
                    if recovered_generations.contains(&recovery_generation) =>
                {
                    break recovery_generation;
                }
                AppEvent::Mux(MuxEvent::Bell(_)) => preserved_bells += 1,
                _ => {}
            }
        };
        assert_eq!(preserved_bells, 4_096);
        assert_eq!(recovery_generation.load(Ordering::Acquire), final_generation);

        mux.emit(MuxEvent::Bell(9_999));
        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            AppEvent::Mux(MuxEvent::Bell(9_999))
        ));
        mux.emit(MuxEvent::Empty);
        assert!(matches!(
            rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            AppEvent::Mux(MuxEvent::Empty)
        ));
        drop(rx);
        forwarder.join().unwrap();
    }

    #[test]
    fn mux_forwarder_preserves_empty_while_app_channel_is_full() {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        tx.send(AppEvent::Mux(MuxEvent::Bell(1))).unwrap();
        let titles = MuxTitleIngress::default();
        let forwarder =
            std::thread::spawn(move || forward_mux_event(MuxEvent::Empty, &tx, &titles));

        assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(1))));
        assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Empty)));
        assert!(matches!(forwarder.join().unwrap(), ForwardMuxOutcome::Stop));
    }

    #[test]
    fn mux_forwarder_preserves_resize_completion_while_app_channel_is_full() {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        tx.send(AppEvent::Mux(MuxEvent::Bell(1))).unwrap();
        let titles = MuxTitleIngress::default();
        let forwarder = std::thread::spawn(move || {
            forward_mux_event(
                MuxEvent::SurfaceResized {
                    surface: 41,
                    cols: 90,
                    rows: 31,
                    reservation_id: Some(7),
                },
                &tx,
                &titles,
            )
        });

        assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(1))));
        assert!(matches!(
            rx.recv().unwrap(),
            AppEvent::Mux(MuxEvent::SurfaceResized { surface: 41, reservation_id: Some(7), .. })
        ));
        assert!(matches!(forwarder.join().unwrap(), ForwardMuxOutcome::Continue));
    }

    #[test]
    fn mux_forwarder_preserves_one_shot_event_while_app_channel_is_full() {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        tx.send(AppEvent::Mux(MuxEvent::Bell(1))).unwrap();
        let titles = MuxTitleIngress::default();
        let forwarder =
            std::thread::spawn(move || forward_mux_event(MuxEvent::Bell(2), &tx, &titles));

        assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(1))));
        assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(2))));
        assert!(matches!(forwarder.join().unwrap(), ForwardMuxOutcome::Continue));
    }

    #[test]
    fn title_wake_waits_for_app_capacity_without_triggering_recovery() {
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        tx.send(AppEvent::Mux(MuxEvent::Bell(1))).unwrap();
        let titles = Arc::new(MuxTitleIngress::default());
        let forwarded_titles = titles.clone();
        let forwarder = std::thread::spawn(move || {
            forward_mux_event(
                MuxEvent::TitleChanged { surface: 41, title: "latest".into() },
                &tx,
                &forwarded_titles,
            )
        });

        assert!(matches!(rx.recv().unwrap(), AppEvent::Mux(MuxEvent::Bell(1))));
        assert!(matches!(rx.recv().unwrap(), AppEvent::MuxTitlesReady));
        assert!(matches!(forwarder.join().unwrap(), ForwardMuxOutcome::Continue));
        assert_eq!(titles.take_dirty().get(&41).map(AsRef::as_ref), Some("latest"));
    }

    #[test]
    fn mux_recovery_barrier_defers_input_until_authoritative_tree_is_applied() {
        let mux = Mux::new("mux-recovery-barrier-test", SurfaceOptions::default());
        mux.new_workspace(None, None).unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());
        app.mux_recovery_generation.store(1, Ordering::Release);

        app.handle(AppEvent::Input(Event::Paste("queued".to_string()))).unwrap();
        assert_eq!(app.deferred_input.len(), 1);
        let client_refresh_generation = app.session.client_refresh_generation();

        app.handle(AppEvent::MuxSubscriptionRecovered {
            recovery_generation: 1,
            routing_generation: 0,
            result: Ok(app.session.tree()),
        })
        .unwrap();
        assert_eq!(app.mux_recovery_generation.load(Ordering::Acquire), 1);
        assert_eq!(app.deferred_input.len(), 1);
        assert!(app.session.client_refresh_generation() > client_refresh_generation);

        app.handle(AppEvent::MuxRecoveryComplete { recovery_generation: 1 }).unwrap();
        assert_eq!(app.mux_recovery_generation.load(Ordering::Acquire), 0);
        assert!(app.routing_refresh_pending);
    }

    #[test]
    fn remote_subscription_recovery_signal_refreshes_client_snapshot() {
        let mux = Mux::new("client-list-recovery-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let before = app.session.client_refresh_generation();

        app.handle(AppEvent::Mux(MuxEvent::ClientListInvalidated)).unwrap();

        assert!(app.session.client_refresh_generation() > before);
    }

    #[test]
    fn failed_mux_recovery_releases_barrier_and_discards_ambiguous_input() {
        let mux = Mux::new("mux-recovery-failure-test", SurfaceOptions::default());
        mux.new_workspace(None, None).unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());
        app.mux_recovery_generation.store(1, Ordering::Release);
        app.handle(AppEvent::Input(Event::Paste("queued".to_string()))).unwrap();

        app.handle(AppEvent::MuxSubscriptionRecovered {
            recovery_generation: 1,
            routing_generation: 0,
            result: Err("refresh failed".to_string()),
        })
        .unwrap();

        assert_eq!(app.mux_recovery_generation.load(Ordering::Acquire), 0);
        assert!(app.deferred_input.is_empty());
        assert!(app.status_message.as_deref().unwrap().contains("discarded"));
    }

    #[test]
    fn stale_mux_recovery_completion_cannot_release_a_newer_barrier() {
        let mux = Mux::new("stale-mux-recovery-completion-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.mux_recovery_generation.store(2, Ordering::Release);

        app.handle(AppEvent::MuxRecoveryComplete { recovery_generation: 1 }).unwrap();

        assert_eq!(app.mux_recovery_generation.load(Ordering::Acquire), 2);
        assert!(!app.routing_refresh_pending);
    }

    #[test]
    fn authoritative_recovery_prunes_render_state_for_missed_surface_exit() {
        let mux = Mux::new("authoritative-prune-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(notify_tree(42, false));
        app.render_states.insert(42, RenderState::new().unwrap());
        app.mux_titles.push(42, "stale-title".to_string());

        app.replace_authoritative_tree(TreeView::default(), 0);

        assert!(!app.render_states.contains_key(&42));
        assert!(!app.tab_locations.contains_key(&42));
        assert!(!app.mux_titles.snapshot().contains_key(&42));
    }

    #[test]
    fn resize_claims_skip_identical_work_and_replace_a_b_a_reversions() {
        let mux = Mux::new("resize-claim-test", SurfaceOptions::default());
        let app = test_app(Session::Local(mux));
        assert!(matches!(
            app.session.surface_resize_decision(7, (80, 24), false),
            SurfaceResizeDecision::Noop
        ));
        let first = match app.session.surface_resize_decision(7, (100, 30), true) {
            SurfaceResizeDecision::NeedsQueue(claim) => claim,
            _ => panic!("first changed size must queue"),
        };
        for _ in 0..1_000 {
            assert!(matches!(
                app.session.surface_resize_decision(7, (100, 30), true),
                SurfaceResizeDecision::AlreadyClaimed
            ));
        }
        let reverted = match app.session.surface_resize_decision(7, (80, 24), false) {
            SurfaceResizeDecision::NeedsQueue(claim) => claim,
            _ => panic!("different outstanding size must be replaced even when server is current"),
        };
        drop(first);
        assert!(matches!(
            app.session.surface_resize_decision(7, (80, 24), false),
            SurfaceResizeDecision::AlreadyClaimed
        ));
        drop(reverted);
        assert!(matches!(
            app.session.surface_resize_decision(7, (80, 24), false),
            SurfaceResizeDecision::Noop
        ));

        let old_a = match app.session.surface_resize_decision(9, (80, 24), true) {
            SurfaceResizeDecision::NeedsQueue(claim) => claim,
            _ => panic!("first A must queue"),
        };
        let b = match app.session.surface_resize_decision(9, (100, 30), true) {
            SurfaceResizeDecision::NeedsQueue(claim) => claim,
            _ => panic!("B must replace A"),
        };
        let new_a = match app.session.surface_resize_decision(9, (80, 24), true) {
            SurfaceResizeDecision::NeedsQueue(claim) => claim,
            _ => panic!("new A must replace B"),
        };
        drop(old_a);
        drop(b);
        assert!(matches!(
            app.session.surface_resize_decision(9, (80, 24), true),
            SurfaceResizeDecision::AlreadyClaimed
        ));
        drop(new_a);
    }

    #[test]
    fn browser_resize_claim_survives_queue_and_input_barrier_until_drop() {
        let mux = Mux::new("browser-resize-claim-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let (dispatcher, blocked) = BrowserInputDispatcher::blocked(2);
        app.browser_input = dispatcher;
        let claim = match app.session.surface_resize_decision(7, (100, 30), true) {
            SurfaceResizeDecision::NeedsQueue(claim) => claim,
            _ => panic!("browser resize must queue"),
        };
        app.enqueue_surface_resize(
            7,
            SurfaceHandle::RemoteBrowserUnsupported,
            100,
            30,
            false,
            Some(claim),
        );
        assert!(app.session.surface_resize_ownership.lock().unwrap().get(&7).is_none());
        let _ = app.browser_input.enqueue(BrowserInputEvent {
            surface_id: 7,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::Mouse {
                event_type: "mouseMoved",
                x: 1.0,
                y: 1.0,
                button: Some("none"),
                click_count: None,
            },
        });

        assert!(matches!(
            app.session.surface_resize_decision(7, (100, 30), true),
            SurfaceResizeDecision::AlreadyClaimed
        ));
        drop(blocked);
        assert!(matches!(
            app.session.surface_resize_decision(7, (100, 30), true),
            SurfaceResizeDecision::NeedsQueue(_)
        ));
    }

    #[test]
    fn browser_resize_ownership_tracks_only_accepted_dispatches() {
        let ownership = Mutex::new(HashMap::new());

        record_surface_resize_dispatch_result(&ownership, 7, (100, 30), None);
        assert!(ownership.lock().unwrap().is_empty());

        record_surface_resize_dispatch_result(&ownership, 7, (100, 30), Some(41));
        assert_eq!(
            ownership.lock().unwrap().get(&7),
            Some(&SurfaceResizeOwnership { desired: (100, 30), reservation_id: Some(41) })
        );

        record_surface_resize_dispatch_result(&ownership, 7, (100, 30), None);
        assert!(ownership.lock().unwrap().contains_key(&7));
    }

    #[test]
    fn resize_events_do_not_refresh_clients_on_the_event_loop() {
        let mux = Mux::new("resize-client-refresh-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));

        app.handle(AppEvent::Mux(MuxEvent::SurfaceResized {
            surface: 7,
            cols: 80,
            rows: 24,
            reservation_id: None,
        }))
        .unwrap();

        assert!(!app.session.client_refresh_queued.load(Ordering::Acquire));
    }

    #[test]
    fn superseded_client_refresh_results_are_ignored() {
        let mux = Mux::new("stale-client-refresh-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.session.client_refresh_generation.store(2, Ordering::Release);

        app.handle(AppEvent::ClientsUpdated {
            generation: 1,
            result: Err("stale snapshot".to_string()),
        })
        .unwrap();

        assert!(app.status_message.is_none());
    }

    #[test]
    fn failed_size_release_keeps_lease_retryable_until_success() {
        let mux = Mux::new("size-release-retry-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.visible_size_surfaces.insert(7);
        app.pending_size_releases.insert(7);

        app.session.pending_mutations.fetch_add(1, Ordering::Release);
        app.handle(settled(super::SessionMutationOutcome::SurfaceSizeReleaseFailed {
            surface: 7,
            error: "transport closed".to_string(),
        }))
        .unwrap();
        assert!(app.visible_size_surfaces.contains(&7));
        assert!(!app.pending_size_releases.contains(&7));

        app.pending_size_releases.insert(7);
        app.session.pending_mutations.fetch_add(1, Ordering::Release);
        app.handle(settled(super::SessionMutationOutcome::SurfaceSizeReleaseCanceled {
            surface: 7,
        }))
        .unwrap();
        assert!(app.visible_size_surfaces.contains(&7));
        assert!(!app.pending_size_releases.contains(&7));

        app.pending_size_releases.insert(7);
        app.session.pending_mutations.fetch_add(1, Ordering::Release);
        app.handle(settled(super::SessionMutationOutcome::SurfaceSizeReleased { surface: 7 }))
            .unwrap();
        assert!(!app.visible_size_surfaces.contains(&7));
        assert!(!app.pending_size_releases.contains(&7));
    }

    #[test]
    fn failed_surface_sync_is_bounded_until_lifecycle_recovery() {
        let mux = Mux::new("surface-sync-failure-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));

        app.session.attach_surface(77, Some((80, 24)));
        let settled = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            settled,
            AppEvent::SessionMutationSettled {
                outcome: super::SessionMutationOutcome::SurfaceSyncFailed {
                    surface: 77,
                    operation: "attach",
                    ..
                },
                ..
            }
        ));
        app.handle(settled).unwrap();
        assert!(!app.session.can_attach_surface(77));
        app.session.attach_surface(77, Some((80, 24)));
        assert!(events.try_recv().is_err());

        let claim = match app.session.surface_resize_decision(88, (100, 30), true) {
            SurfaceResizeDecision::NeedsQueue(claim) => claim,
            _ => panic!("first resize must queue"),
        };
        app.session.resize_surface(
            88,
            SurfaceHandle::RemoteBrowserUnsupported,
            100,
            30,
            false,
            claim,
        );
        let settled = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            settled,
            AppEvent::SessionMutationSettled {
                outcome: super::SessionMutationOutcome::SurfaceSyncFailed {
                    surface: 88,
                    operation: "resize",
                    ..
                },
                ..
            }
        ));
        app.handle(settled).unwrap();
        assert!(matches!(
            app.session.surface_resize_decision(88, (100, 30), true),
            SurfaceResizeDecision::Failed
        ));

        app.session.clear_surface_sync_failures();
        assert!(app.session.can_attach_surface(77));
        assert!(matches!(
            app.session.surface_resize_decision(88, (100, 30), true),
            SurfaceResizeDecision::NeedsQueue(_)
        ));
    }

    #[test]
    fn ambiguous_attach_timeout_survives_lifecycle_clear_until_reconnect() {
        let mux = Mux::new("ambiguous-attach-timeout-test", SurfaceOptions::default());
        let app = test_app(Session::Local(mux));
        app.session
            .surface_attach_failures
            .lock()
            .unwrap()
            .insert(77, super::next_surface_sync_failure(None, false, true));

        app.session.clear_surface_sync_failures();

        assert!(app.session.surface_attach_failures.lock().unwrap().contains_key(&77));
        assert!(!app.session.can_attach_surface(77));
    }

    #[test]
    fn ambiguous_attach_timeout_discards_input_and_requests_reconnect() {
        let mux = Mux::new("ambiguous-attach-reconnect-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.deferred_input.push_back(DeferredInput {
            event: Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
            destination: Some(77),
            routing_intent: None,
            sidebar_focus_intent: false,
        });
        app.session.pending_mutations.store(1, Ordering::Release);

        app.handle(settled(super::SessionMutationOutcome::SurfaceSyncFailed {
            surface: 77,
            operation: "attach",
            error: "remote session did not respond".to_string(),
            reconnect_required: true,
        }))
        .unwrap();

        assert!(app.deferred_input.is_empty());
        assert!(
            app.status_message
                .as_deref()
                .is_some_and(|message| message.contains("detach and reconnect"))
        );
    }

    #[test]
    fn first_input_for_missing_mirror_is_deferred_through_attach() {
        let mux = Mux::new("missing-mirror-input-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        let surface = 77;
        app.replace_tree(notify_tree(surface, false));
        app.pane_areas.push(browser_completion_area(surface));

        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();

        assert_eq!(app.deferred_input.len(), 1);
        let settled = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            settled,
            AppEvent::SessionMutationSettled {
                outcome: super::SessionMutationOutcome::SurfaceSyncFailed {
                    surface: 77,
                    operation: "attach",
                    ..
                },
                ..
            }
        ));
        app.handle(settled).unwrap();
        assert_eq!(app.deferred_input.len(), 1);

        app.routing_refresh_pending = false;
        app.replay_deferred_input().unwrap();
        assert_eq!(app.deferred_input.len(), 1);
    }

    #[test]
    fn replacing_tree_retires_removed_browser_input_state() {
        let mux = Mux::new("browser-input-topology-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let (dispatcher, _blocked) = BrowserInputDispatcher::blocked(1);
        app.browser_input = dispatcher;
        let surface = 41;
        app.replace_tree(browser_completion_tree(surface, surface));
        let _ = app.browser_input.enqueue(BrowserInputEvent {
            surface_id: surface,
            surface: SurfaceHandle::RemoteBrowserUnsupported,
            kind: BrowserInputKind::InsertText("x".to_string()),
        });
        assert!(app.browser_input.tracks_surface(surface));

        app.replace_tree(TreeView::default());

        assert!(!app.browser_input.tracks_surface(surface));
    }

    #[test]
    fn transient_surface_sync_failures_stop_after_bounded_backoff() {
        let first = super::next_surface_sync_failure(None, true, false);
        assert_eq!(first.attempts, 1);
        assert!(super::surface_sync_failure_blocks(first));

        let elapsed = super::SurfaceSyncFailureState {
            attempts: first.attempts,
            retry_after: Some(Instant::now() - Duration::from_millis(1)),
            sticky_until_reconnect: false,
        };
        assert!(!super::surface_sync_failure_blocks(elapsed));
        let capped = (0..10)
            .fold(elapsed, |state, _| super::next_surface_sync_failure(Some(state), true, false));
        assert_eq!(capped.attempts, 6);
        assert!(capped.retry_after.is_none());
        assert!(capped.sticky_until_reconnect);
        assert!(super::surface_sync_failure_blocks(capped));
    }

    #[test]
    fn due_session_resize_failure_rearms_idle_loop_retry() {
        let mux = Mux::new("session-resize-retry-due-test", SurfaceOptions::default());
        let app = test_app(Session::Local(mux));

        assert!(!app.session.note_surface_resize_failure(41, (90, 31), Some(0), Some(7)));
        assert!(!app.session.surface_resize_retry_due());

        app.session
            .surface_resize_ownership
            .lock()
            .unwrap()
            .insert(41, SurfaceResizeOwnership { desired: (90, 31), reservation_id: Some(7) });
        assert!(app.session.note_surface_resize_failure(41, (90, 31), Some(0), Some(7)));
        assert!(app.session.surface_resize_retry_due());

        app.session.confirm_surface_resize(41, (90, 31), Some(7));
        assert!(!app.session.surface_resize_retry_due());
        assert!(!app.session.surface_resize_ownership.lock().unwrap().contains_key(&41));
    }

    #[test]
    fn stale_same_geometry_completion_does_not_release_newer_resize_owner() {
        let mux = Mux::new("resize-owner-identity-test", SurfaceOptions::default());
        let app = test_app(Session::Local(mux));
        app.session
            .surface_resize_ownership
            .lock()
            .unwrap()
            .insert(41, SurfaceResizeOwnership { desired: (90, 31), reservation_id: Some(9) });

        app.session.confirm_surface_resize(41, (90, 31), Some(7));
        assert_eq!(
            app.session.surface_resize_ownership.lock().unwrap().get(&41).copied(),
            Some(SurfaceResizeOwnership { desired: (90, 31), reservation_id: Some(9) })
        );
        assert!(!app.session.note_surface_resize_failure(41, (90, 31), Some(0), Some(7)));

        app.session.confirm_surface_resize(41, (90, 31), Some(9));
        assert!(!app.session.surface_resize_ownership.lock().unwrap().contains_key(&41));
    }

    #[test]
    fn refresh_sequences_are_monotonic_across_identity_and_background_paths() {
        let mux = Mux::new("refresh-sequence-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let newer = notify_tree(22, false);
        let older = notify_tree(11, false);
        app.session.pending_mutations.store(1, Ordering::Release);
        app.deferred_input.push_back(DeferredInput {
            event: Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
            destination: None,
            routing_intent: None,
            sidebar_focus_intent: false,
        });

        app.handle(AppEvent::RemoteTreeUpdated {
            refresh_sequence: 2,
            routing_generation: 0,
            result: Ok(newer.clone()),
        })
        .unwrap();
        app.handle(settled(super::SessionMutationOutcome::IdentityRefreshSucceeded {
            tree: older.clone(),
            authoritative_generation: 0,
            routing_generation: 0,
            refresh_sequence: 1,
        }))
        .unwrap();
        assert_eq!(app.tree.workspaces[0].screens[0].panes[0].tabs[0].surface, 22);
        assert!(app.routing_refresh_pending);
        assert_eq!(app.deferred_input.len(), 1);

        app.routing_refresh_pending = false;
        app.session.pending_mutations.store(1, Ordering::Release);
        app.handle(settled(super::SessionMutationOutcome::IdentityRefreshSucceeded {
            tree: newer,
            authoritative_generation: 0,
            routing_generation: 0,
            refresh_sequence: 4,
        }))
        .unwrap();
        app.handle(AppEvent::RemoteTreeUpdated {
            refresh_sequence: 3,
            routing_generation: 0,
            result: Ok(older),
        })
        .unwrap();
        assert_eq!(app.tree.workspaces[0].screens[0].panes[0].tabs[0].surface, 22);
    }

    #[test]
    fn stale_identity_refresh_retires_completion_against_newer_tree() {
        let mux = Mux::new("stale-identity-completion-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let surface = 41;
        let tree = browser_completion_tree(surface, surface);
        app.pane_areas.push(browser_completion_area(surface));
        app.pending_session_completions.push_back(SessionCompletion {
            mutation_generation: 4,
            action: SessionCompletionAction::BrowserTabCreated { surface },
        });

        app.handle(AppEvent::RemoteTreeUpdated {
            refresh_sequence: 2,
            routing_generation: 0,
            result: Ok(tree.clone()),
        })
        .unwrap();
        app.session.pending_mutations.store(1, Ordering::Release);
        app.handle(settled(super::SessionMutationOutcome::IdentityRefreshSucceeded {
            tree,
            authoritative_generation: 4,
            routing_generation: 0,
            refresh_sequence: 1,
        }))
        .unwrap();

        assert!(app.pending_session_completions.is_empty());
        assert_eq!(app.omnibar.as_ref().map(|state| state.surface), Some(surface));
    }

    #[test]
    fn background_tree_snapshot_sets_input_routing_barrier() {
        let mux = Mux::new("background-routing-barrier-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.handle(AppEvent::RemoteTreeUpdated {
            refresh_sequence: 1,
            routing_generation: 0,
            result: Ok(notify_tree(22, false)),
        })
        .unwrap();

        assert!(app.routing_refresh_pending);
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();
        assert_eq!(app.deferred_input.len(), 1);
    }

    #[test]
    fn background_tree_refresh_stops_after_retry_budget() {
        let mux = Mux::new("background-refresh-budget-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));

        for refresh_sequence in 1..=u64::from(BACKGROUND_REFRESH_RETRIES) + 1 {
            app.handle(AppEvent::RemoteTreeUpdated {
                refresh_sequence,
                routing_generation: 0,
                result: Err("offline".to_string()),
            })
            .unwrap();
        }

        assert_eq!(app.background_refresh_attempts, BACKGROUND_REFRESH_RETRIES);
        assert!(app.background_refresh_retry_at.is_none());
        assert!(
            app.status_message
                .as_deref()
                .is_some_and(|message| message.contains("automatic retries stopped, reconnect"))
        );
    }

    #[test]
    fn exited_surface_tombstones_are_remote_only_and_pruned_authoritatively() {
        let mux = Mux::new("surface-tombstone-churn-test", SurfaceOptions::default());
        let app = test_app(Session::Local(mux));
        for surface in 1..=1_000 {
            app.session.forget_surface(surface);
        }
        assert!(app.session.exited_surfaces.lock().unwrap().is_empty());

        let mut app = app;
        app.session.remote = true;
        for surface in 1..=1_000 {
            app.session.forget_surface(surface);
        }
        assert_eq!(app.session.exited_surfaces.lock().unwrap().len(), 1_000);
        app.session.reconcile_exited_surfaces(&notify_tree(1_000, false));
        assert_eq!(*app.session.exited_surfaces.lock().unwrap(), HashSet::from([1_000]));
        app.session.reconcile_exited_surfaces(&TreeView::default());
        assert!(app.session.exited_surfaces.lock().unwrap().is_empty());
    }

    #[test]
    fn sidebar_plugin_sync_is_deduped_after_it_is_applied() {
        let mux = Mux::new("sidebar-plugin-sync-test", SurfaceOptions::default());
        let plugin = cmux_tui_core::SidebarPluginOptions {
            command: vec!["/bin/cat".to_string()],
            cwd: None,
        };
        mux.configure_sidebar_plugin(Some(plugin.clone()));
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.config.sidebar.plugin = Some(plugin);

        for _ in 0..1_000 {
            app.session.sidebar_plugin((24, 8), false);
        }

        let mut updates = 0;
        while let Ok(event) = events.recv_timeout(Duration::from_secs(5)) {
            if matches!(event, AppEvent::SidebarPluginUpdated { .. }) {
                updates += 1;
            }
            app.handle(event).unwrap();
            if !app.session.has_pending_mutations() && updates == 1 {
                break;
            }
        }
        assert_eq!(updates, 1);
        assert!(!app.session.has_pending_mutations());
        assert_eq!(app.session.sidebar_plugin_sync.lock().unwrap().applied, Some(((24, 8), 0, 0)));
    }

    #[test]
    fn failed_sidebar_plugin_status_schedules_passive_retry() {
        let mux = Mux::new("sidebar-plugin-retry-test", SurfaceOptions::default());
        let plugin = cmux_tui_core::SidebarPluginOptions {
            command: vec!["/definitely/missing/cmux-sidebar-plugin".to_string()],
            cwd: None,
        };
        mux.configure_sidebar_plugin(Some(plugin.clone()));
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.config.sidebar.plugin = Some(plugin);
        app.sidebar_width = 12;
        app.content_area.height = 8;

        app.session.sidebar_plugin((11, 9), false);
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
        }

        assert!(app.sidebar_plugin_error.is_some());
        assert!(app.sidebar_plugin_retry_at.is_some());
        assert!(app.session.sidebar_plugin_sync.lock().unwrap().applied.is_none());
        assert!(!app.sync_sidebar_plugin(false));
        assert!(!app.session.has_pending_mutations());

        app.sidebar_plugin_retry_at = Some(Instant::now() - Duration::from_millis(1));
        app.drag = Some(Drag::PtyMouse {
            surface: 42,
            handle: None,
            reservation_id: 7,
            release_bytes: PtyInputBytes::from_slice(b"release"),
            content: Rect { x: 1, y: 1, width: 20, height: 8 },
            button: MouseButton::Left,
            position: (4, 3),
            modifiers: KeyModifiers::NONE,
        });
        app.retry_sidebar_plugin_if_due();
        assert!(matches!(app.drag, Some(Drag::PtyMouse { reservation_id: 7, .. })));
        assert!(!app.session.has_pending_mutations());

        app.drag = None;
        app.sidebar_plugin_retry_at = Some(Instant::now() - Duration::from_millis(1));
        app.retry_sidebar_plugin_if_due();

        assert!(app.sidebar_plugin_retry_at.is_none());
        assert!(app.session.has_pending_mutations());
        assert!(app.session.sidebar_plugin_sync.lock().unwrap().applied.is_none());
    }

    #[test]
    fn terminal_sidebar_failure_settles_passive_sync_claim() {
        let desired = ((24, 8), 0, 0);
        let state = Arc::new(Mutex::new(SidebarPluginSyncState {
            epoch: 0,
            claimed: Some(desired),
            applied: None,
        }));
        let mut claim = SidebarPluginSyncClaim { state: state.clone(), desired, applied: false };
        let status = SidebarPluginSurface {
            surface_id: None,
            error: Some("terminal failure".to_string()),
            retry_after_ms: None,
        };

        assert!(sidebar_plugin_status_settles_passive_claim(&status));
        claim.mark_applied();
        drop(claim);

        let state = state.lock().unwrap();
        assert_eq!(state.applied, Some(desired));
        assert!(state.claimed.is_none());
        drop(state);

        let mux = Mux::new("terminal-sidebar-failure-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.config.sidebar.plugin = Some(cmux_tui_core::SidebarPluginOptions {
            command: vec!["unused".to_string()],
            cwd: None,
        });
        app.sidebar_visible = true;
        app.sidebar_width = 12;
        app.content_area.height = 8;
        app.apply_sidebar_plugin_status(status, false);

        assert!(!app.sync_sidebar_plugin(false));
        assert!(!app.session.has_pending_mutations());
    }

    #[test]
    fn hiding_then_showing_sidebar_rehydrates_same_size_plugin_status() {
        let mux = Mux::new("sidebar-plugin-hide-show-test", SurfaceOptions::default());
        let plugin = cmux_tui_core::SidebarPluginOptions {
            command: vec!["/bin/cat".to_string()],
            cwd: None,
        };
        mux.configure_sidebar_plugin(Some(plugin.clone()));
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.config.sidebar.plugin = Some(plugin);
        app.sidebar_width = 12;
        app.content_area.height = 8;
        app.session.sidebar_plugin((11, 9), false);
        while app.session.has_pending_mutations() {
            app.handle(events.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
        }
        assert!(app.session.sidebar_plugin_sync.lock().unwrap().applied.is_some());

        app.sidebar_visible = false;
        assert!(!app.sync_sidebar_plugin(false));
        assert!(app.session.sidebar_plugin_sync.lock().unwrap().applied.is_none());
        app.sidebar_visible = true;

        assert!(app.sync_sidebar_plugin(false));
        assert!(app.session.has_pending_mutations());
    }

    #[test]
    fn surface_exit_removes_stale_topology_without_attach_or_failed_mutation() {
        let mux = Mux::new("surface-exit-before-refresh-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        let surface = 77;
        app.session.remote = true;
        app.replace_tree(notify_tree(surface, false));
        app.deferred_input.push_back(DeferredInput {
            event: Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
            destination: Some(surface),
            routing_intent: None,
            sidebar_focus_intent: false,
        });

        assert_eq!(
            app.handle(AppEvent::Mux(MuxEvent::SurfaceExited(surface))).unwrap(),
            RenderAction::Draw
        );
        assert!(!app.tab_locations.contains_key(&surface));
        assert!(app.tree.workspaces[0].screens[0].panes[0].tabs.is_empty());

        // Simulate the stale cached remote tree being painted before the
        // authoritative exit refresh arrives. The exited-surface guard must
        // still suppress a synchronous reattach attempt.
        app.replace_tree(notify_tree(surface, false));
        app.session.attach_surface(surface, Some((80, 24)));

        assert!(!app.session.can_attach_surface(surface));
        assert!(!app.session.has_pending_mutations());
        assert_eq!(app.deferred_input.len(), 1);
        assert!(events.try_recv().is_err());
    }

    #[test]
    fn explicit_sidebar_relaunch_is_a_barrier_before_passive_sync() {
        let mux = Mux::new("sidebar-plugin-relaunch-barrier-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (unblock_tx, unblock_rx) = std::sync::mpsc::channel();
        app.session.operations.enqueue_session_mutation("blocker", false, move || {
            started_tx.send(()).unwrap();
            unblock_rx.recv().unwrap();
            Ok(())
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        app.session.sidebar_plugin((24, 8), true);
        app.session.sidebar_plugin((24, 8), false);
        unblock_tx.send(()).unwrap();

        let mut updates = Vec::new();
        while updates.len() < 2 {
            let event = events.recv_timeout(Duration::from_secs(1)).unwrap();
            if let AppEvent::SidebarPluginUpdated { relaunch, .. } = &event {
                updates.push(*relaunch);
            }
            app.handle(event).unwrap();
        }
        assert_eq!(updates, vec![true, false]);
    }

    #[test]
    fn pending_sidebar_focus_is_fulfilled_by_async_relaunch_success() {
        let mux = Mux::new("sidebar-plugin-focus-intent-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.config.sidebar.plugin = Some(cmux_tui_core::SidebarPluginOptions {
            command: vec!["unused".to_string()],
            cwd: None,
        });
        app.sidebar_width = 12;
        app.content_area.height = 8;

        app.toggle_sidebar_focus();
        assert!(app.sidebar_focus_pending);
        assert!(!app.sidebar_focused);

        app.handle(AppEvent::SidebarPluginUpdated {
            status: SidebarPluginSurface {
                surface_id: Some(42),
                error: None,
                retry_after_ms: None,
            },
            relaunch: true,
        })
        .unwrap();

        assert!(!app.sidebar_focus_pending);
        assert!(app.sidebar_focused);
        assert_eq!(app.sidebar_plugin_surface, Some(42));
    }

    #[test]
    fn builtin_sidebar_focus_survives_plugin_sync() {
        let mux = Mux::new("builtin-sidebar-focus-sync-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.sidebar_visible = true;
        app.sidebar_width = 22;
        app.sidebar_focused = true;

        assert!(!app.sync_sidebar_plugin(false));
        assert!(app.sidebar_focused);
    }

    #[test]
    fn key_typed_during_pending_sidebar_focus_follows_successful_focus() {
        let mux = Mux::new("sidebar-plugin-deferred-key-success-test", SurfaceOptions::default());
        let surface = mux.new_workspace(None, None).unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());
        app.sidebar_focus_pending = true;
        app.session.pending_mutations.store(1, Ordering::Release);

        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();
        assert!(app.deferred_input.front().unwrap().sidebar_focus_intent);

        app.session.pending_mutations.store(0, Ordering::Release);
        app.sidebar_focus_pending = false;
        app.sidebar_focused = true;
        app.sidebar_plugin_surface = Some(surface.id);
        app.replay_deferred_input().unwrap();

        assert!(app.deferred_input.is_empty());
        assert_ne!(
            app.status_message.as_deref(),
            Some("Deferred input was discarded because its destination changed")
        );
    }

    #[test]
    fn key_typed_during_pending_sidebar_focus_keeps_pane_target_on_failure() {
        let mux = Mux::new("sidebar-plugin-deferred-key-failure-test", SurfaceOptions::default());
        mux.new_workspace(None, None).unwrap();
        let mut app = test_app(Session::Local(mux));
        app.replace_tree(app.session.tree());
        app.sidebar_focus_pending = true;
        app.session.pending_mutations.store(1, Ordering::Release);

        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();

        app.session.pending_mutations.store(0, Ordering::Release);
        app.sidebar_focus_pending = false;
        app.replay_deferred_input().unwrap();

        assert!(app.deferred_input.is_empty());
        assert_ne!(
            app.status_message.as_deref(),
            Some("Deferred input was discarded because its destination changed")
        );
    }

    #[test]
    fn surface_output_is_paint_only_and_preserves_the_topology_index() {
        let mux = Mux::new("surface-output-paint-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.tab_locations.insert(77, [1, 2, 3, 4]);

        let action = app.handle(AppEvent::Mux(MuxEvent::SurfaceOutput(77))).unwrap();

        assert_eq!(action, RenderAction::Paint);
        assert_eq!(app.tab_locations.get(&77), Some(&[1, 2, 3, 4]));
    }

    #[test]
    fn remote_mutation_timeout_keeps_deferred_routing_state() {
        let mux = Mux::new("mutation-timeout-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.session.remote = true;
        app.deferred_input.push_back(DeferredInput {
            event: Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
            destination: None,
            routing_intent: None,
            sidebar_focus_intent: false,
        });
        app.session
            .enqueue("timed out mutation", |_| Err(crate::session::test_remote_timeout_error()));
        let settled = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            settled,
            AppEvent::SessionMutationSettled {
                outcome: super::SessionMutationOutcome::MutationTimedOut(_),
                ..
            }
        ));
        app.handle(settled).unwrap();
        assert_eq!(app.deferred_input.len(), 1);
        assert!(
            app.status_message
                .as_deref()
                .is_some_and(|message| message.contains("may have committed"))
        );
    }

    #[test]
    fn remote_coalesced_resize_timeouts_settle_as_ambiguous() {
        let mux = Mux::new("coalesced-timeout-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.session.remote = true;
        app.deferred_input.push_back(DeferredInput {
            event: Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
            destination: None,
            routing_intent: None,
            sidebar_focus_intent: false,
        });

        for (label, key) in [
            ("resize PTY surface", ("surface resize", 7)),
            ("resize pane split", ("horizontal split ratio", 8)),
        ] {
            app.session.enqueue_coalescing_session_mutation(label, key, |_| {
                Err(crate::session::test_remote_timeout_error())
            });
            let settled = events.recv_timeout(Duration::from_secs(1)).unwrap();
            assert!(matches!(
                settled,
                AppEvent::SessionMutationSettled {
                    outcome: super::SessionMutationOutcome::MutationTimedOut(_),
                    ..
                }
            ));
            app.handle(settled).unwrap();
            assert_eq!(app.deferred_input.len(), 1);
        }
    }

    #[test]
    fn queued_mutation_settlement_waits_for_worker_cleanup() {
        let mux = Mux::new("mutation-settlement-barrier-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        app.session.remote = true;
        let pause_first = Arc::new(AtomicBool::new(true));
        let (reached_tx, reached_rx) = std::sync::mpsc::sync_channel(1);
        let release = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let hook_release = release.clone();
        app.session.operations.set_after_operation_before_cleanup(Some(Arc::new(move || {
            if pause_first.swap(false, Ordering::SeqCst) {
                reached_tx.send(()).unwrap();
                let (lock, ready) = &*hook_release;
                let mut released = lock.lock().unwrap();
                while !*released {
                    released = ready.wait(released).unwrap();
                }
            }
        })));

        app.session.enqueue_coalescing_session_mutation(
            "resize PTY surface",
            ("surface resize", 7),
            |_| Err(crate::session::test_remote_timeout_error()),
        );
        reached_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(events.try_recv().is_err(), "settlement escaped before worker cleanup");
        let (lock, ready) = &*release;
        *lock.lock().unwrap() = true;
        ready.notify_all();

        let timed_out = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            timed_out,
            AppEvent::SessionMutationSettled {
                outcome: super::SessionMutationOutcome::MutationTimedOut(_),
                ..
            }
        ));
        app.handle(timed_out).unwrap();

        app.session.enqueue_coalescing_session_mutation(
            "resize PTY surface",
            ("surface resize", 7),
            |_| Ok(()),
        );
        let recovered = events.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            recovered,
            AppEvent::SessionMutationSettled {
                outcome: super::SessionMutationOutcome::Success { .. },
                ..
            }
        ));
    }

    #[test]
    fn browser_completion_waits_for_its_authoritative_identity_generation() {
        let mux = Mux::new("browser-completion-generation-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let surface = 41;
        app.pane_areas.push(browser_completion_area(surface));
        app.pending_session_completions.push_back(SessionCompletion {
            mutation_generation: 4,
            action: SessionCompletionAction::BrowserTabCreated { surface },
        });
        let tree = browser_completion_tree(surface, surface);

        app.handle(AppEvent::RemoteTreeUpdated {
            refresh_sequence: 1,
            routing_generation: 0,
            result: Ok(tree.clone()),
        })
        .unwrap();
        assert_eq!(app.pending_session_completions.len(), 1);
        assert!(app.omnibar.is_none());

        app.session.pending_mutations.store(1, Ordering::Release);
        app.handle(settled(super::SessionMutationOutcome::Success { tree: None })).unwrap();
        assert_eq!(app.pending_session_completions.len(), 1);
        assert!(app.omnibar.is_none());

        app.session.pending_mutations.store(1, Ordering::Release);
        app.handle(settled(super::SessionMutationOutcome::IdentityRefreshSucceeded {
            tree: tree.clone(),
            authoritative_generation: 3,
            routing_generation: 0,
            refresh_sequence: 2,
        }))
        .unwrap();
        assert_eq!(app.pending_session_completions.len(), 1);
        assert!(app.omnibar.is_none());

        app.session.pending_mutations.store(1, Ordering::Release);
        app.handle(settled(super::SessionMutationOutcome::IdentityRefreshSucceeded {
            tree,
            authoritative_generation: 4,
            routing_generation: 0,
            refresh_sequence: 3,
        }))
        .unwrap();
        assert!(app.pending_session_completions.is_empty());
        assert_eq!(app.omnibar.as_ref().map(|state| state.surface), Some(surface));
    }

    #[test]
    fn browser_completion_selects_the_exact_created_surface() {
        let mux = Mux::new("browser-completion-inactive-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let created_surface = 41;
        let active_surface = 42;
        app.pane_areas.push(browser_completion_area(active_surface));
        app.pending_session_completions.push_back(SessionCompletion {
            mutation_generation: 4,
            action: SessionCompletionAction::BrowserTabCreated { surface: created_surface },
        });
        app.session.pending_mutations.store(1, Ordering::Release);

        app.handle(settled(super::SessionMutationOutcome::IdentityRefreshSucceeded {
            tree: browser_completion_tree(created_surface, active_surface),
            authoritative_generation: 4,
            routing_generation: 0,
            refresh_sequence: 1,
        }))
        .unwrap();

        assert!(app.pending_session_completions.is_empty());
        assert_eq!(app.tree.active_surface(), Some(created_surface));
        assert_eq!(app.omnibar.as_ref().map(|state| state.surface), Some(created_surface));
    }

    #[test]
    fn failed_mutation_discards_input_deferred_for_its_destination() {
        let mux = Mux::new("failed-mutation-input-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        app.session.enqueue("failing selection", move |_| {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            anyhow::bail!("selection rejected")
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('b'),
            KeyModifiers::CONTROL,
        ))))
        .unwrap();
        assert!(app.prefix_armed);
        app.handle(AppEvent::Input(Event::Key(KeyEvent::new(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
        ))))
        .unwrap();
        assert_eq!(app.deferred_input.len(), 1);

        release_tx.send(()).unwrap();
        let settled = events.recv_timeout(Duration::from_secs(1)).unwrap();
        app.handle(settled).unwrap();

        assert!(app.deferred_input.is_empty());
        assert!(!app.prefix_armed);
        assert_eq!(
            app.status_message.as_deref(),
            Some("session operation failed: selection rejected")
        );
    }

    #[test]
    fn split_drag_updates_the_coalescing_lane_while_a_ratio_is_pending() {
        let mux = Mux::new("pending-split-drag-test", SurfaceOptions::default());
        let (mut app, _events) = test_app_with_events(Session::Local(mux));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (_release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        app.session.enqueue("blocking ratio", move |_| {
            started_tx.send(()).unwrap();
            let _ = release_rx.recv();
            Ok(())
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        app.drag = Some(Drag::ResizeSplit {
            horizontal: Some((1, super::PaneEdge::Right)),
            vertical: None,
        });

        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Drag(MouseButton::Left),
            column: 20,
            row: 5,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();

        assert!(app.deferred_input.is_empty());
        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: 20,
            row: 5,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert!(app.deferred_input.is_empty());
        assert!(app.drag.is_none());
    }

    #[test]
    fn split_ratio_samples_coalesce_without_snapshots_before_final_settlement() {
        let mux = Mux::new("split-ratio-snapshot-test", SurfaceOptions::default());
        mux.new_workspace(None, Some((40, 12))).unwrap();
        let target = Session::Local(mux.clone()).tree().active_screen().unwrap().active_pane;
        mux.split(target, SplitDir::Right, Some((20, 12))).unwrap();
        let split = mux.with_state(|state| {
            let root = &state.workspaces[0].screens[0].root;
            let Node::Split { id, .. } = root else {
                panic!("expected split root");
            };
            *id
        });
        let (app, events) = test_app_with_events(Session::Local(mux));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        app.session.operations.enqueue_session_mutation("block ratio lane", false, move || {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        for ratio in [0.2, 0.4, 0.8] {
            app.session.set_split_ratio_deferred(split, ratio);
        }
        app.session.settle_split_ratio();
        release_tx.send(()).unwrap();

        let mut sample_without_tree = 0;
        let mut authoritative_snapshots = 0;
        for _ in 0..2 {
            match events.recv_timeout(Duration::from_secs(1)).unwrap() {
                AppEvent::SessionMutationSettled {
                    outcome: super::SessionMutationOutcome::Success { tree: None },
                    ..
                } => sample_without_tree += 1,
                AppEvent::SessionMutationSettled {
                    outcome: super::SessionMutationOutcome::AuthoritativeMutationSucceeded { .. },
                    ..
                } => authoritative_snapshots += 1,
                _ => panic!("unexpected split ratio settlement"),
            }
        }

        assert_eq!(sample_without_tree, 1, "the retained sample must not build a tree");
        assert_eq!(authoritative_snapshots, 1, "final settlement must snapshot exactly once");
    }

    #[test]
    fn pointer_motion_is_discarded_while_a_mutation_can_change_its_target() {
        let mux = Mux::new("deferred-motion-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        app.session.enqueue_routing("blocking mutation", move |_| {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Moved,
            column: 9,
            row: 3,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();

        assert!(app.deferred_input.is_empty());
        assert_eq!(
            app.status_message.as_deref(),
            Some("Pointer input was discarded while the layout changed")
        );
        release_tx.send(()).unwrap();
        let settled = events.recv_timeout(Duration::from_secs(1)).unwrap();
        app.handle(settled).unwrap();
    }

    #[test]
    fn pointer_input_continues_during_non_routing_background_mutation() {
        let mux = Mux::new("background-pointer-test", SurfaceOptions::default());
        let (mut app, events) = test_app_with_events(Session::Local(mux));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        app.session.enqueue("blocking background sync", move |_| {
            started_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            Ok(())
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Moved,
            column: 9,
            row: 3,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();

        assert_ne!(
            app.status_message.as_deref(),
            Some("Pointer input was discarded while the layout changed")
        );
        release_tx.send(()).unwrap();
        app.handle(events.recv_timeout(Duration::from_secs(1)).unwrap()).unwrap();
    }

    #[test]
    fn browser_drag_release_bypasses_a_pending_focus_mutation() {
        let mux = Mux::new("browser-release-barrier-test", SurfaceOptions::default());
        let (mut app, _events) = test_app_with_events(Session::Local(mux));
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (_release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        app.session.enqueue("blocking focus", move |_| {
            started_tx.send(()).unwrap();
            let _ = release_rx.recv();
            Ok(())
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        app.drag =
            Some(Drag::Browser { surface: 42, content: Rect { x: 2, y: 3, width: 20, height: 8 } });

        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: 5,
            row: 5,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();

        assert!(app.deferred_input.is_empty());
        assert!(app.drag.is_none());
    }

    #[test]
    fn selection_drag_and_release_bypass_a_pending_focus_mutation() {
        let mux = Mux::new("selection-release-barrier-test", SurfaceOptions::default());
        let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
        let mut app = test_app(Session::Local(mux));
        app.session.pending_mutations.store(1, Ordering::Release);
        let content = Rect { x: 2, y: 3, width: 20, height: 8 };
        app.selection = Some(Selection { surface: surface.id, anchor: (1, 1), head: (1, 1) });
        app.drag = Some(Drag::Select { content, auto_scroll: None, col: 1 });

        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Drag(MouseButton::Left),
            column: 8,
            row: 6,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert!(app.deferred_input.is_empty());
        assert_eq!(app.selection.map(|selection| selection.head), Some((6, 3)));

        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: 8,
            row: 6,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert!(app.deferred_input.is_empty());
        assert!(app.drag.is_none());
    }

    #[test]
    fn pty_drag_motion_and_release_bypass_pending_mutation_with_pinned_surface() {
        let mux = Mux::new("pty-release-barrier-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.session.pending_mutations.store(1, Ordering::Release);
        app.drag = Some(Drag::PtyMouse {
            surface: 42,
            handle: None,
            reservation_id: 1,
            release_bytes: PtyInputBytes::from_slice(b"release"),
            content: Rect { x: 2, y: 3, width: 20, height: 8 },
            button: MouseButton::Right,
            position: (5, 5),
            modifiers: KeyModifiers::NONE,
        });

        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Drag(MouseButton::Left),
            column: 8,
            row: 6,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert!(app.deferred_input.is_empty());
        assert!(matches!(app.drag, Some(Drag::PtyMouse { surface: 42, position: (8, 6), .. })));

        app.handle(AppEvent::Input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Right),
            column: 8,
            row: 6,
            modifiers: KeyModifiers::NONE,
        })))
        .unwrap();
        assert!(app.deferred_input.is_empty());
        assert!(app.drag.is_none());
    }

    #[test]
    fn doubled_prefix_waits_for_pending_mutation_after_first_prefix_arms() {
        let mux = Mux::new("doubled-prefix-barrier-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.session.pending_mutations.store(1, Ordering::Release);
        let prefix = Event::Key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL));

        app.handle(AppEvent::Input(prefix.clone())).unwrap();
        assert!(app.prefix_armed);
        assert!(app.deferred_input.is_empty());

        app.handle(AppEvent::Input(prefix)).unwrap();
        assert!(app.prefix_armed);
        assert_eq!(app.deferred_input.len(), 1);
    }

    #[test]
    fn committed_mutation_with_stale_refresh_retains_deferred_input() {
        let mux = Mux::new("committed-stale-refresh-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.session.pending_mutations.store(1, Ordering::Release);
        app.deferred_input.push_back(DeferredInput {
            event: Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE)),
            destination: None,
            routing_intent: None,
            sidebar_focus_intent: false,
        });

        app.handle(settled(super::SessionMutationOutcome::CommittedTreeStale {
            error: Some("refresh unavailable".to_string()),
            completion: None,
        }))
        .unwrap();

        assert_eq!(app.deferred_input.len(), 1);
        assert_eq!(
            app.status_message.as_deref(),
            Some("session changed, but its layout refresh failed: refresh unavailable")
        );
        assert!(!app.session.has_pending_mutations());
    }

    #[test]
    fn oversized_paste_is_rejected_before_routing_or_text_insertion() {
        let mux = Mux::new("oversized-paste-ingress-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        let text =
            "x".repeat(super::MAX_DEFERRED_INPUT_BYTES - super::BRACKETED_PASTE_MARKER_BYTES + 1);

        app.handle(AppEvent::Input(Event::Paste(text))).unwrap();

        assert!(app.deferred_input.is_empty());
        assert_eq!(app.status_message.as_deref(), Some("Paste exceeds the 4 MiB PTY buffer limit"));
    }

    #[test]
    fn deferred_paste_budget_counts_bracket_markers() {
        let mux = Mux::new("deferred-paste-budget-test", SurfaceOptions::default());
        let mut app = test_app(Session::Local(mux));
        app.session.pending_mutations.store(1, Ordering::Release);
        let half = "x".repeat(super::MAX_DEFERRED_INPUT_BYTES / 2);

        app.handle(AppEvent::Input(Event::Paste(half.clone()))).unwrap();
        app.handle(AppEvent::Input(Event::Paste(half))).unwrap();

        assert_eq!(app.deferred_input.len(), 1);
        assert_eq!(
            app.status_message.as_deref(),
            Some("Input queue byte limit reached while a session change is pending")
        );
    }

    #[test]
    fn failed_pty_owned_press_does_not_fall_through_to_cmux_mouse_actions() {
        let mux = Mux::new(
            "failed-owned-press-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(None, Some((20, 8))).unwrap();
        surface.with_terminal(|terminal| terminal.vt_write(b"\x1b[?1000h\x1b[?1006h"));
        let mut app = test_app(Session::Local(mux.clone()));
        app.replace_tree(app.session.tree());
        let pane = app.tree.active_screen().unwrap().active_pane;
        let content = Rect { x: 2, y: 3, width: 20, height: 8 };
        app.pane_areas.push(PaneArea {
            pane,
            surface: surface.id,
            rect: Rect { x: 1, y: 2, width: 23, height: 10 },
            bar: Some(Rect { x: 1, y: 2, width: 23, height: 1 }),
            omnibar: None,
            content,
            track: None,
        });
        app.rendered_terminal_bounds.insert(surface.id, content);
        assert!(app.pty_input.shutdown(Duration::from_secs(1)));
        let event = |button| MouseEvent {
            kind: MouseEventKind::Down(button),
            column: content.x + 4,
            row: content.y + 2,
            modifiers: KeyModifiers::NONE,
        };

        app.handle_mouse(event(MouseButton::Right)).unwrap();
        assert!(app.menu.is_none());
        assert!(app.drag.is_none());
        app.handle_mouse(event(MouseButton::Left)).unwrap();
        assert!(app.selection.is_none());
        assert!(app.drag.is_none());
        assert_eq!(
            app.status_message.as_deref(),
            Some("PTY input queue is full; input was not sent")
        );

        mux.close_surface(surface.id);
    }

    #[test]
    fn notify_unread_indicators_render_and_clear() {
        let mux = Mux::new(
            "notify-render-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.sidebar_width = 12;
        app.sidebar_view = SidebarView::Workspaces;
        app.replace_tree(notify_tree(surface.id, true));
        app.pane_areas.push(PaneArea {
            pane: 2,
            surface: surface.id,
            rect: Rect { x: 12, y: 1, width: 26, height: 8 },
            bar: Some(Rect { x: 12, y: 1, width: 26, height: 1 }),
            omnibar: None,
            content: Rect { x: 13, y: 2, width: 23, height: 6 },
            track: None,
        });

        let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
        terminal
            .draw(|frame| {
                crate::ui::draw(&mut app, frame);
            })
            .unwrap();
        let buffer = terminal.backend().buffer();
        assert_eq!(buffer[(12, 2)].symbol(), "│");
        assert_eq!(buffer[(12, 2)].style().fg, Some(app.config.theme.notification_warning));
        assert!(row_contains(buffer, 1, "•"), "tab bar should contain unread dot");
        assert_eq!(buffer[(0, 2)].symbol(), "•", "sidebar should contain unread dot");

        app.replace_tree(notify_tree(surface.id, false));
        let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
        terminal
            .draw(|frame| {
                crate::ui::draw(&mut app, frame);
            })
            .unwrap();
        let buffer = terminal.backend().buffer();
        assert_eq!(buffer[(12, 2)].style().fg, Some(app.config.theme.border_active));
        assert!(!row_contains(buffer, 1, "•"), "tab bar dot should clear");
        assert_ne!(buffer[(0, 2)].symbol(), "•", "sidebar dot should clear");

        mux.close_surface(surface.id);
    }

    #[test]
    fn plugin_sidebar_registers_resize_drag_hit() {
        let mux = Mux::new(
            "plugin-sidebar-drag-test",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
        let mut app = test_app(Session::Local(mux.clone()));
        app.sidebar_width = 12;
        app.config.sidebar.plugin = Some(cmux_tui_core::SidebarPluginOptions {
            command: vec!["/bin/sh".to_string(), "-c".to_string(), "sleep 30".to_string()],
            cwd: None,
        });
        app.replace_tree(notify_tree(surface.id, false));

        let mut terminal = Terminal::new(TestBackend::new(40, 12)).unwrap();
        terminal
            .draw(|frame| {
                crate::ui::draw(&mut app, frame);
            })
            .unwrap();

        // Regression: with a plugin sidebar the divider column must still be a
        // drag handle, exactly like the built-in sidebar.
        let divider_x = app.sidebar_width - 1;
        assert!(
            app.hits.iter().any(|(rect, hit)| matches!(hit, super::Hit::SidebarResize)
                && rect.x == divider_x
                && rect.width == 1),
            "plugin sidebar must register the SidebarResize hit on the divider column"
        );

        mux.close_surface(surface.id);
    }

    fn test_mouse_motion() -> MouseInput {
        MouseInput {
            action: MouseAction::Motion,
            button: None,
            mods: Mods::default(),
            position: (36.0, 40.0),
            screen_size: (640, 384),
            cell_size: (8, 16),
            any_button_pressed: false,
        }
    }

    fn encode_test_mouse_motion(surface: &SurfaceHandle, input: MouseInput) -> Vec<u8> {
        let mut output = Vec::new();
        surface.encode_mouse(input, &mut output).unwrap().unwrap();
        output
    }

    fn browser_completion_area(surface: SurfaceId) -> PaneArea {
        PaneArea {
            pane: 2,
            surface,
            rect: Rect { x: 0, y: 0, width: 40, height: 12 },
            bar: Some(Rect { x: 0, y: 0, width: 40, height: 1 }),
            omnibar: Some(Rect { x: 0, y: 1, width: 40, height: 1 }),
            content: Rect { x: 0, y: 2, width: 40, height: 10 },
            track: None,
        }
    }

    fn browser_completion_tree(created_surface: SurfaceId, active_surface: SurfaceId) -> TreeView {
        let tab = |surface| TabView {
            surface,
            short_id: format!("{surface:06}"),
            name: None,
            title: String::new(),
            kind: SurfaceKind::Browser,
            browser_source: None,
            browser_frames_stalled: false,
            notification: None,
        };
        let mut tabs = vec![tab(created_surface)];
        if active_surface != created_surface {
            tabs.push(tab(active_surface));
        }
        TreeView {
            workspace_revision: 0,
            pane_revision: Some(1),
            active_workspace: 0,
            workspaces: vec![WorkspaceView {
                id: 4,
                key: "00000000-0000-4000-8000-000000000004".to_string(),
                short_id: "000004".to_string(),
                name: "work".to_string(),
                active_screen: 0,
                screens: vec![ScreenView {
                    id: 3,
                    short_id: "000003".to_string(),
                    name: None,
                    layout: Node::Leaf(2),
                    active_pane: 2,
                    zoomed_pane: None,
                    panes: vec![PaneView {
                        id: 2,
                        short_id: "000002".to_string(),
                        name: None,
                        tabs,
                        active_tab: usize::from(active_surface != created_surface),
                        focused_at: 0,
                    }],
                }],
            }],
        }
    }

    #[test]
    fn files_sidebar_renders_temp_directory_and_unread_header_badge() {
        let temp = test_temp_dir("draw-files");
        std::fs::write(temp.join("known-sidebar-file.txt"), "hello").unwrap();
        let (mux, surface) = test_mux("files-sidebar-draw-test", Some(&temp));
        let mut app = test_app(Session::Local(mux.clone()));
        app.sidebar_width = 24;
        app.sidebar_files = FileBrowser::new(temp.clone());
        app.tree = notify_tree(surface.id, true);

        let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        let text = buffer_text(terminal.backend().buffer());
        assert!(text.contains("known-sidebar-file"), "{text}");
        assert!(text.lines().next().is_some_and(|line| line.contains("• 1")), "{text}");

        mux.close_surface(surface.id);
        std::fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn focused_sidebar_tab_toggles_builtin_views_and_back() {
        let temp = test_temp_dir("toggle-view");
        std::fs::write(temp.join("toggle-marker.txt"), "hello").unwrap();
        let (mux, surface) = test_mux("sidebar-toggle-test", Some(&temp));
        let mut app = test_app(Session::Local(mux.clone()));
        app.sidebar_width = 24;
        app.sidebar_files = FileBrowser::new(temp.clone());
        app.tree = notify_tree(surface.id, false);
        app.sidebar_focused = true;

        app.handle_key(KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)).unwrap();
        assert_eq!(app.sidebar_view, SidebarView::Workspaces);
        let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        assert!(buffer_text(terminal.backend().buffer()).contains("workspaces"));

        app.handle_key(KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE)).unwrap();
        assert_eq!(app.sidebar_view, SidebarView::Files);
        let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
        assert!(buffer_text(terminal.backend().buffer()).contains("toggle-marker"));

        mux.close_surface(surface.id);
        std::fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn focus_sidebar_focuses_builtin_sidebar() {
        let (mux, surface) = test_mux("focus-builtin-sidebar-test", None);
        let mut app = test_app(Session::Local(mux.clone()));
        app.tree = notify_tree(surface.id, false);
        app.sidebar_visible = false;

        app.run_action(Action::FocusSidebar).unwrap();
        assert!(app.sidebar_visible);
        assert!(app.sidebar_focused);

        app.run_action(Action::FocusSidebar).unwrap();
        assert!(!app.sidebar_focused);
        mux.close_surface(surface.id);
    }

    #[test]
    fn builtin_sidebar_registers_resize_hit_in_both_views() {
        let temp = test_temp_dir("resize-hit");
        let (mux, surface) = test_mux("builtin-sidebar-resize-test", Some(&temp));
        let mut app = test_app(Session::Local(mux.clone()));
        app.sidebar_width = 18;
        app.sidebar_files = FileBrowser::new(temp.clone());
        app.tree = notify_tree(surface.id, false);

        for view in [SidebarView::Files, SidebarView::Workspaces] {
            app.sidebar_view = view;
            let mut terminal = Terminal::new(TestBackend::new(50, 12)).unwrap();
            terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
            assert!(
                app.hits.iter().any(|(rect, hit)| {
                    matches!(hit, super::Hit::SidebarResize)
                        && rect.x == app.sidebar_width - 1
                        && rect.width == 1
                }),
                "missing resize hit in {view:?} view"
            );
        }

        mux.close_surface(surface.id);
        std::fs::remove_dir_all(temp).unwrap();
    }

    fn test_app(session: Session) -> App {
        test_app_with_events(session).0
    }

    fn test_app_with_events(session: Session) -> (App, Receiver<AppEvent>) {
        let pty_input = PtyInputDispatcher::spawn(|_| {}).unwrap();
        let (events, receiver) = std::sync::mpsc::sync_channel(4_096);
        let session = OrderedSession::new(session, pty_input.sender(), events);
        let app = App {
            session,
            config: Config::default(),
            chrome: ChromeTheme::dark(),
            tree: TreeView::default(),
            tab_locations: HashMap::new(),
            render_states: HashMap::<u64, RenderState>::new(),
            graphics_writer: None,
            graphics_supported: false,
            stdout_lock: Arc::new(Mutex::new(())),
            pane_areas: Vec::new(),
            pane_focus_history: PaneFocusHistory::default(),
            rendered_terminal_bounds: HashMap::new(),
            visible_size_surfaces: HashSet::new(),
            pending_size_releases: HashSet::new(),
            prefix_armed: false,
            session_label: "test".to_string(),
            sidebar_visible: true,
            sidebar_focused: false,
            sidebar_focus_pending: false,
            sidebar_view: SidebarView::Files,
            sidebar_files: FileBrowser::new(std::env::temp_dir()),
            sidebar_workspace_selection: 0,
            sidebar_followed_surface: None,
            sidebar_width: 0,
            sidebar_plugin_surface: None,
            sidebar_plugin_error: None,
            sidebar_plugin_retry_after_ms: None,
            sidebar_plugin_retry_at: None,
            sidebar_width_override: None,
            content_area: Rect::default(),
            hits: Vec::new(),
            tab_scroll: HashMap::new(),
            hover: None,
            menu: None,
            clients: Vec::new(),
            client_border_labels: HashMap::new(),
            prompt: None,
            pairing_dialog: None,
            pairing_queue: VecDeque::new(),
            omnibar: None,
            toast: None,
            shake_frames: 0,
            selection: None,
            status_message: None,
            cell_pixels: (8, 16),
            pointer_shape: false,
            last_browser_hover: None,
            browser_input: BrowserInputDispatcher::spawn(|_| {}, |_| {}).unwrap(),
            pty_input,
            deferred_input: VecDeque::new(),
            routing_refresh_pending: false,
            routing_refresh_retries_remaining: 0,
            background_refresh_attempts: 0,
            background_refresh_retry_at: None,
            last_applied_refresh_sequence: 0,
            applied_routing_generation: 0,
            pending_session_completions: VecDeque::new(),
            mux_titles: Arc::new(MuxTitleIngress::default()),
            pty_failures: Arc::new(PtyFailureIngress::default()),
            mux_recovery_generation: Arc::new(AtomicU64::new(0)),
            drag: None,
            ignored_pty_mouse_buttons: HashSet::new(),
            encoder: KeyEncoder::new().unwrap(),
            encode_buf: Vec::new(),
            quit: false,
        };
        (app, receiver)
    }

    fn notify_tree(surface: u64, unread: bool) -> TreeView {
        TreeView {
            workspace_revision: 0,
            pane_revision: Some(1),
            active_workspace: 0,
            workspaces: vec![WorkspaceView {
                id: 4,
                key: "00000000-0000-4000-8000-000000000004".to_string(),
                short_id: "000004".to_string(),
                name: "work".to_string(),
                active_screen: 0,
                screens: vec![ScreenView {
                    id: 3,
                    short_id: "000003".to_string(),
                    name: None,
                    layout: Node::Leaf(2),
                    active_pane: 2,
                    zoomed_pane: None,
                    panes: vec![PaneView {
                        id: 2,
                        short_id: "000002".to_string(),
                        name: None,
                        active_tab: 0,
                        focused_at: 0,
                        tabs: vec![TabView {
                            surface,
                            short_id: "000001".to_string(),
                            name: Some("tab".to_string()),
                            title: "shell".to_string(),
                            kind: SurfaceKind::Pty,
                            browser_source: None,
                            browser_frames_stalled: false,
                            notification: unread
                                .then_some(TabNotificationView { unread: true, level: "warning" }),
                        }],
                    }],
                }],
            }],
        }
    }

    #[test]
    fn remote_tree_refresh_preserves_this_clients_tab() {
        let mut previous = notify_tree(11, false);
        let pane = &mut previous.workspaces[0].screens[0].panes[0];
        let mut second = pane.tabs[0].clone();
        second.surface = 12;
        pane.tabs.push(second);
        pane.active_tab = 0;

        let mut other_client_selection = previous.clone();
        other_client_selection.workspaces[0].screens[0].panes[0].active_tab = 1;
        preserve_client_view(&previous, &mut other_client_selection);
        assert_eq!(
            other_client_selection.workspaces[0].screens[0].panes[0].active_surface(),
            Some(11)
        );
    }

    fn row_contains(buffer: &ratatui::buffer::Buffer, y: u16, needle: &str) -> bool {
        (0..buffer.area.width).any(|x| buffer[(x, y)].symbol() == needle)
    }

    fn buffer_text(buffer: &ratatui::buffer::Buffer) -> String {
        (0..buffer.area.height)
            .map(|y| (0..buffer.area.width).map(|x| buffer[(x, y)].symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn test_temp_dir(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "cmux-tui-app-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn test_mux(
        name: &str,
        cwd: Option<&std::path::Path>,
    ) -> (Arc<Mux>, Arc<cmux_tui_core::Surface>) {
        let mux = Mux::new(
            name,
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                cwd: cwd.map(|path| path.to_string_lossy().into_owned()),
                ..Default::default()
            },
        );
        let surface = mux.new_workspace(Some("work".to_string()), Some((20, 8))).unwrap();
        (mux, surface)
    }
}
