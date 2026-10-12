//! Claude Code: `<root>/<encoded cwd>/<session uuid>.jsonl`, append-only
//! (0.2.106+). Title and folder come from the head and tail windows (as
//! Claude's own picker and the Agent SDK read them); the message count is
//! folded incrementally. Subagents: inline `isSidechain` (to 2.0.27), flat
//! `agent-*.jsonl` (2.0.28-2.1.1), `<id>/subagents/` (2.1.2+). Claude
//! 0.2.90-0.2.109 also kept a SQLite store, `<config dir>/__store.db`.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, file_stem, files_one_level_down, role};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::{contains, fold_lines, read_first_record, read_head_tail};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};
use crate::text::{prompt_text, title_field};
use crate::time::parse_rfc3339_ms;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    // Old-layout subagents sit beside sessions as agent-*.jsonl; new-layout
    // ones are under <uuid>/subagents/ and are two levels down, so not listed.
    files_one_level_down(root, |name| name.ends_with(".jsonl") && !name.starts_with("agent-"))
}

pub(super) fn read(
    path: &Path,
    stamp: FileStamp,
    prev: Option<&FileState>,
) -> io::Result<FileRead> {
    let window = read_head_tail(path)?;
    // The real first line (the head window drops a first line over 64 KiB).
    let first = read_first_record(path)?;
    if first.is_some_and(|first| first.get("isSidechain") == Some(&Value::Bool(true))) {
        return Ok(FileRead {
            entry: None,
            state: FileState { stamp, offset: stamp.size, ..FileState::default() },
        });
    }
    let (from, mut tally) = FileState::resume_point(prev, &stamp, path);
    let offset = fold_lines(path, from, |line| {
        if contains(line, br#""type":"user""#) || contains(line, br#""type":"assistant""#) {
            tally.messages += 1;
        }
    })?;
    let mut titles = Titles::default();
    for record in window.all() {
        titles.add(record);
    }
    let session_id = file_stem(path).ok_or_else(|| io::Error::other("session file has no name"))?;
    if titles.continued_in {
        // Superseded by the session it continued in (the SDK skips it too).
        return Ok(FileRead {
            entry: None,
            state: FileState { stamp, offset: stamp.size, ..FileState::default() },
        });
    }
    if titles.custom.is_none() {
        titles.custom = sidecar_title(path, &session_id);
    }
    let (title, title_source) = titles.best();
    let entry = ChatEntry {
        harness: AdapterKind::ClaudeCode,
        session_id,
        title,
        title_source,
        cwd: titles.relocated.clone().or(titles.cwd),
        created_ms: titles.created_ms,
        updated_ms: stamp.mtime_ms,
        message_count: Some(tally.messages),
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Adopt,
    };
    Ok(FileRead { entry: Some(entry), state: FileState::folded(path, stamp, offset, tally) })
}

/// Last custom title > last AI title > last prompt > first typed prompt.
/// A `summary` record alone never names a chat: it can describe another one.
#[derive(Default)]
struct Titles {
    custom: Option<String>,
    ai: Option<String>,
    last_prompt: Option<String>,
    first_prompt: Option<String>,
    cwd: Option<String>,
    /// `/cd` moved the session: the last `relocated` record wins.
    relocated: Option<String>,
    continued_in: bool,
    created_ms: Option<i64>,
}

impl Titles {
    fn add(&mut self, record: &Value) {
        if self.cwd.is_none() {
            self.cwd = record
                .get("cwd")
                .and_then(Value::as_str)
                .filter(|cwd| !cwd.is_empty())
                .map(str::to_owned);
        }
        if self.created_ms.is_none() {
            self.created_ms =
                record.get("timestamp").and_then(Value::as_str).and_then(parse_rfc3339_ms);
        }
        match record.get("type").and_then(Value::as_str) {
            Some("custom-title") => {
                replace(&mut self.custom, title_field(record.get("customTitle")));
            }
            Some("ai-title") => replace(&mut self.ai, title_field(record.get("aiTitle"))),
            Some("last-prompt") => {
                replace(&mut self.last_prompt, title_field(record.get("lastPrompt")));
            }
            Some("relocated") => {
                let cwd = record.get("relocatedCwd").and_then(Value::as_str);
                replace(&mut self.relocated, cwd.filter(|cwd| !cwd.is_empty()).map(str::to_owned));
            }
            Some("continued-in") => {
                self.continued_in = record
                    .get("continuedInSessionId")
                    .and_then(Value::as_str)
                    .is_some_and(|id| !id.is_empty());
            }
            Some("user") if self.first_prompt.is_none() && is_typed(record) => {
                self.first_prompt = record.pointer("/message/content").and_then(prompt_text);
            }
            _ => {}
        }
    }

    fn best(&self) -> (Option<String>, Option<TitleSource>) {
        [
            (&self.custom, TitleSource::Custom),
            (&self.ai, TitleSource::Ai),
            (&self.last_prompt, TitleSource::Prompt),
            (&self.first_prompt, TitleSource::Prompt),
        ]
        .into_iter()
        .find_map(|(title, source)| title.clone().map(|title| (Some(title), Some(source))))
        .unwrap_or((None, None))
    }
}

fn replace(slot: &mut Option<String>, value: Option<String>) {
    if value.is_some() {
        *slot = value;
    }
}

/// `<enc>/<session id>/custom-title.json` (`{customTitle}`), read when the
/// transcript has no custom title.
fn sidecar_title(path: &Path, session_id: &str) -> Option<String> {
    let file = path.parent()?.join(session_id).join("custom-title.json");
    let value: Value = crate::store_file::read_json_bounded(&file, 64 * 1024)?;
    title_field(value.get("customTitle"))
}

fn is_typed(record: &Value) -> bool {
    ["isMeta", "isSidechain", "isCompactSummary"]
        .iter()
        .all(|flag| record.get(*flag) != Some(&Value::Bool(true)))
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    let name = parts.last().copied().unwrap_or_default();
    let session = parts.len() == 2 && name.ends_with(".jsonl") && !name.starts_with("agent-");
    // The custom-title sidecar renames its session.
    let sidecar = parts.len() == 3 && name == "custom-title.json";
    role(session, sidecar)
}

/// Claude Code 0.2.90-0.2.109 (2025-04/05) kept chats in
/// `<config dir>/__store.db` (better-sqlite3, drizzle): `base_messages`,
/// `user_messages`, `conversation_summaries`. The root is
/// `<config dir>/projects`, so the store sits beside it.
pub(super) fn add_legacy_store(root: &Path, entries: &mut Vec<ChatEntry>) {
    if root.file_name().is_none_or(|name| name != "projects") {
        return;
    }
    let Some(db) = root.parent().map(|dir| dir.join("__store.db")).filter(|db| db.is_file()) else {
        return;
    };
    let Ok(found) = legacy_sessions(&db) else { return };
    let known: std::collections::HashSet<String> =
        entries.iter().map(|entry| entry.session_id.clone()).collect();
    entries.extend(found.into_iter().filter(|entry| !known.contains(&entry.session_id)));
}

fn legacy_sessions(db: &Path) -> rusqlite::Result<Vec<ChatEntry>> {
    use crate::sqlite::{columns, open_read_only};
    let conn = open_read_only(db)?;
    let cols = columns(&conn, "base_messages")?;
    if !["uuid", "session_id", "timestamp", "message_type"].iter().all(|c| cols.contains(*c)) {
        return Ok(Vec::new());
    }
    let side = if cols.contains("isSidechain") { "coalesce(isSidechain, 0) = 0" } else { "1 = 1" };
    let cwd = if cols.contains("cwd") { "max(cwd)" } else { "NULL" };
    let sql = format!(
        "SELECT session_id, min(timestamp), max(timestamp), count(*), {cwd} FROM base_messages
         WHERE {side} AND session_id IS NOT NULL GROUP BY session_id"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<i64>>(1)?,
            row.get::<_, Option<i64>>(2)?,
            row.get::<_, i64>(3)?,
            row.get::<_, Option<String>>(4)?,
        ))
    })?;
    let first_prompt = |session: &str| -> Option<String> {
        let message: Option<String> = conn
            .query_row(
                "SELECT u.message FROM base_messages b JOIN user_messages u ON u.uuid = b.uuid
                 WHERE b.session_id = ?1 AND b.message_type = 'user' ORDER BY b.timestamp, b.uuid
                 LIMIT 1",
                [session],
                |row| row.get(0),
            )
            .ok()?;
        let value: Value = serde_json::from_str(&message?).ok()?;
        value.get("content").and_then(prompt_text)
    };
    let mut out = Vec::new();
    for row in rows {
        let (id, first, last, count, cwd) = row?;
        let title = first_prompt(&id);
        // drizzle `mode: "timestamp"` stores Unix seconds.
        let ms = |secs: Option<i64>| {
            secs.map(|secs| if secs > 100_000_000_000 { secs } else { secs.saturating_mul(1000) })
        };
        out.push(ChatEntry {
            harness: AdapterKind::ClaudeCode,
            title_source: title.as_ref().map(|_| TitleSource::Prompt),
            title,
            cwd: cwd.filter(|cwd| !cwd.is_empty()),
            created_ms: ms(first),
            updated_ms: ms(last).or(ms(first)).unwrap_or(0),
            message_count: Some(u64::try_from(count).unwrap_or(0)),
            source_path: db.to_path_buf(),
            originator: None,
            archived: false,
            // Claude Code no longer reads this store.
            resume: Resume::ReadOnly,
            session_id: id,
        });
    }
    Ok(out)
}
