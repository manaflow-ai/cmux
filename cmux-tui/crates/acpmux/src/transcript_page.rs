//! Bounded, backwards transcript paging for terminal agent panes.
//!
//! Claude Code and Codex append JSONL records while a terminal pane stays open.  A page starts
//! at the newest records and walks backwards by byte offset, so opening a very large transcript
//! never parses its prefix.  Tool calls are folded with the same rules as adopted chats.

use std::fs::File;
use std::io;
use std::path::Path;

use serde_json::Value;

use super::{
    Fold, PastTurn, Step, add_limited, codex_item_step, codex_step, codex_tool_step, page,
    record_time,
};

/// One lazily read page of a Claude Code or Codex transcript, oldest first.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TranscriptPage {
    /// Turns in display order. Tool calls and results are folded into each turn.
    pub turns: Vec<PastTurn>,
    /// Byte offset where the next older page ends. Zero means no older page exists.
    pub start: u64,
    /// The end offset used for this page. This is the file length for the newest page.
    pub end: u64,
    /// Bytes read while finding and folding this page.
    pub read: u64,
    /// Source extents for terminal clients recovering a line that didn't fit in a normal page.
    pub(crate) clipped_head: Option<std::ops::Range<u64>>,
    pub(crate) last_break: Option<u64>,
}

/// Read at most `want` turns ending at `before`, or at the current file end when it is `None`.
/// `family` accepts `"claude"` and `"codex"`. I/O errors are returned to the caller.
///
/// The file is opened once and bounded by its length at open time. A partial trailing line is
/// skipped, allowing a concurrently written record to be read on the next request.
/// The RPC encodes a bounded preview and serves long message text separately.
/// For a record spanning [`page::PAGE_MAX_BYTES`], the terminal RPC exposes the covered source
/// range on demand while the cursor advances by at most one bounded page.
pub fn transcript_page(
    file: &Path,
    family: &str,
    before: Option<u64>,
    want: usize,
) -> io::Result<TranscriptPage> {
    let mut file = File::open(file)?;
    let len = file.metadata()?.len();
    let end = before.map_or(len, |offset| offset.min(len));
    transcript_page_open(&mut file, family, end, want)
}

/// Page an already opened transcript. Unlike [`transcript_page`], an offset beyond the current
/// file length is rejected so callers that hold a file descriptor can detect rotation/truncation.
pub(crate) fn transcript_page_from(
    file: &mut File,
    family: &str,
    before: Option<u64>,
    want: usize,
) -> io::Result<TranscriptPage> {
    let len = file.metadata()?.len();
    let end = match before {
        Some(offset) if offset > len => {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "transcript cursor past EOF"));
        }
        Some(offset) => offset,
        None => len,
    };
    transcript_page_open(file, family, end, want)
}

fn transcript_page_open(
    file: &mut File,
    family: &str,
    end: u64,
    want: usize,
) -> io::Result<TranscriptPage> {
    let codex = family == "codex";
    let mut previous = CodexPrompts::default();
    let raw = page::scan_page(
        file,
        end,
        want,
        codex,
        |line| {
            if codex { serde_json::from_slice(line).ok() } else { page::parse(line) }
        },
        |record| {
            if !codex {
                return page::Prompt::from(page::is_prompt(record));
            }
            let event = record.get("type").and_then(Value::as_str) == Some("event_msg");
            codex_step(record)
                .or_else(|| codex_item_step(record))
                .map_or(page::Prompt::Other, |step| previous.classify(&step, event))
        },
    )?;
    let records = raw.lines.into_iter().rev().filter(|(at, _)| *at >= raw.start).map(|(_, v)| v);
    let mut turns = if codex {
        codex_turns(records, !raw.has_prompt)
    } else {
        let mut fold = Fold::with_answer_limit(family, true, page::PAGE_MAX_BYTES as usize);
        if !raw.has_prompt {
            fold.turns.push(PastTurn::default());
        }
        for record in records {
            fold.record(&record);
        }
        fold.finish()
    };
    turns.retain(|t| !t.prompt.is_empty() || !t.answer.is_empty() || !t.tools.is_empty());
    Ok(TranscriptPage {
        turns,
        start: raw.start,
        end,
        read: raw.read,
        clipped_head: raw.clipped_head,
        last_break: raw.last_break,
    })
}

/// Legacy Codex can write both an item and an event for one prompt. The pair must agree with
/// no intervening answer. Two successive actual turns may ask exactly the same question.
#[derive(Default)]
struct CodexPrompts(Option<(String, bool)>);

impl CodexPrompts {
    fn classify(&mut self, step: &Step, event: bool) -> page::Prompt {
        let Step::Prompt(text) = step else {
            self.0 = None;
            return page::Prompt::Other;
        };
        if self.0.as_ref().is_some_and(|(prev, source)| *source != event && prev == text) {
            self.0 = None;
            page::Prompt::Mirror
        } else {
            self.0 = Some((text.clone(), event));
            page::Prompt::New
        }
    }
}

/// Choose the representation per exchange. Resumed rollouts can contain item-only, mirrored,
/// event-only and annotated messages in the same byte page. A page-wide choice loses turns.
fn codex_turns(records: impl Iterator<Item = Value>, orphan: bool) -> Vec<PastTurn> {
    let mut turns = Vec::new();
    if orphan {
        turns.push(PastTurn::default());
    }
    let mut prompts = CodexPrompts::default();
    let mut event_answers = false;
    let mut tool_items = false;
    for record in records {
        let at = record_time(&record);
        let event = record.get("type").and_then(Value::as_str) == Some("event_msg");
        let step = if let Some(step) = codex_step(&record).or_else(|| codex_item_step(&record)) {
            match prompts.classify(&step, event) {
                page::Prompt::Mirror => continue,
                page::Prompt::New => event_answers = false,
                // A mirrored turn's authoritative agent messages replace its interim response
                // items. Preserve item answers when no event answer exists for this prompt.
                page::Prompt::Other if event && !event_answers => {
                    if let Some(turn) = turns.last_mut() {
                        turn.answer.clear();
                    }
                    event_answers = true;
                }
                page::Prompt::Other if !event && event_answers => continue,
                page::Prompt::Other => {}
            }
            step
        } else if let Some(tool) = codex_tool_step(&record, at, &mut tool_items) {
            tool
        } else {
            continue;
        };
        add_limited(&mut turns, step, at, page::PAGE_MAX_BYTES as usize);
    }
    turns
}

#[cfg(test)]
#[path = "transcript_page_tests.rs"]
mod tests;
