//! Placed relays: relays we run on our own VMs, near the machines that use them (RFD 0060 Weft
//! move 4, slice 2; the platform side is cmux-platform's `MESH_PLACED_RELAYS`).
//!
//! The platform's answer may carry `placed`: one `{relay, ticket, expires_at}` per placed relay,
//! for the answer's own slot and permission, each ticket signed with that relay's own key (never
//! the Cloud carrier's, so a placed VM cannot mint a ticket for any other relay). The carrier:
//! - measures each placed relay's round trip (one TCP connect, at most [`PROBE_WAIT`], kept
//!   [`MEASURED_FOR`]), and ranks them, unreachable ones out ([`rank`]);
//! - registers its own slot on the nearest one, beside its registration on the platform's
//!   `relay` (which stays, the fallback and all an older dialer knows);
//! - dials the nearest placed relay first, with that relay's own ticket ([`ticket_on`]), then the
//!   platform's relays in re-homing's order (`Homes`: the one that last carried the machine
//!   first). The nearest relay stays first on every dial: a host not registered there answers
//!   `slot-offline` at once, so a miss costs one round trip to the nearest relay.
//!
//! A dial never waits on a measurement: until one is in, it goes the platform's way and the
//! measurement runs behind it. An answer with no `placed` (every answer while the secret is unset,
//! and every older platform's) changes nothing: no probe runs and every list is what it was.

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::Deserialize;
use tokio::time::Instant;

use super::CarrierAnswer;

/// The longest one round-trip probe waits; a relay that does not answer within it is unreachable.
pub(crate) const PROBE_WAIT: Duration = Duration::from_secs(1);
/// How long one measurement stands before the relay is measured again.
pub(crate) const MEASURED_FOR: Duration = Duration::from_secs(600);

/// One placed relay's ticket for the answer's slot and permission.
#[derive(Clone, Deserialize)]
pub struct PlacedTicket {
    /// `relay+wss://host[:port]` or `relay+https://host[:port]`.
    pub relay: String,
    pub ticket: String,
    #[serde(default)]
    pub expires_at: u64,
}

impl std::fmt::Debug for PlacedTicket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PlacedTicket")
            .field("relay", &cmux_remote::provider::sanitized_route_text(&self.relay))
            .finish_non_exhaustive()
    }
}

/// The ticket that authenticates on `relay`: the placed relay's own when the answer names it in
/// `placed`, else the answer's own (the platform's relays share it).
pub(crate) fn ticket_on(answer: &CarrierAnswer, relay: &str) -> String {
    answer
        .placed
        .iter()
        .find(|p| p.relay == relay)
        .map_or_else(|| answer.ticket.clone(), |p| p.ticket.clone())
}

/// The reachable relays in `measured`, nearest first; equal round trips keep their order.
pub(crate) fn rank(measured: Vec<(String, Option<Duration>)>) -> Vec<String> {
    let mut reachable: Vec<(String, Duration)> =
        measured.into_iter().filter_map(|(relay, rtt)| Some((relay, rtt?))).collect();
    reachable.sort_by_key(|(_, rtt)| *rtt);
    reachable.into_iter().map(|(relay, _)| relay).collect()
}

/// `relay`'s host and port: the scheme's port when it names none.
fn address(relay: &str) -> Option<(String, u16)> {
    let url = url::Url::parse(relay).ok()?;
    let default = match url.scheme() {
        "relay+wss" | "relay+https" => 443,
        "relay+ws" => 80,
        _ => return None,
    };
    Some((url.host_str()?.to_owned(), url.port().unwrap_or(default)))
}

/// One round trip to `relay`: a TCP connect, timed. None: no answer within `wait`, or a relay
/// this carrier would not dial.
pub(crate) async fn probe(relay: &str, wait: Duration) -> Option<Duration> {
    let (host, port) = address(relay)?;
    let started = Instant::now();
    match tokio::time::timeout(wait, tokio::net::TcpStream::connect((host.as_str(), port))).await {
        Ok(Ok(_stream)) => Some(started.elapsed()),
        _ => None,
    }
}

fn scope() -> &'static cmux_scope::Scope {
    static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("hub carrier placed relays"))
}

/// Each placed relay's last round trip, and which one is nearest.
#[derive(Default)]
pub(crate) struct Nearest {
    measured: Mutex<HashMap<String, (Instant, Option<Duration>)>>,
    measuring: AtomicBool,
}

impl Nearest {
    /// The relays in `placed` with no measurement standing.
    fn stale(&self, placed: &[PlacedTicket]) -> Vec<String> {
        let measured = self.measured.lock().unwrap_or_else(|e| e.into_inner());
        let mut out: Vec<String> = Vec::new();
        for p in placed {
            let fresh = measured.get(&p.relay).is_some_and(|(at, _)| at.elapsed() < MEASURED_FOR);
            if !fresh && !out.contains(&p.relay) {
                out.push(p.relay.clone());
            }
        }
        out
    }

    /// The nearest reachable relay in `placed` by the measurements in hand.
    fn best(&self, placed: &[PlacedTicket]) -> Option<String> {
        let measured = self.measured.lock().unwrap_or_else(|e| e.into_inner());
        rank(
            placed
                .iter()
                .map(|p| (p.relay.clone(), measured.get(&p.relay).and_then(|(_, rtt)| *rtt)))
                .collect(),
        )
        .into_iter()
        .next()
    }

    /// Keeps `rtt` as `relay`'s round trip now (a probe's, or a test's).
    pub(crate) fn record(&self, relay: &str, rtt: Option<Duration>) {
        self.measured
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(relay.to_owned(), (Instant::now(), rtt));
    }

    async fn measure(&self, relays: Vec<String>) {
        let rtts = futures::future::join_all(relays.iter().map(|r| probe(r, PROBE_WAIT))).await;
        for (relay, rtt) in relays.iter().zip(rtts) {
            self.record(relay, rtt);
        }
    }

    /// The nearest placed relay, measuring the ones with no standing measurement first (at most
    /// [`PROBE_WAIT`]). For the registration, which is off the dial path.
    pub(crate) async fn nearest(&self, placed: &[PlacedTicket]) -> Option<String> {
        let stale = self.stale(placed);
        if !stale.is_empty() {
            self.measure(stale).await;
        }
        self.best(placed)
    }

    /// The nearest placed relay by what is measured now; never waits. Relays with no standing
    /// measurement are measured behind it, once at a time, for the next dial.
    pub(crate) fn now(self: &std::sync::Arc<Self>, placed: &[PlacedTicket]) -> Option<String> {
        let stale = self.stale(placed);
        if !stale.is_empty() && !self.measuring.swap(true, Ordering::SeqCst) {
            let me = self.clone();
            scope().spawn_named("hub carrier placed relay probe", async move {
                me.measure(stale).await;
                me.measuring.store(false, Ordering::SeqCst);
            });
        }
        self.best(placed)
    }
}

/// The relays a dial tries, in order: the nearest placed relay, then the platform's.
pub(crate) fn dial_order(nearest: Option<String>, platform: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(platform.len() + 1);
    out.extend(nearest);
    for relay in platform {
        if !out.contains(&relay) {
            out.push(relay);
        }
    }
    out
}

#[cfg(test)]
#[path = "hub_carrier_placed_tests.rs"]
mod tests;
