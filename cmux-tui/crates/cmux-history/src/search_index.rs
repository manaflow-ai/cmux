//! The local search index: agent chat messages (every harness, imported
//! Claude Code and Codex history included), terminal commands and scrollback
//! lines, and tab and workspace names, in one SQLite file on this Mac. It is
//! never synced.
//!
//! An FTS5 trigram table folds case and diacritics, so any three letters of
//! a word find it; names also match shorter queries. Each hit names its jump
//! target: a chat and its turn, a terminal and its line, a tab or a
//! workspace.
//!
//! Writes are keyed and incremental. `append` adds a source's new docs and
//! moves its cursor in one transaction, so a backfill that stops (quit,
//! crash) resumes where it left off and never indexes a doc twice.
//! [`Backfill::step`] does a bounded amount of work, so the owner (the
//! daemon's search worker, off its main loop) paces a large backlog. WAL
//! mode keeps queries from waiting on that writer.

use std::ops::Range;
use std::path::Path;
use std::time::Duration;

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OptionalExtension, Row, Transaction, params, params_from_iter};

use crate::error::HistoryError;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS docs(
  id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, source TEXT NOT NULL, kind TEXT NOT NULL,
  target TEXT NOT NULL, position INTEGER, title TEXT NOT NULL, at_ms INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS docs_source ON docs(source);
CREATE INDEX IF NOT EXISTS docs_kind ON docs(kind, id);
CREATE VIRTUAL TABLE IF NOT EXISTS docs_text USING fts5(
  text, title, tokenize = 'trigram case_sensitive 0 remove_diacritics 1');
CREATE TABLE IF NOT EXISTS cursors(source TEXT PRIMARY KEY, cursor INTEGER NOT NULL);
PRAGMA user_version=1;
";

/// The shortest word the trigram index can find.
const MIN_TEXT_WORD: usize = 3;

/// What a hit is, and so where it jumps.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SearchKind {
    /// An agent chat message: `target` is the session, `position` the turn.
    Chat,
    /// A finished terminal command: `target` is the terminal, `position` its line.
    Command,
    /// A scrollback line: `target` is the terminal, `position` the line.
    Scrollback,
    /// A tab name: `target` is the tab.
    Tab,
    /// A workspace name: `target` is the workspace.
    Workspace,
}

impl SearchKind {
    pub const ALL: [Self; 5] =
        [Self::Chat, Self::Command, Self::Scrollback, Self::Tab, Self::Workspace];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Chat => "chat",
            Self::Command => "command",
            Self::Scrollback => "scrollback",
            Self::Tab => "tab",
            Self::Workspace => "workspace",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.as_str() == value)
    }

    /// Names, which short queries match too.
    fn is_name(self) -> bool {
        matches!(self, Self::Tab | Self::Workspace)
    }
}

/// One searchable thing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchDoc {
    /// Unique; writing a doc with a key already present replaces it.
    pub key: String,
    /// Where it came from (`acpmux:<session>`, `shell:<terminal>`), the unit
    /// a cursor and `remove_source` act on.
    pub source: String,
    pub kind: SearchKind,
    pub target: String,
    pub position: Option<i64>,
    /// The row label: the chat, terminal, tab or workspace name.
    pub title: String,
    pub text: String,
    pub at_ms: i64,
}

/// One match, newest first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchHit {
    pub key: String,
    pub kind: SearchKind,
    pub target: String,
    pub position: Option<i64>,
    pub title: String,
    /// The text around the match.
    pub snippet: String,
    /// Byte ranges of the matched text in `snippet`.
    pub highlights: Vec<Range<usize>>,
    pub at_ms: i64,
}

/// A source of docs to backfill: each source reads its docs after a cursor.
pub trait SearchFeed {
    fn sources(&self) -> Result<Vec<String>, HistoryError>;
    /// At most `max` docs after `after` (from the start when `None`), and the
    /// cursor after the last one returned.
    fn read(
        &self,
        source: &str,
        after: Option<i64>,
        max: usize,
    ) -> Result<(Vec<SearchDoc>, i64), HistoryError>;
}

/// The index. Not `Sync`: one owner (the daemon's search worker) writes it.
pub struct SearchIndex {
    connection: Connection,
}

impl SearchIndex {
    /// Opens (creating the file and its directory) the index at `path`.
    pub fn open(path: &Path) -> Result<Self, HistoryError> {
        if let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        Self::prepare(Connection::open(path)?)
    }

    /// An index that lives in memory only (tests, benches).
    pub fn open_in_memory() -> Result<Self, HistoryError> {
        Self::prepare(Connection::open_in_memory()?)
    }

    fn prepare(connection: Connection) -> Result<Self, HistoryError> {
        connection.busy_timeout(Duration::from_millis(250))?;
        connection
            .pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get::<_, String>(0))?;
        connection.execute_batch(SCHEMA)?;
        Ok(Self { connection })
    }

    /// Writes `source`'s `docs` and, when given, moves its cursor, in one
    /// transaction.
    pub fn append(
        &mut self,
        source: &str,
        docs: &[SearchDoc],
        cursor: Option<i64>,
    ) -> Result<(), HistoryError> {
        let transaction = self.connection.transaction()?;
        for doc in docs {
            put(&transaction, doc)?;
        }
        if let Some(cursor) = cursor {
            transaction.execute(
                "INSERT INTO cursors(source, cursor) VALUES (?1, ?2) \
                 ON CONFLICT(source) DO UPDATE SET cursor = excluded.cursor",
                params![source, cursor],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    /// Writes one doc, replacing the doc with its key (a renamed tab).
    pub fn upsert(&mut self, doc: &SearchDoc) -> Result<(), HistoryError> {
        self.append(&doc.source, std::slice::from_ref(doc), None)
    }

    /// Drops every doc of `source` and its cursor (a purged chat).
    pub fn remove_source(&mut self, source: &str) -> Result<(), HistoryError> {
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "DELETE FROM docs_text WHERE rowid IN (SELECT id FROM docs WHERE source = ?1)",
            [source],
        )?;
        transaction.execute("DELETE FROM docs WHERE source = ?1", [source])?;
        transaction.execute("DELETE FROM cursors WHERE source = ?1", [source])?;
        transaction.commit()?;
        Ok(())
    }

    /// Where `source`'s backfill stopped.
    pub fn cursor(&self, source: &str) -> Result<Option<i64>, HistoryError> {
        Ok(self
            .connection
            .query_row("SELECT cursor FROM cursors WHERE source = ?1", [source], |row| row.get(0))
            .optional()?)
    }

    /// Hits for every word of `query`, newest first, of `kinds` (every kind
    /// when empty). Words of three letters or more search the text; a query
    /// of only shorter words matches tab and workspace names.
    pub fn search(
        &self,
        query: &str,
        kinds: &[SearchKind],
        limit: usize,
    ) -> Result<Vec<SearchHit>, HistoryError> {
        let words: Vec<&str> = query.split_whitespace().collect();
        if words.is_empty() || limit == 0 {
            return Ok(Vec::new());
        }
        let long: Vec<&str> =
            words.iter().copied().filter(|word| word.chars().count() >= MIN_TEXT_WORD).collect();
        if long.is_empty() {
            return self.search_names(&words, kinds, limit);
        }
        let expression = long
            .iter()
            .map(|word| format!("\"{}\"", word.replace('"', "\"\"")))
            .collect::<Vec<_>>()
            .join(" AND ");
        // The trigram tokenizer counts characters, so the snippet keeps 64 of them.
        let mut values = vec![Sql::Text(expression)];
        let filter = kind_filter(kinds, &mut values);
        values.push(Sql::Integer(i64::try_from(limit).unwrap_or(i64::MAX)));
        let sql = format!(
            "SELECT d.key, d.kind, d.target, d.position, d.title, d.at_ms, \
             snippet(docs_text, 0, '', '', '…', 64) \
             FROM docs_text JOIN docs d ON d.id = docs_text.rowid \
             WHERE docs_text MATCH ?{filter} ORDER BY docs_text.rowid DESC LIMIT ?"
        );
        let mut statement = self.connection.prepare(&sql)?;
        let rows = statement.query_map(params_from_iter(values), |row| {
            let snippet: String = row.get(6)?;
            hit(row, snippet, &long)
        })?;
        Ok(rows.filter_map(Result::transpose).collect::<Result<_, _>>()?)
    }

    /// Tab and workspace names containing every word (ASCII case folded).
    fn search_names(
        &self,
        words: &[&str],
        kinds: &[SearchKind],
        limit: usize,
    ) -> Result<Vec<SearchHit>, HistoryError> {
        let names: Vec<SearchKind> = SearchKind::ALL
            .into_iter()
            .filter(|kind| kind.is_name() && (kinds.is_empty() || kinds.contains(kind)))
            .collect();
        if names.is_empty() {
            return Ok(Vec::new());
        }
        let mut values = Vec::new();
        let filter = kind_filter(&names, &mut values);
        let mut sql = format!(
            "SELECT d.key, d.kind, d.target, d.position, d.title, d.at_ms \
             FROM docs d WHERE 1{filter}"
        );
        for word in words {
            sql.push_str(" AND instr(lower(d.title), lower(?)) > 0");
            values.push(Sql::Text((*word).to_owned()));
        }
        sql.push_str(" ORDER BY d.id DESC LIMIT ?");
        values.push(Sql::Integer(i64::try_from(limit).unwrap_or(i64::MAX)));
        let mut statement = self.connection.prepare(&sql)?;
        let rows = statement.query_map(params_from_iter(values), |row| {
            let title: String = row.get(4)?;
            hit(row, title, words)
        })?;
        Ok(rows.filter_map(Result::transpose).collect::<Result<_, _>>()?)
    }
}

/// Bounded backfill work: [`Backfill::step`] reads each source of a feed
/// after its cursor, at most `budget` docs in all, and reports whether every
/// source has caught up.
pub struct Backfill;

/// One step's result.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BackfillStep {
    pub indexed: usize,
    /// Every source has caught up; the owner can wait for new data.
    pub done: bool,
}

impl Backfill {
    pub fn step(
        index: &mut SearchIndex,
        feed: &dyn SearchFeed,
        budget: usize,
    ) -> Result<BackfillStep, HistoryError> {
        let mut indexed = 0;
        let mut done = true;
        for source in feed.sources()? {
            let left = budget - indexed;
            if left == 0 {
                done = false;
                break;
            }
            let after = index.cursor(&source)?;
            let (mut docs, next) = feed.read(&source, after, left)?;
            if docs.len() >= left {
                docs.truncate(left);
                done = false;
            }
            if !docs.is_empty() || after != Some(next) {
                index.append(&source, &docs, Some(next))?;
            }
            indexed += docs.len();
        }
        Ok(BackfillStep { indexed, done })
    }
}

/// Inserts `doc`, replacing the doc with its key.
fn put(transaction: &Transaction<'_>, doc: &SearchDoc) -> Result<(), HistoryError> {
    let existing: Option<i64> = transaction
        .query_row("SELECT id FROM docs WHERE key = ?1", [&doc.key], |row| row.get(0))
        .optional()?;
    if let Some(id) = existing {
        transaction.execute("DELETE FROM docs_text WHERE rowid = ?1", [id])?;
        transaction.execute("DELETE FROM docs WHERE id = ?1", [id])?;
    }
    transaction.execute(
        "INSERT INTO docs(key, source, kind, target, position, title, at_ms) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            doc.key,
            doc.source,
            doc.kind.as_str(),
            doc.target,
            doc.position,
            doc.title,
            doc.at_ms,
        ],
    )?;
    let id = transaction.last_insert_rowid();
    transaction.execute(
        "INSERT INTO docs_text(rowid, text, title) VALUES (?1, ?2, ?3)",
        params![id, doc.text, doc.title],
    )?;
    Ok(())
}

/// ` AND d.kind IN (?, …)` for `kinds`, binding them; empty for every kind.
fn kind_filter(kinds: &[SearchKind], values: &mut Vec<Sql>) -> String {
    if kinds.is_empty() {
        return String::new();
    }
    values.extend(kinds.iter().map(|kind| Sql::Text(kind.as_str().to_owned())));
    format!(" AND d.kind IN ({})", vec!["?"; kinds.len()].join(", "))
}

/// The hit of a row (`key, kind, target, position, title, at_ms`) with its
/// `snippet`, marking `words` in it; `None` for a kind this build does not know.
fn hit(row: &Row<'_>, snippet: String, words: &[&str]) -> rusqlite::Result<Option<SearchHit>> {
    let kind: String = row.get(1)?;
    let Some(kind) = SearchKind::parse(&kind) else { return Ok(None) };
    let highlights = highlights(&snippet, words);
    Ok(Some(SearchHit {
        key: row.get(0)?,
        kind,
        target: row.get(2)?,
        position: row.get(3)?,
        title: row.get(4)?,
        snippet,
        highlights,
        at_ms: row.get(5)?,
    }))
}

/// Byte ranges of every occurrence of each of `words` in `text`, ASCII case
/// folded (so byte offsets hold), in order and merged where they touch.
fn highlights(text: &str, words: &[&str]) -> Vec<Range<usize>> {
    let folded = text.to_ascii_lowercase();
    let mut ranges: Vec<Range<usize>> = Vec::new();
    for word in words {
        let word = word.to_ascii_lowercase();
        if word.is_empty() {
            continue;
        }
        ranges.extend(folded.match_indices(&word).map(|(start, _)| start..start + word.len()));
    }
    ranges.sort_by_key(|range| range.start);
    let mut merged: Vec<Range<usize>> = Vec::new();
    for range in ranges {
        match merged.last_mut() {
            Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
            _ => merged.push(range),
        }
    }
    merged
}

#[cfg(test)]
#[path = "search_index_tests.rs"]
mod tests;
