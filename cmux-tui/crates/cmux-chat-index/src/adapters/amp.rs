//! Amp: the local thread mirror `<root>/T-<uuid>.json` (whole-file
//! rewrites), written by builds up to 0.0.1774959077 (2026-03-31); later
//! builds keep threads on the server only. Thread shape: `{v, id, created,
//! title?, messages, env.initial.trees[0].uri, mainThreadID, archived}`.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, argv, file_stem, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::stamp::FileStamp;
use crate::text::{prompt_text, title_field};

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    Ok(fs::read_dir(root)?
        .flatten()
        .filter(|child| child.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|child| child.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("T-") && name.ends_with(".json"))
        })
        .collect())
}

pub(super) fn read(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let Some(session_id) = file_stem(path) else { return Ok(None) };
    // Larger than the parse bound: listed without a title or count.
    let thread = read_whole_json(path)?.unwrap_or(Value::Null);
    let messages = thread.get("messages").and_then(Value::as_array);
    // A subagent thread names its main thread.
    if thread.get("mainThreadID").and_then(Value::as_str).is_some_and(|id| !id.is_empty()) {
        return Ok(None);
    }
    let prompt = messages.into_iter().flatten().find_map(|message| {
        (message.get("role").and_then(Value::as_str) == Some("user"))
            .then(|| message.get("content").and_then(prompt_text))
            .flatten()
    });
    let (title, title_source) = match (title_field(thread.get("title")), prompt) {
        (Some(title), _) => (Some(title), Some(TitleSource::Ai)),
        (None, Some(prompt)) => (Some(prompt), Some(TitleSource::Prompt)),
        (None, None) => (None, None),
    };
    Ok(Some(ChatEntry {
        harness: AdapterKind::Amp,
        title_source,
        title,
        cwd: thread
            .pointer("/env/initial/trees/0/uri")
            .and_then(Value::as_str)
            .and_then(file_uri_path),
        created_ms: thread.get("created").and_then(Value::as_i64),
        updated_ms: stamp.mtime_ms,
        message_count: messages.map(|messages| messages.len() as u64),
        source_path: path.to_path_buf(),
        originator: None,
        archived: thread.get("archived") == Some(&Value::Bool(true)),
        resume: Resume::Argv {
            argv: argv(&["amp", "threads", "continue", &session_id]),
            cwd_needed: false,
        },
        session_id,
    }))
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    let name = parts.last().copied().unwrap_or_default();
    role(parts.len() == 1 && name.starts_with("T-") && name.ends_with(".json"), false)
}

/// `file:///Users/me/app` (or `file:///C:/x`) to a local path; `%XX` decoded.
fn file_uri_path(uri: &str) -> Option<String> {
    let rest = uri.strip_prefix("file://")?;
    let bytes = rest.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while let Some(&byte) = bytes.get(at) {
        let hex = bytes.get(at + 1..at + 3).and_then(|pair| std::str::from_utf8(pair).ok());
        match (byte, hex.and_then(|hex| u8::from_str_radix(hex, 16).ok())) {
            (b'%', Some(decoded)) => {
                out.push(decoded);
                at += 3;
            }
            _ => {
                out.push(byte);
                at += 1;
            }
        }
    }
    let mut path = String::from_utf8(out).ok()?;
    // `/C:/x` is a Windows drive path.
    if path.as_bytes().get(2) == Some(&b':') && path.starts_with('/') {
        path.remove(0);
    }
    (!path.is_empty()).then_some(path)
}
