//! Moonshot Kimi, two products with separate homes.
//!
//! kimi-cli (Python, `<KIMI_SHARE_DIR|~/.kimi>`): `sessions/<bucket>/<id>/`
//! holds `context.jsonl` (messages, bookkeeping roles start with `_`),
//! `wire.jsonl` (timestamped events, `TurnBegin.user_input` is a prompt) and
//! `state.json` (`custom_title`, `archived`; `metadata.json` before v1.14).
//! Before v0.59 a session was one `sessions/<bucket>/<id>.jsonl`. The bucket
//! is the md5 of the work dir (`<kaos>_<md5>` off the local kaos); the work
//! dir itself is only in `kimi.json`.
//!
//! Kimi Code (TypeScript, `<KIMI_CODE_HOME|~/.kimi-code>`):
//! `sessions/<wd>/session_<uuid>/state.json` with the metadata, and
//! `session_index.jsonl` (`{sessionId, sessionDir, workDir}`, tombstones
//! `{sessionId, deleted: true}`).

use std::collections::HashMap;
use std::fmt::Write as _;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, file_stem, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{WINDOW, fold_lines, read_whole_json};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};
use crate::store_file::read_json_bounded;
use crate::text::{prompt_text, title_field, title_line};
use crate::time::parse_rfc3339_ms;

const CONTEXT: &str = "context.jsonl";
/// Upper bound for `kimi.json` and `session_index.jsonl` reads.
const INDEX_MAX: u64 = 4 * 1024 * 1024;

// ---------------------------------------------------------------- kimi-cli

pub(super) fn list_cli(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let Ok(buckets) = fs::read_dir(root.join("sessions")) else { return Ok(out) };
    for bucket in buckets.flatten() {
        if !bucket.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let Ok(children) = fs::read_dir(bucket.path()) else { continue };
        for child in children.flatten() {
            let Ok(kind) = child.file_type() else { continue };
            if kind.is_dir() {
                let context = child.path().join(CONTEXT);
                if context.is_file() {
                    out.push(context);
                }
            } else if kind.is_file()
                && child.file_name().to_str().is_some_and(|name| name.ends_with(".jsonl"))
            {
                out.push(child.path());
            }
        }
    }
    Ok(out)
}

/// The session dir of a `context.jsonl`; None for a legacy flat file.
fn session_dir(path: &Path) -> Option<&Path> {
    if path.file_name().and_then(|name| name.to_str()) == Some(CONTEXT) {
        path.parent()
    } else {
        None
    }
}

/// `"key":"value"` as Python (`": "`) or JS (`":"`) writes it.
fn has_pair(line: &[u8], key: &str, value_prefix: &str) -> bool {
    [format!("\"{key}\":\"{value_prefix}"), format!("\"{key}\": \"{value_prefix}")]
        .iter()
        .any(|needle| crate::lines::contains(line, needle.as_bytes()))
}

pub(super) fn read_cli(
    path: &Path,
    stamp: FileStamp,
    prev: Option<&FileState>,
) -> io::Result<FileRead> {
    let (from, mut tally) = FileState::resume_point(prev, &stamp, path);
    let offset = fold_lines(path, from, |line| {
        if !has_pair(line, "role", "") || has_pair(line, "role", "_") {
            return;
        }
        tally.messages += 1;
        if tally.first_prompt.is_none() && has_pair(line, "role", "user") {
            let record: Option<Value> = serde_json::from_slice(line).ok();
            tally.first_prompt =
                record.as_ref().and_then(|record| record.get("content")).and_then(prompt_text);
        }
    })?;
    let dir = session_dir(path);
    let session_id = match dir {
        Some(dir) => dir.file_name().and_then(|name| name.to_str()).map(str::to_owned),
        None => file_stem(path),
    };
    let Some(session_id) = session_id.filter(|id| !id.is_empty()) else {
        return Ok(FileRead { entry: None, state: FileState::folded(path, stamp, offset, tally) });
    };
    let meta = dir.map(SessionMeta::read).unwrap_or_default();
    let (title, title_source) = if let Some(custom) = meta.custom_title.clone() {
        (Some(custom), Some(TitleSource::Custom))
    } else if let Some(prompt) = meta.first_turn.clone().or_else(|| tally.first_prompt.clone()) {
        (Some(prompt), Some(TitleSource::Prompt))
    } else {
        (None, None)
    };
    let entry = ChatEntry {
        harness: AdapterKind::KimiCli,
        session_id,
        title,
        title_source,
        cwd: None,
        created_ms: meta.created_ms,
        updated_ms: stamp.mtime_ms,
        message_count: Some(tally.messages),
        source_path: path.to_path_buf(),
        originator: None,
        archived: meta.archived,
        resume: Resume::ReadOnly,
    };
    Ok(FileRead { entry: Some(entry), state: FileState::folded(path, stamp, offset, tally) })
}

/// What `state.json`, `metadata.json` and the head of `wire.jsonl` say.
#[derive(Default)]
struct SessionMeta {
    custom_title: Option<String>,
    archived: bool,
    first_turn: Option<String>,
    created_ms: Option<i64>,
}

impl SessionMeta {
    fn read(dir: &Path) -> Self {
        let mut meta = Self::default();
        let small = |name: &str| read_json_bounded::<Value>(&dir.join(name), INDEX_MAX);
        if let Some(state) = small("state.json") {
            meta.custom_title = title_field(state.get("custom_title"));
            meta.archived = state.get("archived") == Some(&Value::Bool(true));
        }
        // Before v1.14 the title and archive flag lived in metadata.json.
        if let Some(legacy) = small("metadata.json") {
            if meta.custom_title.is_none() {
                meta.custom_title =
                    title_field(legacy.get("title")).filter(|title| title != "Untitled");
            }
            meta.archived |= legacy.get("archived") == Some(&Value::Bool(true));
        }
        for record in wire_head(&dir.join("wire.jsonl")) {
            if meta.created_ms.is_none() {
                meta.created_ms = record.get("timestamp").and_then(seconds_to_ms);
            }
            let message = record.get("message").unwrap_or(&Value::Null);
            if meta.first_turn.is_none()
                && message.get("type").and_then(Value::as_str) == Some("TurnBegin")
            {
                meta.first_turn = message.pointer("/payload/user_input").and_then(prompt_text);
            }
            if meta.created_ms.is_some() && meta.first_turn.is_some() {
                break;
            }
        }
        meta
    }
}

/// Complete JSON lines of the first `WINDOW` bytes of a wire log.
fn wire_head(path: &Path) -> Vec<Value> {
    let Ok(file) = File::open(path) else { return Vec::new() };
    let mut bytes = Vec::new();
    if file.take(WINDOW).read_to_end(&mut bytes).is_err() {
        return Vec::new();
    }
    let complete = bytes.iter().rposition(|byte| *byte == b'\n').map_or(&[][..], |at| &bytes[..at]);
    complete
        .split(|byte| *byte == b'\n')
        .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
        .collect()
}

/// Unix seconds (float or int) or an RFC 3339 string, as milliseconds.
fn seconds_to_ms(value: &Value) -> Option<i64> {
    if let Some(text) = value.as_str() {
        return parse_rfc3339_ms(text);
    }
    let seconds = value.as_f64()?;
    (seconds.is_finite() && seconds > 0.0 && seconds < 1e12).then_some((seconds * 1000.0) as i64)
}

/// Folders from `kimi.json`: the bucket name is the md5 of the work dir.
pub(super) fn finish_cli(root: &Path, entries: &mut [ChatEntry]) {
    let Some(index) = read_json_bounded::<Value>(&root.join("kimi.json"), INDEX_MAX) else {
        return;
    };
    let mut buckets: HashMap<String, String> = HashMap::new();
    for work_dir in index.get("work_dirs").and_then(Value::as_array).into_iter().flatten() {
        let Some(path) = work_dir.get("path").and_then(Value::as_str).filter(|p| !p.is_empty())
        else {
            continue;
        };
        let digest = md5_hex(path.as_bytes());
        let bucket = match work_dir.get("kaos").and_then(Value::as_str) {
            Some(kaos) if kaos != "local" && !kaos.is_empty() => format!("{kaos}_{digest}"),
            _ => digest,
        };
        buckets.insert(bucket, path.to_owned());
    }
    let sessions = root.join("sessions");
    for entry in entries.iter_mut().filter(|entry| entry.cwd.is_none()) {
        let bucket = entry
            .source_path
            .strip_prefix(&sessions)
            .ok()
            .and_then(|rel| rel.iter().next())
            .and_then(|part| part.to_str());
        if let Some(path) = bucket.and_then(|bucket| buckets.get(bucket)) {
            entry.cwd = Some(path.clone());
        }
    }
}

pub(super) fn classify_cli(parts: &[&str]) -> PathRole {
    let name = parts.last().copied().unwrap_or_default();
    let in_sessions = parts.first() == Some(&"sessions");
    let session = in_sessions
        && match parts.len() {
            3 => name.ends_with(".jsonl"),
            4 => name == CONTEXT,
            _ => false,
        };
    let store = (parts.len() == 1 && name == "kimi.json")
        || (in_sessions
            && parts.len() == 4
            && matches!(name, "state.json" | "metadata.json" | "wire.jsonl"));
    role(session, store)
}

// --------------------------------------------------------------- Kimi Code

pub(super) fn list_code(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    let Ok(work_dirs) = fs::read_dir(root.join("sessions")) else { return Ok(out) };
    for work_dir in work_dirs.flatten() {
        if !work_dir.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let Ok(sessions) = fs::read_dir(work_dir.path()) else { continue };
        for session in sessions.flatten() {
            let name = session.file_name();
            let is_session = name.to_str().is_some_and(|name| name.starts_with("session_"));
            let state = session.path().join("state.json");
            if is_session && state.is_file() {
                out.push(state);
            }
        }
    }
    Ok(out)
}

pub(super) fn read_code(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    let Some(state) = read_whole_json(path)? else { return Ok(None) };
    let dir_name = path.parent().and_then(Path::file_name).and_then(|name| name.to_str());
    let Some(session_id) = state
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .or(dir_name)
        .map(str::to_owned)
    else {
        return Ok(None);
    };
    let custom = state.get("titleKind").and_then(Value::as_str) == Some("custom")
        || state.get("isCustomTitle") == Some(&Value::Bool(true));
    let kind = state.get("titleKind").and_then(Value::as_str);
    let title_source = if custom {
        TitleSource::Custom
    } else if kind == Some("replaceable") {
        TitleSource::Prompt
    } else {
        TitleSource::Ai
    };
    let (title, title_source) = match title_field(state.get("title")) {
        Some(title) => (Some(title), Some(title_source)),
        None => match state.get("lastPrompt").and_then(Value::as_str).and_then(title_line) {
            Some(prompt) => (Some(prompt), Some(TitleSource::Prompt)),
            None => (None, None),
        },
    };
    let millis = |key: &str| state.get(key).and_then(Value::as_i64);
    Ok(Some(ChatEntry {
        harness: AdapterKind::KimiCode,
        session_id,
        title,
        title_source,
        cwd: state
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|cwd| !cwd.is_empty())
            .map(str::to_owned),
        created_ms: millis("createdAt"),
        updated_ms: millis("updatedAt").unwrap_or(stamp.mtime_ms),
        message_count: None,
        source_path: path.to_path_buf(),
        originator: None,
        archived: state.get("archived") == Some(&Value::Bool(true)),
        resume: Resume::ReadOnly,
    }))
}

/// `session_index.jsonl`: folders for sessions whose state has none, and
/// tombstones (`deleted: true`, last line per id wins) drop a session.
pub(super) fn finish_code(root: &Path, entries: &mut Vec<ChatEntry>) {
    let path = root.join("session_index.jsonl");
    if !fs::metadata(&path).is_ok_and(|meta| meta.len() <= INDEX_MAX) {
        return;
    }
    // id -> Some(work dir) or None when deleted.
    let mut index: HashMap<String, Option<String>> = HashMap::new();
    let folded = fold_lines(&path, 0, |line| {
        let Ok(record) = serde_json::from_slice::<Value>(line) else { return };
        let Some(id) = record.get("sessionId").and_then(Value::as_str) else { return };
        if record.get("deleted") == Some(&Value::Bool(true)) {
            index.insert(id.to_owned(), None);
        } else {
            let work_dir = record.get("workDir").and_then(Value::as_str).unwrap_or_default();
            index.insert(id.to_owned(), Some(work_dir.to_owned()));
        }
    });
    if folded.is_err() {
        return;
    }
    entries.retain(|entry| !matches!(index_lookup(&index, entry), Some(None)));
    for entry in entries.iter_mut() {
        if entry.cwd.is_none()
            && let Some(Some(work_dir)) = index_lookup(&index, entry)
            && !work_dir.is_empty()
        {
            entry.cwd = Some(work_dir.clone());
        }
    }
}

/// The index line of a session: by id, else by its session dir name.
fn index_lookup<'a>(
    index: &'a HashMap<String, Option<String>>,
    entry: &ChatEntry,
) -> Option<&'a Option<String>> {
    index.get(&entry.session_id).or_else(|| {
        let dir = entry.source_path.parent()?.file_name()?.to_str()?;
        index.get(dir)
    })
}

pub(super) fn classify_code(parts: &[&str]) -> PathRole {
    let name = parts.last().copied().unwrap_or_default();
    let session = parts.len() == 4 && parts[0] == "sessions" && name == "state.json";
    let store = parts.len() == 1 && name == "session_index.jsonl";
    role(session, store)
}

// --------------------------------------------------------------------- MD5

/// MD5 (RFC 1321) as lowercase hex: kimi-cli names session buckets by it.
fn md5_hex(input: &[u8]) -> String {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5,
        9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10,
        15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    let k: [u32; 64] =
        std::array::from_fn(|i| ((i as f64 + 1.0).sin().abs() * 4_294_967_296.0) as u32);
    let mut state: [u32; 4] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476];
    let mut message = input.to_vec();
    let bit_len = (input.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_le_bytes());
    for chunk in message.chunks_exact(64) {
        let words: [u32; 16] = std::array::from_fn(|i| {
            let at = i * 4;
            u32::from_le_bytes([chunk[at], chunk[at + 1], chunk[at + 2], chunk[at + 3]])
        });
        let [mut a, mut b, mut c, mut d] = state;
        for (i, (&shift, &constant)) in S.iter().zip(k.iter()).enumerate() {
            let (f, g) = match i / 16 {
                0 => ((b & c) | (!b & d), i),
                1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                2 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let rotated =
                a.wrapping_add(f).wrapping_add(constant).wrapping_add(words[g]).rotate_left(shift);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(rotated);
        }
        state = [
            state[0].wrapping_add(a),
            state[1].wrapping_add(b),
            state[2].wrapping_add(c),
            state[3].wrapping_add(d),
        ];
    }
    let mut hex = String::with_capacity(32);
    for byte in state.iter().flat_map(|word| word.to_le_bytes()) {
        let _ = write!(hex, "{byte:02x}");
    }
    hex
}
