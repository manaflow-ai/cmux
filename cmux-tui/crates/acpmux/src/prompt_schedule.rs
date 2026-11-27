//! A chat's scheduled prompt: cmux's own `/loop`, the same for every harness.
//!
//! Claude Code schedules its own wakeups (`claude_stdio/loops.rs`); Codex, OpenCode, Gemini and
//! pi have nothing of the kind. This one belongs to the daemon (`hub/prompt_schedule.rs`): it
//! sends its prompt into the chat through the same path a person's prompt takes, on one of three
//! triggers, and stops on its own.
//!
//! - `every`: every N minutes, counted from the run before (a run the daemon missed while it was
//!   down, or while the chat was busy, goes once when it can, never as a catch-up burst).
//! - `at`: once, at a wall-clock time.
//! - `idle`: each time the agent goes idle, `IDLE_GRACE_MS` after its turn ends, so a person who
//!   starts typing at the end of a turn goes first. It always has a stop: a `max_runs`, an
//!   `until`, or [`IDLE_DEFAULT_MAX_RUNS`] when neither was given.
//!
//! A schedule ends after `max_runs` runs, at `until`, or after an `at` run. Every time here is
//! wall-clock epoch milliseconds, so a schedule means the same thing after a daemon restart; the
//! model takes `now` as an argument and reads no clock of its own (its tests pass the time).

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The shortest interval: a loop that runs faster than a turn takes only fills the queue.
pub const MIN_EVERY_MINUTES: u64 = 1;
/// The longest interval, a week.
pub const MAX_EVERY_MINUTES: u64 = 7 * 24 * 60;
/// How far ahead an `at` or `until` may be: a year.
pub const MAX_AHEAD_MS: u64 = 366 * 24 * 60 * 60 * 1000;
/// How long after a turn ends an `idle` schedule sends.
pub const IDLE_GRACE_MS: u64 = 15_000;
/// The runs an `idle` schedule makes when it was given no stop.
pub const IDLE_DEFAULT_MAX_RUNS: u32 = 10;
/// The most runs any schedule makes.
pub const MAX_RUNS: u32 = 1_000;
/// The longest prompt, in characters.
pub const MAX_PROMPT_CHARS: usize = 8_000;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Trigger {
    Every { minutes: u64 },
    At { at: u64 },
    Idle,
}

/// What a person asks for (`_acpmux/schedule/set`), before it is checked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub prompt: String,
    pub trigger: Trigger,
    pub max_runs: Option<u32>,
    pub until: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptSchedule {
    pub id: String,
    pub prompt: String,
    pub trigger: Trigger,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_runs: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub until: Option<u64>,
    #[serde(default)]
    pub runs: u32,
    /// When it sends next; none while an `idle` schedule waits for a turn to end.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_run_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run_at: Option<u64>,
    #[serde(default)]
    pub paused: bool,
    pub created_at: u64,
    /// Set by the hub: the schedule came from a folder-trust-gated connection, so each run is
    /// checked against the folder's trust when it is sent.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub trust_gate: bool,
}

impl PromptSchedule {
    /// A new schedule from `req`, checked, created at `now`.
    pub fn new(id: String, req: Request, now: u64) -> Result<Self, String> {
        let prompt = req.prompt.trim().to_owned();
        if prompt.is_empty() {
            return Err("prompt is required".into());
        }
        if prompt.chars().count() > MAX_PROMPT_CHARS {
            return Err(format!("prompt is over {MAX_PROMPT_CHARS} characters"));
        }
        if let Some(n) = req.max_runs
            && !(1..=MAX_RUNS).contains(&n)
        {
            return Err(format!("maxRuns must be from 1 to {MAX_RUNS}"));
        }
        if let Some(until) = req.until
            && (until <= now || until - now > MAX_AHEAD_MS)
        {
            return Err("until must be a time in the coming year".into());
        }
        let (next_run_at, max_runs) = match req.trigger {
            Trigger::Every { minutes } => {
                if !(MIN_EVERY_MINUTES..=MAX_EVERY_MINUTES).contains(&minutes) {
                    return Err(format!(
                        "every must be from {MIN_EVERY_MINUTES} to {MAX_EVERY_MINUTES} minutes"
                    ));
                }
                (Some(now + minutes * 60_000), req.max_runs)
            }
            Trigger::At { at } => {
                if at <= now || at - now > MAX_AHEAD_MS {
                    return Err("at must be a time in the coming year".into());
                }
                (Some(at), Some(1))
            }
            Trigger::Idle => {
                let stop = match (req.max_runs, req.until) {
                    (None, None) => Some(IDLE_DEFAULT_MAX_RUNS),
                    (runs, _) => runs,
                };
                (Some(now + IDLE_GRACE_MS), stop)
            }
        };
        Ok(Self {
            id,
            prompt,
            trigger: req.trigger,
            max_runs,
            until: req.until,
            runs: 0,
            next_run_at,
            last_run_at: None,
            paused: false,
            created_at: now,
            trust_gate: false,
        })
    }

    /// Whether it has made its last run or passed its end.
    pub fn finished(&self, now: u64) -> bool {
        self.max_runs.is_some_and(|n| self.runs >= n) || self.until.is_some_and(|u| u <= now)
    }

    /// Whether a run is owed now (the chat may still be busy).
    pub fn due(&self, now: u64) -> bool {
        !self.paused && !self.finished(now) && self.next_run_at.is_some_and(|t| t <= now)
    }

    /// When it runs next, when that is still ahead and it is not paused.
    pub fn deadline(&self, now: u64) -> Option<u64> {
        if self.paused || self.finished(now) {
            return None;
        }
        self.next_run_at.filter(|t| *t > now)
    }

    /// One run sent at `now`: the next is counted from here.
    pub fn fire(&mut self, now: u64) {
        self.runs = self.runs.saturating_add(1);
        self.last_run_at = Some(now);
        self.next_run_at = match self.trigger {
            Trigger::Every { minutes } => Some(now + minutes * 60_000),
            Trigger::At { .. } | Trigger::Idle => None,
        };
    }

    /// The chat's turn ended at `now`: an `idle` schedule sends after its grace. Whether it
    /// changed.
    pub fn turn_ended(&mut self, now: u64) -> bool {
        if self.trigger != Trigger::Idle || self.paused || self.finished(now) {
            return false;
        }
        self.next_run_at = Some(now + IDLE_GRACE_MS);
        true
    }

    /// Paused or resumed at `now`. A resumed `every` schedule waits a full interval rather than
    /// sending what it missed; a resumed `idle` one sends after its grace.
    pub fn set_paused(&mut self, paused: bool, now: u64) {
        if self.paused == paused {
            return;
        }
        self.paused = paused;
        if !paused {
            match self.trigger {
                Trigger::Every { minutes } => self.next_run_at = Some(now + minutes * 60_000),
                Trigger::Idle => self.next_run_at = Some(now + IDLE_GRACE_MS),
                Trigger::At { .. } => {}
            }
        }
    }

    /// Its wire form (`_meta.schedule`, `_acpmux/schedule/*`'s answer).
    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

/// `_acpmux/schedule/set`'s params as a [`Request`]: `prompt`, one of `everyMinutes`, `at`
/// (epoch ms) or `idle: true`, and optional `maxRuns` and `until` (epoch ms).
pub fn request_of(params: &Value) -> Result<Request, String> {
    let prompt = params.get("prompt").and_then(Value::as_str).unwrap_or_default().to_owned();
    let number = |key: &str| match params.get(key).filter(|v| !v.is_null()) {
        None => Ok(None),
        Some(v) => v.as_u64().map(Some).ok_or_else(|| format!("{key} must be a whole number")),
    };
    let every = number("everyMinutes")?;
    let at = number("at")?;
    let idle = params.get("idle").and_then(Value::as_bool).unwrap_or(false);
    let trigger = match (every, at, idle) {
        (Some(minutes), None, false) => Trigger::Every { minutes },
        (None, Some(at), false) => Trigger::At { at },
        (None, None, true) => Trigger::Idle,
        _ => return Err("give exactly one of everyMinutes, at or idle".into()),
    };
    let max_runs = number("maxRuns")?
        .map(|n| u32::try_from(n).map_err(|_| format!("maxRuns must be at most {MAX_RUNS}")))
        .transpose()?;
    Ok(Request { prompt, trigger, max_runs, until: number("until")? })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const T0: u64 = 1_800_000_000_000;
    const MIN: u64 = 60_000;

    fn every(minutes: u64, max_runs: Option<u32>, until: Option<u64>) -> PromptSchedule {
        let req = Request {
            prompt: "check CI".into(),
            trigger: Trigger::Every { minutes },
            max_runs,
            until,
        };
        PromptSchedule::new("s1".into(), req, T0).unwrap()
    }

    #[test]
    fn every_runs_on_its_interval_and_stops_after_max_runs() {
        let mut s = every(5, Some(2), None);
        assert_eq!(s.deadline(T0), Some(T0 + 5 * MIN));
        assert!(!s.due(T0 + 5 * MIN - 1));
        assert!(s.due(T0 + 5 * MIN));
        s.fire(T0 + 5 * MIN);
        assert_eq!(s.next_run_at, Some(T0 + 10 * MIN));
        assert!(!s.finished(T0 + 5 * MIN));
        s.fire(T0 + 10 * MIN);
        assert!(s.finished(T0 + 10 * MIN));
        assert!(!s.due(T0 + 15 * MIN));
        assert_eq!(s.deadline(T0 + 10 * MIN), None);
    }

    #[test]
    fn a_missed_run_goes_once_and_the_next_counts_from_it() {
        // The daemon was down for an hour: one run now, then five minutes on, never twelve.
        let mut s = every(5, None, None);
        let late = T0 + 60 * MIN;
        assert!(s.due(late));
        s.fire(late);
        assert!(!s.due(late));
        assert_eq!(s.deadline(late), Some(late + 5 * MIN));
    }

    #[test]
    fn until_ends_it() {
        let s = every(5, None, Some(T0 + 12 * MIN));
        assert!(s.due(T0 + 10 * MIN));
        assert!(s.finished(T0 + 12 * MIN));
        assert!(!s.due(T0 + 12 * MIN));
    }

    #[test]
    fn at_runs_once() {
        let req = Request {
            prompt: "standup notes".into(),
            trigger: Trigger::At { at: T0 + 30 * MIN },
            max_runs: None,
            until: None,
        };
        let mut s = PromptSchedule::new("a".into(), req, T0).unwrap();
        assert!(s.due(T0 + 30 * MIN));
        s.fire(T0 + 30 * MIN);
        assert!(s.finished(T0 + 30 * MIN));
    }

    #[test]
    fn idle_sends_after_each_turn_and_always_has_a_stop() {
        let req = Request {
            prompt: "keep going".into(),
            trigger: Trigger::Idle,
            max_runs: None,
            until: None,
        };
        let mut s = PromptSchedule::new("i".into(), req, T0).unwrap();
        assert_eq!(s.max_runs, Some(IDLE_DEFAULT_MAX_RUNS));
        assert_eq!(s.next_run_at, Some(T0 + IDLE_GRACE_MS));
        s.fire(T0 + IDLE_GRACE_MS);
        // Waits for the turn its prompt started to end.
        assert_eq!(s.next_run_at, None);
        assert!(!s.due(T0 + 10 * MIN));
        assert!(s.turn_ended(T0 + 10 * MIN));
        assert_eq!(s.deadline(T0 + 10 * MIN), Some(T0 + 10 * MIN + IDLE_GRACE_MS));
        // An until alone is a stop: no default run count.
        let req = Request {
            prompt: "keep going".into(),
            trigger: Trigger::Idle,
            max_runs: None,
            until: Some(T0 + 60 * MIN),
        };
        assert_eq!(PromptSchedule::new("j".into(), req, T0).unwrap().max_runs, None);
    }

    #[test]
    fn turn_end_leaves_other_triggers_alone() {
        let mut s = every(5, None, None);
        assert!(!s.turn_ended(T0 + MIN));
        assert_eq!(s.next_run_at, Some(T0 + 5 * MIN));
    }

    #[test]
    fn pause_holds_runs_and_resume_waits_a_full_interval() {
        let mut s = every(5, None, None);
        s.set_paused(true, T0 + MIN);
        assert!(!s.due(T0 + 20 * MIN));
        assert_eq!(s.deadline(T0 + MIN), None);
        s.set_paused(false, T0 + 20 * MIN);
        assert!(!s.due(T0 + 20 * MIN));
        assert_eq!(s.deadline(T0 + 20 * MIN), Some(T0 + 25 * MIN));
    }

    #[test]
    fn checks_what_it_is_given() {
        let bad = |trigger, max_runs, until, prompt: &str| {
            let req = Request { prompt: prompt.into(), trigger, max_runs, until };
            PromptSchedule::new("x".into(), req, T0).is_err()
        };
        assert!(bad(Trigger::Every { minutes: 5 }, None, None, "  "));
        assert!(bad(Trigger::Every { minutes: 0 }, None, None, "p"));
        assert!(bad(Trigger::Every { minutes: MAX_EVERY_MINUTES + 1 }, None, None, "p"));
        assert!(bad(Trigger::At { at: T0 }, None, None, "p"));
        assert!(bad(Trigger::Every { minutes: 5 }, Some(0), None, "p"));
        assert!(bad(Trigger::Every { minutes: 5 }, None, Some(T0 - 1), "p"));
        assert!(bad(Trigger::Idle, None, None, &"p".repeat(MAX_PROMPT_CHARS + 1)));
        assert!(!bad(Trigger::Every { minutes: 5 }, Some(3), Some(T0 + MIN), " p "));
    }

    #[test]
    fn reads_its_params() {
        let r = request_of(&json!({"prompt": "p", "everyMinutes": 10, "maxRuns": 3})).unwrap();
        assert_eq!(r.trigger, Trigger::Every { minutes: 10 });
        assert_eq!(r.max_runs, Some(3));
        assert_eq!(
            request_of(&json!({"prompt": "p", "idle": true})).unwrap().trigger,
            Trigger::Idle
        );
        assert_eq!(
            request_of(&json!({"prompt": "p", "at": T0})).unwrap().trigger,
            Trigger::At { at: T0 }
        );
        assert!(request_of(&json!({"prompt": "p"})).is_err());
        assert!(request_of(&json!({"prompt": "p", "everyMinutes": 5, "idle": true})).is_err());
        assert!(request_of(&json!({"prompt": "p", "everyMinutes": "5"})).is_err());
    }

    #[test]
    fn survives_its_stored_form() {
        let mut s = every(5, Some(4), Some(T0 + 99 * MIN));
        s.fire(T0 + 5 * MIN);
        let stored = s.to_value();
        assert_eq!(stored["trigger"], json!({"kind": "every", "minutes": 5}));
        assert_eq!(stored["nextRunAt"], json!(T0 + 10 * MIN));
        let back: PromptSchedule = serde_json::from_value(stored).unwrap();
        assert_eq!(back, s);
    }
}
