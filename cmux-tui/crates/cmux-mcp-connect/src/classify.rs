//! What a tool can do, and the policy it starts with (threat model T11).

use serde_json::Value;

/// What a tool does to the world.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum ToolKind {
    /// Only reads (`readOnlyHint: true`, or a read-like name and no hint
    /// saying otherwise).
    Read,
    /// Changes data.
    Write,
    /// Deletes or cannot be undone (`destructiveHint: true`, or a
    /// delete-like name).
    Destructive,
}

/// Whether a call runs without asking.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Policy {
    Always,
    Ask,
    Never,
}

const READ_VERBS: [&str; 10] =
    ["get", "list", "search", "read", "fetch", "find", "query", "describe", "view", "show"];
const DESTRUCTIVE_VERBS: [&str; 8] =
    ["delete", "remove", "destroy", "drop", "purge", "revoke", "archive", "cancel"];

/// The first word of a tool name (`create_issue`, `createIssue`,
/// `issues.create` -> `create` / `issues`).
fn verbs(name: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut cur = String::new();
    for c in name.chars() {
        if c == '_' || c == '-' || c == '.' || c == '/' || c.is_uppercase() {
            if !cur.is_empty() {
                words.push(std::mem::take(&mut cur));
            }
            if c.is_uppercase() {
                cur.extend(c.to_lowercase());
            }
        } else {
            cur.push(c);
        }
    }
    if !cur.is_empty() {
        words.push(cur);
    }
    words
}

/// The kind of a tool from its MCP annotations, then its name. A server's
/// annotations are hints from the server, so a read-only hint never
/// outranks a destructive name (`delete_x` with `readOnlyHint: true` is
/// still destructive).
pub fn classify(tool: &Value) -> ToolKind {
    let name = tool.get("name").and_then(Value::as_str).unwrap_or("");
    let words = verbs(name);
    let has = |list: &[&str]| words.iter().any(|w| list.contains(&w.as_str()));
    let hint = |k: &str| tool.get("annotations").and_then(|a| a.get(k)).and_then(Value::as_bool);
    if has(&DESTRUCTIVE_VERBS)
        || (hint("destructiveHint") == Some(true) && hint("readOnlyHint") != Some(true))
    {
        return ToolKind::Destructive;
    }
    if hint("readOnlyHint") == Some(true) {
        return ToolKind::Read;
    }
    match words.first() {
        Some(w) if READ_VERBS.contains(&w.as_str()) && hint("readOnlyHint") != Some(false) => {
            ToolKind::Read
        }
        _ => ToolKind::Write,
    }
}

/// The policy a tool starts with: reads run, writes and destructive calls
/// ask, and a tool the screen flagged never runs until the person says so.
pub fn default_policy(kind: ToolKind, flagged: bool) -> Policy {
    match (flagged, kind) {
        (true, _) => Policy::Never,
        (false, ToolKind::Read) => Policy::Always,
        (false, ToolKind::Write | ToolKind::Destructive) => Policy::Ask,
    }
}
