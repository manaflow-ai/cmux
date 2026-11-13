//! The cloud driver: one thread that keeps `/v1/wire/feed` open on the
//! app's cloud lease (Swift `CloudFeedSource`). It waits on the socket (a
//! queued frame interrupts the receive), on a reconnect backoff, or on a new
//! lease; it stops at `FeedClient::shutdown`.

use std::sync::Arc;
use std::time::Duration;

use cmux_feed_core::client::{
    CloudAction, Connection, FEED_WIRE_PATH, Frame, Owner, Reject, is_github,
};

use super::{FeedEvent, Inner, State, view_event};
use crate::cloud_conversations::{CloudConversations, CloudWire, OwnerWireError, WireRecv};

/// The longest reconnect backoff while the owner is unreachable.
const MAX_BACKOFF: Duration = Duration::from_secs(30);
/// A wait for a new lease ends at least this often (a check, not a poll of
/// the page: a new lease or a shutdown ends it at once).
const LEASE_WAIT: Duration = Duration::from_secs(300);
/// A receive with an interrupter waits this long; without one a queued
/// frame waits at most [`FALLBACK_RECV`].
const RECV: Duration = Duration::from_secs(30);
const FALLBACK_RECV: Duration = Duration::from_secs(1);

pub(super) fn start(inner: &Arc<Inner>) {
    let Some(cloud) = inner.deps.cloud.clone() else { return };
    let inner = Arc::clone(inner);
    let spawned = std::thread::Builder::new()
        .name("cmux-feed-cloud".to_owned())
        .spawn(move || run(&inner, &cloud));
    if let Err(error) = spawned {
        eprintln!("cmux-tui: feed: the cloud driver did not start: {error}");
    }
}

/// How one socket ended.
enum Ended {
    Stopped,
    /// The socket dropped: reconnect after the backoff.
    Dropped,
    /// The owner refused the token (close 4401): wait for another lease.
    Unauthenticated,
    /// The lease changed under the socket: reconnect now.
    NewLease,
}

fn run(inner: &Inner, cloud: &CloudConversations) {
    let mut backoff = Duration::from_secs(1);
    while !inner.stopped() {
        forget_other_lease(inner, cloud);
        let (generation, ended) = match cloud.open_owner_wire(FEED_WIRE_PATH) {
            Ok(owner) => {
                let generation = owner.generation;
                (generation, pump(inner, cloud, owner.wire, generation, &mut backoff))
            }
            Err((error, generation)) => {
                let reason = match &error {
                    OwnerWireError::SignedOut => "signed_out",
                    OwnerWireError::Expired => "expired",
                    OwnerWireError::Unauthenticated => "unauthenticated",
                    OwnerWireError::Forbidden => "forbidden",
                    OwnerWireError::Unavailable(_) => "unavailable",
                };
                disconnect(inner, reason, error == OwnerWireError::SignedOut);
                match error {
                    OwnerWireError::Unavailable(_) => (generation, Ended::Dropped),
                    OwnerWireError::Unauthenticated => (generation, Ended::Unauthenticated),
                    _ => {
                        cloud.wait_lease_change(generation, LEASE_WAIT);
                        continue;
                    }
                }
            }
        };
        match ended {
            Ended::Stopped => break,
            Ended::NewLease => {}
            Ended::Dropped => {
                disconnect(inner, "offline", false);
                cloud.wait_lease_change(generation, backoff);
                backoff = (backoff * 2).min(MAX_BACKOFF);
            }
            Ended::Unauthenticated => {
                // The app hears `cloud-session-needed` and renews the
                // lease; this token is not tried again.
                disconnect(inner, "unauthenticated", false);
                cloud.report_unauthenticated(generation);
                while !inner.stopped() && cloud.lease_generation() == generation {
                    cloud.wait_lease_change(generation, LEASE_WAIT);
                }
            }
        }
    }
    disconnect(inner, "offline", false);
}

/// The socket closed or never opened: cloud items refuse changes until the
/// next snapshot; a sign-out also takes them away.
fn disconnect(inner: &Inner, reason: &str, signed_out: bool) {
    let now = inner.now();
    let events = {
        let mut state = inner.lock();
        state.stream.on_disconnect();
        state.wire_wake = None;
        state.outbox.clear();
        let mut events: Vec<FeedEvent> = Vec::new();
        if signed_out {
            events.extend(change_account(&mut state, None, now));
        }
        events.extend(
            state
                .mirror
                .set_connection(Connection::Disconnected(reason.to_owned()))
                .map(view_event),
        );
        events
    };
    inner.wake.notify_all();
    inner.emit(events);
}

/// The person the lease names: its Stack project and user, else a
/// self-hosted server and its user; `None` with no lease. With it, the
/// person's user id when the lease names one.
fn lease_identity(cloud: &CloudConversations) -> Option<(String, Option<String>)> {
    cloud
        .lease_person()
        .map(|(user, project)| (format!("stack:{project}:{user}"), Some(user)))
        .or_else(|| {
            cloud.lease_selfhost().map(|(origin, user)| {
                (format!("selfhost:{origin}:{}", user.as_deref().unwrap_or_default()), user)
            })
        })
}

/// A lease of another person takes the old account's state away at once,
/// before any socket opens on it: a refused or failing connection never
/// leaves the old account's items, reports or GitHub rows readable.
pub(super) fn forget_other_lease(inner: &Inner, cloud: &CloudConversations) {
    let (identity, user) = lease_identity(cloud).unzip();
    let user = user.flatten();
    let now = inner.now();
    let events = {
        let mut state = inner.lock();
        if state.lease_identity == identity {
            return;
        }
        state.lease_identity = identity;
        state.lease_user = user;
        let mut events = change_account(&mut state, None, now);
        // The Reports basket follows the lease's person even before any
        // welcome: the reader starts over on the new person's mailbox.
        if state.reports.clear() {
            events.push(FeedEvent::Reports { revision: state.reports.revision() });
        }
        state.reports_epoch = state.reports_epoch.wrapping_add(1);
        state.reports_generation = state.reports_generation.wrapping_add(1);
        events.extend(state.mirror.set_connection(Connection::Connecting).map(view_event));
        events
    };
    inner.wake.notify_all();
    inner.emit(events);
}

/// Another account (or none): the old account's cloud items, intents and
/// reports leave; on every change, signed out to signed in too, the GitHub
/// rows, ETags and details leave (the poller reads GitHub again at once); the
/// integration owner's other items stay.
pub(super) fn change_account(state: &mut State, user: Option<String>, now: i64) -> Vec<FeedEvent> {
    if state.account == user {
        return Vec::new();
    }
    let mut events = Vec::new();
    if state.account.is_some() {
        events.extend(state.mirror.clear_cloud(now).map(view_event));
        for key in state.stream.reset() {
            events.extend(Inner::settle(state, &key, Some(Reject::Disconnected), now));
        }
        if state.reports.clear() {
            events.push(FeedEvent::Reports { revision: state.reports.revision() });
        }
    }
    // The GitHub poller starts over on every change of account, signed out
    // included (None -> Some as well): no row, ETag or detail read under the
    // old account (or none) stays, a poll in flight is dropped, and the
    // waiting poller wakes for a pass.
    let github_rows = state.owner.remove_where(is_github);
    events.extend(Inner::local_events(state, github_rows.into_iter().collect(), now));
    state.github.reset();
    state.github_epoch = state.github_epoch.wrapping_add(1);
    state.github_generation = state.github_generation.wrapping_add(1);
    state.owner.set_user(user.as_deref().unwrap_or_default());
    state.account = user;
    state.reports_epoch = state.reports_epoch.wrapping_add(1);
    state.reports_generation = state.reports_generation.wrapping_add(1);
    events
}

fn pump(
    inner: &Inner,
    cloud: &CloudConversations,
    mut wire: Box<dyn CloudWire>,
    generation: u64,
    backoff: &mut Duration,
) -> Ended {
    let interrupter = wire.interrupter();
    let recv = if interrupter.is_some() { RECV } else { FALLBACK_RECV };
    let events = {
        let mut state = inner.lock();
        state.stream.on_connect();
        state.outbox.clear();
        state.wire_wake = interrupter;
        state.mirror.set_connection(Connection::Connecting).map(view_event)
    };
    inner.emit(events.into_iter().collect());
    loop {
        if inner.stopped() {
            return Ended::Stopped;
        }
        if cloud.lease_generation() != generation {
            return Ended::NewLease;
        }
        let outbox = std::mem::take(&mut inner.lock().outbox);
        for frame in outbox {
            if wire.send(&frame).is_err() {
                return Ended::Dropped;
            }
        }
        match wire.recv(recv) {
            WireRecv::Idle => {}
            WireRecv::Closed { code: Some(4401) } => return Ended::Unauthenticated,
            WireRecv::Closed { .. } => return Ended::Dropped,
            WireRecv::Text(text) => {
                match apply(inner, &text, || cloud.lease_generation() == generation) {
                    Applied::Live => *backoff = Duration::from_secs(1),
                    Applied::Frame => {}
                    Applied::OldLease => return Ended::NewLease,
                }
            }
        }
    }
}

/// What one frame did.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Applied {
    /// A snapshot: the stream is live, the backoff starts over.
    Live,
    Frame,
    /// The lease changed since the socket opened: the frame is the old
    /// lease's and is dropped.
    OldLease,
}

/// One frame into the stream and the mirror. `current` says whether the
/// socket's lease is still the lease; it is asked under the feed lock, so a
/// frame never lands after `FeedClient::lease_changed` took the old
/// account's state away (that bumps the lease first, then takes the lock).
pub(super) fn apply(inner: &Inner, text: &str, current: impl Fn() -> bool) -> Applied {
    let now = inner.now();
    let mut live = false;
    let mut account_moved = false;
    let events = {
        let mut state = inner.lock();
        if !current() {
            return Applied::OldLease;
        }
        let mut events = Vec::new();
        let mut actions: std::collections::VecDeque<CloudAction> =
            state.stream.on_text(text).into();
        while let Some(action) = actions.pop_front() {
            match action {
                CloudAction::Send(frame) => state.outbox.push(frame),
                CloudAction::User(user) => {
                    if state.account.as_deref() == Some(user.as_str()) {
                        continue;
                    }
                    let had_account = state.account.is_some();
                    events.extend(change_account(&mut state, Some(user.clone()), now));
                    account_moved = true;
                    if had_account {
                        // The reset forgot the stream: welcome it again, and
                        // drop the subscribe of the old stream that follows.
                        actions.retain(|action| !matches!(action, CloudAction::Send(_)));
                        actions.extend(
                            state
                                .stream
                                .on_frame(Frame::Welcome { user })
                                .into_iter()
                                .filter(|action| !matches!(action, CloudAction::User(_))),
                        );
                    }
                }
                CloudAction::Snapshot { user, items } => {
                    live = true;
                    events.extend(state.mirror.cloud_snapshot(&user, items, now).map(view_event));
                    events
                        .extend(state.mirror.set_connection(Connection::Connected).map(view_event));
                }
                CloudAction::Event { items, removed } => {
                    events.extend(
                        state.mirror.event(Owner::Cloud, items, removed, None, now).map(view_event),
                    );
                }
                CloudAction::Settled { key, reject } => {
                    events.extend(Inner::settle(&mut state, &key, reject, now));
                }
            }
        }
        events
    };
    if account_moved {
        inner.wake.notify_all();
    }
    inner.emit(events);
    if live { Applied::Live } else { Applied::Frame }
}
