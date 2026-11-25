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
//! [`lists`] reads a scalar given for a key the schema types as an array as a list of that one
//! value, for every listed key, not only a renamed one: `wrap_up {"learned": "a fact"}` was
//! refused 11 times in 24 h on one host (2026-11-22), each refusal losing a whole well-formed
//! recap, where the tool itself already *trims* a field past its bound instead of refusing it.
//!
//! [`values`] does the same for the *values* a schema lists (`"enum"`). A value the schema does
//! not list is read as the listed value it spells with other case or separators, else as the one
//! [`crate::mcp_hint::nearest`] finds close to it; a word that means every one of them ([`EVERY`])
//! drops a key the schema does not require, because `{"state": "all"}` to a filter is no filter,
//! not a refusal. `bg_list {"state": "all"}` cost a round trip on 2026-11-22 for exactly that.
//! A value with no match is left as it was: the tool still gets to refuse it.

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
    // What a recap is written under: on 2026-11-22 two wrap_up calls carried a complete recap
    // keyed `summary` and were refused "recap is required", losing it.
    &["recap", "summary", "recapText", "recap_text", "summaryText", "summary_text"],
];

/// Words that mean every one of the values a schema lists, so a filter with one of them is no
/// filter. Not `none`: for a filter that reads as "nothing matches" to one caller and "no filter"
/// to another, the tool should say what it did, so it is left to the tool.
const EVERY: &[&str] = &["all", "any", "every", "everything", "anything", "*", "-", "unset"];

/// One value read: the key, the value the call gave, and the listed value it was read as --
/// `None` when the key was dropped because the value meant every one of them.
#[derive(Debug, PartialEq, Eq)]
pub struct Reread {
    pub key: String,
    pub given: String,
    pub read_as: Option<String>,
}

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

/// The schema of tool `name` in a `tools/list` array.
fn schema<'a>(tools: &'a Value, name: &str) -> Option<&'a Value> {
    tools
        .as_array()?
        .iter()
        .find(|tool| tool.get("name").and_then(Value::as_str) == Some(name))?
        .get("inputSchema")
}

/// The values `property` lists, for itself or for its entries.
fn listed_values(property: &Value) -> (Vec<&str>, bool) {
    // A nested fn, not a closure: the strings borrow from the value given, and a closure cannot
    // say that its input and its output share one lifetime (rustc: "lifetime may not live long
    // enough").
    fn of(v: &Value) -> Vec<&str> {
        v.as_array().map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default()
    }
    match property.get("enum") {
        Some(e) => (of(e), false),
        None => {
            (property.get("items").and_then(|i| i.get("enum")).map(of).unwrap_or_default(), true)
        }
    }
}

/// The listed value `given` stands for: its own spelling with other case or separators, else the
/// one a near miss names. `None` leaves it for the tool to judge.
fn listed_value<'a>(given: &str, values: &[&'a str]) -> Option<&'a str> {
    let wanted = folded(given);
    values
        .iter()
        .copied()
        .find(|v| folded(v) == wanted)
        .or_else(|| crate::mcp_hint::nearest(given, values.iter().copied()))
}

/// Reads the values of `params.arguments` against the values tool `params.name`'s schema lists
/// (see the module), and returns what it read. Run it after [`normalize`], so a key renamed to a
/// listed one has its value read too.
pub fn values(tools: &Value, params: &mut Value) -> Vec<Reread> {
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
    let Some(schema) = schema(tools, &name) else { return Vec::new() };
    let Some(listed) = schema.get("properties").and_then(Value::as_object) else {
        return Vec::new();
    };
    let required: Vec<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let keys: Vec<String> = listed.keys().cloned().collect();
    let Some(args) = params.get_mut("arguments").and_then(Value::as_object_mut) else {
        return Vec::new();
    };
    let mut reread = Vec::new();
    for key in keys {
        let (values, per_entry) = listed_values(&listed[&key]);
        if values.is_empty() {
            continue;
        }
        let Some(given) = args.get(&key).cloned() else { continue };
        let entries: Vec<&Value> = match (&given, per_entry) {
            (Value::Array(a), true) => a.iter().collect(),
            (one, _) => vec![one],
        };
        if entries.iter().all(|e| e.as_str().is_some_and(|s| values.contains(&s))) {
            continue;
        }
        // Every one of them: no filter, unless the tool needs the key to act at all.
        if entries.len() == 1 {
            let one = entries[0].as_str().unwrap_or_default().trim().to_owned();
            if EVERY.contains(&one.to_ascii_lowercase().as_str())
                && !required.contains(&key.as_str())
            {
                args.remove(&key);
                reread.push(Reread { key, given: one, read_as: None });
                continue;
            }
        }
        let mut read: Vec<Value> = Vec::new();
        let mut told: Vec<(String, String)> = Vec::new();
        for entry in &entries {
            let Some(text) = entry.as_str() else {
                read.push((*entry).clone());
                continue;
            };
            match listed_value(text, &values) {
                Some(v) if v != text => {
                    told.push((text.to_owned(), v.to_owned()));
                    read.push(json!(v));
                }
                _ => read.push((*entry).clone()),
            }
        }
        if told.is_empty() {
            continue;
        }
        let whole = match (&given, per_entry) {
            (Value::Array(_), true) => Value::Array(read),
            _ => read.into_iter().next().unwrap_or(Value::Null),
        };
        args.insert(key.clone(), whole);
        for (given, read_as) in told {
            reread.push(Reread { key: key.clone(), given, read_as: Some(read_as) });
        }
    }
    reread
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

/// Whether the schema types this property as an array (`"type": "array"`, or a type list that
/// holds it, as a nullable list is written).
fn wants_list(property: &Value) -> bool {
    match property.get("type") {
        Some(Value::String(t)) => t == "array",
        Some(Value::Array(ts)) => ts.iter().any(|t| t.as_str() == Some("array")),
        _ => false,
    }
}

/// Reads a scalar given for a key tool `params.name`'s schema types as an array as a list of
/// that one value, and returns the keys it read that way. Run it after [`normalize`] (which
/// does the same for a key it renames) and before [`values`], so a list's own listed values are
/// read per entry.
///
/// Why: one fact is the shape of one fact. `wrap_up {"learned": "..."}` with a single
/// well-formed fact was refused 11 times in 24 h on one host, and each refusal threw away the
/// recap in the same call -- a round trip and a lost answer for a value the tool could read.
pub fn lists(tools: &Value, params: &mut Value) -> Vec<String> {
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
    let Some(listed) = properties(tools, &name) else { return Vec::new() };
    let keys: Vec<(String, bool)> =
        listed.iter().map(|(k, v)| (k.clone(), wants_list(v))).collect();
    let Some(args) = params.get_mut("arguments").and_then(Value::as_object_mut) else {
        return Vec::new();
    };
    let mut wrapped = Vec::new();
    for (key, list) in keys {
        if !list {
            continue;
        }
        // Null is not a value given: a key set to null is the caller leaving it out, and
        // `[null]` is a list with an entry in it.
        match args.get(&key) {
            None | Some(Value::Null) | Some(Value::Array(_)) => continue,
            Some(_) => {}
        }
        let Some(one) = args.remove(&key) else { continue };
        args.insert(key.clone(), json!([one]));
        wrapped.push(key);
    }
    wrapped
}

/// The one line that tells a call's renames and value reads: `(read argument session as name)`,
/// `(read argument state "all" as every state)`.
pub fn line(renamed: &[Renamed], reread: &[Reread], wrapped: &[String]) -> Option<String> {
    if renamed.is_empty() && reread.is_empty() && wrapped.is_empty() {
        return None;
    }
    let mut each: Vec<String> =
        renamed.iter().map(|r| format!("{} as {}", r.given, r.canonical)).collect();
    each.extend(reread.iter().map(|r| match &r.read_as {
        Some(v) => format!("{} {:?} as {v:?}", r.key, r.given),
        None => format!("{} {:?} as every one of them (no filter)", r.key, r.given),
    }));
    each.extend(wrapped.iter().map(|key| format!("{key} as a list of the one value given")));
    Some(format!("(read argument {}; the schema's names are canonical)", each.join(", ")))
}

/// Adds [`line`] to a tool result's content, as its last text.
pub fn tell(result: &mut Value, renamed: &[Renamed], reread: &[Reread], wrapped: &[String]) {
    let Some(text) = line(renamed, reread, wrapped) else { return };
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
