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
//! Where no single listed key stands for a key, nothing moves and the result says why
//! ([`ArgsRead::unread`]): the tool implements no such argument, or it stands for a listed key
//! the call already gives, or it is equally close to several listed keys, where reading it as
//! one of them would guess — a wrong rename is worse than the usage error it would hide.
//!
//! A key no listed key stands for is also *named* in the result ([`ArgsRead::unread`]),
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
    /// The keys the tool will not read, and why. Sorted by key, as a JSON object's keys arrive.
    pub unread: Vec<Unread>,
    /// The tool the call named, and the arguments its schema lists, sorted: what the line that
    /// names an unimplemented key tells the caller to use instead.
    tool: String,
    listed: Vec<String>,
}

/// One key the tool will not read, and why. [`unread_lines`] says it in words.
#[derive(Debug, PartialEq, Eq)]
pub struct Unread {
    pub given: String,
    pub why: Why,
}

/// Why a key the schema does not list was not read as one that is.
#[derive(Debug, PartialEq, Eq)]
pub enum Why {
    /// Nothing the tool's schema lists stands for it: the tool implements no such argument.
    NotImplemented,
    /// It stands for this listed key, which the call already gives; the tool reads that one.
    Already(String),
    /// It is equally close to each of these listed keys, so reading it as one would guess.
    Ambiguous(Vec<String>),
}

impl ArgsRead {
    /// Keeps a key the tool will not read, unless the daemon or the server reads it (module).
    fn unread(&mut self, given: String, why: Why) {
        if !PASSED_ON.contains(&given.as_str()) {
            self.unread.push(Unread { given, why });
        }
    }
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

/// What one listed key `key` stands for, or why none does.
enum Reads<'a> {
    /// Read it as this listed key.
    As(&'a str),
    /// It stands for this listed key, which the call already gives.
    Already(&'a str),
    /// It is equally close to each of these listed keys.
    Ambiguous(Vec<&'a str>),
    /// Nothing the tool lists stands for it.
    Nothing,
}

/// The listed key `key` stands for (see the module), or why none does. `taken`: listed keys the
/// call already gives, which a key that stands for one of them may not overwrite.
fn reads<'a>(key: &str, listed: &'a Map<String, Value>, taken: &[&str]) -> Reads<'a> {
    let one = |k: &'a String| {
        if taken.contains(&k.as_str()) { Reads::Already(k) } else { Reads::As(k) }
    };
    let wanted = folded(key);
    if let Some(k) = listed.keys().find(|k| folded(k) == wanted) {
        return one(k);
    }
    for group in GROUPS {
        if !group.iter().any(|g| folded(g) == wanted) {
            continue;
        }
        let mut members = listed.keys().filter(|k| group.contains(&k.as_str()));
        if let (Some(only), None) = (members.next(), members.next()) {
            return one(only);
        }
    }
    // A typo, but only where one listed key is nearest: two equally near are no rename at all.
    let near = crate::mcp_hint::nearest_all(key, listed.keys().map(String::as_str));
    match near.len() {
        0 => Reads::Nothing,
        1 => listed.keys().find(|k| k.as_str() == near[0]).map_or(Reads::Nothing, one),
        _ => Reads::Ambiguous(near),
    }
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
        // Anything but one free listed key leaves the call as it is, and says why (module).
        let to = match reads(&key, listed, &taken) {
            Reads::As(to) => to.to_owned(),
            Reads::Already(to) => {
                read.unread(key, Why::Already(to.to_owned()));
                continue;
            }
            Reads::Ambiguous(near) => {
                let near = near.iter().map(|k| (*k).to_owned()).collect();
                read.unread(key, Why::Ambiguous(near));
                continue;
            }
            Reads::Nothing => {
                read.unread(key, Why::NotImplemented);
                continue;
            }
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

/// What the tool did not read, in words: the arguments it does not implement and the ones it
/// does (`(bg_output does not implement argument tail_lines, so it did nothing; its arguments
/// are description, fromByte, id, maxBytes)`), then a line for each key it would have had to
/// guess at. One line each, so no reason is read as another.
pub fn unread_lines(read: &ArgsRead) -> Vec<String> {
    let listed = || {
        if read.listed.is_empty() {
            "it takes no arguments".to_owned()
        } else {
            format!("its arguments are {}", read.listed.join(", "))
        }
    };
    let mut lines = Vec::new();
    let none: Vec<&str> = read
        .unread
        .iter()
        .filter(|u| u.why == Why::NotImplemented)
        .map(|u| u.given.as_str())
        .collect();
    if !none.is_empty() {
        let (plural, pronoun) = if none.len() == 1 { ("", "it") } else { ("s", "they") };
        lines.push(format!(
            "({tool} does not implement argument{plural} {given}, so {pronoun} did nothing; {instead})",
            tool = read.tool,
            given = none.join(", "),
            instead = listed(),
        ));
    }
    for u in &read.unread {
        match &u.why {
            Why::NotImplemented => {}
            Why::Already(to) => lines.push(format!(
                "({tool} reads {given} as {to}, which this call already gives, so {given} did nothing)",
                tool = read.tool,
                given = u.given,
            )),
            Why::Ambiguous(near) => lines.push(format!(
                "({tool} did not read {given}: it is as close to {near}, so reading it as one would have guessed; {instead})",
                tool = read.tool,
                given = u.given,
                near = near.join(" as to "),
                instead = listed(),
            )),
        }
    }
    lines
}

/// Adds [`line`] and [`unread_lines`] to a tool result's content, as its last texts.
pub fn tell(result: &mut Value, read: &ArgsRead) {
    let unread = unread_lines(read);
    let told = [
        ("argumentsRead", line(read)),
        ("argumentsNotRead", (!unread.is_empty()).then(|| unread.join(" "))),
    ];
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
