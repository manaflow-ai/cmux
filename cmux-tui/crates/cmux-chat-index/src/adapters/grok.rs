//! xAI Grok Build: `<GROK_HOME|~/.grok>/sessions/<encoded cwd>/<uuid>/`.
//! Only `summary.json` (the session list entry) is read; `chat_history.jsonl`
//! and the other transcript files stay unread. Subagents live deeper
//! (`<uuid>/subagents/<id>/summary.json`) and are not listed.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::stamp::FileStamp;
use crate::text::title_field;
use crate::time::parse_rfc3339_ms;

const SUMMARY: &str = "summary.json";

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for group in fs::read_dir(root)?.flatten() {
        if !group.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let Ok(sessions) = fs::read_dir(group.path()) else { continue };
        for session in sessions.flatten() {
            let summary = session.path().join(SUMMARY);
            if session.file_type().is_ok_and(|kind| kind.is_dir()) && summary.is_file() {
                out.push(summary);
            }
        }
    }
    Ok(out)
}

pub(super) fn read(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let Some(summary) = read_whole_json(path)? else { return Ok(None) };
    if !summary.is_object() || summary.get("hidden") == Some(&Value::Bool(true)) {
        return Ok(None);
    }
    // A parent without a fork time is a subagent run; a fork is a chat.
    let has_parent = text(&summary, "parent_session_id").is_some();
    if has_parent && summary.get("forked_at").is_none_or(Value::is_null) {
        return Ok(None);
    }
    let session_dir = path.parent();
    let dir_id = session_dir.and_then(Path::file_name).and_then(|name| name.to_str());
    let Some(session_id) = summary
        .pointer("/info/id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .or(dir_id)
        .map(str::to_owned)
    else {
        return Ok(None);
    };
    let cwd = summary
        .pointer("/info/cwd")
        .and_then(Value::as_str)
        .filter(|cwd| !cwd.is_empty())
        .map(str::to_owned)
        .or_else(|| session_dir.and_then(Path::parent).and_then(cwd_file));
    let manual = summary.get("title_is_manual") == Some(&Value::Bool(true));
    let (title, title_source) = match title_field(summary.get("generated_title")) {
        Some(title) => {
            (Some(title), Some(if manual { TitleSource::Custom } else { TitleSource::Ai }))
        }
        None => match title_field(summary.get("session_summary")) {
            Some(title) => (Some(title), Some(TitleSource::Ai)),
            None => (None, None),
        },
    };
    let time = |key: &str| text(&summary, key).and_then(parse_rfc3339_ms);
    let updated = match (time("updated_at"), time("last_active_at")) {
        (Some(updated), Some(active)) => Some(updated.max(active)),
        (updated, active) => updated.or(active),
    };
    let count = |key: &str| summary.get(key).and_then(Value::as_u64);
    Ok(Some(ChatEntry {
        harness: AdapterKind::Grok,
        session_id,
        title,
        title_source,
        cwd,
        created_ms: time("created_at"),
        updated_ms: updated.unwrap_or(stamp.mtime_ms),
        message_count: count("num_chat_messages").filter(|n| *n > 0).or(count("num_messages")),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::ReadOnly,
    }))
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str).filter(|text| !text.is_empty())
}

/// `<encoded cwd>/.cwd`: the real folder when the encoded name was cut.
fn cwd_file(group: &Path) -> Option<String> {
    let file = group.join(".cwd");
    if fs::metadata(&file).ok()?.len() > 4096 {
        return None;
    }
    let text = fs::read_to_string(file).ok()?;
    let cwd = text.trim();
    (!cwd.is_empty()).then(|| cwd.to_owned())
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    role(matches!(parts, [_, _, name] if *name == SUMMARY), false)
}
