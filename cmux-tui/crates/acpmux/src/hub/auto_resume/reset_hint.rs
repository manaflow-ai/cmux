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
        None => return s.parse::<u64>().ok().map(|seconds| seconds.saturating_mul(1000)),
    };
    let n = s[..split].parse::<f64>().ok()?;
    if !n.is_finite() || n <= 0.0 {
        return None;
    }
    let unit = s[split..].trim().to_ascii_lowercase();
    let multiplier = if unit.starts_with("ms") {
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
    } else if digits.len() == 4 {
        (digits[..2].parse::<i32>().ok()?, digits[2..].parse::<i32>().ok()?)
    } else {
        (digits.parse::<i32>().ok()?, 0)
    };
    let hours = i8::try_from(sign * h).ok()?;
    let minutes = i8::try_from(sign * m).ok()?;
    time::UtcOffset::from_hms(hours, minutes, 0).ok()
}

fn named_deadline_ms(zone: Tz, date: chrono::NaiveDate, hour: u8, minute: u8) -> Option<u64> {
    let local = date.and_hms_opt(u32::from(hour), u32::from(minute), 0)?;
    let date_time = match zone.from_local_datetime(&local) {
        LocalResult::Single(value) => value,
        LocalResult::Ambiguous(first, second) => first.min(second),
        LocalResult::None => return None,
    };
    u64::try_from(date_time.timestamp_millis()).ok()
}

fn clock_reset(error: &str, now_ms: u64) -> Option<u64> {
    let lower = error.to_ascii_lowercase();
    let at = lower.find("resets ")? + "resets ".len();
    let tail = lower[at..].trim_start();
    let mut end = 0;
    while end < tail.len() && tail.as_bytes()[end].is_ascii_digit() {
        end += 1;
    }
    if end == 0 {
        return None;
    }
    let mut hour = tail[..end].parse::<u8>().ok()?;
    let mut minute = 0u8;
    let mut rest = &tail[end..];
    if let Some(after_colon) = rest.strip_prefix(':') {
        let mut minute_end = 0;
        while minute_end < after_colon.len() && after_colon.as_bytes()[minute_end].is_ascii_digit()
        {
            minute_end += 1;
        }
        minute = after_colon[..minute_end].parse::<u8>().ok()?;
        rest = &after_colon[minute_end..];
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
        let mut deadline = named_deadline_ms(named, local_now.date(), hour, minute)?;
        if deadline <= now_ms {
            deadline = named_deadline_ms(
                named,
                local_now.date() + chrono::Duration::days(1),
                hour,
                minute,
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

fn as_deadline(v: u64, now_ms: u64) -> u64 {
    if v >= 10_000_000_000 {
        v
    } else if v >= 1_000_000_000 {
        v.saturating_mul(1000)
    } else {
        now_ms.saturating_add(v.saturating_mul(1000))
    }
}

/// Parse an IMF-fixdate without adding a date crate to the daemon.
fn http_date_ms(s: &str) -> Option<u64> {
    let (_, rest) = s.trim().split_once(", ")?;
    let p: Vec<&str> = rest.split_whitespace().collect();
    if p.len() != 5 || p[4] != "GMT" {
        return None;
    }
    let day = p[0].parse::<u32>().ok()?;
    let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        .iter()
        .position(|m| m.eq_ignore_ascii_case(p[1]))? as u32
        + 1;
    let year = p[2].parse::<i64>().ok()?;
    let t: Vec<&str> = p[3].split(':').collect();
    if t.len() != 3 {
        return None;
    }
    let hour = t[0].parse::<u32>().ok()?;
    let minute = t[1].parse::<u32>().ok()?;
    let second = t[2].parse::<u32>().ok()?;
    if !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let y = year - i64::from(month <= 2);
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
        let tail = &text[at + marker.len()..];
        let tail =
            tail.trim_start_matches(|c: char| c == ':' || c == '=' || c.is_ascii_whitespace());
        let mut end = 0;
        while end < tail.len()
            && (tail.as_bytes()[end].is_ascii_digit() || tail.as_bytes()[end] == b'.')
        {
            end += 1;
        }
        if end == 0 {
            if let Some(deadline) = http_date_ms(tail) {
                return Some(deadline);
            }
            continue;
        }
        let ms = duration_ms(tail)?;
        return Some(now_ms.saturating_add(ms));
    }
    if let Some(pipe) = text.rfind('|')
        && let Some(v) = seconds(&text[pipe + 1..])
    {
        return Some(as_deadline(v, now_ms));
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
                    lower[at + 10..].chars().take_while(|c| c.is_ascii_digit()).collect();
                seconds(&n).map(|v| as_deadline(v, now_ms))
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
                    w.get("resetsAt").and_then(Value::as_u64).map(|s| s.saturating_mul(1000))
                })
                .filter(|reset| *reset > now_ms)
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
                    return Some(now_ms.saturating_add(n));
                }
            } else if lower == "retryafter" || lower == "retry_after" || lower == "retry-after" {
                if let Some(n) = value.as_u64() {
                    return Some(now_ms.saturating_add(n.saturating_mul(1000)));
                }
                if let Some(s) = value.as_str() {
                    if let Some(ms) = duration_ms(s) {
                        return Some(now_ms.saturating_add(ms));
                    }
                    if let Some(n) = http_date_ms(s) {
                        return Some(n);
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
        assert_eq!(reset_at("usage limit|1760000000", None, 0), Some(1_760_000_000_000));
        assert_eq!(reset_at("Retry-After: 2m", None, 1000), Some(121_000));
        assert_eq!(reset_at("Retry-After: 999999999999999999d", None, 1000), None);
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
        assert_eq!(
            reset_at("You've hit your limit · resets 3pm (Europe/Berlin)", None, now,),
            Some(now + 2 * 3_600_000)
        );
        let usage = serde_json::json!({
            "windows": [
                {"usedPercent": 100, "resetsAt": 1},
                {"usedPercent": 100, "resetsAt": 200},
                {"usedPercent": 100, "resetsAt": 300}
            ]
        });
        assert_eq!(reset_at("usage limit", Some(&usage), 150_000), Some(300_000));
        assert_eq!(
            error_reset_at(Some(&serde_json::json!({"Retry-After":"2m"})), 1000),
            Some(121_000)
        );
        assert_eq!(
            error_reset_at(Some(&serde_json::json!({"Retry-After":"500ms"})), 1000),
            Some(1500)
        );
        assert_eq!(
            error_reset_at(Some(&serde_json::json!({"details":{"Retry-After":"120"}})), 1000),
            Some(121_000)
        );
        assert_eq!(
            error_reset_at(
                Some(&serde_json::json!({"Retry-After":"Sun, 06 Nov 1994 08:49:37 GMT"})),
                0
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
