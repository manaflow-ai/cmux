//! GitHub Copilot CLI, every layout under the Copilot home (`~/.copilot`):
//!
//! - v1 (to 0.0.341): `history-session-state/session_<id>_<startMs>.json`,
//!   one JSON object `{sessionId, startTime, chatMessages[], ...}`.
//! - v2 (0.0.342): flat `session-state/<id>.jsonl` event logs.
//! - v3 (0.0.378+): `session-state/<id>/events.jsonl` plus `workspace.yaml`
//!   (`name`, `summary`, `cwd`, `created_at`, `updated_at`, `user_named`).
//!
//! Event lines are `{id, timestamp, parentId, type, data}`; `session.start`
//! carries the id, start time and `context.cwd`.

use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, argv, file_stem, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{contains, fold_lines, read_first_record, read_whole_json};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};
use crate::text::{prompt_text, title_line};
use crate::time::parse_rfc3339_ms;

const HISTORY: &str = "history-session-state";
const STATE: &str = "session-state";
const EVENTS: &str = "events.jsonl";
const WORKSPACE: &str = "workspace.yaml";
/// Upper bound for `workspace.yaml`.
const WORKSPACE_MAX: u64 = 64 * 1024;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    if let Ok(children) = fs::read_dir(root.join(HISTORY)) {
        for child in children.flatten() {
            let name = child.file_name();
            if child.file_type().is_ok_and(|kind| kind.is_file())
                && name.to_str().is_some_and(is_history_name)
            {
                out.push(child.path());
            }
        }
    }
    if let Ok(children) = fs::read_dir(root.join(STATE)) {
        for child in children.flatten() {
            let Ok(kind) = child.file_type() else { continue };
            let name = child.file_name();
            if kind.is_file() && name.to_str().is_some_and(|name| name.ends_with(".jsonl")) {
                out.push(child.path());
            } else if kind.is_dir() {
                let events = child.path().join(EVENTS);
                if events.is_file() {
                    out.push(events);
                }
            }
        }
    }
    Ok(out)
}

fn is_history_name(name: &str) -> bool {
    name.starts_with("session_") && name.ends_with(".json")
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    match parts {
        [HISTORY, name] => role(is_history_name(name), false),
        [STATE, name] => role(name.ends_with(".jsonl"), false),
        [STATE, _, EVENTS] => PathRole::Session,
        [STATE, _, WORKSPACE] => PathRole::Store,
        _ => PathRole::Ignore,
    }
}

pub(super) fn read(
    path: &Path,
    stamp: FileStamp,
    prev: Option<&FileState>,
) -> io::Result<FileRead> {
    let whole = FileState { stamp, offset: stamp.size, ..FileState::default() };
    if path.extension().is_some_and(|ext| ext == "json") {
        return Ok(FileRead { entry: read_history(path, stamp)?, state: whole });
    }
    let v3 = path.file_name().is_some_and(|name| name == EVENTS);
    let file_id = if v3 {
        path.parent().and_then(Path::file_name).and_then(|name| name.to_str()).map(str::to_owned)
    } else {
        file_stem(path)
    };
    let start = read_first_record(path)?
        .filter(|record| record.get("type").and_then(Value::as_str) == Some("session.start"));
    let data = start.as_ref().and_then(|record| record.get("data"));
    let text = |pointer: &str| {
        data.and_then(|data| data.pointer(pointer))
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
            .map(str::to_owned)
    };
    let session_id = text("/sessionId").or(file_id);
    let created_ms = text("/startTime")
        .as_deref()
        .and_then(parse_rfc3339_ms)
        .or_else(|| start.as_ref().and_then(timestamp_of));
    let workspace = if v3 {
        path.parent().map(|dir| Workspace::read(&dir.join(WORKSPACE))).unwrap_or_default()
    } else {
        Workspace::default()
    };

    let (from, mut tally) = FileState::resume_point(prev, &stamp, path);
    let offset = fold_lines(path, from, |line| {
        if contains(line, br#""type":"user.message""#) {
            tally.messages += 1;
            if tally.first_prompt.is_none()
                && let Ok(record) = serde_json::from_slice::<Value>(line)
            {
                tally.first_prompt = record.pointer("/data/content").and_then(prompt_text);
            }
        } else if contains(line, br#""type":"assistant.message""#) {
            tally.messages += 1;
        } else if contains(line, br#""type":"session.title_changed""#)
            && let Ok(record) = serde_json::from_slice::<Value>(line)
        {
            let title = record.pointer("/data/title").and_then(Value::as_str).and_then(title_line);
            if title.is_some() {
                tally.name = title;
            }
        }
    })?;

    let (title, title_source) = if let Some(name) = &tally.name {
        (Some(name.clone()), Some(TitleSource::Ai))
    } else if let Some(name) = &workspace.name {
        let source = if workspace.user_named { TitleSource::Custom } else { TitleSource::Ai };
        (Some(name.clone()), Some(source))
    } else if let Some(summary) = &workspace.summary {
        (Some(summary.clone()), Some(TitleSource::Ai))
    } else if let Some(prompt) = &tally.first_prompt {
        (Some(prompt.clone()), Some(TitleSource::Prompt))
    } else {
        (None, None)
    };
    let entry = session_id.map(|session_id| ChatEntry {
        harness: AdapterKind::CopilotCli,
        title,
        title_source,
        cwd: text("/context/cwd").or_else(|| workspace.cwd.clone()),
        created_ms: created_ms.or(workspace.created_ms),
        updated_ms: stamp.mtime_ms.max(workspace.updated_ms.unwrap_or(0)),
        message_count: Some(tally.messages),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Argv {
            argv: argv(&["copilot", "--resume", &session_id]),
            cwd_needed: true,
        },
        session_id,
    });
    Ok(FileRead { entry, state: FileState::folded(path, stamp, offset, tally) })
}

fn timestamp_of(record: &Value) -> Option<i64> {
    record.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms)
}

/// A time that may be an ISO string or epoch milliseconds.
fn time_ms(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::String(text) => parse_rfc3339_ms(text),
        Value::Number(number) => number.as_i64(),
        _ => None,
    }
}

/// v1: `session_<id>_<startMs>.json`, one object rewritten whole.
fn read_history(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let Some(file) = read_whole_json(path)? else { return Ok(None) };
    let name_id = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .and_then(|stem| stem.strip_prefix("session_"))
        .and_then(|rest| rest.rsplit_once('_'))
        .map(|(id, _)| id.to_owned())
        .filter(|id| !id.is_empty());
    let Some(session_id) = file
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .or(name_id)
    else {
        return Ok(None);
    };
    let messages = file.get("chatMessages").and_then(Value::as_array);
    let turns = messages.into_iter().flatten().filter(|message| {
        matches!(message.get("role").and_then(Value::as_str), Some("user" | "assistant"))
    });
    let mut count = 0u64;
    let mut first_prompt = None;
    for message in turns {
        count += 1;
        if first_prompt.is_none() && message.get("role").and_then(Value::as_str) == Some("user") {
            first_prompt = message.get("content").and_then(prompt_text);
        }
    }
    Ok(Some(ChatEntry {
        harness: AdapterKind::CopilotCli,
        title_source: first_prompt.as_ref().map(|_| TitleSource::Prompt),
        title: first_prompt,
        cwd: None,
        created_ms: time_ms(file.get("startTime")),
        updated_ms: stamp.mtime_ms,
        message_count: Some(count),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Argv {
            argv: argv(&["copilot", "--resume", &session_id]),
            cwd_needed: true,
        },
        session_id,
    }))
}

/// The top-level scalars of `workspace.yaml` the index needs.
#[derive(Default)]
struct Workspace {
    name: Option<String>,
    summary: Option<String>,
    cwd: Option<String>,
    created_ms: Option<i64>,
    updated_ms: Option<i64>,
    user_named: bool,
}

impl Workspace {
    fn read(path: &Path) -> Self {
        let mut out = Self::default();
        let Ok(file) = File::open(path) else { return out };
        let mut bytes = Vec::new();
        if file.take(WORKSPACE_MAX).read_to_end(&mut bytes).is_err() {
            return out;
        }
        let text = String::from_utf8_lossy(&bytes);
        for line in text.lines() {
            // Only top-level keys: nested maps and lists are indented.
            if line.starts_with([' ', '\t', '-', '#']) {
                continue;
            }
            let Some((key, value)) = line.split_once(':') else { continue };
            let Some(value) = yaml_scalar(value) else { continue };
            match key.trim() {
                "name" => out.name = title_line(&value),
                "summary" => out.summary = title_line(&value),
                "cwd" => out.cwd = Some(value).filter(|cwd| !cwd.is_empty()),
                "created_at" => out.created_ms = parse_rfc3339_ms(&value),
                "updated_at" => out.updated_ms = parse_rfc3339_ms(&value),
                "user_named" => out.user_named = value == "true",
                _ => {}
            }
        }
        out
    }
}

/// A plain, single-quoted or double-quoted YAML scalar on one line. None
/// for an empty value, a block indicator or a flow collection.
fn yaml_scalar(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() || raw.starts_with(['|', '>', '[', '{', '&', '*', '!']) {
        return None;
    }
    if let Some(body) = raw.strip_prefix('"') {
        let mut out = String::new();
        let mut chars = body.chars();
        while let Some(ch) = chars.next() {
            match ch {
                '"' => return Some(out),
                '\\' => match chars.next()? {
                    'n' => out.push('\n'),
                    't' => out.push('\t'),
                    other => out.push(other),
                },
                other => out.push(other),
            }
        }
        return None;
    }
    if let Some(body) = raw.strip_prefix('\'') {
        let end = body.rfind('\'')?;
        return Some(body.get(..end)?.replace("''", "'"));
    }
    // A plain scalar ends before ` #` (a comment).
    let plain = raw.split(" #").next().unwrap_or(raw).trim_end();
    Some(plain.to_owned()).filter(|value| value != "null" && value != "~")
}
