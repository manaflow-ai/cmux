//! Continue (the `cn` CLI and the IDE extensions share one store):
//! `<root>/sessions.json` is the index `[{sessionId, title, dateCreated,
//! workspaceDirectory, messageCount}]` and `<root>/<uuid>.json` holds each
//! session (`{sessionId, title, workspaceDirectory, history[]}`). Sessions
//! missing from the index are read from their files.

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, file_stem, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::scan::AdapterConfig;
use crate::stamp::FileStamp;
use crate::text::{prompt_text, title_line};

const INDEX: &str = "sessions.json";
/// The title Continue shows before it generates one.
const PLACEHOLDER: &str = "New Session";

pub(super) fn classify(parts: &[&str]) -> PathRole {
    role(false, matches!(parts, [name] if name.ends_with(".json")))
}

pub(super) fn read_store(root: &Path) -> io::Result<Vec<ChatEntry>> {
    let mut entries = Vec::new();
    let mut seen = HashSet::new();
    let index = read_whole_json(&root.join(INDEX)).ok().flatten();
    for item in index.as_ref().and_then(Value::as_array).into_iter().flatten() {
        // Entries with `session_id` are a legacy shape Continue itself drops.
        if item.get("session_id").is_some() {
            continue;
        }
        let Some(id) = item.get("sessionId").and_then(Value::as_str).filter(|id| valid_id(id))
        else {
            continue;
        };
        if !seen.insert(id.to_owned()) {
            continue;
        }
        let file = root.join(format!("{id}.json"));
        let mtime = mtime_ms(&file);
        let mut title = named(item.get("title"));
        let mut title_source = title.as_ref().map(|_| TitleSource::Ai);
        if title.is_none() {
            title = read_whole_json(&file).ok().flatten().as_ref().and_then(first_prompt);
            title_source = title.as_ref().map(|_| TitleSource::Prompt);
        }
        let created_ms = date_ms(item.get("dateCreated"));
        entries.push(ChatEntry {
            harness: AdapterKind::Continue,
            session_id: id.to_owned(),
            title,
            title_source,
            cwd: folder(item.get("workspaceDirectory")),
            created_ms,
            updated_ms: mtime.or(created_ms).unwrap_or(0),
            message_count: item.get("messageCount").and_then(Value::as_u64),
            source_path: if mtime.is_some() { file } else { root.join(INDEX) },
            originator: None,
            archived: false,
            resume: Resume::ReadOnly,
        });
    }
    let mut files: Vec<(PathBuf, i64)> = fs::read_dir(root)?
        .flatten()
        .filter(|child| child.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|child| child.path())
        .filter(|path| {
            path.extension().is_some_and(|ext| ext == "json")
                && file_stem(path).is_some_and(|stem| stem != "sessions" && !seen.contains(&stem))
        })
        .filter_map(|path| {
            let mtime = mtime_ms(&path)?;
            Some((path, mtime))
        })
        .collect();
    files.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    files.truncate(AdapterConfig::DEFAULT_MAX_FILES);
    for (path, mtime) in files {
        let Some(session) = read_whole_json(&path).ok().flatten() else { continue };
        let Some(id) = session
            .get("sessionId")
            .and_then(Value::as_str)
            .filter(|id| valid_id(id))
            .map(str::to_owned)
        else {
            continue;
        };
        if !seen.insert(id.clone()) {
            continue;
        }
        let (title, title_source) = match named(session.get("title")) {
            Some(title) => (Some(title), Some(TitleSource::Ai)),
            None => {
                let prompt = first_prompt(&session);
                let source = prompt.as_ref().map(|_| TitleSource::Prompt);
                (prompt, source)
            }
        };
        let assistants = history(&session)
            .filter(|item| {
                item.pointer("/message/role").and_then(Value::as_str) == Some("assistant")
            })
            .count();
        entries.push(ChatEntry {
            harness: AdapterKind::Continue,
            session_id: id,
            title,
            title_source,
            cwd: folder(session.get("workspaceDirectory")),
            created_ms: None,
            updated_ms: mtime,
            message_count: Some(assistants as u64),
            source_path: path,
            originator: None,
            archived: false,
            resume: Resume::ReadOnly,
        });
    }
    Ok(entries)
}

/// A session id that can name a file in the root (no separators).
/// An id that names a file directly in the root: no separators, no `..`,
/// no Windows drive prefix (`C:x` would replace the root in `join`).
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        && !id.starts_with('.')
}

fn mtime_ms(path: &Path) -> Option<i64> {
    fs::metadata(path).ok().map(|meta| FileStamp::of(&meta).mtime_ms)
}

/// A real title: not empty and not the placeholder.
fn named(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).filter(|title| title.trim() != PLACEHOLDER).and_then(title_line)
}

fn history(session: &Value) -> impl Iterator<Item = &Value> {
    session.get("history").and_then(Value::as_array).into_iter().flatten()
}

fn first_prompt(session: &Value) -> Option<String> {
    history(session)
        .filter(|item| item.pointer("/message/role").and_then(Value::as_str) == Some("user"))
        .find_map(|item| item.pointer("/message/content").and_then(prompt_text))
}

/// `dateCreated`: epoch ms as a string (current) or a number.
fn date_ms(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::String(text) => text.trim().parse().ok(),
        Value::Number(number) => number.as_i64().or_else(|| number.as_f64().map(|ms| ms as i64)),
        _ => None,
    }
}

/// The workspace folder: a path, or a `file://` URI from the IDE.
fn folder(value: Option<&Value>) -> Option<String> {
    let raw = value.and_then(Value::as_str)?.trim();
    let path = match raw.strip_prefix("file://") {
        Some(rest) => {
            // `file:///c%3A/x` on Windows: drop the slash before a drive letter.
            let decoded = percent_decode(rest);
            let bytes = decoded.as_bytes();
            if bytes.len() >= 3
                && bytes[0] == b'/'
                && bytes[2] == b':'
                && bytes[1].is_ascii_alphabetic()
            {
                decoded[1..].to_owned()
            } else {
                decoded
            }
        }
        None => raw.to_owned(),
    };
    (!path.is_empty()).then_some(path)
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'%'
            && let (Some(high), Some(low)) =
                (bytes.get(at + 1).and_then(hex), bytes.get(at + 2).and_then(hex))
        {
            out.push(high * 16 + low);
            at += 3;
            continue;
        }
        out.push(bytes[at]);
        at += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(byte: &u8) -> Option<u8> {
    char::from(*byte).to_digit(16).and_then(|digit| u8::try_from(digit).ok())
}
