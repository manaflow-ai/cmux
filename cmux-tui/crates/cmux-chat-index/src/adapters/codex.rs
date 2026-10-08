//! Codex CLI and the Codex desktop app (same `CODEX_HOME`). Primary source:
//! the `threads` table of the newest `state_<n>.sqlite`. Without it, the
//! rollout files under `sessions/` and `archived_sessions/`. Names from
//! `session_index.jsonl` (last line per id wins).

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

use rusqlite::Connection;
use serde_json::Value;

use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{contains, fold_lines, read_first_record};
use crate::scan::FileRead;
use crate::sqlite::{columns, open_read_only};
use crate::stamp::{FileStamp, FileState};
use crate::text::{prompt_text, title_line};
use crate::time::parse_rfc3339_ms;

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
    name.starts_with("rollout-") && (name.ends_with(".jsonl") || name.ends_with(".jsonl.zst"))
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
    if name.ends_with(".zst") {
        // Compressed rollouts (older than 7 days): no zstd reader, so no count.
        let state = FileState { stamp, offset: stamp.size, ..FileState::default() };
        return Ok(FileRead { entry: (!entry.session_id.is_empty()).then_some(entry), state });
    }
    if let Some(meta) =
        read_first_record(path)?.filter(|record| record_type(record) == Some("session_meta"))
    {
        let payload = &meta["payload"];
        if let Some(id) = payload.get("id").and_then(Value::as_str) {
            id.clone_into(&mut entry.session_id);
        }
        entry.cwd = string(payload.get("cwd"));
        entry.originator = string(payload.get("originator"));
        let started = payload.get("timestamp").or_else(|| meta.get("timestamp"));
        entry.created_ms =
            started.and_then(Value::as_str).and_then(parse_rfc3339_ms).or(entry.created_ms);
    }
    let (from, mut tally) = FileState::resume_point(prev, &stamp);
    let offset = fold_lines(path, from, |line| {
        if !contains(line, br#""type":"user_message""#) {
            return;
        }
        tally.messages += 1;
        if tally.first_prompt.is_none() {
            let record: Option<Value> = serde_json::from_slice(line).ok();
            tally.first_prompt = record
                .as_ref()
                .and_then(|record| record.pointer("/payload/message"))
                .and_then(prompt_text);
        }
    })?;
    entry.message_count = Some(tally.messages);
    entry.title_source = tally.first_prompt.as_ref().map(|_| TitleSource::Prompt);
    entry.title.clone_from(&tally.first_prompt);
    let state = FileState { stamp, offset, tally };
    Ok(FileRead { entry: (!entry.session_id.is_empty()).then_some(entry), state })
}

/// `rollout-2026-10-01T10-00-00-<thread id>[_<rollout id>].jsonl[.zst]`:
/// the thread id and the start time (read as UTC).
fn parse_rollout_name(name: &str) -> Option<(String, Option<i64>)> {
    let stem = name.strip_prefix("rollout-")?;
    let stem = stem.strip_suffix(".jsonl.zst").or_else(|| stem.strip_suffix(".jsonl"))?;
    let (stamp, rest) = (stem.get(..19)?, stem.get(20..)?);
    let id = rest.split('_').next().filter(|id| !id.is_empty())?;
    let iso = format!("{}:{}:{}", &stamp[..13], &stamp[14..16], &stamp[17..19]);
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

fn query_threads(db: &Path) -> rusqlite::Result<Vec<ChatEntry>> {
    let conn = open_read_only(db)?;
    let cols = columns(&conn, "threads")?;
    if !cols.contains("id") {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let col = |name: &str| if cols.contains(name) { name.to_owned() } else { "NULL".to_owned() };
    let millis = |name: &str| {
        if cols.contains(&format!("{name}_ms")) {
            format!("{name}_ms")
        } else if cols.contains(name) {
            format!("{name} * 1000")
        } else {
            "NULL".to_owned()
        }
    };
    let mut filters = vec!["1 = 1".to_owned()];
    if cols.contains("has_user_event") {
        filters.push("has_user_event = 1".to_owned());
    }
    for agent_col in ["agent_nickname", "agent_role"] {
        if cols.contains(agent_col) {
            filters.push(format!("({agent_col} IS NULL OR {agent_col} = '')"));
        }
    }
    if let Some(child) = spawn_child_column(&conn) {
        filters.push(format!(
            "id NOT IN (SELECT {child} FROM thread_spawn_edges WHERE {child} IS NOT NULL)"
        ));
    }
    let sql = format!(
        "SELECT id, {name}, {title}, {preview}, {first}, {cwd}, {created}, {updated}, {archived}, {originator}, {rollout}
         FROM threads WHERE {filters}",
        name = col("name"),
        title = col("title"),
        preview = col("preview"),
        first = col("first_user_message"),
        cwd = col("cwd"),
        created = millis("created_at"),
        updated = millis("updated_at"),
        archived = col("archived"),
        originator = col("originator"),
        rollout = col("rollout_path"),
        filters = filters.join(" AND "),
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |row| {
        let text = |index: usize| row.get::<_, Option<String>>(index);
        let candidates = [
            (text(1)?, TitleSource::Custom),
            (text(2)?, TitleSource::Ai),
            (text(3)?, TitleSource::Prompt),
            (text(4)?, TitleSource::Prompt),
        ];
        let (title, title_source) = candidates
            .into_iter()
            .find_map(|(value, source)| {
                value.as_deref().and_then(title_line).map(|title| (Some(title), Some(source)))
            })
            .unwrap_or((None, None));
        let created_ms = row.get::<_, Option<i64>>(6)?;
        Ok(ChatEntry {
            harness: AdapterKind::Codex,
            session_id: row.get(0)?,
            title,
            title_source,
            cwd: text(5)?.filter(|cwd| !cwd.is_empty()),
            created_ms,
            updated_ms: row.get::<_, Option<i64>>(7)?.or(created_ms).unwrap_or(0),
            message_count: None,
            source_path: text(10)?.map_or_else(|| db.to_path_buf(), PathBuf::from),
            originator: text(9)?,
            archived: row.get::<_, Option<i64>>(8)?.unwrap_or(0) != 0,
            resume: Resume::Adopt,
        })
    })?;
    rows.collect()
}

fn spawn_child_column(conn: &Connection) -> Option<&'static str> {
    let cols = columns(conn, "thread_spawn_edges").ok()?;
    ["child_thread_id", "child_id"].into_iter().find(|name| cols.contains(*name))
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
