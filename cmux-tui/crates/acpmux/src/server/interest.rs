//! Part of the server; see `server/mod.rs`. Which connections a hub event wakes (cmuxterm-hq#13493
//! item 3). Leo, 2026-11-18: "Why should non visible thing even affect the renderer thread
//! anyways?"
//!
//! Before, every connection's fan-out task (`fanout.rs`) read the hub's one broadcast and dropped
//! in [`super::deliver`] what it did not need: bytes were bounded, but each event woke every
//! connection, O(events x connections). Now the hub routes each event, as it sends it, into the
//! [`Inbox`] of each connection it can reach:
//!
//! - **attached**: a connection attached to the event's session hears every record of it;
//! - **watching**: a connection that watches (`_acpmux/watch`) hears the records a watcher is sent
//!   anything for ([`watch_hears`]): change kinds, a removal, a row change, a peer's row;
//! - **activity**: a connection with a chats window or a chats watch hears the records that can
//!   change a chat's attention or preview ([`activity_hears`]).
//!
//! A connection none of these name is never woken. [`super::deliver`] still decides what each
//! woken connection is sent, against its state when it reads the event, as before: routing only
//! decides who wakes, and names a superset of whom `deliver` sends to.
//!
//! Order and lag are the broadcast's: every event is routed under one lock, in the order it is
//! broadcast, so each inbox holds its events in that order; an inbox holds as many as the
//! broadcast does and, full, drops its oldest and answers [`RecvError::Lagged`] once with the
//! count, as a lagging broadcast receiver does. A connection now lags only on events it needed.
//!
//! Per connection, interest changes with its state under the same locks that change that state:
//! an attach, detach or watch toggle ([`Conn::set_watching`](super::Conn::set_watching)) takes
//! effect for the next event routed, so a page that pauses its watch (`_acpmux/watch
//! {enabled: false}`) stops being woken by other chats' changes at once, and one that resumes it
//! hears from the next change on (its watch reply carries the list as it is then).

use crate::hub::HubEvent;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::Notify;
use tokio::sync::broadcast::error::{RecvError, TryRecvError};

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Whether a connection that watches, and is not attached to the event's session, can be sent
/// anything for it by [`super::deliver`] (its `watching` branch, [`super::processes::push_update`]
/// and the cold-archive row notice). Kept beside `deliver`'s rules: a kind added there is added
/// here.
pub(crate) fn watch_hears(ev: &HubEvent) -> bool {
    let rec = &ev.record;
    if rec.kind == crate::hub::PEER_LAGGED {
        return false;
    }
    if rec.dir == crate::hub::COLD_CHANGED {
        return true;
    }
    if ev.remote.is_some() {
        return rec.dir == "peer" || rec.kind == crate::hub::PEER_PERMISSION_PENDING;
    }
    if rec.dir == "mux" && rec.kind == "purged" {
        return true;
    }
    (rec.dir == "mux" || rec.kind == "available_commands_update")
        && super::change_kind::session_change_kind(&rec.kind).is_some()
}

/// Whether the event can change a chat's activity ([`super::chats::push_activity`]): what a
/// connection with a chats window or a chats watch hears without attaching or watching.
pub(crate) fn activity_hears(ev: &HubEvent) -> bool {
    ev.record.dir == "mux" && crate::chats::changes_activity(&ev.record.kind)
}

/// One connection's queue of the hub events routed to it.
pub(crate) struct Inbox {
    id: u64,
    capacity: usize,
    queue: Mutex<Queue>,
    wake: Notify,
    /// Events routed here: each one woke (or would wake) its fan-out task once.
    routed: AtomicU64,
}

#[derive(Default)]
struct Queue {
    events: VecDeque<HubEvent>,
    /// Dropped oldest-first since the last read: told once, as `Lagged`.
    dropped: u64,
    closed: bool,
    /// The last send this inbox took, so one connection named twice (attached and watching)
    /// gets an event once.
    last_send: u64,
}

impl Inbox {
    /// Queues `ev` for send number `send`, unless it already holds it; wakes the reader when the
    /// queue was empty (a reader with events left reads on without one).
    fn push(&self, send: u64, ev: &HubEvent) {
        let was_empty = {
            let mut q = lock(&self.queue);
            if q.closed || q.last_send == send {
                return;
            }
            q.last_send = send;
            if q.events.len() >= self.capacity {
                q.events.pop_front();
                q.dropped += 1;
            }
            let was_empty = q.events.is_empty();
            q.events.push_back(ev.clone());
            was_empty
        };
        self.routed.fetch_add(1, Ordering::Relaxed);
        if was_empty {
            self.wake.notify_one();
        }
    }

    /// The next event routed here, as `broadcast::Receiver::recv` answers: `Lagged(n)` once after
    /// `n` were dropped, `Closed` once the connection is gone and the queue is empty.
    pub(crate) async fn recv(&self) -> Result<HubEvent, RecvError> {
        loop {
            // Made before the check: a push between the check and the wait stores its permit.
            let notified = self.wake.notified();
            match self.try_recv() {
                Ok(ev) => return Ok(ev),
                Err(TryRecvError::Lagged(n)) => return Err(RecvError::Lagged(n)),
                Err(TryRecvError::Closed) => return Err(RecvError::Closed),
                Err(TryRecvError::Empty) => notified.await,
            }
        }
    }

    /// [`Self::recv`] without waiting: `Empty` when nothing is queued.
    pub(crate) fn try_recv(&self) -> Result<HubEvent, TryRecvError> {
        let mut q = lock(&self.queue);
        if q.dropped > 0 {
            return Err(TryRecvError::Lagged(std::mem::take(&mut q.dropped)));
        }
        if let Some(ev) = q.events.pop_front() {
            return Ok(ev);
        }
        Err(if q.closed { TryRecvError::Closed } else { TryRecvError::Empty })
    }

    /// Events routed here so far.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn routed(&self) -> u64 {
        self.routed.load(Ordering::Relaxed)
    }
}

/// What one inbox asked to hear.
#[derive(Default)]
struct Wants {
    sessions: HashSet<String>,
    watching: bool,
    activity: bool,
}

#[derive(Default)]
struct Routes {
    sends: u64,
    next_id: u64,
    wants: HashMap<u64, Wants>,
    by_session: HashMap<String, Vec<Arc<Inbox>>>,
    watchers: Vec<Arc<Inbox>>,
    activity: Vec<Arc<Inbox>>,
}

fn remove(list: &mut Vec<Arc<Inbox>>, id: u64) {
    list.retain(|inbox| inbox.id != id);
}

/// The hub's routing table: which inbox each event goes to. Owned by the hub's event channel
/// (`hub/list_guard.rs` `Events`), which routes every event it broadcasts through [`Self::send`].
pub(crate) struct Router {
    capacity: usize,
    routes: Mutex<Routes>,
}

impl Router {
    pub(crate) fn new(capacity: usize) -> Self {
        Self { capacity: capacity.max(1), routes: Mutex::new(Routes::default()) }
    }

    /// A new connection's inbox, hearing nothing until it attaches, watches or opens chats.
    pub(crate) fn inbox(&self) -> Arc<Inbox> {
        let mut routes = lock(&self.routes);
        routes.next_id += 1;
        let inbox = Arc::new(Inbox {
            id: routes.next_id,
            capacity: self.capacity,
            queue: Mutex::new(Queue::default()),
            wake: Notify::new(),
            routed: AtomicU64::new(0),
        });
        routes.wants.insert(inbox.id, Wants::default());
        inbox
    }

    /// Broadcasts `ev` with `broadcast` and routes it to every inbox that wants it, both under the
    /// routing lock: the inboxes hold events in the order they were broadcast.
    pub(crate) fn send<R>(&self, ev: HubEvent, broadcast: impl FnOnce(HubEvent) -> R) -> R {
        let mut routes = lock(&self.routes);
        routes.sends += 1;
        let send = routes.sends;
        let mut targets: Vec<&Arc<Inbox>> = Vec::new();
        if let Some(attached) = routes.by_session.get(&ev.session_id) {
            targets.extend(attached);
        }
        if !routes.watchers.is_empty() && watch_hears(&ev) {
            targets.extend(&routes.watchers);
        }
        if !routes.activity.is_empty() && activity_hears(&ev) {
            targets.extend(&routes.activity);
        }
        // The fan-out clock (`gauges.fanout`) waits for each connection the event wakes, armed
        // before any of them can take it; one connection named twice takes it once.
        targets.sort_unstable_by_key(|inbox| inbox.id);
        targets.dedup_by_key(|inbox| inbox.id);
        ev.row.fanout.arm(targets.len());
        for inbox in targets {
            inbox.push(send, &ev);
        }
        broadcast(ev)
    }

    /// `inbox` hears every event of `session` (an attach, local or a peer's chat).
    pub(crate) fn attach(&self, inbox: &Arc<Inbox>, session: &str) {
        let mut routes = lock(&self.routes);
        let Some(wants) = routes.wants.get_mut(&inbox.id) else { return };
        if wants.sessions.insert(session.to_owned()) {
            routes.by_session.entry(session.to_owned()).or_default().push(inbox.clone());
        }
    }

    /// `inbox` stops hearing `session` for its own sake (a detach).
    pub(crate) fn detach(&self, inbox: &Inbox, session: &str) {
        let mut routes = lock(&self.routes);
        let Some(wants) = routes.wants.get_mut(&inbox.id) else { return };
        if wants.sessions.remove(session)
            && let Some(list) = routes.by_session.get_mut(session)
        {
            remove(list, inbox.id);
            if list.is_empty() {
                routes.by_session.remove(session);
            }
        }
    }

    /// `inbox` hears what a watcher hears ([`watch_hears`]), or stops.
    pub(crate) fn set_watching(&self, inbox: &Arc<Inbox>, on: bool) {
        let mut routes = lock(&self.routes);
        let Some(wants) = routes.wants.get_mut(&inbox.id) else { return };
        if wants.watching == on {
            return;
        }
        wants.watching = on;
        if on {
            routes.watchers.push(inbox.clone());
        } else {
            remove(&mut routes.watchers, inbox.id);
        }
    }

    /// `inbox` hears activity records ([`activity_hears`]) from now on: its connection opened a
    /// chats window or a chats watch. Kept until the connection closes.
    pub(crate) fn hear_activity(&self, inbox: &Arc<Inbox>) {
        let mut routes = lock(&self.routes);
        let Some(wants) = routes.wants.get_mut(&inbox.id) else { return };
        if !wants.activity {
            wants.activity = true;
            routes.activity.push(inbox.clone());
        }
    }

    /// The connection closed: `inbox` hears nothing more, and its reader sees `Closed` once the
    /// queue is read.
    pub(crate) fn forget(&self, inbox: &Inbox) {
        {
            let mut routes = lock(&self.routes);
            if let Some(wants) = routes.wants.remove(&inbox.id) {
                for session in wants.sessions {
                    if let Some(list) = routes.by_session.get_mut(&session) {
                        remove(list, inbox.id);
                        if list.is_empty() {
                            routes.by_session.remove(&session);
                        }
                    }
                }
                if wants.watching {
                    remove(&mut routes.watchers, inbox.id);
                }
                if wants.activity {
                    remove(&mut routes.activity, inbox.id);
                }
            }
        }
        lock(&inbox.queue).closed = true;
        inbox.wake.notify_one();
    }

    /// How many inboxes are routed to (a closed connection's is gone).
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn inboxes(&self) -> usize {
        lock(&self.routes).wants.len()
    }
}

/// One connection's place in the [`Router`]: its inbox, and the calls that change what it hears.
/// Each is called beside the change of the connection's state it follows (`view.rs` attach and
/// detach, `list_reply.rs` watch, `chats.rs` and `chat_windows.rs` for activity).
pub(crate) struct Interest {
    router: Arc<Router>,
    pub(crate) inbox: Arc<Inbox>,
}

impl Interest {
    pub(crate) fn new(router: &Arc<Router>) -> Self {
        Self { router: router.clone(), inbox: router.inbox() }
    }

    /// Hears every event of `session`.
    pub(crate) fn attach(&self, session: &str) {
        self.router.attach(&self.inbox, session);
    }

    /// Stops hearing `session` for its own sake.
    pub(crate) fn detach(&self, session: &str) {
        self.router.detach(&self.inbox, session);
    }

    /// Hears what a watcher hears, or stops: the per-connection pause and resume.
    pub(crate) fn set_watching(&self, on: bool) {
        self.router.set_watching(&self.inbox, on);
    }

    /// Hears activity records from now on.
    pub(crate) fn hear_activity(&self) {
        self.router.hear_activity(&self.inbox);
    }

    /// The connection closed.
    pub(crate) fn forget(&self) {
        self.router.forget(&self.inbox);
    }
}

#[cfg(test)]
#[path = "interest_tests.rs"]
mod tests;
