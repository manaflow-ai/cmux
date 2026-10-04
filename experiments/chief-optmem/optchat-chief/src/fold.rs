//! Folds one turn session's acpmux events into OptChat log entries (section 7:
//! "everything the agent does is logged as it happens"): each finished reply
//! is `talk`, each tool call `tool` (its name and JSON input), each tool
//! result `echo`. Thoughts are never logged (section 2). Pure; the runner
//! feeds it events in seq order and appends what it returns.

use std::collections::HashMap;

use cmux_chief::acp::AcpmuxEvent;
use optchat_core::Kind;
use serde_json::Value;

/// One log entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub kind: Kind,
    pub text: String,
}

/// How the turn ended, once it did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ended {
    pub error: Option<String>,
}

#[derive(Debug, Default)]
struct Tool {
    name: String,
    input: Value,
    /// The `tool` entry is in the log.
    logged: bool,
    /// The `echo` entry is in the log.
    done: bool,
}

#[derive(Debug, Default)]
pub struct TurnFold {
    last_seq: u64,
    /// Reply text since the last tool call.
    talk: String,
    tools: HashMap<String, Tool>,
    /// The last finished reply: what the turn posts.
    last_talk: Option<String>,
    ended: Option<Ended>,
}

impl TurnFold {
    pub fn new() -> TurnFold {
        TurnFold::default()
    }

    /// Highest seq folded; the next fetch asks for the events after it.
    pub fn seq(&self) -> u64 {
        self.last_seq
    }

    pub fn ended(&self) -> Option<&Ended> {
        self.ended.as_ref()
    }

    /// The turn's final assistant text: its last finished reply.
    pub fn final_text(&self) -> Option<&str> {
        self.last_talk.as_deref()
    }

    /// Folds one event; events at or below the last seq are replays.
    pub fn apply(&mut self, event: &AcpmuxEvent) -> Vec<Entry> {
        if !event.valid {
            return Vec::new();
        }
        if event.seq > 0 {
            if event.seq <= self.last_seq {
                return Vec::new();
            }
            self.last_seq = event.seq;
        }
        let mut out = Vec::new();
        if self.ended.is_some() {
            return out;
        }
        let update = event.msg.get("params").and_then(|p| p.get("update"));
        match (event.dir.as_str(), event.kind.as_str()) {
            (_, "agent_message_chunk") => {
                if let Some(content) = update.and_then(|u| u.get("content"))
                    && content.get("type").and_then(Value::as_str) == Some("text")
                    && let Some(text) = content.get("text").and_then(Value::as_str)
                {
                    self.talk.push_str(text);
                }
            }
            (_, "tool_call") => {
                self.finish_talk(&mut out);
                if let Some(update) = update {
                    self.tool_call(update, &mut out);
                }
            }
            (_, "tool_call_update") => {
                if let Some(update) = update {
                    self.tool_update(update, &mut out);
                }
            }
            ("mux", kind @ ("turn_end" | "turn_error")) => {
                self.finish_talk(&mut out);
                let error = (kind == "turn_error").then(|| match event.msg.get("error") {
                    Some(Value::String(text)) => text.clone(),
                    Some(Value::Null) | None => Value::Object(event.msg.clone()).to_string(),
                    Some(other) => other.to_string(),
                });
                self.ended = Some(Ended { error });
            }
            _ => {}
        }
        out
    }

    /// The turn is over without a `turn_end` (the prompt failed or the
    /// connection was lost): what is pending becomes final.
    pub fn finish(&mut self, error: Option<String>) -> Vec<Entry> {
        let mut out = Vec::new();
        if self.ended.is_none() {
            self.finish_talk(&mut out);
            self.ended = Some(Ended { error });
        }
        out
    }

    fn finish_talk(&mut self, out: &mut Vec<Entry>) {
        let text = std::mem::take(&mut self.talk);
        let text = text.trim();
        if !text.is_empty() {
            out.push(Entry {
                kind: Kind::Talk,
                text: text.to_owned(),
            });
            self.last_talk = Some(text.to_owned());
        }
    }

    fn tool_call(&mut self, update: &Value, out: &mut Vec<Entry>) {
        let Some(id) = tool_id(update) else { return };
        let tool = self.tools.entry(id).or_default();
        tool.name = tool_name(update).unwrap_or_else(|| tool.name.clone());
        if let Some(input) = update.get("rawInput").filter(|v| has_input(v)) {
            tool.input = input.clone();
        }
        // Some adapters announce a call before its input streams in; it is
        // logged once the input is known, or at its result at the latest.
        if has_input(&tool.input) {
            log_tool(tool, out);
        }
    }

    fn tool_update(&mut self, update: &Value, out: &mut Vec<Entry>) {
        let Some(id) = tool_id(update) else { return };
        let tool = self.tools.entry(id).or_default();
        if tool.name.is_empty()
            && let Some(name) = tool_name(update)
        {
            tool.name = name;
        }
        if let Some(input) = update.get("rawInput").filter(|v| has_input(v)) {
            tool.input = input.clone();
        }
        if has_input(&tool.input) {
            log_tool(tool, out);
        }
        let status = update.get("status").and_then(Value::as_str).unwrap_or("");
        if !tool.done && matches!(status, "completed" | "failed") {
            log_tool(tool, out);
            tool.done = true;
            let text = result_text(update);
            let text = if status == "failed" {
                format!("error: {text}")
            } else {
                text
            };
            out.push(Entry {
                kind: Kind::Echo,
                text,
            });
        }
    }
}

fn log_tool(tool: &mut Tool, out: &mut Vec<Entry>) {
    if tool.logged {
        return;
    }
    tool.logged = true;
    let name = if tool.name.is_empty() {
        "tool"
    } else {
        tool.name.as_str()
    };
    out.push(Entry {
        kind: Kind::Tool,
        text: format!("{name} {}", tool.input),
    });
}

fn tool_id(update: &Value) -> Option<String> {
    match update.get("toolCallId")? {
        Value::String(id) => Some(id.clone()),
        Value::Null => None,
        other => Some(other.to_string()),
    }
}

/// The harness's own tool name (Claude Code's in `_meta.claude.tool`), else the title.
fn tool_name(update: &Value) -> Option<String> {
    update
        .pointer("/_meta/claude/tool")
        .or_else(|| update.pointer("/_meta/claudeCode/toolName"))
        .or_else(|| update.get("title"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn has_input(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Object(map) => !map.is_empty(),
        _ => true,
    }
}

/// A tool result's text: its text content blocks, else its raw output.
fn result_text(update: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    for item in update
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let content = item.get("content").unwrap_or(item);
        if let Some(text) = content.get("text").and_then(Value::as_str) {
            parts.push(text.to_owned());
        } else if item.get("type").and_then(Value::as_str) == Some("diff") {
            let path = item.get("path").and_then(Value::as_str).unwrap_or("?");
            parts.push(format!("(diff of {path})"));
        }
    }
    if parts.is_empty() {
        match update.get("rawOutput") {
            Some(Value::String(text)) => return text.clone(),
            Some(Value::Null) | None => return String::new(),
            Some(other) => return other.to_string(),
        }
    }
    parts.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ev(seq: u64, dir: &str, kind: &str, msg: Value) -> AcpmuxEvent {
        serde_json::from_value(json!({"seq": seq, "dir": dir, "kind": kind, "msg": msg})).unwrap()
    }

    fn update(seq: u64, kind: &str, update: Value) -> AcpmuxEvent {
        let mut u = update;
        u["sessionUpdate"] = json!(kind);
        ev(
            seq,
            "in",
            kind,
            json!({"method": "session/update", "params": {"update": u}}),
        )
    }

    fn chunk(seq: u64, text: &str) -> AcpmuxEvent {
        update(
            seq,
            "agent_message_chunk",
            json!({"content": {"type": "text", "text": text}}),
        )
    }

    fn kinds(entries: &[Entry]) -> Vec<(Kind, &str)> {
        entries.iter().map(|e| (e.kind, e.text.as_str())).collect()
    }

    #[test]
    fn talk_tool_echo_in_order_and_no_thoughts() {
        let mut fold = TurnFold::new();
        let mut log = Vec::new();
        let events = vec![
            ev(1, "mux", "user_message", json!({"promptId": "optchat:0"})),
            ev(2, "mux", "turn_started", json!({})),
            update(
                3,
                "agent_thought_chunk",
                json!({"content": {"type": "text", "text": "secret"}}),
            ),
            chunk(4, "Let me "),
            chunk(5, "look."),
            update(
                6,
                "tool_call",
                json!({"toolCallId": "t1", "title": "Read a.rs", "rawInput": {"file_path": "a.rs"}, "_meta": {"claude": {"tool": "Read"}}}),
            ),
            update(
                7,
                "tool_call_update",
                json!({"toolCallId": "t1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "fn main() {}"}}]}),
            ),
            chunk(8, "  It is empty.  "),
            ev(9, "mux", "turn_end", json!({})),
        ];
        for e in &events {
            log.extend(fold.apply(e));
        }
        assert_eq!(
            kinds(&log),
            vec![
                (Kind::Talk, "Let me look."),
                (Kind::Tool, "Read {\"file_path\":\"a.rs\"}"),
                (Kind::Echo, "fn main() {}"),
                (Kind::Talk, "It is empty."),
            ]
        );
        assert_eq!(fold.final_text(), Some("It is empty."));
        assert_eq!(fold.ended(), Some(&Ended { error: None }));
        // A replay of the same events changes nothing.
        for e in &events {
            assert!(fold.apply(e).is_empty());
        }
    }

    #[test]
    fn a_call_announced_before_its_input_is_logged_once_with_it() {
        let mut fold = TurnFold::new();
        let mut log = Vec::new();
        log.extend(fold.apply(&update(
            1,
            "tool_call",
            json!({"toolCallId": "t", "title": "Bash", "rawInput": {}}),
        )));
        assert!(log.is_empty());
        log.extend(fold.apply(&update(
            2,
            "tool_call_update",
            json!({"toolCallId": "t", "rawInput": {"command": "ls"}}),
        )));
        log.extend(fold.apply(&update(
            3,
            "tool_call_update",
            json!({"toolCallId": "t", "status": "failed", "rawOutput": "boom"}),
        )));
        assert_eq!(
            kinds(&log),
            vec![
                (Kind::Tool, "Bash {\"command\":\"ls\"}"),
                (Kind::Echo, "error: boom")
            ]
        );
    }

    #[test]
    fn an_error_ends_the_turn_and_keeps_the_last_reply() {
        let mut fold = TurnFold::new();
        fold.apply(&chunk(1, "partial"));
        let out = fold.apply(&ev(2, "mux", "turn_error", json!({"error": "overloaded"})));
        assert_eq!(kinds(&out), vec![(Kind::Talk, "partial")]);
        assert_eq!(
            fold.ended(),
            Some(&Ended {
                error: Some("overloaded".into())
            })
        );
        assert!(fold.finish(None).is_empty(), "already ended");
    }

    #[test]
    fn finish_flushes_pending_talk() {
        let mut fold = TurnFold::new();
        fold.apply(&chunk(1, "half"));
        assert_eq!(
            kinds(&fold.finish(Some("lost".into()))),
            vec![(Kind::Talk, "half")]
        );
        assert_eq!(fold.ended().unwrap().error.as_deref(), Some("lost"));
    }
}
