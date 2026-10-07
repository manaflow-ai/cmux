//! Claude Code: `<root>/<encoded cwd>/<session uuid>.jsonl`, append-only.
//! Title and folder come from the head and tail windows (as Claude's own
//! picker reads them); the message count is folded incrementally.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{file_stem, files_one_level_down};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{contains, fold_lines, read_head_tail};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};
use crate::text::{prompt_text, title_field};
use crate::time::parse_rfc3339_ms;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    // Old-layout subagents sit beside sessions as agent-*.jsonl; new-layout
    // ones are under <uuid>/subagents/ and are two levels down, so not listed.
    files_one_level_down(root, |name| name.ends_with(".jsonl") && !name.starts_with("agent-"))
}

pub(super) fn read(
    path: &Path,
    stamp: FileStamp,
    prev: Option<&FileState>,
) -> io::Result<FileRead> {
    let window = read_head_tail(path)?;
    if window.head.first().is_some_and(|first| first.get("isSidechain") == Some(&Value::Bool(true)))
    {
        return Ok(FileRead {
            entry: None,
            state: FileState { stamp, offset: stamp.size, ..FileState::default() },
        });
    }
    let (from, mut tally) = FileState::resume_point(prev, &stamp);
    let offset = fold_lines(path, from, |line| {
        if contains(line, br#""type":"user""#) || contains(line, br#""type":"assistant""#) {
            tally.messages += 1;
        }
    })?;
    let mut titles = Titles::default();
    for record in window.all() {
        titles.add(record);
    }
    let (title, title_source) = titles.best();
    let session_id = file_stem(path).ok_or_else(|| io::Error::other("session file has no name"))?;
    let entry = ChatEntry {
        harness: AdapterKind::ClaudeCode,
        session_id,
        title,
        title_source,
        cwd: titles.cwd,
        created_ms: titles.created_ms,
        updated_ms: stamp.mtime_ms,
        message_count: Some(tally.messages),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Adopt,
    };
    Ok(FileRead { entry: Some(entry), state: FileState { stamp, offset, tally } })
}

/// Last custom title > last AI title > last prompt > first typed prompt.
/// A `summary` record alone never names a chat: it can describe another one.
#[derive(Default)]
struct Titles {
    custom: Option<String>,
    ai: Option<String>,
    last_prompt: Option<String>,
    first_prompt: Option<String>,
    cwd: Option<String>,
    created_ms: Option<i64>,
}

impl Titles {
    fn add(&mut self, record: &Value) {
        if self.cwd.is_none() {
            self.cwd = record
                .get("cwd")
                .and_then(Value::as_str)
                .filter(|cwd| !cwd.is_empty())
                .map(str::to_owned);
        }
        if self.created_ms.is_none() {
            self.created_ms =
                record.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms);
        }
        match record.get("type").and_then(Value::as_str) {
            Some("custom-title") => {
                replace(&mut self.custom, title_field(record.get("customTitle")));
            }
            Some("ai-title") => replace(&mut self.ai, title_field(record.get("aiTitle"))),
            Some("last-prompt") => {
                replace(&mut self.last_prompt, title_field(record.get("lastPrompt")));
            }
            Some("user") if self.first_prompt.is_none() && is_typed(record) => {
                self.first_prompt = record.pointer("/message/content").and_then(prompt_text);
            }
            _ => {}
        }
    }

    fn best(&self) -> (Option<String>, Option<TitleSource>) {
        [
            (&self.custom, TitleSource::Custom),
            (&self.ai, TitleSource::Ai),
            (&self.last_prompt, TitleSource::Prompt),
            (&self.first_prompt, TitleSource::Prompt),
        ]
        .into_iter()
        .find_map(|(title, source)| title.clone().map(|title| (Some(title), Some(source))))
        .unwrap_or((None, None))
    }
}

fn replace(slot: &mut Option<String>, value: Option<String>) {
    if value.is_some() {
        *slot = value;
    }
}

fn is_typed(record: &Value) -> bool {
    ["isMeta", "isSidechain", "isCompactSummary"]
        .iter()
        .all(|flag| record.get(*flag) != Some(&Value::Bool(true)))
}
