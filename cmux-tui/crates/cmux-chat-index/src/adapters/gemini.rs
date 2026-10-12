//! Gemini CLI: `<gemini home>/tmp/<project>/chats/session-*.jsonl` (v0.39+;
//! v0.4-v0.38: one `.json` object). Line 1 is metadata; `$set` records
//! patch it and `$rewindTo` drops a message and everything after it. The
//! project folder is in `tmp/<project>/.project_root` (slug dirs, v0.29+;
//! older dirs are a sha256 of the folder and the migration copies them, so
//! the same session id can be in both). Subagent chats are skipped.
//! `/chat save` checkpoints (`tmp/<project>/checkpoint-<tag>.json`) are
//! chats too, and `tmp/<project>/logs.json` (every version) is the only
//! record of chats from before v0.4. Qwen Code v0.1-v0.3 wrote the same
//! layout under `~/.qwen` (message type `qwen`).

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, argv, file_stem, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{fold_lines, read_whole_json};
use crate::stamp::FileStamp;
use crate::text::{prompt_text, title_field};
use crate::time::parse_rfc3339_ms;

/// JSONL sessions above this size are listed from their header only.
const JSONL_MAX: u64 = 64 * 1024 * 1024;
/// Project dirs whose `logs.json` is read per scan.
const LOGGED_PROJECTS_MAX: usize = 256;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = list_chats(root);
    let Ok(projects) = fs::read_dir(root.join("tmp")) else { return Ok(out) };
    for project in projects.flatten() {
        let Ok(files) = fs::read_dir(project.path()) else { continue };
        for file in files.flatten() {
            let name = file.file_name();
            if file.file_type().is_ok_and(|kind| kind.is_file())
                && name.to_str().is_some_and(is_checkpoint_name)
            {
                out.push(file.path());
            }
        }
    }
    Ok(out)
}

fn is_checkpoint_name(name: &str) -> bool {
    name.starts_with("checkpoint-") && name.ends_with(".json")
}

/// `tmp/<project>/chats/session-*.json[l]` (Gemini, and Qwen Code v0.1-v0.3).
pub(super) fn list_chats(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(projects) = fs::read_dir(root.join("tmp")) else { return out };
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
    out
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    let name = parts.last().copied().unwrap_or_default();
    let session = match parts {
        ["tmp", _, "chats", _] => {
            name.starts_with("session-") && (name.ends_with(".jsonl") || name.ends_with(".json"))
        }
        ["tmp", _, _] => is_checkpoint_name(name),
        _ => false,
    };
    role(session, matches!(parts, ["tmp", _, "logs.json"]))
}

pub(super) fn read(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
    if is_checkpoint_name(name) {
        return read_checkpoint(path, stamp);
    }
    read_as(AdapterKind::Gemini, path, stamp)
}

/// A session file in the Gemini format, for Gemini or Qwen Code.
pub(super) fn read_as(
    kind: AdapterKind,
    path: &Path,
    stamp: FileStamp,
) -> io::Result<Option<ChatEntry>> {
    let mut chat = Chat::default();
    if path.extension().is_some_and(|ext| ext == "json") {
        let Some(legacy) = read_whole_json(path)? else { return Ok(None) };
        chat.meta(&legacy);
        for message in legacy.get("messages").and_then(Value::as_array).into_iter().flatten() {
            chat.message(message);
        }
    } else if fs::metadata(path)?.len() > JSONL_MAX {
        // Too large to fold on every change: the header names it.
        if let Some(record) = crate::lines::read_first_record(path)? {
            chat.meta(&record);
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
                chat.rewind(target);
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
    let resume = match kind {
        AdapterKind::Gemini => {
            Resume::Argv { argv: argv(&["gemini", "--resume", &session_id]), cwd_needed: true }
        }
        // Current Qwen Code no longer reads its v0.1-v0.3 chat files.
        _ => Resume::ReadOnly,
    };
    Ok(Some(ChatEntry {
        harness: kind,
        title,
        title_source,
        cwd: project_root(path),
        created_ms: chat.created_ms,
        updated_ms: chat.updated_ms.unwrap_or(stamp.mtime_ms),
        message_count: Some(chat.messages.len() as u64),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume,
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
    /// Message id to its index in `messages` (records upsert by id).
    at: HashMap<String, usize>,
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
        if !matches!(kind, "user" | "gemini" | "qwen") {
            return;
        }
        let prompt =
            if kind == "user" { record.get("content").and_then(typed_prompt) } else { None };
        match self.at.get(id) {
            Some(&index) => {
                if let Some(slot) = self.messages.get_mut(index) {
                    slot.1 = prompt;
                }
            }
            None => {
                self.at.insert(id.to_owned(), self.messages.len());
                self.messages.push((id.to_owned(), prompt));
            }
        }
    }

    /// `$rewindTo`: drop the message and everything after it.
    fn rewind(&mut self, target: &str) {
        let Some(&index) = self.at.get(target) else { return };
        for (id, _) in self.messages.drain(index..) {
            self.at.remove(&id);
        }
    }
}

/// A typed prompt: not a slash command, a `?` help query or injected context.
fn typed_prompt(content: &Value) -> Option<String> {
    let text = prompt_text(content)?;
    (!text.starts_with('/') && !text.starts_with('?')).then_some(text)
}

/// `tmp/<project>/.project_root` next to `chats/`, when present and small.
fn project_root(path: &Path) -> Option<String> {
    project_dir_root(path.parent()?.parent()?)
}

fn project_dir_root(project: &Path) -> Option<String> {
    let file = project.join(".project_root");
    if fs::metadata(&file).ok()?.len() > 4096 {
        return None;
    }
    let text = fs::read_to_string(file).ok()?;
    let root = text.trim();
    (!root.is_empty()).then(|| root.to_owned())
}

/// `/chat save <tag>`: `Content[]` before v0.16, `{history, authType?}`
/// after. No id or times: the id is `checkpoint:<project dir>/<tag>`.
fn read_checkpoint(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let Some(file) = read_whole_json(path)? else { return Ok(None) };
    let history = file.get("history").unwrap_or(&file).as_array();
    let Some(history) = history else { return Ok(None) };
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
    let tag = name.strip_prefix("checkpoint-").and_then(|rest| rest.strip_suffix(".json"));
    let Some(tag) = tag.filter(|tag| !tag.is_empty()) else { return Ok(None) };
    let project = path.parent();
    let project_name =
        project.and_then(Path::file_name).and_then(|name| name.to_str()).unwrap_or_default();
    let title = crate::text::title_line(&percent_decode(tag));
    Ok(Some(ChatEntry {
        harness: AdapterKind::Gemini,
        session_id: format!("checkpoint:{project_name}/{tag}"),
        title_source: title.as_ref().map(|_| TitleSource::Custom),
        title,
        cwd: project.and_then(project_dir_root),
        created_ms: None,
        updated_ms: stamp.mtime_ms,
        message_count: Some(
            history
                .iter()
                .filter(|turn| {
                    matches!(turn.get("role").and_then(Value::as_str), Some("user" | "model"))
                })
                .count() as u64,
        ),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        // `/chat resume <tag>` runs inside a session; there is no argv for it.
        resume: Resume::ReadOnly,
    }))
}

/// `%XX` escapes (tags are `encodeURIComponent`-encoded since v0.1.22).
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let hex = bytes.get(at + 1..at + 3).and_then(|pair| std::str::from_utf8(pair).ok());
        match (bytes[at], hex.and_then(|hex| u8::from_str_radix(hex, 16).ok())) {
            (b'%', Some(byte)) => {
                out.push(byte);
                at += 3;
            }
            (byte, _) => {
                out.push(byte);
                at += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Chats only `tmp/<project>/logs.json` remembers (before chat recording,
/// v0.4): one entry per session id that no chat file holds. Each record is
/// `{sessionId, messageId, timestamp, type: "user", message}`.
pub(super) fn add_logged_sessions(kind: AdapterKind, root: &Path, entries: &mut Vec<ChatEntry>) {
    let Ok(projects) = fs::read_dir(root.join("tmp")) else { return };
    let mut known: std::collections::HashSet<String> =
        entries.iter().map(|entry| entry.session_id.clone()).collect();
    for project in projects.flatten().take(LOGGED_PROJECTS_MAX) {
        let logs = project.path().join("logs.json");
        let Ok(Some(Value::Array(records))) = read_whole_json(&logs) else { continue };
        let mut sessions: Vec<(String, Logged)> = Vec::new();
        let mut index: HashMap<String, usize> = HashMap::new();
        for record in &records {
            let Some(id) = record.get("sessionId").and_then(Value::as_str) else { continue };
            if known.contains(id) {
                continue;
            }
            let at = record.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms);
            let prompt = record.get("message").and_then(typed_prompt);
            let slot_at = *index.entry(id.to_owned()).or_insert_with(|| {
                sessions.push((id.to_owned(), Logged::default()));
                sessions.len() - 1
            });
            let Some((_, slot)) = sessions.get_mut(slot_at) else { continue };
            slot.count += 1;
            slot.first_ms = match (slot.first_ms, at) {
                (Some(first), Some(at)) => Some(first.min(at)),
                (first, at) => first.or(at),
            };
            slot.last_ms = slot.last_ms.max(at);
            if slot.title.is_none() {
                slot.title = prompt;
            }
        }
        let cwd = project_dir_root(&project.path());
        for (id, logged) in sessions {
            known.insert(id.clone());
            entries.push(ChatEntry {
                harness: kind,
                title_source: logged.title.as_ref().map(|_| TitleSource::Prompt),
                title: logged.title,
                cwd: cwd.clone(),
                created_ms: logged.first_ms,
                updated_ms: logged.last_ms.or(logged.first_ms).unwrap_or(0),
                message_count: Some(logged.count),
                source_path: logs.clone(),
                originator: None,
                archived: false,
                resume: Resume::ReadOnly,
                session_id: id,
            });
        }
    }
}

#[derive(Default)]
struct Logged {
    count: u64,
    first_ms: Option<i64>,
    last_ms: Option<i64>,
    title: Option<String>,
}
