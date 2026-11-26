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
//!
//! Both passes run on Braid's one racer, `cmux_braid_path::race` (RFD 0164 slice B1): the
//! same code cmux-remote's hedged connect and the phone's signaling dial use. The pass's own
//! loop is kept for one release behind `CMUX_ROUTE_RACE_BRAID=0` (the A/B).

use std::io;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use cmux_braid_path::{RacePolicy, Won};
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
    if braid_enabled() {
        select_routes_braid(routes, order, session, lane_policy, auth, upgrade, attempt).await
    } else {
        select_routes_own(routes, order, session, lane_policy, auth, upgrade, attempt).await
    }
}

/// `CMUX_ROUTE_RACE_BRAID=0` runs the passes on their own loops again (one release, the A/B
/// for the adoption). Tests flip it per thread with [`own_loops_for_test`].
fn braid_enabled() -> bool {
    #[cfg(test)]
    if OWN_LOOPS.with(std::cell::Cell::get) {
        return false;
    }
    std::env::var_os("CMUX_ROUTE_RACE_BRAID").is_none_or(|value| value != "0")
}

#[cfg(test)]
thread_local! {
    static OWN_LOOPS: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Runs this thread's passes on their own loops (`true`) or on Braid's racer (`false`).
#[cfg(test)]
pub(crate) fn own_loops_for_test(own: bool) {
    OWN_LOOPS.with(|cell| cell.set(own));
}

/// Longer than any dial: an attempt the race never times out or a stagger that never runs out
/// (a serial pass keeps one route in flight, so its stagger is never read).
const NEVER: Duration = Duration::from_secs(365 * 24 * 60 * 60);

/// The race policy for a pass over `routes` routes: each route once; raced, all may be in
/// flight with `race`'s stagger; serial, one at a time. No attempt timeout: each route's own
/// attempt budget ends it, as in the pass's own loop.
fn braid_policy(race: Option<RouteRace>, routes: usize) -> RacePolicy {
    RacePolicy {
        stagger: race.map_or(NEVER, |race| race.stagger),
        attempt_timeout: NEVER,
        max_in_flight: if race.is_some() { routes } else { 1 },
        max_attempts: routes,
    }
}

/// What ends a race: a connect, or a failure that ends the whole pass. A route failure that
/// lets the pass go on is the race's `Err` (the next route starts at once); its text is kept in
/// a [`Tally`].
enum Decisive<T, E> {
    Connected(T),
    Terminal(E),
}

/// The failures of a pass's routes as they answer, for the error when every one failed.
struct Tally<E> {
    failures: Vec<Option<String>>,
    last: Option<(usize, E)>,
    retryable: bool,
}

impl<E> Tally<E> {
    fn new(routes: usize) -> Mutex<Self> {
        Mutex::new(Self { failures: vec![None; routes], last: None, retryable: false })
    }
}

/// Records one route's failure in `tally` and hands the race its `Err`.
fn tallied<E>(tally: &Mutex<Tally<E>>, position: usize, failure: String) -> io::Error {
    let mut tally = tally.lock().unwrap_or_else(PoisonError::into_inner);
    record(&mut tally.failures, position, failure);
    io::Error::other("route failed")
}

/// The order of a pass's dials: `first`, then the rest by index.
fn pass_sequence(routes: usize, first: Option<usize>) -> Vec<usize> {
    first.into_iter().chain((0..routes).filter(|&index| Some(index) != first)).collect()
}

/// [`select_routes`] on Braid's racer.
async fn select_routes_braid<T: Send, E: RouteFailure>(
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
    let sequence = pass_sequence(routes.len(), first);
    let positions: Vec<usize> = (0..sequence.len()).collect();
    let tally = Tally::new(sequence.len());
    let tally = &tally;
    let sequence = &sequence;
    let outcome = cmux_braid_path::race(
        &positions,
        braid_policy(race, positions.len()),
        |position| async move {
            let Some((index, candidate)) = route_at(routes, sequence, position) else {
                return Err(io::Error::other("no route at this place"));
            };
            let display = sanitized_route(&candidate.endpoint);
            if !candidate.supports_client_auth(auth) {
                let error = ProviderError::UnsupportedClientAuth {
                    scheme: candidate.endpoint.scheme().into(),
                    auth,
                };
                return Err(tallied(tally, position, format!("{display}: {error}")));
            }
            let request = match connect_request(candidate, session, lane_policy) {
                Ok(request) => request,
                Err(error) => return Ok(Decisive::Terminal(E::terminal(format!("{error:#}")))),
            };
            let upgrade_candidate = upgrade && index == 0;
            let Finished { stage, result, .. } =
                dial(attempt, position, index, display.clone(), request, upgrade_candidate).await;
            match result {
                Ok(connected) => Ok(Decisive::Connected(connected)),
                Err(InitialRouteAttemptError::Route { error, retryable }) => {
                    let summary = error.summary();
                    if upgrade_candidate {
                        return Ok(Decisive::Terminal(E::terminal(upgrade_failure(
                            stage, &display, &summary,
                        ))));
                    }
                    let failure = route_failure(stage, &display, &summary);
                    {
                        let mut tally = tally.lock().unwrap_or_else(PoisonError::into_inner);
                        tally.retryable |= retryable;
                        if tally.last.as_ref().is_none_or(|(at, _)| *at < position) {
                            tally.last = Some((position, error));
                        }
                    }
                    Err(tallied(tally, position, failure))
                }
                Err(InitialRouteAttemptError::Fatal(error)) => Ok(Decisive::Terminal(error)),
            }
        },
    )
    .await;
    match outcome {
        Ok(Won { value: Decisive::Connected(connected), .. }) => Ok(connected),
        Ok(Won { value: Decisive::Terminal(error), .. }) => {
            Err(InitialRouteSelectionError::terminal(error))
        }
        Err(_) => {
            let Tally { failures, last, retryable } = std::mem::replace(
                &mut *tally.lock().unwrap_or_else(PoisonError::into_inner),
                Tally { failures: Vec::new(), last: None, retryable: false },
            );
            Err(InitialRouteSelectionError {
                error: E::all_failed(
                    failures.into_iter().flatten().collect(),
                    last.map(|(_, e)| e),
                ),
                retryable,
            })
        }
    }
}

/// A failed route's entry in a pass's error.
fn route_failure(stage: Stage, display: &str, summary: &str) -> String {
    match stage {
        Stage::Bootstrap => format!("{display}: SSH bootstrap failed: {summary}"),
        Stage::Connect => format!("{display}: {summary}"),
    }
}

/// The error that ends an `--upgrade` pass whose SSH route failed.
fn upgrade_failure(stage: Stage, display: &str, summary: &str) -> String {
    match stage {
        Stage::Bootstrap => format!("SSH bootstrap failed for {display}: {summary}"),
        Stage::Connect => format!("upgraded SSH route failed for {display}: {summary}"),
    }
}

/// [`select_routes`] on the pass's own loop (`CMUX_ROUTE_RACE_BRAID=0`).
async fn select_routes_own<T: Send, E: RouteFailure>(
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
    let sequence = pass_sequence(routes.len(), first);
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
                    return Err(InitialRouteSelectionError::terminal(E::terminal(
                        upgrade_failure(stage, &display, &error.summary()),
                    )));
                }
                retryable |= route_retryable;
                record(&mut failures, position, route_failure(stage, &display, &error.summary()));
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
#[cfg(test)]
pub(crate) async fn select_reconnect_routes<T: Send>(
    routes: &[ResolvedRouteCandidate],
    start: usize,
    race: Option<RouteRace>,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &(impl ReconnectRouteAttempt<T> + ?Sized),
) -> Result<(usize, T), ProviderError> {
    select_reconnect_routes_skipping(routes, start, None, race, session, lane_policy, auth, attempt)
        .await
}

/// [`select_reconnect_routes`] without the route `skip` (one that just failed), unless it is
/// the only route.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn select_reconnect_routes_skipping<T: Send>(
    routes: &[ResolvedRouteCandidate],
    start: usize,
    skip: Option<usize>,
    race: Option<RouteRace>,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &(impl ReconnectRouteAttempt<T> + ?Sized),
) -> Result<(usize, T), ProviderError> {
    if routes.is_empty() {
        return Err(ProviderError::Configuration("no reconnect routes configured".into()));
    }
    let sequence = reconnect_sequence(routes.len(), start, skip);
    if braid_enabled() {
        reconnect_braid(routes, &sequence, race, session, lane_policy, auth, attempt).await
    } else {
        reconnect_own(routes, &sequence, race, session, lane_policy, auth, attempt).await
    }
}

/// A reconnect pass's order: from `start` round the list, without `skip` unless it is the
/// only route.
fn reconnect_sequence(routes: usize, start: usize, skip: Option<usize>) -> Vec<usize> {
    let skip = skip.filter(|_| routes > 1);
    (0..routes)
        .map(|offset| (start + offset) % routes)
        .filter(|&index| Some(index) != skip)
        .collect()
}

/// The error of a reconnect pass whose every route failed.
fn reconnect_failed(failures: Vec<Option<String>>) -> ProviderError {
    ProviderError::Transport(format!(
        "all reconnect route providers failed: {}",
        failures.into_iter().flatten().collect::<Vec<_>>().join("; ")
    ))
}

/// [`select_reconnect_routes_skipping`] on Braid's racer.
async fn reconnect_braid<T: Send>(
    routes: &[ResolvedRouteCandidate],
    sequence: &[usize],
    race: Option<RouteRace>,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &(impl ReconnectRouteAttempt<T> + ?Sized),
) -> Result<(usize, T), ProviderError> {
    let positions: Vec<usize> = (0..sequence.len()).collect();
    let tally = Tally::<()>::new(sequence.len());
    let tally = &tally;
    let outcome = cmux_braid_path::race(
        &positions,
        braid_policy(race, positions.len()),
        |position| async move {
            let Some((index, candidate)) = route_at(routes, sequence, position) else {
                return Err(io::Error::other("no route at this place"));
            };
            if !candidate.supports_client_auth(auth) {
                let error = ProviderError::UnsupportedClientAuth {
                    scheme: candidate.endpoint.scheme().into(),
                    auth,
                };
                let display = sanitized_route(&candidate.endpoint);
                return Err(tallied(tally, position, format!("{display}: {error}")));
            }
            let request = match connect_request(candidate, session, lane_policy) {
                Ok(request) => request,
                Err(error) => {
                    return Ok(Decisive::Terminal(ProviderError::Configuration(error.to_string())));
                }
            };
            let display = sanitized_route(&request.endpoint);
            match attempt.connect(index, request, auth).await {
                Ok(group) => Ok(Decisive::Connected((index, group))),
                Err(error) => Err(tallied(tally, position, format!("{display}: {error}"))),
            }
        },
    )
    .await;
    match outcome {
        Ok(Won { value: Decisive::Connected(won), .. }) => Ok(won),
        Ok(Won { value: Decisive::Terminal(error), .. }) => Err(error),
        Err(_) => Err(reconnect_failed(std::mem::take(
            &mut tally.lock().unwrap_or_else(PoisonError::into_inner).failures,
        ))),
    }
}

/// [`select_reconnect_routes_skipping`] on the pass's own loop (`CMUX_ROUTE_RACE_BRAID=0`).
async fn reconnect_own<T: Send>(
    routes: &[ResolvedRouteCandidate],
    sequence: &[usize],
    race: Option<RouteRace>,
    session: SessionId,
    lane_policy: LanePolicy,
    auth: AuthKind,
    attempt: &(impl ReconnectRouteAttempt<T> + ?Sized),
) -> Result<(usize, T), ProviderError> {
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
            let Some((index, candidate)) = route_at(routes, sequence, position) else { continue };
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
    Err(reconnect_failed(failures))
}
