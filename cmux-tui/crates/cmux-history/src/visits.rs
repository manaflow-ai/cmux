//! The page visit log of one browser profile: port of Swift
//! `BrowserVisitLog` and `HistorySQLite`. One SQLite file per profile, after
//! Chromium's `History` model, opened in WAL mode with one connection.
//! Incognito never gets one.

use std::collections::HashMap;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OptionalExtension, params, params_from_iter};
use sha2::{Digest, Sha256};
use url::Url;

use crate::entry::{HistoryEntry, HistoryKind};
use crate::error::HistoryError;
use crate::fold::{fold, tokens};
use crate::query::ActorFilter;
use crate::search_syntax::SearchFilter;

/// Visits older than 90 days are pruned.
pub const RETENTION_MS: i64 = 90 * 86_400_000;
/// At most 100,000 visits per profile; prune drops the oldest beyond it.
pub const MAX_VISITS: usize = 100_000;
/// Main database plus WAL/SHM accepted from the app-local legacy store.
const MAX_IMPORT_FILE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_IMPORT_URL_BYTES: i64 = 8_192;
const MAX_IMPORT_TITLE_BYTES: i64 = 1_024;
const MAX_IMPORT_TAB_BYTES: i64 = 1_024;

const SCHEMA_VERSION: i64 = 4;

/// A finished main-frame navigation to record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewVisit {
    pub url: String,
    pub title: Option<String>,
    /// The tab (`<machine>/<tab id>`) that visited it, when known.
    pub tab: Option<String>,
    /// The driver of the visit. Legacy callers default to the person.
    pub actor: Option<VisitActor>,
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
    pub actor: VisitActor,
}

/// Provenance of a page visit. Agent session ids may be unavailable for
/// restored or older agent tabs, so the session is nullable by design.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VisitActor {
    Person,
    Agent { session_id: Option<String> },
}

impl VisitActor {
    fn db_values(&self) -> (&'static str, Option<&str>) {
        match self {
            Self::Person => ("person", None),
            Self::Agent { session_id } => ("agent", session_id.as_deref()),
        }
    }

    fn from_db(actor: String, session_id: Option<String>) -> Self {
        if actor == "agent" { Self::Agent { session_id } } else { Self::Person }
    }

    pub fn is_agent(&self) -> bool {
        matches!(self, Self::Agent { .. })
    }
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
        entry.actor = Some(if self.actor.is_agent() { "agent".into() } else { "person".into() });
        if let VisitActor::Agent { session_id } = &self.actor {
            entry.session_id = session_id.clone();
        }
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
    ///
    /// A file SQLite cannot read (not a database, or corrupt) is moved aside with its WAL and
    /// shared-memory files, never deleted (`<name>.corrupt-<ms>`), and a new log opens in its
    /// place: one bad file must not keep the profile's history off until someone deletes it.
    pub fn open(path: &Path) -> Result<Self, HistoryError> {
        if let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        match Self::prepare(Connection::open(path)?) {
            Err(HistoryError::Sqlite(error)) if is_unreadable_database(&error) => {
                move_aside(path)?;
                Self::prepare(Connection::open(path)?)
            }
            other => other,
        }
    }

    /// A log that lives in memory only (tests, demos).
    pub fn open_in_memory() -> Result<Self, HistoryError> {
        Self::prepare(Connection::open_in_memory()?)
    }

    fn prepare(connection: Connection) -> Result<Self, HistoryError> {
        connection.busy_timeout(Duration::from_millis(250))?;
        connection
            .pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get::<_, String>(0))?;
        let transaction = connection.unchecked_transaction()?;
        transaction.execute_batch(
            "CREATE TABLE IF NOT EXISTS visits(
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
               source TEXT PRIMARY KEY, visits INTEGER NOT NULL);",
        )?;
        for table in ["visits", "removed_visits"] {
            for (name, definition) in
                [("actor", "TEXT NOT NULL DEFAULT 'person'"), ("session_id", "TEXT")]
            {
                let present = transaction
                    .prepare(&format!(
                        "SELECT 1 FROM pragma_table_info('{table}') WHERE name = ?1"
                    ))?
                    .exists([name])?;
                if !present {
                    transaction.execute(
                        &format!("ALTER TABLE {table} ADD COLUMN {name} {definition}"),
                        [],
                    )?;
                }
            }
        }
        let searchable = transaction
            .prepare("SELECT 1 FROM pragma_table_info('visits') WHERE name = 'search'")?
            .exists([])?;
        if !searchable {
            transaction.execute_batch("ALTER TABLE visits ADD COLUMN search TEXT")?;
        }
        transaction.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        transaction.commit()?;
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
        let (actor, session_id) =
            visit.actor.as_ref().map_or(("person", None), VisitActor::db_values);
        self.connection.execute(
            "INSERT INTO visits(url, title, visit_time_ms, tab, search, actor, session_id) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                visit.url,
                visit.title,
                visit.at_ms,
                visit.tab,
                search_text(&visit.url, visit.title.as_deref()),
                actor,
                session_id
            ],
        )?;
        Ok(self.connection.last_insert_rowid())
    }

    /// Sets the title of `url`'s newest visit (titles arrive after the load).
    /// Returns the number of visits changed (0 or 1): a page that announces the title it already
    /// has changes none and writes nothing.
    pub fn update_title(&self, url: &str, title: &str) -> Result<usize, HistoryError> {
        Ok(self.connection.execute(
            "UPDATE visits SET title = ?1, search = ?3 WHERE id = \
             (SELECT id FROM visits WHERE url = ?2 AND actor = 'person' \
              ORDER BY visit_time_ms DESC, id DESC LIMIT 1) \
             AND title IS NOT ?1",
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
        let filter =
            SearchFilter::<HistoryKind> { after_ms: since_ms, ..SearchFilter::words(tokens(text)) };
        self.visits_matching(&filter, limit)
    }

    /// Visits newest first that `filter`'s words, exclusions and time window
    /// pass, all in SQL so the limit applies after the filter. Its kinds are
    /// the caller's to check.
    pub fn visits_matching(
        &self,
        filter: &SearchFilter<HistoryKind>,
        limit: usize,
    ) -> Result<Vec<Visit>, HistoryError> {
        self.visits_matching_with_actor(filter, limit, ActorFilter::Mine)
    }

    pub fn visits_matching_with_actor(
        &self,
        filter: &SearchFilter<HistoryKind>,
        limit: usize,
        actor_filter: ActorFilter,
    ) -> Result<Vec<Visit>, HistoryError> {
        let mut sql = String::from(
            "SELECT id, url, title, visit_time_ms, tab, actor, session_id FROM visits WHERE visit_time_ms >= ?",
        );
        let mut bindings = vec![Sql::Integer(filter.after_ms.unwrap_or(0))];
        if let Some(before) = filter.before_ms {
            sql.push_str(" AND visit_time_ms < ?");
            bindings.push(Sql::Integer(before));
        }
        // The `search` column is folded, so the words are too.
        for word in &filter.words {
            sql.push_str(" AND search LIKE ? ESCAPE '\\'");
            bindings.push(Sql::Text(format!("%{}%", escape_like(&fold(word)))));
        }
        for word in &filter.excluded {
            sql.push_str(" AND search NOT LIKE ? ESCAPE '\\'");
            bindings.push(Sql::Text(format!("%{}%", escape_like(&fold(word)))));
        }
        match actor_filter {
            ActorFilter::Mine => sql.push_str(" AND actor = 'person'"),
            ActorFilter::Agents => sql.push_str(" AND actor = 'agent'"),
            ActorFilter::All => {}
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
                actor: VisitActor::from_db(row.get(5)?, row.get(6)?),
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// [`VisitStore::visits_matching`] as wire entries of `profile`.
    pub fn entries(
        &self,
        profile: &str,
        filter: &SearchFilter<HistoryKind>,
        limit: usize,
        actor_filter: ActorFilter,
    ) -> Result<Vec<HistoryEntry>, HistoryError> {
        Ok(self
            .visits_matching_with_actor(filter, limit, actor_filter)?
            .iter()
            .map(|visit| visit.entry(profile))
            .collect())
    }

    /// One row per URL the person visited (agent visits are left out), most recent first.
    ///
    /// One sequential scan of the table (rowid order, no index walk): each URL keeps its count,
    /// its last visit and the title of its newest titled visit, then the URLs sort by last
    /// visit. The `GROUP BY` with a title subquery per URL it replaced grew faster than the log
    /// (4.3x the per-visit cost from 10k to 100k visits).
    pub fn summaries(&self, limit: usize) -> Result<Vec<VisitSummary>, HistoryError> {
        struct Sum {
            summary: VisitSummary,
            titled_ms: i64,
        }
        let mut statement = self
            .connection
            .prepare("SELECT url, title, visit_time_ms FROM visits WHERE actor = 'person'")?;
        let mut at: HashMap<String, usize> = HashMap::new();
        let mut sums: Vec<Sum> = Vec::new();
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            let url = row.get_ref(0)?.as_str().map_err(rusqlite::Error::from)?;
            let visit_ms: i64 = row.get(2)?;
            let index = match at.get(url) {
                Some(&index) => index,
                None => {
                    let index = sums.len();
                    at.insert(url.to_owned(), index);
                    sums.push(Sum {
                        summary: VisitSummary {
                            url: url.to_owned(),
                            title: None,
                            visit_count: 0,
                            last_visit_ms: visit_ms,
                        },
                        titled_ms: i64::MIN,
                    });
                    index
                }
            };
            // `at` only holds indexes into `sums`, so this always finds the entry.
            let Some(sum) = sums.get_mut(index) else {
                continue;
            };
            sum.summary.visit_count = sum.summary.visit_count.saturating_add(1);
            sum.summary.last_visit_ms = sum.summary.last_visit_ms.max(visit_ms);
            // The title of the newest visit that has one. A URL's visits mostly repeat its title:
            // a newer one that matches only moves the time, with no copy.
            if (sum.summary.title.is_none() || visit_ms > sum.titled_ms)
                && let Some(title) =
                    row.get_ref(1)?.as_str_or_null().map_err(rusqlite::Error::from)?
            {
                if sum.summary.title.as_deref() != Some(title) {
                    sum.summary.title = Some(title.to_owned());
                }
                sum.titled_ms = visit_ms;
            }
        }
        let mut out: Vec<VisitSummary> = sums.into_iter().map(|sum| sum.summary).collect();
        out.sort_unstable_by_key(|summary| std::cmp::Reverse(summary.last_visit_ms));
        out.truncate(limit);
        Ok(out)
    }

    /// The visit with `id`, if it exists.
    pub fn visit(&self, id: i64) -> Result<Option<Visit>, HistoryError> {
        Ok(self
            .connection
            .query_row(
                "SELECT id, url, title, visit_time_ms, tab, actor, session_id FROM visits WHERE id = ?1",
                params![id],
                |row| {
                    Ok(Visit {
                        id: row.get(0)?,
                        url: row.get(1)?,
                        title: row.get(2)?,
                        at_ms: row.get(3)?,
                        tab: row.get(4)?,
                        actor: VisitActor::from_db(row.get(5)?, row.get(6)?),
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
                "INSERT INTO removed_visits(backup, id, url, title, visit_time_ms, tab, actor, session_id) \
                 SELECT ?1, id, url, title, visit_time_ms, tab, actor, session_id FROM visits WHERE {condition}"
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
                "SELECT id, url, title, visit_time_ms, tab, actor, session_id FROM removed_visits WHERE backup = ?1",
            )?;
            statement
                .query_map(params![backup], |row| {
                    Ok(Visit {
                        id: row.get(0)?,
                        url: row.get(1)?,
                        title: row.get(2)?,
                        at_ms: row.get(3)?,
                        tab: row.get(4)?,
                        actor: VisitActor::from_db(row.get(5)?, row.get(6)?),
                    })
                })?
                .collect::<Result<_, _>>()?
        };
        // Free ids first, so a later new id cannot take one of them.
        let mut taken = Vec::new();
        for visit in &rows {
            let inserted = transaction.execute(
                "INSERT OR IGNORE INTO visits(id, url, title, visit_time_ms, tab, actor, session_id, search) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![visit.id, visit.url, visit.title, visit.at_ms, visit.tab, visit.actor.db_values().0, visit.actor.db_values().1, search_text(&visit.url, visit.title.as_deref())],
            )?;
            if inserted == 0 {
                taken.push(visit);
            }
        }
        for visit in taken {
            transaction.execute(
                "INSERT INTO visits(url, title, visit_time_ms, tab, actor, session_id, search) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![visit.url, visit.title, visit.at_ms, visit.tab, visit.actor.db_values().0, visit.actor.db_values().1, search_text(&visit.url, visit.title.as_deref())],
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
                "INSERT INTO removed_visits(backup, id, url, title, visit_time_ms, tab, actor, session_id) \
                 SELECT ?1, id, url, title, visit_time_ms, tab, actor, session_id FROM visits WHERE id = ?2",
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
        self.remove_between(since_ms, i64::MAX, backup)
    }

    /// Removes visits at or after `since_ms` (`None`: from the first) and at
    /// or before `until_ms`, into `backup`.
    pub fn remove_between(
        &self,
        since_ms: Option<i64>,
        until_ms: i64,
        backup: &str,
    ) -> Result<usize, HistoryError> {
        let since = since_ms.unwrap_or(i64::MIN);
        self.remove_where(
            "visit_time_ms >= ?2 AND visit_time_ms <= ?3",
            &[&since, &until_ms],
            backup,
        )
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
    /// records the path and validated row digest, so the same generation is
    /// never imported twice, also not by another session. Returns how
    /// many visits came in (0 for a file imported before).
    pub fn import(&self, other: &Path) -> Result<usize, HistoryError> {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|elapsed| i64::try_from(elapsed.as_millis()).ok())
            .unwrap_or(0);
        self.import_at(other, now_ms)
    }

    /// [`VisitStore::import`] at an explicit retention time.
    pub fn import_at(&self, other: &Path, now_ms: i64) -> Result<usize, HistoryError> {
        Self::import_metadata(other)?;
        let mut source = Connection::open_with_flags(
            other,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
                | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
                | rusqlite::OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        source.busy_timeout(Duration::from_millis(250))?;
        let source_transaction = source.transaction()?;
        // Establish one WAL snapshot. Every validation and copied row below
        // belongs to that same snapshot.
        let _: i64 =
            source_transaction
                .query_row("SELECT COUNT(*) FROM sqlite_schema", [], |row| row.get(0))?;
        let page_count: i64 =
            source_transaction.query_row("PRAGMA page_count", [], |row| row.get(0))?;
        let page_size: i64 =
            source_transaction.query_row("PRAGMA page_size", [], |row| row.get(0))?;
        let logical_bytes = (page_count.max(0) as u64).saturating_mul(page_size.max(0) as u64);
        if logical_bytes > MAX_IMPORT_FILE_BYTES {
            return Err(HistoryError::InvalidImport(format!(
                "source is too large (maximum {MAX_IMPORT_FILE_BYTES} bytes)"
            )));
        }
        let (visits, url_bytes, title_bytes, tab_bytes): (i64, i64, i64, i64) = source_transaction
            .query_row(
                "SELECT COUNT(*),
                        COALESCE(MAX(length(CAST(url AS BLOB))), 0),
                        COALESCE(MAX(length(CAST(title AS BLOB))), 0),
                        COALESCE(MAX(length(CAST(tab AS BLOB))), 0)
                 FROM (SELECT url, title, tab FROM visits LIMIT ?1)",
                [i64::try_from(MAX_VISITS + 1).unwrap_or(i64::MAX)],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )?;
        if visits > i64::try_from(MAX_VISITS).unwrap_or(i64::MAX) {
            return Err(HistoryError::InvalidImport(format!(
                "too many visits (maximum {MAX_VISITS})"
            )));
        }
        if url_bytes > MAX_IMPORT_URL_BYTES
            || title_bytes > MAX_IMPORT_TITLE_BYTES
            || tab_bytes > MAX_IMPORT_TAB_BYTES
        {
            return Err(HistoryError::InvalidImport("a visit field is too large".into()));
        }
        let source_has_actor = source_transaction
            .prepare("SELECT 1 FROM pragma_table_info('visits') WHERE name = 'actor'")?
            .exists([])?;
        let source_columns = if source_has_actor {
            "url, title, visit_time_ms, tab, actor, session_id"
        } else {
            "url, title, visit_time_ms, tab, NULL AS actor, NULL AS session_id"
        };
        let mut rows = source_transaction.prepare(&format!(
            "SELECT typeof(url), length(CAST(url AS BLOB)),
                    typeof(title), COALESCE(length(CAST(title AS BLOB)), 0),
                    typeof(visit_time_ms),
                    typeof(tab), COALESCE(length(CAST(tab AS BLOB)), 0),
                    {source_columns}
             FROM visits ORDER BY visit_time_ms, id LIMIT ?1"
        ))?;
        let transaction = self.connection.unchecked_transaction()?;
        let mut imported = 0;
        let mut imported_digest = Sha256::new();
        imported_digest.update(other.to_string_lossy().as_bytes());
        {
            let mut insert = transaction.prepare(
                "INSERT INTO visits(url, title, visit_time_ms, tab, actor, session_id) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )?;
            let mut cursor = rows.query([i64::try_from(MAX_VISITS + 1).unwrap_or(i64::MAX)])?;
            while let Some(row) = cursor.next()? {
                if imported >= MAX_VISITS {
                    return Err(HistoryError::InvalidImport(format!(
                        "too many visits (maximum {MAX_VISITS})"
                    )));
                }
                let url_kind: String = row.get(0)?;
                let url_bytes: i64 = row.get(1)?;
                let title_kind: String = row.get(2)?;
                let title_bytes: i64 = row.get(3)?;
                let time_kind: String = row.get(4)?;
                let tab_kind: String = row.get(5)?;
                let tab_bytes: i64 = row.get(6)?;
                if url_kind != "text"
                    || !matches!(title_kind.as_str(), "null" | "text")
                    || time_kind != "integer"
                    || !matches!(tab_kind.as_str(), "null" | "text")
                {
                    return Err(HistoryError::InvalidImport(
                        "a visit field has the wrong type".into(),
                    ));
                }
                if url_bytes > MAX_IMPORT_URL_BYTES
                    || title_bytes > MAX_IMPORT_TITLE_BYTES
                    || tab_bytes > MAX_IMPORT_TAB_BYTES
                {
                    return Err(HistoryError::InvalidImport("a visit field is too large".into()));
                }
                let (url, title, at_ms, tab, actor, session_id): (
                    String,
                    Option<String>,
                    i64,
                    Option<String>,
                    Option<String>,
                    Option<String>,
                ) = (
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                    row.get(12)?,
                );
                imported_digest.update((url.len() as u64).to_le_bytes());
                imported_digest.update(url.as_bytes());
                match &title {
                    Some(title) => {
                        imported_digest.update([1]);
                        imported_digest.update((title.len() as u64).to_le_bytes());
                        imported_digest.update(title.as_bytes());
                    }
                    None => imported_digest.update([0]),
                }
                imported_digest.update(at_ms.to_le_bytes());
                match &tab {
                    Some(tab) => {
                        imported_digest.update([1]);
                        imported_digest.update((tab.len() as u64).to_le_bytes());
                        imported_digest.update(tab.as_bytes());
                    }
                    None => imported_digest.update([0]),
                }
                // Anything but an explicit agent row is the person's; only agent rows keep a session.
                let (actor, session_id) = if actor.as_deref() == Some("agent") {
                    ("agent", session_id.filter(|id| id.len() as i64 <= MAX_IMPORT_TAB_BYTES))
                } else {
                    ("person", None)
                };
                imported += insert.execute(params![url, title, at_ms, tab, actor, session_id])?;
            }
        }
        drop(rows);
        source_transaction.commit()?;
        let digest = imported_digest.finalize();
        let digest = digest.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let marker = format!("v4|{}|{digest}", other.display());
        let seen = transaction
            .prepare("SELECT 1 FROM imported_logs WHERE source = ?1")?
            .exists(params![marker])?;
        if seen {
            return Ok(0);
        }
        transaction.execute(
            "INSERT INTO imported_logs(source, visits) VALUES (?1, ?2)",
            params![marker, i64::try_from(imported).unwrap_or(i64::MAX)],
        )?;
        let cutoff = now_ms.saturating_sub(RETENTION_MS);
        transaction
            .execute("DELETE FROM removed_visits WHERE visit_time_ms < ?1", params![cutoff])?;
        transaction.execute("DELETE FROM visits WHERE visit_time_ms < ?1", params![cutoff])?;
        transaction.execute(
            "DELETE FROM visits WHERE id IN
             (SELECT id FROM visits ORDER BY visit_time_ms DESC, id DESC LIMIT -1 OFFSET ?1)",
            params![i64::try_from(MAX_VISITS).unwrap_or(i64::MAX)],
        )?;
        transaction.commit()?;
        self.fill_search()?;
        Ok(imported)
    }

    /// Size and latest modification of the legacy database and its SQLite
    /// sidecars. Every present component must be a regular file, never a link.
    fn import_metadata(path: &Path) -> Result<(), HistoryError> {
        let mut bytes = 0_u64;
        for suffix in ["", "-wal", "-shm"] {
            let candidate = if suffix.is_empty() {
                path.to_path_buf()
            } else {
                let mut name = path.as_os_str().to_os_string();
                name.push(suffix);
                name.into()
            };
            let metadata = match std::fs::symlink_metadata(&candidate) {
                Ok(metadata) => metadata,
                Err(error)
                    if !suffix.is_empty() && error.kind() == std::io::ErrorKind::NotFound =>
                {
                    continue;
                }
                Err(error) => return Err(error.into()),
            };
            if !metadata.file_type().is_file() {
                return Err(HistoryError::InvalidImport(
                    "source and sidecars must be regular files".into(),
                ));
            }
            bytes = bytes.saturating_add(metadata.len());
            if bytes > MAX_IMPORT_FILE_BYTES {
                return Err(HistoryError::InvalidImport(format!(
                    "source is too large (maximum {MAX_IMPORT_FILE_BYTES} bytes)"
                )));
            }
        }
        Ok(())
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

/// SQLite said the file is not a database, or is corrupt. Any other failure (busy, locked, out of
/// space, permission) leaves the file where it is: it may be fine on the next open.
fn is_unreadable_database(error: &rusqlite::Error) -> bool {
    matches!(
        error.sqlite_error_code(),
        Some(rusqlite::ErrorCode::NotADatabase | rusqlite::ErrorCode::DatabaseCorrupt)
    )
}

/// Renames `path` and its `-wal` and `-shm` files to `<name>.corrupt-<ms>[-<n>]` beside it, a
/// name no earlier one has, so a second bad file never replaces the first kept. Nothing is
/// deleted. The new names do not end in `.sqlite`, so they are never read as a profile's log.
fn move_aside(path: &Path) -> Result<(), HistoryError> {
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("visits.sqlite");
    let millis = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis());
    let taken = |stem: &str| {
        ["", "-wal", "-shm"]
            .iter()
            .any(|suffix| path.with_file_name(format!("{stem}{suffix}")).exists())
    };
    let mut stem = format!("{name}.corrupt-{millis}");
    let mut n = 1;
    while taken(&stem) {
        stem = format!("{name}.corrupt-{millis}-{n}");
        n += 1;
    }
    for suffix in ["", "-wal", "-shm"] {
        let from = path.with_file_name(format!("{name}{suffix}"));
        match std::fs::rename(&from, path.with_file_name(format!("{stem}{suffix}"))) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    // The renames last past a crash (docs/handbook rename-without-directory-sync); best effort:
    // the kept file is there either way.
    if let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        let _ = std::fs::File::open(parent).and_then(|dir| dir.sync_all());
    }
    Ok(())
}

#[cfg(test)]
#[path = "visits_summaries_tests.rs"]
mod summaries_tests;
