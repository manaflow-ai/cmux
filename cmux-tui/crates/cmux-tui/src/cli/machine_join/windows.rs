//! The join line for a Windows PC, which pastes it in PowerShell beside the `sh` one:
//!
//! ```text
//!  $env:CMUX_JOIN='cmj_…'; irm <origin>/v1/machines/join.ps1 | iex
//! ```
//!
//! Its script (`cmux-tui/scripts/machine-join.ps1`) takes the token out of the environment before
//! it starts anything. The token is `cmj_` and `A-Z a-z 0-9 _ -` only (`valid_token`), so it
//! needs no escaping inside the single quotes.

use serde_json::{Value, json};
use std::io::Write;

/// The PowerShell line for `token` on the platform at `origin`.
pub(super) fn line(origin: &str, token: &str) -> String {
    format!(" $env:CMUX_JOIN='{token}'; irm {origin}/v1/machines/join.ps1 | iex")
}

/// Adds `windowsLine` and `windowsScriptUrl` to `machine add`'s summary.
pub(super) fn add(summary: &mut Value, origin: &str, token: &str) {
    if let Some(summary) = summary.as_object_mut() {
        summary.insert("windowsLine".into(), json!(line(origin, token)));
        summary.insert("windowsScriptUrl".into(), json!(format!("{origin}/v1/machines/join.ps1")));
    }
}

/// The human output's Windows paragraph, from the summary [`add`] filled.
pub(super) fn print(out: &mut dyn Write, summary: &Value) -> std::io::Result<()> {
    match summary.get("windowsLine").and_then(Value::as_str) {
        Some(line) => writeln!(out, "On a Windows PC, in PowerShell:\n\n{line}\n"),
        None => Ok(()),
    }
}
