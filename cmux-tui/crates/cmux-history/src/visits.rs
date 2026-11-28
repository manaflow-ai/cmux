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
use crate::fold::{fold, tokens};

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
CREATE TABLE IF NOT EXISTS removed_visits(
  backup TEXT NOT NULL, id INTEGER NOT NULL, url TEXT NOT NULL, title TEXT,
  visit_time_ms INTEGER NOT NULL, tab TEXT);
CREATE INDEX IF NOT EXISTS removed_visits_backup ON removed_visits(backup);
CREATE INDEX IF NOT EXISTS removed_visits_time ON removed_visits(visit_time_ms);
CREATE TABLE IF NOT EXISTS imported_logs(
  source TEXT PRIMARY KEY, visits INTEGER NOT NULL);
PRAGMA user_version=3;
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
        let searchable = connection
            .prepare("SELECT 1 FROM pragma_table_info('visits') WHERE name = 'search'")?
            .exists([])?;
        if !searchable {
            connection.execute_batch("ALTER TABLE visits ADD COLUMN search TEXT")?;
        }
        let store = Self { connection };
        store.fill_search()?;
        Ok(store)
    }

    /// Sets the folded search text of every visit that has none: rows from
    /// before the column, restored and imported rows. A record or a title
    /// update writes it in its own statement. Runs in batches by id, so it
    /// never loads every row at once.
    fn fill_search(&self) -> Result<(), HistoryError> {
        const BATCH: i64 = 1000;
        let mut after = i64::MIN;
        loop {
            let rows: Vec<(i64, String, Option<String>)> = {
                let mut statement = self.connection.prepare(
                    "SELECT id, url, title FROM visits WHERE id > ?1 AND search IS NULL \
                     ORDER BY id LIMIT ?2",
                )?;
                statement
                    .query_map(params![after, BATCH], |row| {
                        Ok((row.get(0)?, row.get(1)?, row.get(2)?))
                    })?
                    .collect::<Result<_, _>>()?
            };
            let Some(&(last, _, _)) = rows.last() else { return Ok(()) };
            let transaction = self.connection.unchecked_transaction()?;
            {
                let mut update =
                    transaction.prepare("UPDATE visits SET search = ?1 WHERE id = ?2")?;
                for (id, url, title) in &rows {
                    update.execute(params![search_text(url, title.as_deref()), id])?;
                }
            }
            transaction.commit()?;
            after = last;
        }
    }

    /// Records a visit; returns its id.
    pub fn record(&self, visit: &NewVisit) -> Result<i64, HistoryError> {
        self.connection.execute(
            "INSERT INTO visits(url, title, visit_time_ms, tab, search) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                visit.url,
                visit.title,
                visit.at_ms,
                visit.tab,
                search_text(&visit.url, visit.title.as_deref())
            ],
        )?;
        Ok(self.connection.last_insert_rowid())
    }

    /// Sets the title of `url`'s newest visit (titles arrive after the load).
    /// Returns the number of visits changed (0 or 1).
    pub fn update_title(&self, url: &str, title: &str) -> Result<usize, HistoryError> {
        Ok(self.connection.execute(
            "UPDATE visits SET title = ?1, search = ?3 WHERE id = \
             (SELECT id FROM visits WHERE url = ?2 ORDER BY visit_time_ms DESC, id DESC LIMIT 1)",
            params![title, url, search_text(url, Some(title))],
        )?)
    }

    /// Visits newest first. Every folded token of `text` must appear in the
    /// folded URL and title (SQL `LIKE` on the `search` column, so the limit
    /// applies after the filter),
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
            sql.push_str(" AND search LIKE ? ESCAPE '\\'");
            bindings.push(Sql::Text(format!("%{}%", escape_like(&token))));
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

    /// Removes one visit; `backup` names the backup it can be restored
    /// from.
    pub fn remove_visit(&self, id: i64, backup: &str) -> Result<usize, HistoryError> {
        self.remove_where("id = ?2", &[&id], backup)
    }

    /// Moves the visits matching `condition` (SQL over `visits`, its
    /// parameters from `?2`) into `backup`, in one transaction.
    fn remove_where(
        &self,
        condition: &str,
        args: &[&dyn rusqlite::ToSql],
        backup: &str,
    ) -> Result<usize, HistoryError> {
        let mut all: Vec<&dyn rusqlite::ToSql> = vec![&backup];
        all.extend_from_slice(args);
        let transaction = self.connection.unchecked_transaction()?;
        transaction.execute(
            &format!(
                "INSERT INTO removed_visits(backup, id, url, title, visit_time_ms, tab) \
                 SELECT ?1, id, url, title, visit_time_ms, tab FROM visits WHERE {condition}"
            ),
            params_from_iter(all.iter()),
        )?;
        let removed = transaction.execute(
            &format!("DELETE FROM visits WHERE {condition}"),
            params_from_iter(all.iter()),
        )?;
        transaction.commit()?;
        Ok(removed)
    }

    /// Removes every visit of `url` into `backup`.
    pub fn remove_url(&self, url: &str, backup: &str) -> Result<usize, HistoryError> {
        self.remove_where("url = ?2", &[&url], backup)
    }

    /// Restores the visits removed into `backup`; returns how many came back.
    /// A visit whose id was taken meanwhile comes back under a new id.
    pub fn restore(&self, backup: &str) -> Result<usize, HistoryError> {
        let transaction = self.connection.unchecked_transaction()?;
        let rows: Vec<Visit> = {
            let mut statement = transaction.prepare(
                "SELECT id, url, title, visit_time_ms, tab FROM removed_visits WHERE backup = ?1",
            )?;
            statement
                .query_map(params![backup], |row| {
                    Ok(Visit {
                        id: row.get(0)?,
                        url: row.get(1)?,
                        title: row.get(2)?,
                        at_ms: row.get(3)?,
                        tab: row.get(4)?,
                    })
                })?
                .collect::<Result<_, _>>()?
        };
        // Free ids first, so a later new id cannot take one of them.
        let mut taken = Vec::new();
        for visit in &rows {
            let inserted = transaction.execute(
                "INSERT OR IGNORE INTO visits(id, url, title, visit_time_ms, tab) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![visit.id, visit.url, visit.title, visit.at_ms, visit.tab],
            )?;
            if inserted == 0 {
                taken.push(visit);
            }
        }
        for visit in taken {
            transaction.execute(
                "INSERT INTO visits(url, title, visit_time_ms, tab) VALUES (?1, ?2, ?3, ?4)",
                params![visit.url, visit.title, visit.at_ms, visit.tab],
            )?;
        }
        transaction.execute("DELETE FROM removed_visits WHERE backup = ?1", params![backup])?;
        transaction.commit()?;
        self.fill_search()?;
        Ok(rows.len())
    }

    /// Deletes `backup` for good; returns how many visits it held.
    pub fn purge(&self, backup: &str) -> Result<usize, HistoryError> {
        Ok(self
            .connection
            .execute("DELETE FROM removed_visits WHERE backup = ?1", params![backup])?)
    }

    /// Removes every visit whose host is `host` or a subdomain of it, into
    /// `backup`.
    pub fn remove_host(&self, host: &str, backup: &str) -> Result<usize, HistoryError> {
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
        // One transaction for the whole host: all of it moves, or none.
        let transaction = self.connection.unchecked_transaction()?;
        let mut removed = 0;
        {
            let mut keep = transaction.prepare(
                "INSERT INTO removed_visits(backup, id, url, title, visit_time_ms, tab) \
                 SELECT ?1, id, url, title, visit_time_ms, tab FROM visits WHERE id = ?2",
            )?;
            let mut delete = transaction.prepare("DELETE FROM visits WHERE id = ?1")?;
            for id in ids {
                keep.execute(params![backup, id])?;
                removed += delete.execute(params![id])?;
            }
        }
        transaction.commit()?;
        Ok(removed)
    }

    /// Removes visits at or after `since_ms` (`None`: every visit), into
    /// `backup`.
    pub fn remove_since(&self, since_ms: Option<i64>, backup: &str) -> Result<usize, HistoryError> {
        let since = since_ms.unwrap_or(i64::MIN);
        self.remove_where("visit_time_ms >= ?2", &[&since], backup)
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
        // A backup never outlives normal history (ff, 2026-10-06).
        self.connection
            .execute("DELETE FROM removed_visits WHERE visit_time_ms < ?1", params![cutoff])?;
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

    /// Copies every visit of another log file of the same schema (the app's
    /// own `History.sqlite` from before the daemon owned page history) in
    /// one transaction, keeping times, titles and tabs; new ids. The other
    /// file is opened read-only and never changed. The same transaction
    /// records the file (path, size, modification time), so the same file
    /// is never imported twice, also not by another session. Returns how
    /// many visits came in (0 for a file imported before).
    pub fn import(&self, other: &Path) -> Result<usize, HistoryError> {
        let meta = std::fs::metadata(other)?;
        let modified = meta
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |elapsed| elapsed.as_nanos());
        let marker = format!("{}|{}|{modified}", other.display(), meta.len());
        let source = Connection::open_with_flags(
            other,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        source.busy_timeout(Duration::from_millis(250))?;
        let mut rows = source.prepare(
            "SELECT url, title, visit_time_ms, tab FROM visits ORDER BY visit_time_ms, id",
        )?;
        let transaction = self.connection.unchecked_transaction()?;
        let seen = transaction
            .prepare("SELECT 1 FROM imported_logs WHERE source = ?1")?
            .exists(params![marker])?;
        if seen {
            return Ok(0);
        }
        let mut imported = 0;
        {
            let mut insert = transaction.prepare(
                "INSERT INTO visits(url, title, visit_time_ms, tab) VALUES (?1, ?2, ?3, ?4)",
            )?;
            let mut cursor = rows.query([])?;
            while let Some(row) = cursor.next()? {
                let (url, title, at_ms, tab): (String, Option<String>, i64, Option<String>) =
                    (row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?);
                imported += insert.execute(params![url, title, at_ms, tab])?;
            }
        }
        transaction.execute(
            "INSERT INTO imported_logs(source, visits) VALUES (?1, ?2)",
            params![marker, i64::try_from(imported).unwrap_or(i64::MAX)],
        )?;
        transaction.commit()?;
        self.fill_search()?;
        Ok(imported)
    }

    pub fn count(&self) -> Result<u64, HistoryError> {
        let count: i64 =
            self.connection.query_row("SELECT COUNT(*) FROM visits", [], |row| row.get(0))?;
        Ok(count.unsigned_abs())
    }
}

/// The folded text a search matches: URL and title.
fn search_text(url: &str, title: Option<&str>) -> String {
    fold(&format!("{url} {}", title.unwrap_or_default()))
}

/// Escapes `LIKE` wildcards with backslash.
fn escape_like(text: &str) -> String {
    text.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}
