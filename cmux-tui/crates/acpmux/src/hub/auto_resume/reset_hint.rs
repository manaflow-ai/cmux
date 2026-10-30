//! Provider reset and retry hints. Times are absolute milliseconds since Unix epoch.
use serde_json::Value;

fn seconds(s: &str) -> Option<u64> {
    s.trim().parse::<u64>().ok().filter(|v| *v > 0)
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
        let n = tail[..end].parse::<f64>().ok()?.max(0.0);
        let unit = tail[end..].trim_start().to_ascii_lowercase();
        let ms = if unit.starts_with("ms") {
            n
        } else if unit.starts_with('m') {
            n * 60_000.0
        } else if unit.starts_with('h') {
            n * 3_600_000.0
        } else {
            n * 1000.0
        };
        return Some(now_ms.saturating_add(ms.min(u64::MAX as f64) as u64));
    }
    if let Some(pipe) = text.rfind('|') {
        if let Some(v) = seconds(&text[pipe + 1..]) {
            return Some(as_deadline(v, now_ms));
        }
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
        .or_else(|| {
            // Saved Claude usage windows only describe a usage-limit failure.  A later
            // transport/gateway error must not inherit a stale weekly reset deadline.
            let lower = error.to_ascii_lowercase();
            let usage_error =
                lower.contains("limit") || lower.contains("quota") || lower.contains("credit");
            (!usage_error).then_some(())?;
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
                .min()
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
                    if let Some(n) = seconds(s) {
                        return Some(now_ms.saturating_add(n * 1000));
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
