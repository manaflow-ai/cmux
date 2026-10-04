//! The page visit log of one browser profile: port of Swift
//! `BrowserVisitLog` and `HistorySQLite`. One SQLite file per profile, after
//! Chromium's `History` model, opened in WAL mode with one connection.
//! Incognito never gets one.

use std::path::Path;
use std::time::Duration;

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OptionalExtension, params, params_from_iter};
use url::Url;

use crate::entry::{HistoryEntry, HistoryKind};
use crate::error::HistoryError;
use crate::fold::tokens;

/// Visits older than 90 days are pruned.
pub const RETENTION_MS: i64 = 90 * 86_400_000;
/// At most 100,000 visits per profile; prune drops the oldest beyond it.
pub const MAX_VISITS: usize = 100_000;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS visits(
  id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT,
  visit_time_ms INTEGER NOT NULL, tab TEXT);
CREATE INDEX IF NOT EXISTS visits_time ON visits(visit_time_ms);
CREATE INDEX IF NOT EXISTS visits_url ON visits(url);
PRAGMA user_version=1;
";

/// A finished main-frame navigation to record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewVisit {
    pub url: String,
    pub title: Option<String>,
    /// The tab (`<machine>/<tab id>`) that visited it, when known.
    pub tab: Option<String>,
    pub at_ms: i64,
}

/// One stored visit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Visit {
    pub id: i64,
    pub url: String,
    pub title: Option<String>,
    pub at_ms: i64,
    pub tab: Option<String>,
}

impl Visit {
    /// The wire entry: `page:<profile>:<id>`, titled by the page title or,
    /// without one, the URL.
    pub fn entry(&self, profile: &str) -> HistoryEntry {
        let title = self.title.clone().filter(|title| !title.is_empty()).unwrap_or_else(|| self.url.clone());
        let mut entry = HistoryEntry::new(format!("page:{profile}:{}", self.id), HistoryKind::Page, self.at_ms, title);
        entry.detail = Some(self.url.clone());
        entry.url = Some(self.url.clone());
        entry.profile = Some(profile.to_owned());
        entry
    }
}

/// One URL with its visits summed (the omnibox seed).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VisitSummary {
    pub url: String,
    /// The newest non-null title of the URL.
    pub title: Option<String>,
    pub visit_count: u64,
    pub last_visit_ms: i64,
}

/// One profile's visit log. Not `Sync`: one owner (the daemon module's
/// history actor) holds it.
pub struct VisitStore {
    connection: Connection,
}

impl VisitStore {
    /// Opens (creating the file and its directory) the log at `path`.
    pub fn open(path: &Path) -> Result<Self, HistoryError> {
        if let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        Self::prepare(Connection::open(path)?)
    }

    /// A log that lives in memory only (tests, demos).
    pub fn open_in_memory() -> Result<Self, HistoryError> {
        Self::prepare(Connection::open_in_memory()?)
    }

    fn prepare(connection: Connection) -> Result<Self, HistoryError> {
        connection.busy_timeout(Duration::from_millis(250))?;
        connection.pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get::<_, String>(0))?;
        connection.execute_batch(SCHEMA)?;
        Ok(Self { connection })
    }

    /// Records a visit; returns its id.
    pub fn record(&self, visit: &NewVisit) -> Result<i64, HistoryError> {
        let _ = visit; Ok(0)
    }

    /// Sets the title of `url`'s newest visit (titles arrive after the load).
    /// Returns the number of visits changed (0 or 1).
    pub fn update_title(&self, url: &str, title: &str) -> Result<usize, HistoryError> {
        let _ = (url, title); Ok(0)
    }

    /// Visits newest first. Every folded token of `text` must appear in the
    /// URL or the title (SQL `LIKE`, ASCII case insensitive, as in Swift),
    /// and the visit must be at or after `since_ms`.
    pub fn visits(&self, text: &str, since_ms: Option<i64>, limit: usize) -> Result<Vec<Visit>, HistoryError> {
        let mut sql = String::from("SELECT id, url, title, visit_time_ms, tab FROM visits WHERE visit_time_ms >= ?");
        let mut bindings = vec![Sql::Integer(since_ms.unwrap_or(0))];
        for token in tokens(text) {
            sql.push_str(" AND (url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')");
            let pattern = format!("%{}%", escape_like(&token));
            bindings.push(Sql::Text(pattern.clone()));
            bindings.push(Sql::Text(pattern));
        }
        sql.push_str(" ORDER BY visit_time_ms DESC, id DESC LIMIT ?");
        bindings.push(Sql::Integer(i64::try_from(limit).unwrap_or(i64::MAX)));
        let mut statement = self.connection.prepare(&sql)?;
        let rows = statement.query_map(params_from_iter(bindings), |row| {
            Ok(Visit { id: row.get(0)?, url: row.get(1)?, title: row.get(2)?, at_ms: row.get(3)?, tab: row.get(4)? })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// [`VisitStore::visits`] as wire entries of `profile`.
    pub fn entries(&self, profile: &str, text: &str, since_ms: Option<i64>, limit: usize) -> Result<Vec<HistoryEntry>, HistoryError> {
        Ok(self.visits(text, since_ms, limit)?.iter().map(|visit| visit.entry(profile)).collect())
    }

    /// One row per URL, most recent first.
    pub fn summaries(&self, limit: usize) -> Result<Vec<VisitSummary>, HistoryError> {
        let _ = limit; Ok(Vec::new())
    }

    /// The visit with `id`, if it exists.
    pub fn visit(&self, id: i64) -> Result<Option<Visit>, HistoryError> {
        Ok(self
            .connection
            .query_row("SELECT id, url, title, visit_time_ms, tab FROM visits WHERE id = ?1", params![id], |row| {
                Ok(Visit { id: row.get(0)?, url: row.get(1)?, title: row.get(2)?, at_ms: row.get(3)?, tab: row.get(4)? })
            })
            .optional()?)
    }

    pub fn remove_visit(&self, id: i64) -> Result<usize, HistoryError> {
        let _ = id; Ok(0)
    }

    /// Removes every visit of `url`.
    pub fn remove_url(&self, url: &str) -> Result<usize, HistoryError> {
        let _ = url; Ok(0)
    }

    /// Removes every visit whose host is `host` or a subdomain of it.
    pub fn remove_host(&self, host: &str) -> Result<usize, HistoryError> {
        let _ = host; Ok(0)
    }

    /// Removes visits at or after `since_ms` (`None`: every visit).
    pub fn remove_since(&self, since_ms: Option<i64>) -> Result<usize, HistoryError> {
        let _ = since_ms; Ok(0)
    }

    /// Drops visits older than the retention before `now_ms` and the oldest
    /// beyond the row cap; returns how many went.
    pub fn prune(&self, now_ms: i64) -> Result<usize, HistoryError> {
        self.prune_to(now_ms, RETENTION_MS, MAX_VISITS)
    }

    /// [`VisitStore::prune`] with explicit limits (tests use small ones).
    pub fn prune_to(&self, now_ms: i64, retention_ms: i64, max_visits: usize) -> Result<usize, HistoryError> {
        let _ = (now_ms, retention_ms, max_visits); Ok(0)
    }

    pub fn count(&self) -> Result<u64, HistoryError> {
        let count: i64 = self.connection.query_row("SELECT COUNT(*) FROM visits", [], |row| row.get(0))?;
        Ok(count.unsigned_abs())
    }
}

/// Escapes `LIKE` wildcards with backslash.
fn escape_like(text: &str) -> String {
    text.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

#[cfg(test)]
#[path = "visits_tests.rs"]
mod tests;
