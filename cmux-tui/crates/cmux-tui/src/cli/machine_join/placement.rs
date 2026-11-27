//! `cmux machine placement on|off|status`: whether the team's new machines book its own joined
//! machines first.

use std::io::Write;

use serde_json::{Value, json};

use super::{CallError, Failure, Platform};
use crate::cli::{OutputMode, UsageError};

const USAGE: &str = "usage: cmux machine placement on|off|status";

/// `placement on|off|status`'s one word: `Some(enabled)` sets it, `None` reads it.
pub(super) fn parse_state(words: &[String]) -> Result<Option<bool>, UsageError> {
    match words {
        [state] if state == "on" => Ok(Some(true)),
        [state] if state == "off" => Ok(Some(false)),
        [state] if state == "status" => Ok(None),
        _ => Err(UsageError::new(USAGE)),
    }
}

/// `machine placement on|off|status`: PUT or GET `/v1/machines/joined/placement`. On, the team's
/// new machines book a free slot on one of its own joined machines before a new VM is made
/// (cmux-platform's `setJoinedPlacement`); only a team owner or admin, as a person, sets it.
pub(super) fn run(
    platform: &Platform,
    set: Option<bool>,
    output: OutputMode,
    out: &mut dyn Write,
) -> Result<i32, Failure> {
    let path = "/v1/machines/joined/placement";
    let answer = match set {
        Some(enabled) => {
            platform.request(reqwest::Method::PUT, path, Some(json!({ "enabled": enabled })))
        }
        None => platform.request(reqwest::Method::GET, path, None),
    }
    .map_err(|error| match error {
        CallError::Status { status: 404, .. } => Failure::new(
            "machine_join.unavailable",
            "joined placement isn't available on this server (it answered 404)",
        ),
        CallError::Status { status: 403, code, .. } => Failure::new(
            "machine_join.forbidden",
            format!(
                "only a team owner or admin, signed in as a person, turns joined placement on or off ({})",
                format!("403 {code}").trim_end()
            ),
        ),
        error => error.failure(if set.is_some() { "the placement change" } else { "the placement read" }),
    })?;
    let Some(enabled) = answer.get("enabled").and_then(Value::as_bool) else {
        return Err(Failure::new(
            "machine_join.unreadable",
            "the cmux platform's placement answer has no enabled field",
        ));
    };
    let updated_at = answer.get("updated_at").and_then(Value::as_u64).unwrap_or(0);
    let io = |e: std::io::Error| Failure::new("io", e.to_string());
    match output {
        OutputMode::Human => {
            let state = if enabled { "on" } else { "off" };
            let when = if updated_at == 0 { " (never set)" } else { "" };
            writeln!(out, "joined placement: {state}{when}").map_err(io)?;
        }
        OutputMode::Json | OutputMode::JsonLines => {
            writeln!(out, "{}", json!({ "enabled": enabled, "updated_at": updated_at }))
                .map_err(io)?;
        }
        OutputMode::Quiet => {}
    }
    Ok(0)
}
