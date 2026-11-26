//! Native pre-tool readiness checks. These wait for an existing sync, but do
//! not hold a lease through a tool running in another process.
use std::{io, path::PathBuf, time::Duration};

use serde_json::{Value, json};

pub const WAIT: Duration = Duration::from_secs(30);

pub fn wait(source: &str, event: &str, native: &Value, timeout: Duration) -> io::Result<()> {
    if !matches!(source, "claude" | "codex") || event != "PreToolUse" {
        return Ok(());
    }
    let cwd = native
        .get("cwd")
        .or_else(|| native.get("working_directory"))
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .map(Ok)
        .unwrap_or_else(std::env::current_dir)?;
    let cwd = if cwd.is_absolute() { cwd } else { std::env::current_dir()?.join(cwd) };
    let mut paths = vec![cwd.clone()];
    if let Some(input) = native.get("tool_input") {
        for key in ["file_path", "path", "cwd", "workdir", "working_directory", "notebook_path"] {
            if let Some(path) = input.get(key).and_then(Value::as_str) {
                let path = PathBuf::from(path);
                paths.push(if path.is_absolute() { path } else { cwd.join(path) });
            }
        }
    }
    let deadline = std::time::Instant::now() + timeout;
    for path in paths {
        crate::sync_barrier::wait_ready(
            &path,
            deadline.saturating_duration_since(std::time::Instant::now()),
        )?;
    }
    Ok(())
}

pub fn denial(reason: &str) -> Value {
    json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": format!("Repository sync is not ready: {reason}. Retry after synchronization completes.")
    }})
}
