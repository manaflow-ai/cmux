//! A range of an acpmux log as text an agent can read: what was asked, what the agent said, each
//! tool call and the start of its result, with the name that brings the whole result back.
//!
//! This is what partial decompaction hands back by default. A compacted agent holds a summary
//! and the range names of the turns it summarized ([`outline`]); it asks for one and reads a few
//! kilobytes ([`digest`]) instead of the megabyte of records the turn is on disk, then pulls any
//! one tool result whole by its `seq`.

use crate::Result;
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
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    (&s[..end], s.len() - end)
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
    for line in &lines {
        let Ok(v) = serde_json::from_slice::<Value>(line) else { continue };
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
            "tool_call_update" => {
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

/// One line a turn: its range name, when it started (ms since 1970), how many records it holds,
/// and the start of what was asked.
pub fn outline(pack: &Pack) -> Result<String> {
    let m = &pack.manifest;
    let starts: Vec<u64> = m.marks().collect();
    let mut out = String::new();
    // The turn-start records sit in every segment, so read each segment's once.
    let all = pack.read_lines(starts.first().copied().unwrap_or(0)..m.lines)?;
    let base = starts.first().copied().unwrap_or(0);
    for (i, first) in starts.iter().enumerate() {
        let last = starts.get(i + 1).copied().unwrap_or(m.lines) - 1;
        let v: Value = serde_json::from_slice(&all[(first - base) as usize]).unwrap_or(Value::Null);
        let prompt = v
            .pointer("/msg/promptLine")
            .or_else(|| v.pointer("/msg/prompt"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let at = v.get("at").and_then(Value::as_u64).unwrap_or(0);
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
