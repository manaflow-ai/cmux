//! A page's oversized tool output goes cut short (`_acpmux/events` `toolOutputMaxBytes`).
//!
//! The phone reads a chat's older history a page at a time (256 KiB of records), but a page
//! always carries a record whole: one 2 MB command log made a page nine times its bound, on the
//! wire and in the parse, every time the chat scrolled up past it. A reader that names
//! `toolOutputMaxBytes` gets a tool call record past it with its output's text cut to its head,
//! marked `update._meta.acpmux.cut` with the whole record's size and seq; it reads the record
//! whole (`afterSeq: seq - 1, limit: 1`) when the person opens the output. A reader that does not
//! name it (the Mac's own pane, an older phone) reads every record whole, as before.

use super::paging::record_bytes;
use super::*;

/// A string of a tool's output shorter than this is never cut: ids, paths, exit codes and
/// short lines stay as they are, whatever the record holds.
const CUT_MIN_BYTES: usize = 1024;

/// What a cut record's output keeps, at most, of `max` (the reader's `toolOutputMaxBytes`): half,
/// so the record's other fields and the marker fit with room to spare.
fn output_budget(max: usize) -> usize {
    (max / 2).max(CUT_MIN_BYTES)
}

/// The record's tool output strings: each `content` text block's text (`type: content`,
/// `content.type: text`) and every string in `rawOutput`. Diffs (`type: diff`) are left whole:
/// the phone counts and shows their lines, and a cut diff would read as a smaller change.
fn output_strings(update: &mut Value) -> Vec<&mut String> {
    let mut out = Vec::new();
    let Some(update) = update.as_object_mut() else { return out };
    for (key, value) in update.iter_mut() {
        match key.as_str() {
            "content" => {
                for block in value.as_array_mut().into_iter().flatten() {
                    if block.get("type").and_then(Value::as_str) != Some("content") {
                        continue;
                    }
                    let Some(inner) = block.get_mut("content") else { continue };
                    if inner.get("type").and_then(Value::as_str) != Some("text") {
                        continue;
                    }
                    if let Some(Value::String(text)) = inner.get_mut("text") {
                        out.push(text);
                    }
                }
            }
            "rawOutput" => strings_in(value, &mut out),
            _ => {}
        }
    }
    out
}

fn strings_in<'a>(value: &'a mut Value, out: &mut Vec<&'a mut String>) {
    match value {
        Value::String(text) => out.push(text),
        Value::Array(items) => items.iter_mut().for_each(|item| strings_in(item, out)),
        Value::Object(map) => map.values_mut().for_each(|item| strings_in(item, out)),
        _ => {}
    }
}

/// `text`'s first `keep` bytes or fewer, at a char boundary, ending after its last newline in
/// them when one falls in their second half (a log cut mid-line reads as a broken line).
fn head(text: &str, keep: usize) -> &str {
    if text.len() <= keep {
        return text;
    }
    let mut end = keep;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let cut = &text[..end];
    match cut.rfind('\n') {
        Some(at) if at >= end / 2 => &cut[..=at],
        _ => cut,
    }
}

/// Whether the record is a tool call, or an update of one, from the agent.
fn is_tool_record(rec: &EventRecord) -> bool {
    rec.dir == "in" && matches!(rec.kind.as_str(), "tool_call" | "tool_call_update")
}

/// `rec` (of `bytes` bytes) with its tool output cut to fit `max`, and its bytes after; `rec`
/// unchanged when it fits, is no tool call, or holds no output long enough to cut.
pub(super) fn cut_tool_output(
    mut rec: EventRecord,
    bytes: usize,
    max: usize,
) -> (EventRecord, usize) {
    if bytes <= max || !is_tool_record(&rec) {
        return (rec, bytes);
    }
    let seq = rec.seq;
    let Some(update) = rec.msg.pointer_mut("/params/update") else { return (rec, bytes) };
    let mut strings: Vec<&mut String> =
        output_strings(update).into_iter().filter(|s| s.len() > CUT_MIN_BYTES).collect();
    if strings.is_empty() {
        return (rec, bytes);
    }
    // Shared out evenly: a Codex command's text and its `rawOutput` copy each keep their head.
    let share = (output_budget(max) / strings.len()).max(CUT_MIN_BYTES);
    let mut cut_any = false;
    for text in strings.iter_mut() {
        let kept = head(text, share).len();
        if kept < text.len() {
            text.truncate(kept);
            cut_any = true;
        }
    }
    if !cut_any {
        return (rec, bytes);
    }
    let marker = json!({"bytes": bytes, "seq": seq});
    if let Some(update) = update.as_object_mut() {
        let meta = update.entry("_meta").or_insert_with(|| json!({}));
        if !meta.is_object() {
            *meta = json!({});
        }
        let acpmux = meta.as_object_mut().map(|m| m.entry("acpmux").or_insert_with(|| json!({})));
        match acpmux {
            Some(Value::Object(acpmux)) => {
                acpmux.insert("cut".into(), marker);
            }
            Some(other) => *other = json!({"cut": marker}),
            None => {}
        }
    }
    let after = record_bytes(&rec);
    (rec, after)
}

#[cfg(test)]
#[path = "tool_output_cut_tests.rs"]
mod tests;
