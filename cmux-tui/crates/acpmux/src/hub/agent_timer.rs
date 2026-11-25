//! A timer the agent set keeps its machine up until it fires (wake kind 4 of the pause-resume
//! lane, cmuxterm-hq RFD 0017).
//!
//! Claude Code runs a /loop on timers in its own process: a self-paced loop's ScheduleWakeup and
//! an interval loop's CronCreate (`claude_stdio/loops.rs`, which lists them in the chat's goal as
//! `timers`). Between two runs no turn is open, so before this the chat counted as idle twice
//! over: acpmux's idle reaper ended Claude after 2 minutes (`idle.rs`), which ended the loop with
//! it, and the Cloud activity report said 0 sessions at work (`daemon/cloud_activity.rs`), so the
//! Cloud paused the machine and nothing resumed it at the due time: the run came only when
//! something else woke the machine, however late.
//!
//! The timers are what the live agent itself last said (`Session::loop_timers`, from its goal
//! updates), not the chat's saved goal: a `goal_set` over an armed loop replaces the goal but not
//! the loop, and a goal restored after a reboot names timers no process holds.
//!
//! Now a live agent with a timer pending is at work and never hibernated:
//! - A one-shot wakeup is pending until [`FIRE_GRACE`] after its time: the agent is up (it was
//!   kept), so it fires on time and its turn holds the session from then on. A wakeup that does
//!   not re-arm frees the chat once the grace is over.
//! - A recurring cron is pending while armed. Its next fire is known only until its first one
//!   (Claude names `nextFireAt` at the create), so after that the report names none.
//!
//! The Cloud report names the session's phase `timer` and, where known, the next due time
//! (`wake_at`, Unix ms). The Cloud reads any phase but `model-wait` as awake and pauses no
//! machine with a session at work, so a pending timer's machine is not paused before the timer
//! fires: it fires no later than its due time plus the agent's own timer slack. A guest's clocks
//! run on through a Freestyle pause (RFD 0017, `/proc/uptime` measured), so a timer that came due
//! during a pause some other wake ended fires at the resume, once, not twice.

use super::*;

/// How long after its due time a one-shot wakeup still counts as pending: its agent is up, so it
/// fires well inside this, and its turn holds the session from then on.
pub(crate) const FIRE_GRACE_MS: u64 = 60_000;

/// The timer `session`'s agent holds, as of `now_ms` (Unix ms).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PendingTimer {
    /// The earliest due time still ahead, or None when one pending timer's is not known (the
    /// machine must stay up for it).
    pub wake_at: Option<u64>,
}

/// The pending timers in a loop goal (`claude_stdio/loops.rs`): one per armed loop.
fn timers(goal: &Value) -> Vec<(Option<u64>, bool)> {
    let read =
        |t: &Value| (t.get("at").and_then(Value::as_u64), t.get("recurring") == Some(&json!(true)));
    match goal.get("timers").and_then(Value::as_array) {
        Some(list) => list.iter().map(read).collect(),
        // A loop from an agent that names no list: its own next run, recurring when it has a
        // schedule.
        None => {
            vec![(goal.get("nextRunAt").and_then(Value::as_u64), goal.get("schedule").is_some())]
        }
    }
}

/// The agent's goal update (`permissions.rs` `on_update`): a loop arms its timers, anything else
/// it sends (a clear at its last loop's stop, a goal of its own) disarms them. Only the agent
/// says this: `goal_set` and the hub's own clears never come through here, so a goal the chat
/// set over an armed loop no longer hides the loop's timers.
pub(super) fn note_agent_goal(session: &Session, goal: &Value) {
    let looping = goal.get("kind").and_then(Value::as_str) == Some("loop");
    *session.loop_timers.lock().unwrap_or_else(|e| e.into_inner()) = looping.then(|| timers(goal));
}

impl Hub {
    /// The timer `session`'s live agent holds at `now_ms`, or None (module docs).
    pub(crate) fn pending_timer(&self, session: &Session, now_ms: u64) -> Option<PendingTimer> {
        // Claude's timers live in its process: none without one (its exit clears the loop).
        let live = session.child.try_lock().map(|c| c.is_some()).unwrap_or(true);
        if !live {
            return None;
        }
        // What this daemon heard from the agent, never the saved goal: a goal restored after a
        // reboot names timers no process holds any more, and would keep the machine up forever.
        let timers = session.loop_timers.lock().unwrap_or_else(|e| e.into_inner()).clone()?;
        let mut pending = false;
        let mut wake_at: Option<u64> = None;
        let mut unknown = false;
        for (at, recurring) in timers {
            match (at, recurring) {
                // A wakeup past its grace fired (or never will): it holds nothing.
                (Some(at), false) if at.saturating_add(FIRE_GRACE_MS) <= now_ms => continue,
                (Some(at), _) if at > now_ms => wake_at = Some(wake_at.map_or(at, |w| w.min(at))),
                // Due now, a cron past its known fire, or a time never said.
                _ => unknown = true,
            }
            pending = true;
        }
        pending.then_some(PendingTimer { wake_at: if unknown { None } else { wake_at } })
    }
}

#[cfg(all(test, unix))]
#[path = "agent_timer_tests.rs"]
mod tests;
