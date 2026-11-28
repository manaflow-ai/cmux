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
        // A Glob reads only below its pattern's literal folders (`docs/cloud/**` reads
        // `docs/cloud`), in its `path` or the working folder. One with none (`**/*.rs`) reads
        // that folder whole.
        if native.get("tool_name").and_then(Value::as_str) == Some("Glob")
            && let Some(pattern) = input.get("pattern").and_then(Value::as_str)
        {
            let literal = literal_folders(pattern);
            if !literal.as_os_str().is_empty() {
                let base =
                    if paths.len() > 1 { paths.pop() } else { None }.unwrap_or_else(|| cwd.clone());
                paths.push(base.join(literal));
            }
        }
    }
    let deadline = std::time::Instant::now() + timeout;
    if read_only && paths.len() > 1 {
        // The working folder is where the paths resolve, not something the tool reads.
        for path in paths.iter().skip(1) {
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

/// What a readiness check within its budget decided ([`check`]).
#[derive(Debug, PartialEq, Eq)]
pub enum Readiness {
    /// No marker, or every marker says ready: the tool may run.
    Ready,
    /// A marker says its sync still runs or failed (or the check failed otherwise): deny.
    NotReady(String),
    /// The budget ran out on a lock wait before any marker said anything: nothing is known
    /// to be syncing, so the caller lets the tool run rather than drop it.
    Undecided(String),
}

/// [`wait`], read as a [`Readiness`].
pub fn check(source: &str, event: &str, native: &Value, timeout: Duration) -> Readiness {
    match wait(source, event, native, timeout) {
        Ok(()) => Readiness::Ready,
        Err(error) if crate::sync_barrier::lock_wait_elapsed(&error) => {
            Readiness::Undecided(error.to_string())
        }
        Err(error) => Readiness::NotReady(error.to_string()),
    }
}

/// The leading components of a glob pattern that hold no glob character: `docs/cloud/*.md`
/// gives `docs/cloud`, `**/x` nothing. A pattern with none is a path itself.
fn literal_folders(pattern: &str) -> PathBuf {
    let mut literal = PathBuf::new();
    if pattern.starts_with('/') {
        literal.push("/");
    }
    for part in pattern.split('/').take_while(|part| !part.contains(['*', '?', '[', ']', '{', '}']))
    {
        if !part.is_empty() && part != "." {
            literal.push(part);
        }
    }
    literal
}

pub fn denial(reason: &str) -> Value {
    json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": format!("Repository sync is not ready: {reason}. Retry after synchronization completes.")
    }})
}
