//! Part of `Hub`; see `hub/mod.rs`. A Claude chat forked through an earlier
//! turn (session replay's Continue from here, `server/fork_through.rs`).
//! Claude Code forks a conversation only at its end (`--fork-session`), so
//! the fork resumes a copy of the parent's transcript that holds its first
//! prompts and everything they led to, under a new session id.

use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

/// Copies the transcript of Claude session `parent` in the store at `store`
/// (a CLAUDE_CONFIG_DIR) up to its first prompt written at or after `cut_ms`
/// (Unix milliseconds, when the chat moved past the turn the fork keeps), beside the
/// parent's, and returns the copy's session id.
///
/// The cut is a time, not a count of the chat's prompts: an adopted chat's
/// earlier history, a prompt Claude never stored and Claude's own
/// interruption lines all make the two counts differ.
pub(super) fn claude_transcript_through(
    store: &Path,
    parent: &str,
    cut_ms: u64,
) -> anyhow::Result<String> {
    let file = crate::adopt::is_bare_id(parent)
        .then(|| crate::adopt::find_claude(store, parent))
        .flatten()
        .ok_or_else(|| anyhow::anyhow!("no Claude transcript for session {parent}"))?;
    let id = uuid::Uuid::now_v7().to_string();
    let mut lines = Vec::new();
    let mut prompts = 0;
    for line in BufReader::new(std::fs::File::open(&file)?).lines() {
        let Ok(mut record) = serde_json::from_str::<Value>(&line?) else { continue };
        if is_prompt(&record) {
            if written_ms(&record).is_some_and(|at| at >= cut_ms) {
                break;
            }
            prompts += 1;
        }
        if record.get("sessionId").is_some_and(Value::is_string) {
            record["sessionId"] = Value::String(id.clone());
        }
        lines.push(serde_json::to_string(&record)?);
    }
    // Claude started this conversation after that turn (a failover starts
    // one fresh): resuming the copy would hold none of the chat's turns.
    anyhow::ensure!(prompts > 0, "Claude's conversation for this chat starts after that turn");
    let mut copy = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(file.with_file_name(format!("{id}.jsonl")))?;
    for line in lines {
        writeln!(copy, "{line}")?;
    }
    Ok(id)
}

/// A line the person sent: a user message that is not a tool result, a
/// compaction summary, a meta line or a subagent's.
fn is_prompt(record: &Value) -> bool {
    let flag = |key: &str| record.get(key).and_then(Value::as_bool).unwrap_or(false);
    if record.get("type").and_then(Value::as_str) != Some("user")
        || flag("isMeta")
        || flag("isSidechain")
        || flag("isCompactSummary")
    {
        return false;
    }
    match record.pointer("/message/content") {
        Some(Value::String(_)) => true,
        Some(Value::Array(blocks)) => {
            !blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
        }
        _ => false,
    }
}

/// When Claude wrote the record, from its `timestamp`.
fn written_ms(record: &Value) -> Option<u64> {
    let at = record.get("timestamp")?.as_str()?;
    cmux_chat_index::parse_rfc3339_ms(at).and_then(|ms| u64::try_from(ms).ok())
}
