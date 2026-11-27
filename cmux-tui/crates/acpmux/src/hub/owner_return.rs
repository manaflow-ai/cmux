//! Part of `Hub`; see `hub/mod.rs`. The owner always wins on a machine enrolled in AutoCloud:
//! when its owner comes back to the keyboard, the work AutoCloud placed here gets out of the way.
//!
//! Off unless this machine is enrolled (`cloud.autoCloudEnroll`, `autocloud_enroll.rs`; off by
//! default). Off runs no timer; on runs one ([`Hub::start_owner_return`], at start and on each
//! config reload), which ends at the first enrollment read that says off, after resuming
//! anything it paused, or when the daemon stops.
//!
//! Every [`TICK`] the timer reads the owner's HID idle time and asks
//! `cmux_host_budget::owner_return::owner_return_plan` what to do to the sessions AutoCloud
//! placed here (`placedBy: "autoCloud"` in their meta). A placed session with no running turn
//! moves off through `session move --host auto`'s own steps (the same [`SessionMove`] automatic
//! evacuation uses, so no second authority over moves), with a note in its history first. One
//! mid-turn is paused: its harness's process group gets SIGSTOP, and SIGCONT once the owner is
//! away again or its turn ended so it can move. Nothing is killed or dropped.
//!
//! The measurement: one log line when the owner's return is detected (`owner_back_at_ms`) and
//! one when the machine is free of placed work (`freed_at_ms`, `elapsed_ms`), for p50/p95.

use super::auto_evacuate::{Mover, SessionMove};
use super::*;
use cmux_host_budget::owner_return::{
    Action, Placed, ReturnPlan, ReturnSetting, ReturnState, owner_return_plan,
};
use std::collections::{HashMap, HashSet};

/// The signal that pauses a placed agent's process group, and the one that continues it.
/// Unix only; elsewhere `signal_placed` sends nothing, so the values are never used.
#[cfg(unix)]
const PAUSE: i32 = libc::SIGSTOP;
#[cfg(unix)]
const CONTINUE: i32 = libc::SIGCONT;
#[cfg(not(unix))]
const PAUSE: i32 = 0;
#[cfg(not(unix))]
const CONTINUE: i32 = 0;

/// How often the timer looks: the owner's return should free the machine within seconds.
pub(crate) const TICK: std::time::Duration = std::time::Duration::from_secs(2);

/// Enrollment is re-read every this many ticks (a settings file read).
const ENROLL_EVERY: u32 = 15;

/// The note's kind in a chat's history.
pub(crate) const NOTE_KIND: &str = "owner_return";

/// Whether the timer runs (one per daemon).
static RUNNING: AtomicBool = AtomicBool::new(false);

/// What the timer keeps between ticks.
#[derive(Default)]
pub(crate) struct Returner {
    state: ReturnState,
    /// Sessions whose agent's process group this timer stopped.
    paused: HashSet<String>,
    /// When each session was last moved or tried, in hub-clock ms.
    tried: HashMap<String, u64>,
    /// When the owner's return was detected, until the machine is free.
    back_at_ms: Option<u64>,
}

impl Returner {
    /// One tick: plan and carry the plan out.
    pub(crate) async fn tick(
        &mut self,
        hub: &Hub,
        enrolled: bool,
        idle: Option<f64>,
        mover: &dyn Mover,
    ) -> ReturnPlan {
        let now = hub.clock_now() / 1_000_000;
        let setting = ReturnSetting::default();
        let cooldown_ms = setting.cooldown_secs.saturating_mul(1000);
        self.tried.retain(|_, at| now.saturating_sub(*at) < cooldown_ms);
        let (paused, tried) = (&self.paused, &self.tried);
        let plan = owner_return_plan(
            &mut self.state,
            enrolled,
            idle,
            || hub.placed_sessions(paused, tried),
            &setting,
            now,
        );
        if plan.returned {
            self.back_at_ms = Some(now);
            tracing::info!(
                owner_back_at_ms = now, why = %plan.why,
                "autoCloud: the owner is back; placed work leaves or pauses"
            );
        }
        for action in &plan.actions {
            match action {
                Action::Pause { id } => {
                    if hub.signal_placed(id, PAUSE).await {
                        self.paused.insert(id.clone());
                        tracing::info!(session = %id, "autoCloud: paused a placed turn for the owner");
                    }
                }
                Action::Resume { id } => {
                    hub.signal_placed(id, CONTINUE).await;
                    self.paused.remove(id);
                    tracing::info!(session = %id, "autoCloud: resumed a paused placed session");
                }
                Action::Move { id, name } => {
                    self.tried.insert(id.clone(), now);
                    hub.owner_return_move(id, name, &plan, mover).await;
                }
            }
        }
        if plan.freed
            && let Some(at) = self.back_at_ms.take()
        {
            let freed_at = hub.clock_now() / 1_000_000;
            tracing::info!(
                owner_back_at_ms = at,
                freed_at_ms = freed_at,
                elapsed_ms = freed_at.saturating_sub(at),
                "autoCloud: this machine is free of placed work for its owner"
            );
        }
        if !self.state.back() {
            self.back_at_ms = None;
        }
        plan
    }
}

impl Hub {
    /// Starts the timer when this machine is enrolled in AutoCloud and none runs (module docs).
    pub(crate) async fn start_owner_return(self: &Arc<Self>) {
        if !crate::autocloud_enroll::Enrollment::read().enabled {
            return;
        }
        if RUNNING.swap(true, Ordering::SeqCst) {
            return;
        }
        tracing::info!("autoCloud enrollment is on: placed work yields when the owner comes back");
        // A daemon restart may have left a placed agent stopped: continue each one.
        for s in self.live_session_handles() {
            if s.read_meta(|m| m.placed_by.is_some()) {
                self.signal_placed(&s.id, CONTINUE).await;
            }
        }
        let weak = Arc::downgrade(self);
        self.scope.spawn_until_cancelled("owner-return", async move {
            owner_return_loop(weak, &SessionMove).await;
            RUNNING.store(false, Ordering::SeqCst);
        });
    }

    /// The live AutoCloud-placed sessions here, as the plan reads them.
    fn placed_sessions(
        &self,
        paused: &HashSet<String>,
        tried: &HashMap<String, u64>,
    ) -> Vec<Placed> {
        self.live_session_handles()
            .iter()
            .filter_map(|s| {
                let (name, placed, gone) =
                    s.read_meta(|m| (m.name.clone(), m.placed_by.is_some(), m.moved_to.is_some()));
                if !placed || gone {
                    return None;
                }
                Some(Placed {
                    id: s.id.clone(),
                    name,
                    running: s.turn().is_some() || s.turn_claimed() || s.queued() > 0,
                    paused: paused.contains(&s.id),
                    moving: s.moving().is_some(),
                    tried_at_ms: tried.get(&s.id).copied(),
                })
            })
            .collect()
    }

    /// Sends `signal` to a session's agent's process group; false when it has no live agent.
    #[cfg(unix)]
    async fn signal_placed(&self, id: &str, signal: i32) -> bool {
        let Some(session) = self.session_get(id) else { return false };
        let child = session.child.lock().await.clone();
        match child {
            Some(agent) => agent.signal_harness_group(signal).await,
            None => false,
        }
    }

    /// No process groups to stop off Unix: a placed session is never paused there, only moved.
    #[cfg(not(unix))]
    async fn signal_placed(&self, _id: &str, _signal: i32) -> bool {
        false
    }

    /// The note, the move and the log line for one placed session leaving for its owner.
    async fn owner_return_move(&self, id: &str, name: &str, plan: &ReturnPlan, mover: &dyn Mover) {
        let Some(session) = self.session_get(id) else { return };
        let text = format!(
            "Moved off this machine automatically: {}, and AutoCloud placed this chat here only \
             while the owner was away.",
            plan.why
        );
        self.append(&session, "mux", NOTE_KIND, json!({"text": text, "why": plan.why}));
        match mover.move_off(id).await {
            Ok(host) => tracing::info!(
                session = %id, name = %name, to = %host,
                "autoCloud: moved a placed chat off for the returning owner"
            ),
            Err(why_not) => {
                tracing::warn!(
                    session = %id, name = %name, error = %why_not,
                    "autoCloud: a placed chat did not move; it stays here idle"
                );
                self.append(
                    &session,
                    "mux",
                    NOTE_KIND,
                    json!({"text": format!("It stayed on this machine: {why_not}"),
                           "failed": why_not}),
                );
            }
        }
    }
}

/// The timer: a tick every [`TICK`] until enrollment is off or the daemon stops.
pub(crate) async fn owner_return_loop(weak: std::sync::Weak<Hub>, mover: &dyn Mover) {
    let mut every = tokio::time::interval(TICK);
    every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut returner = Returner::default();
    let mut ticks: u32 = 0;
    loop {
        every.tick().await;
        let enrolled = ticks % ENROLL_EVERY != 0 || {
            tokio::task::spawn_blocking(|| crate::autocloud_enroll::Enrollment::read().enabled)
                .await
                .unwrap_or(true)
        };
        ticks = ticks.wrapping_add(1);
        let idle = cmux_host_budget::owner_idle_seconds();
        let Some(hub) = weak.upgrade() else { return };
        if hub.stopping.load(Ordering::SeqCst) {
            return;
        }
        // Off: this tick resumes whatever it paused, then the timer ends.
        returner.tick(&hub, enrolled, idle, mover).await;
        if !enrolled {
            tracing::info!("autoCloud enrollment is off: the owner-return timer ends");
            return;
        }
    }
}

#[cfg(test)]
#[path = "owner_return_tests.rs"]
mod tests;
