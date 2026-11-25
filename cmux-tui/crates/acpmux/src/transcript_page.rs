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

    /// The same page/find/page route used by the read-only desktop view: start with old
    /// item-only turns, cross a mirrored/event-only range, and resume on annotated items.
    #[cfg(unix)]
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn terminal_agent_history_reads_mixed_codex_and_finds_the_pre_resume_turn() {
        use crate::{
            chats::ChatSources,
            config::{Config, StoreMode},
            hub::Hub,
        };
        use std::sync::Arc;

        let home = tempfile::tempdir_in("/tmp").unwrap();
        let root = home.path().canonicalize().unwrap();
        let id = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5c";
        let day = root.join(".codex/sessions/2026/11/12");
        std::fs::create_dir_all(&day).unwrap();
        let path = day.join(format!("rollout-2026-11-12T07-00-00-{id}.jsonl"));
        let mut file = File::create(&path).unwrap();
        writeln!(file, "{}", json!({"type":"session_meta","payload":{"id":id,"cwd":"/repo","timestamp":"2026-11-12T07:00:00Z"}})).unwrap();
        for n in 0..40 {
            // Distinct turns at a transition can have the same prompt text.
            let prompt = if n == 6 || n == 7 { "again".to_owned() } else { format!("ask {n}") };
            let answer = format!("Answer from turn #{n}.");
            let item = |role, text: &str| {
                let mut payload = json!({"type":"message","role":role,"content":[{"text":text}]});
                if n >= 22 {
                    payload["internal_chat_message_metadata_passthrough"] = json!({
                        "content_item_kinds": [if role == "user" { "user.text" } else { "unknown" }]
                    });
                }
                json!({"type":"response_item","payload":payload})
            };
            let event = |ty, msg| json!({"type":"event_msg","payload":{"type":ty,"message":msg}});
            let items = n != 7;
            let events = (7..16).contains(&n);
            if items {
                writeln!(file, "{}", item("user", &prompt)).unwrap();
            }
            if events {
                writeln!(file, "{}", event("user_message", &prompt)).unwrap();
            }
            if items {
                writeln!(file, "{}", item("assistant", &answer)).unwrap();
            }
            if events {
                writeln!(file, "{}", event("agent_message", &answer)).unwrap();
            }
        }
        drop(file);
        let mut cfg: Config = serde_json::from_value(json!({"harnesses":{}})).unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, &root).unwrap();
        let hub = Hub::new(cfg, store);
        hub.start_chats(ChatSources {
            home: root.clone(),
            acpmux_home: root.join("test-daemon-state"),
            env: Arc::new(|_| None),
            launch_roots: Vec::new(),
            user_roots: Vec::new(),
        })
        .await
        .unwrap();
        let socket = root.join("history.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(crate::server::serve_unix(hub, listener));
        let client = crate::client::Client::connect_without_caller(&socket).await.unwrap();
        let key = format!("codex:{id}");
        let page = crate::rpc::method::MUX_CHAT_TRANSCRIPT_PAGE;
        let find = crate::rpc::method::MUX_CHAT_TRANSCRIPT_FIND;
        let latest = client.request(page, json!({"key":key})).await.unwrap();
        let older =
            client.request(page, json!({"key":key, "before":latest["before"]})).await.unwrap();
        assert_eq!(latest["turns"].as_array().unwrap().len(), 32);
        assert!(older["before"].is_null());
        let all: Vec<_> = [older["turns"].as_array().unwrap(), latest["turns"].as_array().unwrap()]
            .into_iter()
            .flatten()
            .collect();
        assert_eq!(all.len(), 40);
        for (n, row) in all.iter().enumerate() {
            assert_eq!(row["answer"], format!("Answer from turn #{n}."), "{row}");
        }
        let mut before = Value::Null;
        loop {
            let found = client
                .request(find, json!({"key":key,"query":"#6.","before":before}))
                .await
                .unwrap();
            if let Some(hit) = found["hits"].as_array().unwrap().first() {
                let reread =
                    client.request(page, json!({"key":key,"before":hit["pageEnd"]})).await.unwrap();
                let turn = &reread["turns"][hit["turn"].as_u64().unwrap() as usize];
                assert_eq!(turn["prompt"], "again");
                assert_eq!(turn["answer"], "Answer from turn #6.");
                break;
            }
            before = found["before"].clone();
            assert!(before.is_u64(), "older answer missing");
        }
        server.abort();
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
