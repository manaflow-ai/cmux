//! A verdict judged again with a newer memory pressure. The host-budget
//! contract lets the app read the pressure itself, for speed: macOS reports
//! each change through a dispatch source the moment it happens, between two
//! samples. The verdict may be the daemon's (with its session facts) or the
//! app's own, so this works on the verdict's JSON and keeps every other key.

use serde_json::Value;

/// `verdict` with memory pressure `newer` (`normal`, `warn`, `critical` or
/// `unknown`): its memory reason replaced (the new one, if over, goes last),
/// `ok` and `warning` judged again with the verdict's own allowance
/// (`formula.pressure`, `normal` when absent). Unchanged when the pressure is
/// the same. `None` when `verdict` is not a verdict object or `newer` is not
/// one of those words.
pub fn with_pressure(verdict: &Value, _newer: &str) -> Option<Value> {
    // Red step: the rule is not ported yet.
    Some(verdict.clone())
}
