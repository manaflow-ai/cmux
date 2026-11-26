//! Part of `Hub`'s context surgery (`surgery.rs`): the same masking over a Codex rollout
//! (`<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<thread>.jsonl`), RFD 0149's "Codex
//! rollouts" row.
//!
//! What the model reads of a resumed Codex thread is its rollout's `response_item`s after the last
//! `compacted` record (whose replacement history stands in for everything before it), so only
//! those are masked: every `function_call_output` and `custom_tool_call_output` older than the
//! last [`MaskOptions::keep_turns`] turns (`event_msg` `task_started`) and larger than
//! [`MaskOptions::min_chars`] gets the stub Claude's copy gets, naming its call (`shell cat
//! a.rs`). Calls, messages, reasoning (encrypted content included) and every `event_msg` the app
//! shows are copied verbatim; no record is added or removed, so each call keeps its output by
//! `call_id`. A rollout that does not parse, or one with a call that has no output yet, is
//! refused.
//!
//! The copy is a new thread: Codex finds a thread by the id in its rollout's file name, and
//! `session_meta` names it too, so both change (as `fork_at::codex_rollout_through` copies one).
//! The original is never changed or deleted.

use super::surgery::{Masked, MaskOptions, refetch_key, stub};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

fn kind(record: &Value) -> (Option<&str>, Option<&str>) {
    (
        record.get("type").and_then(Value::as_str),
        record.pointer("/payload/type").and_then(Value::as_str),
    )
}

/// A call's input as the stub and the refetch count read it: its JSON `arguments` (a shell call's
/// `command`, `cmd` as `command`), a custom tool's `input`, a local shell call's `action`.
pub(crate) fn call_input(payload: &Value) -> Value {
    let mut input = match payload.get("arguments").and_then(Value::as_str) {
        Some(args) => serde_json::from_str(args).unwrap_or(Value::Null),
        None => payload
            .get("action")
            .or_else(|| payload.get("input"))
            .cloned()
            .unwrap_or(Value::Null),
    };
    if let Value::String(text) = input {
        input = serde_json::json!({"input": text});
    }
    if let Some(obj) = input.as_object_mut()
        && !obj.contains_key("command")
        && let Some(cmd) = obj.remove("cmd")
    {
        obj.insert("command".into(), cmd);
    }
    input
}

/// The context a `token_count` event says the call before it read.
fn context_of(record: &Value) -> Option<u64> {
    let last = record.pointer("/payload/info/last_token_usage")?;
    let n = |k: &str| last.get(k).and_then(Value::as_u64);
    n("total_tokens")
        .or_else(|| Some(n("input_tokens").unwrap_or(0) + n("output_tokens").unwrap_or(0)))
        .filter(|t| *t > 0)
}

/// The masked copy of rollout `file` (module docs), not written yet. None: nothing to mask.
pub fn mask_codex(file: &Path, opts: MaskOptions) -> anyhow::Result<Option<Masked>> {
    let mut records = Vec::new();
    for line in BufReader::new(std::fs::File::open(file)?).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        records.push(serde_json::from_str::<Value>(&line)?);
    }
    mask_codex_records(records, opts)
}

pub(crate) fn mask_codex_records(
    mut records: Vec<Value>,
    opts: MaskOptions,
) -> anyhow::Result<Option<Masked>> {
    let thread = records
        .iter()
        .find(|r| kind(r).0 == Some("session_meta"))
        .and_then(|r| r.pointer("/payload/id"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("no session_meta names the thread"))?;
    let start = records.iter().rposition(|r| kind(r).0 == Some("compacted")).map_or(0, |i| i + 1);
    let mut calls: HashMap<String, (String, Value)> = HashMap::new();
    let mut open: HashSet<String> = HashSet::new();
    let mut tokens_before = None;
    let mut turns = Vec::new();
    for (i, record) in records.iter().enumerate().skip(start) {
        let call_id = record.pointer("/payload/call_id").and_then(Value::as_str);
        match kind(record) {
            (Some("event_msg"), Some("task_started")) => turns.push(i),
            (Some("event_msg"), Some("token_count")) => {
                tokens_before = context_of(record).or(tokens_before);
            }
            (
                Some("response_item"),
                Some(t @ ("function_call" | "custom_tool_call" | "local_shell_call")),
            ) => {
                if let Some(id) = call_id {
                    let payload = &record["payload"];
                    let name = payload.get("name").and_then(Value::as_str).unwrap_or(match t {
                        "local_shell_call" => "shell",
                        _ => "tool",
                    });
                    calls.insert(id.to_owned(), (name.to_owned(), call_input(payload)));
                    open.insert(id.to_owned());
                }
            }
            (Some("response_item"), Some("function_call_output" | "custom_tool_call_output")) => {
                if let Some(id) = call_id {
                    open.remove(id);
                }
            }
            _ => {}
        }
    }
    anyhow::ensure!(open.is_empty(), "a tool call has no output yet: the turn is not over");
    let Some(&cutoff) =
        turns.len().checked_sub(opts.keep_turns).filter(|&k| k > 0).and_then(|k| turns.get(k))
    else {
        return Ok(None);
    };
    let id = uuid::Uuid::now_v7().to_string();
    let mut out = Masked { id: id.clone(), tokens_before, ..Masked::default() };
    for (i, record) in records.iter_mut().enumerate() {
        match kind(record) {
            (Some("session_meta"), _) => {
                if let Some(t) =
                    record.pointer_mut("/payload/id").filter(|v| v.as_str() == Some(&thread))
                {
                    *t = Value::String(id.clone());
                }
            }
            (Some("response_item"), Some("function_call_output" | "custom_tool_call_output"))
                if i >= start && i < cutoff =>
            {
                mask_output(record, &calls, opts.min_chars, &mut out);
            }
            _ => {}
        }
        out.lines.push(serde_json::to_string(record)?);
    }
    out.thread = Some(thread);
    Ok((out.masked > 0).then_some(out))
}

fn mask_output(
    record: &mut Value,
    calls: &HashMap<String, (String, Value)>,
    min_chars: usize,
    out: &mut Masked,
) {
    let call = record
        .pointer("/payload/call_id")
        .and_then(Value::as_str)
        .and_then(|id| calls.get(id))
        .cloned();
    let Some(output) = record.pointer_mut("/payload/output") else { return };
    let chars = super::surgery::content_chars(output);
    if chars < min_chars || super::surgery::already_masked(output) {
        return;
    }
    let text = stub(call.as_ref().map_or("tool", |(n, _)| n.as_str()), call.as_ref().map(|(_, i)| i), chars);
    out.chars_masked += chars.saturating_sub(text.len());
    out.masked += 1;
    if let Some(key) = call.as_ref().and_then(|(_, input)| refetch_key(input)) {
        out.keys.push(key);
    }
    *output = Value::String(text);
}

/// Writes `masked` beside rollout `original` under its new thread id, never over a file.
pub fn write_codex_beside(original: &Path, masked: &Masked) -> anyhow::Result<PathBuf> {
    let name = original.file_name().and_then(|n| n.to_str()).unwrap_or_default();
    let thread = masked.thread.as_deref().unwrap_or_default();
    let stem = name
        .strip_suffix(&format!("{thread}.jsonl"))
        .filter(|s| s.starts_with("rollout-"))
        .ok_or_else(|| anyhow::anyhow!("unexpected Codex rollout name {name}"))?;
    let path = original.with_file_name(format!("{stem}{}.jsonl", masked.id));
    let mut file =
        crate::home_fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
    for line in &masked.lines {
        writeln!(file, "{line}")?;
    }
    file.sync_all()?;
    Ok(path)
}

#[cfg(test)]
#[path = "surgery_codex_tests.rs"]
mod tests;
