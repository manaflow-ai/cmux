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
        let title = self
            .title
            .clone()
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| self.url.clone());
        let mut entry = HistoryEntry::new(
            format!("page:{profile}:{}", self.id),
            HistoryKind::Page,
            self.at_ms,
            title,
        );
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
        connection
            .pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get::<_, String>(0))?;
        connection.execute_batch(SCHEMA)?;
        Ok(Self { connection })
    }

    /// Records a visit; returns its id.
    pub fn record(&self, visit: &NewVisit) -> Result<i64, HistoryError> {
        self.connection.execute(
            "INSERT INTO visits(url, title, visit_time_ms, tab) VALUES (?1, ?2, ?3, ?4)",
            params![visit.url, visit.title, visit.at_ms, visit.tab],
        )?;
        Ok(self.connection.last_insert_rowid())
    }

    /// Sets the title of `url`'s newest visit (titles arrive after the load).
    /// Returns the number of visits changed (0 or 1).
    pub fn update_title(&self, url: &str, title: &str) -> Result<usize, HistoryError> {
        Ok(self.connection.execute(
            "UPDATE visits SET title = ?1 WHERE id = \
             (SELECT id FROM visits WHERE url = ?2 ORDER BY visit_time_ms DESC, id DESC LIMIT 1)",
            params![title, url],
        )?)
    }

    /// Visits newest first. Every folded token of `text` must appear in the
    /// URL or the title (SQL `LIKE`, ASCII case insensitive, as in Swift),
    /// and the visit must be at or after `since_ms`.
    pub fn visits(
        &self,
        text: &str,
        since_ms: Option<i64>,
        limit: usize,
    ) -> Result<Vec<Visit>, HistoryError> {
        let mut sql = String::from(
            "SELECT id, url, title, visit_time_ms, tab FROM visits WHERE visit_time_ms >= ?",
        );
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
            Ok(Visit {
                id: row.get(0)?,
                url: row.get(1)?,
                title: row.get(2)?,
                at_ms: row.get(3)?,
                tab: row.get(4)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// [`VisitStore::visits`] as wire entries of `profile`.
    pub fn entries(
        &self,
        profile: &str,
        text: &str,
        since_ms: Option<i64>,
        limit: usize,
    ) -> Result<Vec<HistoryEntry>, HistoryError> {
        Ok(self.visits(text, since_ms, limit)?.iter().map(|visit| visit.entry(profile)).collect())
    }

    /// One row per URL, most recent first.
    pub fn summaries(&self, limit: usize) -> Result<Vec<VisitSummary>, HistoryError> {
        let mut statement = self.connection.prepare(
            "SELECT url, (SELECT title FROM visits v2 WHERE v2.url = v.url AND v2.title IS NOT NULL \
             ORDER BY visit_time_ms DESC LIMIT 1), COUNT(*), MAX(visit_time_ms) \
             FROM visits v GROUP BY url ORDER BY MAX(visit_time_ms) DESC LIMIT ?1",
        )?;
        let rows =
            statement.query_map(params![i64::try_from(limit).unwrap_or(i64::MAX)], |row| {
                Ok(VisitSummary {
                    url: row.get(0)?,
                    title: row.get(1)?,
                    visit_count: row.get::<_, i64>(2)?.unsigned_abs(),
                    last_visit_ms: row.get(3)?,
                })
            })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// The visit with `id`, if it exists.
    pub fn visit(&self, id: i64) -> Result<Option<Visit>, HistoryError> {
        Ok(self
            .connection
            .query_row(
                "SELECT id, url, title, visit_time_ms, tab FROM visits WHERE id = ?1",
                params![id],
                |row| {
                    Ok(Visit {
                        id: row.get(0)?,
                        url: row.get(1)?,
                        title: row.get(2)?,
                        at_ms: row.get(3)?,
                        tab: row.get(4)?,
                    })
                },
            )
            .optional()?)
    }

    pub fn remove_visit(&self, id: i64) -> Result<usize, HistoryError> {
        Ok(self.connection.execute("DELETE FROM visits WHERE id = ?1", params![id])?)
    }

    /// Removes every visit of `url`.
    pub fn remove_url(&self, url: &str) -> Result<usize, HistoryError> {
        Ok(self.connection.execute("DELETE FROM visits WHERE url = ?1", params![url])?)
    }

    /// Removes every visit whose host is `host` or a subdomain of it.
    pub fn remove_host(&self, host: &str) -> Result<usize, HistoryError> {
        let host = host.to_lowercase();
        let suffix = format!(".{host}");
        let mut ids = Vec::new();
        {
            let mut statement = self.connection.prepare("SELECT id, url FROM visits")?;
            let mut rows = statement.query([])?;
            while let Some(row) = rows.next()? {
                let url: String = row.get(1)?;
                let candidate =
                    Url::parse(&url).ok().and_then(|url| url.host_str().map(str::to_lowercase));
                if candidate
                    .is_some_and(|candidate| candidate == host || candidate.ends_with(&suffix))
                {
                    ids.push(row.get::<_, i64>(0)?);
                }
            }
        }
        let transaction = self.connection.unchecked_transaction()?;
        let mut removed = 0;
        for id in ids {
            removed += transaction.execute("DELETE FROM visits WHERE id = ?1", params![id])?;
        }
        transaction.commit()?;
        Ok(removed)
    }

    /// Removes visits at or after `since_ms` (`None`: every visit).
    pub fn remove_since(&self, since_ms: Option<i64>) -> Result<usize, HistoryError> {
        let since = since_ms.unwrap_or(i64::MIN);
        Ok(self
            .connection
            .execute("DELETE FROM visits WHERE visit_time_ms >= ?1", params![since])?)
    }

    /// Drops visits older than the retention before `now_ms` and the oldest
    /// beyond the row cap; returns how many went.
    pub fn prune(&self, now_ms: i64) -> Result<usize, HistoryError> {
        self.prune_to(now_ms, RETENTION_MS, MAX_VISITS)
    }

    /// [`VisitStore::prune`] with explicit limits (tests use small ones).
    pub fn prune_to(
        &self,
        now_ms: i64,
        retention_ms: i64,
        max_visits: usize,
    ) -> Result<usize, HistoryError> {
        let cutoff = now_ms.saturating_sub(retention_ms);
        let mut removed = self
            .connection
            .execute("DELETE FROM visits WHERE visit_time_ms < ?1", params![cutoff])?;
        removed += self.connection.execute(
            "DELETE FROM visits WHERE id IN \
             (SELECT id FROM visits ORDER BY visit_time_ms DESC, id DESC LIMIT -1 OFFSET ?1)",
            params![i64::try_from(max_visits).unwrap_or(i64::MAX)],
        )?;
        Ok(removed)
    }

    pub fn count(&self) -> Result<u64, HistoryError> {
        let count: i64 =
            self.connection.query_row("SELECT COUNT(*) FROM visits", [], |row| row.get(0))?;
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
