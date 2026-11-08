//! A hand-off's words (cloud work mode; cmux#26578): a chat handed to a Cloud machine, which
//! reports `starting`, `running`, `needs-you`, `done`, `failed` or `cancelled`, turn after turn.

use crate::model::{Notice, Outcome};

/// The store's statuses.
pub const STATUSES: [&str; 6] = ["starting", "running", "needs-you", "done", "failed", "cancelled"];
/// The statuses that end a turn (and, before turns, the hand-off).
pub const TURN_ENDS: [&str; 3] = ["done", "failed", "cancelled"];
/// The statuses of a turn that runs: a hand-off in one is never given up for age.
pub const TURN_RUNS: [&str; 2] = ["starting", "running"];

/// What the person is told about this turn's status, if anything: done, failed and needs-you,
/// once per turn and status. Never cancelled, starting or running.
pub fn notice(status: &str, turn: Option<i64>) -> Option<Notice> {
    let outcome = match status {
        "done" => Outcome::Succeeded,
        "failed" => Outcome::Failed,
        "needs-you" => Outcome::NeedsYou,
        _ => return None,
    };
    Some(Notice { key: format!("{}:{status}", turn.unwrap_or(1)), outcome })
}

/// A listed hand-off can still change: not closed (a store from before turns, no `state`: not
/// done, failed or cancelled).
pub fn is_open(status: &str, state: Option<&str>) -> bool {
    state.map_or_else(|| !TURN_ENDS.contains(&status), |state| state != "closed")
}

/// Its current turn runs: `starting` or `running`.
pub fn is_running(status: &str) -> bool {
    TURN_RUNS.contains(&status)
}

/// A store time as milliseconds since 1970: a number of milliseconds as sent, or an ISO 8601
/// string ([`iso_millis`]); none for any other value.
pub fn millis(time: &serde_json::Value) -> Option<f64> {
    match time {
        serde_json::Value::Number(number) => number.as_f64(),
        serde_json::Value::String(text) => iso_millis(text),
        _ => None,
    }
}

/// A store time (`toISOString()`, or any ISO 8601 date and time with a zone) as milliseconds
/// since 1970; none when it is no such time.
pub fn iso_millis(text: &str) -> Option<f64> {
    let (date, rest) = text.split_once('T')?;
    let mut date = date.split('-');
    let (year, month, day) =
        (number(date.next()?, 4)?, number(date.next()?, 2)?, number(date.next()?, 2)?);
    if date.next().is_some()
        || !(1..=12).contains(&month)
        || !(1..=days_in(year, month)).contains(&day)
    {
        return None;
    }
    let zone_at = rest.find(['Z', 'z', '+', '-'])?;
    let (time, zone) = rest.split_at(zone_at);
    let (clock, fraction) =
        time.split_once('.').map_or((time, None), |(clock, fraction)| (clock, Some(fraction)));
    let mut clock = clock.split(':');
    let (hour, minute, second) =
        (number(clock.next()?, 2)?, number(clock.next()?, 2)?, number(clock.next()?, 2)?);
    if clock.next().is_some() || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let fraction = match fraction {
        None => 0.0,
        Some(digits) if !digits.is_empty() && digits.bytes().all(|byte| byte.is_ascii_digit()) => {
            format!("0.{digits}").parse::<f64>().ok()?
        }
        Some(_) => return None,
    };
    let offset = zone_offset(zone)?;
    let seconds =
        days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second - offset;
    Some((seconds as f64 + fraction) * 1_000.0)
}

/// Exactly `width` ASCII digits.
fn number(text: &str, width: usize) -> Option<i64> {
    (text.len() == width && text.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| text.parse().ok())
        .flatten()
}

/// `Z`, `±hh:mm` or `±hhmm`, as seconds east of UTC.
fn zone_offset(zone: &str) -> Option<i64> {
    if zone.eq_ignore_ascii_case("z") {
        return Some(0);
    }
    let sign = match zone.as_bytes().first()? {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let digits = zone.get(1..)?.replacen(':', "", 1);
    let (hours, minutes) = (number(digits.get(..2)?, 2)?, number(digits.get(2..)?, 2)?);
    (hours <= 23 && minutes <= 59).then_some(sign * (hours * 3_600 + minutes * 60))
}

fn days_in(year: i64, month: i64) -> i64 {
    match month {
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Days from 1970-01-01 to the proleptic Gregorian date.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}
