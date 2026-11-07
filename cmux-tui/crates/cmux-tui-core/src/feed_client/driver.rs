//! The cloud driver: one thread that keeps `/v1/wire/feed` open on the
//! app's cloud lease (Swift `CloudFeedSource`). It waits on the socket (a
//! queued frame interrupts the receive), on a reconnect backoff, or on a new
//! lease; it stops at `FeedClient::shutdown`.

use std::sync::Arc;
use std::time::Duration;

use cmux_feed_core::client::{CloudAction, Connection, FEED_WIRE_PATH, Frame, Owner, Reject};

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

/// Another account (or none): the old account's cloud items, intents and
/// reports leave; the integration owner's items stay.
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
    state.owner.set_user(user.as_deref().unwrap_or_default());
    state.account = user;
    state.reports_generation += 1;
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
                if apply(inner, &text) {
                    *backoff = Duration::from_secs(1);
                }
            }
        }
    }
}

/// One frame into the stream and the mirror; true for a snapshot (the
/// stream is live: the backoff starts over).
fn apply(inner: &Inner, text: &str) -> bool {
    let now = inner.now();
    let mut live = false;
    let mut account_moved = false;
    let events = {
        let mut state = inner.lock();
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
    live
}
