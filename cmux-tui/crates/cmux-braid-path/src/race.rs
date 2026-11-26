//! A staggered race over candidate targets: start one attempt, start another every
//! [`RacePolicy::stagger`] while none has connected (rotating through the targets), keep at
//! most [`RacePolicy::max_in_flight`] in flight, give each but the last
//! [`RacePolicy::attempt_timeout`], and return the first that connects. [`race`] drops the
//! losers; [`race_keeping_losers`] hands them back still running ([`Losers`]), so a caller can
//! keep the ones that connect after the winner as warm standbys ([`crate::Standby`], RFD 0164
//! slice B3). A fast failure starts the next attempt at once.
//!
//! The last attempt gets the longer [`RacePolicy::last_attempt_timeout`]: on a saturated uplink
//! where every connect is slower than [`RacePolicy::attempt_timeout`] it still connects slowly.
//! It is still bounded, because a caller with no budget of its own (the direct TCP dialer under
//! the terminal client) would otherwise wait out the operating system's connect timeout, over a
//! minute, on a black-holed address. A caller with a shorter budget (the relay's 10 s connect)
//! ends the race first.

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use tokio::time::{Instant, Sleep};

/// When to start another attempt and how many to keep.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RacePolicy {
    /// How long the newest attempt has alone before the next one starts.
    pub stagger: Duration,
    /// How long one attempt but the last may take before it is dropped.
    pub attempt_timeout: Duration,
    /// How long the last attempt may take, unless the caller's own budget ends the race first.
    pub last_attempt_timeout: Duration,
    /// Attempts in flight at once.
    pub max_in_flight: usize,
    /// Attempts in all; the last one's failure is the answer once they ran out.
    pub max_attempts: usize,
}

impl RacePolicy {
    /// For a host that connects in 10 to 50 ms: a second attempt after 400 ms, at most three
    /// at a time, each but the last given 3 s, six in all. When every one is black-holed the
    /// sixth starts after about 3.8 s and gets 8 s, so a race with no other budget fails after
    /// about 11.8 s; the relay's 10 s connect budget ends sooner.
    pub const INTERNET: Self = Self {
        stagger: Duration::from_millis(400),
        attempt_timeout: Duration::from_secs(3),
        last_attempt_timeout: Duration::from_secs(8),
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
pub async fn race<A, T, F, Fut>(targets: &[A], policy: RacePolicy, connect: F) -> io::Result<Won<T>>
where
    A: Clone,
    F: FnMut(A) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    run(targets, policy, connect).await.map(|(won, _)| won)
}

/// [`race`], with the attempts still in flight when the winner answered handed back as
/// [`Losers`] instead of dropped. Each keeps its policy timeout, including
/// [`RacePolicy::last_attempt_timeout`] for the final attempt.
///
/// # Errors
/// The race's error: the last attempt's.
pub async fn race_keeping_losers<A, T, F, Fut>(
    targets: &[A],
    policy: RacePolicy,
    connect: F,
) -> io::Result<(Won<T>, Losers<A, Fut>)>
where
    A: Clone,
    F: FnMut(A) -> Fut,
    Fut: Future<Output = io::Result<T>>,
{
    let (won, running) = run(targets, policy, connect).await?;
    Ok((won, Losers { targets: targets.to_vec(), running }))
}

/// A loser that connected after the winner.
#[derive(Debug)]
pub struct Lost<A, T> {
    /// The target it dialed.
    pub target: A,
    /// What it returned.
    pub value: T,
}

/// The attempts of a [`race_keeping_losers`] still in flight when the winner answered.
pub struct Losers<A, Fut> {
    targets: Vec<A>,
    running: FuturesUnordered<Attempt<Fut>>,
}

impl<A: Clone, Fut> Losers<A, Fut> {
    /// No loser is still in flight.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.running.is_empty()
    }

    /// The next loser that connects; `None` once every one has connected, failed or run out of
    /// time. Failures are skipped.
    pub async fn next<T>(&mut self) -> Option<Lost<A, T>>
    where
        Fut: Future<Output = io::Result<T>>,
    {
        while let Some((_, target_index, _, result)) = self.running.next().await {
            if let (Ok(value), Some(target)) = (result, self.targets.get(target_index)) {
                return Some(Lost { target: target.clone(), value });
            }
        }
        None
    }
}

/// One attempt: its index, its target's index, its start, the connect and its deadline.
struct Attempt<Fut> {
    index: usize,
    target_index: usize,
    begun: Instant,
    connect: Pin<Box<Fut>>,
    deadline: Option<(Duration, Pin<Box<Sleep>>)>,
}

impl<T, Fut: Future<Output = io::Result<T>>> Future for Attempt<Fut> {
    type Output = (usize, usize, Duration, io::Result<T>);

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        // Every field is Unpin (the futures are boxed).
        let this = self.get_mut();
        let result = match this.connect.as_mut().poll(cx) {
            Poll::Ready(result) => result,
            Poll::Pending => {
                let Some((timeout, sleep)) = &mut this.deadline else { return Poll::Pending };
                if sleep.as_mut().poll(cx).is_pending() {
                    return Poll::Pending;
                }
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!("no answer within {} ms", timeout.as_millis()),
                ))
            }
        };
        Poll::Ready((this.index, this.target_index, this.begun.elapsed(), result))
    }
}

async fn run<A, T, F, Fut>(
    targets: &[A],
    policy: RacePolicy,
    mut connect: F,
) -> io::Result<(Won<T>, FuturesUnordered<Attempt<Fut>>)>
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
            // Give the last attempt its longer bounded timeout; the caller's own
            // budget may still end the race earlier.
            let timeout = if launched + 1 < max_attempts {
                policy.attempt_timeout
            } else {
                policy.last_attempt_timeout
            };
            let deadline = Some((timeout, Box::pin(tokio::time::sleep(timeout))));
            running.push(Attempt {
                index: launched,
                target_index,
                begun: Instant::now(),
                connect: Box::pin(connect(target)),
                deadline,
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
                    let won = Won { value, attempt, target_index, elapsed: started.elapsed(), connect };
                    return Ok((won, running));
                }
                // A failed attempt frees its place: the next starts at once (RFC 8305 section
                // 5), not when the stagger since the last start runs out.
                Err(error) => {
                    last_error = Some(error);
                    next_launch = Instant::now();
                }
            },
            () = tokio::time::sleep_until(next_launch), if may_launch => {}
        }
    }
}

#[cfg(test)]
#[path = "race_tests.rs"]
mod tests;
