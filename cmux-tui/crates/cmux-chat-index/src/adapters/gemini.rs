//! Gemini CLI: `<gemini home>/tmp/<project>/chats/session-*.jsonl` (legacy:
//! one `.json` object). Line 1 is metadata; `$set` records patch it and
//! `$rewindTo` drops a message and everything after it. The project folder
//! is in `tmp/<project>/.project_root`. Subagent chats are skipped.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{argv, file_stem};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{fold_lines, read_whole_json};
use crate::stamp::FileStamp;
use crate::text::{prompt_text, title_field};
use crate::time::parse_rfc3339_ms;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let Ok(projects) = fs::read_dir(root.join("tmp")) else { return Ok(out) };
    for project in projects.flatten() {
        let Ok(chats) = fs::read_dir(project.path().join("chats")) else { continue };
        for chat in chats.flatten() {
            let is_file = chat.file_type().is_ok_and(|kind| kind.is_file());
            let name = chat.file_name();
            let name = name.to_str().unwrap_or_default();
            if is_file
                && name.starts_with("session-")
                && (name.ends_with(".jsonl") || name.ends_with(".json"))
            {
                out.push(chat.path());
            }
        }
    }
    Ok(out)
}

pub(super) fn read(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let mut chat = Chat::default();
    if path.extension().is_some_and(|ext| ext == "json") {
        let Some(legacy) = read_whole_json(path)? else { return Ok(None) };
        chat.meta(&legacy);
        for message in legacy.get("messages").and_then(Value::as_array).into_iter().flatten() {
            chat.message(message);
        }
    } else {
        let mut first = true;
        fold_lines(path, 0, |line| {
            let Ok(record) = serde_json::from_slice::<Value>(line) else { return };
            if std::mem::take(&mut first) {
                chat.meta(&record);
            } else if let Some(patch) = record.get("$set") {
                chat.meta(patch);
            } else if let Some(target) = record.get("$rewindTo").and_then(Value::as_str) {
                if let Some(at) = chat.messages.iter().position(|(id, _)| id == target) {
                    chat.messages.truncate(at);
                }
            } else {
                chat.message(&record);
            }
        })?;
    }
    if chat.subagent {
        return Ok(None);
    }
    let Some(session_id) = chat.session_id.or_else(|| file_stem(path)) else { return Ok(None) };
    let (title, title_source) =
        match (chat.summary, chat.messages.iter().find_map(|(_, prompt)| prompt.clone())) {
            (Some(summary), _) => (Some(summary), Some(TitleSource::Ai)),
            (None, Some(prompt)) => (Some(prompt), Some(TitleSource::Prompt)),
            (None, None) => (None, None),
        };
    Ok(Some(ChatEntry {
        harness: AdapterKind::Gemini,
        title,
        title_source,
        cwd: project_root(path),
        created_ms: chat.created_ms,
        updated_ms: chat.updated_ms.unwrap_or(stamp.mtime_ms),
        message_count: Some(chat.messages.len() as u64),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Argv { argv: argv(&["gemini", "--resume", &session_id]), cwd_needed: true },
        session_id,
    }))
}

#[derive(Default)]
struct Chat {
    session_id: Option<String>,
    subagent: bool,
    summary: Option<String>,
    created_ms: Option<i64>,
    updated_ms: Option<i64>,
    /// (message id, title line when it is a typed user prompt)
    messages: Vec<(String, Option<String>)>,
}

impl Chat {
    fn meta(&mut self, record: &Value) {
        let text = |key: &str| record.get(key).and_then(Value::as_str);
        if let Some(id) = text("sessionId") {
            self.session_id = Some(id.to_owned());
        }
        if let Some(kind) = text("kind") {
            self.subagent = kind == "subagent";
        }
        if let Some(summary) = title_field(record.get("summary")) {
            self.summary = Some(summary);
        }
        self.created_ms = text("startTime").and_then(parse_rfc3339_ms).or(self.created_ms);
        self.updated_ms = text("lastUpdated").and_then(parse_rfc3339_ms).or(self.updated_ms);
    }

    fn message(&mut self, record: &Value) {
        let (Some(id), Some(kind)) =
            (record.get("id").and_then(Value::as_str), record.get("type").and_then(Value::as_str))
        else {
            return;
        };
        if !matches!(kind, "user" | "gemini") {
            return;
        }
        let prompt =
            if kind == "user" { record.get("content").and_then(prompt_text) } else { None };
        self.messages.push((id.to_owned(), prompt));
    }
}

/// `tmp/<project>/.project_root` next to `chats/`, when present and small.
fn project_root(path: &Path) -> Option<String> {
    let file = path.parent()?.parent()?.join(".project_root");
    if fs::metadata(&file).ok()?.len() > 4096 {
        return None;
    }
    let text = fs::read_to_string(file).ok()?;
    let root = text.trim();
    (!root.is_empty()).then(|| root.to_owned())
}
