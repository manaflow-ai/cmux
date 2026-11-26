//! The first connect's pass over a daemon's route candidates, raced (happy eyeballs for
//! routes, RFC 8305 §5): the first route starts, and the next starts when the ones before it
//! have not connected within [`RouteRace::stagger`], or at once when one fails. The first
//! route whose whole connect finishes (transport, Noise handshake, link-ready on every lane)
//! wins; the others are dropped, which closes their sockets.
//!
//! Why racing whole connects is safe: every connect draws its own random connection attempt
//! id (`establish_physical_links` in cmux-remote), and the daemon keys a pending link group by
//! (device, session, generation, attempt), so two racers never join one group. Only one group
//! can register the session at generation 0: the daemon registers groups one at a time per
//! session, and a second one finds the session taken and is closed. So the connect that
//! finishes here is the one the daemon kept. A loser that reached the daemon holds its pending
//! group until the daemon's pending-link expiry (30 s).
//!
//! Before this, routes were tried in order and each got the whole attempt budget (15 s by
//! default), so a black-holed first route cost every first connect 15 s.
//!
//! Without a [`RouteRace`] the pass is the old one: one route at a time, in order.

use std::time::Duration;

use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use tokio::time::Instant;

use super::{
    InitialRouteAttempt, InitialRouteAttemptError, InitialRouteSelectionError,
    ReconnectRouteAttempt, ResolvedRouteCandidate, RouteFailure, connect_request, sanitized_route,
};
use cmux_remote::crypto::AuthKind;
use cmux_remote::provider::{ConnectRequest, ProviderError};
use cmux_remote_protocol::{LanePolicy, SessionId};

/// When the next route starts while the ones before it have not connected.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RouteRace {
    pub(crate) stagger: Duration,
}

impl RouteRace {
    /// The shortest stagger: RFC 8305's recommended connection attempt delay.
    pub(crate) const FLOOR: Duration = Duration::from_millis(250);
    /// The longest: a slow route remembered from a bad network never holds the next one back
    /// longer than this.
    pub(crate) const CEILING: Duration = Duration::from_secs(2);

    /// The race for a dial whose leading route last connected in `lead` (`None`: not known).
    /// The stagger is `max(250 ms, 1.5 × lead)`, at most [`Self::CEILING`]: a route that took
    /// 400 ms over a long path last time gets 600 ms before the next one starts beside it,
    /// one on a LAN gets the floor. A connect takes several round trips, so this is never
    /// shorter than 1.5 round trips.
    pub(crate) fn after(lead: Option<Duration>) -> Self {
        let stagger =
            lead.map_or(Self::FLOOR, |lead| lead.mul_f64(1.5).clamp(Self::FLOOR, Self::CEILING));
        Self { stagger }
    }
}

/// The order of a pass: which route goes first (the last-known-good one), and whether the
/// routes race.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct RouteOrder {
    pub(crate) first: Option<usize>,
    pub(crate) race: Option<RouteRace>,
}

impl RouteOrder {
    /// One route at a time, `first` before the rest.
    pub(crate) fn serial(first: Option<usize>) -> Self {
        Self { first, race: None }
    }

    /// Raced, `first` leading.
    pub(crate) fn raced(first: Option<usize>, race: RouteRace) -> Self {
        Self { first, race: Some(race) }
    }
}

/// Which step of a route's dial failed.
#[derive(Clone, Copy)]
enum Stage {
    Bootstrap,
    Connect,
}

/// A route's dial, finished.
struct Finished<T, E> {
    /// Where the route is in the pass's order.
    position: usize,
    display: String,
    upgrade_candidate: bool,
    stage: Stage,
    result: Result<T, InitialRouteAttemptError<E>>,
}

async fn dial<T: Send, E: Send, A: InitialRouteAttempt<T, E> + ?Sized>(
    attempt: &A,
    position: usize,
    index: usize,
    display: String,
    request: ConnectRequest,
    upgrade_candidate: bool,
) -> Finished<T, E> {
    if request.endpoint.scheme() == "ssh"
        && let Err(error) = attempt.bootstrap_ssh(&request.endpoint, upgrade_candidate).await
    {
        return Finished {
            position,
            display,
            upgrade_candidate,
            stage: Stage::Bootstrap,
            result: Err(error),
        };
    }
    let result = attempt.connect(index, request).await;
    Finished { position, display, upgrade_candidate, stage: Stage::Connect, result }
}

/// One pass over `routes` in `order`. `--upgrade` (`upgrade`) is never raced and never
/// reordered: the SSH route at 0 installs the daemon and must go first, alone.
pub(crate) async fn select_routes<T: Send, E: RouteFailure>(
    routes: &[ResolvedRouteCandidate],
    order: RouteOrder,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    upgrade: bool,
    attempt: &(impl InitialRouteAttempt<T, E> + ?Sized),
) -> Result<T, InitialRouteSelectionError<E>> {
    if routes.is_empty() {
        return Err(InitialRouteSelectionError::terminal(E::terminal(
            "remote connection has no route candidates".into(),
        )));
    }
    if upgrade && routes.first().is_none_or(|route| route.endpoint.scheme() != "ssh") {
        return Err(InitialRouteSelectionError::terminal(E::terminal(
            "--upgrade requires SSH to be the initial route".into(),
        )));
    }
    let first = order.first.filter(|&first| !upgrade && first < routes.len());
    let race = order.race.filter(|_| !upgrade);
    let sequence: Vec<usize> =
        first.into_iter().chain((0..routes.len()).filter(|&index| Some(index) != first)).collect();
    // Each route's failure at its place in the order, so the error lists them as dialed.
    let mut failures: Vec<Option<String>> = vec![None; sequence.len()];
    let mut last: Option<(usize, E)> = None;
    let mut retryable = false;
    let mut cursor = 0;
    let mut in_flight = FuturesUnordered::new();
    // When the next route may start beside the ones in flight (`None`: only once they end).
    let mut next_at: Option<Instant> = None;
    loop {
        while cursor < sequence.len()
            && (in_flight.is_empty() || next_at.is_some_and(|at| Instant::now() >= at))
        {
            let position = cursor;
            cursor += 1;
            let Some((index, candidate)) = route_at(routes, &sequence, position) else { continue };
            let display = sanitized_route(&candidate.endpoint);
            if !candidate.supports_client_auth(auth) {
                record(
                    &mut failures,
                    position,
                    format!(
                        "{display}: {}",
                        ProviderError::UnsupportedClientAuth {
                            scheme: candidate.endpoint.scheme().into(),
                            auth,
                        }
                    ),
                );
                continue;
            }
            let request = connect_request(candidate, session, lane_policy).map_err(|error| {
                InitialRouteSelectionError::terminal(E::terminal(format!("{error:#}")))
            })?;
            let upgrade_candidate = upgrade && index == 0;
            in_flight.push(dial(attempt, position, index, display, request, upgrade_candidate));
            next_at = race.map(|race| Instant::now() + race.stagger);
        }
        let stagger_due = next_at.filter(|_| cursor < sequence.len() && !in_flight.is_empty());
        let finished = tokio::select! {
            finished = in_flight.next() => Some(finished),
            () = sleep_until_some(stagger_due) => None,
        };
        // The stagger ran out: start the next route beside the ones in flight.
        let Some(finished) = finished else { continue };
        let Some(Finished { position, display, upgrade_candidate, stage, result }) = finished
        else {
            break;
        };
        match result {
            Ok(connected) => return Ok(connected),
            Err(InitialRouteAttemptError::Route { error, retryable: route_retryable }) => {
                if upgrade_candidate {
                    let message = match stage {
                        Stage::Bootstrap => {
                            format!("SSH bootstrap failed for {display}: {}", error.summary())
                        }
                        Stage::Connect => {
                            format!("upgraded SSH route failed for {display}: {}", error.summary())
                        }
                    };
                    return Err(InitialRouteSelectionError::terminal(E::terminal(message)));
                }
                retryable |= route_retryable;
                record(
                    &mut failures,
                    position,
                    match stage {
                        Stage::Bootstrap => {
                            format!("{display}: SSH bootstrap failed: {}", error.summary())
                        }
                        Stage::Connect => format!("{display}: {}", error.summary()),
                    },
                );
                if last.as_ref().is_none_or(|(at, _)| *at < position) {
                    last = Some((position, error));
                }
                // A failed route frees its place in the race: the next one starts at once.
                if race.is_some() {
                    next_at = Some(Instant::now());
                }
            }
            Err(InitialRouteAttemptError::Fatal(error)) => {
                return Err(InitialRouteSelectionError::terminal(error));
            }
        }
    }
    Err(InitialRouteSelectionError {
        error: E::all_failed(failures.into_iter().flatten().collect(), last.map(|(_, e)| e)),
        retryable,
    })
}

/// The route at `position` in a pass's order, with its index in `routes`.
fn route_at<'a>(
    routes: &'a [ResolvedRouteCandidate],
    sequence: &[usize],
    position: usize,
) -> Option<(usize, &'a ResolvedRouteCandidate)> {
    let index = *sequence.get(position)?;
    Some((index, routes.get(index)?))
}

/// Records the failure of the route at `position` in a pass's order.
fn record(failures: &mut [Option<String>], position: usize, failure: String) {
    if let Some(slot) = failures.get_mut(position) {
        *slot = Some(failure);
    }
}

/// Waits until `at`, or forever without one.
async fn sleep_until_some(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

/// The reconnect pass of an established link after its route failed: from `start` round the
/// list, the same race as the first connect's when `race` is set (one route at a time without
/// one). Each route's dial ends at a provider group (transport up, before the Noise handshake);
/// the first group wins and the dials still in flight are dropped, which closes them.
pub(crate) async fn select_reconnect_routes<T: Send>(
    routes: &[ResolvedRouteCandidate],
    start: usize,
    race: Option<RouteRace>,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &(impl ReconnectRouteAttempt<T> + ?Sized),
) -> Result<(usize, T), ProviderError> {
    if routes.is_empty() {
        return Err(ProviderError::Configuration("no reconnect routes configured".into()));
    }
    let sequence: Vec<usize> =
        (0..routes.len()).map(|offset| (start + offset) % routes.len()).collect();
    let mut failures: Vec<Option<String>> = vec![None; sequence.len()];
    let mut cursor = 0;
    let mut in_flight = FuturesUnordered::new();
    let mut next_at: Option<Instant> = None;
    loop {
        while cursor < sequence.len()
            && (in_flight.is_empty() || next_at.is_some_and(|at| Instant::now() >= at))
        {
            let position = cursor;
            cursor += 1;
            let Some((index, candidate)) = route_at(routes, &sequence, position) else { continue };
            if !candidate.supports_client_auth(auth) {
                record(
                    &mut failures,
                    position,
                    format!(
                        "{}: {}",
                        sanitized_route(&candidate.endpoint),
                        ProviderError::UnsupportedClientAuth {
                            scheme: candidate.endpoint.scheme().into(),
                            auth,
                        }
                    ),
                );
                continue;
            }
            let request = connect_request(candidate, session, lane_policy)
                .map_err(|error| ProviderError::Configuration(error.to_string()))?;
            let display = sanitized_route(&request.endpoint);
            in_flight.push(async move {
                (position, index, display, attempt.connect(index, request, auth).await)
            });
            next_at = race.map(|race| Instant::now() + race.stagger);
        }
        let stagger_due = next_at.filter(|_| cursor < sequence.len() && !in_flight.is_empty());
        let finished = tokio::select! {
            finished = in_flight.next() => Some(finished),
            () = sleep_until_some(stagger_due) => None,
        };
        let Some(finished) = finished else { continue };
        let Some((position, index, display, result)) = finished else { break };
        match result {
            Ok(group) => return Ok((index, group)),
            Err(error) => {
                record(&mut failures, position, format!("{display}: {error}"));
                if race.is_some() {
                    next_at = Some(Instant::now());
                }
            }
        }
    }
    Err(ProviderError::Transport(format!(
        "all reconnect route providers failed: {}",
        failures.into_iter().flatten().collect::<Vec<_>>().join("; ")
    )))
}
