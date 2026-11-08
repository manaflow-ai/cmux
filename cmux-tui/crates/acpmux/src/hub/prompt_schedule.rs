//! Part of `Hub`; see `hub/mod.rs`. A chat's scheduled prompt (`crate::prompt_schedule`) runs
//! here: cmux's own `/loop`, which works the same for every harness.
//!
//! The schedule lives in the chat's record (`SessionMeta::prompt_schedule`), so it outlives a
//! daemon restart: `resume_queues` reads every record's at start (`restore_prompt_schedules`).
//! Each change is saved and logged as a `session_info_update` carrying `_meta.schedule` (null
//! once it ends), which every client of the chat hears, the strip over its composer included.
//!
//! A run goes in through `prompt_with`, the person's own path, named `schedule` in its
//! provenance. A run that falls due while the chat is busy (a turn, a queue, a question) waits
//! for the chat to be free: the end of a turn wakes the timer (`prompt_schedule_turn_ended`),
//! which looks again `SETTLE_MS` later, once the turn's own wrap-up and whatever it queued have
//! started. So one run at most is ever waiting, never a queue of them.
//!
//! One task per hub waits on the hub clock for the earliest run and on a wake signal for a
//! change. It looks at a busy chat again every `BUSY_RECHECK_MS` only while that chat's run is
//! due and waiting, and stops once the run went. It sleeps at most `MAX_SLEEP_MS` at a time while any schedule waits
//! (a monotonic wait does not run while the machine sleeps, and the schedule is wall-clock),
//! sleeps without a deadline when no chat has one, and ends with the hub or once shutdown starts.
//! It reads only the chats that have a schedule (`Scheduler::chats`), never every chat.

use super::*;
use crate::prompt_schedule::{PromptSchedule, Request};
use std::collections::{HashMap, HashSet};

/// After a turn ends, how long the timer waits before it looks at the chat again.
pub(super) const SETTLE_MS: u64 = 2_000;
/// While a due run waits for a busy chat, how often the timer looks at the chat again.
pub(super) const BUSY_RECHECK_MS: u64 = 15_000;
/// The longest single wait, so a wall-clock run is at most this late after the machine wakes.
pub(super) const MAX_SLEEP_MS: u64 = 60_000;
/// Sends refused in a row (a folder no longer trusted, a harness that will not start) before the
/// schedule ends: each refused run is given back and tried again `BUSY_RECHECK_MS` later.
pub(super) const MAX_REFUSALS: u32 = 3;

/// Wall-clock milliseconds since the epoch; tests replace it.
pub(super) type WallClock = Arc<dyn Fn() -> u64 + Send + Sync>;

pub(crate) struct Scheduler {
    wake: Arc<Notify>,
    running: AtomicBool,
    /// The chats with a schedule, by session id.
    chats: StdMutex<HashSet<String>>,
    /// A chat whose turn just ended, and when to look at it again.
    settle: StdMutex<HashMap<String, u64>>,
    /// A chat's sends refused in a row, cleared by one that goes in.
    refused: StdMutex<HashMap<String, u32>>,
    wall: StdMutex<WallClock>,
}

impl Default for Scheduler {
    fn default() -> Self {
        Self {
            wake: Arc::new(Notify::new()),
            running: AtomicBool::new(false),
            chats: StdMutex::default(),
            settle: StdMutex::default(),
            refused: StdMutex::default(),
            wall: StdMutex::new(Arc::new(crate::store::now_ms)),
        }
    }
}

fn locked<T>(m: &StdMutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Hub {
    pub(super) fn schedule_now(&self) -> u64 {
        let wall = locked(&self.prompt_schedules.wall).clone();
        wall()
    }

    #[cfg(test)]
    pub(super) fn set_schedule_wall(&self, wall: WallClock) {
        *locked(&self.prompt_schedules.wall) = wall;
    }

    /// `_acpmux/schedule/set`: the chat's schedule, replacing the one it had.
    /// `trust_gate`: it came from a folder-trust-gated connection (the app's pane), so each run
    /// is checked against the folder's trust again when it is sent, as a queued prompt is.
    pub(crate) fn schedule_set(
        self: &Arc<Self>,
        session: &Arc<Session>,
        req: Request,
        trust_gate: bool,
    ) -> Result<Value, RpcError> {
        let now = self.schedule_now();
        let id = format!("sch-{}", uuid::Uuid::new_v4().simple());
        let mut schedule = PromptSchedule::new(id, req, now).map_err(RpcError::invalid_params)?;
        schedule.trust_gate = trust_gate;
        let value = schedule.to_value();
        locked(&session.meta).prompt_schedule = Some(schedule);
        locked(&self.prompt_schedules.refused).remove(&session.id);
        self.publish_schedule(session)?;
        locked(&self.prompt_schedules.chats).insert(session.id.clone());
        self.wake_scheduler();
        Ok(value)
    }

    /// `_acpmux/schedule/pause {paused}`: the schedule's answer, null when the chat has none.
    pub(crate) fn schedule_pause(
        self: &Arc<Self>,
        session: &Arc<Session>,
        paused: bool,
    ) -> Result<Value, RpcError> {
        let now = self.schedule_now();
        let value = {
            let mut m = locked(&session.meta);
            let Some(schedule) = m.prompt_schedule.as_mut() else { return Ok(Value::Null) };
            schedule.set_paused(paused, now);
            schedule.to_value()
        };
        self.publish_schedule(session)?;
        self.wake_scheduler();
        Ok(value)
    }

    /// `_acpmux/schedule/clear`: whether the chat had one.
    pub(crate) fn schedule_clear(&self, session: &Session) -> Result<bool, RpcError> {
        let had = locked(&session.meta).prompt_schedule.take().is_some();
        locked(&self.prompt_schedules.chats).remove(&session.id);
        if had {
            self.publish_schedule(session)?;
        }
        Ok(had)
    }

    pub(crate) fn schedule_get(&self, session: &Session) -> Value {
        locked(&session.meta).prompt_schedule.as_ref().map_or(Value::Null, PromptSchedule::to_value)
    }

    /// Saves the chat's schedule, durably before it answers, and tells its clients, as one
    /// `session_info_update`. A failed save tells no one and fails the caller.
    fn publish_schedule(&self, session: &Session) -> Result<(), RpcError> {
        let (sid, schedule) = {
            let m = locked(&session.meta);
            (
                m.agent_session_id.clone().unwrap_or_else(|| session.id.clone()),
                m.prompt_schedule.as_ref().map_or(Value::Null, PromptSchedule::to_value),
            )
        };
        self.save_meta_answered(session)?;
        let update =
            json!({"sessionUpdate": "session_info_update", "_meta": {"schedule": schedule}});
        let msg = json!({"jsonrpc": "2.0", "method": "session/update",
                         "params": {"sessionId": sid, "update": update}});
        self.append(session, "in", "session_info_update", msg);
        Ok(())
    }

    /// `publish_schedule` for a change no request waits on: a failed save is logged.
    fn publish_schedule_logged(&self, session: &Session) {
        if let Err(e) = self.publish_schedule(session) {
            tracing::warn!(session = %session.id, error = %e.message, "scheduled prompt not saved");
        }
    }

    /// At daemon start: the chats whose record holds a schedule.
    pub(super) fn restore_prompt_schedules(self: &Arc<Self>) {
        let found: Vec<String> = self
            .sessions()
            .iter()
            .filter(|s| locked(&s.meta).prompt_schedule.is_some())
            .map(|s| s.id.clone())
            .collect();
        if found.is_empty() {
            return;
        }
        locked(&self.prompt_schedules.chats).extend(found);
        self.wake_scheduler();
    }

    /// A turn of `session` ended: an `idle` schedule counts its grace from now, and a run that
    /// waited for the chat looks again shortly. Costs nothing for a chat with no schedule.
    pub(super) fn prompt_schedule_turn_ended(self: &Arc<Self>, session: &Arc<Session>) {
        if !locked(&self.prompt_schedules.chats).contains(&session.id) {
            return;
        }
        let now = self.schedule_now();
        let changed =
            locked(&session.meta).prompt_schedule.as_mut().is_some_and(|s| s.turn_ended(now));
        if changed {
            self.publish_schedule_logged(session);
        }
        locked(&self.prompt_schedules.settle).insert(session.id.clone(), now + SETTLE_MS);
        self.wake_scheduler();
    }

    pub(super) fn wake_scheduler(self: &Arc<Self>) {
        if !self.prompt_schedules.running.swap(true, Ordering::SeqCst) {
            let weak = Arc::downgrade(self);
            let wake = self.prompt_schedules.wake.clone();
            tokio::spawn(async move { Self::scheduler_loop(weak, wake).await });
        }
        self.prompt_schedules.wake.notify_one();
    }

    async fn scheduler_loop(weak: std::sync::Weak<Self>, wake: Arc<Notify>) {
        loop {
            let (next, now, clock) = {
                let Some(hub) = weak.upgrade() else { return };
                if hub.stopping.load(Ordering::SeqCst) {
                    return;
                }
                let now = hub.schedule_now();
                let next = hub.run_due_schedules(now);
                (next, now, hub.clock.lock().unwrap_or_else(|e| e.into_inner()).clone())
            };
            match next {
                Some(at) => {
                    let wait = at.saturating_sub(now).clamp(1, MAX_SLEEP_MS);
                    let deadline = clock.now() + std::time::Duration::from_millis(wait);
                    tokio::select! {
                        _ = clock.sleep_until(deadline) => {}
                        _ = wake.notified() => {}
                    }
                }
                None => wake.notified().await,
            }
        }
    }

    /// Ends finished schedules, sends the runs due at `now` to the chats free for them, and
    /// answers when to look next.
    pub(super) fn run_due_schedules(self: &Arc<Self>, now: u64) -> Option<u64> {
        let ids: Vec<String> = locked(&self.prompt_schedules.chats).iter().cloned().collect();
        let mut next: Option<u64> = None;
        let mut soonest = |at: u64| next = Some(next.map_or(at, |n| n.min(at)));
        for id in ids {
            let Ok(session) = self.resolve(&id) else {
                locked(&self.prompt_schedules.chats).remove(&id);
                continue;
            };
            if session.id != id || matches!(session.status(), SessionStatus::Closed) {
                locked(&self.prompt_schedules.chats).remove(&id);
                continue;
            }
            let settling = {
                let mut settle = locked(&self.prompt_schedules.settle);
                match settle.get(&id).copied() {
                    Some(at) if at > now => Some(at),
                    Some(_) => {
                        settle.remove(&id);
                        None
                    }
                    None => None,
                }
            };
            let (finished, due, deadline) = {
                let m = locked(&session.meta);
                let Some(s) = m.prompt_schedule.as_ref() else {
                    drop(m);
                    locked(&self.prompt_schedules.chats).remove(&id);
                    continue;
                };
                (s.finished(now), s.due(now), s.deadline(now))
            };
            if finished {
                self.end_schedule(&session, "finished");
                continue;
            }
            if let Some(at) = deadline {
                soonest(at);
            }
            if !due {
                continue;
            }
            if let Some(at) = settling {
                soonest(at);
                continue;
            }
            // Busy: the end of its turn wakes this timer again, and it looks again every
            // `BUSY_RECHECK_MS` while the run waits, for a chat freed another way (a queued
            // prompt removed, a permission answered after its turn). It stops once the run went.
            if !self.free_for_schedule(&session) {
                soonest(now + BUSY_RECHECK_MS);
                continue;
            }
            if let Some(at) = self.fire_schedule(&session, now) {
                soonest(at);
            }
        }
        next
    }

    /// Whether nothing runs, waits or asks in the chat, so a scheduled run starts at once rather
    /// than joining a queue.
    fn free_for_schedule(&self, session: &Session) -> bool {
        // Idle (hibernated) and Disconnected chats start their agent for it, as for a person's.
        matches!(
            session.status(),
            SessionStatus::Ready | SessionStatus::Idle | SessionStatus::Disconnected
        ) && session.turn().is_none()
            && !session.harness_turn.load(Ordering::SeqCst)
            && session.queued() == 0
            && session.pending_permissions().is_empty()
            && !self.continuation_pending(session)
    }

    /// Sends one run, counting it first, so a restart mid-send never sends it twice. A send
    /// that is refused gives its run back (`schedule_refused`). The schedule's next run, if it
    /// has one.
    fn fire_schedule(self: &Arc<Self>, session: &Arc<Session>, now: u64) -> Option<u64> {
        let (before, id, run, prompt, next, done, trust_gate) = {
            let mut m = locked(&session.meta);
            let s = m.prompt_schedule.as_mut()?;
            let before = s.clone();
            s.fire(now);
            let done = s.finished(now);
            let fired = (
                before,
                s.id.clone(),
                s.runs,
                s.prompt.clone(),
                s.deadline(now),
                done,
                s.trust_gate,
            );
            if done {
                m.prompt_schedule = None;
            }
            fired
        };
        if done {
            locked(&self.prompt_schedules.chats).remove(&session.id);
        }
        // The run is counted on disk before it goes, so a restart never sends it twice; one that
        // could not be counted is not sent.
        if let Err(e) = self.publish_schedule(session) {
            tracing::warn!(session = %session.id, schedule = %id, run, error = %e.message,
                "scheduled prompt not sent: its run could not be saved");
            return if done { None } else { next };
        }
        tracing::info!(session = %session.id, schedule = %id, run, "scheduled prompt sent");
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            let blocks = vec![json!({"type": "text", "text": prompt})];
            let opts = PromptOptions {
                prompt_id: Some(format!("{id}-run-{run}")),
                provenance: Some(json!({"kind": "schedule", "scheduleId": id, "run": run})),
                trust_gate,
                ..PromptOptions::default()
            };
            match hub.prompt_with(&session, blocks, "acpmux", false, opts).await {
                Ok(_) => {
                    locked(&hub.prompt_schedules.refused).remove(&session.id);
                }
                Err(e) => {
                    tracing::warn!(session = %session.id, schedule = %id, run, error = %e.message,
                        "scheduled prompt refused");
                    hub.schedule_refused(&session, before, done);
                }
            }
        });
        if done { None } else { next }
    }

    /// A run's send was refused: the run is given back, to go again `BUSY_RECHECK_MS` from now,
    /// unless the schedule changed since it went (replaced, paused, cleared) or this is the
    /// `MAX_REFUSALS`th refusal in a row, which ends it. `before`: the schedule as it was before
    /// the run; `done`: whether that run ended it.
    pub(super) fn schedule_refused(
        self: &Arc<Self>,
        session: &Arc<Session>,
        before: PromptSchedule,
        done: bool,
    ) {
        let refusals = {
            let mut refused = locked(&self.prompt_schedules.refused);
            let n = refused.entry(session.id.clone()).or_insert(0);
            *n += 1;
            *n
        };
        let given_back = {
            let mut m = locked(&session.meta);
            let unchanged = match m.prompt_schedule.as_ref() {
                Some(s) => {
                    s.id == before.id && s.runs == before.runs.saturating_add(1) && !s.paused
                }
                None => done,
            };
            if !unchanged {
                return;
            }
            if refusals >= MAX_REFUSALS {
                false
            } else {
                let mut s = before;
                s.next_run_at = Some(self.schedule_now() + BUSY_RECHECK_MS);
                m.prompt_schedule = Some(s);
                true
            }
        };
        if !given_back {
            locked(&self.prompt_schedules.refused).remove(&session.id);
            self.end_schedule(session, "refused");
            return;
        }
        locked(&self.prompt_schedules.chats).insert(session.id.clone());
        self.publish_schedule_logged(session);
        self.wake_scheduler();
    }

    fn end_schedule(&self, session: &Session, reason: &str) {
        let ended = locked(&session.meta).prompt_schedule.take();
        locked(&self.prompt_schedules.chats).remove(&session.id);
        locked(&self.prompt_schedules.refused).remove(&session.id);
        if let Some(s) = ended {
            tracing::info!(session = %session.id, schedule = %s.id, runs = s.runs, reason,
                "scheduled prompt ended");
            self.publish_schedule_logged(session);
        }
    }
}
