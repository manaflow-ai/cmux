//! Codex CLI and the Codex desktop app (same `CODEX_HOME`). Primary source:
//! the `threads` table of the newest `state_<n>.sqlite`. Without it, the
//! rollout files under `sessions/` and `archived_sessions/`. Names from
//! `session_index.jsonl` (last line per id wins).

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

use serde_json::Value;

use super::{PathRole, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{contains, fold_lines, read_first_record, read_whole_json};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};
use crate::text::{prompt_text, title_line};
use crate::time::parse_rfc3339_ms;

mod threads;
pub use threads::forget;
use threads::query_threads;

const ARCHIVED: &str = "archived_sessions";

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    collect_rollouts(&root.join("sessions"), 4, &mut out);
    collect_rollouts(&root.join(ARCHIVED), 1, &mut out);
    Ok(out)
}

fn collect_rollouts(dir: &Path, depth: u32, out: &mut Vec<PathBuf>) {
    let Ok(children) = fs::read_dir(dir) else { return };
    for child in children.flatten() {
        let Ok(kind) = child.file_type() else { continue };
        if kind.is_dir() && depth > 1 {
            collect_rollouts(&child.path(), depth - 1, out);
        } else if kind.is_file() && child.file_name().to_str().is_some_and(is_rollout) {
            out.push(child.path());
        }
    }
}

fn is_rollout(name: &str) -> bool {
    name.starts_with("rollout-")
        && (name.ends_with(".jsonl") || name.ends_with(".jsonl.zst") || name.ends_with(".json"))
}

/// The prefix the Codex IDE extension puts before the typed request.
const REQUEST_MARKER: &str = "## My request for Codex:";

/// The typed request of a user message, without the IDE preamble.
fn request_text(content: &Value) -> Option<String> {
    let joined;
    let text = match content {
        Value::String(text) => text.as_str(),
        Value::Array(parts) => {
            let texts: Vec<&str> = parts
                .iter()
                .filter(|part| {
                    matches!(part.get("type").and_then(Value::as_str), Some("input_text" | "text"))
                })
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect();
            joined = texts.join("\n");
            joined.as_str()
        }
        _ => return None,
    };
    let request = text.find(REQUEST_MARKER).map_or(text, |at| &text[at + REQUEST_MARKER.len()..]);
    prompt_text(&Value::String(request.to_owned()))
}

pub(super) fn read(
    path: &Path,
    stamp: FileStamp,
    prev: Option<&FileState>,
) -> io::Result<FileRead> {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
    let (file_id, file_created) = parse_rollout_name(name).unzip();
    let archived = path.components().any(|part| part == Component::Normal(ARCHIVED.as_ref()));
    let mut entry = ChatEntry {
        harness: AdapterKind::Codex,
        session_id: file_id.unwrap_or_default(),
        title: None,
        title_source: None,
        cwd: None,
        created_ms: file_created.flatten(),
        updated_ms: stamp.mtime_ms,
        message_count: None,
        source_path: path.to_path_buf(),
        originator: None,
        archived,
        resume: Resume::Adopt,
    };
    let whole = FileState { stamp, offset: stamp.size, ..FileState::default() };
    if name.ends_with(".zst") {
        // Compressed rollouts (older than 7 days): no zstd reader, so no count.
        return Ok(FileRead {
            entry: (!entry.session_id.is_empty()).then_some(entry),
            state: whole,
        });
    }
    if name.ends_with(".json") {
        // The TypeScript CLI (2025-04 to 2025-08): one JSON object rewritten
        // each turn, `{"session":{id,timestamp,instructions},"items":[...]}`.
        let entry = read_typescript_rollout(path, entry)?;
        return Ok(FileRead { entry, state: whole });
    }
    let first = read_first_record(path)?;
    // Rollouts before rust-v0.32.0 have no RolloutLine wrapper: line 1 is
    // `{"id","timestamp","instructions"}` and then bare response items.
    let wrapped = first.as_ref().is_some_and(|record| record.get("payload").is_some());
    if let Some(meta) = first.as_ref().filter(|record| record_type(record) == Some("session_meta"))
    {
        let payload = &meta["payload"];
        if is_subagent(payload) {
            return Ok(FileRead { entry: None, state: whole });
        }
        if let Some(id) = payload.get("id").and_then(Value::as_str) {
            id.clone_into(&mut entry.session_id);
        }
        entry.cwd = string(payload.get("cwd"));
        entry.originator = string(payload.get("originator"));
        let started = payload.get("timestamp").or_else(|| meta.get("timestamp"));
        entry.created_ms =
            started.and_then(Value::as_str).and_then(parse_rfc3339_ms).or(entry.created_ms);
    } else if let Some(meta) = first.as_ref().filter(|_| !wrapped)
        && let Some(id) = meta.get("id").and_then(Value::as_str).filter(|id| !id.is_empty())
    {
        id.clone_into(&mut entry.session_id);
    }
    let (from, mut tally) = FileState::resume_point(prev, &stamp, path);
    let offset = fold_lines(path, from, |line| {
        if wrapped {
            if contains(line, br#""type":"user_message""#) {
                tally.messages += 1;
                if tally.first_prompt.is_none() {
                    let record: Option<Value> = serde_json::from_slice(line).ok();
                    tally.first_prompt = record
                        .as_ref()
                        .and_then(|record| record.pointer("/payload/message"))
                        .and_then(request_text);
                }
            } else if contains(line, br#""user.text""#)
                && let Some(prompt) = typed_prompt(line)
            {
                tally.messages += 1;
                tally.first_prompt.get_or_insert(prompt);
            }
        } else if contains(line, br#""role":"user""#) {
            let Ok(item) = serde_json::from_slice::<Value>(line) else { return };
            if item.get("type").and_then(Value::as_str) != Some("message") {
                return;
            }
            let content = item.get("content").unwrap_or(&Value::Null);
            if tally.cwd.is_none() {
                tally.cwd = environment_cwd(content);
            }
            if let Some(prompt) = request_text(content) {
                tally.messages += 1;
                tally.first_prompt.get_or_insert(prompt);
            }
        }
    })?;
    entry.message_count = Some(tally.messages);
    entry.title_source = tally.first_prompt.as_ref().map(|_| TitleSource::Prompt);
    entry.title.clone_from(&tally.first_prompt);
    if entry.cwd.is_none() {
        entry.cwd.clone_from(&tally.cwd);
    }
    let state = FileState::folded(path, stamp, offset, tally);
    Ok(FileRead { entry: (!entry.session_id.is_empty()).then_some(entry), state })
}

/// A prompt of current Codex, which writes no `user_message` events: a `user` message item
/// whose content items are the person's own (`user.text`, maybe `user.image`), not injected
/// context.
/// Older rollouts carry no item kinds and are counted from their events, so none counts twice.
fn typed_prompt(line: &[u8]) -> Option<String> {
    let record: Value = serde_json::from_slice(line).ok()?;
    let payload =
        record.get("payload").filter(|_| record_type(&record) == Some("response_item"))?;
    if payload.get("type").and_then(Value::as_str) != Some("message")
        || payload.get("role").and_then(Value::as_str) != Some("user")
    {
        return None;
    }
    let kinds = payload
        .pointer("/internal_chat_message_metadata_passthrough/content_item_kinds")?
        .as_array()?;
    // The person's own text, maybe with images, never injected context.
    let typed = kinds.iter().any(|kind| kind.as_str() == Some("user.text"))
        && kinds.iter().all(|kind| kind.as_str().is_some_and(|kind| kind.starts_with("user.")));
    if !typed {
        return None;
    }
    request_text(payload.get("content")?)
}

/// `source: {"subagent": ...}` or `thread_source: "subagent"`: a review,
/// compaction or spawned thread, not a chat.
fn is_subagent(payload: &Value) -> bool {
    payload.pointer("/source/subagent").is_some()
        || payload.get("thread_source").and_then(Value::as_str) == Some("subagent")
}

/// `<cwd>/path</cwd>` inside an `<environment_context>` user message.
fn environment_cwd(content: &Value) -> Option<String> {
    let texts: Vec<&str> = match content {
        Value::String(text) => vec![text.as_str()],
        Value::Array(parts) => {
            parts.iter().filter_map(|part| part.get("text").and_then(Value::as_str)).collect()
        }
        _ => return None,
    };
    texts.into_iter().find_map(|text| {
        let body = text.trim_start().strip_prefix("<environment_context>")?;
        let start = body.find("<cwd>")? + "<cwd>".len();
        let len = body[start..].find("</cwd>")?;
        let cwd = body[start..start + len].trim();
        (!cwd.is_empty()).then(|| cwd.to_owned())
    })
}

fn read_typescript_rollout(path: &Path, mut entry: ChatEntry) -> io::Result<Option<ChatEntry>> {
    let Some(file) = read_whole_json(path)? else { return Ok(None) };
    let session = file.get("session").unwrap_or(&Value::Null);
    if let Some(id) = session.get("id").and_then(Value::as_str).filter(|id| !id.is_empty()) {
        id.clone_into(&mut entry.session_id);
    }
    if entry.session_id.is_empty() {
        return Ok(None);
    }
    // `session.timestamp` is the last save, not the start.
    if let Some(saved) = session.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms)
    {
        entry.updated_ms = saved;
    }
    let users = file.get("items").and_then(Value::as_array).into_iter().flatten().filter(|item| {
        item.get("type").and_then(Value::as_str) == Some("message")
            && item.get("role").and_then(Value::as_str) == Some("user")
    });
    let prompts: Vec<String> =
        users.filter_map(|item| item.get("content").and_then(request_text)).collect();
    entry.message_count = Some(prompts.len() as u64);
    entry.title = prompts.into_iter().next();
    entry.title_source = entry.title.as_ref().map(|_| TitleSource::Prompt);
    // The TypeScript CLI had no resume; show it read-only.
    entry.resume = Resume::ReadOnly;
    Ok(Some(entry))
}

/// `rollout-2026-10-01T10-00-00-<thread id>[_<rollout id>].jsonl[.zst]` or
/// the first Rust and TypeScript names `rollout-2025-05-07-<uuid>.json[l]`:
/// the thread id and the start time (read as UTC).
fn parse_rollout_name(name: &str) -> Option<(String, Option<i64>)> {
    let stem = name.strip_prefix("rollout-")?;
    let stem = stem
        .strip_suffix(".jsonl.zst")
        .or_else(|| stem.strip_suffix(".jsonl"))
        .or_else(|| stem.strip_suffix(".json"))?;
    if stem.as_bytes().get(10) == Some(&b'-') {
        let id = stem.get(11..).filter(|id| !id.is_empty())?;
        return Some((id.to_owned(), parse_rfc3339_ms(&format!("{}T00:00:00Z", stem.get(..10)?))));
    }
    let (stamp, rest) = (stem.get(..19)?, stem.get(20..)?);
    let id = rest.split('_').next().filter(|id| !id.is_empty())?;
    let iso = format!("{}:{}:{}", stamp.get(..13)?, stamp.get(14..16)?, stamp.get(17..19)?);
    Some((id.to_owned(), parse_rfc3339_ms(&iso)))
}

pub(super) fn read_store(root: &Path) -> io::Result<Option<Vec<ChatEntry>>> {
    let Some(db) = newest_state_db(root)? else { return Ok(None) };
    // A locked, missing or unknown DB falls back to the rollout files.
    let Ok(mut entries) = query_threads(&db) else { return Ok(None) };
    apply_session_index(root, &mut entries);
    Ok(Some(entries))
}

fn newest_state_db(root: &Path) -> io::Result<Option<PathBuf>> {
    let mut best: Option<(u64, PathBuf)> = None;
    for child in fs::read_dir(root)?.flatten() {
        let name = child.file_name();
        let Some(version) = name
            .to_str()
            .and_then(|name| name.strip_prefix("state_")?.strip_suffix(".sqlite"))
            .and_then(|digits| digits.parse::<u64>().ok())
        else {
            continue;
        };
        if best.as_ref().is_none_or(|(current, _)| version > *current) {
            best = Some((version, child.path()));
        }
    }
    Ok(best.map(|(_, path)| path))
}

/// Names from `session_index.jsonl` replace every title except a DB name.
pub(super) fn apply_session_index(root: &Path, entries: &mut [ChatEntry]) {
    let mut names: HashMap<String, Option<String>> = HashMap::new();
    let folded = fold_lines(&root.join("session_index.jsonl"), 0, |line| {
        if let Ok(record) = serde_json::from_slice::<Value>(line)
            && let Some(id) = record.get("id").and_then(Value::as_str)
        {
            let name = record.get("thread_name").and_then(Value::as_str).and_then(title_line);
            names.insert(id.to_owned(), name);
        }
    });
    if folded.is_err() {
        return;
    }
    for entry in entries {
        if entry.title_source == Some(TitleSource::Custom) {
            continue;
        }
        if let Some(Some(name)) = names.get(&entry.session_id) {
            entry.title = Some(name.clone());
            entry.title_source = Some(TitleSource::Custom);
        }
    }
}

fn record_type(record: &Value) -> Option<&str> {
    record.get("type").and_then(Value::as_str)
}

fn string(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).filter(|text| !text.is_empty()).map(str::to_owned)
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    let name = parts.last().copied().unwrap_or_default();
    let session = matches!(parts.first(), Some(&("sessions" | ARCHIVED))) && is_rollout(name);
    let store = parts.len() == 1
        && ((name.starts_with("state_") && name.contains(".sqlite"))
            || name == "session_index.jsonl");
    role(session, store)
}
