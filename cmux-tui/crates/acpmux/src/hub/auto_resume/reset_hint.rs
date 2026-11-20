//! Provider reset and retry hints. Times are absolute milliseconds since Unix epoch.
use chrono::{LocalResult, TimeZone, Utc};
use chrono_tz::Tz;
use serde_json::Value;

const MAX_HINT_DELAY_MS: u64 = 8 * 24 * 60 * 60 * 1000;

fn seconds(s: &str) -> Option<u64> {
    s.trim().parse::<u64>().ok().filter(|v| *v > 0)
}

fn duration_ms(s: &str) -> Option<u64> {
    let s = s.trim();
    let split = match s.find(|c: char| !c.is_ascii_digit() && c != '.') {
        Some(split) => split,
        None => {
            let seconds = s.parse::<u64>().ok()?;
            let ms = seconds.checked_mul(1000)?;
            return (ms <= MAX_HINT_DELAY_MS).then_some(ms);
        }
    };
    let (number, unit) = s.split_at_checked(split)?;
    let n = number.parse::<f64>().ok()?;
    if !n.is_finite() || n <= 0.0 {
        return None;
    }
    let unit = unit.trim().to_ascii_lowercase();
    let multiplier = if unit.starts_with("ms") || unit.starts_with("millisecond") {
        1.0
    } else if unit.starts_with('m') {
        60_000.0
    } else if unit.starts_with('h') {
        3_600_000.0
    } else if unit.starts_with('d') {
        86_400_000.0
    } else {
        1_000.0
    };
    let ms = n * multiplier;
    (ms.is_finite() && ms <= MAX_HINT_DELAY_MS as f64).then_some(ms as u64)
}

fn fixed_offset(zone: &str) -> Option<time::UtcOffset> {
    let sign = if zone.starts_with('-') { -1 } else { 1 };
    let digits = zone.trim_start_matches(['+', '-']);
    let (h, m) = if let Some((h, m)) = digits.split_once(':') {
        (h.parse::<i32>().ok()?, m.parse::<i32>().ok()?)
    } else if digits.len() == 4 && digits.bytes().all(|byte| byte.is_ascii_digit()) {
        let (h, m) = digits.split_at_checked(2)?;
        (h.parse::<i32>().ok()?, m.parse::<i32>().ok()?)
    } else {
        (digits.parse::<i32>().ok()?, 0)
    };
    let hours = i8::try_from(sign * h).ok()?;
    let minutes = i8::try_from(sign * m).ok()?;
    time::UtcOffset::from_hms(hours, minutes, 0).ok()
}

fn named_deadline_ms(
    zone: Tz,
    date: chrono::NaiveDate,
    hour: u8,
    minute: u8,
    now_ms: u64,
) -> Option<u64> {
    let local = date.and_hms_opt(u32::from(hour), u32::from(minute), 0)?;
    let timestamps = match zone.from_local_datetime(&local) {
        LocalResult::Single(value) => [value.timestamp_millis(), i64::MAX],
        LocalResult::Ambiguous(first, second) => {
            [first.timestamp_millis(), second.timestamp_millis()]
        }
        LocalResult::None => return None,
    };
    timestamps
        .into_iter()
        .filter(|timestamp| *timestamp != i64::MAX)
        .filter_map(|timestamp| u64::try_from(timestamp).ok())
        .filter(|timestamp| *timestamp > now_ms)
        .min()
        .or_else(|| {
            timestamps
                .into_iter()
                .filter(|timestamp| *timestamp != i64::MAX)
                .filter_map(|timestamp| u64::try_from(timestamp).ok())
                .min()
        })
}

fn clock_reset(error: &str, now_ms: u64) -> Option<u64> {
    let lower = error.to_ascii_lowercase();
    let at = lower.find("resets ")? + "resets ".len();
    let tail = lower.get(at..)?.trim_start();
    let end = tail.bytes().take_while(u8::is_ascii_digit).count();
    if end == 0 {
        return None;
    }
    let (hour_digits, mut rest) = tail.split_at_checked(end)?;
    let mut hour = hour_digits.parse::<u8>().ok()?;
    let mut minute = 0u8;
    if let Some(after_colon) = rest.strip_prefix(':') {
        let minute_end = after_colon.bytes().take_while(u8::is_ascii_digit).count();
        let (minute_digits, after) = after_colon.split_at_checked(minute_end)?;
        minute = minute_digits.parse::<u8>().ok()?;
        rest = after;
    }
    let meridiem = rest.trim_start().as_bytes().get(..2).and_then(|m| std::str::from_utf8(m).ok());
    match meridiem {
        Some("am") if hour == 12 => hour = 0,
        Some("pm") if hour < 12 => hour = hour.saturating_add(12),
        Some("am") | Some("pm") => {}
        _ => return None,
    }
    if hour > 23 || minute > 59 {
        return None;
    }
    let now = time::OffsetDateTime::from_unix_timestamp((now_ms / 1000) as i64).ok()?;
    let zone = error
        .rsplit_once('(')
        .and_then(|(_, tail)| tail.split_once(')').map(|(zone, _)| zone))
        .unwrap_or("UTC");
    if let Ok(named) = zone.parse::<Tz>() {
        let utc = Utc.timestamp_millis_opt(now_ms as i64).single()?;
        let local_now = utc.with_timezone(&named);
        let mut deadline = named_deadline_ms(named, local_now.date_naive(), hour, minute, now_ms)?;
        if deadline <= now_ms {
            deadline = named_deadline_ms(
                named,
                local_now.date_naive() + chrono::Duration::days(1),
                hour,
                minute,
                now_ms,
            )?;
        }
        return Some(deadline);
    }
    let offset = fixed_offset(&zone.to_ascii_lowercase())?;
    let local_now = now.to_offset(offset);
    let clock = time::Time::from_hms(hour, minute, 0).ok()?;
    let mut deadline = u64::try_from(
        time::PrimitiveDateTime::new(local_now.date(), clock)
            .assume_offset(offset)
            .unix_timestamp_nanos()
            / 1_000_000,
    )
    .ok()?;
    if deadline <= now_ms {
        let tomorrow = local_now.date().next_day()?;
        deadline = u64::try_from(
            time::PrimitiveDateTime::new(tomorrow, clock)
                .assume_offset(offset)
                .unix_timestamp_nanos()
                / 1_000_000,
        )
        .ok()?;
    }
    Some(deadline)
}

fn bounded_deadline(deadline: u64, now_ms: u64) -> Option<u64> {
    deadline.checked_sub(now_ms).filter(|delay| *delay <= MAX_HINT_DELAY_MS).map(|_| deadline)
}

fn as_deadline(v: u64, now_ms: u64) -> Option<u64> {
    let deadline = if v >= 10_000_000_000 {
        v
    } else if v >= 1_000_000_000 {
        v.saturating_mul(1000)
    } else {
        now_ms.saturating_add(v.saturating_mul(1000))
    };
    bounded_deadline(deadline, now_ms)
}

/// Parse an IMF-fixdate without adding a date crate to the daemon.
fn http_date_ms(s: &str) -> Option<u64> {
    let (_, rest) = s.trim().split_once(", ")?;
    let p: Vec<&str> = rest.split_whitespace().collect();
    let [day, month, year, clock, "GMT"] = p.as_slice() else {
        return None;
    };
    let day = day.parse::<u32>().ok()?;
    let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        .iter()
        .position(|m| m.eq_ignore_ascii_case(month))? as u32
        + 1;
    if year.len() != 4 || !year.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let year = year.parse::<i32>().ok()?;
    if !(1970..=9999).contains(&year) {
        return None;
    }
    let t: Vec<&str> = clock.split(':').collect();
    let [hour, minute, second] = t.as_slice() else {
        return None;
    };
    let hour = hour.parse::<u32>().ok()?;
    let minute = minute.parse::<u32>().ok()?;
    let second = second.parse::<u32>().ok()?;
    if !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let y = i64::from(year) - i64::from(month <= 2);
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = i64::from(month) + if month > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    (days >= 0).then(|| {
        (days as u64 * 86_400 + hour as u64 * 3_600 + minute as u64 * 60 + second as u64) * 1000
    })
}

fn retry_after(text: &str, now_ms: u64) -> Option<u64> {
    let lower = text.to_ascii_lowercase();
    for marker in ["retry after", "retry-after", "retry_after"] {
        let Some(at) = lower.find(marker) else { continue };
        let Some(tail) = text.get(at + marker.len()..) else { continue };
        let tail =
            tail.trim_start_matches(|c: char| c == ':' || c == '=' || c.is_ascii_whitespace());
        let end = tail.bytes().take_while(|b| b.is_ascii_digit() || *b == b'.').count();
        if end == 0 {
            if let Some(deadline) =
                http_date_ms(tail).and_then(|deadline| bounded_deadline(deadline, now_ms))
            {
                return Some(deadline);
            }
            continue;
        }
        let ms = duration_ms(tail)?;
        return bounded_deadline(now_ms.saturating_add(ms), now_ms);
    }
    if let Some(pipe) = text.rfind('|')
        && let Some(v) = text.get(pipe + 1..).and_then(seconds)
    {
        return as_deadline(v, now_ms);
    }
    None
}

/// Finds an absolute reset deadline in an agent error or saved Claude usage windows.
pub(super) fn reset_at(error: &str, usage_limits: Option<&Value>, now_ms: u64) -> Option<u64> {
    retry_after(error, now_ms)
        .or_else(|| {
            let lower = error.to_ascii_lowercase();
            lower.find("resets at ").and_then(|at| {
                let n: String =
                    lower.get(at + 10..)?.chars().take_while(|c| c.is_ascii_digit()).collect();
                seconds(&n).and_then(|v| as_deadline(v, now_ms))
            })
        })
        .or_else(|| clock_reset(error, now_ms))
        .or_else(|| {
            // Saved Claude usage windows only describe a usage-limit failure.  A later
            // transport/gateway error must not inherit a stale weekly reset deadline.
            let lower = error.to_ascii_lowercase();
            let usage_error =
                lower.contains("limit") || lower.contains("quota") || lower.contains("credit");
            usage_error.then_some(())?;
            usage_limits
                .and_then(|v| v.get("windows"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|w| {
                    w.get("usedPercent").and_then(Value::as_f64).is_some_and(|u| u >= 100.0)
                })
                .filter_map(|w| {
                    let seconds = w.get("resetsAt").and_then(Value::as_u64)?;
                    let reset = seconds.checked_mul(1000)?;
                    bounded_deadline(reset, now_ms)
                })
                .max()
        })
}

/// Retry-After and structured error data.
pub(in crate::hub) fn error_reset_at(data: Option<&Value>, now_ms: u64) -> Option<u64> {
    fn walk(v: &Value, now_ms: u64) -> Option<u64> {
        let o = v.as_object()?;
        for (key, value) in o {
            let lower = key.to_ascii_lowercase();
            if lower == "retryafterms" || lower == "retry_after_ms" {
                if let Some(n) = value.as_u64() {
                    return bounded_deadline(now_ms.saturating_add(n), now_ms);
                }
            } else if lower == "retryafter" || lower == "retry_after" || lower == "retry-after" {
                if let Some(n) = value.as_u64() {
                    return n
                        .checked_mul(1000)
                        .and_then(|ms| bounded_deadline(now_ms.saturating_add(ms), now_ms));
                }
                if let Some(s) = value.as_str() {
                    if let Some(ms) = duration_ms(s) {
                        return bounded_deadline(now_ms.saturating_add(ms), now_ms);
                    }
                    if let Some(n) = http_date_ms(s) {
                        return bounded_deadline(n, now_ms);
                    }
                }
            }
            if let Some(n) = value.as_object().and_then(|_| walk(value, now_ms)) {
                return Some(n);
            }
        }
        None
    }
    data.and_then(|v| walk(v, now_ms))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_router_claude_and_http_hints() {
        assert_eq!(reset_at("503 retry after 2401s", None, 1000), Some(2_402_000));
        assert_eq!(
            reset_at("usage limit|1760000000", None, 1_759_999_500_000),
            Some(1_760_000_000_000)
        );
        assert_eq!(reset_at("Retry-After: 2m", None, 1000), Some(121_000));
        assert_eq!(reset_at("Retry-After: 500 milliseconds", None, 1000), Some(1500));
        assert_eq!(reset_at("Retry-After: 999999999999999999d", None, 1000), None);
        assert_eq!(reset_at("Retry-After: 999999999999", None, 1000), None);
        assert_eq!(
            reset_at("You've hit your limit · resets 3pm", None, 12 * 3_600_000),
            Some(15 * 3_600_000)
        );
        assert_eq!(
            reset_at("You've hit your limit · resets 3pm", None, 16 * 3_600_000),
            Some(39 * 3_600_000)
        );
        let now = time::PrimitiveDateTime::new(
            time::Date::from_calendar_date(2026, time::Month::October, 30).unwrap(),
            time::Time::from_hms(12, 0, 0).unwrap(),
        )
        .assume_utc()
        .unix_timestamp_nanos() as u64
            / 1_000_000;
        assert_eq!(
            reset_at("You've hit your limit · resets 3pm (America/Los_Angeles)", None, now,),
            Some(now + 10 * 3_600_000)
        );
        assert_eq!(
            reset_at("You've hit your limit · resets 3pm (Europe/London)", None, now,),
            Some(now + 3 * 3_600_000)
        );
        let spring = time::PrimitiveDateTime::new(
            time::Date::from_calendar_date(2026, time::Month::March, 8).unwrap(),
            time::Time::from_hms(7, 30, 0).unwrap(),
        )
        .assume_utc()
        .unix_timestamp_nanos() as u64
            / 1_000_000;
        assert_eq!(
            reset_at("You've hit your limit · resets 12am (America/Los_Angeles)", None, spring,),
            Some(spring + 30 * 60_000)
        );
        let fall = time::PrimitiveDateTime::new(
            time::Date::from_calendar_date(2026, time::Month::November, 1).unwrap(),
            time::Time::from_hms(6, 30, 0).unwrap(),
        )
        .assume_utc()
        .unix_timestamp_nanos() as u64
            / 1_000_000;
        assert_eq!(
            reset_at("You've hit your limit · resets 3am (America/New_York)", None, fall,),
            Some(fall + 90 * 60_000)
        );
        let fall_back = time::PrimitiveDateTime::new(
            time::Date::from_calendar_date(2026, time::Month::November, 1).unwrap(),
            time::Time::from_hms(5, 45, 0).unwrap(),
        )
        .assume_utc()
        .unix_timestamp_nanos() as u64
            / 1_000_000;
        assert_eq!(
            reset_at("You've hit your limit · resets 1:30am (America/New_York)", None, fall_back,),
            Some(fall_back + 45 * 60_000)
        );
        assert_eq!(
            reset_at("You've hit your limit · resets 3pm (Europe/Berlin)", None, now,),
            Some(now + 2 * 3_600_000)
        );
        assert_eq!(reset_at("You've hit your limit · resets 3pm (€a)", None, now), None);
        let usage = serde_json::json!({
            "windows": [
                {"usedPercent": 100, "resetsAt": 1},
                {"usedPercent": 100, "resetsAt": 200},
                {"usedPercent": 100, "resetsAt": 300}
            ]
        });
        assert_eq!(reset_at("usage limit", Some(&usage), 150_000), Some(300_000));
        let far_usage = serde_json::json!({
            "windows": [{"usedPercent": 100, "resetsAt": 9_999_999_999u64}]
        });
        assert_eq!(reset_at("usage limit", Some(&far_usage), 0), None);
        assert_eq!(
            error_reset_at(Some(&serde_json::json!({"Retry-After":"2m"})), 1000),
            Some(121_000)
        );
        assert_eq!(
            error_reset_at(Some(&serde_json::json!({"Retry-After":"500ms"})), 1000),
            Some(1500)
        );
        assert_eq!(
            error_reset_at(Some(&serde_json::json!({"Retry-After":999999999999u64})), 1000),
            None
        );
        assert_eq!(
            error_reset_at(Some(&serde_json::json!({"details":{"Retry-After":"120"}})), 1000),
            Some(121_000)
        );
        assert_eq!(
            error_reset_at(
                Some(&serde_json::json!({"Retry-After":"Sun, 06 Nov 1994 08:49:37 GMT"})),
                784111000000
            ),
            Some(784111777000)
        );
        assert_eq!(
            reset_at(
                "limit",
                Some(&serde_json::json!({"windows":[{"usedPercent":100,"resetsAt":200}]})),
                0
            ),
            Some(200_000)
        );
    }
}
