//! Augment Auggie CLI: `<root>/<conversationId>.json`, one object rewritten
//! whole (`{sessionId, created, modified, chatHistory[], title?,
//! customTitle?, parentConversationId?}`). `<id>-backup<N>.json` copies and
//! child conversations are skipped.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, file_stem, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::stamp::FileStamp;
use crate::text::{prompt_text, title_field};
use crate::time::parse_rfc3339_ms;

/// Exchanges searched for the workspace folder and the first prompt.
const PROBE: usize = 16;

fn is_session_name(name: &str) -> bool {
    name.ends_with(".json") && !name.contains("-backup")
}

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    Ok(fs::read_dir(root)?
        .flatten()
        .filter(|child| child.file_type().is_ok_and(|kind| kind.is_file()))
        .filter(|child| child.file_name().to_str().is_some_and(is_session_name))
        .map(|child| child.path())
        .collect())
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    role(matches!(parts, [name] if is_session_name(name)), false)
}

pub(super) fn read(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let Some(file) = read_whole_json(path)? else { return Ok(None) };
    if !file.is_object() {
        return Ok(None);
    }
    if file.get("parentConversationId").is_some_and(|parent| match parent {
        Value::Null => false,
        Value::String(text) => !text.is_empty(),
        _ => true,
    }) {
        return Ok(None);
    }
    let Some(session_id) = file
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .or_else(|| file_stem(path))
    else {
        return Ok(None);
    };
    let history = file.get("chatHistory").and_then(Value::as_array);
    let exchanges: Vec<&Value> =
        history.into_iter().flatten().take(PROBE).filter_map(|item| item.get("exchange")).collect();
    let first_prompt = exchanges.iter().copied().find_map(prompt_of);
    let cwd = exchanges.iter().copied().find_map(workspace_root);
    let (title, title_source) = if let Some(title) = title_field(file.get("customTitle")) {
        (Some(title), Some(TitleSource::Custom))
    } else if let Some(title) = title_field(file.get("title")) {
        (Some(title), Some(TitleSource::Ai))
    } else if let Some(prompt) = first_prompt {
        (Some(prompt), Some(TitleSource::Prompt))
    } else {
        (None, None)
    };
    let time = |key: &str| file.get(key).and_then(Value::as_str).and_then(parse_rfc3339_ms);
    Ok(Some(ChatEntry {
        harness: AdapterKind::Auggie,
        title,
        title_source,
        cwd,
        created_ms: time("created"),
        updated_ms: time("modified").unwrap_or(stamp.mtime_ms),
        message_count: history.map(|history| history.len() as u64),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::ReadOnly,
        session_id,
    }))
}

/// `request_message`, else the first text node (`type` 0).
fn prompt_of(exchange: &Value) -> Option<String> {
    if let Some(text) = exchange.get("request_message").and_then(prompt_text) {
        return Some(text);
    }
    nodes(exchange)
        .filter(|node| node.get("type").and_then(Value::as_i64) == Some(0))
        .find_map(|node| node.pointer("/text_node/content").and_then(prompt_text))
}

/// The IDE state node (`type` 4) names the workspace folder.
fn workspace_root(exchange: &Value) -> Option<String> {
    nodes(exchange).filter(|node| node.get("type").and_then(Value::as_i64) == Some(4)).find_map(
        |node| {
            let folder = node.pointer("/ide_state_node/workspace_folders/0")?;
            ["repository_root", "folder_root"]
                .iter()
                .find_map(|key| folder.get(*key).and_then(Value::as_str))
                .filter(|root| !root.is_empty())
                .map(str::to_owned)
        },
    )
}

fn nodes(exchange: &Value) -> impl Iterator<Item = &Value> {
    exchange.get("request_nodes").and_then(Value::as_array).into_iter().flatten()
}
