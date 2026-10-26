//! Latest complete assistant code, independent of a reader's forward cursor.
//! Read from the log's tail, never from the first page of a long conversation.

use pulldown_cmark::{CodeBlockKind, Event, Parser, Tag, TagEnd};
use serde_json::{Value, json};

use super::{MAX_EVENT_PAGES, Transcript, visible_text};

const MAX_SCAN_BYTES: usize = 8 << 20;
const MAX_BLOCK_BYTES: usize = 8 << 10;
// A normal page can overshoot its 160 KiB budget by one escaped 8 KiB item
// (48 KiB). This field adds at most 16 KiB, below MCP's 256 KiB result cap.
const MAX_FIELD_BYTES: usize = 16 << 10;

pub(super) fn load(mut events: impl FnMut(u64) -> Result<Value, String>) -> Result<Value, String> {
    let mut before = u64::MAX;
    let mut pages = Vec::new();
    let mut bytes = 0;
    for _ in 0..MAX_EVENT_PAGES {
        let page = events(before)?;
        let older = page
            .get("events")
            .and_then(Value::as_array)
            .ok_or(crate::localization::chat_code::text().invalid_page)?;
        let more = page.get("hasMore") == Some(&Value::Bool(true));
        if older.is_empty() {
            if more {
                return Err(crate::localization::chat_code::text().stalled_cursor.into());
            }
        } else {
            let first = older
                .first()
                .and_then(|event| event.get("seq"))
                .and_then(Value::as_u64)
                .filter(|seq| *seq < before)
                .ok_or(crate::localization::chat_code::text().stalled_cursor)?;
            bytes += page.to_string().len();
            if bytes > MAX_SCAN_BYTES {
                return Err(scan_limit());
            }
            before = first;
            pages.push(older.clone());
        }
        let mut transcript = Transcript::default();
        for page in pages.iter().rev() {
            for event in page {
                transcript.apply(event);
            }
        }
        if let Some(block) = from_transcript(&transcript, more) {
            return Ok(block);
        }
        if !more {
            return Ok(Value::Null);
        }
    }
    Err(scan_limit())
}

fn scan_limit() -> String {
    crate::localization::chat_code::text().scan_limit.into()
}

pub(super) fn from_transcript(transcript: &Transcript, more: bool) -> Option<Value> {
    transcript
        .items
        .iter()
        .enumerate()
        .rev()
        // The first item may start before the oldest page we have. Do not
        // parse a suffix of Markdown as a new answer. Wait for its boundary.
        .filter(|(index, item)| item.role == "assistant" && (!more || *index > 0))
        .find_map(|(_, item)| extract(&visible_text(&item.text, false)))
}

fn extract(text: &str) -> Option<Value> {
    let mut latest = None;
    let mut current = None;
    for (event, range) in Parser::new(text).into_offset_iter() {
        match event {
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info))) => {
                let source = text.get(range.clone()).unwrap_or_default();
                current = closed_fence(source).then(|| {
                    (
                        info.split_whitespace().next().unwrap_or_default().to_owned(),
                        String::new(),
                        range.end,
                        range.start,
                    )
                });
            }
            Event::Text(value) => {
                if let Some((_, code, _, text_end)) = current.as_mut() {
                    code.push_str(&value);
                    *text_end = range.end;
                }
            }
            Event::End(TagEnd::CodeBlock) => {
                if let Some((language, code, end, text_end)) = current.take()
                    && text_end < end
                {
                    latest = Some(bounded(&language, code.strip_suffix('\n').unwrap_or(&code)));
                }
            }
            _ => {}
        }
    }
    latest
}

// CommonMark also emits an End for an unclosed fence at EOF. A completed
// block must contain a closing line, even if the assistant turn has ended.
fn closed_fence(source: &str) -> bool {
    let mut lines = source.lines();
    let Some(first) = lines.next() else { return false };
    let Some(last) = lines.last() else { return false };
    let opener = first.trim_start_matches(|ch: char| ch != '`' && ch != '~');
    let Some(marker) = opener.chars().next() else { return false };
    let width = opener.chars().take_while(|ch| *ch == marker).count();
    let closer = last.trim_start_matches([' ', '\t', '>']);
    let close_width = closer.chars().take_while(|ch| *ch == marker).count();
    width >= 3 && close_width >= width && closer.trim_start_matches(marker).trim().is_empty()
}

fn prefix(text: &str, maximum: usize) -> &str {
    let mut end = text.len().min(maximum);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.get(..end).unwrap_or_default()
}

fn bounded(language: &str, code: &str) -> Value {
    let mut block =
        json!({"language": prefix(language, 256), "code": prefix(code, MAX_BLOCK_BYTES)});
    let mut truncated = language.len() > 256 || code.len() > MAX_BLOCK_BYTES;
    while block.to_string().len() > MAX_FIELD_BYTES {
        let text = block.get("code").and_then(Value::as_str).unwrap_or_default();
        block["code"] = json!(prefix(text, text.len() / 2));
        truncated = true;
    }
    if truncated {
        block["truncated"] = json!(true);
    }
    block
}

#[cfg(test)]
mod tests;
