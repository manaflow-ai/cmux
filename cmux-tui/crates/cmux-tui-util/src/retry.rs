//! Retrying a transient failure for the person, so no message tells them to
//! "try again" when the only sensible answer is yes.
//!
//! Leo, 2026-11-22: "vacuous decisions like that should be just done and the
//! underlying problems should be done better at the root". A refusal that a
//! later try can pass (the daemon is still starting, a lock is held for a
//! moment, a peer is reconnecting, a value changed while it was read) is
//! retried here with [`RetryBudget`]'s full-jitter exponential backoff inside
//! one bounded deadline, so a command still ends. Each try answers
//! [`Attempt::Retry`] (a later try can pass) or [`Attempt::Fail`] (it cannot,
//! or it has a side effect the person must choose to repeat); the last
//! `Retry` error is returned when the deadline is spent, and its text should
//! name the cause and what the person can do, not "try again".
//!
//! A long wait on a terminal says so once ([`Patience`]): after
//! `notice_after` a single "waiting for X..." line goes to stderr when stderr
//! is a TTY, and nothing otherwise (scripts and the daemon stay quiet).

use std::io::IsTerminal;
use std::time::{Duration, Instant};

use crate::backoff::RetryBudget;

/// The first wait after a transient failure, at most.
pub const FIRST_WAIT: Duration = Duration::from_millis(100);
/// The longest single wait between two tries.
pub const MAX_WAIT: Duration = Duration::from_secs(2);
/// How long a wait runs before a TTY is told about it.
pub const NOTICE_AFTER: Duration = Duration::from_secs(3);

/// One try's outcome when it did not succeed.
#[derive(Debug)]
pub enum Attempt<E> {
    /// A later try can pass: wait and try again, inside the deadline.
    Retry(E),
    /// A later try would wait for the server's estimate first (rate limits
    /// that are short enough to sit out inside the deadline).
    RetryAfter(E, Duration),
    /// No later try can pass, or a repeat has a cost: stop now.
    Fail(E),
}

impl<E> Attempt<E> {
    pub fn into_error(self) -> E {
        match self {
            Self::Retry(error) | Self::RetryAfter(error, _) | Self::Fail(error) => error,
        }
    }
}

/// The wait state of one retried operation: the backoff, the deadline, and
/// whether the person was told it is waiting.
#[derive(Debug)]
pub struct Patience {
    budget: RetryBudget,
    started: Instant,
    what: String,
    notice_after: Duration,
    notice: Notice,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Notice {
    /// Not printed yet; printed to stderr if it is a TTY.
    Pending,
    /// Printed, or never printed (no TTY, or the caller turned it off).
    Done,
}

impl Patience {
    /// Tries of `what` (a short noun phrase: "the cmux daemon to start") that
    /// end `total` from now.
    pub fn new(what: impl Into<String>, total: Duration) -> Self {
        let started = Instant::now();
        Self {
            budget: RetryBudget::until(FIRST_WAIT, MAX_WAIT, started + total),
            started,
            what: what.into(),
            notice_after: NOTICE_AFTER,
            notice: if std::io::stderr().is_terminal() { Notice::Pending } else { Notice::Done },
        }
    }

    /// No "waiting for" line at all: the daemon, an MCP tool reply, a GUI
    /// request, where stderr is not the person's.
    pub fn quiet(mut self) -> Self {
        self.notice = Notice::Done;
        self
    }

    /// Spacing other than [`FIRST_WAIT`]..[`MAX_WAIT`] (same deadline).
    pub fn spaced(mut self, first: Duration, max: Duration) -> Self {
        let deadline = self.budget.deadline().unwrap_or_else(Instant::now);
        self.budget = RetryBudget::until(first, max, deadline);
        self
    }

    /// Time spent since the first try.
    pub fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }

    /// The wait before the next try, or `None` when it would end past the
    /// deadline. Prints the one "waiting for" line when it is due.
    pub fn next_wait(&mut self, retry_after: Option<Duration>) -> Option<Duration> {
        let wait = self.budget.next_wait(retry_after)?;
        if self.notice == Notice::Pending && self.elapsed() + wait >= self.notice_after {
            self.notice = Notice::Done;
            eprintln!("waiting for {}\u{2026}", self.what);
        }
        Some(wait)
    }

    /// Sleeps the next wait on this thread; false (no sleep) past the deadline.
    pub fn sleep(&mut self, retry_after: Option<Duration>) -> bool {
        match self.next_wait(retry_after) {
            Some(wait) => {
                std::thread::sleep(wait);
                true
            }
            None => false,
        }
    }

    /// Runs `attempt` until it succeeds, fails for good, or the deadline is
    /// spent (then the last transient error is returned).
    pub fn run<T, E>(mut self, mut attempt: impl FnMut() -> Result<T, Attempt<E>>) -> Result<T, E> {
        loop {
            let (error, retry_after) = match attempt() {
                Ok(value) => return Ok(value),
                Err(Attempt::Fail(error)) => return Err(error),
                Err(Attempt::Retry(error)) => (error, None),
                Err(Attempt::RetryAfter(error, after)) => (error, Some(after)),
            };
            if !self.sleep(retry_after) {
                return Err(error);
            }
        }
    }

    /// Runs async tries under one deadline, including time spent awaiting a reply.
    /// On expiry, drops the pending future and returns the last transient error,
    /// or `on_timeout()` if no try has answered. Expiry never replays the attempt.
    #[cfg(feature = "tokio")]
    pub async fn run_async<T, E, F, Fut>(
        mut self,
        on_timeout: impl FnOnce() -> E,
        mut attempt: F,
    ) -> Result<T, E>
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = Result<T, Attempt<E>>>,
    {
        let remaining = self
            .budget
            .deadline()
            .unwrap_or(self.started)
            .saturating_duration_since(Instant::now());
        let deadline = tokio::time::Instant::now() + remaining;
        let mut last_error = None;
        loop {
            // timeout_at polls the future first, even if the deadline has already passed.
            // A late wake from backoff must not start another request.
            if tokio::time::Instant::now() >= deadline {
                return Err(last_error.unwrap_or_else(on_timeout));
            }
            let Ok(outcome) = tokio::time::timeout_at(deadline, attempt()).await else {
                return Err(last_error.unwrap_or_else(on_timeout));
            };
            let (error, retry_after) = match outcome {
                Ok(value) => return Ok(value),
                Err(Attempt::Fail(error)) => return Err(error),
                Err(Attempt::Retry(error)) => (error, None),
                Err(Attempt::RetryAfter(error, after)) => (error, Some(after)),
            };
            let Some(wait) = self.next_wait(retry_after) else {
                return Err(error);
            };
            let retry_at = tokio::time::Instant::now() + wait;
            if retry_at >= deadline {
                return Err(error);
            }
            last_error = Some(error);
            tokio::time::sleep_until(retry_at).await;
        }
    }
}

/// Runs `attempt` with retries of transient failures for at most `total`.
pub fn retry<T, E>(
    what: impl Into<String>,
    total: Duration,
    attempt: impl FnMut() -> Result<T, Attempt<E>>,
) -> Result<T, E> {
    Patience::new(what, total).run(attempt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn a_transient_failure_is_retried_until_it_passes() {
        let tries = Cell::new(0);
        let out: Result<u32, &str> = Patience::new("a test", Duration::from_secs(5))
            .quiet()
            .spaced(Duration::from_millis(1), Duration::from_millis(2))
            .run(|| {
                tries.set(tries.get() + 1);
                if tries.get() < 4 { Err(Attempt::Retry("busy")) } else { Ok(7) }
            });
        assert_eq!(out, Ok(7));
        assert_eq!(tries.get(), 4);
    }

    #[test]
    fn a_lasting_failure_stops_at_once() {
        let tries = Cell::new(0);
        let out: Result<(), &str> =
            Patience::new("a test", Duration::from_secs(5)).quiet().run(|| {
                tries.set(tries.get() + 1);
                Err(Attempt::Fail("refused"))
            });
        assert_eq!(out, Err("refused"));
        assert_eq!(tries.get(), 1);
    }

    #[test]
    fn the_deadline_ends_the_tries_with_the_last_transient_error() {
        let started = Instant::now();
        let tries = Cell::new(0);
        let out: Result<(), String> = Patience::new("a test", Duration::from_millis(150))
            .quiet()
            .spaced(Duration::from_millis(5), Duration::from_millis(20))
            .run(|| {
                tries.set(tries.get() + 1);
                Err(Attempt::Retry(format!("busy {}", tries.get())))
            });
        assert_eq!(out, Err(format!("busy {}", tries.get())));
        assert!(tries.get() > 2, "only {} tries", tries.get());
        assert!(started.elapsed() < Duration::from_millis(400));
    }

    #[test]
    fn a_retry_after_longer_than_the_deadline_is_not_slept() {
        let started = Instant::now();
        let out: Result<(), &str> = Patience::new("a test", Duration::from_millis(100))
            .quiet()
            .run(|| Err(Attempt::RetryAfter("rate limited", Duration::from_secs(60))));
        assert_eq!(out, Err("rate limited"));
        assert!(started.elapsed() < Duration::from_millis(50));
    }

    #[test]
    fn the_notice_is_printed_at_most_once() {
        let mut patience = Patience::new("a test", Duration::from_secs(60))
            .spaced(Duration::from_millis(1), Duration::from_millis(1));
        patience.notice = Notice::Pending;
        patience.notice_after = Duration::ZERO;
        assert!(patience.next_wait(None).is_some());
        assert_eq!(patience.notice, Notice::Done);
        assert!(patience.next_wait(None).is_some());
        assert_eq!(patience.notice, Notice::Done);
    }

    #[cfg(feature = "tokio")]
    #[tokio::test]
    async fn async_tries_retry_the_same_way() {
        let tries = std::sync::atomic::AtomicU32::new(0);
        let out: Result<u32, &str> = Patience::new("a test", Duration::from_secs(5))
            .quiet()
            .spaced(Duration::from_millis(1), Duration::from_millis(2))
            .run_async(
                || "timed out",
                || {
                    let n = tries.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                    async move { if n < 3 { Err(Attempt::Retry("busy")) } else { Ok(n) } }
                },
            )
            .await;
        assert_eq!(out, Ok(3));
    }

    #[cfg(feature = "tokio")]
    #[tokio::test(start_paused = true)]
    async fn async_deadline_ends_a_pending_attempt_without_replaying_it() {
        for answered in [false, true] {
            let tries = Cell::new(0);
            let operation = Patience::new("the reply", Duration::from_secs(10))
                .quiet()
                .spaced(Duration::ZERO, Duration::ZERO)
                .run_async(
                    || "no reply",
                    || {
                        let first = tries.get() == 0;
                        tries.set(tries.get() + 1);
                        async move {
                            if first && answered {
                                Err(Attempt::Retry("partial reply"))
                            } else {
                                std::future::pending::<Result<(), _>>().await
                            }
                        }
                    },
                );
            let out = tokio::time::timeout(Duration::from_secs(11), operation)
                .await
                .expect("even a pending attempt must finish within the budget");
            assert_eq!(out, Err(if answered { "partial reply" } else { "no reply" }));
            assert_eq!(tries.get(), if answered { 2 } else { 1 });
        }
    }
}
