//! A connection's SQLite page cache: how much it holds and giving it back.
//!
//! Chrome's `sql::Database::TrimMemory()` (sql/database.cc) calls
//! `sqlite3_db_release_memory` on one connection, on that connection's own
//! sequence, when memory is short. It frees the clean pages no statement
//! holds; the next query reads them again from the file (or the OS cache).
//! It never calls the process-wide `sqlite3_release_memory`, which would
//! reach connections that other threads use at that moment.

use rusqlite::{Connection, ffi};

use crate::error::HistoryError;

/// Frees `connection`'s unused page cache (`sqlite3_db_release_memory`).
/// The caller is the connection's owner: `Connection` is not `Sync`, so a
/// shared borrow on this thread is exclusive use. An in-memory database
/// keeps its pages: they are its only copy.
pub fn release(connection: &Connection) -> Result<(), HistoryError> {
    Ok(connection.release_memory()?)
}

/// The heap bytes `connection`'s page caches hold now
/// (`SQLITE_DBSTATUS_CACHE_USED`), or `None` when SQLite refuses the query.
#[allow(unsafe_code)] // rusqlite has no safe `sqlite3_db_status`; SAFETY below.
pub fn cache_used_bytes(connection: &Connection) -> Option<u64> {
    let mut current = 0;
    let mut highwater = 0;
    // SAFETY: the handle is valid for `connection`'s borrow and this thread
    // has exclusive use of it (`Connection` is not `Sync`); the two out
    // pointers are live locals.
    let status = unsafe {
        ffi::sqlite3_db_status(
            connection.handle(),
            ffi::SQLITE_DBSTATUS_CACHE_USED,
            &mut current,
            &mut highwater,
            0,
        )
    };
    (status == ffi::SQLITE_OK).then(|| u64::try_from(current).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Runs `read` until the cache holds more than `min` bytes; returns what
    /// it holds. SQLite here shares one page cache LRU between every
    /// connection of the process (`SQLITE_ENABLE_MEMORY_MANAGEMENT`), and a
    /// connection that closes in a parallel test evicts LRU pages of the
    /// others, so a read is repeated when that emptied the cache first.
    fn filled(read: impl Fn(), cache: impl Fn() -> Option<u64>, min: u64) -> u64 {
        let mut bytes = 0;
        for _ in 0..5 {
            read();
            bytes = cache().unwrap();
            if bytes > min {
                return bytes;
            }
        }
        panic!("five reads left {bytes} bytes in the page cache");
    }

    /// A file database after a 10k-row query holds about 1 MB of page cache
    /// (under its 2 MB cap); a release brings it near 0, and the next query
    /// reads the rows again.
    #[test]
    fn sqlite_trim_release_frees_the_cache_a_10k_row_query_filled() {
        let dir = temp_dir("rows");
        let connection = Connection::open(dir.join("cache.sqlite")).unwrap();
        connection
            .execute_batch(
                "PRAGMA journal_mode=WAL;
                 CREATE TABLE rows(id INTEGER PRIMARY KEY, text TEXT NOT NULL);
                 WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10000)
                 INSERT INTO rows(text) SELECT printf('%0100d', i) FROM n;",
            )
            .unwrap();
        let total = || -> i64 {
            connection
                .query_row("SELECT SUM(LENGTH(text)) FROM rows", [], |row| row.get(0))
                .unwrap()
        };
        let read = || assert_eq!(total(), 1_000_000, "the rows read (again after a release)");
        let filled = filled(read, || cache_used_bytes(&connection), 500_000);

        release(&connection).unwrap();
        let trimmed = cache_used_bytes(&connection).unwrap();
        assert!(trimmed < 32 * 1024, "release leaves {trimmed} of {filled} bytes");

        read();
        drop(connection);
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("cmux-history-page-cache-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Every open visit log frees its cache; the visits read again.
    #[test]
    fn sqlite_trim_visit_stores_release_every_open_log() {
        let dir = temp_dir("visits");
        let mut stores = crate::VisitStores::new(&dir);
        for at_ms in 0..2000 {
            let visit = crate::NewVisit {
                url: format!("https://example.com/{at_ms}/{}", "p".repeat(200)),
                title: Some("t".repeat(100)),
                tab: None,
                at_ms,
            };
            stores.record("default", &visit).unwrap();
        }
        let store = stores.store("default").unwrap();
        let read = || assert_eq!(store.summaries(5000).unwrap().len(), 2000);
        let filled = filled(read, || store.cache_used_bytes(), 128 * 1024);

        stores.release_memory().unwrap();
        let store = stores.store("default").unwrap();
        let trimmed = store.cache_used_bytes().unwrap();
        assert!(trimmed < 32 * 1024, "release left {trimmed} of {filled} bytes");
        assert_eq!(store.summaries(5000).unwrap().len(), 2000);
        drop(stores);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The search index frees its cache; a search still finds the docs.
    #[test]
    fn sqlite_trim_search_index_release_frees_its_cache() {
        let dir = temp_dir("search");
        let mut index = crate::SearchIndex::open(&dir.join("search.sqlite")).unwrap();
        let docs: Vec<crate::SearchDoc> = (0..2000)
            .map(|i| crate::SearchDoc {
                key: format!("doc-{i}"),
                source: "shell:1".into(),
                kind: crate::SearchKind::Command,
                target: "terminal-1".into(),
                position: Some(i),
                title: "build".into(),
                text: format!("cargo test --package number{i} {}", "x".repeat(100)),
                at_ms: i,
            })
            .collect();
        index.append("shell:1", &docs, Some(2000)).unwrap();
        let read = || assert_eq!(index.search("cargo test", &[], 2000).unwrap().len(), 2000);
        let filled = filled(read, || index.cache_used_bytes(), 128 * 1024);

        index.release_memory().unwrap();
        let trimmed = index.cache_used_bytes().unwrap();
        assert!(trimmed < 32 * 1024, "release left {trimmed} of {filled} bytes");
        assert_eq!(index.search("number1999", &[], 10).unwrap().len(), 1);
        drop(index);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
