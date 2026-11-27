//! Part of `Hub`; see `hub/mod.rs`. A Claude or Codex chat forked through an
//! earlier turn (Fork from Here, session replay's Continue from here,
//! `server/fork_through.rs`). Claude Code forks a conversation only at its
//! end (`--fork-session`), and Codex a thread only at its end, so the fork
//! resumes a copy of the parent's transcript that holds its first prompts
//! and everything they led to, under a new session id.

use cmux_json::JsonSet as _;
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
    claude_transcript_through_checked(store, parent, cut_ms, None)
}

pub(super) fn claude_transcript_through_checked(
    store: &Path,
    parent: &str,
    cut_ms: u64,
    expected: Option<usize>,
) -> anyhow::Result<String> {
    let file = crate::adopt::is_bare_id(parent)
        .then(|| crate::adopt::find_claude(store, parent))
        .flatten()
        .ok_or_else(|| anyhow::anyhow!("no Claude transcript for session {parent}"))?;
    let id = uuid::Uuid::now_v7().to_string();
    let mut lines = Vec::new();
    let mut prompts = 0;
    let mut answered = false;
    for line in BufReader::new(std::fs::File::open(&file)?).lines() {
        let line = line?;
        let mut record: Value = match serde_json::from_str(&line) {
            Ok(record) => record,
            Err(e) if expected.is_some() => return Err(e.into()),
            Err(_) => continue,
        };
        if is_prompt(&record) {
            anyhow::ensure!(
                expected.is_none() || prompts == 0 || answered,
                "native history omits a retained answer"
            );
            anyhow::ensure!(
                expected.is_none() || written_ms(&record).is_some(),
                "native prompt has no boundary timestamp"
            );
            if written_ms(&record).is_some_and(|at| at >= cut_ms) {
                break;
            }
            prompts += 1;
            answered = false;
        } else if record.get("type").and_then(Value::as_str) == Some("assistant") {
            // Use the replay contract: thinking, sidechains and nonterminal text do
            // not prove the retained main conversation reached its completed answer.
            answered |= crate::adopt_replay::ends_turn("claude", &record);
        }
        if record.get("sessionId").is_some_and(Value::is_string) {
            record.set("sessionId", Value::String(id.clone()));
        }
        lines.push(serde_json::to_string(&record)?);
    }
    // Claude started this conversation after that turn (a failover starts
    // one fresh): resuming the copy would hold none of the chat's turns.
    anyhow::ensure!(prompts > 0, "Claude's conversation for this chat starts after that turn");
    anyhow::ensure!(
        expected.is_none_or(|n| prompts == n && answered),
        "native history does not cover the complete recorded prefix"
    );
    let mut copy = crate::home_fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(file.with_file_name(format!("{id}.jsonl")))?;
    for line in lines {
        writeln!(copy, "{line}")?;
    }
    Ok(id)
}

/// What a fork of a working chat tells its own Claude conversation about a tool call
/// still running in the chat: it never finished there.
const CUT_TOOL_RESULT: &str =
    "The chat was forked while this tool ran; it did not finish in this fork.";

/// Copies the whole transcript of Claude session `parent` as it is now, while
/// its turn may still run, beside the parent's, and returns the copy's session
/// id. A tool call stored with no result yet gets one in the copy only (an error
/// result saying the fork cut it off, as Claude Code stores an interrupted tool):
/// Claude's API refuses a conversation whose tool call has no result.
///
/// `streamed` is the running turn's reply text as the chat streamed it, by API
/// message id, in order (`Hub::streamed_reply`). Claude Code stores a message's
/// text only once its block ends, so the text it was streaming when the fork cut
/// it is in acpmux's log alone: the fork shows it, and without it the fork's agent
/// remembered no such reply (Claude fills the gap with "No response requested.",
/// cmux#50021). A message whose text the transcript lacks ends the copy as an
/// assistant line, so the fork's agent knows what its chat shows it said.
pub(super) fn claude_transcript_now(
    store: &Path,
    parent: &str,
    streamed: &[(String, String)],
) -> anyhow::Result<String> {
    let file = crate::adopt::is_bare_id(parent)
        .then(|| crate::adopt::find_claude(store, parent))
        .flatten()
        .ok_or_else(|| anyhow::anyhow!("no Claude transcript for session {parent}"))?;
    let id = uuid::Uuid::now_v7().to_string();
    let mut lines = Vec::new();
    let mut prompts = 0;
    let mut unresolved: Vec<String> = Vec::new();
    let mut last: Option<Value> = None;
    // The last line in Claude's uuid chain, which a line added to the copy follows.
    let mut last_uuid: Option<Value> = None;
    // The API messages whose text the transcript holds, and the model the last one ran.
    let mut stored_text = std::collections::HashSet::new();
    let mut model: Option<Value> = None;
    for line in BufReader::new(std::fs::File::open(&file)?).lines() {
        let Ok(mut record) = serde_json::from_str::<Value>(&line?) else { continue };
        prompts += usize::from(is_prompt(&record));
        if record.get("type").and_then(Value::as_str) == Some("assistant") {
            if let Some(m) = record.pointer("/message/model").filter(|m| m.is_string()) {
                model = Some(m.clone());
            }
            let has_text = record
                .pointer("/message/content")
                .and_then(Value::as_array)
                .is_some_and(|blocks| {
                    blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                });
            if let Some(message) = record.pointer("/message/id").and_then(Value::as_str)
                && has_text
            {
                stored_text.insert(message.to_owned());
            }
        }
        if let Some(Value::Array(blocks)) = record.pointer("/message/content") {
            for b in blocks {
                let id = |key: &str| b.get(key).and_then(Value::as_str).map(str::to_owned);
                match b.get("type").and_then(Value::as_str) {
                    Some("tool_use") => unresolved.extend(id("id")),
                    Some("tool_result") => {
                        let done = id("tool_use_id");
                        unresolved.retain(|u| Some(u) != done.as_ref());
                    }
                    _ => {}
                }
            }
        }
        if record.get("sessionId").is_some_and(Value::is_string) {
            record.set("sessionId", Value::String(id.clone()));
        }
        lines.push(serde_json::to_string(&record)?);
        // Claude's bookkeeping lines (no uuid) carry no folder or version: an added line takes
        // those from the last line in the chain, or the last line when none has a uuid.
        if let Some(uuid) = record.get("uuid").filter(|u| u.is_string()) {
            last_uuid = Some(uuid.clone());
            last = Some(record);
        } else if last_uuid.is_none() {
            last = Some(record);
        }
    }
    anyhow::ensure!(prompts > 0, "Claude has not stored this chat's conversation yet");
    // A line the copy adds: it follows the transcript's last chained one, with its time, folder and
    // version, and Claude's uuid chain (`parentUuid`) when the transcript keeps one.
    let mut added = |mut line: Value| -> anyhow::Result<()> {
        if let Some(last) = &last {
            for key in ["timestamp", "cwd", "version", "gitBranch", "userType", "entrypoint"] {
                if let Some(v) = last.get(key) {
                    line.set(key, v.clone());
                }
            }
        }
        if let Some(parent_uuid) = &last_uuid {
            let uuid = Value::String(uuid::Uuid::now_v7().to_string());
            line.set("parentUuid", parent_uuid.clone());
            line.set("uuid", uuid.clone());
            last_uuid = Some(uuid);
        }
        lines.push(serde_json::to_string(&line)?);
        Ok(())
    };
    if !unresolved.is_empty() {
        let content: Vec<Value> = unresolved
            .iter()
            .map(|u| {
                serde_json::json!({"type": "tool_result", "tool_use_id": u, "is_error": true, "content": CUT_TOOL_RESULT})
            })
            .collect();
        added(serde_json::json!({
            "type": "user",
            "sessionId": id,
            "message": {"role": "user", "content": content},
        }))?;
    }
    for (message, text) in streamed {
        if text.trim().is_empty() || stored_text.contains(message) {
            continue;
        }
        let mut reply = serde_json::json!({
            "id": message, "type": "message", "role": "assistant",
            "content": [{"type": "text", "text": text}],
            "stop_reason": null, "stop_sequence": null,
        });
        if let Some(model) = &model {
            reply.set("model", model.clone());
        }
        added(serde_json::json!({
            "type": "assistant",
            "isSidechain": false,
            "sessionId": id,
            "message": reply,
        }))?;
    }
    let mut copy = crate::home_fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(file.with_file_name(format!("{id}.jsonl")))?;
    for line in lines {
        writeln!(copy, "{line}")?;
    }
    Ok(id)
}

/// Copies the rollout of Codex thread `parent` in the store at `store` (a
/// CODEX_HOME) up to its first turn started at or after `cut_ms` (as
/// `claude_transcript_through`), beside the parent's under a new thread id,
/// and returns that id. Codex finds a thread by the id in its rollout's file
/// name; its `session_meta` names the thread too.
///
/// The cut is a turn's start, not any record: Codex stamps a record when its
/// writer flushes it, so the kept turn's last records (`task_complete`, token
/// counts) can carry a time after the chat moved past it.
pub(super) fn codex_rollout_through(
    store: &Path,
    parent: &str,
    cut_ms: u64,
) -> anyhow::Result<String> {
    codex_rollout_through_checked(store, parent, cut_ms, None)
}

pub(super) fn codex_rollout_through_checked(
    store: &Path,
    parent: &str,
    cut_ms: u64,
    expected: Option<usize>,
) -> anyhow::Result<String> {
    let file = crate::adopt::is_bare_id(parent)
        .then(|| crate::adopt::find_codex(store, parent))
        .flatten()
        .ok_or_else(|| anyhow::anyhow!("no Codex rollout for thread {parent}"))?;
    let name = file.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    let stem = name
        .strip_suffix(&format!("{parent}.jsonl"))
        .ok_or_else(|| anyhow::anyhow!("unexpected Codex rollout name {name}"))?;
    let id = uuid::Uuid::now_v7().to_string();
    let copy_name = format!("{stem}{id}.jsonl");
    let mut lines = Vec::new();
    let mut turns = 0;
    let (mut user, mut answer, mut complete) = (false, false, true);
    for line in BufReader::new(std::fs::File::open(&file)?).lines() {
        let line = line?;
        let mut record: Value = match serde_json::from_str(&line) {
            Ok(record) => record,
            Err(e) if expected.is_some() => return Err(e.into()),
            Err(_) => continue,
        };
        let kind = |key: &str| record.pointer(key).and_then(Value::as_str).map(str::to_owned);
        let (kind, event) = (kind("/type"), kind("/payload/type"));
        if kind.as_deref() == Some("session_meta") {
            if let Some(thread) =
                record.pointer_mut("/payload/id").filter(|v| v.as_str() == Some(parent))
            {
                *thread = Value::String(id.clone());
            }
        } else if is_turn_start(kind.as_deref(), event.as_deref()) {
            anyhow::ensure!(
                expected.is_none() || written_ms(&record).is_some(),
                "native prompt has no boundary timestamp"
            );
            if written_ms(&record).is_some_and(|at| at >= cut_ms) {
                break;
            }
            if turns > 0 {
                complete &= user && answer;
            }
            turns += 1;
            user = false;
            answer = false;
        } else if kind.as_deref() == Some("response_item") && event.as_deref() == Some("message") {
            let content = record
                .pointer("/payload/content")
                .and_then(Value::as_array)
                .is_some_and(|blocks| !blocks.is_empty());
            match record.pointer("/payload/role").and_then(Value::as_str) {
                Some("user") => user |= content,
                Some("assistant") => {
                    answer |= content
                        && record.pointer("/payload/phase").and_then(Value::as_str)
                            != Some("commentary")
                }
                _ => {}
            }
        }
        lines.push(serde_json::to_string(&record)?);
    }
    // Codex started this thread after that turn (a failover starts one
    // fresh): resuming the copy would hold none of the chat's turns.
    anyhow::ensure!(turns > 0, "Codex's conversation for this chat starts after that turn");
    anyhow::ensure!(
        expected.is_none_or(|n| turns == n && complete && user && answer),
        "native history does not cover the complete recorded prefix"
    );
    let mut copy = crate::home_fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(file.with_file_name(copy_name))?;
    for line in lines {
        writeln!(copy, "{line}")?;
    }
    Ok(id)
}

/// A Codex rollout record that opens a turn: `task_started`, written before
/// the turn's context and the person's message.
fn is_turn_start(kind: Option<&str>, event: Option<&str>) -> bool {
    kind == Some("event_msg") && event == Some("task_started")
}

/// A line the person sent: a user message that is not a tool result, a
/// compaction summary, a meta line, a subagent's or one Claude Code wrote
/// itself (a task notification, another session's message).
fn is_prompt(record: &Value) -> bool {
    let flag = |key: &str| record.get(key).and_then(Value::as_bool).unwrap_or(false);
    if record.get("type").and_then(Value::as_str) != Some("user")
        || flag("isMeta")
        || flag("isSidechain")
        || flag("isCompactSummary")
        || !crate::adopt_replay::from_person(record)
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

#[cfg(test)]
#[path = "fork_at_streamed_reply_tests.rs"]
mod streamed_reply_tests;
