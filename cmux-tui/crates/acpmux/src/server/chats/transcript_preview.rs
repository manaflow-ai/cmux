//! Terminal-history pages cross the app's 1 MiB JSON reply bridge. A huge message may need a
//! preview, but must never evict a sibling or change a turn index reported by Find. The index
//! and search read the underlying turn even when its display preview has been shortened.

use serde_json::{Value, json};

use crate::adopt_replay::{PastTurn, TranscriptPage};
use crate::adopt_tools::PastTool;
use crate::no_panic::JsonExt;
use crate::rpc::RpcError;

// Leave space for the chat key, title, cursor, dates and JSON-RPC/native envelopes.
const ROWS_BUDGET: usize = 960 * 1024;
const ROW_OVERHEAD: usize = 256; // property names, two u64 timestamps, truncation flag and comma
const TOOL_OVERHEAD: usize = 16; // {"title":""},

pub(super) fn tool_title(tool: &PastTool) -> &str {
    tool.call.get("title").and_then(Value::as_str).unwrap_or("Tool call")
}

pub(super) fn title(text: &str) -> &str {
    let mut bytes = 4096;
    take_text(text, &mut bytes)
}

/// Debit the bytes serde_json uses between the quotes, stopping on a whole UTF-8 character.
fn take_text<'a>(text: &'a str, remaining: &mut usize) -> &'a str {
    for (offset, ch) in text.char_indices() {
        let bytes = match ch {
            '"' | '\\' | '\n' | '\t' | '\r' | '\u{0008}' | '\u{000c}' => 2,
            '\u{0000}'..='\u{001f}' => 6,
            _ => ch.len_utf8(),
        };
        if bytes > *remaining {
            return &text[..offset];
        }
        *remaining -= bytes;
    }
    text
}

// Six is the longest possible JSON escape for one input byte. Short rows reserve only what
// they could actually need, leaving the unused part of their share available to long rows.
fn wire_bound(turn: &PastTurn) -> usize {
    ROW_OVERHEAD
        + 6 * (turn.prompt.len() + turn.answer.len())
        + turn.tools.iter().map(|t| TOOL_OVERHEAD + 6 * tool_title(t).len()).sum::<usize>()
}

pub(super) fn turns(page: &TranscriptPage) -> Vec<Value> {
    let fair_share = ROWS_BUDGET / page.turns.len().max(1);
    let shares: Vec<_> = page.turns.iter().map(|t| wire_bound(t).min(fair_share)).collect();
    let mut reserved = shares.iter().sum::<usize>();
    let mut remaining = ROWS_BUDGET;
    page.turns
        .iter()
        .zip(shares)
        .map(|(turn, share)| {
            reserved -= share;
            let allowance = remaining - reserved;
            let (row, used) = preview(turn, allowance);
            remaining -= used;
            row
        })
        .collect()
}

fn preview(turn: &PastTurn, allowance: usize) -> (Value, usize) {
    let content = allowance - ROW_OVERHEAD;
    let prompt_reserve = (content / 3).min(6 * turn.prompt.len());
    let answer_reserve = (content / 3).min(6 * turn.answer.len());
    let mut tool_budget = content - prompt_reserve - answer_reserve;
    let mut tools = Vec::new();
    let mut shortened = false;
    for tool in &turn.tools {
        if tool_budget < TOOL_OVERHEAD {
            shortened = true;
            break;
        }
        tool_budget -= TOOL_OVERHEAD;
        let title = tool_title(tool);
        let shown = take_text(title, &mut tool_budget);
        shortened |= shown.len() < title.len();
        tools.push(json!({"title":shown}));
    }
    let mut prose_budget = prompt_reserve + tool_budget;
    let prompt = take_text(&turn.prompt, &mut prose_budget);
    prose_budget += answer_reserve;
    let answer = take_text(&turn.answer, &mut prose_budget);
    shortened |= prompt.len() != turn.prompt.len() || answer.len() != turn.answer.len();
    let mut row = json!({
        "prompt":prompt,"answer":answer,"promptAt":turn.prompt_at,"answerAt":turn.answer_at,
        "tools":tools,"truncated":shortened
    });
    if prompt.len() < turn.prompt.len() {
        row.set("promptMore", json!(prompt.len()));
    }
    if answer.len() < turn.answer.len() {
        row.set("answerMore", json!(answer.len()));
    }
    (row, allowance - prose_budget)
}

/// An exact turn on the source page, including a UTF-8 byte offset supplied by a previous reply.
pub(super) struct TextChunk {
    turn: usize,
    assistant: bool,
    offset: usize,
}

impl TextChunk {
    pub fn parse(params: &Value, can_read: bool) -> Result<Option<Self>, RpcError> {
        if ["turn", "role", "offset"].iter().all(|field| params.get(*field).is_none()) {
            return Ok(None);
        }
        if !can_read {
            return Err(RpcError::invalid_params("text chunks need a transcript page end"));
        }
        let number = |name| {
            params
                .get(name)
                .and_then(Value::as_u64)
                .and_then(|n| usize::try_from(n).ok())
                .ok_or_else(|| {
                    RpcError::invalid_params(format!("{name} must be an unsigned integer"))
                })
        };
        let assistant = match params.get("role").and_then(Value::as_str) {
            Some("user") => false,
            Some("assistant") => true,
            _ => return Err(RpcError::invalid_params("role must be user or assistant")),
        };
        Ok(Some(Self { turn: number("turn")?, assistant, offset: number("offset")? }))
    }

    pub fn reply(&self, page: &TranscriptPage) -> Result<Value, RpcError> {
        let row = page
            .turns
            .get(self.turn)
            .ok_or_else(|| RpcError::invalid_params("turn is outside this transcript page"))?;
        let raw = if self.assistant { &row.answer } else { &row.prompt };
        let tail = raw.get(self.offset..).ok_or_else(|| {
            RpcError::invalid_params("offset must be a UTF-8 boundary in the message")
        })?;
        let mut bytes = 128 * 1024;
        let text = take_text(tail, &mut bytes);
        let next = (text.len() < tail.len()).then_some(self.offset + text.len());
        Ok(json!({"text":text, "nextOffset":next}))
    }
}

#[cfg(test)]
#[path = "transcript_preview_tests.rs"]
mod tests;
