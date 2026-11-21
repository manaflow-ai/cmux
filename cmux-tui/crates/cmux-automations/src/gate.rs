//! Between a trigger and a run: the condition script and the guardrails
//! (cmuxterm-hq docs/automation-triggers.md).
//!
//! A fire (a due time, a watch event, a manual run) becomes a run only when
//! the guardrails let it: no run of the automation is live, its cooldown is
//! over and its daily cap is not reached. The condition script runs later, in
//! the run's own process ([`crate::exec::run_job`]), so a slow script never
//! holds the runner.

use serde::{Deserialize, Serialize};

use crate::run::{Run, RunState};

/// The most event text a run keeps; the rest is cut and counted.
pub const MAX_EVENT_BYTES: usize = 16 * 1024;

/// How long a condition script may take before the run fails.
pub const CONDITION_TIMEOUT_SECONDS: u64 = 60;

/// The window of the daily cap.
const DAY_SECONDS: i64 = 86_400;

fn is_zero(n: &u64) -> bool {
    *n == 0
}

/// The condition and guardrails of one automation. The default is none: a
/// fire runs unless a run of it is still live.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Gate {
    /// `--if`: a shell command run before the body. Exit 0 runs the body and
    /// its output joins the prompt; exit 1 skips the run; anything else fails it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
    /// After a run starts, fires are dropped (watch) or skipped (schedule)
    /// for this long.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub cooldown_seconds: u64,
    /// At most this many runs start in any 24 hours.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_runs_per_day: Option<u32>,
}

/// Whether a fire may start a run now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Go,
    /// A run of this automation is still live.
    Busy {
        run: String,
    },
    /// The cooldown after the last run ends at `until`.
    Cooldown {
        until: i64,
    },
    /// `max` runs started in the last 24 hours; the oldest of them leaves the
    /// window at `until`.
    Cap {
        max: u32,
        until: i64,
    },
}

impl Verdict {
    /// The run row reason of a fire this verdict stops: `previous_run_running`,
    /// `cooldown` or `cap_reached`.
    pub fn reason(&self) -> Option<&'static str> {
        match self {
            Verdict::Go => None,
            Verdict::Busy { .. } => Some("previous_run_running"),
            Verdict::Cooldown { .. } => Some("cooldown"),
            Verdict::Cap { .. } => Some("cap_reached"),
        }
    }
}

/// Whether `r` started its body: running, or ended after it started. A skip,
/// a run whose process never started, and a run whose condition said no or
/// failed, did not.
pub fn fired(r: &Run) -> bool {
    let stopped = r
        .reason
        .as_deref()
        .is_some_and(|why| why.starts_with("condition_") || why.starts_with("start_failed"));
    matches!(r.state, RunState::Running | RunState::Succeeded | RunState::Failed)
        && r.started_at.is_some()
        && !stopped
}

/// The verdict for a fire of an automation with `gate` and run `history` at
/// `now`. `alive` says whether a run's process still runs.
pub fn verdict(gate: &Gate, history: &[Run], now: i64, alive: &dyn Fn(u32) -> bool) -> Verdict {
    let live = history.iter().find(|r| match r.state {
        RunState::Queued => true,
        RunState::Running => r.pid.is_some_and(alive),
        _ => false,
    });
    if let Some(r) = live {
        return Verdict::Busy { run: r.id.clone() };
    }
    let starts: Vec<i64> =
        history.iter().filter(|r| fired(r)).filter_map(|r| r.started_at).collect();
    if gate.cooldown_seconds > 0
        && let Some(last) = starts.iter().copied().max()
    {
        let until = last.saturating_add(gate.cooldown_seconds as i64);
        if now < until {
            return Verdict::Cooldown { until };
        }
    }
    if let Some(max) = gate.max_runs_per_day {
        let mut recent: Vec<i64> =
            starts.iter().copied().filter(|t| now - *t < DAY_SECONDS).collect();
        if recent.len() >= max as usize {
            recent.sort_unstable();
            let oldest = recent.first().copied().unwrap_or(now);
            return Verdict::Cap { max, until: oldest + DAY_SECONDS };
        }
    }
    Verdict::Go
}

/// `text` cut to [`MAX_EVENT_BYTES`] on a character boundary.
pub fn clip_event(text: &str) -> String {
    if text.len() <= MAX_EVENT_BYTES {
        return text.to_string();
    }
    let mut end = MAX_EVENT_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n[cut at {} KiB]", text.get(..end).unwrap_or_default(), MAX_EVENT_BYTES / 1024)
}
