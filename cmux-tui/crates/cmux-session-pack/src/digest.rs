//! A range of an acpmux log or a Claude Code transcript as text an agent can read: what was
//! asked, what the agent said, each tool call and the start of its result, with the command that
//! brings the whole result back (`session-pack seq` for an acpmux record, `session-pack range`
//! of the one line for a transcript's).
//!
//! This is what partial decompaction hands back by default. A compacted agent holds a summary
//! and the range names of the turns it summarized ([`outline`]); it asks for one and reads a few
//! kilobytes ([`digest`]) instead of the megabyte of records the turn is on disk, then pulls any
//! one tool result whole by its `seq`.

use crate::Result;
use crate::claude;
use crate::manifest::RangeId;
use crate::read::Pack;
use serde_json::Value;
use std::fmt::Write as _;

/// How much of a prompt, a tool's input and a tool's result a digest shows.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Bytes of a person's message.
    pub prompt: usize,
    /// Bytes of a tool call's input.
    pub input: usize,
    /// Bytes of a tool call's result.
    pub result: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self { prompt: 4000, input: 400, result: 600 }
    }
}

fn cut(s: &str, max: usize) -> (&str, usize) {
    if s.len() <= max {
        return (s, 0);
    }
    // `s.get` is `Some` at a char boundary, and 0 is one.
    let mut end = max;
    loop {
        if let Some(head) = s.get(..end) {
            return (head, s.len() - end);
        }
        end -= 1;
    }
}

fn flush(out: &mut String, say: &mut String, thought: &mut usize) {
    if *thought > 0 {
        let _ = writeln!(out, "(thinking: {thought} bytes, not shown)");
        *thought = 0;
    }
    if !say.trim().is_empty() {
        let _ = writeln!(out, "assistant: {}", say.trim());
    }
    say.clear();
}

/// The lines of `range` of `pack` as text. `name` is the session's name, for the commands the
/// text gives.
pub fn digest(pack: &Pack, range: &RangeId, limits: Limits) -> Result<String> {
    let lines = pack.read_lines(range.first..range.last.saturating_add(1))?;
    let name = &range.name;
    let mut out = String::new();
    let (mut say, mut thought) = (String::new(), 0usize);
    let _ = writeln!(out, "# {range}: {} records", lines.len());
    for (line_no, line) in (range.first..).zip(&lines) {
        let Ok(v) = serde_json::from_slice::<Value>(line) else { continue };
        if v.get("kind").is_none() && v.get("type").is_some() {
            let at = Line { name, line: line_no, limits };
            transcript_line(&mut out, &mut say, &mut thought, &v, &at);
            continue;
        }
        let seq = v.get("seq").and_then(Value::as_u64).unwrap_or(0);
        let kind = v.get("kind").and_then(Value::as_str).unwrap_or("");
        let update = v.pointer("/msg/params/update");
        match kind {
            "agent_message_chunk" => {
                say.push_str(
                    update
                        .and_then(|u| u.pointer("/content/text"))
                        .and_then(Value::as_str)
                        .unwrap_or(""),
                );
            }
            "agent_thought_chunk" => {
                thought += update
                    .and_then(|u| u.pointer("/content/text"))
                    .and_then(Value::as_str)
                    .map_or(0, str::len);
            }
            "user_message" => {
                flush(&mut out, &mut say, &mut thought);
                let text = v.pointer("/msg/text").and_then(Value::as_str).unwrap_or("");
                let (shown, more) = cut(text, limits.prompt);
                let _ = writeln!(out, "\nuser (seq {seq}): {shown}");
                if more > 0 {
                    let _ = writeln!(out, "  [{more} more bytes: session-pack seq {name} {seq}]");
                }
            }
            "tool_call" | "tool_call_update" => {
                let Some(u) = update else { continue };
                if let Some(input) = u.get("rawInput") {
                    flush(&mut out, &mut say, &mut thought);
                    let tool = u
                        .pointer("/_meta/claude/tool")
                        .or_else(|| u.get("kind"))
                        .and_then(Value::as_str)
                        .unwrap_or("tool");
                    let text = input.to_string();
                    let (shown, more) = cut(&text, limits.input);
                    let _ = writeln!(
                        out,
                        "tool {tool} (seq {seq}): {shown}{}",
                        if more > 0 { format!(" [{more} more bytes]") } else { String::new() }
                    );
                }
                let status = u.get("status").and_then(Value::as_str).unwrap_or("");
                if let Some(content) = u.get("content").and_then(Value::as_array)
                    && matches!(status, "completed" | "failed")
                {
                    flush(&mut out, &mut say, &mut thought);
                    let mut text = String::new();
                    for c in content {
                        match c.pointer("/content/text").and_then(Value::as_str) {
                            Some(t) => text.push_str(t),
                            None => {
                                let _ = write!(
                                    text,
                                    "[{}]",
                                    c.pointer("/content/type")
                                        .or_else(|| c.get("type"))
                                        .and_then(Value::as_str)
                                        .unwrap_or("content")
                                );
                            }
                        }
                    }
                    let (shown, more) = cut(&text, limits.result);
                    let _ = writeln!(out, "  result ({status}, {} bytes): {shown}", text.len());
                    if more > 0 {
                        let _ =
                            writeln!(out, "  [{more} more bytes: session-pack seq {name} {seq}]");
                    }
                }
            }
            "compaction_summary" => {
                flush(&mut out, &mut say, &mut thought);
                let len =
                    update.and_then(|u| u.get("text")).and_then(Value::as_str).map_or(0, str::len);
                let _ = writeln!(
                    out,
                    "\n(context compacted here; its summary, {len} bytes: session-pack seq {name} {seq})"
                );
            }
            "turn_result" => {
                flush(&mut out, &mut say, &mut thought);
                let m = v.get("msg");
                let field =
                    |k: &str| m.and_then(|m| m.get(k)).map(Value::to_string).unwrap_or_default();
                let _ = writeln!(
                    out,
                    "(turn ended: {}, {} model calls, {} output tokens)",
                    field("status"),
                    field("modelCalls"),
                    field("outputTokens")
                );
            }
            _ => {}
        }
    }
    flush(&mut out, &mut say, &mut thought);
    Ok(out)
}

/// Where a transcript line is, for the commands a digest gives.
struct Line<'a> {
    name: &'a str,
    line: u64,
    limits: Limits,
}

impl Line<'_> {
    /// The note under something cut short: how much was left out and the command that reads it.
    fn more(&self, out: &mut String, more: usize) {
        if more > 0 {
            let (n, l) = (self.name, self.line);
            let _ = writeln!(out, "  [{more} more bytes: session-pack range {n}@{l}-{l}]");
        }
    }
}

/// A text block list's text, with what is not text named in brackets.
fn blocks_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => {
            let mut text = String::new();
            for b in blocks {
                match b.get("text").and_then(Value::as_str) {
                    Some(t) => text.push_str(t),
                    None => {
                        let kind = b.get("type").and_then(Value::as_str).unwrap_or("content");
                        let _ = write!(text, "[{kind}]");
                    }
                }
            }
            text
        }
        _ => String::new(),
    }
}

/// One line of a Claude Code transcript: a person's prompt, the assistant's text, thinking and
/// tool calls, a tool's result, a compaction's summary, a notice the harness sent.
fn transcript_line(
    out: &mut String,
    say: &mut String,
    thought: &mut usize,
    v: &Value,
    at: &Line<'_>,
) {
    let set = |k: &str| v.get(k).and_then(Value::as_bool) == Some(true);
    // A subagent's lines are its own conversation; the parent's tool call and result hold what
    // it was asked and what it said.
    if set("isSidechain") {
        return;
    }
    let (n, l) = (at.name, at.line);
    let content = v.pointer("/message/content");
    match v.get("type").and_then(Value::as_str).unwrap_or("") {
        "assistant" => {
            let Some(Value::Array(blocks)) = content else { return };
            for b in blocks {
                match b.get("type").and_then(Value::as_str).unwrap_or("") {
                    "text" => {
                        if !say.is_empty() {
                            say.push('\n');
                        }
                        say.push_str(b.get("text").and_then(Value::as_str).unwrap_or(""));
                    }
                    "thinking" | "redacted_thinking" => {
                        *thought += b
                            .get("thinking")
                            .or_else(|| b.get("data"))
                            .and_then(Value::as_str)
                            .map_or(0, str::len);
                    }
                    "tool_use" => {
                        flush(out, say, thought);
                        let tool = b.get("name").and_then(Value::as_str).unwrap_or("tool");
                        let input = b.get("input").map(Value::to_string).unwrap_or_default();
                        let (shown, more) = cut(&input, at.limits.input);
                        let _ = writeln!(
                            out,
                            "tool {tool} (line {l}): {shown}{}",
                            if more > 0 { format!(" [{more} more bytes]") } else { String::new() }
                        );
                    }
                    _ => {}
                }
            }
        }
        "user" if set("isCompactSummary") => {
            flush(out, say, thought);
            let len = content.map_or(0, |c| blocks_text(c).len());
            let _ = writeln!(
                out,
                "\n(context compacted here; its summary, {len} bytes: session-pack range {n}@{l}-{l})"
            );
        }
        "user" if set("isMeta") => {}
        "user" => {
            let results: Vec<&Value> = match content {
                Some(Value::Array(blocks)) => blocks
                    .iter()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
                    .collect(),
                _ => Vec::new(),
            };
            if !results.is_empty() {
                flush(out, say, thought);
                for r in results {
                    let text = r.get("content").map(blocks_text).unwrap_or_default();
                    let status = if r.get("is_error").and_then(Value::as_bool) == Some(true) {
                        "error"
                    } else {
                        "ok"
                    };
                    let (shown, more) = cut(&text, at.limits.result);
                    let _ = writeln!(out, "  result ({status}, {} bytes): {shown}", text.len());
                    at.more(out, more);
                }
                return;
            }
            let text = content.map(blocks_text).unwrap_or_default();
            if text.is_empty() {
                return;
            }
            flush(out, say, thought);
            let (shown, more) = match claude::asked(v) {
                Some(asked) => {
                    let (shown, more) = cut(&asked, at.limits.prompt);
                    let _ = writeln!(out, "\nuser (line {l}): {shown}");
                    (String::new(), more)
                }
                // A notice the harness sent in the user's place (a background task's result, an
                // interrupt, a command's output).
                None => {
                    let (shown, more) = cut(&text, at.limits.input);
                    (format!("notice (line {l}): {shown}"), more)
                }
            };
            if !shown.is_empty() {
                let _ = writeln!(out, "{shown}");
            }
            at.more(out, more);
        }
        _ => {}
    }
}

/// `s` on one line: each run of whitespace a single space.
fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// One line a turn: its range name, when it started (ms since 1970), how many records it holds,
/// and the start of what was asked.
pub fn outline(pack: &Pack) -> Result<String> {
    let m = &pack.manifest;
    let starts: Vec<u64> = m.marks().collect();
    let mut out = String::new();
    // Long strings are left out, so no blob chunk is read. Rows whose prompt was
    // stored as a blob are read again with their blobs, and only those lines' blob
    // chunks are read.
    let all = pack.skim_lines(&starts)?;
    let mut rows = Vec::with_capacity(starts.len());
    let mut again = Vec::new();
    for (i, line) in all.iter().enumerate() {
        let v: Value = serde_json::from_slice(line).unwrap_or(Value::Null);
        let row = if v.get("kind").is_none()
            && let Some(asked) = claude::asked(&v)
        {
            if asked.trim().is_empty() {
                again.push(i);
            }
            (claude::timestamp_ms(&v).unwrap_or(0), one_line(&asked))
        } else {
            let prompt = v
                .pointer("/msg/promptLine")
                .or_else(|| v.pointer("/msg/prompt"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let has_prompt_field =
                v.pointer("/msg/promptLine").is_some() || v.pointer("/msg/prompt").is_some();
            if v.get("kind").is_some() && has_prompt_field && prompt.is_empty() {
                again.push(i);
            }
            (v.get("at").and_then(Value::as_u64).unwrap_or(0), prompt.to_owned())
        };
        rows.push(row);
    }
    let lines: Vec<u64> = again.iter().filter_map(|i| starts.get(*i).copied()).collect();
    for (i, line) in again.iter().zip(pack.lines_at(&lines)?) {
        let v: Value = serde_json::from_slice(&line).unwrap_or(Value::Null);
        if let Some(row) = rows.get_mut(*i) {
            if v.get("kind").is_none() {
                if let Some(asked) = claude::asked(&v) {
                    row.1 = one_line(&asked);
                }
            } else {
                row.1 = v
                    .pointer("/msg/promptLine")
                    .or_else(|| v.pointer("/msg/prompt"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
            }
        }
    }
    for (i, (first, (at, prompt))) in starts.iter().zip(&rows).enumerate() {
        let last = starts.get(i + 1).copied().unwrap_or(m.lines) - 1;
        let _ = writeln!(
            out,
            "{}\t{at}\t{}\t{}",
            RangeId { name: m.name.clone(), first: *first, last },
            last - first + 1,
            cut(prompt, 160).0
        );
    }
    Ok(out)
}
