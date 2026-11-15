//! A link before its first connect (`remote connect`), run like a recovery: the first dial
//! spends from the same redial budget, dials in the same bursts, parks between them, dials at
//! once on a network change or a caller's wait, and publishes its state from the start, so an
//! owner waits on the link instead of restarting it.
//!
//! A [`LinkCell`] is the link's identity across the two phases. Before the first connect it holds
//! the first dial's state; once a [`ClientConnection`] exists it points at it, and the
//! connection's own state machine (`connection.rs`) takes over. The link's own socket serves the
//! cell (`admin/link.rs`), so `link-state` and `await-ready` answer before the first connect too.
//!
//! A permanent failure (a refused identity, a changed daemon key, a bad configuration) ends the
//! first dial: the cell says `failed` with the reason and the caller exits, as before.

use std::fmt;
use std::future::Future;
use std::sync::{Arc, Weak};

use tokio::sync::watch;

use crate::connection::{ClientConnection, ReconnectPolicy, TokenBucket};

/// The reason a dial abandoned because the network changed reports.
const NETWORK_CHANGED: &str = "network changed during the dial";

/// Where a link is.
#[derive(Debug, Clone)]
pub enum LinkPhase {
    /// A first dial is in flight. `reason` is why the previous one failed.
    Connecting { reason: Option<String> },
    /// The first dial is parked between bursts (or waits for a budget token) until a network
    /// change, a caller's wait or the policy's longest delay.
    Disconnected { reason: Option<String> },
    /// The first dial ended for good: a permanent error, or the attempts an explicit
    /// `--reconnect-attempts` allows ran out.
    Failed { reason: String },
    /// Connected once: the connection's own state applies from here on.
    Connected(Weak<ClientConnection>),
    /// The link's owner closed it.
    Closed,
}

/// How one first-dial attempt ended.
pub enum DialOutcome<T, E> {
    Ready(T),
    /// The route is unavailable now (nothing listens, the network is down, a dial timed out).
    Retry(E),
    /// A permanent error: nothing redials.
    Fatal(E),
}

/// Why the first dial stopped without an attempt's own error. The caller's error type converts
/// from it ([`LinkCell::dial`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DialStop {
    /// A network change abandoned the attempt in flight.
    NetworkChanged,
    /// `ReconnectPolicy::maximum_duration` passed after `attempts` attempts.
    DeadlineExceeded { attempts: u32 },
}

impl fmt::Display for DialStop {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NetworkChanged => formatter.write_str(NETWORK_CHANGED),
            Self::DeadlineExceeded { attempts } => write!(
                formatter,
                "the first connect did not succeed within its maximum duration ({attempts} attempts)"
            ),
        }
    }
}

/// Why [`LinkCell::wait_connected`] did not return a connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotConnected {
    /// The deadline passed first; the reason the last dial failed, if one did.
    TimedOut {
        reason: Option<String>,
    },
    Failed {
        reason: String,
    },
    Closed,
}

/// A link's state across its first connect and after it. See the module docs.
#[derive(Debug)]
pub struct LinkCell {
    phase: watch::Sender<LinkPhase>,
    /// Bumped by a caller that waits on the link: a parked first dial dials now.
    actions: watch::Sender<u64>,
}

impl LinkCell {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            phase: watch::channel(LinkPhase::Connecting { reason: None }).0,
            actions: watch::channel(0).0,
        })
    }

    pub fn phase(&self) -> LinkPhase {
        self.phase.borrow().clone()
    }

    pub fn subscribe(&self) -> watch::Receiver<LinkPhase> {
        self.phase.subscribe()
    }

    /// The first connect succeeded: from now on the connection answers for the link.
    pub fn attach(&self, connection: &Arc<ClientConnection>) {
        self.phase.send_replace(LinkPhase::Connected(Arc::downgrade(connection)));
    }

    /// The owner is done with the link; every waiter returns.
    pub fn close(&self) {
        self.phase.send_replace(LinkPhase::Closed);
    }

    /// A caller waits on the link: a parked first dial dials now (still within its budget).
    pub fn wake(&self) {
        self.actions.send_modify(|count| *count = count.wrapping_add(1));
    }

    /// Wait until the link has a connection or `deadline` passes, waking a parked first dial.
    /// Returns the connection once the first connect succeeded, whatever its state now (the
    /// caller waits on the connection itself for the rest of its deadline).
    pub async fn wait_connected(
        &self,
        deadline: tokio::time::Instant,
    ) -> Result<Arc<ClientConnection>, NotConnected> {
        let mut phase = self.phase.subscribe();
        if matches!(*phase.borrow(), LinkPhase::Connecting { .. } | LinkPhase::Disconnected { .. })
        {
            self.wake();
        }
        loop {
            let reason = match &*phase.borrow_and_update() {
                LinkPhase::Connected(connection) => {
                    return connection.upgrade().ok_or(NotConnected::Closed);
                }
                LinkPhase::Failed { reason } => {
                    return Err(NotConnected::Failed { reason: reason.clone() });
                }
                LinkPhase::Closed => return Err(NotConnected::Closed),
                LinkPhase::Connecting { reason } | LinkPhase::Disconnected { reason } => {
                    reason.clone()
                }
            };
            tokio::select! {
                changed = phase.changed() => {
                    if changed.is_err() {
                        return Err(NotConnected::Closed);
                    }
                }
                () = tokio::time::sleep_until(deadline) => {
                    return Err(NotConnected::TimedOut { reason });
                }
            }
        }
    }

    /// Run the first dial until `attempt` connects or fails for good. Each attempt spends a token
    /// from `policy.redial_budget`; attempts come in bursts of `policy.attempts_per_recovery`
    /// (the first at once, then after the jittered `initial_delay` and four times that), and the
    /// dial then parks until a network change on `network`, a [`LinkCell::wake`], or the
    /// jittered `maximum_delay`. A network change abandons an attempt in flight and starts a new
    /// burst at once. A finite `policy.maximum_attempts` ends it after that many failures with
    /// the last error, counting an attempt a network change abandoned
    /// ([`DialStop::NetworkChanged`]), so a flapping network cannot outlast the bound. A finite
    /// `policy.maximum_duration` ends the whole dial, an attempt in flight or a wait included, with
    /// [`DialStop::DeadlineExceeded`]. The caller attaches the connection it got
    /// ([`LinkCell::attach`]).
    pub async fn dial<T, E, F, Fut>(
        &self,
        policy: ReconnectPolicy,
        mut network: watch::Receiver<u64>,
        mut attempt: F,
    ) -> Result<T, E>
    where
        E: fmt::Display + From<DialStop>,
        F: FnMut() -> Fut,
        Fut: Future<Output = DialOutcome<T, E>>,
    {
        let mut actions = self.actions.subscribe();
        actions.borrow_and_update();
        let mut bucket = TokenBucket::new(policy.redial_budget, tokio::time::Instant::now());
        // The whole first dial, attempts and waits included, ends by `maximum_duration`.
        let deadline = policy
            .maximum_duration
            .and_then(|bound| tokio::time::Instant::now().checked_add(bound));
        let mut attempts = 0_u32;
        let mut failures = 0_u32;
        let mut in_burst = 0_u32;
        let mut delay = policy.initial_delay;
        let mut reason: Option<String> = None;
        // The deadline is polled first in every wait, as `ClientConnection`'s is: a wait that
        // is ready at or past it still loses, so nothing goes on after it.
        loop {
            if expired(deadline) {
                return Err(self.fail(DialStop::DeadlineExceeded { attempts }.into()));
            }
            while let Err(next) = bucket.take(tokio::time::Instant::now()) {
                self.phase.send_replace(LinkPhase::Disconnected { reason: reason.clone() });
                tokio::select! {
                    biased;
                    () = until(deadline) => {
                        return Err(self.fail(DialStop::DeadlineExceeded { attempts }.into()));
                    }
                    () = tokio::time::sleep_until(next) => {}
                }
            }
            // A token that arrived at the deadline starts nothing.
            if expired(deadline) {
                return Err(self.fail(DialStop::DeadlineExceeded { attempts }.into()));
            }
            attempts = attempts.saturating_add(1);
            in_burst = in_burst.saturating_add(1);
            self.phase.send_replace(LinkPhase::Connecting { reason: reason.clone() });
            // This attempt starts on the network as it is now; only a change while it is in
            // flight abandons it.
            network.borrow_and_update();
            let mut network_moved = false;
            let outcome = tokio::select! {
                biased;
                () = until(deadline) => {
                    return Err(self.fail(DialStop::DeadlineExceeded { attempts }.into()));
                }
                outcome = attempt() => outcome,
                // A dial on the network that went away may hang until its timeout; drop it.
                Ok(()) = network.changed() => {
                    network_moved = true;
                    DialOutcome::Retry(DialStop::NetworkChanged.into())
                }
            };
            let error = match outcome {
                DialOutcome::Ready(value) => return Ok(value),
                DialOutcome::Fatal(error) => return Err(self.fail(error)),
                DialOutcome::Retry(error) => error,
            };
            reason = Some(error.to_string());
            // Every failed attempt counts, one a network change abandoned too: a flapping
            // network cannot outlast an attempt bound.
            failures = failures.saturating_add(1);
            if policy.maximum_attempts.is_some_and(|maximum| failures >= maximum) {
                return Err(self.fail(error));
            }
            if network_moved || network.has_changed().unwrap_or(false) {
                // A new network starts a new burst at once.
                network.borrow_and_update();
                in_burst = 0;
                delay = policy.initial_delay;
                continue;
            }
            let parking = in_burst >= policy.attempts_per_recovery;
            let wait = if parking {
                self.phase.send_replace(LinkPhase::Disconnected { reason: reason.clone() });
                policy.retry_delay(policy.maximum_delay)
            } else {
                policy.retry_delay(delay)
            };
            // Any change seen before this wait counts: a caller's wait while an attempt was in
            // flight still wakes the park.
            let woken = tokio::select! {
                biased;
                () = until(deadline) => {
                    return Err(self.fail(DialStop::DeadlineExceeded { attempts }.into()));
                }
                Ok(()) = network.changed() => {
                    network.borrow_and_update();
                    true
                }
                Ok(()) = actions.changed(), if parking => {
                    actions.borrow_and_update();
                    true
                }
                () = tokio::time::sleep(wait) => false,
            };
            if parking || woken {
                in_burst = 0;
                delay = policy.initial_delay;
            } else {
                delay = delay.saturating_mul(4).min(policy.maximum_delay);
            }
        }
    }

    /// The first dial ended for good with `error`: the cell says why.
    fn fail<E: fmt::Display>(&self, error: E) -> E {
        self.phase.send_replace(LinkPhase::Failed { reason: error.to_string() });
        error
    }
}

fn expired(deadline: Option<tokio::time::Instant>) -> bool {
    deadline.is_some_and(|deadline| tokio::time::Instant::now() >= deadline)
}

/// Resolves at `deadline`, or never without one.
async fn until(deadline: Option<tokio::time::Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending().await,
    }
}
