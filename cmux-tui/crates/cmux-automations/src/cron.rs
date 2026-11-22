//! Five-field cron (minute hour day-of-month month day-of-week).
//!
//! Lists, ranges, steps, `*`, month and weekday names, `7` as Sunday, and
//! the `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly` shorthands.
//! When both day fields are restricted, a day matches either (Vixie cron).

use crate::clock::Zone;

/// A parsed cron expression.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CronExpr {
    minutes: u64,
    hours: u32,
    days: u32,
    months: u16,
    weekdays: u8,
    day_restricted: bool,
    weekday_restricted: bool,
}

const MONTHS: [&str; 12] =
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const WEEKDAYS: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

/// How far ahead [`CronExpr::next_after`] looks: long enough for any
/// expression that can match at all (Feb 29 on a given weekday recurs within
/// 28 years), short enough to stay cheap for one that never does.
const SEARCH_DAYS: i64 = 366 * 29;

impl CronExpr {
    /// Parse; the error names the field that is wrong.
    pub fn parse(text: &str) -> Result<CronExpr, String> {
        let text = text.trim();
        let expanded = match text {
            "@hourly" => "0 * * * *",
            "@daily" | "@midnight" => "0 0 * * *",
            "@weekly" => "0 0 * * 0",
            "@monthly" => "0 0 1 * *",
            "@yearly" | "@annually" => "0 0 1 1 *",
            other => other,
        };
        let fields: Vec<&str> = expanded.split_whitespace().collect();
        let &[minute, hour, day, month, weekday] = fields.as_slice() else {
            return Err(format!(
                "cron \"{text}\" needs 5 fields (minute hour day month weekday), not {}",
                fields.len()
            ));
        };
        let minutes = field(minute, 0, 59, &[], "minute")?;
        let hours = field(hour, 0, 23, &[], "hour")?;
        let days = field(day, 1, 31, &[], "day")?;
        let months = field(month, 1, 12, &MONTHS, "month")?;
        let mut weekdays = field(weekday, 0, 7, &WEEKDAYS, "weekday")?;
        if weekdays & (1 << 7) != 0 {
            weekdays = (weekdays | 1) & 0x7f;
        }
        Ok(CronExpr {
            minutes,
            hours: hours as u32,
            days: days as u32,
            months: months as u16,
            weekdays: weekdays as u8,
            day_restricted: day != "*",
            weekday_restricted: weekday != "*",
        })
    }

    fn day_matches(&self, day: u32, weekday: u32) -> bool {
        let d = self.days & (1 << day) != 0;
        let w = self.weekdays & (1 << weekday) != 0;
        match (self.day_restricted, self.weekday_restricted) {
            (true, true) => d || w,
            (true, false) => d,
            (false, true) => w,
            (false, false) => true,
        }
    }

    /// The first fire strictly after `t` in `zone`, or `None` when the
    /// expression never matches (`0 0 30 2 *`).
    ///
    /// Each wall-clock minute fires once: a minute in a spring-forward gap
    /// fires at the time `mktime` moves it to; a minute of the repeated
    /// fall-back hour fires at its first occurrence only.
    pub fn next_after(&self, t: i64, zone: Zone) -> Option<i64> {
        let start = zone.civil(t);
        for offset in 0..SEARCH_DAYS {
            // Day arithmetic through the C library, which carries overflow.
            let noon =
                zone.timestamp(start.year, start.month as i64, start.day as i64 + offset, 12, 0);
            let day = zone.civil(noon);
            if self.months & (1 << day.month) == 0 || !self.day_matches(day.day, day.weekday) {
                continue;
            }
            let first_hour = if offset == 0 { start.hour.saturating_sub(1) } else { 0 };
            for hour in first_hour..24 {
                if self.hours & (1 << hour) == 0 {
                    continue;
                }
                let (y, m, d) = (day.year, day.month as i64, day.day as i64);
                if offset == 0 && zone.timestamp(y, m, d, hour as i64, 59) <= t {
                    continue;
                }
                let first_minute = if offset == 0 && hour == start.hour { start.minute } else { 0 };
                for minute in first_minute..60u32 {
                    if self.minutes & (1 << minute) == 0 {
                        continue;
                    }
                    let fire = zone.timestamp(
                        day.year,
                        day.month as i64,
                        day.day as i64,
                        hour as i64,
                        minute as i64,
                    );
                    if fire > t {
                        return Some(fire);
                    }
                }
            }
        }
        None
    }
}

fn field(text: &str, min: u32, max: u32, names: &[&str], what: &str) -> Result<u64, String> {
    let bad = |why: &str| Err(format!("cron {what} \"{text}\": {why}"));
    let mut bits = 0u64;
    for part in text.split(',') {
        let (range, step) = match part.split_once('/') {
            Some((r, s)) => match s.parse::<u32>() {
                Ok(n) if n > 0 => (r, n),
                _ => return bad("the step must be a positive number"),
            },
            None => (part, 1),
        };
        let (lo, hi) = if range == "*" {
            (min, max)
        } else if let Some((a, b)) = range.split_once('-') {
            (value(a, names, min)?, value(b, names, min)?)
        } else {
            let v = value(range, names, min)?;
            (v, if step > 1 { max } else { v })
        };
        if lo < min || hi > max {
            return bad(&format!("values run from {min} to {max}"));
        }
        if lo > hi {
            return bad("a range must go up");
        }
        let mut v = lo;
        while v <= hi {
            bits |= 1 << v;
            v += step;
        }
    }
    if bits == 0 {
        return bad("matches nothing");
    }
    Ok(bits)
}

fn value(text: &str, names: &[&str], base: u32) -> Result<u32, String> {
    if let Ok(v) = text.parse::<u32>() {
        return Ok(v);
    }
    let lower = text.to_ascii_lowercase();
    names
        .iter()
        .position(|n| *n == lower)
        .map(|i| i as u32 + base)
        .ok_or_else(|| format!("cron value \"{text}\" is not a number or a name"))
}
