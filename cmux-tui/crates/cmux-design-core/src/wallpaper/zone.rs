//! A time zone as the app hands it over: Foundation's `TimeZone` reduced to a base offset and
//! the transitions around the instant asked about. The crate reads no clock and no tz database,
//! so Swift sends `{offset, transitions}` covering the days a rule looks at (a week around it)
//! and every calendar step the wallpaper rules take (`startOfDay`, `date(byAdding: .day)`,
//! `dateComponents([.hour, .minute, .second])`, `nextDaylightSavingTimeTransition`) is done here
//! on that table.

use serde::{Deserialize, Serialize};

/// One change of a zone's offset.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transition {
    /// The instant (Unix seconds) the new offset starts.
    pub at: f64,
    /// Seconds east of UTC from `at` on.
    pub offset: i32,
}

/// A zone: `offset` before the first transition, then each transition's offset from its instant.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Zone {
    /// Seconds east of UTC before the first transition.
    pub offset: i32,
    /// Sorted by `at`.
    #[serde(default)]
    pub transitions: Vec<Transition>,
}

impl Zone {
    /// A zone with one offset.
    pub fn fixed(offset: i32) -> Self {
        Self { offset, transitions: Vec::new() }
    }

    /// `secondsFromGMT(for:)`: the offset in force at `t` (a transition's instant has the new one).
    pub fn seconds_from_gmt(&self, t: f64) -> i32 {
        self.transitions.iter().rev().find(|x| x.at <= t).map_or(self.offset, |x| x.offset)
    }

    /// `nextDaylightSavingTimeTransition(after:)`: the first transition after `t`.
    pub fn next_transition(&self, t: f64) -> Option<f64> {
        self.transitions.iter().find(|x| x.at > t).map(|x| x.at)
    }

    /// The instant a local wall clock reading (`wall`, seconds as if the wall clock were UTC)
    /// names: the earliest when it is read twice, the transition that skipped it when it is in
    /// a gap. Swift `BackdropTimeOfDay.wallTime`'s search.
    pub fn instant(&self, wall: f64) -> f64 {
        let mut offsets = vec![
            self.seconds_from_gmt(wall - 86_400.0),
            self.seconds_from_gmt(wall),
            self.seconds_from_gmt(wall + 86_400.0),
        ];
        offsets.sort_unstable();
        offsets.dedup();
        let candidates: Vec<f64> = offsets.iter().map(|&o| wall - f64::from(o)).collect();
        let valid = candidates
            .iter()
            .copied()
            .filter(|&c| f64::from(self.seconds_from_gmt(c)) + c == wall)
            .reduce(f64::min);
        if let Some(first) = valid {
            return first;
        }
        let earliest = candidates.iter().copied().reduce(f64::min).unwrap_or(wall);
        self.next_transition(earliest - 1.0).unwrap_or(earliest)
    }

    /// The local wall clock at `t`, as seconds since 1970 read as UTC.
    pub fn wall(&self, t: f64) -> f64 {
        t + f64::from(self.seconds_from_gmt(t))
    }

    /// `calendar.startOfDay(for: t)`.
    pub fn start_of_day(&self, t: f64) -> f64 {
        let day = (self.wall(t) / 86_400.0).floor();
        self.instant(day * 86_400.0)
    }

    /// `calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: t))`.
    pub fn start_of_day_offset(&self, t: f64, days: i32) -> f64 {
        let day = (self.wall(t) / 86_400.0).floor() + f64::from(days);
        self.instant(day * 86_400.0)
    }

    /// `calendar.dateComponents([.hour, .minute, .second], from: t)` as seconds into the local day.
    pub fn seconds_into_day(&self, t: f64) -> i64 {
        (self.wall(t).floor() as i64).rem_euclid(86_400)
    }
}
