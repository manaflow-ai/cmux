//! Time watches (RFD 0012 G4, RFD 0177): `acpmux watch add --at T | --every D [--until T]
//! --prompt TEXT`. A time watch wakes its recipient with its prompt when it falls due, and keeps
//! that durably, like the state watches it sits beside (`watches.rs`): the next due time is in
//! the watch, the wake it owes in `pending`, and both commit together in one save.
//!
//! The timer queue is the Linux hrtimer rbtree's analogue: a `BTreeMap` from due time to the
//! watches due then, ordered so the earliest is the first key. One hub task sleeps until that key
//! and never polls; an add or remove wakes it to re-arm. A timer wheel is overkill at this scale
//! (tens of watches, not millions of sockets), and the map is rebuilt from the saved watches on
//! each arm, so it can never disagree with what is on disk.
//!
//! Kernel ideas taken wholesale, and where they bend:
//! - Timer slack (`prctl(PR_SET_TIMERSLACK)`): as in the kernel, slack only ever makes a timer
//!   later, never earlier. The task arms for the last due time within [`SLACK_MS`] of the earliest
//!   (`wake_at`), so watches due within a second of each other fire in one wake.
//! - A missed periodic fire collapses, like an overrun `timerfd` read returning a count instead of
//!   N wakeups: an `--every` watch the host slept through fires once, then reschedules from now.
//! - Exactly once across restarts, which the kernel never needed: the wake's prompt id is
//!   `<watch id>@<due ms>` (`prompt_id`). The outbox and the recipient's prompt ledger both key on
//!   it, so a fire repeated after a crash mid-save is the same message, not a second one.
//! - Monotonic sleep stops while the host sleeps (CLOCK_MONOTONIC on Linux, CLOCK_UPTIME_RAW on
//!   macOS), so the task re-reads the wall clock at least every [`MAX_SLEEP_MS`]: a timer the host
//!   slept through fires within that bound of waking, not a whole sleep late.
use super::{Delivery, State, Watch, Watches};
use crate::rpc::RpcError;
use serde_json::json;
use std::collections::BTreeMap;

/// How late a watch may fire so it shares a wake with an earlier one (timer slack).
pub const SLACK_MS: u64 = 1_000;
/// The longest the timer task sleeps before it re-reads the wall clock (see the module doc).
pub const MAX_SLEEP_MS: u64 = 300_000;
/// The shortest `--every`.
pub const MIN_EVERY_MS: u64 = 1_000;
/// The longest prompt a time watch keeps (it is saved in `watches.json` and sent each fire).
pub const MAX_PROMPT_BYTES: usize = 64 * 1024;

/// The prompt id of the wake a watch owes for the fire due at `due_ms`: the same on every retry
/// and after any restart, so each fire is delivered once.
pub fn prompt_id(watch_id: &str, due_ms: u64) -> String {
    format!("{watch_id}@{due_ms}")
}

/// After a fire due at `due`, at `now`: the next due time, or None when the watch is done (a
/// one-shot `--at`, or an `--every` past its `--until`). A fire on time keeps the period's
/// phase (`due + every`); one the host slept through collapses to a single fire and reschedules
/// from now, not N catch-up fires.
pub fn next_due(due: u64, every: Option<u64>, end: Option<u64>, now: u64) -> Option<u64> {
    let every = every?;
    let on_phase = due.saturating_add(every);
    let next = if on_phase > now { on_phase } else { now.saturating_add(every) };
    end.is_none_or(|end| next <= end).then_some(next)
}

/// The timer queue: due time to the active time watches due then.
pub fn queue<'a>(watches: impl IntoIterator<Item = &'a Watch>) -> BTreeMap<u64, Vec<String>> {
    let mut q: BTreeMap<u64, Vec<String>> = BTreeMap::new();
    for w in watches.into_iter().filter(|w| w.active) {
        if let Some(due) = w.due_ms {
            q.entry(due).or_default().push(w.id.clone());
        }
    }
    q
}

/// When to wake next: the last due time within `SLACK_MS` of the earliest, so those fire
/// together, each at most `SLACK_MS` late and none early.
pub fn wake_at(queue: &BTreeMap<u64, Vec<String>>) -> Option<u64> {
    let first = *queue.keys().next()?;
    queue.range(first..=first.saturating_add(SLACK_MS)).next_back().map(|(due, _)| *due)
}

/// The watches to fire in a wake at `now`: every one due by then.
pub fn due_now(queue: &BTreeMap<u64, Vec<String>>, now: u64) -> Vec<(u64, String)> {
    queue
        .range(..=now)
        .flat_map(|(due, ids)| ids.iter().map(move |id| (*due, id.clone())))
        .collect()
}

fn rfc3339(ms: u64) -> String {
    chrono::DateTime::from_timestamp_millis(ms as i64)
        .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
        .unwrap_or_else(|| ms.to_string())
}

impl Watches {
    /// Fire every time watch due by `now` in one save: each owes one wake whose
    /// prompt id is `prompt_id(watch, due)`, and its next due time moves on in the same write.
    /// Returns the prompt ids fired and when to wake next (`wake_at`).
    pub(crate) fn fire_timers(&self, now: u64) -> Result<(Vec<String>, Option<u64>), RpcError> {
        let due = {
            let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            due_now(&queue(inner.saved.watches.values()), now)
        };
        let fired = if due.is_empty() {
            Vec::new()
        } else {
            self.change(|s| {
                let mut fired = Vec::new();
                for (at, id) in &due {
                    let Some(w) = s.watches.get_mut(id) else { continue };
                    if !w.active || w.due_ms != Some(*at) {
                        continue;
                    }
                    let next = next_due(*at, w.every_ms, w.end_ms, now);
                    w.due_ms = next;
                    w.active = next.is_some();
                    let pid = prompt_id(&w.id, *at);
                    let text = format!(
                        "acpmux watch {} (time, due {}):\n{}",
                        w.id,
                        rfc3339(*at),
                        w.prompt.as_deref().unwrap_or_default()
                    );
                    let d = delivery(w, pid.clone(), text, next.is_none());
                    s.pending.entry(pid.clone()).or_insert(d);
                    fired.push(pid);
                }
                fired
            })?
        };
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let earliest = wake_at(&queue(inner.saved.watches.values()));
        Ok((fired, earliest))
    }
}

/// The wake a watch owes, as the durable outbox sends it.
pub(super) fn delivery(w: &Watch, id: String, text: String, done: bool) -> Delivery {
    let now = crate::store::now_ms();
    let request = json!({"sessionId": w.to, "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": id, "resend": true, "steer": true,
            "watchId": w.id, "watchDone": done}}});
    Delivery {
        id,
        target: w.to.clone(),
        request,
        caller: w.caller.clone(),
        unproven_caller: None,
        not_terminal: false,
        state: State::Queued,
        attempts: 0,
        never_sent: false,
        resends: 0,
        resent_at: 0,
        relay_post: None,
        relay_unreached: false,
        direct_maybe: false,
        open_on_peer: false,
        pin: None,
        proof: None,
        error: None,
        accepted: None,
        created_at: now,
        updated_at: now,
    }
}

#[cfg(test)]
#[path = "watch_timers_tests.rs"]
mod tests;
