//! `usage_insights`: the person's own efficiency insights, computed on the machine this server
//! runs on from its agent records; nothing is uploaded. The same report as
//! `cmux usage insights --json` (cli/usage_insights.rs, acpmux `usage_insights.rs`).

use serde_json::{Map, Value, json};

use super::{envelope, success, tool_error, v2_tools};

pub(super) const NAME: &str = "usage_insights";

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "title": "Analyze where agent tokens went",
        "description": format!("Efficiency insights from this machine's own agent records (Claude Code transcripts), computed locally; nothing leaves the machine. Today: cache waste by cause. Each cache-write token is split into the floor (append, session start, helper start) and avoidable rewrites (idle wake, compaction, model switch, shape change, lost under ttl, prefix edit), with tokens, list-price cost, the saving a warm cache would have given, the fix for each cause, a headline and the sessions with the most avoidable writes. hours is the window back from now (default {}, at most {}).", super::super::usage_insights::DEFAULT_HOURS, acpmux::usage_insights::MAX_HOURS),
        "inputSchema": {
            "type": "object",
            "properties": {
                "hours": {"type": "integer", "minimum": 1, "maximum": acpmux::usage_insights::MAX_HOURS, "description": "The window in hours back from now. Default 24."}
            }
        },
        "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
    })
}

/// The window; other arguments are ignored, so a newer or older caller's extra field never fails.
fn hours(arguments: &Map<String, Value>) -> Result<u64, String> {
    match arguments.get("hours") {
        None | Some(Value::Null) => Ok(super::super::usage_insights::DEFAULT_HOURS),
        Some(value) => value
            .as_u64()
            .filter(|hours| (1..=acpmux::usage_insights::MAX_HOURS).contains(hours))
            .ok_or_else(|| {
                format!(
                    "usage_insights hours must be an integer from 1 to {}",
                    acpmux::usage_insights::MAX_HOURS
                )
            }),
    }
}

pub(super) fn call(name: &str, arguments: &Map<String, Value>) -> Option<Value> {
    if name != NAME {
        return None;
    }
    Some(match hours(arguments) {
        Ok(hours) => {
            let report = super::super::usage_insights::cache_waste(hours);
            success(json!({"insights": [report]}), false)
        }
        Err(message) => tool_error(envelope(v2_tools::invalid(message), "not_run", None)),
    })
}

#[cfg(test)]
#[path = "usage_insights_tool_tests.rs"]
mod tests;
