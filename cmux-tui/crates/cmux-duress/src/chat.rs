//! The chat load: the recorded acpmux session looped to `chat_records` records. `seq` is
//! renumbered from 1; every id a record carries (tool calls, messages, turns, subagents, tasks)
//! gets a `-dN` suffix on the Nth replay after the first, so replays never collide and records of
//! one replay still refer to each other. `msg` is otherwise written byte for byte. `at` is the
//! relative delivery ms: the recording's own gaps scaled to a mean of `1000 / chat_rate` ms (its
//! bursts stay bursts), then shaped by the link with each record's line length as its bytes.

use serde::Serialize;
use serde_json::value::RawValue;

use crate::inputs::ChatRecord;
use crate::link::Link;

/// The keys whose string values are ids, rewritten per replay. The acpmux `sessionId` and Claude's
/// `session_id` are the one session and stay.
const ID_KEYS: &[&str] = &[
    "toolCallId",
    "messageId",
    "id",
    "uuid",
    "agentId",
    "task_id",
    "run_id",
    "tool_use_id",
    "subagentSessionId",
    "taskId",
    "turnId",
    "promptId",
    "parent_task_id",
    "bgTaskId",
    "toolUseId",
    "request_id",
    "origin",
    "segment",
];

#[derive(Serialize)]
struct Line<'a> {
    #[serde(rename = "sessionId")]
    session_id: &'a str,
    seq: u64,
    at: u64,
    dir: &'a str,
    kind: &'a str,
    msg: &'a RawValue,
}

/// `count` records as `chat.ndjson` lines (no newline), delivery times nondecreasing.
pub fn chat(
    recorded: &[ChatRecord],
    count: u64,
    rate: u64,
    link: &mut Link,
) -> Result<Vec<String>, String> {
    if count == 0 || recorded.is_empty() {
        return Ok(Vec::new());
    }
    let gaps = scaled_gaps(recorded, rate);
    let mut out = Vec::with_capacity(count as usize);
    let mut sent_us = 0_u64;
    let mut renamed: Vec<String> = Vec::new();
    for seq in 1..=count {
        let index = ((seq - 1) % recorded.len() as u64) as usize;
        let replay = (seq - 1) / recorded.len() as u64;
        if index == 0 {
            renamed.clear();
        }
        let Some(record) = recorded.get(index) else { continue };
        let msg = if replay == 0 {
            record.msg.clone()
        } else {
            rename_ids(&record.msg, &format!("-d{replay}"))
        };
        let raw = RawValue::from_string(msg).map_err(|error| format!("record {seq}: {error}"))?;
        // The bytes on the link: the line as sent (the delivery time's digits barely change it).
        let mut line = Line {
            session_id: &record.session_id,
            seq,
            at: sent_us / 1000,
            dir: &record.dir,
            kind: &record.kind,
            msg: &raw,
        };
        let bytes = serde_json::to_string(&line).map_err(|error| error.to_string())?.len() + 1;
        line.at = link.deliver(sent_us, bytes) / 1000;
        out.push(serde_json::to_string(&line).map_err(|error| error.to_string())?);
        sent_us += gaps.get(index).copied().unwrap_or(0);
    }
    Ok(out)
}

/// The gap after each record in microseconds, the last one wrapping to the next replay at the
/// mean; scaled so the mean is `1_000_000 / rate`. Rate 0 sends everything at once.
fn scaled_gaps(recorded: &[ChatRecord], rate: u64) -> Vec<u64> {
    if rate == 0 {
        return vec![0; recorded.len()];
    }
    let mut gaps: Vec<u64> = recorded
        .windows(2)
        .map(|pair| match pair {
            [before, after] => after.at.saturating_sub(before.at),
            _ => 0,
        })
        .collect();
    let mean_ms = gaps.iter().sum::<u64>() as f64 / gaps.len().max(1) as f64;
    gaps.push(mean_ms as u64);
    let target_us = 1_000_000.0 / rate as f64;
    if mean_ms <= 0.0 {
        return vec![target_us as u64; recorded.len()];
    }
    let scale = target_us / mean_ms;
    gaps.into_iter().map(|gap| (gap as f64 * scale).round() as u64).collect()
}

/// `msg` with `suffix` added to every id value (inserted before the last `.` of a `segment`,
/// which ends in its index). Works on the JSON text, so everything else keeps its bytes.
pub fn rename_ids(msg: &str, suffix: &str) -> String {
    let mut out = msg.to_owned();
    for key in ID_KEYS {
        let needle = format!("\"{key}\":\"");
        if !out.contains(&needle) {
            continue;
        }
        let mut next = String::with_capacity(out.len() + 64);
        let mut rest = out.as_str();
        while let Some(found) = rest.find(&needle) {
            let Some((head, tail)) = rest.split_at_checked(found + needle.len()) else { break };
            next.push_str(head);
            let Some((value, after)) = tail.split_at_checked(string_end(tail)) else {
                next.push_str(tail);
                rest = "";
                break;
            };
            let dot = if *key == "segment" { value.rfind('.') } else { None };
            match dot.and_then(|dot| value.split_at_checked(dot)) {
                Some((stem, last)) => {
                    next.push_str(stem);
                    next.push_str(suffix);
                    next.push_str(last);
                }
                None => {
                    next.push_str(value);
                    next.push_str(suffix);
                }
            }
            rest = after;
        }
        next.push_str(rest);
        out = next;
    }
    out
}

/// Where a JSON string's body ends (the index of its closing quote) in `text`, which starts just
/// after the opening quote.
fn string_end(text: &str) -> usize {
    let bytes = text.as_bytes();
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
        match byte {
            b'\\' => index += 2,
            b'"' => return index,
            _ => index += 1,
        }
    }
    bytes.len()
}

#[cfg(test)]
#[path = "chat_tests.rs"]
mod tests;
