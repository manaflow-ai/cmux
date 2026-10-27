//! The bus fan-out: the publish queue, the subscriber index and the
//! delivery that runs outside `Mux::state`.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Weak};

use cmux_threads::sync::Mutex;

use super::{MuxEventFilter, MuxEventMailbox, SessionPathUpdate};
use crate::event_cause::EventCause;
use crate::lock_rank::LockRank;
use crate::panic_free::RecoverPoison;
use crate::{MuxEvent, SurfaceId, TreeDeltaKind};

#[derive(Default)]
pub(super) struct Bus {
    /// Held for a whole fan-out, which also orders two fan-outs.
    pub(super) subscribers: Mutex<Subscribers>,
    /// Published and not yet delivered. A leaf lock held for one push or
    /// one take; lock order: `subscribers` before `queue`.
    pub(super) queue: Mutex<PublishQueue>,
}

#[derive(Default)]
pub(super) struct PublishQueue {
    pub(super) next_sequence: u64,
    items: VecDeque<Published>,
}

/// One queued publication, in emit order.
pub(super) enum Published {
    Event { sequence: u64, event: Arc<MuxEvent>, cause: EventCause },
    SessionPath { sequence: u64, path: SessionPathUpdate, cause: EventCause },
}

/// The subscribers, by who hears first and by scope. The frontend (the
/// verified app's stream) is served first; surface-scoped subscribers are
/// indexed by their surface, so an event of one surface runs that surface's
/// filters only.
#[derive(Default)]
pub(super) struct Subscribers {
    frontend: Vec<MuxEventSubscriber>,
    broad: Vec<MuxEventSubscriber>,
    pub(super) by_surface: HashMap<SurfaceId, Vec<MuxEventSubscriber>>,
    pub(super) stats: FanOutStats,
}

/// What fan-outs did, read by tests (empty in other builds).
#[derive(Default)]
pub(super) struct FanOutStats {
    #[cfg(test)]
    pub(super) filter_runs: usize,
    /// The mailboxes pushed to, in push order.
    #[cfg(test)]
    pub(super) pushes: Vec<usize>,
}

/// Which surface-scoped subscribers can hear an event. It only prunes: a
/// subscriber left out is one whose filter refuses the event and changes
/// nothing.
#[derive(Clone, Copy)]
enum ScopedRoute {
    /// Only subscribers of this surface.
    Surface(SurfaceId),
    /// Every surface-scoped subscriber.
    All,
    /// No surface-scoped subscriber.
    None,
}

/// The last field of `StateGuard`, dropped after the lock: delivers what
/// this thread queued while it held `Mux::state`.
pub(crate) struct StateReleasePublish(());

thread_local! {
    /// Buses that hold events this thread queued under `Mux::state`.
    static QUEUED_UNDER_STATE: RefCell<Vec<Weak<Bus>>> = const { RefCell::new(Vec::new()) };
}

pub(super) struct MuxEventSubscriber {
    pub(super) mailbox: Weak<MuxEventMailbox>,
    pub(super) filter: MuxEventFilter,
    /// The first publication it hears: nothing queued before it subscribed.
    pub(super) since: u64,
}

impl Bus {
    pub(super) fn publish(bus: &Arc<Self>, item: impl FnOnce(u64) -> Published) {
        {
            let mut queue = bus.queue.lock().recover_poison();
            let sequence = queue.next_sequence;
            queue.next_sequence = sequence.saturating_add(1);
            queue.items.push_back(item(sequence));
        }
        if crate::workspace_registry::registry_connection::current_thread_holds_state() {
            // During thread teardown the next publish delivers it.
            let _ = QUEUED_UNDER_STATE.try_with(|queued| {
                let mut queued = queued.borrow_mut();
                if !queued.iter().any(|queued| std::ptr::eq(queued.as_ptr(), Arc::as_ptr(bus))) {
                    queued.push(Arc::downgrade(bus));
                }
            });
            return;
        }
        bus.deliver_queued();
    }

    /// Deliver everything queued, in order. Never runs under `Mux::state`.
    #[track_caller]
    pub(super) fn deliver_queued(&self) {
        crate::lock_rank::debug_assert_rank_not_held(LockRank::MuxState, "the mux event fan-out");
        let mut subscribers = self.subscribers.lock().recover_poison();
        loop {
            let batch = std::mem::take(&mut self.queue.lock().recover_poison().items);
            if batch.is_empty() {
                return;
            }
            subscribers.deliver(&batch);
        }
    }
}

impl StateReleasePublish {
    pub(crate) const fn armed() -> Self {
        Self(())
    }
}

impl Drop for StateReleasePublish {
    fn drop(&mut self) {
        // A panic leaves its events queued for the next publish.
        if std::thread::panicking()
            || crate::workspace_registry::registry_connection::current_thread_holds_state()
        {
            return;
        }
        let queued = QUEUED_UNDER_STATE
            .try_with(|queued| std::mem::take(&mut *queued.borrow_mut()))
            .unwrap_or_default();
        for bus in queued.iter().filter_map(Weak::upgrade) {
            bus.deliver_queued();
        }
    }
}

impl Subscribers {
    pub(super) fn insert(&mut self, subscriber: MuxEventSubscriber, frontend: bool) {
        if frontend {
            self.frontend.push(subscriber);
        } else if let Some(surface) = subscriber.filter.surface() {
            self.by_surface.entry(surface).or_default().push(subscriber);
        } else {
            self.broad.push(subscriber);
        }
    }

    pub(super) fn all(&self) -> impl Iterator<Item = &MuxEventSubscriber> {
        self.frontend.iter().chain(&self.broad).chain(self.by_surface.values().flatten())
    }

    /// Drop subscribers whose receiver is gone. A fan-out drops only those
    /// it visits; this runs on each subscribe.
    pub(super) fn prune(&mut self) {
        let live = |subscriber: &MuxEventSubscriber| subscriber.mailbox.strong_count() > 0;
        self.frontend.retain(live);
        self.broad.retain(live);
        self.by_surface.retain(|_, scoped| {
            scoped.retain(live);
            !scoped.is_empty()
        });
    }

    /// Deliver `batch` in order: the whole batch to the frontend first, then
    /// to the broad subscribers, then each item to the scoped subscribers
    /// its route names.
    fn deliver(&mut self, batch: &VecDeque<Published>) {
        let Self { frontend, broad, by_surface, stats } = self;
        for list in [frontend, broad] {
            list.retain_mut(|subscriber| {
                let Some(mailbox) = subscriber.mailbox.upgrade() else { return false };
                batch.iter().all(|item| subscriber.deliver(&mailbox, item, stats))
            });
        }
        for item in batch {
            match item.route() {
                ScopedRoute::Surface(surface) => {
                    if let Some(scoped) = by_surface.get_mut(&surface) {
                        deliver_item(scoped, item, stats);
                        if scoped.is_empty() {
                            by_surface.remove(&surface);
                        }
                    }
                }
                ScopedRoute::All => by_surface.retain(|_, scoped| {
                    deliver_item(scoped, item, stats);
                    !scoped.is_empty()
                }),
                ScopedRoute::None => {}
            }
        }
    }
}

fn deliver_item(scoped: &mut Vec<MuxEventSubscriber>, item: &Published, stats: &mut FanOutStats) {
    scoped.retain_mut(|subscriber| {
        let Some(mailbox) = subscriber.mailbox.upgrade() else { return false };
        subscriber.deliver(&mailbox, item, stats)
    });
}

impl MuxEventSubscriber {
    /// Offer one item; false once the mailbox is closed.
    fn deliver(
        &mut self,
        mailbox: &Arc<MuxEventMailbox>,
        item: &Published,
        stats: &mut FanOutStats,
    ) -> bool {
        if item.sequence() < self.since {
            return true;
        }
        let event = match item {
            Published::Event { event, .. } => {
                stats.filter_ran();
                if !self.filter.accepts(event) {
                    return true;
                }
                Arc::clone(event)
            }
            Published::SessionPath { path: (surface, workspace, screen, pane), .. } => {
                let MuxEventFilter::SurfaceSession(scope) = &mut self.filter else { return true };
                if scope.surface != *surface {
                    return true;
                }
                scope.workspace = *workspace;
                scope.screen = *screen;
                scope.pane = *pane;
                Arc::new(MuxEvent::TreeChanged)
            }
        };
        stats.pushed(mailbox);
        mailbox.push(event, item.cause())
    }
}

impl FanOutStats {
    fn filter_ran(&mut self) {
        #[cfg(test)]
        {
            self.filter_runs += 1;
        }
    }

    fn pushed(&mut self, mailbox: &Arc<MuxEventMailbox>) {
        #[cfg(test)]
        self.pushes.push(Arc::as_ptr(mailbox) as usize);
        #[cfg(not(test))]
        let _ = mailbox;
    }
}

impl Published {
    fn sequence(&self) -> u64 {
        match self {
            Self::Event { sequence, .. } | Self::SessionPath { sequence, .. } => *sequence,
        }
    }

    fn cause(&self) -> EventCause {
        match self {
            Self::Event { cause, .. } | Self::SessionPath { cause, .. } => *cause,
        }
    }

    fn route(&self) -> ScopedRoute {
        match self {
            Self::Event { event, .. } => ScopedRoute::of(event),
            Self::SessionPath { path: (surface, ..), .. } => ScopedRoute::Surface(*surface),
        }
    }
}

impl ScopedRoute {
    /// The scoped subscribers whose filter can accept `event`: the union of
    /// what [`SurfaceSessionScope::accepts`] and the attached-surface filter
    /// accept (event_bus_tests checks it against both).
    fn of(event: &MuxEvent) -> Self {
        match event {
            MuxEvent::SurfaceOutput(surface)
            | MuxEvent::SurfaceExited(surface, _)
            | MuxEvent::ProgramStatusChanged { surface, .. }
            | MuxEvent::Bell(surface)
            | MuxEvent::SurfaceResized { surface, .. }
            | MuxEvent::SurfaceResizeFailed { surface, .. }
            | MuxEvent::AgentChanged { surface, .. }
            | MuxEvent::AgentPresenceChanged { surface, .. }
            | MuxEvent::TitleChanged { surface, .. }
            | MuxEvent::ScrollChanged { surface, .. }
            | MuxEvent::SizeStateChanged { surface, .. } => Self::Surface(*surface),
            MuxEvent::Notification(notification) => {
                notification.surface.map_or(Self::All, Self::Surface)
            }
            MuxEvent::TreeDelta(delta) => match delta.kind {
                TreeDeltaKind::TabAdded
                | TreeDeltaKind::TabClosed
                | TreeDeltaKind::TabRenamed
                | TreeDeltaKind::TabChanged => delta.surface.map_or(Self::None, Self::Surface),
                TreeDeltaKind::PaneClosed
                | TreeDeltaKind::ScreenClosed
                | TreeDeltaKind::WorkspaceClosed => Self::All,
                TreeDeltaKind::WorkspaceAdded
                | TreeDeltaKind::WorkspaceRenamed
                | TreeDeltaKind::WorkspaceMoved
                | TreeDeltaKind::WorkspaceChanged
                | TreeDeltaKind::ScreenAdded
                | TreeDeltaKind::ScreenRenamed
                | TreeDeltaKind::ScreenChanged
                | TreeDeltaKind::PaneAdded => Self::None,
            },
            MuxEvent::LayoutChanged(..)
            | MuxEvent::ClientAttached { .. }
            | MuxEvent::ClientChanged { .. }
            | MuxEvent::ClientDetached(_)
            | MuxEvent::ClientListInvalidated
            | MuxEvent::TreeChanged
            | MuxEvent::TreeSelectionChanged => Self::None,
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
            | MuxEvent::Empty => Self::All,
        }
    }
}
