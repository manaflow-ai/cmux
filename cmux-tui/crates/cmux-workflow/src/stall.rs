//! When an agent step stops making progress. The host feeds a [`Watch`] the
//! agent's events (acpmux session updates) and ticks it; the watch answers
//! what to do. The ladder: nudge the agent, then restart it on another route
//! or harness, then fail the step. A limit or route error skips the nudge
//! (a nudge cannot clear it): Chief's agents a1-a7 sat for hours on "You've
//! hit your limit" with nothing to move them.

use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StallPolicy {
    /// No event for this long, or a permission waiting this long, is a stall.
    pub quiet: Duration,
    /// Nudges before the first restart.
    pub nudges: u32,
    /// Restarts before the step fails.
    pub restarts: u32,
}

impl Default for StallPolicy {
    fn default() -> Self {
        Self { quiet: Duration::from_secs(10 * 60), nudges: 1, restarts: 1 }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Signal {
    /// Any session event: text, a tool call, a status change.
    Activity,
    /// A permission or question dialog is open.
    PermissionWaiting,
    /// The harness hit a usage limit.
    LimitHit(String),
    /// The model route failed (router down, auth, 5xx).
    RouteError(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Wait,
    /// Send the agent one short message asking it to continue.
    Nudge {
        reason: String,
    },
    /// Stop the session and continue it on another route or harness
    /// (`acpmux continue`); call [`Watch::restarted`] once done.
    Restart {
        reason: String,
    },
    /// Fail the step with `reason`.
    Fail {
        reason: String,
    },
}

#[derive(Clone, Debug)]
pub struct Watch {
    policy: StallPolicy,
    last: Instant,
    waiting: bool,
    nudged: u32,
    restarted: u32,
}

impl Watch {
    pub fn new(policy: StallPolicy, now: Instant) -> Self {
        Self { policy, last: now, waiting: false, nudged: 0, restarted: 0 }
    }

    pub fn observe(&mut self, signal: Signal, now: Instant) -> Decision {
        match signal {
            Signal::Activity => {
                self.last = now;
                self.waiting = false;
                Decision::Wait
            }
            Signal::PermissionWaiting => {
                if !self.waiting {
                    self.waiting = true;
                    self.last = now;
                }
                Decision::Wait
            }
            Signal::LimitHit(detail) => self.restart_or_fail(format!("usage limit: {detail}"), now),
            Signal::RouteError(detail) => {
                self.restart_or_fail(format!("route error: {detail}"), now)
            }
        }
    }

    /// Call periodically (a minute is fine) while the step runs.
    pub fn tick(&mut self, now: Instant) -> Decision {
        let quiet = now.saturating_duration_since(self.last);
        if quiet < self.policy.quiet {
            return Decision::Wait;
        }
        let minutes = quiet.as_secs() / 60;
        let reason = if self.waiting {
            format!("a permission has waited {minutes} min")
        } else {
            format!("no event for {minutes} min")
        };
        if self.nudged < self.policy.nudges {
            self.nudged += 1;
            self.last = now;
            return Decision::Nudge { reason };
        }
        self.restart_or_fail(reason, now)
    }

    /// The host restarted the session: the quiet clock and nudges reset.
    pub fn restarted(&mut self, now: Instant) {
        self.last = now;
        self.waiting = false;
        self.nudged = 0;
    }

    fn restart_or_fail(&mut self, reason: String, now: Instant) -> Decision {
        if self.restarted < self.policy.restarts {
            self.restarted += 1;
            self.last = now;
            Decision::Restart { reason }
        } else {
            Decision::Fail { reason }
        }
    }
}
