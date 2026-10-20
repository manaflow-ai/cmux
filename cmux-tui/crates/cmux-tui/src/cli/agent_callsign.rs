//! The live callsign lease `callsign start` keeps for an agent session, read
//! the way `tools/remote-agents/agent_identity.py` (manaflow-ai/cmuxterm-hq)
//! reads it, so `cmux agent link` names the agent as the commit hook does.
//!
//! The lease is `$CALLSIGN_STATE_DIR/session-<slug>.json` (default
//! `$XDG_STATE_HOME/callsign`, else `~/.local/state/callsign`). A pending or
//! expired lease, or one without a string `callsign`, doesn't count.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// The callsign of the live lease for `session_id`, if any.
pub(super) fn callsign(session_id: &str, env: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    let set = |key: &str| env(key).filter(|value| !value.is_empty());
    let base = set("CALLSIGN_STATE_DIR").map(PathBuf::from).unwrap_or_else(|| {
        set("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(env("HOME").unwrap_or_default()).join(".local/state"))
            .join("callsign")
    });
    let path = base.join(format!("session-{}.json", state_slug(session_id)));
    let lease: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    let lease = lease.as_object()?;
    if lease.get("pending").is_some_and(truthy) {
        return None;
    }
    let callsign = lease.get("callsign")?.as_str()?;
    let expires = unix_seconds(lease.get("expiresAt")?.as_str()?)?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs_f64();
    (expires > now).then(|| callsign.to_owned())
}

/// Python truthiness of a JSON value.
fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(value) => *value,
        Value::Number(number) => number.as_f64().is_some_and(|number| number != 0.0),
        Value::String(text) => !text.is_empty(),
        Value::Array(items) => !items.is_empty(),
        Value::Object(fields) => !fields.is_empty(),
    }
}

/// stensibly's `slug`: lowercase, every run of other characters one `_`,
/// trimmed of `_`, at most 80 characters, `session` when nothing is left.
pub(super) fn slug(value: &str) -> String {
    let mut out = String::new();
    let mut gap = false;
    for char in value.trim().to_lowercase().chars() {
        if char.is_ascii_lowercase() || char.is_ascii_digit() {
            if gap && !out.is_empty() {
                out.push('_');
            }
            gap = false;
            out.push(char);
        } else {
            gap = true;
        }
    }
    out.truncate(80);
    if out.is_empty() { "session".into() } else { out }
}

/// The lease file's slug: stensibly slugs twice, and the second pass trims a
/// `_` the first pass's 80-character cut left at the end.
pub(super) fn state_slug(session_id: &str) -> String {
    slug(&slug(session_id))
}

/// Unix seconds of an ISO 8601 time (`2026-10-20T04:00:00.000Z`,
/// `…+02:00`, or no offset for UTC), as Python's `fromisoformat` reads it.
pub(super) fn unix_seconds(text: &str) -> Option<f64> {
    let text = text.trim();
    let (date, time) = match text.split_once(['T', ' ']) {
        Some((date, time)) => (date, time),
        None => (text, "00:00"),
    };
    let mut date_parts = date.splitn(3, '-');
    let year: i64 = number(date_parts.next()?, 4)?;
    let month: i64 = number(date_parts.next()?, 2)?;
    let day: i64 = number(date_parts.next()?, 2)?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let (clock, offset) = match time.find(['Z', 'z', '+', '-']) {
        Some(index) => (&time[..index], &time[index..]),
        None => (time, ""),
    };
    let offset_seconds = match offset {
        "" | "Z" | "z" => 0,
        _ => {
            let sign = if offset.starts_with('-') { -1 } else { 1 };
            let (hours, minutes) = offset[1..].split_once(':').unwrap_or((&offset[1..], "00"));
            sign * (number::<i64>(hours, 2)? * 3600 + number::<i64>(minutes, 2)? * 60)
        }
    };
    let mut clock_parts = clock.splitn(3, ':');
    let hour: i64 = number(clock_parts.next()?, 2)?;
    let minute: i64 = number(clock_parts.next()?, 2)?;
    let second: f64 = match clock_parts.next() {
        Some(second) => {
            let whole = second.split('.').next()?;
            number::<i64>(whole, 2)?;
            second.parse().ok()?
        }
        None => 0.0,
    };
    if hour > 23 || minute > 59 || second >= 60.0 {
        return None;
    }
    let days = days_from_civil(year, month, day);
    Some((days * 86_400 + hour * 3600 + minute * 60 - offset_seconds) as f64 + second)
}

fn number<T: std::str::FromStr>(text: &str, digits: usize) -> Option<T> {
    (text.len() == digits && text.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| text.parse().ok())
        .flatten()
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Expected values are what agent_identity.py's `callsign_slug` and
    /// `callsign_state_slug` print for the same input.
    #[test]
    fn slugs_match_agent_identity() {
        assert_eq!(slug("0f3c2a91-7d4e-4b8a"), "0f3c2a91_7d4e_4b8a");
        assert_eq!(slug("  Other Session!! "), "other_session");
        assert_eq!(slug("---"), "session");
        let long = format!("{}-x", "a".repeat(79));
        assert_eq!(slug(&long), format!("{}_", "a".repeat(79)));
        assert_eq!(state_slug(&long), "a".repeat(79));
    }

    #[test]
    fn iso_times_read_like_fromisoformat() {
        assert_eq!(unix_seconds("1970-01-01T00:00:00Z"), Some(0.0));
        assert_eq!(unix_seconds("2026-10-20T04:00:00.500Z"), Some(1_792_468_800.5));
        assert_eq!(unix_seconds("2026-10-20T06:00:00+02:00"), Some(1_792_468_800.0));
        assert_eq!(unix_seconds("2026-10-20T04:00:00"), Some(1_792_468_800.0));
        assert_eq!(unix_seconds("2026-10-20"), Some(1_792_454_400.0));
        assert_eq!(unix_seconds("tomorrow"), None);
        assert_eq!(unix_seconds("2026-13-01T00:00:00Z"), None);
    }
}
