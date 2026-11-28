//! OpenHands CLI (V1, agent SDK): `<root>/<conversation hex>/base_state.json`
//! plus one file per event, `events/event-<index>-<event id>.json`. The
//! listing follows the CLI's own store (`conversations/store/local.py`):
//! created is the first event's time, the title is the first user
//! `MessageEvent`'s text. No title is stored.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::stamp::FileStamp;
use crate::text::prompt_text;
use crate::time::parse_rfc3339_ms;

const BASE_STATE: &str = "base_state.json";
/// Event files read to find the first user message.
const EVENT_PROBE: usize = 64;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for conversation in fs::read_dir(root)?.flatten() {
        let state = conversation.path().join(BASE_STATE);
        if conversation.file_type().is_ok_and(|kind| kind.is_dir()) && state.is_file() {
            out.push(state);
        }
    }
    Ok(out)
}

pub(super) fn read(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let Some(dir) = path.parent() else { return Ok(None) };
    let Some(session_id) = dir.file_name().and_then(|name| name.to_str()).map(str::to_owned) else {
        return Ok(None);
    };
    let events_dir = dir.join("events");
    let events = event_files(&events_dir);
    // The CLI lists only conversations with at least one event.
    if events.is_empty() {
        return Ok(None);
    }
    let state = read_whole_json(path)?.unwrap_or(Value::Null);
    let cwd = state
        .pointer("/workspace/working_dir")
        .and_then(Value::as_str)
        .filter(|cwd| !cwd.is_empty())
        .map(str::to_owned);
    let mut created_ms = None;
    let mut title = None;
    for (at, file) in events.iter().take(EVENT_PROBE).enumerate() {
        let Ok(Some(event)) = read_whole_json(file) else { continue };
        if at == 0 {
            created_ms = event.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms);
        }
        if is_user_message(&event) {
            title = event.pointer("/llm_message/content").and_then(prompt_text);
            if title.is_some() {
                break;
            }
        }
    }
    let events_mtime =
        fs::metadata(&events_dir).map(|meta| FileStamp::of(&meta).mtime_ms).unwrap_or(0);
    Ok(Some(ChatEntry {
        harness: AdapterKind::OpenHands,
        title_source: title.as_ref().map(|_| TitleSource::Prompt),
        title,
        cwd,
        created_ms,
        updated_ms: stamp.mtime_ms.max(events_mtime),
        message_count: None,
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::ReadOnly,
        session_id,
    }))
}

fn is_user_message(event: &Value) -> bool {
    let kind = event.get("kind").and_then(Value::as_str);
    matches!(kind, None | Some("MessageEvent"))
        && event.get("source").and_then(Value::as_str) == Some("user")
        && event.get("llm_message").is_some_and(Value::is_object)
}

/// `event-*.json` files, sorted by name (the index is zero-padded).
fn event_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(children) = fs::read_dir(dir) else { return Vec::new() };
    let mut files: Vec<PathBuf> = children
        .flatten()
        .filter(|child| child.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|child| child.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("event-") && name.ends_with(".json"))
        })
        .collect();
    files.sort();
    files
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    // Event files are written on every step; `base_state.json` names the
    // conversation and its writes refresh it.
    role(matches!(parts, [_, name] if *name == BASE_STATE), false)
}
