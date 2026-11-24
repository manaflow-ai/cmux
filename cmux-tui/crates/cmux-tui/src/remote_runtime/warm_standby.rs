//! One warm standby route per peer: after the active link is up, the best other route is
//! dialed to a provider group and kept, so when the active route dies the reconnect takes the
//! standby at once instead of racing the routes cold.
//!
//! What "warm" buys depends on the provider. The group of `iroh://` is a live QUIC connection
//! (the dial, hole punching and TLS are done); an `ssh://` route's group is lazy, but its
//! bootstrap (a `remote-probe` round trip, see `prepared_ssh`) is done when the standby is
//! armed; a `ws(s)://` group is lazy (its socket opens with the link), so a standby there saves
//! the race's bookkeeping only. Relay routes keep their own standby (`relay_standby.rs`) and
//! are never held here.
//!
//! No daemon state is held: the standby is a group, not a link, so there is no pending link
//! group to expire (the daemon's `PENDING_LINK_TTL`, 30 s, only starts at a link hello). But a
//! daemon closes an iroh connection that opens no stream within its `first_stream_timeout`
//! (15 s, `provider/iroh.rs`), and a standby opens none until it is used. So a new standby asks
//! the far end to hold it ([`LinkGroup::hold`], one unidirectional stream each way, no cmux
//! stream): a listener that knows the hold keeps it until its unauthenticated timeout (5 min) and
//! says so, and the standby is kept for that lease less [`HOLD_MARGIN`], one connection per peer
//! every few minutes instead of a QUIC handshake every few seconds. A far end with no hold (an
//! older daemon, or a provider without one) is asked once per peer; there the standby is redialed
//! after [`REFRESH`] (the old one kept until the new one is in), never trusted past [`MAX_AGE`],
//! both under the daemon's 15 s. Before a standby is taken its group is asked whether it closed
//! (local state, no round trip). The keeper also re-arms the moment a held group
//! closes. A standby that is live by every local sign but dead on the wire gets a short redial
//! ([`attempt_timeout`]) with the ordinary race started behind it.
//!
//! Bounded: one standby per peer, re-armed after use, none for the Cloud carrier (single-use
//! grants, and `carrier::source` does not use this) nor for any auth but Enrolled, and
//! `CMUX_REMOTE_WARM_STANDBY=0` turns it off.

use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::Notify;
use tokio::time::Instant;

use super::route_race::RouteRace;
use super::{ReconnectRouteAttempt, ResolvedRouteCandidate, connect_request, next_reconnect_route};
use cmux_remote::crypto::AuthKind;
use cmux_remote::provider::ProviderError;
use cmux_remote_protocol::{LanePolicy, SessionId};

/// How long a standby is trusted. Under the daemon's 15 s close of a connection that opened
/// no stream, with room for the clocks of both ends and a slow link.
pub(crate) const MAX_AGE: Duration = Duration::from_secs(11);
/// How long before a standby stops being trusted the keeper dials its replacement (the old one
/// is held until the new one is in).
pub(crate) const REFRESH_LEAD: Duration = Duration::from_secs(3);
/// When the keeper replaces a standby the far end does not hold.
pub(crate) const REFRESH: Duration = MAX_AGE.saturating_sub(REFRESH_LEAD);
/// A held standby is trusted until this long before its lease ends.
pub(crate) const HOLD_MARGIN: Duration = Duration::from_secs(5);

/// How long a standby is trusted: [`MAX_AGE`], or a hold's lease less [`HOLD_MARGIN`].
pub(crate) fn trusted_for(lease: Option<Duration>) -> Duration {
    lease.map_or(MAX_AGE, |lease| lease.saturating_sub(HOLD_MARGIN).max(MAX_AGE))
}

/// When the keeper replaces a standby trusted for `max_age`: [`REFRESH`] for one with no hold.
fn refresh_at(max_age: Duration) -> Duration {
    if max_age <= MAX_AGE { REFRESH } else { max_age.saturating_sub(REFRESH_LEAD) }
}
/// A standby that closed sooner than this after it was armed counts as a failed arm (backoff),
/// so a far end that closes every standby at once is not redialed in a loop.
pub(crate) const MIN_LIFE: Duration = Duration::from_secs(1);
/// The floor of a redial on a standby: covers scheduling on a loaded machine.
pub(crate) const ATTEMPT_FLOOR: Duration = Duration::from_secs(1);
/// The bound of a redial on a standby whose round trip is not known.
pub(crate) const ATTEMPT_UNKNOWN_RTT: Duration = Duration::from_secs(3);

/// The bound of the redial on a standby: `ATTEMPT_FLOOR + 2 × rtt` (a Noise handshake and the
/// resume each take one round trip on a group that is already up), or
/// [`ATTEMPT_UNKNOWN_RTT`].
pub(crate) fn attempt_timeout(rtt: Option<Duration>) -> Duration {
    rtt.map_or(ATTEMPT_UNKNOWN_RTT, |rtt| ATTEMPT_FLOOR.saturating_add(rtt.saturating_mul(2)))
}
/// The first wait after a failed arm; it doubles up to [`MAX_BACKOFF`].
pub(crate) const INITIAL_BACKOFF: Duration = Duration::from_secs(2);
pub(crate) const MAX_BACKOFF: Duration = Duration::from_secs(60);

/// `CMUX_REMOTE_WARM_STANDBY=0` keeps no standby (the A/B for its numbers).
pub(crate) fn warm_standby_enabled() -> bool {
    std::env::var_os("CMUX_REMOTE_WARM_STANDBY").is_none_or(|value| value != "0")
}

struct Standby<T> {
    index: usize,
    group: T,
    armed_at: Instant,
    /// [`trusted_for`] its hold.
    max_age: Duration,
}

/// The standby slot of one peer.
pub(crate) struct WarmStandby<T> {
    slot: Mutex<Option<Standby<T>>>,
    /// The route the link is on (the one the standby must not be).
    active: AtomicUsize,
    wake: Arc<Notify>,
    /// The far end answered no hold once: later standbys of this peer do not ask again.
    no_hold: AtomicBool,
}

impl<T> WarmStandby<T> {
    pub(crate) fn new(active: usize) -> Self {
        Self {
            slot: Mutex::new(None),
            active: AtomicUsize::new(active),
            wake: Arc::default(),
            no_hold: AtomicBool::new(false),
        }
    }

    /// Wakes the keeper to look at the slot now.
    pub(crate) fn wake(&self) -> Arc<Notify> {
        Arc::clone(&self.wake)
    }

    fn set_active(&self, index: usize) {
        self.active.store(index, Ordering::Relaxed);
    }

    /// The held standby, when it is fresh and `alive` says its group has not closed. A stale or
    /// closed one is returned in `Err` to be closed.
    fn take(&self, alive: impl Fn(&T) -> bool) -> Option<Result<(usize, T), T>> {
        let held = self.slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take()?;
        Some(if held.armed_at.elapsed() < held.max_age && alive(&held.group) {
            Ok((held.index, held.group))
        } else {
            Err(held.group)
        })
    }

    /// The held standby's group and when it was armed (the keeper waits on its close).
    pub(crate) fn held(&self) -> Option<(T, Instant)>
    where
        T: Clone,
    {
        let slot = self.slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        slot.as_ref().map(|held| (held.group.clone(), held.armed_at))
    }

    /// How long until the held standby is due its replacement (`None`: nothing held, or the
    /// one held closed).
    fn refresh_in(&self, alive: impl Fn(&T) -> bool) -> Option<Duration> {
        let slot = self.slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        slot.as_ref()
            .filter(|held| alive(&held.group))
            .map(|held| refresh_at(held.max_age).saturating_sub(held.armed_at.elapsed()))
    }

    /// The held standby's route, for logs and tests.
    #[cfg(test)]
    pub(crate) fn held_index(&self) -> Option<usize> {
        self.slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).as_ref().map(|s| s.index)
    }

    fn put(&self, index: usize, group: T, armed_at: Instant, max_age: Duration) -> Option<T> {
        self.slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .replace(Standby { index, group, armed_at, max_age })
            .map(|old| old.group)
    }
}

impl<T> Drop for WarmStandby<T> {
    fn drop(&mut self) {
        // The keeper ends at its next look.
        self.wake.notify_one();
    }
}

/// The route the standby goes on: the one the reconnect pass would try first, that is not the
/// active one. Relay routes are skipped (`relay_standby.rs` is theirs).
pub(crate) fn standby_route(
    routes: &[ResolvedRouteCandidate],
    next: usize,
    active: usize,
    auth: AuthKind,
) -> Option<usize> {
    let len = routes.len();
    if len == 0 {
        return None;
    }
    (0..len).map(|offset| (next % len + offset) % len).find(|&index| {
        index != active
            && routes.get(index).is_some_and(|route| {
                route.supports_client_auth(auth) && !route.endpoint.scheme().starts_with("relay+")
            })
    })
}

/// What one look at the slot did.
pub(crate) enum Armed<T> {
    /// A live standby is held, not yet due its replacement; look again after this long.
    Held(Duration),
    /// A standby on this route was dialed. `retired` is the one it replaced, to close.
    Dialed { retired: Option<T> },
    /// No route can be a standby (a single route, or none supports the auth).
    NoRoute,
}

/// Fills the slot if it is empty, closed (`alive` false) or due its replacement. A new standby
/// asks the far end to `hold` it unless this peer's far end already answered no hold.
pub(crate) async fn arm_standby<T: Send + Clone, H: Future<Output = Option<Duration>>>(
    standby: &WarmStandby<T>,
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &(impl ReconnectRouteAttempt<T> + ?Sized),
    alive: impl Fn(&T) -> bool,
    hold: impl FnOnce(T) -> H,
) -> Result<Armed<T>, ProviderError> {
    if let Some(left) = standby.refresh_in(&alive).filter(|left| !left.is_zero()) {
        return Ok(Armed::Held(left));
    }
    let Some(index) = standby_route(
        routes,
        next.load(Ordering::Relaxed),
        standby.active.load(Ordering::Relaxed),
        auth,
    ) else {
        return Ok(Armed::NoRoute);
    };
    let Some(route) = routes.get(index) else { return Ok(Armed::NoRoute) };
    let request = connect_request(route, session, lane_policy)
        .map_err(|error| ProviderError::Configuration(error.to_string()))?;
    let group = attempt.connect(index, request, auth).await?;
    let dialed_at = Instant::now();
    let lease =
        if standby.no_hold.load(Ordering::Relaxed) { None } else { hold(group.clone()).await };
    if lease.is_none() {
        standby.no_hold.store(true, Ordering::Relaxed);
    }
    Ok(Armed::Dialed { retired: standby.put(index, group, dialed_at, trusted_for(lease)) })
}

/// The standby for a redial about to start ([`ReconnectGroupSource::take_standby`]): the
/// held one when it is fresh and `alive`, with the route it is on. The rotation moves to that
/// route, so the pass started behind it redials it cold first (a standby can be dead on the
/// wire with every local sign live), and the next standby goes beside it. A stale or closed
/// one is returned in `Err` to be closed.
///
/// [`ReconnectGroupSource::take_standby`]: cmux_remote::connection::ReconnectGroupSource::take_standby
pub(crate) fn take_standby<T>(
    standby: &WarmStandby<T>,
    next: &AtomicUsize,
    alive: impl Fn(&T) -> bool,
) -> Option<Result<(usize, T), T>> {
    let taken = standby.take(alive)?;
    if let Ok((index, _)) = &taken {
        next.store(*index, Ordering::Relaxed);
        standby.set_active(*index);
    }
    standby.wake.notify_one();
    Some(taken)
}

/// [`next_reconnect_route`] that starts from the standby: a fresh, live one is the answer
/// with no dial (the standby's route is dialed already). Without one, or when it is stale or
/// closed, the ordinary pass. Returns the group and, for a stale or closed standby, the one to
/// close.
pub(crate) async fn next_warm_route<T: Send>(
    standby: &WarmStandby<T>,
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    race: Option<RouteRace>,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &impl ReconnectRouteAttempt<T>,
    alive: impl Fn(&T) -> bool,
) -> Result<(T, Option<T>), ProviderError> {
    let mut stale = None;
    match standby.take(alive) {
        Some(Ok((index, group))) => {
            next.store(index.saturating_add(1), Ordering::Relaxed);
            standby.set_active(index);
            standby.wake.notify_one();
            return Ok((group, None));
        }
        Some(Err(old)) => stale = Some(old),
        None => {}
    }
    let group =
        next_reconnect_route(next, routes, race, session, lane_policy, auth, attempt).await?;
    let len = routes.len().max(1);
    standby.set_active((next.load(Ordering::Relaxed) + len - 1) % len);
    standby.wake.notify_one();
    Ok((group, stale))
}
