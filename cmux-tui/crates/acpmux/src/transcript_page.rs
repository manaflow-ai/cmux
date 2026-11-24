//! Bounded, backwards transcript paging for terminal agent panes.
//!
//! Claude Code and Codex append JSONL records while a terminal pane stays open.  A page starts
//! at the newest records and walks backwards by byte offset, so opening a very large transcript
//! never parses its prefix.  Tool calls are folded with the same rules as adopted chats.

use std::fs::File;
use std::io;
use std::path::Path;

use serde_json::Value;

use super::{Fold, PastTurn, Step, codex_item_step, codex_step, page};

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
}

/// Read at most `want` turns ending at `before`, or at the current file end when it is `None`.
/// `family` accepts `"claude"` and `"codex"`. I/O errors are returned to the caller.
///
/// The file is opened once and bounded by its length at open time. A partial trailing line is
/// skipped, allowing a concurrently written record to be read on the next request.
/// The RPC encodes a bounded preview and serves long message text separately.
/// A single JSONL record larger than [`page::PAGE_MAX_BYTES`] is advanced past as an oversized record,
/// so it cannot stall older-page cursors.
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
    let mut previous_prompt: Option<(String, bool)> = None;
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
            let Some(Step::Prompt(text)) = codex_step(record).or_else(|| codex_item_step(record))
            else {
                return page::Prompt::Other;
            };
            // Some Codex versions write an event and a response item for the same prompt. Equal
            // consecutive user turns in the same representation are distinct.
            if previous_prompt
                .as_ref()
                .is_some_and(|(older, kind)| *kind != event && older == &text)
            {
                previous_prompt = None;
                return page::Prompt::Mirror;
            }
            previous_prompt = Some((text, event));
            page::Prompt::New
        },
    )?;
    let mut fold = Fold::with_answer_limit(family, true, page::PAGE_MAX_BYTES as usize);
    if !raw.has_prompt && !raw.lines.is_empty() {
        fold.turns.push(PastTurn::default());
        if codex {
            fold.items.push(PastTurn::default());
        }
    }
    for (_, record) in raw.lines.into_iter().rev().filter(|(at, _)| *at >= raw.start) {
        fold.record(&record);
    }
    if !raw.has_prompt
        && codex
        && fold.turns.iter().all(|t| t.answer.is_empty() && t.tools.is_empty())
    {
        fold.turns.clear();
    }
    let mut turns = fold.finish();
    turns.retain(|t| !t.prompt.is_empty() || !t.answer.is_empty() || !t.tools.is_empty());
    Ok(TranscriptPage { turns, start: raw.start, end, read: raw.read })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;

    #[test]
    fn newest_claude_page_is_bounded_and_folds_tools() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("claude.jsonl");
        let mut out = std::io::BufWriter::new(File::create(&path).unwrap());
        for n in 0..80 {
            writeln!(out, "{}", json!({"type":"user","message":{"content":format!("prompt {n}")}}))
                .unwrap();
            writeln!(out, "{}", json!({"type":"assistant","message":{"content":[{"type":"text","text":format!("answer {n}")}],"stop_reason":"end_turn"}})).unwrap();
        }
        out.flush().unwrap();
        let page = transcript_page(&path, "claude", None, 20).unwrap();
        assert_eq!(page.turns.len(), 20);
        assert_eq!(page.turns.last().unwrap().prompt, "prompt 79");
        assert!(page.start > 0);
        assert!(page.read <= page::PAGE_MAX_BYTES);
    }

    #[test]
    fn codex_event_messages_are_folded() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("codex.jsonl");
        let mut out = std::io::BufWriter::new(File::create(&path).unwrap());
        for n in 0..4 {
            writeln!(out, "{}", json!({"type":"event_msg","payload":{"type":"user_message","message":format!("prompt {n}")}})).unwrap();
            writeln!(out, "{}", json!({"type":"event_msg","payload":{"type":"agent_message","message":format!("answer {n}")}})).unwrap();
        }
        out.flush().unwrap();
        let page = transcript_page(&path, "codex", None, 2).unwrap();
        assert_eq!(
            page.turns.iter().map(|turn| turn.prompt.as_str()).collect::<Vec<_>>(),
            ["prompt 2", "prompt 3"]
        );
    }

    #[test]
    fn terminal_agent_history_mirrored_codex_turns_are_not_split_at_page_edges() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let mut writer = File::create(&path).unwrap();
        for i in 0..6 {
            let prompt = format!("turn {i}");
            let answer = format!("answer {i}");
            for record in [
                json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":prompt}]}}),
                json!({"type":"event_msg","payload":{"type":"user_message","message":prompt}}),
                json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":answer}]}}),
                json!({"type":"event_msg","payload":{"type":"agent_message","message":answer}}),
            ] {
                writeln!(writer, "{record}").unwrap();
            }
        }
        let mut before = None;
        for i in (0..6).rev() {
            let page = transcript_page(&path, "codex", before, 1).unwrap();
            assert_eq!(page.turns.len(), 1);
            assert_eq!(page.turns[0].prompt, format!("turn {i}"));
            assert_eq!(page.turns[0].answer, format!("answer {i}"));
            assert!(page.start < page.end);
            before = Some(page.start);
        }
        assert_eq!(before, Some(0));
    }

    #[test]
    fn terminal_agent_history_pages_past_one_huge_tool_and_an_unfinished_tail() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("claude.jsonl");
        let mut writer = std::io::BufWriter::new(File::create(&path).unwrap());
        writeln!(writer, "{}", json!({"type":"user","message":{"content":"day one"}})).unwrap();
        writeln!(writer, "{}", json!({"type":"assistant","message":{"content":"before tool"}}))
            .unwrap();
        let huge = "t".repeat(page::PAGE_MAX_BYTES as usize + 1);
        writeln!(writer, "{}", json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":huge}]}})).unwrap();
        writeln!(writer, "{}", json!({"type":"user","message":{"content":"today"}})).unwrap();
        writeln!(writer, "{}", json!({"type":"assistant","message":{"content":"after tool"}}))
            .unwrap();
        writer.write_all(br#"{"type":"user","message":{"content":"still being written"#).unwrap();
        writer.flush().unwrap();
        let mut prompts = Vec::new();
        let mut before = None;
        loop {
            let slice = transcript_page(&path, "claude", before, 1).unwrap();
            assert!(slice.start < slice.end);
            assert!(slice.read <= page::PAGE_MAX_BYTES);
            prompts
                .extend(slice.turns.into_iter().filter(|t| !t.prompt.is_empty()).map(|t| t.prompt));
            if slice.start == 0 {
                break;
            }
            before = Some(slice.start);
        }
        assert_eq!(prompts, ["today", "day one"]);
    }
}
