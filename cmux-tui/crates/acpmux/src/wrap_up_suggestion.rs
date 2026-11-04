//! A predicted next prompt for harnesses that make none: the first answer of the turn's
//! `wrap_up` call (`acpmux_mcp_wrap_up.rs`). Claude Code predicts the person's next prompt itself
//! (`claude_stdio/prompt_suggestions.rs`); Codex and the other harnesses have no such thing, so a
//! chat on them took nothing to Tab to. When such a chat's turn ends on a wrap-up whose question
//! has answers, the first one (the agent's pick) is offered as the suggestion, under its own
//! source, `wrap_up`, so the acceptance gate (`suggestion_gate.rs`) counts it apart from any other
//! and withholds it once people stop taking it. Leo, 2026-11-03: "that suggested prompting from
//! Codex, we need to have that as well. We need to make sure we have that."
//!
//! The tap watches each live update of the chat's own thread ([`observe`]): a wrap-up call under
//! any name a harness gives it (`mcp__acpmux__wrap_up`, Codex's `{server, tool, arguments}`, the
//! folded `cmux.acpmux_wrap_up`, or a `cmux_exec` script whose call_log shows one) leaves its first
//! answer pending once it completes. The turn's end takes it ([`take`]) and, on a completed turn,
//! writes it as a `prompt_suggestion` update.

use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

/// The gate's source for these suggestions (`suggestion_gate::key`).
pub const SOURCE: &str = "wrap_up";
const TOOL: &str = "wrap_up";
const FOLDED: &str = "acpmux_wrap_up";
const EXEC: &str = "cmux_exec";

/// One chat's wrap-up calls seen this turn and the answer its last completed one left.
#[derive(Debug, Default)]
pub struct Watch {
    /// The arguments of each wrap-up call still running, by tool call id (a later update carries
    /// only the status), or `None` for a `cmux_exec` call whose output is read when it completes.
    calls: HashMap<String, Option<Value>>,
    pending: Option<String>,
}

impl Watch {
    /// A live `session/update` of the chat's own thread.
    pub fn observe(&mut self, update: &Value) {
        let kind = update.get("sessionUpdate").and_then(Value::as_str);
        if !matches!(kind, Some("tool_call" | "tool_call_update")) {
            return;
        }
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
        if let Some(call) = recognise(update) {
            self.calls.insert(id.to_owned(), call);
        }
        let status = update.get("status").and_then(Value::as_str);
        if !matches!(status, Some("completed" | "failed")) {
            return;
        }
        let Some(call) = self.calls.remove(id) else { return };
        if status != Some("completed") {
            return;
        }
        let args = match call {
            Some(args) => Some(args),
            None => shown_in_output(update),
        };
        if let Some(answer) = args.as_ref().and_then(first_answer) {
            self.pending = Some(answer);
        }
    }

    /// The turn ended: its answer, if any, and a clean slate for the next turn.
    pub fn take(&mut self) -> Option<String> {
        self.calls.clear();
        self.pending.take()
    }
}

/// Whether an update names a wrap-up call: `Some(Some(args))` with its arguments, `Some(None)`
/// for a `cmux_exec` script that calls it (its output says what it showed), `None` otherwise.
fn recognise(update: &Value) -> Option<Option<Value>> {
    let input = update.get("rawInput");
    let title = update.get("title").and_then(Value::as_str).map(str::trim).unwrap_or("");
    // Claude Code: `mcp__<server>__<tool>` with the arguments as the input.
    if let Some((server, tool)) = title.strip_prefix("mcp__").and_then(|rest| rest.split_once("__"))
    {
        return named(server, tool, input.cloned(), input);
    }
    // Codex: `{server, tool, arguments}`.
    if let Some(Value::Object(o)) = input
        && let (Some(server), Some(tool)) =
            (o.get("server").and_then(Value::as_str), o.get("tool").and_then(Value::as_str))
    {
        return named(server, tool, o.get("arguments").cloned(), o.get("arguments"));
    }
    // A bare or dotted name.
    match title {
        "wrap_up" | "acpmux.wrap_up" | "acpmux_wrap_up" | "cmux.acpmux_wrap_up" => {
            Some(input.cloned())
        }
        _ => None,
    }
}

fn named(
    server: &str,
    tool: &str,
    args: Option<Value>,
    raw: Option<&Value>,
) -> Option<Option<Value>> {
    match (server, tool) {
        ("acpmux", TOOL) | ("cmux", FOLDED) => Some(args),
        // Only a script that names the wrap-up; the others are not watched.
        ("cmux", EXEC) if raw.is_some_and(|r| r.to_string().contains(FOLDED)) => Some(None),
        _ => None,
    }
}

/// What the last successful wrap-up in a `cmux_exec` script showed, from its output's call_log
/// (`code_mode.rs` keeps it as `shown`).
fn shown_in_output(update: &Value) -> Option<Value> {
    let mut logs: Vec<Value> = Vec::new();
    if let Some(log) = update.pointer("/rawOutput/call_log") {
        logs.push(log.clone());
    }
    let mut texts = Vec::new();
    collect_strings(update.get("rawOutput"), &mut texts);
    collect_strings(update.get("content"), &mut texts);
    for text in texts {
        if let Ok(parsed) = serde_json::from_str::<Value>(text)
            && let Some(log) = parsed.get("call_log")
        {
            logs.push(log.clone());
        }
    }
    logs.iter().rev().filter_map(Value::as_array).find_map(|log| {
        log.iter()
            .rev()
            .find(|e| {
                e.get("name").and_then(Value::as_str) == Some(FOLDED)
                    && e.get("ok").and_then(Value::as_bool) == Some(true)
            })
            .and_then(|e| e.get("shown").cloned())
    })
}

fn collect_strings<'a>(value: Option<&'a Value>, out: &mut Vec<&'a str>) {
    match value {
        Some(Value::String(s)) if s.trim_start().starts_with('{') => out.push(s),
        Some(Value::Array(items)) => items.iter().for_each(|v| collect_strings(Some(v), out)),
        Some(Value::Object(o)) => o.values().for_each(|v| collect_strings(Some(v), out)),
        _ => {}
    }
}

/// The agent's pick: the first answer of a wrap-up that asks something.
fn first_answer(args: &Value) -> Option<String> {
    let args = match args {
        // Some harnesses pass the arguments as a JSON string.
        Value::String(s) => serde_json::from_str::<Value>(s).ok()?,
        other => other.clone(),
    };
    args.get("ask").and_then(Value::as_str).filter(|a| !a.trim().is_empty())?;
    args.get("actions")?
        .as_array()?
        .first()?
        .as_str()
        .map(str::trim)
        .filter(|a| !a.is_empty())
        .map(str::to_owned)
}

/// The `prompt_suggestion` update for an answer, named as this source's.
pub fn update(answer: &str) -> Value {
    json!({
        "sessionUpdate": "prompt_suggestion",
        "suggestion": answer,
        "_meta": {"acpmux": {"source": SOURCE}},
    })
}

static WATCHES: LazyLock<Mutex<HashMap<String, Watch>>> = LazyLock::new(Default::default);

/// [`Watch::observe`] for `session`.
pub fn observe(session: &str, update: &Value) {
    let kind = update.get("sessionUpdate").and_then(Value::as_str);
    if !matches!(kind, Some("tool_call" | "tool_call_update")) {
        return;
    }
    let mut watches = WATCHES.lock().unwrap_or_else(|e| e.into_inner());
    watches.entry(session.to_owned()).or_default().observe(update);
}

/// [`Watch::take`] for `session`.
pub fn take(session: &str) -> Option<String> {
    WATCHES.lock().unwrap_or_else(|e| e.into_inner()).remove(session).and_then(|mut w| w.take())
}

#[cfg(test)]
#[path = "wrap_up_suggestion_tests.rs"]
mod tests;
