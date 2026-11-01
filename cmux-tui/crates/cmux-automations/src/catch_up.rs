//! What to do with scheduled times a sleeping or switched-off machine missed.

use serde::{Deserialize, Serialize};

use crate::trigger::{ScheduleError, Trigger};

/// A fire this close to its scheduled time is on time, not a catch-up. The
/// runner ticks every 30 s, so a normal fire is well inside it.
pub const ON_TIME_SECONDS: i64 = 120;

/// Skip rows kept per tick; older skips are only counted.
const MAX_SKIP_ROWS: usize = 50;

/// Due times looked at per tick before the oldest are only counted (a
/// one-minute schedule asleep for about two years).
const MAX_SCAN: usize = 1_000_000;

/// The catch-up policy of one automation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "policy", rename_all = "snake_case")]
pub enum CatchUp {
    /// One run for the newest missed time when it is within `window_seconds`;
    /// the older ones are recorded as `superseded`, a newest one outside the
    /// window as `stale`.
    Latest { window_seconds: u64 },
    /// One run per missed time, the newest `max`, oldest first.
    All { max: u32 },
    /// Late times are recorded as `machine_asleep` and never run.
    None,
}

impl Default for CatchUp {
    fn default() -> Self {
        CatchUp::Latest { window_seconds: 24 * 3_600 }
    }
}

/// The plan for one tick of one automation.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FirePlan {
    /// Scheduled times to run, oldest first.
    pub run: Vec<i64>,
    /// Scheduled times recorded as skipped, with the reason, oldest first.
    pub skipped: Vec<(i64, String)>,
    /// Skipped times beyond the rows kept.
    pub skipped_uncounted: u64,
    /// The cursor to store: every time up to here is handled.
    pub handled_through: i64,
}

/// The due times in `(since, now]` and what to do with each.
pub fn plan_fires(
    trigger: &Trigger,
    since: i64,
    now: i64,
    policy: CatchUp,
) -> Result<FirePlan, ScheduleError> {
    let mut due = std::collections::VecDeque::new();
    let mut uncounted = 0u64;
    let mut cursor = since;
    while let Some(t) = trigger.next_after(cursor)? {
        if t > now {
            break;
        }
        due.push_back(t);
        if due.len() > MAX_SCAN {
            due.pop_front();
            uncounted += 1;
        }
        cursor = t;
    }
    let due: Vec<i64> = due.into();
    let mut plan = FirePlan { handled_through: now.max(since), ..FirePlan::default() };
    let skip = |t: i64, why: &str, plan: &mut FirePlan| plan.skipped.push((t, why.to_string()));
    match policy {
        CatchUp::Latest { window_seconds } => {
            if let Some((&newest, older)) = due.split_last() {
                for &t in older {
                    skip(t, "superseded", &mut plan);
                }
                if now - newest <= window_seconds as i64 || now - newest <= ON_TIME_SECONDS {
                    plan.run.push(newest);
                } else {
                    skip(newest, "stale", &mut plan);
                }
            }
        }
        CatchUp::All { max } => {
            let keep = due.len().saturating_sub(max as usize);
            for (i, &t) in due.iter().enumerate() {
                if i < keep {
                    skip(t, "superseded", &mut plan);
                } else {
                    plan.run.push(t);
                }
            }
        }
        CatchUp::None => {
            for &t in &due {
                if now - t <= ON_TIME_SECONDS {
                    plan.run.push(t);
                } else {
                    skip(t, "machine_asleep", &mut plan);
                }
            }
        }
    }
    if plan.skipped.len() > MAX_SKIP_ROWS {
        let drop = plan.skipped.len() - MAX_SKIP_ROWS;
        plan.skipped.drain(..drop);
        uncounted += drop as u64;
    }
    plan.skipped_uncounted = uncounted;
    Ok(plan)
}
