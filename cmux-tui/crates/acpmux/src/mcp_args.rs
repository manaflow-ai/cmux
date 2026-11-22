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
//!
//! A key no listed key stands for is also *named* in the result ([`ArgsRead::unimplemented`]),
//! because a tool reads the arguments its schema lists and no others: the key reached the tool,
//! the tool did nothing with it, and the answer used to look exactly like one that honoured it.
//! Measured on 2026-11-22: `bg_output` called with `tail_lines: 40` answered the whole 1438-byte
//! log (`tail_lines` is in no schema in this crate), and the only sign the bound was never
//! applied was the size of what came back; an agent that asks for 40 lines of a 6,000-line log
//! pays for all 6,000. A line count is not coerced into `maxBytes`: 40 lines read as 40 bytes
//! would be a *different* wrong answer with the same false confidence, so the line names the
//! bounds the tool does implement instead and the next call is right. The call still runs: a
//! notice keeps a nearly-right call working, where a bounce would cost another round trip.

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

/// The keys the daemon or the server itself reads, which are no tool's argument and not a
/// mistake (the same set `acpmux_mcp_bg_list.rs` passes on).
const PASSED_ON: [&str; 4] = ["sessionId", "callerSubagent", "description", "_meta"];

/// One rename: the key the call gave and the listed key it was read as.
#[derive(Debug, PartialEq, Eq)]
pub struct Renamed {
    pub given: String,
    pub canonical: String,
}

/// What one call's arguments were read as: what [`normalize`] renamed, and the keys the tool
/// does not implement, which it dropped. [`tell`] puts both in the result.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ArgsRead {
    pub renamed: Vec<Renamed>,
    /// Keys the tool's schema does not list and no listed key stands for, in the order given.
    pub unimplemented: Vec<String>,
    /// The tool the call named, and the arguments its schema lists, sorted: what the line that
    /// names an unimplemented key tells the caller to use instead.
    tool: String,
    listed: Vec<String>,
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
/// list (see the module), and returns what it renamed and what the tool does not implement. A
/// value given for a list as one string becomes a list of it.
pub fn normalize(tools: &Value, params: &mut Value) -> ArgsRead {
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
    let Some(listed) = properties(tools, &name) else { return ArgsRead::default() };
    let mut names: Vec<String> = listed.keys().cloned().collect();
    names.sort();
    let mut read = ArgsRead { tool: name, listed: names, ..ArgsRead::default() };
    let Some(args) = params.get_mut("arguments").and_then(Value::as_object_mut) else {
        return read;
    };
    let unlisted: Vec<String> = args.keys().filter(|k| !listed.contains_key(*k)).cloned().collect();
    for key in unlisted {
        let taken: Vec<&str> =
            args.keys().filter(|k| listed.contains_key(*k)).map(String::as_str).collect();
        let Some(to) = canonical(&key, listed, &taken).map(str::to_owned) else {
            // No listed key stands for it: the tool will not read it, so say so (module).
            if !PASSED_ON.contains(&key.as_str()) {
                read.unimplemented.push(key);
            }
            continue;
        };
        let Some(mut value) = args.remove(&key) else { continue };
        let wants_list =
            listed.get(&to).and_then(|s| s.get("type")).and_then(Value::as_str) == Some("array");
        if wants_list && value.is_string() {
            value = json!([value]);
        }
        args.insert(to.clone(), value);
        read.renamed.push(Renamed { given: key, canonical: to });
    }
    read
}

/// The one line that tells a call's renames: `(read argument session as name)`.
pub fn line(read: &ArgsRead) -> Option<String> {
    if read.renamed.is_empty() {
        return None;
    }
    let each: Vec<String> =
        read.renamed.iter().map(|r| format!("{} as {}", r.given, r.canonical)).collect();
    Some(format!("(read argument {}; the schema's names are canonical)", each.join(", ")))
}

/// The one line that names the arguments the tool does not implement, and the ones it does:
/// `(bg_output does not implement argument tail_lines, so it did nothing; its arguments are
/// description, fromByte, id, maxBytes)`.
pub fn unimplemented_line(read: &ArgsRead) -> Option<String> {
    if read.unimplemented.is_empty() {
        return None;
    }
    let (plural, pronoun) = if read.unimplemented.len() == 1 { ("", "it") } else { ("s", "they") };
    let instead = if read.listed.is_empty() {
        "it takes no arguments".to_owned()
    } else {
        format!("its arguments are {}", read.listed.join(", "))
    };
    Some(format!(
        "({tool} does not implement argument{plural} {given}, so {pronoun} did nothing; {instead})",
        tool = read.tool,
        given = read.unimplemented.join(", "),
    ))
}

/// Adds [`line`] and [`unimplemented_line`] to a tool result's content, as its last texts.
pub fn tell(result: &mut Value, read: &ArgsRead) {
    let told =
        [("argumentsRead", line(read)), ("argumentsNotImplemented", unimplemented_line(read))];
    for (key, text) in told.into_iter().filter_map(|(k, t)| t.map(|t| (k, t))) {
        // Claude Code shows the structured result, not the text, when there is one.
        if let Some(structured) = result.get_mut("structuredContent").and_then(Value::as_object_mut)
        {
            structured.insert(key.to_owned(), json!(text));
        }
        if let Some(content) = result.get_mut("content").and_then(Value::as_array_mut) {
            content.push(json!({"type": "text", "text": text}));
        }
    }
}

#[cfg(test)]
#[path = "mcp_args_tests.rs"]
mod tests;
