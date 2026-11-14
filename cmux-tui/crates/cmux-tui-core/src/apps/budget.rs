//! The host's budget ladder for App Store apps and `local/customize`
//! (plans/cmux-next/extensibility-DESIGN.md sections 3 and 6):
//! Normal -> Slowed -> Paused, and Off (the install mirror's `enabled`).
//!
//! - **Op batches per mount** ([`MountBudget`]): the supervisor forwards at
//!   most one scene batch per frame ([`FRAME`]) to the client; batches that
//!   arrive sooner wait and coalesce (ops appended in order, consecutive
//!   `update`s of one node merged). When an app sends more than [`MAX_RATE`]
//!   batches in a second for [`SLOW_AFTER`], the mount is **Slowed**: it gets
//!   at most one batch per [`SLOWED_INTERVAL`]. Back under the rate for
//!   [`SLOW_AFTER`], it is Normal again.
//! - **Paused** ([`AppLadder`]): [`TIMEOUTS_TO_PAUSE`] entry timeouts (or CPU
//!   window kills) within [`TIMEOUT_WINDOW`], a second memory kill (the
//!   first one restarted the VM), or a mount Slowed for [`PAUSE_AFTER_SLOWED`].
//!   Every mount of the app fails with [`PAUSED`] (the place shows its native
//!   view), the host stops and no host starts until `apps.resume`, a save of
//!   a local app, or turning the app off and on.
//!
//! Everything here is a pure function of the `now` it is given, so tests
//! drive it with injected instants and no sleeps.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use cmux_app_host::FatalReason;
use cmux_json::JsonSet as _;
use serde::Deserialize;
use serde_json::{Value, json};

use super::mirror::Origin;
use super::supervisor::{ApiError, HostKey, Inner, MountKey, Out, Supervisor};
use crate::panic_free::RecoverPoison;

/// One display frame at 60 Hz: the most often a mount's scene is forwarded.
pub(super) const FRAME: Duration = Duration::from_micros(16_667);
/// Batches per second a mount may send sustained.
pub(super) const MAX_RATE: usize = 10;
/// The window the rate is measured over.
pub(super) const RATE_WINDOW: Duration = Duration::from_secs(1);
/// How long over (or back under) the rate before the step changes.
pub(super) const SLOW_AFTER: Duration = Duration::from_secs(5);
/// A Slowed mount gets at most one batch this often.
pub(super) const SLOWED_INTERVAL: Duration = Duration::from_secs(1);
/// Slowed this long pauses the app.
pub(super) const PAUSE_AFTER_SLOWED: Duration = Duration::from_secs(60);
/// Entry timeouts within [`TIMEOUT_WINDOW`] that pause the app.
pub(super) const TIMEOUTS_TO_PAUSE: usize = 3;
pub(super) const TIMEOUT_WINDOW: Duration = Duration::from_secs(60);
/// What a paused app's mounts fail with, and what its header says.
pub(super) const PAUSED: &str = "Paused: this app used too much time";

/// A mount's or an app's step on the ladder. Off is not here: it is the
/// install mirror's `enabled = false`, and an app that is off has no host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Step {
    Normal,
    Slowed,
    Paused,
}

impl Step {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Slowed => "slowed",
            Self::Paused => "paused",
        }
    }
}

/// What one batch or one flush asks the supervisor to do.
#[derive(Debug, Default, PartialEq)]
pub(super) struct Outcome {
    /// Forward these ops to the client now (one `apps-scene`).
    pub deliver: Option<Vec<Value>>,
    /// Call [`MountBudget::flush`] at this instant (a held batch is waiting).
    pub flush_at: Option<Instant>,
    /// The mount moved to this step (Normal or Slowed).
    pub changed: Option<Step>,
    /// The mount was Slowed for [`PAUSE_AFTER_SLOWED`]: pause the app.
    pub pause: bool,
}

/// The batch-rate budget of one mount.
#[derive(Debug)]
pub(super) struct MountBudget {
    /// The last `MAX_RATE + 1` arrivals: enough to tell whether more than
    /// `MAX_RATE` came within [`RATE_WINDOW`], bounded whatever the app sends.
    arrivals: VecDeque<Instant>,
    over_since: Option<Instant>,
    under_since: Option<Instant>,
    slowed_since: Option<Instant>,
    last_sent: Option<Instant>,
    pending: Vec<Value>,
    flush_armed: bool,
    /// Batches the app sent, and batches forwarded (perf-gate counters).
    pub batches_in: u64,
    pub batches_out: u64,
}

impl Default for MountBudget {
    fn default() -> Self {
        Self {
            arrivals: VecDeque::with_capacity(MAX_RATE + 1),
            over_since: None,
            under_since: None,
            slowed_since: None,
            last_sent: None,
            pending: Vec::new(),
            flush_armed: false,
            batches_in: 0,
            batches_out: 0,
        }
    }
}

impl MountBudget {
    /// Drops held ops (the host restarted: they belong to the old tree).
    pub(super) fn clear_pending(&mut self) {
        self.pending.clear();
    }

    pub(super) fn step(&self) -> Step {
        if self.slowed_since.is_some() { Step::Slowed } else { Step::Normal }
    }

    /// One scene batch from the app at `now`.
    pub(super) fn offer(&mut self, now: Instant, ops: Vec<Value>) -> Outcome {
        self.batches_in = self.batches_in.saturating_add(1);
        if self.arrivals.len() > MAX_RATE {
            self.arrivals.pop_front();
        }
        self.arrivals.push_back(now);
        let mut outcome = Outcome::default();
        // The oldest of the last `MAX_RATE + 1` batches, when it is within
        // the window: more than `MAX_RATE` came in one second.
        let over = self.arrivals.front().copied().filter(|first| {
            self.arrivals.len() > MAX_RATE && now.duration_since(*first) < RATE_WINDOW
        });
        if let Some(first) = over {
            self.under_since = None;
            // Over since the oldest batch of the window that went over.
            let since = *self.over_since.get_or_insert(first);
            if self.slowed_since.is_none() && now.duration_since(since) >= SLOW_AFTER {
                self.slowed_since = Some(now);
                outcome.changed = Some(Step::Slowed);
            }
        } else {
            self.over_since = None;
            let since = *self.under_since.get_or_insert(now);
            if self.slowed_since.is_some() && now.duration_since(since) >= SLOW_AFTER {
                self.slowed_since = None;
                outcome.changed = Some(Step::Normal);
            }
        }
        if self.slowed_since.is_some_and(|at| now.duration_since(at) >= PAUSE_AFTER_SLOWED) {
            outcome.pause = true;
            return outcome;
        }
        append(&mut self.pending, ops);
        self.send_or_hold(now, &mut outcome);
        outcome
    }

    /// The flush timer fired at `now`: forwards the held batch when it is due.
    pub(super) fn flush(&mut self, now: Instant) -> Outcome {
        self.flush_armed = false;
        let mut outcome = Outcome::default();
        if !self.pending.is_empty() {
            self.send_or_hold(now, &mut outcome);
        }
        outcome
    }

    fn send_or_hold(&mut self, now: Instant, outcome: &mut Outcome) {
        let interval = if self.slowed_since.is_some() { SLOWED_INTERVAL } else { FRAME };
        let due = self.last_sent.map_or(now, |at| at.checked_add(interval).unwrap_or(at));
        if now >= due {
            self.last_sent = Some(now);
            self.batches_out = self.batches_out.saturating_add(1);
            outcome.deliver = Some(std::mem::take(&mut self.pending));
        } else if !self.flush_armed {
            self.flush_armed = true;
            outcome.flush_at = Some(due);
        }
    }
}

/// Appends `ops` to the held ops. An `update` of the node the last held op
/// updates merges into it (later props win, a `null` still deletes), so a
/// row rewritten every frame holds one op, not one per batch.
fn append(pending: &mut Vec<Value>, ops: Vec<Value>) {
    for op in ops {
        if op.get("op").and_then(Value::as_str) == Some("update")
            && let Some(last) = pending.last_mut()
            && last.get("op").and_then(Value::as_str) == Some("update")
            && last.get("id") == op.get("id")
            && let (Some(into), Some(from)) = (
                last.get_mut("props").and_then(Value::as_object_mut),
                op.get("props").and_then(Value::as_object),
            )
        {
            for (key, value) in from {
                into.insert(key.clone(), value.clone());
            }
            continue;
        }
        pending.push(op);
    }
}

/// Why an app was paused (for its log line and `run_state`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PauseCause {
    Timeouts,
    Memory,
    Slowed,
}

impl PauseCause {
    pub(super) fn describe(self) -> &'static str {
        match self {
            Self::Timeouts => "3 entry timeouts in 60 s",
            Self::Memory => "out of memory again after a restart",
            Self::Slowed => "Slowed for 60 s",
        }
    }
}

/// The app-wide part of the ladder: the VM kills that pause, and the pause.
#[derive(Debug, Default)]
pub(super) struct AppLadder {
    timeouts: VecDeque<Instant>,
    memory_kills: u32,
    pub paused: Option<PauseCause>,
    /// Scene batches the app sent and the host forwarded, over every mount
    /// since this daemon started (`apps.list` `scene_batches`; the perf
    /// gate's `section_chatty` reads them).
    pub batches_in: u64,
    pub batches_out: u64,
}

impl AppLadder {
    pub(super) fn batches_json(&self) -> Value {
        json!({ "in": self.batches_in, "out": self.batches_out })
    }

    /// An entry ran past its deadline (or the VM used up its CPU window).
    /// True when this pauses the app.
    pub(super) fn entry_timeout(&mut self, now: Instant) -> bool {
        while self.timeouts.front().is_some_and(|at| now.duration_since(*at) >= TIMEOUT_WINDOW) {
            self.timeouts.pop_front();
        }
        self.timeouts.push_back(now);
        if self.timeouts.len() >= TIMEOUTS_TO_PAUSE {
            return self.pause(PauseCause::Timeouts);
        }
        false
    }

    /// The VM ran out of memory. The first kill restarts it; the next pauses.
    pub(super) fn memory_kill(&mut self) -> bool {
        self.memory_kills = self.memory_kills.saturating_add(1);
        if self.memory_kills > 1 {
            return self.pause(PauseCause::Memory);
        }
        false
    }

    /// The host stayed up long enough to count as healthy: a later memory
    /// kill is a first one again.
    pub(super) fn healthy(&mut self) {
        self.memory_kills = 0;
    }

    pub(super) fn pause(&mut self, cause: PauseCause) -> bool {
        if self.paused.is_some() {
            return false;
        }
        self.paused = Some(cause);
        self.timeouts.clear();
        self.memory_kills = 0;
        true
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ResumeParams {
    app: String,
}

impl Supervisor {
    /// An app's step: Paused, else Slowed when any mount of it is, else Normal.
    pub(super) fn budget_step_locked(inner: &Inner, app: &str) -> Step {
        if inner.ladders.get(app).is_some_and(|l| l.paused.is_some()) {
            return Step::Paused;
        }
        let slowed =
            inner.mounts.values().any(|m| m.host.app == app && m.budget.step() == Step::Slowed);
        if slowed { Step::Slowed } else { Step::Normal }
    }

    /// One scene batch of `mount_key` at `now`, through its budget.
    pub(super) fn scene_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        mount_key: &MountKey,
        ops: Value,
        now: Instant,
    ) -> Vec<Out> {
        let ops = match ops {
            Value::Array(ops) => ops,
            other => vec![other],
        };
        let Some(record) = inner.mounts.get_mut(mount_key) else { return vec![] };
        let outcome = record.budget.offer(now, ops);
        let ladder = inner.ladders.entry(key.app.clone()).or_default();
        ladder.batches_in = ladder.batches_in.saturating_add(1);
        self.budget_outcome_locked(inner, key, mount_key, outcome)
    }

    /// The flush timer of `mount_key` fired.
    fn flush_fired(&self, mount_key: &MountKey) {
        let outs = {
            let mut inner = self.inner.lock().recover_poison();
            let Some(record) = inner.mounts.get_mut(mount_key) else { return };
            let key = record.host.clone();
            let outcome = record.budget.flush(Instant::now());
            self.budget_outcome_locked(&mut inner, &key, mount_key, outcome)
        };
        self.emit(outs);
    }

    fn budget_outcome_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        mount_key: &MountKey,
        outcome: Outcome,
    ) -> Vec<Out> {
        if outcome.pause {
            return self.pause_locked(inner, key, PauseCause::Slowed);
        }
        let mut outs = Vec::new();
        if let Some(step) = outcome.changed {
            let message = match step {
                Step::Slowed => format!(
                    "slowed: {} sends more than {MAX_RATE} scene updates a second; it gets 1 a second",
                    mount_key.mount_id
                ),
                _ => {
                    format!("{}: back under {MAX_RATE} scene updates a second", mount_key.mount_id)
                }
            };
            let level = if step == Step::Slowed { "warn" } else { "info" };
            outs.extend(self.log_locked(inner, &key.app, level, message));
            outs.push(Out::Client(
                mount_key.client,
                json!({ "event": "apps-budget", "mount_id": mount_key.mount_id, "app": key.app, "step": step.as_str() }),
            ));
        }
        if let Some(at) = outcome.flush_at {
            let me = self.me.clone();
            let timer_key = mount_key.clone();
            let after = at.saturating_duration_since(Instant::now());
            self.timers.schedule(after, move || {
                if let Some(me) = me.upgrade() {
                    me.flush_fired(&timer_key);
                }
            });
        }
        if let Some(ops) = outcome.deliver {
            if let Some(ladder) = inner.ladders.get_mut(&key.app) {
                ladder.batches_out = ladder.batches_out.saturating_add(1);
            }
            let mut event =
                json!({ "event": "apps-scene", "mount_id": mount_key.mount_id, "ops": ops });
            // The caller found the mount under this lock; a missing one has no reset.
            if inner
                .mounts
                .get_mut(mount_key)
                .is_some_and(|record| std::mem::take(&mut record.reset))
            {
                event.set("reset", Value::Bool(true));
            }
            outs.push(Out::Client(mount_key.client, event));
        }
        outs
    }

    /// The VM of `key` was killed for a limit: entry timeouts and memory
    /// kills count toward Paused.
    pub(super) fn vm_killed_locked(
        &self,
        inner: &mut Inner,
        key: &HostKey,
        reason: FatalReason,
        now: Instant,
    ) -> Vec<Out> {
        let ladder = inner.ladders.entry(key.app.clone()).or_default();
        let (pause, cause) = match reason {
            FatalReason::Interrupt | FatalReason::CpuBudget => {
                (ladder.entry_timeout(now), PauseCause::Timeouts)
            }
            FatalReason::Memory => (ladder.memory_kill(), PauseCause::Memory),
            FatalReason::Engine => (false, PauseCause::Timeouts),
        };
        if !pause {
            return vec![];
        }
        // `entry_timeout`/`memory_kill` set the cause; end the host.
        self.paused_locked(inner, key, cause)
    }

    /// Pauses `key`'s app for `cause` (no-op when it already is).
    fn pause_locked(&self, inner: &mut Inner, key: &HostKey, cause: PauseCause) -> Vec<Out> {
        if !inner.ladders.entry(key.app.clone()).or_default().pause(cause) {
            return vec![];
        }
        self.paused_locked(inner, key, cause)
    }

    /// The app was just paused: its mounts fail, its host ends, it stays off
    /// until Resume.
    fn paused_locked(&self, inner: &mut Inner, key: &HostKey, cause: PauseCause) -> Vec<Out> {
        let mut outs = self.log_locked(
            inner,
            &key.app,
            "error",
            format!("paused: {}. Resume starts it again (apps.resume)", cause.describe()),
        );
        outs.push(Out::Broadcast(
            json!({ "event": "apps-budget", "app": key.app, "step": Step::Paused.as_str(), "reason": cause.describe() }),
        ));
        outs.extend(self.end_host_locked(inner, key, PAUSED, "paused"));
        outs
    }

    /// `apps.resume {app}`: a paused app may start again (Normal, nothing
    /// counted). Any origin: an agent that fixed its app resumes it, and the
    /// ladder pauses it again if it is still over.
    pub(super) fn resume(&self, p: ResumeParams, origin: Origin) -> Result<Value, ApiError> {
        let outs = {
            let mut inner = self.inner.lock().recover_poison();
            if !inner.catalog.packages.contains_key(&p.app) {
                return Err(ApiError::new("apps.unknown", "no such app"));
            }
            let by = if origin == Origin::User { "you" } else { "an agent" };
            self.resume_locked(&mut inner, &p.app, &format!("by {by}"))
        };
        self.emit(outs);
        Ok(json!({ "app": p.app, "budget": Step::Normal.as_str() }))
    }

    /// Clears `app`'s pause; logs and tells clients when there was one.
    pub(super) fn resume_locked(&self, inner: &mut Inner, app: &str, why: &str) -> Vec<Out> {
        let Some(ladder) = inner.ladders.get_mut(app) else { return vec![] };
        let was = ladder.paused.take();
        *ladder = AppLadder {
            batches_in: ladder.batches_in,
            batches_out: ladder.batches_out,
            ..AppLadder::default()
        };
        if was.is_none() {
            return vec![];
        }
        let mut outs = self.log_locked(inner, app, "info", format!("resumed ({why})"));
        outs.push(Out::Broadcast(
            json!({ "event": "apps-budget", "app": app, "step": Step::Normal.as_str() }),
        ));
        outs
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn update(id: &str, text: &str) -> Vec<Value> {
        vec![json!({ "op": "update", "id": id, "props": { "text": text } })]
    }

    /// Sends `per_second` batches a second from `start` for `seconds`,
    /// firing flush timers when due. Returns (instant, ops) of each forward
    /// and the instant the mount went Slowed and was paused, if it did.
    struct Run {
        sent: Vec<(Instant, Vec<Value>)>,
        slowed_at: Option<Instant>,
        paused_at: Option<Instant>,
    }

    fn drive(budget: &mut MountBudget, start: Instant, per_second: u32, seconds: u32) -> Run {
        let mut run = Run { sent: Vec::new(), slowed_at: None, paused_at: None };
        let mut flush_at: Option<Instant> = None;
        let step = Duration::from_secs(1) / per_second;
        for i in 0..per_second * seconds {
            let now = start + step * i;
            if let Some(at) = flush_at.filter(|at| *at <= now) {
                flush_at = None;
                let out = budget.flush(at);
                if let Some(ops) = out.deliver {
                    run.sent.push((at, ops));
                }
                flush_at = flush_at.or(out.flush_at);
            }
            let out = budget.offer(now, update("clock", &i.to_string()));
            if out.changed == Some(Step::Slowed) {
                run.slowed_at.get_or_insert(now);
            }
            if out.pause {
                run.paused_at = Some(now);
                return run;
            }
            if let Some(ops) = out.deliver {
                run.sent.push((now, ops));
            }
            flush_at = flush_at.or(out.flush_at);
        }
        run
    }

    #[test]
    fn a_chatty_mount_is_slowed_within_5_s_then_gets_1_batch_a_second_then_pauses() {
        let start = Instant::now();
        let mut budget = MountBudget::default();
        let run = drive(&mut budget, start, 60, 70);
        let slowed = run.slowed_at.expect("60 batches a second reaches Slowed");
        // Over the rate from its first batch: Slowed 5 s later (one batch of slack).
        let took = slowed.duration_since(start);
        assert!(took >= SLOW_AFTER && took <= SLOW_AFTER + FRAME * 2, "Slowed at {took:?}");
        // Before Slowed: one per frame (60 Hz input is exactly frame rate).
        let before = run.sent.iter().filter(|(at, _)| *at < slowed).count();
        assert!(before >= 290, "forwarded {before} batches before Slowed");
        // Slowed: at most one forward in any second.
        let after: Vec<Instant> =
            run.sent.iter().filter(|(at, _)| *at > slowed).map(|(at, _)| *at).collect();
        assert!(!after.is_empty(), "a Slowed mount still updates");
        for pair in after.windows(2) {
            assert!(pair[1] - pair[0] >= SLOWED_INTERVAL, "{:?} apart", pair[1] - pair[0]);
        }
        // Each coalesced forward is one op: the rewritten row's last value.
        let (_, last) = run.sent.last().expect("forwards");
        assert_eq!(last.len(), 1);
        // Slowed for 60 s pauses the app.
        let paused = run.paused_at.expect("Slowed for 60 s pauses");
        assert_eq!(paused.duration_since(slowed).as_secs(), PAUSE_AFTER_SLOWED.as_secs());
        assert_eq!(budget.step(), Step::Slowed);
    }

    #[test]
    fn a_slowed_mount_back_under_the_rate_for_5_s_is_normal_again() {
        let start = Instant::now();
        let mut budget = MountBudget::default();
        let run = drive(&mut budget, start, 60, 6);
        assert!(run.slowed_at.is_some());
        let calm = start + Duration::from_secs(6);
        let mut changed = None;
        for i in 0..7 {
            let out = budget.offer(calm + Duration::from_secs(i), update("clock", "x"));
            changed = changed.or(out.changed);
        }
        assert_eq!(changed, Some(Step::Normal));
        assert_eq!(budget.step(), Step::Normal);
    }

    #[test]
    fn one_changed_row_under_budget_sends_one_update_op_at_once() {
        let start = Instant::now();
        let mut budget = MountBudget::default();
        for i in 0..20u32 {
            // 5 a second: well under the rate, each a frame or more apart.
            let now = start + Duration::from_millis(200) * i;
            let out = budget.offer(now, update("row-7", &i.to_string()));
            assert_eq!(out.deliver, Some(update("row-7", &i.to_string())));
            assert_eq!((out.flush_at, out.changed, out.pause), (None, None, false));
        }
        assert_eq!((budget.batches_in, budget.batches_out), (20, 20));
    }

    #[test]
    fn two_batches_in_one_frame_forward_once_in_order() {
        let start = Instant::now();
        let mut budget = MountBudget::default();
        assert!(budget.offer(start, update("a", "1")).deliver.is_some());
        let create = json!({ "op": "create", "id": "b", "type": "Text", "props": {} });
        let held = budget.offer(start + Duration::from_millis(2), vec![create.clone()]);
        assert_eq!(held.deliver, None);
        let at = held.flush_at.expect("a flush is armed");
        assert_eq!(at, start + FRAME);
        let again = budget.offer(start + Duration::from_millis(4), update("b", "2"));
        assert_eq!((again.deliver, again.flush_at), (None, None), "one timer for the frame");
        let flushed = budget.flush(at).deliver.expect("the frame forwards");
        assert_eq!(flushed, vec![create, update("b", "2")[0].clone()]);
    }

    #[test]
    fn merged_updates_keep_later_props_and_deletes() {
        let mut pending = Vec::new();
        append(
            &mut pending,
            vec![json!({ "op": "update", "id": "n", "props": { "a": 1, "b": 1 } })],
        );
        append(
            &mut pending,
            vec![json!({ "op": "update", "id": "n", "props": { "b": null, "c": 3 } })],
        );
        append(&mut pending, vec![json!({ "op": "remove", "id": "n" })]);
        append(&mut pending, vec![json!({ "op": "update", "id": "n", "props": { "a": 9 } })]);
        assert_eq!(
            pending,
            vec![
                json!({ "op": "update", "id": "n", "props": { "a": 1, "b": null, "c": 3 } }),
                json!({ "op": "remove", "id": "n" }),
                json!({ "op": "update", "id": "n", "props": { "a": 9 } }),
            ]
        );
    }

    #[test]
    fn three_entry_timeouts_in_60_s_pause_and_older_ones_do_not_count() {
        let start = Instant::now();
        let mut ladder = AppLadder::default();
        assert!(!ladder.entry_timeout(start));
        assert!(!ladder.entry_timeout(start + Duration::from_secs(30)));
        // The first fell out of the window: two in the last 60 s.
        assert!(!ladder.entry_timeout(start + Duration::from_secs(61)));
        assert!(ladder.entry_timeout(start + Duration::from_secs(62)));
        assert_eq!(ladder.paused, Some(PauseCause::Timeouts));
        // Paused once; more timeouts do not pause again.
        assert!(!ladder.entry_timeout(start + Duration::from_secs(63)));
    }

    #[test]
    fn a_memory_kill_after_a_restart_pauses_and_a_healthy_run_forgets_it() {
        let mut ladder = AppLadder::default();
        assert!(!ladder.memory_kill());
        ladder.healthy();
        assert!(!ladder.memory_kill());
        assert!(ladder.memory_kill());
        assert_eq!(ladder.paused, Some(PauseCause::Memory));
    }
}
