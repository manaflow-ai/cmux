//! A hedged connect: a new socket when the first one's SYN goes nowhere.
//!
//! Some network paths black-hole one connection's 5-tuple: its SYN and every
//! retransmit of it are dropped, while a new socket (a new source port) to the
//! same address connects in milliseconds. The operating system retransmits on
//! the same socket for over a minute, and a resolver's addresses tried one
//! after the other wait that long on each. Measured on 2026-11-17: 1 in 8 to 1
//! in 2 new connections to the Cloud API and relay hosts, which turned a 3 s
//! carrier link into 36 to 83 s.
//!
//! [`connect`] starts one attempt, starts another every [`HedgePolicy::stagger`]
//! while none has connected (rotating through the addresses), keeps at most
//! [`HedgePolicy::max_in_flight`] in flight, gives each one
//! [`HedgePolicy::attempt_timeout`], and returns the first that connects. The
//! others are dropped, which closes their sockets. Only the connect is hedged:
//! nothing has been written on any of them yet.
//!
//! The last attempt has no timeout of its own: on a saturated uplink where every
//! connect takes longer than [`HedgePolicy::attempt_timeout`], it still connects
//! slowly inside the caller's own budget (the relay's 10 s connect) instead of
//! failing where a plain connect used to succeed.

use std::future::Future;
use std::io;
use std::time::Duration;

use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use tokio::time::Instant;

/// When to start another socket and how many to keep.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HedgePolicy {
    /// How long the newest attempt has alone before the next one starts.
    pub stagger: Duration,
    /// How long one attempt but the last may take to connect before it is
    /// dropped. The last runs until it answers or the caller's budget ends.
    pub attempt_timeout: Duration,
    /// Attempts in flight at once.
    pub max_in_flight: usize,
    /// Attempts in all; the last one's failure is the answer once they ran out.
    pub max_attempts: usize,
}

impl HedgePolicy {
    /// For a host that connects in 10 to 50 ms: a second socket after 400 ms,
    /// at most three at a time, each but the last given 3 s, six in all (the
    /// sixth starts after about 4 s when every one is black-holed, and has the
    /// rest of the relay's 10 s connect budget).
    pub const INTERNET: Self = Self {
        stagger: Duration::from_millis(400),
        attempt_timeout: Duration::from_secs(3),
        max_in_flight: 3,
        max_attempts: 6,
    };
}

/// Connects to one of `targets` through `connect`, hedged by `policy`
/// (module docs). Attempt `n` dials `targets[n % targets.len()]`. The error
/// is the last attempt's (an attempt that ran out of time is `TimedOut`). The
/// final attempt is not timed out here: the caller bounds the whole connect.
pub async fn connect<A, T, F, Fut>(
    targets: &[A],
    policy: HedgePolicy,
    mut connect: F,
) -> io::Result<T>
where
    A: Clone,
    F: FnMut(A) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    if targets.is_empty() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "no addresses to connect to"));
    }
    let max_in_flight = policy.max_in_flight.max(1);
    let max_attempts = policy.max_attempts.max(1);
    let mut running = FuturesUnordered::new();
    let mut launched = 0_usize;
    let mut next_launch = Instant::now();
    let mut last_error = None;
    loop {
        let may_launch = launched < max_attempts && running.len() < max_in_flight;
        if may_launch && (running.is_empty() || Instant::now() >= next_launch) {
            // `targets` is not empty (checked above), so `get` always finds the slot.
            let Some(target) = targets.get(launched % targets.len()).cloned() else {
                return Err(io::Error::new(io::ErrorKind::NotFound, "no addresses to connect to"));
            };
            let attempt = connect(target);
            // The last attempt may connect slowly: only the caller's budget ends it.
            let timeout = (launched + 1 < max_attempts).then_some(policy.attempt_timeout);
            running.push(async move {
                let Some(timeout) = timeout else { return attempt.await };
                match tokio::time::timeout(timeout, attempt).await {
                    Ok(result) => result,
                    Err(_) => Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        format!("no answer within {} ms", timeout.as_millis()),
                    )),
                }
            });
            launched += 1;
            next_launch = Instant::now() + policy.stagger;
            continue;
        }
        if running.is_empty() {
            return Err(last_error.unwrap_or_else(|| {
                io::Error::new(io::ErrorKind::TimedOut, "no connect attempt answered")
            }));
        }
        tokio::select! {
            biased;
            Some(result) = running.next() => match result {
                Ok(connected) => return Ok(connected),
                Err(error) => last_error = Some(error),
            },
            () = tokio::time::sleep_until(next_launch), if may_launch => {}
        }
    }
}

#[cfg(test)]
#[path = "hedge_tests.rs"]
mod tests;
