//! The lane's per-caller budget on lent GitHub actions (`server/github_lane.rs`).
//!
//! Every agent session on this machine shares the one Mac that lends it GitHub, and that Mac runs
//! at most `OWNER_SLOTS` actions of this machine at once (`github_broker.rs`). Without a budget
//! one session in a loop (a `gh` retry storm, a script polling a pull request) takes every slot
//! and the shared GitHub quota, and every other session's push waits or fails: the fleet's
//! `gh-quota-shim` and `gh_quota.py` exist for that (hq `docs/design/fleet-dogfoods-remote.md`,
//! class 8). Here each caller (the session that asked, proved by its caller token) gets at most
//! `CALLER_RUNNING` actions at once and `CALLER_RATE` started per `CALLER_WINDOW_MS`; past
//! either, the action is refused at once with `github.budget`, retryable, and the time to wait.

use crate::rpc::RpcError;
use serde_json::json;
use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

/// Actions one caller may have running at once: half the Mac's slots for this machine, so one
/// session never holds all of them.
pub const CALLER_RUNNING: usize = crate::github_broker::OWNER_SLOTS / 2;
/// Actions one caller may start per window. A push mints one token, a `gh pr create` one read
/// and one action; 60 a minute is past any person-paced agent and stops a loop within a minute.
pub const CALLER_RATE: usize = 60;
pub const CALLER_WINDOW_MS: u64 = 60_000;
/// Callers kept; past that the idle ones go first (a caller's entry is idle once nothing of it
/// runs and its window is empty).
const CALLERS_MAX: usize = 4096;

#[derive(Default)]
struct Caller {
    running: usize,
    starts: VecDeque<u64>,
}

impl Caller {
    fn expire(&mut self, now_ms: u64) {
        while self.starts.front().is_some_and(|t| now_ms.saturating_sub(*t) >= CALLER_WINDOW_MS) {
            self.starts.pop_front();
        }
    }
    fn idle(&self) -> bool {
        self.running == 0 && self.starts.is_empty()
    }
}

#[derive(Default)]
pub struct Budget(Mutex<HashMap<String, Caller>>);

/// One action `caller` was let start; it counts as running until this drops.
pub struct Permit<'a> {
    budget: &'a Budget,
    caller: String,
}

impl Drop for Permit<'_> {
    fn drop(&mut self) {
        let mut callers = self.budget.0.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(c) = callers.get_mut(&self.caller) {
            c.running = c.running.saturating_sub(1);
        }
    }
}

impl Budget {
    /// Let `caller` start one action at `now_ms`, or refuse it with how long to wait.
    pub fn take(&self, caller: &str, now_ms: u64) -> Result<Permit<'_>, RpcError> {
        let mut callers = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if callers.len() >= CALLERS_MAX && !callers.contains_key(caller) {
            callers.retain(|_, c| {
                c.expire(now_ms);
                !c.idle()
            });
        }
        let c = callers.entry(caller.to_owned()).or_default();
        c.expire(now_ms);
        if c.running >= CALLER_RUNNING {
            return Err(refused(
                format!("this session already has {CALLER_RUNNING} GitHub actions running"),
                "running",
                1_000,
            ));
        }
        if c.starts.len() >= CALLER_RATE {
            let oldest = c.starts.front().copied().unwrap_or(now_ms);
            let wait = (oldest + CALLER_WINDOW_MS).saturating_sub(now_ms).max(1);
            return Err(refused(
                format!(
                    "this session started {CALLER_RATE} GitHub actions in the last {}s",
                    CALLER_WINDOW_MS / 1000
                ),
                "rate",
                wait,
            ));
        }
        c.running += 1;
        c.starts.push_back(now_ms);
        Ok(Permit { budget: self, caller: caller.to_owned() })
    }

    #[cfg(test)]
    fn callers(&self) -> usize {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).len()
    }
}

fn refused(message: String, limit: &str, retry_after_ms: u64) -> RpcError {
    RpcError::new(
        -32000,
        format!("{message}; nothing was sent, retry in {}s", retry_after_ms.div_ceil(1000)),
    )
    .with_data(json!({
        "reason": "github.budget",
        "limit": limit,
        "retryable": true,
        "retryAfterMs": retry_after_ms,
    }))
}

/// This daemon's budget.
pub fn budget() -> &'static Budget {
    static BUDGET: std::sync::LazyLock<Budget> = std::sync::LazyLock::new(Budget::default);
    &BUDGET
}

#[cfg(test)]
#[path = "github_budget_tests.rs"]
mod tests;
