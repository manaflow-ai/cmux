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
//! group to expire (the daemon's `PENDING_LINK_TTL`, 30 s, only starts at a link hello). The
//! standby is dropped and redialed after [`MAX_AGE`] so a transport the network silently
//! dropped is not what the next reconnect starts on.
//!
//! Bounded: one standby per peer, re-armed after use, none for the Cloud carrier (single-use
//! grants, and `carrier::source` does not use this) nor for any auth but Enrolled, and
//! `CMUX_REMOTE_WARM_STANDBY=0` turns it off.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::Notify;
use tokio::time::Instant;

use super::route_race::RouteRace;
use super::{ReconnectRouteAttempt, ResolvedRouteCandidate, connect_request, next_reconnect_route};
use cmux_remote::crypto::AuthKind;
use cmux_remote::provider::ProviderError;
use cmux_remote_protocol::{LanePolicy, SessionId};

/// How long a standby is trusted before it is dropped and dialed again.
pub(crate) const MAX_AGE: Duration = Duration::from_secs(30);
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
}

/// The standby slot of one peer.
pub(crate) struct WarmStandby<T> {
    slot: Mutex<Option<Standby<T>>>,
    /// The route the link is on (the one the standby must not be).
    active: AtomicUsize,
    wake: Arc<Notify>,
}

impl<T> WarmStandby<T> {
    pub(crate) fn new(active: usize) -> Self {
        Self { slot: Mutex::new(None), active: AtomicUsize::new(active), wake: Arc::default() }
    }

    /// Wakes the keeper to look at the slot now.
    pub(crate) fn wake(&self) -> Arc<Notify> {
        Arc::clone(&self.wake)
    }

    fn set_active(&self, index: usize) {
        self.active.store(index, Ordering::Relaxed);
    }

    /// The held standby, when it is fresh. A stale one is returned in `Err` to be closed.
    fn take(&self) -> Option<Result<(usize, T), T>> {
        let held = self.slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take()?;
        Some(if held.armed_at.elapsed() < MAX_AGE {
            Ok((held.index, held.group))
        } else {
            Err(held.group)
        })
    }

    /// How long until the held standby goes stale (`None`: nothing held).
    pub(crate) fn fresh_for(&self) -> Option<Duration> {
        let slot = self.slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        slot.as_ref().map(|held| MAX_AGE.saturating_sub(held.armed_at.elapsed()))
    }

    /// The held standby's route, for logs and tests.
    #[cfg(test)]
    pub(crate) fn held_index(&self) -> Option<usize> {
        self.slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).as_ref().map(|s| s.index)
    }

    fn put(&self, index: usize, group: T) -> Option<T> {
        self.slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .replace(Standby { index, group, armed_at: Instant::now() })
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
            && routes[index].supports_client_auth(auth)
            && !routes[index].endpoint.scheme().starts_with("relay+")
    })
}

/// What one look at the slot did.
pub(crate) enum Armed<T> {
    /// A fresh standby is held already; look again after this long.
    Held(Duration),
    /// A standby on this route was dialed. `retired` is the stale one it replaced, to close.
    Dialed { index: usize, retired: Option<T> },
    /// No route can be a standby (a single route, or none supports the auth).
    NoRoute,
}

/// Fills the slot if it is empty or stale.
pub(crate) async fn arm_standby<T: Send>(
    standby: &WarmStandby<T>,
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &(impl ReconnectRouteAttempt<T> + ?Sized),
) -> Result<Armed<T>, ProviderError> {
    if let Some(left) = standby.fresh_for().filter(|left| !left.is_zero()) {
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
    let request = connect_request(&routes[index], session, lane_policy)
        .map_err(|error| ProviderError::Configuration(error.to_string()))?;
    let t0 = Instant::now();
    let group = attempt.connect(index, request, auth).await;
    if std::env::var_os("CMUX_BENCH_TRACE").is_some() {
        eprintln!(
            "bench-trace arm_standby: route {index} connect {}ms ok={}",
            t0.elapsed().as_millis(),
            group.is_ok()
        );
    }
    let group = group?;
    Ok(Armed::Dialed { index, retired: standby.put(index, group) })
}

/// [`next_reconnect_route`] that starts from the standby: a fresh one is the answer with no
/// dial (the standby's route is dialed already). Without one, or when it is stale, the
/// ordinary pass. Returns the group and, for a stale standby, the one to close.
pub(crate) async fn next_warm_route<T: Send>(
    standby: &WarmStandby<T>,
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    race: Option<RouteRace>,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &impl ReconnectRouteAttempt<T>,
) -> Result<(T, Option<T>), ProviderError> {
    let mut stale = None;
    let bench_trace = std::env::var_os("CMUX_BENCH_TRACE").is_some();
    match standby.take() {
        Some(Ok((index, group))) => {
            if bench_trace {
                eprintln!("bench-trace next_warm_route: took fresh standby route {index}");
            }
            next.store(index.saturating_add(1), Ordering::Relaxed);
            standby.set_active(index);
            standby.wake.notify_one();
            return Ok((group, None));
        }
        Some(Err(old)) => {
            if bench_trace {
                eprintln!("bench-trace next_warm_route: standby stale");
            }
            stale = Some(old)
        }
        None => {
            if bench_trace {
                eprintln!("bench-trace next_warm_route: no standby");
            }
        }
    }
    let group =
        next_reconnect_route(next, routes, race, session, lane_policy, auth, attempt).await?;
    let len = routes.len().max(1);
    standby.set_active((next.load(Ordering::Relaxed) + len - 1) % len);
    standby.wake.notify_one();
    Ok((group, stale))
}
