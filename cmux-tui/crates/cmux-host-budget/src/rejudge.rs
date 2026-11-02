//! A verdict judged again with a newer memory pressure. The host-budget
//! contract lets the app read the pressure itself, for speed: macOS reports
//! each change through a dispatch source the moment it happens, between two
//! samples. The verdict may be the daemon's (with its session facts) or the
//! app's own, so this works on the verdict's JSON and keeps every other key.

use crate::{MEMORY_REASON, memory_reason, pressure_is_over, warning_line};
use serde_json::Value;

/// `verdict` with memory pressure `newer` (`normal`, `warn`, `critical` or
/// `unknown`): its memory reason replaced (the new one, if over, goes last),
/// `ok` and `warning` judged again with the verdict's own allowance
/// (`formula.pressure`, `normal` when absent). Unchanged when the pressure is
/// the same. `None` when `verdict` is not a verdict object or `newer` is not
/// one of those words.
pub fn with_pressure(verdict: &Value, newer: &str) -> Option<Value> {
    if !matches!(newer, "normal" | "warn" | "critical" | "unknown") {
        return None;
    }
    let mut v = verdict.clone();
    let obj = v.as_object_mut()?;
    let over = obj.get("over")?.as_array()?;
    if obj.get("pressure").and_then(Value::as_str) == Some(newer) {
        return Some(v);
    }
    let allowed = verdict.pointer("/formula/pressure").and_then(Value::as_str).unwrap_or("normal");
    let mut reasons: Vec<String> = over
        .iter()
        .filter_map(Value::as_str)
        .filter(|r| !r.starts_with(MEMORY_REASON))
        .map(str::to_owned)
        .collect();
    if pressure_is_over(newer, allowed) {
        reasons.push(memory_reason(newer));
    }
    let host = obj.get("host").and_then(Value::as_str).unwrap_or_default().to_owned();
    let ok = reasons.is_empty();
    // A verdict without a `warning` key (a test's, an older daemon's) gets none.
    if obj.contains_key("warning") {
        let warning = warning_line(&host, &reasons).map_or(Value::Null, Value::String);
        obj.insert("warning".into(), warning);
    }
    obj.insert("pressure".into(), newer.into());
    obj.insert("over".into(), reasons.into());
    obj.insert("ok".into(), ok.into());
    Some(v)
}
