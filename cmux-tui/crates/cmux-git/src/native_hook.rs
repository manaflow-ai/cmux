//! Native pre-tool readiness checks. These wait for an existing sync, but do
//! not hold a lease through a tool running in another process.
use std::{io, path::PathBuf, time::Duration};

use serde_json::{Value, json};

pub const WAIT: Duration = Duration::from_secs(30);

/// Tools that only read the paths their input names: in a checkout still filling past its
/// head they go ahead once those paths are in place ([`crate::sync_barrier::wait_filled`]),
/// not the whole checkout. One that names no path reads the working folder whole.
const READ_ONLY: &[&str] = &["Read", "Glob", "Grep", "LS", "NotebookRead"];

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
    let read_only = native
        .get("tool_name")
        .and_then(Value::as_str)
        .is_some_and(|tool| READ_ONLY.contains(&tool));
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
    if read_only && paths.len() > 1 {
        // The working folder is where the paths resolve, not something the tool reads.
        for path in &paths[1..] {
            crate::sync_barrier::wait_filled(
                path,
                deadline.saturating_duration_since(std::time::Instant::now()),
            )?;
        }
        return Ok(());
    }
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
