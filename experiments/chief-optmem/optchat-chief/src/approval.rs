//! Approvals of a remote-origin turn's local effects (README "Remote-origin
//! messages"). The turn session runs with acpmux policy `ask`; each
//! permission request it raises is either one of the memory tools (answered
//! at once: reading the memory has no local effect) or shown in the Chief
//! chat and answered by the next `allow` or `deny` a person of the
//! conversation sends. Every answer goes to the trace with the approving
//! device.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use serde_json::{Value, json};

/// Tools that only read the OptChat memory: allowed without asking.
pub const MEMORY_TOOLS: [&str; 2] = ["mcp__optchat__zoom", "mcp__optchat__date"];

/// One permission request waiting for a person.
#[derive(Clone, Debug, PartialEq)]
pub struct Pending {
    pub session_id: String,
    pub permission_id: String,
    pub tool: String,
    pub request: Value,
    /// The child agent that asked (its name), None for the turn itself.
    pub child: Option<String>,
}

/// The tag `chief agents spawn` puts on a child that runs with policy `ask`
/// (the host's spawn floor): its approvals go to the Chief chat.
pub const POLICY_TAG: &str = "optchat.policy";
pub const ASK: &str = "ask";

/// The harness's tool name of a permission request (Claude Code's
/// `_meta.claude.tool`), else its title.
pub fn tool_name(request: &Value) -> String {
    let call = request.get("toolCall");
    call.and_then(|c| {
        c.pointer("/_meta/claude/tool")
            .or_else(|| c.pointer("/_meta/claudeCode/toolName"))
            .or_else(|| c.get("title"))
    })
    .and_then(Value::as_str)
    .filter(|s| !s.is_empty())
    .unwrap_or("a tool")
    .to_owned()
}

/// Whether the request only reads the memory.
pub fn is_memory_tool(request: &Value) -> bool {
    MEMORY_TOOLS.contains(&tool_name(request).as_str())
}

/// A person's answer in a chat message: `allow` or `deny` (any case, alone).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Answer {
    Allow,
    Deny,
}

impl Answer {
    pub fn parse(text: &str) -> Option<Answer> {
        match text.trim().to_ascii_lowercase().as_str() {
            "allow" => Some(Answer::Allow),
            "deny" => Some(Answer::Deny),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Answer::Allow => "allow",
            Answer::Deny => "deny",
        }
    }
}

/// The option that answers `request`: allow once (never "always": each
/// effect is approved on its own), or reject once. None: no such option.
pub fn option_for(request: &Value, answer: Answer) -> Option<String> {
    let options = request.get("options").and_then(Value::as_array)?;
    fn kind(o: &Value) -> &str {
        o.get("kind").and_then(Value::as_str).unwrap_or("")
    }
    let pick = match answer {
        Answer::Allow => options.iter().find(|o| kind(o) == "allow_once"),
        Answer::Deny => options
            .iter()
            .find(|o| kind(o) == "reject_once")
            .or_else(|| options.iter().find(|o| kind(o).starts_with("reject"))),
    }?;
    pick.get("optionId")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// The Chief chat's question for one request.
pub fn question(pending: &Pending) -> String {
    let input = pending
        .request
        .pointer("/toolCall/rawInput")
        .map(|raw| {
            let text: String = raw.to_string().chars().take(1_000).collect();
            format!("\n{text}")
        })
        .unwrap_or_default();
    match &pending.child {
        None => format!(
            "Approval needed: this turn started from a paired device, so every local effect waits for you. {} wants to run:{input}\nReply allow or deny.",
            pending.tool
        ),
        Some(child) => format!(
            "Approval needed: subagent {child} started from a turn that needs approvals, so its local effects wait for you too. {} wants to run:{input}\nReply allow or deny.",
            pending.tool
        ),
    }
}

/// Appends one `approval` event to the trace in `dir`
/// (`traces/YYYY-MM-DD.jsonl`, the monitoring trace's layout:
/// `{"ts", "ev", ...}`, 0600). A failed write is reported, never fatal.
pub fn record(dir: &Path, fields: Value) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    let now = chrono::Local::now();
    let mut line = json!({"ts": now.timestamp_millis(), "ev": "approval"});
    if let (Some(line), Value::Object(fields)) = (line.as_object_mut(), fields) {
        line.extend(fields);
    }
    let path = dir.join(format!("{}.jsonl", now.format("%Y-%m-%d")));
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(format!("{line}\n").as_bytes())
}
