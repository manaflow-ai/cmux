//! When an automation runs.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::clock::Zone;
use crate::cron::CronExpr;

/// The shortest interval a local `every` may use.
pub const MIN_EVERY_SECONDS: u64 = 60;

/// One trigger. Presets (hourly, daily, weekdays, weekly) are stored as cron.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Trigger {
    /// A cron expression in `tz` (`local` or `UTC` on this machine).
    Cron { expr: String, tz: String },
    /// Every `seconds`, counted from `anchor` (the time it was made).
    Every { seconds: u64, anchor: i64 },
    /// Once, at `at`. The automation pauses itself after that run.
    At { at: i64 },
    /// Only when someone runs it (`cmux automation run`).
    Manual,
    /// Whenever the long-running `command` prints a line (`--watch`). Lines
    /// closer together than `debounce_seconds` are one event. It has no due
    /// times: the runner keeps the command alive ([`crate::watch`]).
    Watch { command: String, debounce_seconds: u64 },
    /// Whenever the named event happens (`--when agent-idle`): a watch whose
    /// command cmux supplies ([`crate::events`]), `cmux automation events NAME`.
    Event { event: String, debounce_seconds: u64 },
}

/// A watch's default debounce: a burst of lines inside it is one event.
pub const DEFAULT_DEBOUNCE_SECONDS: u64 = 5;

/// The longest debounce: a stream that never pauses is one event at most this
/// long (`watch::MAX_HOLD_MS`), so a longer one would mean nothing.
pub const MAX_DEBOUNCE_SECONDS: u64 = 30;

/// A trigger that cannot be scheduled.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScheduleError(pub String);

impl fmt::Display for ScheduleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ScheduleError {}

impl Trigger {
    /// Every hour on the hour.
    pub fn preset_hourly(zone: Zone) -> Trigger {
        Trigger::Cron { expr: "0 * * * *".into(), tz: zone.name().into() }
    }
    /// Every day at `hour:minute`.
    pub fn preset_daily(hour: u32, minute: u32, zone: Zone) -> Trigger {
        Trigger::Cron { expr: format!("{minute} {hour} * * *"), tz: zone.name().into() }
    }
    /// Monday to Friday at `hour:minute`.
    pub fn preset_weekdays(hour: u32, minute: u32, zone: Zone) -> Trigger {
        Trigger::Cron { expr: format!("{minute} {hour} * * 1-5"), tz: zone.name().into() }
    }
    /// One weekday (0 Sunday to 6 Saturday) at `hour:minute`.
    pub fn preset_weekly(weekday: u32, hour: u32, minute: u32, zone: Zone) -> Trigger {
        Trigger::Cron { expr: format!("{minute} {hour} * * {weekday}"), tz: zone.name().into() }
    }

    /// Whether this trigger can be scheduled here.
    pub fn validate(&self) -> Result<(), ScheduleError> {
        match self {
            Trigger::Cron { expr, tz } => {
                Zone::parse(tz).map_err(ScheduleError)?;
                CronExpr::parse(expr).map_err(ScheduleError)?;
                Ok(())
            }
            Trigger::Every { seconds, .. } if *seconds < MIN_EVERY_SECONDS => {
                Err(ScheduleError(format!("every {seconds}s is shorter than the one-minute floor")))
            }
            Trigger::Watch { command, .. } if command.trim().is_empty() => {
                Err(ScheduleError("--watch needs a command".into()))
            }
            Trigger::Event { event, .. } if crate::events::find(event).is_none() => {
                Err(ScheduleError(format!(
                    "--when takes one of {}, not {event:?}; run `cmux automation events`",
                    crate::events::names()
                )))
            }
            Trigger::Watch { debounce_seconds: 0, .. }
            | Trigger::Event { debounce_seconds: 0, .. } => {
                Err(ScheduleError("a watch's debounce is at least one second".into()))
            }
            Trigger::Watch { debounce_seconds, .. } | Trigger::Event { debounce_seconds, .. }
                if *debounce_seconds > MAX_DEBOUNCE_SECONDS =>
            {
                Err(ScheduleError(format!(
                    "a watch's debounce is at most {MAX_DEBOUNCE_SECONDS} seconds (a stream is held \
                     no longer); space runs out with --cooldown"
                )))
            }
            _ => Ok(()),
        }
    }

    /// The first scheduled time strictly after `t`, or `None` when there is
    /// no further one.
    pub fn next_after(&self, t: i64) -> Result<Option<i64>, ScheduleError> {
        match self {
            Trigger::Cron { expr, tz } => {
                let zone = Zone::parse(tz).map_err(ScheduleError)?;
                Ok(CronExpr::parse(expr).map_err(ScheduleError)?.next_after(t, zone))
            }
            Trigger::Every { seconds, anchor } => {
                self.validate()?;
                let step = *seconds as i64;
                if t < *anchor {
                    return Ok(Some(*anchor));
                }
                Ok(Some(anchor + ((t - anchor) / step + 1) * step))
            }
            Trigger::At { at } => Ok((*at > t).then_some(*at)),
            Trigger::Manual | Trigger::Watch { .. } | Trigger::Event { .. } => Ok(None),
        }
    }

    /// Words for a person: `cron 0 9 * * 1-5 (local)`, `every 30m`, `once at …`.
    pub fn describe(&self) -> String {
        match self {
            Trigger::Cron { expr, tz } => format!("cron {expr} ({tz})"),
            Trigger::Every { seconds, .. } => match seconds {
                s if s % 3_600 == 0 => format!("every {}h", s / 3_600),
                s if s % 60 == 0 => format!("every {}m", s / 60),
                s => format!("every {s}s"),
            },
            Trigger::At { at } => format!("once at {at}"),
            Trigger::Manual => "manual".into(),
            Trigger::Watch { command, .. } => format!("watch `{command}`"),
            Trigger::Event { event, .. } => match crate::events::find(event) {
                Some(kind) => kind.label.to_string(),
                None => format!("when {event}"),
            },
        }
    }

    /// The command a runner keeps alive for this trigger: a watch's own, or
    /// for an event, `program automation events NAME` (`program` is the
    /// runner's `cmux`). `None` for a schedule.
    pub fn watch_command(&self, program: &str) -> Option<String> {
        match self {
            Trigger::Watch { command, .. } => Some(command.clone()),
            Trigger::Event { event, .. } => Some(crate::events::watch_command(program, event)),
            _ => None,
        }
    }

    /// The debounce of a watch or an event trigger.
    pub fn debounce_seconds(&self) -> Option<u64> {
        match self {
            Trigger::Watch { debounce_seconds, .. } | Trigger::Event { debounce_seconds, .. } => {
                Some(*debounce_seconds)
            }
            _ => None,
        }
    }

    /// Whether the runner keeps a command alive for it (a watch or an event).
    pub fn is_watched(&self) -> bool {
        matches!(self, Trigger::Watch { .. } | Trigger::Event { .. })
    }
}
