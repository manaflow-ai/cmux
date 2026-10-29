//! Per-subscriber mux event delivery with bounded coalesced state.

use crate::panic_free::RecoverPoison;
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::mpsc::{RecvError, RecvTimeoutError, TryRecvError};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, Weak};
use std::time::{Duration, Instant};

use crate::event_cause::EventCause;
use crate::{MuxEvent, PaneId, ScreenId, SurfaceId, TreeDelta, TreeDeltaKind, WorkspaceId};

mod fan_out;
mod hidden_surfaces;

pub(crate) use fan_out::StateReleasePublish;
use fan_out::{Bus, MuxEventSubscriber, Published, Subscribers};
pub(crate) use hidden_surfaces::HiddenFlush;
use hidden_surfaces::VisibilityScope;

// A subscriber may drain accepted events after crossing this limit, then observes a disconnect.
const MAX_PENDING_EVENTS: usize = 4_096;

type SessionPathUpdate = (SurfaceId, WorkspaceId, ScreenId, PaneId);

thread_local! {
    /// Session path updates held back while a resource mutation is staged
    /// on a candidate state. `None` outside [`defer_session_paths`].
    static DEFERRED_SESSION_PATHS: RefCell<Option<Vec<SessionPathUpdate>>> =
        const { RefCell::new(None) };
}

/// Session path updates recorded by [`defer_session_paths`]. Pass them to
/// [`MuxEventBroadcaster::publish_deferred_session_paths`] after the change
/// commits; drop them when it does not.
#[must_use]
pub(crate) struct DeferredSessionPaths(Vec<SessionPathUpdate>);

/// Run `f` and hold back every surface session path update it makes on this
/// thread. A resource mutation prepares and stages its state change before
/// the durable commit; subscribers must see the new path only after that
/// commit succeeds.
pub(crate) fn defer_session_paths<R>(f: impl FnOnce() -> R) -> (R, DeferredSessionPaths) {
    struct Restore(Option<Option<Vec<SessionPathUpdate>>>);
    impl Drop for Restore {
        fn drop(&mut self) {
            if let Some(previous) = self.0.take() {
                DEFERRED_SESSION_PATHS.with(|cell| *cell.borrow_mut() = previous);
            }
        }
    }
    let previous = DEFERRED_SESSION_PATHS.with(|cell| cell.borrow_mut().replace(Vec::new()));
    let mut restore = Restore(Some(previous));
    let output = f();
    let previous = restore.0.take().flatten();
    let recorded = DEFERRED_SESSION_PATHS
        .with(|cell| std::mem::replace(&mut *cell.borrow_mut(), previous))
        .unwrap_or_default();
    (output, DeferredSessionPaths(recorded))
}

/// The mux event bus. An emit is queued in order and its fan-out (each
/// subscriber's filter and mailbox push) runs outside `Mux::state`: a thread
/// that holds `Mux::state` only queues, and delivers what it queued once it
/// releases the lock ([`StateReleasePublish`]), so no thread waits for the
/// state lock while a fan-out runs. One queue for every thread keeps the
/// state order of emits made under the lock (a per-thread buffer would let
/// a later holder's delta overtake an earlier one). Chromium likewise
/// notifies observers outside the lock that guards their list
/// (base/observer_list_threadsafe.h, `ObserverListThreadSafe::Notify`).
pub struct MuxEventBroadcaster {
    bus: Arc<Bus>,
}

impl Default for MuxEventBroadcaster {
    fn default() -> Self {
        Self { bus: Arc::new(Bus::default()) }
    }
}

enum MuxEventFilter {
    All,
    ConfigReload,
    /// Events that can change which terminals have zero placements.
    TerminalTopology,
    /// Events that change the launch snapshot's layout or projections. Title
    /// changes alone are left out: a busy terminal retitles itself many
    /// times a second, and the live tree corrects a stale title at once.
    LaunchSnapshot,
    /// Local conversation changes (the host replica's Chief stream).
    Conversations,
    /// Only events of these kinds: a page relay's interest set, so an event
    /// it never hears is not cloned into its mailbox or rendered.
    Kinds(MuxEventKinds),
    AttachedSurface(SurfaceId),
    SurfaceSession(SurfaceSessionScope),
}

struct SurfaceSessionScope {
    surface: SurfaceId,
    workspace: WorkspaceId,
    screen: ScreenId,
    pane: PaneId,
}

#[derive(Clone)]
pub struct MuxEventReceiver {
    mailbox: Arc<MuxEventMailbox>,
}

/// A [`MuxEventReceiver`] that does not keep its subscription alive.
pub(crate) struct WeakMuxEventReceiver(Weak<MuxEventMailbox>);

impl WeakMuxEventReceiver {
    pub(crate) fn upgrade(&self) -> Option<MuxEventReceiver> {
        self.0.upgrade().map(|mailbox| MuxEventReceiver { mailbox })
    }
}

#[derive(Default)]
struct MuxEventMailbox {
    state: Mutex<MuxEventMailboxState>,
    changed: Condvar,
    /// The subscriber's drain task when it runs on a sequence instead of
    /// blocking on `changed` (attach streams).
    ready_hook: crate::stream_interrupt::ReadyHook,
}

#[derive(Default)]
struct MuxEventMailboxState {
    next_sequence: u128,
    events: VecDeque<(u128, Arc<MuxEvent>, EventCause)>,
    coalesced_sequences: HashMap<CoalescedEventKey, u128>,
    coalesced: BTreeMap<u128, (CoalescedEventKey, Arc<MuxEvent>, EventCause)>,
    /// The frontend's visible surfaces and the held slots of its hidden
    /// ones (`frontend.visibility.set`); `None`: every surface is visible.
    visibility: Option<VisibilityScope>,
    closed: bool,
    overflowed: bool,
}

/// What [`MuxEventMailbox::push`] did with an event.
enum Pushed {
    /// Refused: the mailbox is closed or full.
    Rejected,
    /// Ready to pop, or the first held slot (its waiter needs the flush deadline).
    Ready,
    /// Folded into the held slots, whose flush deadline is already set: no waiter wakes.
    Held,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum CoalescedEventKey {
    ConfigReload,
    Agent(SurfaceId),
    Title(SurfaceId),
    ProgramStatus(SurfaceId),
    SurfaceOutput(SurfaceId),
    Scroll(SurfaceId),
}

impl CoalescedEventKey {
    /// The slot a pending event of this kind replaces, if it coalesces.
    fn of(event: &MuxEvent) -> Option<Self> {
        match *event {
            MuxEvent::AgentChanged { surface, .. } => Some(Self::Agent(surface)),
            MuxEvent::TitleChanged { surface, .. } => Some(Self::Title(surface)),
            MuxEvent::ProgramStatusChanged { surface, .. } => Some(Self::ProgramStatus(surface)),
            MuxEvent::SurfaceOutput(surface) => Some(Self::SurfaceOutput(surface)),
            MuxEvent::ScrollChanged { surface, .. } => Some(Self::Scroll(surface)),
            MuxEvent::ConfigReloadRequested => Some(Self::ConfigReload),
            _ => None,
        }
    }

    /// Every slot of `surface`.
    const fn of_surface(surface: SurfaceId) -> [Self; 5] {
        [
            Self::Agent(surface),
            Self::Title(surface),
            Self::ProgramStatus(surface),
            Self::SurfaceOutput(surface),
            Self::Scroll(surface),
        ]
    }

    /// The surface whose field this slot holds; `None` for a session-wide one.
    fn surface(self) -> Option<SurfaceId> {
        match self {
            Self::ConfigReload => None,
            Self::Agent(surface)
            | Self::Title(surface)
            | Self::ProgramStatus(surface)
            | Self::SurfaceOutput(surface)
            | Self::Scroll(surface) => Some(surface),
        }
    }
}

impl MuxEventBroadcaster {
    pub fn subscribe(&self) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::All)
    }

    /// The verified app's stream: every event, delivered before any other
    /// subscriber's.
    pub(crate) fn subscribe_frontend(&self) -> MuxEventReceiver {
        self.subscribe_as(MuxEventFilter::All, true)
    }

    pub fn subscribe_config_reload(&self) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::ConfigReload)
    }

    pub(crate) fn subscribe_terminal_topology(&self) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::TerminalTopology)
    }

    pub(crate) fn subscribe_launch_snapshot(&self) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::LaunchSnapshot)
    }

    pub(crate) fn subscribe_conversations(&self) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::Conversations)
    }

    /// A subscription that receives only events of `kinds`.
    pub(crate) fn subscribe_kinds(&self, kinds: MuxEventKinds) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::Kinds(kinds))
    }

    pub fn subscribe_attached_surface(&self, surface: SurfaceId) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::AttachedSurface(surface))
    }

    pub fn subscribe_surface_session(
        &self,
        surface: SurfaceId,
        workspace: WorkspaceId,
        screen: ScreenId,
        pane: PaneId,
    ) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::SurfaceSession(SurfaceSessionScope {
            surface,
            workspace,
            screen,
            pane,
        }))
    }

    /// Move `surface`'s session subscribers to a new path and wake them with
    /// a `TreeChanged`, in order with the events published around it.
    pub(crate) fn update_surface_session_path(
        &self,
        surface: SurfaceId,
        workspace: WorkspaceId,
        screen: ScreenId,
        pane: PaneId,
    ) {
        let deferred = DEFERRED_SESSION_PATHS.with(|cell| {
            cell.borrow_mut()
                .as_mut()
                .map(|updates| updates.push((surface, workspace, screen, pane)))
        });
        if deferred.is_some() {
            return;
        }
        let cause = EventCause::current();
        Bus::publish(&self.bus, |sequence| Published::SessionPath {
            sequence,
            path: (surface, workspace, screen, pane),
            cause,
        });
    }

    /// Publish session path updates held back while a committed change was
    /// staged.
    pub(crate) fn publish_deferred_session_paths(&self, deferred: DeferredSessionPaths) {
        for (surface, workspace, screen, pane) in deferred.0 {
            self.update_surface_session_path(surface, workspace, screen, pane);
        }
    }

    fn subscribe_with_filter(&self, filter: MuxEventFilter) -> MuxEventReceiver {
        self.subscribe_as(filter, false)
    }

    fn subscribe_as(&self, filter: MuxEventFilter, frontend: bool) -> MuxEventReceiver {
        let mailbox = Arc::new(MuxEventMailbox::default());
        let mut subscribers = self.bus.subscribers.lock().recover_poison();
        let since = self.bus.queue.lock().recover_poison().next_sequence;
        subscribers.prune();
        subscribers.insert(
            MuxEventSubscriber { mailbox: Arc::downgrade(&mailbox), filter, since },
            frontend,
        );
        MuxEventReceiver { mailbox }
    }

    /// Deliver `event` with the cause of this thread's scope
    /// ([`EventCause::current`]).
    pub fn emit(&self, event: MuxEvent) {
        self.emit_caused(event, EventCause::current());
    }

    /// Publish `event` once, shared by every subscriber that hears it. Under
    /// `Mux::state` it is only queued, and delivered when the lock is
    /// released.
    pub(crate) fn emit_caused(&self, event: MuxEvent, cause: EventCause) {
        let event = Arc::new(event);
        Bus::publish(&self.bus, |sequence| Published::Event { sequence, event, cause });
    }
}

/// The variant of a [`MuxEvent`], the unit of a [`MuxEventKinds`] interest
/// set. Chromium routes an event only to listeners registered for its name
/// (extensions/browser/event_router.cc, `EventRouter::DispatchEventImpl`);
/// a subscription with an interest set is filtered the same way, on the bus.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MuxEventKind {
    SurfaceOutput,
    SurfaceResized,
    SurfaceResizeFailed,
    SurfaceExited,
    ProgramStatusChanged,
    TitleChanged,
    AgentChanged,
    AgentPresenceChanged,
    Bell,
    Notification,
    GraphicsStatus,
    Status,
    ConfigReloadRequested,
    WindowTitleRequested,
    ScrollChanged,
    TreeChanged,
    TreeSelectionChanged,
    TreeDelta,
    FrontendProjectionChanged,
    PersonalChanged,
    BookmarksChanged,
    HistoryChanged,
    SettingsChanged,
    KeybindingsChanged,
    Conversation,
    CloudConversation,
    TerminalRegistryChanged,
    TerminalReaped,
    LayoutChanged,
    ClientAttached,
    ClientChanged,
    ClientDetached,
    SizeStateChanged,
    ClientListInvalidated,
    PairingRequested,
    PairingResolved,
    MachineUsageChanged,
    DiagnosticSite,
    Empty,
}

// Every kind is one bit of `MuxEventKinds`.
const _: () = assert!(MuxEventKind::COUNT <= u64::BITS as usize);

impl MuxEventKind {
    /// How many kinds there are (`Empty` is the last).
    pub(crate) const COUNT: usize = Self::Empty as usize + 1;

    pub(crate) const fn of(event: &MuxEvent) -> Self {
        match event {
            MuxEvent::SurfaceOutput(_) => Self::SurfaceOutput,
            MuxEvent::SurfaceResized { .. } => Self::SurfaceResized,
            MuxEvent::SurfaceResizeFailed { .. } => Self::SurfaceResizeFailed,
            MuxEvent::SurfaceExited(..) => Self::SurfaceExited,
            MuxEvent::ProgramStatusChanged { .. } => Self::ProgramStatusChanged,
            MuxEvent::TitleChanged { .. } => Self::TitleChanged,
            MuxEvent::AgentChanged { .. } => Self::AgentChanged,
            MuxEvent::AgentPresenceChanged { .. } => Self::AgentPresenceChanged,
            MuxEvent::Bell(_) => Self::Bell,
            MuxEvent::Notification(_) => Self::Notification,
            MuxEvent::GraphicsStatus(_) => Self::GraphicsStatus,
            MuxEvent::Status(_) => Self::Status,
            MuxEvent::ConfigReloadRequested => Self::ConfigReloadRequested,
            MuxEvent::WindowTitleRequested(_) => Self::WindowTitleRequested,
            MuxEvent::ScrollChanged { .. } => Self::ScrollChanged,
            MuxEvent::TreeChanged => Self::TreeChanged,
            MuxEvent::TreeSelectionChanged => Self::TreeSelectionChanged,
            MuxEvent::TreeDelta(_) => Self::TreeDelta,
            MuxEvent::FrontendProjectionChanged { .. } => Self::FrontendProjectionChanged,
            MuxEvent::PersonalChanged { .. } => Self::PersonalChanged,
            MuxEvent::BookmarksChanged(_) => Self::BookmarksChanged,
            MuxEvent::HistoryChanged { .. } => Self::HistoryChanged,
            MuxEvent::SettingsChanged(_) => Self::SettingsChanged,
            MuxEvent::KeybindingsChanged(_) => Self::KeybindingsChanged,
            MuxEvent::Conversation(_) => Self::Conversation,
            MuxEvent::CloudConversation(_) => Self::CloudConversation,
            MuxEvent::TerminalRegistryChanged { .. } => Self::TerminalRegistryChanged,
            MuxEvent::TerminalReaped { .. } => Self::TerminalReaped,
            MuxEvent::LayoutChanged(..) => Self::LayoutChanged,
            MuxEvent::ClientAttached { .. } => Self::ClientAttached,
            MuxEvent::ClientChanged { .. } => Self::ClientChanged,
            MuxEvent::ClientDetached(_) => Self::ClientDetached,
            MuxEvent::SizeStateChanged { .. } => Self::SizeStateChanged,
            MuxEvent::ClientListInvalidated => Self::ClientListInvalidated,
            MuxEvent::PairingRequested(_) => Self::PairingRequested,
            MuxEvent::PairingResolved { .. } => Self::PairingResolved,
            MuxEvent::MachineUsageChanged(_) => Self::MachineUsageChanged,
            MuxEvent::DiagnosticSite(_) => Self::DiagnosticSite,
            MuxEvent::Empty => Self::Empty,
        }
    }
}

/// A set of [`MuxEventKind`]s: what one subscriber wants to hear.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct MuxEventKinds(u64);

impl MuxEventKinds {
    pub(crate) const NONE: Self = Self(0);

    pub(crate) const fn with(self, kind: MuxEventKind) -> Self {
        Self(self.0 | 1 << kind as u32)
    }

    pub(crate) const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    pub(crate) const fn contains(self, kind: MuxEventKind) -> bool {
        self.0 & (1 << kind as u32) != 0
    }

    pub(crate) const fn accepts(self, event: &MuxEvent) -> bool {
        self.contains(MuxEventKind::of(event))
    }
}

impl MuxEventFilter {
    /// The surface a scoped filter hears, its key in `Subscribers::by_surface`.
    fn surface(&self) -> Option<SurfaceId> {
        match self {
            Self::AttachedSurface(surface) => Some(*surface),
            Self::SurfaceSession(scope) => Some(scope.surface),
            Self::All
            | Self::ConfigReload
            | Self::TerminalTopology
            | Self::LaunchSnapshot
            | Self::Conversations
            | Self::Kinds(_) => None,
        }
    }

    fn accepts(&mut self, event: &MuxEvent) -> bool {
        match self {
            Self::All => true,
            Self::ConfigReload => matches!(event, MuxEvent::ConfigReloadRequested),
            Self::TerminalTopology => matches!(
                event,
                MuxEvent::TreeChanged
                    | MuxEvent::TreeDelta(_)
                    | MuxEvent::TerminalRegistryChanged { .. }
                    | MuxEvent::SurfaceExited(..)
                    | MuxEvent::Empty
            ),
            Self::LaunchSnapshot => matches!(
                event,
                MuxEvent::TreeChanged
                    | MuxEvent::TreeSelectionChanged
                    | MuxEvent::TreeDelta(_)
                    | MuxEvent::LayoutChanged(..)
                    | MuxEvent::PersonalChanged { .. }
                    | MuxEvent::FrontendProjectionChanged { .. }
                    | MuxEvent::Empty
            ),
            Self::Conversations => matches!(event, MuxEvent::Conversation(_) | MuxEvent::Empty),
            Self::Kinds(kinds) => kinds.accepts(event),
            Self::AttachedSurface(surface) => match event {
                MuxEvent::Notification(notification) => notification.surface == Some(*surface),
                MuxEvent::ScrollChanged { surface: event_surface, .. } => {
                    *event_surface == *surface
                }
                _ => false,
            },
            Self::SurfaceSession(scope) => scope.accepts(event),
        }
    }
}

impl SurfaceSessionScope {
    fn accepts(&mut self, event: &MuxEvent) -> bool {
        match event {
            MuxEvent::SurfaceOutput(surface)
            | MuxEvent::SurfaceExited(surface, _)
            | MuxEvent::ProgramStatusChanged { surface, .. }
            | MuxEvent::Bell(surface) => *surface == self.surface,
            MuxEvent::SurfaceResized { surface, .. }
            | MuxEvent::SurfaceResizeFailed { surface, .. }
            | MuxEvent::AgentChanged { surface, .. }
            | MuxEvent::AgentPresenceChanged { surface, .. }
            | MuxEvent::TitleChanged { surface, .. }
            | MuxEvent::ScrollChanged { surface, .. }
            | MuxEvent::SizeStateChanged { surface, .. } => *surface == self.surface,
            MuxEvent::Notification(notification) => {
                notification.surface.is_none_or(|surface| surface == self.surface)
            }
            MuxEvent::TreeDelta(delta) => self.accepts_tree_delta(delta),
            // A surface-only client always renders its target across the full
            // host terminal. Screen layout churn therefore carries no useful
            // state and would only force repeated whole-tree refreshes.
            MuxEvent::LayoutChanged(..) => false,
            MuxEvent::ClientAttached { .. }
            | MuxEvent::ClientChanged { .. }
            | MuxEvent::ClientDetached(_)
            | MuxEvent::ClientListInvalidated
            | MuxEvent::TreeChanged
            | MuxEvent::TreeSelectionChanged
            // The daemon's sites go to the app's control connection only.
            | MuxEvent::DiagnosticSite(_) => false,
            MuxEvent::GraphicsStatus(_)
            | MuxEvent::Status(_)
            | MuxEvent::ConfigReloadRequested
            | MuxEvent::WindowTitleRequested(_)
            | MuxEvent::FrontendProjectionChanged { .. }
            | MuxEvent::PersonalChanged { .. }
            | MuxEvent::BookmarksChanged(_)
            | MuxEvent::HistoryChanged { .. }
            | MuxEvent::SettingsChanged(_)
            | MuxEvent::KeybindingsChanged(_)
            | MuxEvent::Conversation(_)
            | MuxEvent::CloudConversation(_)
            | MuxEvent::TerminalRegistryChanged { .. }
            | MuxEvent::TerminalReaped { .. }
            | MuxEvent::PairingRequested(_)
            | MuxEvent::PairingResolved { .. }
            | MuxEvent::MachineUsageChanged(_)
            | MuxEvent::Empty => true,
        }
    }

    fn accepts_tree_delta(&mut self, delta: &TreeDelta) -> bool {
        let relevant = match delta.kind {
            TreeDeltaKind::TabAdded
            | TreeDeltaKind::TabClosed
            | TreeDeltaKind::TabRenamed
            | TreeDeltaKind::TabChanged => delta.surface == Some(self.surface),
            TreeDeltaKind::PaneClosed => delta.pane == Some(self.pane),
            TreeDeltaKind::ScreenClosed => delta.screen == Some(self.screen),
            TreeDeltaKind::WorkspaceClosed => delta.workspace == self.workspace,
            TreeDeltaKind::WorkspaceAdded
            | TreeDeltaKind::WorkspaceRenamed
            | TreeDeltaKind::WorkspaceMoved
            | TreeDeltaKind::WorkspaceChanged
            | TreeDeltaKind::ScreenAdded
            | TreeDeltaKind::ScreenRenamed
            | TreeDeltaKind::ScreenChanged
            | TreeDeltaKind::PaneAdded => false,
        };
        if delta.surface == Some(self.surface) && delta.kind == TreeDeltaKind::TabAdded {
            self.workspace = delta.workspace;
            if let Some(screen) = delta.screen {
                self.screen = screen;
            }
            if let Some(pane) = delta.pane {
                self.pane = pane;
            }
        }
        relevant
    }
}

impl Drop for MuxEventBroadcaster {
    fn drop(&mut self) {
        let mut subscribers = self.bus.subscribers.lock().recover_poison();
        for subscriber in subscribers.all() {
            if let Some(mailbox) = subscriber.mailbox.upgrade() {
                mailbox.close();
            }
        }
        *subscribers = Subscribers::default();
    }
}

impl MuxEventMailbox {
    fn push(&self, event: Arc<MuxEvent>, cause: EventCause) -> bool {
        let mut state = self.state.lock().recover_poison();
        if state.closed {
            return false;
        }
        let sequence = state.next_sequence;
        state.next_sequence = state.next_sequence.saturating_add(1);
        // A structural change goes after the held fields of the surfaces it touches, as it did
        // before they were held: a tab's change after its own, a close of a pane, screen or
        // workspace (which names no surface) after all of them.
        if let MuxEvent::TreeDelta(delta) = &*event {
            match (delta.surface, delta.kind) {
                (Some(surface), _) => state.release_surface(surface),
                (
                    None,
                    TreeDeltaKind::PaneClosed
                    | TreeDeltaKind::ScreenClosed
                    | TreeDeltaKind::WorkspaceClosed,
                ) => {
                    state.release_held(|_| true);
                }
                (None, _) => {}
            }
        }
        let pushed = if let Some(key) = CoalescedEventKey::of(&event) {
            state.push_coalesced(sequence, key, event, cause)
        } else {
            match *event {
                MuxEvent::SurfaceExited(surface, _) => {
                    state.discard_surface_state(surface);
                    state.push_pending(sequence, event, cause)
                }
                MuxEvent::Empty => {
                    let mut terminal_events = state
                        .events
                        .iter()
                        .filter(|(_, event, _)| {
                            matches!(**event, MuxEvent::SurfaceExited(..))
                                || matches!(
                                    &**event,
                                    MuxEvent::TreeDelta(delta)
                                        if delta.kind == TreeDeltaKind::WorkspaceClosed
                                )
                        })
                        .cloned()
                        .collect::<Vec<_>>();
                    let keep = MAX_PENDING_EVENTS.saturating_sub(1);
                    if terminal_events.len() > keep {
                        terminal_events.drain(..terminal_events.len() - keep);
                    }
                    state.events.clear();
                    state.coalesced_sequences.clear();
                    state.coalesced.clear();
                    state.clear_held();
                    state.events.extend(terminal_events);
                    state.events.push_back((sequence, event, cause));
                    Pushed::Ready
                }
                _ => state.push_pending(sequence, event, cause),
            }
        };
        drop(state);
        match pushed {
            Pushed::Rejected => {
                self.changed.notify_all();
                self.ready_hook.wake();
                false
            }
            Pushed::Ready => {
                self.changed.notify_one();
                self.ready_hook.wake();
                true
            }
            Pushed::Held => true,
        }
    }

    /// Waits for a push or a close and, while a hidden surface's slot is
    /// held, at most until its flush.
    fn wait<'a>(
        &self,
        state: MutexGuard<'a, MuxEventMailboxState>,
    ) -> MutexGuard<'a, MuxEventMailboxState> {
        match state.flush_wait() {
            // wakeup-allow: deadline the held slots' one aligned flush, set only while a hidden surface has a pending change
            Some(wait) => self.changed.wait_timeout(state, wait).recover_poison().0,
            None => self.changed.wait(state).recover_poison(),
        }
    }

    fn close(&self) {
        self.state.lock().recover_poison().closed = true;
        self.changed.notify_all();
        self.ready_hook.wake();
    }
}

impl MuxEventMailboxState {
    /// Replaces the pending event of `key`, if any. The kept event takes
    /// the higher of the two causes: a person's change folded into a later
    /// program one is still the person's.
    ///
    /// The slot of a surface the frontend does not show is held until its
    /// flush ([`VisibilityScope`]); the frontend's own change never is.
    fn push_coalesced(
        &mut self,
        sequence: u128,
        key: CoalescedEventKey,
        event: Arc<MuxEvent>,
        cause: EventCause,
    ) -> Pushed {
        let mut cause = cause;
        let ready = self.coalesced_sequences.remove(&key).and_then(|at| self.coalesced.remove(&at));
        let held = self.take_held(key);
        let replaced = ready.is_some() || held.is_some();
        for (_, _, previous_cause) in ready.into_iter().chain(held) {
            cause = cause.merge(previous_cause);
        }
        if !replaced && !self.reserve_pending_slot() {
            return Pushed::Rejected;
        }
        if self.holds(key, cause) {
            return if self.hold(sequence, key, event, cause) {
                Pushed::Ready
            } else {
                Pushed::Held
            };
        }
        self.coalesced_sequences.insert(key, sequence);
        self.coalesced.insert(sequence, (key, event, cause));
        Pushed::Ready
    }

    fn push_pending(&mut self, sequence: u128, event: Arc<MuxEvent>, cause: EventCause) -> Pushed {
        if !self.reserve_pending_slot() {
            return Pushed::Rejected;
        }
        self.events.push_back((sequence, event, cause));
        Pushed::Ready
    }

    fn discard_coalesced(&mut self, key: CoalescedEventKey) {
        if let Some(previous) = self.coalesced_sequences.remove(&key) {
            self.coalesced.remove(&previous);
        }
        let _ = self.take_held(key);
    }

    fn discard_surface_state(&mut self, surface: SurfaceId) {
        for key in CoalescedEventKey::of_surface(surface) {
            self.discard_coalesced(key);
        }
    }

    fn reserve_pending_slot(&mut self) -> bool {
        if self.events.len() + self.coalesced.len() + self.held_len() < MAX_PENDING_EVENTS {
            true
        } else {
            self.closed = true;
            self.overflowed = true;
            false
        }
    }

    fn pop(&mut self) -> Option<MuxEvent> {
        self.pop_caused().map(|(event, _)| event)
    }

    /// The next event, owned: the last mailbox to take a shared event takes
    /// it without a copy.
    fn pop_caused(&mut self) -> Option<(MuxEvent, EventCause)> {
        self.pop_shared().map(|(event, cause)| (Arc::unwrap_or_clone(event), cause))
    }

    fn pop_shared(&mut self) -> Option<(Arc<MuxEvent>, EventCause)> {
        self.release_due();
        let event_sequence = self.events.front().map(|(sequence, ..)| *sequence);
        let coalesced_sequence = self.coalesced.first_key_value().map(|(sequence, _)| *sequence);
        let next_sequence = [event_sequence, coalesced_sequence].into_iter().flatten().min()?;
        if event_sequence == Some(next_sequence) {
            self.events.pop_front().map(|(_, event, cause)| (event, cause))
        } else {
            let (_, (key, event, cause)) = self.coalesced.pop_first()?;
            self.coalesced_sequences.remove(&key);
            Some((event, cause))
        }
    }
}

impl MuxEventReceiver {
    /// Runs `hook` after each event and when the mailbox closes, for a
    /// subscriber whose drain polls `try_recv` on a sequence instead of
    /// blocking. False when a hook is set already.
    pub(crate) fn on_ready(&self, hook: impl Fn() + Send + Sync + 'static) -> bool {
        self.mailbox.ready_hook.set(hook)
    }

    pub fn close(&self) {
        self.mailbox.close();
    }

    /// Scopes this subscription by the frontend's visible surfaces
    /// (`frontend.visibility.set`): the field events of every other surface
    /// wait in held slots for `flush`'s aligned grid, and a surface that
    /// shows has its held slots released at once. `None` shows every
    /// surface. Returns how many held slots it released.
    pub(crate) fn scope_visibility(
        &self,
        visible: Option<&HashSet<SurfaceId>>,
        flush: &HiddenFlush,
    ) -> usize {
        let released = self.mailbox.state.lock().recover_poison().set_visible(visible, flush);
        if released > 0 {
            self.mailbox.changed.notify_all();
            self.mailbox.ready_hook.wake();
        }
        released
    }

    /// A handle that does not keep the subscription alive.
    pub(crate) fn downgrade(&self) -> WeakMuxEventReceiver {
        WeakMuxEventReceiver(Arc::downgrade(&self.mailbox))
    }

    /// Wake this receiver alone with a `TreeChanged` token. Owner-internal
    /// consumers use it for state changes that no broadcast event carries.
    pub(crate) fn wake(&self) {
        self.mailbox.push(Arc::new(MuxEvent::TreeChanged), EventCause::Program);
    }

    pub fn overflowed(&self) -> bool {
        self.mailbox.state.lock().recover_poison().overflowed
    }

    pub fn recv(&self) -> Result<MuxEvent, RecvError> {
        let mut state = self.mailbox.state.lock().recover_poison();
        loop {
            if let Some(event) = state.pop() {
                return Ok(event);
            }
            if state.closed {
                return Err(RecvError);
            }
            state = self.mailbox.wait(state);
        }
    }

    /// Wakes a blocked `recv_until_interrupted` when `interrupt` fires.
    pub(crate) fn wake_on(&self, interrupt: &crate::stream_interrupt::StreamInterrupt) {
        let mailbox = Arc::downgrade(&self.mailbox);
        interrupt.on_fire(move || {
            if let Some(mailbox) = mailbox.upgrade() {
                let _state = mailbox.state.lock().unwrap_or_else(|error| error.into_inner());
                mailbox.changed.notify_all();
            }
        });
    }

    /// Blocks for an event. Returns `Timeout` once `interrupt` has fired
    /// and nothing is queued.
    pub(crate) fn recv_until_interrupted(
        &self,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> Result<MuxEvent, RecvTimeoutError> {
        self.recv_caused_until_interrupted(interrupt).map(|(event, _)| Arc::unwrap_or_clone(event))
    }

    /// [`Self::recv_until_interrupted`] with the event's cause. The event is
    /// the one every subscriber shares: a reader that only renders it never
    /// copies it.
    pub(crate) fn recv_caused_until_interrupted(
        &self,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> Result<(Arc<MuxEvent>, EventCause), RecvTimeoutError> {
        let mut state = self.mailbox.state.lock().recover_poison();
        loop {
            if let Some(event) = state.pop_shared() {
                return Ok(event);
            }
            if state.closed {
                return Err(RecvTimeoutError::Disconnected);
            }
            if interrupt.is_fired() {
                return Err(RecvTimeoutError::Timeout);
            }
            state = self.mailbox.wait(state);
        }
    }

    pub fn try_recv(&self) -> Result<MuxEvent, TryRecvError> {
        self.try_recv_caused().map(|(event, _)| event)
    }

    /// [`Self::try_recv`] with the event's cause.
    pub(crate) fn try_recv_caused(&self) -> Result<(MuxEvent, EventCause), TryRecvError> {
        let mut state = self.mailbox.state.lock().recover_poison();
        if let Some(event) = state.pop_caused() {
            Ok(event)
        } else if state.closed {
            Err(TryRecvError::Disconnected)
        } else {
            Err(TryRecvError::Empty)
        }
    }

    /// [`Self::try_recv_caused`] without a copy: the event every subscriber
    /// shares, for a drain that only renders it.
    pub(crate) fn try_recv_shared(&self) -> Result<(Arc<MuxEvent>, EventCause), TryRecvError> {
        let mut state = self.mailbox.state.lock().recover_poison();
        if let Some(event) = state.pop_shared() {
            Ok(event)
        } else if state.closed {
            Err(TryRecvError::Disconnected)
        } else {
            Err(TryRecvError::Empty)
        }
    }

    pub fn try_iter(&self) -> impl Iterator<Item = MuxEvent> + '_ {
        std::iter::from_fn(|| self.try_recv().ok())
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<MuxEvent, RecvTimeoutError> {
        self.recv_caused_timeout(timeout).map(|(event, _)| event)
    }

    /// [`Self::recv_timeout`] with the event's cause.
    pub(crate) fn recv_caused_timeout(
        &self,
        timeout: Duration,
    ) -> Result<(MuxEvent, EventCause), RecvTimeoutError> {
        let started = Instant::now();
        let mut state = self.mailbox.state.lock().recover_poison();
        loop {
            if let Some(event) = state.pop_caused() {
                return Ok(event);
            }
            if state.closed {
                return Err(RecvTimeoutError::Disconnected);
            }
            let remaining = timeout.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                return Err(RecvTimeoutError::Timeout);
            }
            let wait = state.flush_wait().map_or(remaining, |flush| flush.min(remaining));
            // wakeup-allow: deadline the caller's one timeout, or the held slots' aligned flush when sooner
            state = self.mailbox.changed.wait_timeout(state, wait).recover_poison().0;
        }
    }

    /// The checked wait of a mailbox-owning thread: the next event, waiting
    /// at most `timeout` (`None`: until one arrives or the bus closes). It is
    /// checked as a [`cmux_threads::BlockingKind::Recv`] at the caller's line,
    /// so it is never called on a request or echo thread.
    #[track_caller]
    pub(crate) fn wait_event(
        &self,
        timeout: Option<Duration>,
    ) -> Result<MuxEvent, RecvTimeoutError> {
        cmux_threads::assert_blocking_allowed(cmux_threads::BlockingKind::Recv);
        match timeout {
            // wakeup-allow: deadline the caller's one timeout; an event or the bus closing ends it first
            Some(timeout) => self.recv_timeout(timeout),
            None => self.recv().map_err(|_| RecvTimeoutError::Disconnected),
        }
    }
}

#[cfg(test)]
#[path = "event_bus_tests.rs"]
mod tests;
