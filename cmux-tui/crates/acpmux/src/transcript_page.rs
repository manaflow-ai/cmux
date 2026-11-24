//! Bounded, backwards transcript paging for terminal agent panes.
//!
//! Claude Code and Codex append JSONL records while a terminal pane stays open.  A page starts
//! at the newest records and walks backwards by byte offset, so opening a very large transcript
//! never parses its prefix.  Tool calls are folded with the same rules as adopted chats.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

use super::{Fold, PastTurn, Step, claude_steps, record_time};

/// The maximum useful content read for one page.
pub const PAGE_BYTES: u64 = 8 << 20;
/// A malformed or unusually large record cannot make one request unbounded.
pub const PAGE_MAX_BYTES: u64 = 16 << 20;
const CHUNK: u64 = 1 << 20;

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
/// `family` accepts `"claude"` and `"codex"`. An unreadable file returns an empty page.
///
/// The file is opened once and bounded by its length at open time. A partial trailing line is
/// skipped, allowing a concurrently written record to be read on the next request.
pub fn transcript_page(
    file: &Path,
    family: &str,
    before: Option<u64>,
    want: usize,
)-> io::Result<TranscriptPage> {
    let mut file = File::open(file)?;
    let len = file.metadata()?.len();
    let end = before.map_or(len, |offset| offset.min(len));
    transcript_page_open(&mut file, family, end, want)
}

fn transcript_page_open(file: &mut File, family: &str, end: u64, want: usize)-> io::Result<TranscriptPage> {
    let want = want.max(1);
    let mut pos = end;
    let mut head = Vec::new();
    let mut skip_partial = true;
    let mut lines: Vec<(u64, Vec<u8>)> = Vec::new();
    let mut oldest_prompt = None;
    let mut prompts = 0usize;

    'scan: loop {
        if pos == 0 {
            if !head.is_empty() {
                let offset = 0;
                if is_prompt(&head, family) {
                    prompts += 1;
                    oldest_prompt = Some(offset);
                }
                lines.push((offset, head));
            }
            break 'scan 0;
        }
        let take = CHUNK.min(pos);
        pos -= take;
        let mut buf = vec![0u8; take as usize];
        file.seek(SeekFrom::Start(pos))?;
        file.read_exact(&mut buf)?;
        buf.extend_from_slice(&head);

        if skip_partial {
            match memchr::memrchr(b'\n', &buf) {
                Some(index) => {
                    buf.truncate(index + 1);
                    skip_partial = false;
                }
                None => {
                    head.clear();
                    if end - pos >= PAGE_MAX_BYTES {
                        break 'scan pos;
                    }
                    continue;
                }
            }
        }

        // Bytes before the first break may be a line prefix. Keep it for the next chunk.
        let whole_from = memchr::memchr(b'\n', &buf).map_or(buf.len(), |index| index + 1);
        let mut line_end = buf.len();
        while line_end > whole_from {
            let body_end = line_end - 1;
            let line_start = memchr::memrchr(b'\n', &buf[..body_end]).map_or(0, |index| index + 1);
            let offset = pos + line_start as u64;
            let line = buf[line_start..body_end].to_vec();
            if is_prompt(&line, family) {
                prompts += 1;
                oldest_prompt = Some(offset);
            }
            lines.push((offset, line));
            if prompts >= want {
                break 'scan oldest_prompt.unwrap_or(offset);
            }
            line_end = line_start;
        }
        head = buf[..whole_from].to_vec();

        let read = end - pos;
        if prompts >= want {
            break 'scan oldest_prompt.unwrap_or(pos);
        }
        if read >= PAGE_BYTES {
            break 'scan oldest_prompt.unwrap_or(pos);
        }
        if read >= PAGE_MAX_BYTES {
            break 'scan oldest_prompt.unwrap_or(if lines.is_empty() { pos } else { pos + head.len() as u64 });
        }
    };

    let start = oldest_prompt.unwrap_or_else(|| {
        lines.first().map(|(offset, _)| *offset).unwrap_or(pos)
    });
    let mut fold = Fold::new(family, true);
    // A page can begin after Codex's item-kind marker. Infer current-rollout item mode from the
    // records in this page so paging does not lose response_item turns.
    if family == "codex"
        && lines.iter().any(|(_, line)| {
            serde_json::from_slice::<Value>(line)
                .ok()
                .and_then(|record| record.get("type").and_then(Value::as_str).map(|kind| kind == "response_item"))
                .unwrap_or(false)
        })
    {
        fold.assume_codex_items();
    }
    for (offset, line) in lines.into_iter().rev() {
        if offset < start {
            continue;
        }
        fold.line(&line);
    }
    Ok(TranscriptPage { turns: fold.finish(), start, end, read: end - pos })
}

fn is_prompt(line: &[u8], family: &str) -> bool {
    let Ok(record) = serde_json::from_slice::<Value>(line) else { return false };
    match family {
        "codex" => super::codex_step(&record)
            .or_else(|| super::codex_item_step(&record))
            .is_some_and(|step| matches!(step, Step::Prompt(_))),
        _ => claude_steps(&record, record_time(&record))
            .iter()
            .any(|step| matches!(step, Step::Prompt(_))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use serde_json::json;

    fn file(name: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("acpmux-transcript-page-{name}-{}", std::process::id()));
        let _ = std::fs::remove_file(&path);
        path
    }

    #[test]
    fn newest_claude_page_is_bounded_and_folds_tools() {
        let path = file("claude");
        let mut out = std::io::BufWriter::new(File::create(&path).unwrap());
        for n in 0..80 {
            writeln!(out, "{}", json!({"type":"user","message":{"content":format!("prompt {n}")}})).unwrap();
            writeln!(out, "{}", json!({"type":"assistant","message":{"content":[{"type":"text","text":format!("answer {n}")}],"stop_reason":"end_turn"}})).unwrap();
        }
        let page = transcript_page(&path, "claude", None, 20).unwrap();
        assert_eq!(page.turns.len(), 20);
        assert_eq!(page.turns.last().unwrap().prompt, "prompt 79");
        assert!(page.start > 0);
        assert!(page.read <= PAGE_MAX_BYTES);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn codex_event_messages_are_folded() {
        let path = file("codex");
        let mut out = std::io::BufWriter::new(File::create(&path).unwrap());
        for n in 0..4 {
            writeln!(out, "{}", json!({"type":"event_msg","payload":{"type":"user_message","message":format!("prompt {n}")}})).unwrap();
            writeln!(out, "{}", json!({"type":"event_msg","payload":{"type":"agent_message","message":format!("answer {n}")}})).unwrap();
        }
        let page = transcript_page(&path, "codex", None, 2).unwrap();
        assert_eq!(page.turns.iter().map(|turn| turn.prompt.as_str()).collect::<Vec<_>>(), ["prompt 2", "prompt 3"]);
        let _ = std::fs::remove_file(path);
    }
}
