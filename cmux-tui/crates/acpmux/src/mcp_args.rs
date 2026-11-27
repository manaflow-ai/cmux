//! A tool call's argument names, read against the tool's own advertised schema before the
//! tool sees them: an agent that writes `session` where `last` takes `name`, or `message`
//! where `send_message` takes `text`, gets its call run instead of a bounce ("name is required")
//! and one more round trip. Every acpmux MCP server's `tools/call` goes through it
//! (`tools_mcp::serve`), so each tool gets it from its schema with nothing of its own, and the
//! schema keeps advertising the canonical names.
//!
//! A key the tool's schema does not list is renamed, in this order, to:
//! 1. the listed key it spells with other case or separators (`session_id` for `sessionId`);
//! 2. the one listed key of its synonym group ([`GROUPS`]), when exactly one is listed;
//! 3. the one listed key [`crate::mcp_hint::nearest`] finds close to it (a typo).
//!
//! A listed key the call already gives is never overwritten, and a key with no match is left
//! as it was, for the tool to judge. Each rename is told in one line added to the result.

use serde_json::{Map, Value, json};

/// Names agents use for one argument. A key in a group stands for the group's member the tool
/// lists, when it lists exactly one; groups are tried in order, so `session` reads as a single
/// session's key before a list's (`sessions`) or a recipient's (`to`).
const GROUPS: &[&[&str]] = &[
    &["session", "name", "sessionId", "session_id", "sessionName", "session_name"],
    &["sessions", "sessionIds", "session_ids", "names", "session"],
    &["to", "session", "name", "sessionId", "session_id", "target", "recipient"],
    &["text", "message", "prompt", "body", "content", "msg"],
    &["id", "task", "taskId", "task_id", "bgId", "bg_id"],
    &["repo", "repository"],
    &["pr", "number", "prNumber", "pr_number"],
    &["run", "runId", "run_id"],
];

/// One rename: the key the call gave and the listed key it was read as.
#[derive(Debug, PartialEq, Eq)]
pub struct Renamed {
    pub given: String,
    pub canonical: String,
}

/// The `properties` of tool `name`'s `inputSchema` in a `tools/list` array.
fn properties<'a>(tools: &'a Value, name: &str) -> Option<&'a Map<String, Value>> {
    tools
        .as_array()?
        .iter()
        .find(|tool| tool.get("name").and_then(Value::as_str) == Some(name))?
        .get("inputSchema")?
        .get("properties")?
        .as_object()
}

fn folded(key: &str) -> String {
    key.chars().filter(|c| !matches!(c, '_' | '-')).flat_map(char::to_lowercase).collect()
}

/// The listed key `key` stands for, or `None`. `taken`: listed keys the call already gives.
fn canonical<'a>(key: &str, listed: &'a Map<String, Value>, taken: &[&str]) -> Option<&'a str> {
    let free = |k: &&String| !taken.contains(&k.as_str());
    let wanted = folded(key);
    if let Some(k) = listed.keys().filter(free).find(|k| folded(k) == wanted) {
        return Some(k);
    }
    for group in GROUPS {
        if !group.iter().any(|g| folded(g) == wanted) {
            continue;
        }
        let mut members = listed.keys().filter(|k| group.contains(&k.as_str()));
        if let (Some(only), None) = (members.next(), members.next()) {
            return free(&only).then_some(only.as_str());
        }
    }
    crate::mcp_hint::nearest(key, listed.keys().filter(free).map(String::as_str))
}

/// Renames the keys of `params.arguments` that tool `params.name`'s schema in `tools` does not
/// list (see the module), and returns what it renamed. A value given for a list as one string
/// becomes a list of it.
pub fn normalize(tools: &Value, params: &mut Value) -> Vec<Renamed> {
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
    let Some(listed) = properties(tools, &name) else { return Vec::new() };
    let Some(args) = params.get_mut("arguments").and_then(Value::as_object_mut) else {
        return Vec::new();
    };
    let unlisted: Vec<String> = args.keys().filter(|k| !listed.contains_key(*k)).cloned().collect();
    let mut renamed = Vec::new();
    for key in unlisted {
        let taken: Vec<&str> =
            args.keys().filter(|k| listed.contains_key(*k)).map(String::as_str).collect();
        let Some(to) = canonical(&key, listed, &taken).map(str::to_owned) else { continue };
        let Some(mut value) = args.remove(&key) else { continue };
        let wants_list =
            listed.get(&to).and_then(|s| s.get("type")).and_then(Value::as_str) == Some("array");
        if wants_list && value.is_string() {
            value = json!([value]);
        }
        args.insert(to.clone(), value);
        renamed.push(Renamed { given: key, canonical: to });
    }
    renamed
}

/// The one line that tells a call's renames: `(read argument session as name)`.
pub fn line(renamed: &[Renamed]) -> Option<String> {
    if renamed.is_empty() {
        return None;
    }
    let each: Vec<String> =
        renamed.iter().map(|r| format!("{} as {}", r.given, r.canonical)).collect();
    Some(format!("(read argument {}; the schema's names are canonical)", each.join(", ")))
}

/// Adds [`line`] to a tool result's content, as its last text.
pub fn tell(result: &mut Value, renamed: &[Renamed]) {
    let Some(text) = line(renamed) else { return };
    // Claude Code shows the structured result, not the text, when there is one.
    if let Some(structured) = result.get_mut("structuredContent").and_then(Value::as_object_mut) {
        structured.insert("argumentsRead".to_owned(), json!(text));
    }
    if let Some(content) = result.get_mut("content").and_then(Value::as_array_mut) {
        content.push(json!({"type": "text", "text": text}));
    }
}

#[cfg(test)]
#[path = "mcp_args_tests.rs"]
mod tests;
