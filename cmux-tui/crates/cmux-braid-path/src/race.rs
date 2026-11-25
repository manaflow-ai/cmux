//! A staggered race over candidate targets: start one attempt, start another every
//! [`RacePolicy::stagger`] while none has connected (rotating through the targets), keep at
//! most [`RacePolicy::max_in_flight`] in flight, give each but the last
//! [`RacePolicy::attempt_timeout`], and return the first that connects. The losers are
//! dropped. A fast failure starts the next attempt at once.
//!
//! The last attempt has no timeout of its own: on a saturated uplink where every connect is
//! slower than the timeout it still connects inside the caller's own budget.

use std::future::Future;
use std::io;
use std::time::Duration;

use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use tokio::time::Instant;

/// When to start another attempt and how many to keep.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RacePolicy {
    /// How long the newest attempt has alone before the next one starts.
    pub stagger: Duration,
    /// How long one attempt but the last may take before it is dropped.
    pub attempt_timeout: Duration,
    /// Attempts in flight at once.
    pub max_in_flight: usize,
    /// Attempts in all; the last one's failure is the answer once they ran out.
    pub max_attempts: usize,
}

impl RacePolicy {
    /// For a host that connects in 10 to 50 ms: a second attempt after 400 ms, at most three
    /// at a time, each but the last given 3 s, six in all.
    pub const INTERNET: Self = Self {
        stagger: Duration::from_millis(400),
        attempt_timeout: Duration::from_secs(3),
        max_in_flight: 3,
        max_attempts: 6,
    };

    /// The same policy with its stagger set from a remembered connect time
    /// ([`stagger_after`]), never above this policy's own stagger.
    #[must_use]
    pub fn with_lead(self, lead: Option<Duration>) -> Self {
        Self { stagger: stagger_after(lead, STAGGER_FLOOR, self.stagger), ..self }
    }
}

/// RFC 8305 section 5: a connection attempt delay taken from history should not be under
/// 100 ms.
pub const STAGGER_FLOOR: Duration = Duration::from_millis(100);

/// The stagger for a target that last connected in `lead`: 1.5 times it, between `floor` and
/// `ceiling`; `ceiling` with no history. A path that connects in 30 ms is not waited on for
/// 400 ms before its backup starts.
#[must_use]
pub fn stagger_after(lead: Option<Duration>, floor: Duration, ceiling: Duration) -> Duration {
    let Some(lead) = lead else { return ceiling };
    (lead + lead / 2).clamp(floor, ceiling.max(floor))
}

/// The attempt that won a [`race`].
#[derive(Debug)]
pub struct Won<T> {
    /// What the winning attempt returned.
    pub value: T,
    /// Which attempt won, from 0.
    pub attempt: usize,
    /// Its index in the targets given to [`race`].
    pub target_index: usize,
    /// From the start of the race to the winner's answer.
    pub elapsed: Duration,
    /// From the winner's own start to its answer: the connect time to remember.
    pub connect: Duration,
}

/// Races `connect` over `targets` by `policy` (module docs). Attempt `n` dials
/// `targets[n % targets.len()]`. The error is the last attempt's (one that ran out of time is
/// `TimedOut`).
pub async fn race<A, T, F, Fut>(
    targets: &[A],
    policy: RacePolicy,
    mut connect: F,
) -> io::Result<Won<T>>
where
    A: Clone,
    F: FnMut(A) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    if targets.is_empty() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "no addresses to connect to"));
    }
    let started = Instant::now();
    let max_in_flight = policy.max_in_flight.max(1);
    let max_attempts = policy.max_attempts.max(1);
    let mut running = FuturesUnordered::new();
    let mut launched = 0_usize;
    let mut next_launch = started;
    let mut last_error = None;
    loop {
        let may_launch = launched < max_attempts && running.len() < max_in_flight;
        if may_launch && (running.is_empty() || Instant::now() >= next_launch) {
            let target_index = launched % targets.len();
            // `targets` is not empty (checked above), so `get` always finds the slot.
            let Some(target) = targets.get(target_index).cloned() else {
                return Err(io::Error::new(io::ErrorKind::NotFound, "no addresses to connect to"));
            };
            let attempt = connect(target);
            // The last attempt may connect slowly: only the caller's budget ends it.
            let timeout = (launched + 1 < max_attempts).then_some(policy.attempt_timeout);
            let index = launched;
            running.push(async move {
                let begun = Instant::now();
                let result = match timeout {
                    None => attempt.await,
                    Some(timeout) => match tokio::time::timeout(timeout, attempt).await {
                        Ok(result) => result,
                        Err(_) => Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            format!("no answer within {} ms", timeout.as_millis()),
                        )),
                    },
                };
                (index, target_index, begun.elapsed(), result)
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
            Some((attempt, target_index, connect, result)) = running.next() => match result {
                Ok(value) => {
                    return Ok(Won { value, attempt, target_index, elapsed: started.elapsed(), connect });
                }
                Err(error) => last_error = Some(error),
            },
            () = tokio::time::sleep_until(next_launch), if may_launch => {}
        }
    }
}

#[cfg(test)]
#[path = "race_tests.rs"]
mod tests;
