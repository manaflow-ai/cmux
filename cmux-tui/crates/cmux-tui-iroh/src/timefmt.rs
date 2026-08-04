//! Minimal RFC 3339 UTC helpers so the crate avoids a calendar dependency.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub fn unix_seconds_now() -> i64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(elapsed) => elapsed.as_secs() as i64,
        Err(_) => 0,
    }
}

/// Formats a future instant as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn rfc3339_after(duration: Duration) -> String {
    rfc3339_from_unix(unix_seconds_now() + duration.as_secs() as i64)
}

pub fn rfc3339_from_unix(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let secs_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        secs_of_day / 3600,
        (secs_of_day % 3600) / 60,
        secs_of_day % 60,
    )
}

/// Howard Hinnant's `civil_from_days` algorithm.
fn civil_from_days(days_from_epoch: i64) -> (i64, u32, u32) {
    let z = days_from_epoch + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

/// Parses either epoch seconds or an RFC 3339 timestamp into epoch seconds.
pub fn parse_expiry(value: &serde_json::Value) -> Option<i64> {
    if let Some(seconds) = value.as_i64() {
        return Some(seconds);
    }
    let text = value.as_str()?;
    parse_rfc3339(text)
}

pub fn parse_rfc3339(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.len() < 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return None;
    }
    let year: i64 = text.get(0..4)?.parse().ok()?;
    let month: i64 = text.get(5..7)?.parse().ok()?;
    let day: i64 = text.get(8..10)?.parse().ok()?;
    let hour: i64 = text.get(11..13)?.parse().ok()?;
    let minute: i64 = text.get(14..16)?.parse().ok()?;
    let second: i64 = text.get(17..19)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // Only UTC forms are produced by the broker ("Z" suffix, optional millis).
    if !text.ends_with('Z') {
        return None;
    }
    let days = days_from_civil(year, month as u32, day as u32);
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let adjusted_year = if month <= 2 { year - 1 } else { year };
    let era = adjusted_year.div_euclid(400);
    let yoe = adjusted_year.rem_euclid(400);
    let mp = if month > 2 { month - 3 } else { month + 9 } as i64;
    let doy = (153 * mp + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_and_parses_round_trip() {
        let now = unix_seconds_now();
        let formatted = rfc3339_from_unix(now);
        assert_eq!(parse_rfc3339(&formatted), Some(now));
    }

    #[test]
    fn parses_known_timestamp() {
        assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_rfc3339("2026-07-21T22:00:30Z"), Some(1_784_671_230));
        assert_eq!(parse_rfc3339("2026-07-21T22:00:30.123Z"), Some(1_784_671_230));
    }

    #[test]
    fn parses_epoch_second_json_values() {
        assert_eq!(parse_expiry(&serde_json::json!(1_784_671_230)), Some(1_784_671_230));
        assert_eq!(parse_expiry(&serde_json::json!("2026-07-21T22:00:30Z")), Some(1_784_671_230));
        assert_eq!(parse_expiry(&serde_json::json!(null)), None);
    }
}
