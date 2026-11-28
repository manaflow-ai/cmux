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

/// A leading "nov 27, " (Claude's weekly window: "resets Nov 27, 7am (UTC)"): its month (1-12),
/// day and the words after it. A clock alone ("resets 7am") has none.
fn month_day(tail: &str) -> Option<(u32, u32, &str)> {
    const MONTHS: [&str; 12] =
        ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    let word = tail.bytes().take_while(u8::is_ascii_alphabetic).count();
    let (name, rest) = tail.split_at_checked(word)?;
    let month = MONTHS.iter().position(|m| name.len() >= 3 && name.starts_with(m))? as u32 + 1;
    let rest = rest.trim_start_matches('.').trim_start();
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    let (day, rest) = rest.split_at_checked(digits)?;
    let day = day.parse::<u32>().ok().filter(|d| (1..=31).contains(d))?;
    let rest = rest.trim_start_matches(',').trim_start();
    let rest = rest.strip_prefix("at ").unwrap_or(rest).trim_start();
    Some((month, day, rest))
}

fn clock_reset(error: &str, now_ms: u64) -> Option<u64> {
    let lower = error.to_ascii_lowercase();
    let at = lower.find("resets ")? + "resets ".len();
    let tail = lower.get(at..)?.trim_start();
    // A reset on a named day is that day's clock (cmux#55066: with the date unread, a chat out of
    // its weekly usage was sent its continuation every few minutes until the reset).
    let (date, tail) = match month_day(tail) {
        Some((month, day, rest)) => (Some((month, day)), rest),
        None => (None, tail),
    };
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
        if let Some((month, day)) = date {
            use chrono::Datelike as _;
            let on = |year: i32| chrono::NaiveDate::from_ymd_opt(year, month, day);
            let year = local_now.year();
            let mut deadline = named_deadline_ms(named, on(year)?, hour, minute, now_ms)?;
            if deadline <= now_ms {
                deadline = named_deadline_ms(named, on(year + 1)?, hour, minute, now_ms)?;
            }
            return bounded_deadline(deadline, now_ms);
        }
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
    if let Some((month, day)) = date {
        let at = |year: i32| -> Option<u64> {
            let month = time::Month::try_from(u8::try_from(month).ok()?).ok()?;
            let date = time::Date::from_calendar_date(year, month, u8::try_from(day).ok()?).ok()?;
            let nanos = time::PrimitiveDateTime::new(date, clock).assume_offset(offset);
            u64::try_from(nanos.unix_timestamp_nanos() / 1_000_000).ok()
        };
        let mut deadline = at(local_now.year())?;
        if deadline <= now_ms {
            deadline = at(local_now.year() + 1)?;
        }
        return bounded_deadline(deadline, now_ms);
    }
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

/// The wait, in ms, an error's own `retry after Ss` (or `Retry-After`) names, as [`reset_at`] reads it.
pub fn retry_after_ms(text: &str) -> Option<u64> {
    retry_after(text, 0)
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
pub(in crate::hub) fn reset_at(
    error: &str,
    usage_limits: Option<&Value>,
    now_ms: u64,
) -> Option<u64> {
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
#[path = "reset_hint_tests.rs"]
mod tests;
