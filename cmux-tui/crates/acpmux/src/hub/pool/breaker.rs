//! The background-start circuit breaker: one budget for every agent start no person asked for.
//!
//! The pool (hinted, last-used, reserved and spare entries, their restores at daemon start and
//! their restarts after a death) and the desktop pane's warm-up (`warm.rs`) start agents nobody
//! is waiting on. A bug in any of them that starts, ends and starts again thrashes the machine:
//! one such loop (a spare started on every app request and evicted at once by the pool's RSS
//! cap) made about 2,800 agent starts in two hours, a load average of 214 and unusable chats.
//! This module bounds every such loop, whatever its cause:
//!
//! - **Budget.** A token bucket for all background starts together and one per harness. A
//!   start over either budget is refused and trips the breaker for that scope.
//! - **Churn.** An entry that ends unused (evicted, idled out, over the cap, dead) within
//!   [`CHURN_AGE`] of becoming ready is churn; [`CHURN_TRIPS`] of them for one harness within
//!   [`CHURN_WINDOW`] trip the breaker for that harness.
//! - **Cooldown.** A tripped scope refuses every background start for a cooldown that doubles
//!   with each trip ([`BASE_COOLDOWN`] up to [`MAX_COOLDOWN`]), and starts again at the base
//!   once a [`CALM`] passes with no trip. Each trip logs one WARN line; refusals log nothing.
//!
//! A person's own start (a `session/new`, a prompt that starts its chat's agent) never comes
//! here: a claim that finds no pooled entry starts cold, so a tripped breaker costs warm starts,
//! never a chat. Time is the hub's injected clock (`clock.rs`).

use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::time::Duration;

/// Background starts per minute for the whole daemon, and its burst.
pub(super) const GLOBAL_PER_MINUTE: u32 = 12;
/// Background starts per minute for one harness, and its burst.
pub(super) const HARNESS_PER_MINUTE: u32 = 6;
/// An entry that ends unused this soon after it became ready is churn.
pub(super) const CHURN_AGE: Duration = Duration::from_secs(120);
/// The window churn is counted in.
pub(super) const CHURN_WINDOW: Duration = Duration::from_secs(10 * 60);
/// Churned entries of one harness within [`CHURN_WINDOW`] that trip its breaker.
pub(super) const CHURN_TRIPS: usize = 3;
/// The first trip's cooldown; each trip after it doubles it.
pub(super) const BASE_COOLDOWN: Duration = Duration::from_secs(60);
/// The longest cooldown.
pub(super) const MAX_COOLDOWN: Duration = Duration::from_secs(30 * 60);
/// A scope with no trip this long after its last cooldown ended starts over at the base.
pub(super) const CALM: Duration = Duration::from_secs(30 * 60);

/// A token bucket refilled continuously at `per_minute`, holding at most `per_minute`.
struct Bucket {
    tokens: f64,
    at: Duration,
    per_minute: u32,
}

impl Bucket {
    fn new(per_minute: u32) -> Self {
        Self { tokens: f64::from(per_minute), at: Duration::ZERO, per_minute }
    }

    fn has(&mut self, now: Duration) -> bool {
        let elapsed = now.saturating_sub(self.at).as_secs_f64();
        let burst = f64::from(self.per_minute);
        self.tokens = (self.tokens + elapsed * burst / 60.0).min(burst);
        self.at = self.at.max(now);
        self.tokens >= 1.0
    }

    fn take(&mut self) {
        self.tokens -= 1.0;
    }
}

/// One scope's breaker: the whole daemon, or one harness.
struct Scope {
    bucket: Bucket,
    churn: VecDeque<Duration>,
    open_until: Option<Duration>,
    strikes: u32,
    trips: u64,
    refused: u64,
    reason: Option<&'static str>,
}

impl Scope {
    fn new(per_minute: u32) -> Self {
        Self {
            bucket: Bucket::new(per_minute),
            churn: VecDeque::new(),
            open_until: None,
            strikes: 0,
            trips: 0,
            refused: 0,
            reason: None,
        }
    }

    fn open(&self, now: Duration) -> bool {
        self.open_until.is_some_and(|until| now < until)
    }

    fn trip(&mut self, name: &str, reason: &'static str, now: Duration) {
        let calm = self.open_until.is_none_or(|until| now >= until + CALM);
        self.strikes = if calm { 1 } else { self.strikes.saturating_add(1) };
        let cooldown =
            BASE_COOLDOWN.saturating_mul(1u32 << (self.strikes - 1).min(16)).min(MAX_COOLDOWN);
        self.open_until = Some(now + cooldown);
        self.trips += 1;
        self.reason = Some(reason);
        self.churn.clear();
        tracing::warn!(
            scope = name,
            reason,
            cooldown_secs = cooldown.as_secs(),
            trips = self.trips,
            "background agent starts paused: the start breaker tripped"
        );
    }

    fn view(&self, now: Duration) -> Value {
        let open = self.open(now);
        json!({
            "open": open,
            "reopensInMs": self
                .open_until
                .filter(|_| open)
                .map(|until| u64::try_from((until - now).as_millis()).unwrap_or(u64::MAX)),
            "trips": self.trips,
            "strikes": self.strikes,
            "refused": self.refused,
            "reason": self.reason,
        })
    }
}

/// The breaker for every background start (the module doc).
pub(super) struct StartBreaker {
    global: Scope,
    harnesses: HashMap<String, Scope>,
}

impl Default for StartBreaker {
    fn default() -> Self {
        Self { global: Scope::new(GLOBAL_PER_MINUTE), harnesses: HashMap::new() }
    }
}

const GLOBAL: &str = "all harnesses";

impl StartBreaker {
    /// Whether a background start of `harness` may run at `now`; an admitted start spends one
    /// token of the daemon's budget and one of the harness's. A start over either trips it.
    pub(super) fn admit(&mut self, harness: &str, now: Duration) -> bool {
        let scope = self
            .harnesses
            .entry(harness.to_owned())
            .or_insert_with(|| Scope::new(HARNESS_PER_MINUTE));
        if self.global.open(now) {
            self.global.refused += 1;
            return false;
        }
        if scope.open(now) {
            scope.refused += 1;
            return false;
        }
        if !self.global.bucket.has(now) {
            self.global.refused += 1;
            self.global.trip(GLOBAL, "budget", now);
            return false;
        }
        if !scope.bucket.has(now) {
            scope.refused += 1;
            scope.trip(harness, "budget", now);
            return false;
        }
        self.global.bucket.take();
        scope.bucket.take();
        true
    }

    /// A background entry of `harness` that became ready at `ready_at` ended at `now` without a
    /// chat taking it. Ended soon after it was ready, it counts as churn.
    pub(super) fn note_unused_end(&mut self, harness: &str, ready_at: Duration, now: Duration) {
        if now.saturating_sub(ready_at) > CHURN_AGE {
            return;
        }
        let scope = self
            .harnesses
            .entry(harness.to_owned())
            .or_insert_with(|| Scope::new(HARNESS_PER_MINUTE));
        while scope.churn.front().is_some_and(|at| now.saturating_sub(*at) > CHURN_WINDOW) {
            scope.churn.pop_front();
        }
        scope.churn.push_back(now);
        if scope.churn.len() >= CHURN_TRIPS && !scope.open(now) {
            scope.trip(harness, "churn", now);
        }
    }

    /// The breaker as `_acpmux/status` reports it (`pool.breaker`): only harnesses that ever
    /// tripped are listed.
    pub(super) fn view(&self, now: Duration) -> Value {
        let harnesses: serde_json::Map<String, Value> = self
            .harnesses
            .iter()
            .filter(|(_, s)| s.trips > 0)
            .map(|(name, s)| (name.clone(), s.view(now)))
            .collect();
        let tripped = self.global.open(now) || self.harnesses.values().any(|s| s.open(now));
        json!({
            "tripped": tripped,
            "global": self.global.view(now),
            "harnesses": harnesses,
            "limits": {"globalPerMinute": GLOBAL_PER_MINUTE, "harnessPerMinute": HARNESS_PER_MINUTE},
        })
    }
}

/// `acpmux daemon status`'s line for the breaker, once it has ever tripped.
pub(crate) fn status_line(status: &Value) -> Option<String> {
    let b = status.pointer("/pool/breaker")?;
    let mut scopes: Vec<(&str, &Value)> = vec![(GLOBAL, &b["global"])];
    if let Some(map) = b["harnesses"].as_object() {
        scopes.extend(map.iter().map(|(k, v)| (k.as_str(), v)));
    }
    let trips: u64 = scopes.iter().filter_map(|(_, s)| s["trips"].as_u64()).sum();
    if trips == 0 {
        return None;
    }
    let open: Vec<String> = scopes
        .iter()
        .filter(|(_, s)| s["open"].as_bool() == Some(true))
        .map(|(name, s)| {
            let secs = s["reopensInMs"].as_u64().unwrap_or(0).div_ceil(1000);
            format!("{name} ({}, {secs}s left)", s["reason"].as_str().unwrap_or("?"))
        })
        .collect();
    Some(if open.is_empty() {
        format!("breaker:  closed ({trips} trips since start)")
    } else {
        format!("breaker:  background starts paused for {} ({trips} trips)", open.join(", "))
    })
}

#[cfg(test)]
#[path = "breaker_tests.rs"]
mod tests;
