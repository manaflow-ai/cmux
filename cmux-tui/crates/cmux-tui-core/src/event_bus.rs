//! Per-subscriber mux event delivery with bounded coalesced state.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::mpsc::{RecvError, RecvTimeoutError, TryRecvError};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use crate::{MuxEvent, PaneId, ScreenId, SurfaceId, TreeDelta, TreeDeltaKind, WorkspaceId};

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
    let previous = restore.0.take().expect("deferral scope restores once");
    let recorded = DEFERRED_SESSION_PATHS
        .with(|cell| std::mem::replace(&mut *cell.borrow_mut(), previous))
        .unwrap_or_default();
    (output, DeferredSessionPaths(recorded))
}

#[derive(Default)]
pub struct MuxEventBroadcaster {
    subscribers: Mutex<Vec<MuxEventSubscriber>>,
}

struct MuxEventSubscriber {
    mailbox: Weak<MuxEventMailbox>,
    filter: MuxEventFilter,
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

#[derive(Default)]
struct MuxEventMailbox {
    state: Mutex<MuxEventMailboxState>,
    changed: Condvar,
}

#[derive(Default)]
struct MuxEventMailboxState {
    next_sequence: u128,
    events: VecDeque<(u128, MuxEvent)>,
    coalesced_sequences: HashMap<CoalescedEventKey, u128>,
    coalesced: BTreeMap<u128, (CoalescedEventKey, MuxEvent)>,
    closed: bool,
    overflowed: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum CoalescedEventKey {
    ConfigReload,
    Agent(SurfaceId),
    Title(SurfaceId),
    SurfaceOutput(SurfaceId),
    Scroll(SurfaceId),
}

impl MuxEventBroadcaster {
    pub fn subscribe(&self) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::All)
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
        let mut subscribers = self.subscribers.lock().unwrap();
        subscribers.retain_mut(|subscriber| {
            let Some(mailbox) = subscriber.mailbox.upgrade() else { return false };
            if let MuxEventFilter::SurfaceSession(scope) = &mut subscriber.filter
                && scope.surface == surface
            {
                scope.workspace = workspace;
                scope.screen = screen;
                scope.pane = pane;
                return mailbox.push(MuxEvent::TreeChanged);
            }
            true
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
        let mailbox = Arc::new(MuxEventMailbox::default());
        self.subscribers
            .lock()
            .unwrap()
            .push(MuxEventSubscriber { mailbox: Arc::downgrade(&mailbox), filter });
        MuxEventReceiver { mailbox }
    }

    pub fn emit(&self, event: MuxEvent) {
        let mut subscribers = self.subscribers.lock().unwrap();
        subscribers.retain_mut(|subscriber| {
            let Some(mailbox) = subscriber.mailbox.upgrade() else { return false };
            !subscriber.filter.accepts(&event) || mailbox.push(event.clone())
        });
    }
}

impl MuxEventFilter {
    fn accepts(&mut self, event: &MuxEvent) -> bool {
        match self {
            Self::All => true,
            Self::ConfigReload => matches!(event, MuxEvent::ConfigReloadRequested),
            Self::TerminalTopology => matches!(
                event,
                MuxEvent::TreeChanged
                    | MuxEvent::TreeDelta(_)
                    | MuxEvent::TerminalRegistryChanged { .. }
                    | MuxEvent::SurfaceExited(_)
                    | MuxEvent::Empty
            ),
            Self::LaunchSnapshot => matches!(
                event,
                MuxEvent::TreeChanged
                    | MuxEvent::TreeSelectionChanged
                    | MuxEvent::TreeDelta(_)
                    | MuxEvent::LayoutChanged(_)
                    | MuxEvent::PersonalChanged { .. }
                    | MuxEvent::FrontendProjectionChanged { .. }
                    | MuxEvent::Empty
            ),
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
            | MuxEvent::SurfaceExited(surface)
            | MuxEvent::Bell(surface) => *surface == self.surface,
            MuxEvent::SurfaceResized { surface, .. }
            | MuxEvent::SurfaceResizeFailed { surface, .. }
            | MuxEvent::AgentChanged { surface, .. }
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
            MuxEvent::LayoutChanged(_) => false,
            MuxEvent::ClientAttached { .. }
            | MuxEvent::ClientChanged { .. }
            | MuxEvent::ClientDetached(_)
            | MuxEvent::ClientListInvalidated
            | MuxEvent::TreeChanged
            | MuxEvent::TreeSelectionChanged => false,
            MuxEvent::GraphicsStatus(_)
            | MuxEvent::Status(_)
            | MuxEvent::ConfigReloadRequested
            | MuxEvent::WindowTitleRequested(_)
            | MuxEvent::FrontendProjectionChanged { .. }
            | MuxEvent::PersonalChanged { .. }
            | MuxEvent::BookmarksChanged(_)
            | MuxEvent::SettingsChanged(_)
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
        for subscriber in self.subscribers.get_mut().unwrap().drain(..) {
            if let Some(mailbox) = subscriber.mailbox.upgrade() {
                mailbox.close();
            }
        }
    }
}

impl MuxEventMailbox {
    fn push(&self, event: MuxEvent) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return false;
        }
        let sequence = state.next_sequence;
        state.next_sequence = state.next_sequence.saturating_add(1);
        let accepted = match event {
            event @ MuxEvent::AgentChanged { surface, .. } => {
                state.push_coalesced(sequence, CoalescedEventKey::Agent(surface), event)
            }
            event @ MuxEvent::TitleChanged { surface, .. } => {
                state.push_coalesced(sequence, CoalescedEventKey::Title(surface), event)
            }
            event @ MuxEvent::SurfaceOutput(surface) => {
                state.push_coalesced(sequence, CoalescedEventKey::SurfaceOutput(surface), event)
            }
            event @ MuxEvent::ScrollChanged { surface, .. } => {
                state.push_coalesced(sequence, CoalescedEventKey::Scroll(surface), event)
            }
            MuxEvent::ConfigReloadRequested => state.push_coalesced(
                sequence,
                CoalescedEventKey::ConfigReload,
                MuxEvent::ConfigReloadRequested,
            ),
            MuxEvent::SurfaceExited(surface) => {
                state.discard_surface_state(surface);
                if !state.reserve_pending_slot() {
                    false
                } else {
                    state.events.push_back((sequence, MuxEvent::SurfaceExited(surface)));
                    true
                }
            }
            MuxEvent::Empty => {
                let mut terminal_events = state
                    .events
                    .iter()
                    .filter(|(_, event)| {
                        matches!(event, MuxEvent::SurfaceExited(_))
                            || matches!(
                                event,
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
                state.events.extend(terminal_events);
                state.events.push_back((sequence, MuxEvent::Empty));
                true
            }
            event => {
                if !state.reserve_pending_slot() {
                    false
                } else {
                    state.events.push_back((sequence, event));
                    true
                }
            }
        };
        if !accepted {
            self.changed.notify_all();
            return false;
        }
        self.changed.notify_one();
        true
    }

    fn close(&self) {
        self.state.lock().unwrap().closed = true;
        self.changed.notify_all();
    }
}

impl MuxEventMailboxState {
    fn push_coalesced(&mut self, sequence: u128, key: CoalescedEventKey, event: MuxEvent) -> bool {
        if let Some(previous) = self.coalesced_sequences.get(&key).copied() {
            self.coalesced.remove(&previous);
        } else if !self.reserve_pending_slot() {
            return false;
        }
        self.coalesced_sequences.insert(key, sequence);
        self.coalesced.insert(sequence, (key, event));
        true
    }

    fn discard_coalesced(&mut self, key: CoalescedEventKey) {
        if let Some(previous) = self.coalesced_sequences.remove(&key) {
            self.coalesced.remove(&previous);
        }
    }

    fn discard_surface_state(&mut self, surface: SurfaceId) {
        self.discard_coalesced(CoalescedEventKey::Agent(surface));
        self.discard_coalesced(CoalescedEventKey::Title(surface));
        self.discard_coalesced(CoalescedEventKey::SurfaceOutput(surface));
        self.discard_coalesced(CoalescedEventKey::Scroll(surface));
    }

    fn reserve_pending_slot(&mut self) -> bool {
        if self.events.len() + self.coalesced.len() < MAX_PENDING_EVENTS {
            true
        } else {
            self.closed = true;
            self.overflowed = true;
            false
        }
    }

    fn pop(&mut self) -> Option<MuxEvent> {
        let event_sequence = self.events.front().map(|(sequence, _)| *sequence);
        let coalesced_sequence = self.coalesced.first_key_value().map(|(sequence, _)| *sequence);
        let next_sequence = [event_sequence, coalesced_sequence].into_iter().flatten().min()?;
        if event_sequence == Some(next_sequence) {
            self.events.pop_front().map(|(_, event)| event)
        } else {
            let (_, (key, event)) = self.coalesced.pop_first()?;
            self.coalesced_sequences.remove(&key);
            Some(event)
        }
    }
}

impl MuxEventReceiver {
    pub fn close(&self) {
        self.mailbox.close();
    }

    /// Wake this receiver alone with a `TreeChanged` token. Owner-internal
    /// consumers use it for state changes that no broadcast event carries.
    pub(crate) fn wake(&self) {
        self.mailbox.push(MuxEvent::TreeChanged);
    }

    pub fn overflowed(&self) -> bool {
        self.mailbox.state.lock().unwrap().overflowed
    }

    pub fn recv(&self) -> Result<MuxEvent, RecvError> {
        let mut state = self.mailbox.state.lock().unwrap();
        loop {
            if let Some(event) = state.pop() {
                return Ok(event);
            }
            if state.closed {
                return Err(RecvError);
            }
            state = self.mailbox.changed.wait(state).unwrap();
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
        let mut state = self.mailbox.state.lock().unwrap();
        loop {
            if let Some(event) = state.pop() {
                return Ok(event);
            }
            if state.closed {
                return Err(RecvTimeoutError::Disconnected);
            }
            if interrupt.is_fired() {
                return Err(RecvTimeoutError::Timeout);
            }
            state = self.mailbox.changed.wait(state).unwrap();
        }
    }

    pub fn try_recv(&self) -> Result<MuxEvent, TryRecvError> {
        let mut state = self.mailbox.state.lock().unwrap();
        if let Some(event) = state.pop() {
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
        let started = Instant::now();
        let mut remaining = timeout;
        let mut state = self.mailbox.state.lock().unwrap();
        loop {
            if let Some(event) = state.pop() {
                return Ok(event);
            }
            if state.closed {
                return Err(RecvTimeoutError::Disconnected);
            }
            let (next, waited) = self.mailbox.changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if waited.timed_out() {
                if let Some(event) = state.pop() {
                    return Ok(event);
                }
                if state.closed {
                    return Err(RecvTimeoutError::Disconnected);
                }
                return Err(RecvTimeoutError::Timeout);
            }
            remaining = timeout.saturating_sub(started.elapsed());
        }
    }
}
