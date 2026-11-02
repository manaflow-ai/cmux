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
}

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
            Trigger::Manual => Ok(None),
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
        }
    }
}
