//! Provider reset and retry hints. Times are absolute milliseconds since Unix epoch.
use serde_json::Value;

fn seconds(s: &str) -> Option<u64> {
    s.trim().parse::<u64>().ok().filter(|v| *v > 0)
}

/// Finds an absolute reset deadline in an agent error or saved Claude usage windows.
pub(super) fn reset_at(error: &str, usage_limits: Option<&Value>, now_ms: u64) -> Option<u64> {
    let lower = error.to_ascii_lowercase();
    // Router errors use `retry after 2401s`; Claude sometimes emits `|1760000000`.
    for marker in ["retry after ", "retry-after:", "retry_after:"] {
        if let Some(at) = lower.find(marker) {
            let tail = &lower[at + marker.len()..];
            let n: String = tail
                .chars()
                .skip_while(|c| c.is_ascii_whitespace())
                .take_while(|c| c.is_ascii_digit())
                .collect();
            if let Some(v) = seconds(&n) {
                return Some(if v < 10_000_000_000 {
                    now_ms.saturating_add(v.saturating_mul(1000))
                } else {
                    v.saturating_mul(1000)
                });
            }
        }
    }
    if let Some(pipe) = error.rfind('|') {
        let n = error[pipe + 1..].trim();
        if let Some(v) = seconds(n) {
            return Some(if v < 10_000_000_000 { v.saturating_mul(1000) } else { v });
        }
    }
    usage_limits
        .and_then(|v| v.get("windows"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|w| w.get("usedPercent").and_then(Value::as_f64).is_some_and(|u| u >= 100.0))
        .filter_map(|w| w.get("resetsAt").and_then(Value::as_u64).map(|s| s.saturating_mul(1000)))
        .min()
}

/// Retry-After and structured error data (`retryAfterMs`, `retry_after_ms`, `retryAfter`).
pub(in crate::hub) fn error_reset_at(data: Option<&Value>, now_ms: u64) -> Option<u64> {
    let o = data?.as_object()?;
    for key in ["retryAfterMs", "retry_after_ms"] {
        if let Some(v) = o.get(key).and_then(Value::as_u64) {
            return Some(now_ms.saturating_add(v));
        }
    }
    for key in ["retryAfter", "retry_after"] {
        if let Some(v) = o.get(key).and_then(Value::as_u64) {
            return Some(now_ms.saturating_add(v.saturating_mul(1000)));
        }
    }
    o.get("retry-after")
        .and_then(Value::as_str)
        .and_then(seconds)
        .map(|v| now_ms.saturating_add(v.saturating_mul(1000)))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_router_and_claude_hints() {
        assert_eq!(reset_at("503 retry after 2401s", None, 1000), Some(2_402_000));
        assert_eq!(reset_at("usage limit|1760000000", None, 0), Some(1_760_000_000_000));
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
