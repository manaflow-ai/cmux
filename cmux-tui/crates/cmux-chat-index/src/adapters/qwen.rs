//! Qwen Code (`<QWEN_HOME|~/.qwen>`, session data under the runtime base).
//!
//! v2 (v0.5.0+): `projects/<sanitized cwd>/chats/<uuid>.jsonl`, archived
//! sessions in `chats/archive/`. Each line is a `ChatRecord` `{uuid,
//! parentUuid, sessionId, timestamp, type: user|assistant|tool_result|system,
//! subtype?, cwd, message?: {role, parts}, systemPayload?}`; a `system` /
//! `custom_title` record names the chat (re-appended, so the tail has it).
//!
//! v1 (v0.1-v0.3, inherited from Gemini CLI): `tmp/<sha256 cwd>/chats/
//! session-*.json`, read by the Gemini adapter. Current Qwen ignores these
//! files and never migrates them.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, argv, file_stem, role, whole};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{contains, fold_lines, read_first_record, read_head_tail};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};
use crate::text::{prompt_text, title_field};
use crate::time::parse_rfc3339_ms;

const ARCHIVE: &str = "archive";

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    if let Ok(projects) = fs::read_dir(root.join("projects")) {
        for project in projects.flatten() {
            let chats = project.path().join("chats");
            push_files(&chats, is_v2_name, &mut out);
            push_files(&chats.join(ARCHIVE), is_v2_name, &mut out);
        }
    }
    if let Ok(projects) = fs::read_dir(root.join("tmp")) {
        for project in projects.flatten() {
            push_files(&project.path().join("chats"), is_v1_name, &mut out);
        }
    }
    Ok(out)
}

fn push_files(dir: &Path, keep: fn(&str) -> bool, out: &mut Vec<PathBuf>) {
    let Ok(children) = fs::read_dir(dir) else { return };
    for child in children.flatten() {
        if child.file_type().is_ok_and(|kind| kind.is_file())
            && child.file_name().to_str().is_some_and(keep)
        {
            out.push(child.path());
        }
    }
}

/// `<uuid>.jsonl`: 32-36 hex digits and dashes.
fn is_v2_name(name: &str) -> bool {
    name.strip_suffix(".jsonl").is_some_and(|stem| {
        (32..=36).contains(&stem.len()) && stem.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
    })
}

fn is_v1_name(name: &str) -> bool {
    name.starts_with("session-") && name.ends_with(".json")
}

pub(super) fn read(
    path: &Path,
    stamp: FileStamp,
    prev: Option<&FileState>,
) -> io::Result<FileRead> {
    if path.extension().is_some_and(|ext| ext == "json") {
        return whole(super::gemini::read_as(AdapterKind::QwenCode, path, stamp), stamp);
    }
    let first = read_first_record(path)?;
    let (from, mut tally) = FileState::resume_point(prev, &stamp, path);
    let offset = fold_lines(path, from, |line| {
        let user = contains(line, br#""type":"user""#);
        if !user && !contains(line, br#""type":"assistant""#) {
            return;
        }
        let Ok(record) = serde_json::from_slice::<Value>(line) else { return };
        if record.get("subtype").is_some_and(|subtype| !subtype.is_null()) {
            return;
        }
        match record.get("type").and_then(Value::as_str) {
            Some("user") => {
                tally.messages += 1;
                if tally.first_prompt.is_none() {
                    tally.first_prompt = typed_prompt(&record);
                }
            }
            Some("assistant") => tally.messages += 1,
            _ => {}
        }
    })?;
    let first = first.as_ref();
    let field = |key: &str| first.and_then(|record| record.get(key)).and_then(Value::as_str);
    let session_id = field("sessionId").filter(|id| !id.is_empty()).map(str::to_owned);
    let Some(session_id) = session_id.or_else(|| file_stem(path)) else {
        return Ok(FileRead { entry: None, state: FileState::folded(path, stamp, offset, tally) });
    };
    let (title, title_source) = match custom_title(path) {
        Some(named) => (Some(named.0), Some(named.1)),
        None => {
            let source = tally.first_prompt.as_ref().map(|_| TitleSource::Prompt);
            (tally.first_prompt.clone(), source)
        }
    };
    let archived = path.parent().and_then(Path::file_name).is_some_and(|name| name == ARCHIVE);
    let entry = ChatEntry {
        harness: AdapterKind::QwenCode,
        title,
        title_source,
        cwd: field("cwd").filter(|cwd| !cwd.is_empty()).map(str::to_owned),
        created_ms: field("timestamp").and_then(parse_rfc3339_ms),
        updated_ms: stamp.mtime_ms,
        message_count: Some(tally.messages),
        source_path: path.to_path_buf(),
        originator: None,
        archived,
        resume: Resume::Argv { argv: argv(&["qwen", "--resume", &session_id]), cwd_needed: true },
        session_id,
    };
    Ok(FileRead { entry: Some(entry), state: FileState::folded(path, stamp, offset, tally) })
}

/// `systemPayload.displayText` (what the user typed), else the text parts.
fn typed_prompt(record: &Value) -> Option<String> {
    if let Some(shown) = record.pointer("/systemPayload/displayText").and_then(prompt_text) {
        return Some(shown);
    }
    let parts = record.pointer("/message/parts")?.as_array()?;
    let texts: Vec<&str> =
        parts.iter().filter_map(|part| part.get("text").and_then(Value::as_str)).collect();
    prompt_text(&Value::String(texts.join("\n")))
}

/// The last `custom_title` record in the head and tail windows. An
/// `auto` title is generated; anything else the user set.
fn custom_title(path: &Path) -> Option<(String, TitleSource)> {
    let window = read_head_tail(path).ok()?;
    window
        .all()
        .filter(|record| {
            record.get("type").and_then(Value::as_str) == Some("system")
                && record.get("subtype").and_then(Value::as_str) == Some("custom_title")
        })
        .filter_map(|record| {
            let title = title_field(record.pointer("/systemPayload/customTitle"))?;
            let auto = record.pointer("/systemPayload/titleSource").and_then(Value::as_str)
                == Some("auto");
            Some((title, if auto { TitleSource::Ai } else { TitleSource::Custom }))
        })
        .last()
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    let session = match parts {
        ["projects", _, "chats", name] => is_v2_name(name),
        ["projects", _, "chats", dir, name] => *dir == ARCHIVE && is_v2_name(name),
        ["tmp", _, "chats", name] => is_v1_name(name),
        _ => false,
    };
    let store = matches!(parts, ["tmp", _, "logs.json"]);
    role(session, store)
}
