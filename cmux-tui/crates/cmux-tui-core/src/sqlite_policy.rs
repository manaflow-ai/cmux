//! The SQLite error policy of the daemon's own stores, after Chromium's
//! `sql::Database` error callback and `sql::Recovery` (sql/database.cc,
//! sql/recovery.cc), which raze a corrupt database instead of crashing:
//!
//! - every connection waits [`BUSY_TIMEOUT`] for a lock instead of failing
//!   at once with `SQLITE_BUSY`;
//! - a file SQLite reports corrupt or not a database (`SQLITE_CORRUPT`,
//!   `SQLITE_NOTADB`) is moved aside to `<name>.corrupt` with its sidecars,
//!   a new store is created at the path, and one fault is reported;
//! - the open is tried at most twice: a store that still fails after the set
//!   aside returns that error, so a start never loops on it.
//!
//! Stores another program owns (harness stores, imports) are never moved:
//! they open read-only and a corrupt one is an error for that read alone.
//! The workspace registry keeps its own quarantine (`open_guard.rs`), which
//! fails one start so the session's journal is never replaced silently.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::Context as _;
use cmux_threads::checked::fs as files;
use rusqlite::{Connection, ErrorCode};

/// How long a daemon store connection waits for another connection's lock.
pub(crate) const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// The sidecars SQLite keeps beside a database. The rollback journal must
/// move with the file: SQLite would roll it back into the new store.
const SIDECAR_SUFFIXES: [&str; 3] = ["-wal", "-journal", "-shm"];

/// One unreadable store moved aside and recreated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SetAside {
    /// The store's name (`chief_registry`, `conversation_store`, ...).
    pub(crate) store: &'static str,
    pub(crate) database: PathBuf,
    /// Where the unreadable file went (`<name>.corrupt`, or
    /// `<name>.corrupt-<n>` when that exists).
    pub(crate) aside: PathBuf,
    /// SQLite's message for the failed read.
    pub(crate) reason: String,
}

/// Where a store reports the fault of a set-aside. The daemon logs it;
/// tests count it.
pub(crate) trait SqliteFaults {
    fn set_aside(&self, event: &SetAside);
}

/// The daemon's fault report: one `ERROR` line in its log, which the app's
/// error journal harvests.
pub(crate) struct LoggedFaults;

impl SqliteFaults for LoggedFaults {
    fn set_aside(&self, event: &SetAside) {
        eprintln!(
            "cmux-tui: ERROR sqlite store {} was unreadable ({}); moved {} to {} and started a new one",
            event.store,
            event.reason,
            event.database.display(),
            event.aside.display()
        );
    }
}

/// SQLite's message when `error` (or its cause) is `SQLITE_CORRUPT` or
/// `SQLITE_NOTADB`. A schema this SQLite cannot parse ("malformed database
/// schema") is excluded: a newer build may have written it, and moving it
/// aside would lose that build's data.
pub(crate) fn unreadable_reason(error: &anyhow::Error) -> Option<String> {
    let sqlite = error.chain().find_map(|cause| cause.downcast_ref::<rusqlite::Error>())?;
    let unreadable = matches!(
        sqlite.sqlite_error_code(),
        Some(ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase)
    );
    let reason = sqlite.to_string();
    (unreadable && !reason.contains("malformed database schema")).then_some(reason)
}

/// Reads the schema once, so an unreadable file fails the open rather than
/// the first request (a connection opens lazily and reads no page).
pub(crate) fn probe(connection: &Connection) -> rusqlite::Result<()> {
    connection.query_row("SELECT count(*) FROM sqlite_master", [], |row| row.get::<_, i64>(0))?;
    Ok(())
}

/// Runs `open` on `path`; when it fails because the file is unreadable,
/// moves the file aside, reports one fault to `faults` and runs `open` once
/// more on the now empty path. `open` must drop every connection it made
/// before it returns an error (the file is renamed next).
pub(crate) fn open_own_store<T>(
    store: &'static str,
    path: &Path,
    faults: &dyn SqliteFaults,
    mut open: impl FnMut(&Path) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let error = match open(path) {
        Ok(opened) => return Ok(opened),
        Err(error) => error,
    };
    let Some(reason) = unreadable_reason(&error) else {
        return Err(error);
    };
    let aside = match move_aside(path) {
        Ok(aside) => aside,
        Err(move_error) => {
            return Err(error.context(format!(
                "{store} is unreadable and could not be moved aside: {move_error:#}"
            )));
        }
    };
    faults.set_aside(&SetAside { store, database: path.to_path_buf(), aside, reason });
    open(path).with_context(|| format!("create a new {store} at {}", path.display()))
}

/// Moves the database to `<name>.corrupt` (never over an earlier one) and
/// each sidecar to the same name plus its suffix, database first.
pub(crate) fn move_aside(path: &Path) -> anyhow::Result<PathBuf> {
    let aside = free_aside_path(path)?;
    files::rename(path, &aside)
        .with_context(|| format!("move {} to {}", path.display(), aside.display()))?;
    for suffix in SIDECAR_SUFFIXES {
        let sidecar = with_suffix(path, suffix);
        if !sidecar.exists() {
            continue;
        }
        if files::rename(&sidecar, with_suffix(&aside, suffix)).is_err() {
            // A sidecar left beside the new store would be replayed into it.
            files::remove_file(&sidecar)
                .with_context(|| format!("remove stale {}", sidecar.display()))?;
        }
    }
    if let Some(directory) = path.parent() {
        let _ = crate::platform::sync_directory(directory);
    }
    Ok(aside)
}

fn free_aside_path(path: &Path) -> anyhow::Result<PathBuf> {
    let first = with_suffix(path, ".corrupt");
    if !first.exists() {
        return Ok(first);
    }
    (1u32..1000)
        .map(|attempt| with_suffix(path, &format!(".corrupt-{attempt}")))
        .find(|candidate| !candidate.exists())
        .with_context(|| format!("no free .corrupt name beside {}", path.display()))
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

/// A fault sink that records each set-aside (tests).
#[cfg(test)]
#[derive(Default)]
pub(crate) struct RecordedFaults(std::cell::RefCell<Vec<SetAside>>);

#[cfg(test)]
impl SqliteFaults for RecordedFaults {
    fn set_aside(&self, event: &SetAside) {
        self.0.borrow_mut().push(event.clone());
    }
}

#[cfg(test)]
impl RecordedFaults {
    pub(crate) fn taken(&self) -> Vec<SetAside> {
        self.0.take()
    }
}

/// A fresh directory under the temp dir, removed on drop (tests).
#[cfg(test)]
pub(crate) struct TestDir(PathBuf);

#[cfg(test)]
impl TestDir {
    pub(crate) fn new() -> Self {
        let mut bytes = [0u8; 8];
        getrandom::fill(&mut bytes).unwrap();
        let name: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let dir = std::env::temp_dir().join(format!("cmux-sqlite-policy-{name}"));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    pub(crate) fn path(&self) -> &Path {
        &self.0
    }
}

#[cfg(test)]
impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open_probed(path: &Path) -> anyhow::Result<Connection> {
        let connection = Connection::open(path)?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        probe(&connection)?;
        connection.execute_batch("CREATE TABLE IF NOT EXISTS t (v TEXT)")?;
        Ok(connection)
    }

    #[test]
    fn a_garbage_file_is_set_aside_and_the_store_recreated() {
        let dir = TestDir::new();
        let path = dir.path().join("store.sqlite3");
        std::fs::write(&path, vec![0x5a_u8; 8192]).unwrap();
        let faults = RecordedFaults::default();

        let connection = open_own_store("test_store", &path, &faults, open_probed).unwrap();

        connection.execute("INSERT INTO t VALUES ('kept')", []).unwrap();
        let events = faults.taken();
        assert_eq!(events.len(), 1, "one fault: {events:?}");
        assert_eq!(events[0].store, "test_store");
        assert_eq!(events[0].aside, dir.path().join("store.sqlite3.corrupt"));
        assert_eq!(std::fs::read(&events[0].aside).unwrap(), vec![0x5a_u8; 8192]);
    }

    #[test]
    fn every_sidecar_moves_aside_with_its_database() {
        let dir = TestDir::new();
        let path = dir.path().join("store.sqlite3");
        std::fs::write(&path, b"database").unwrap();
        for suffix in SIDECAR_SUFFIXES {
            std::fs::write(with_suffix(&path, suffix), suffix).unwrap();
        }

        let aside = move_aside(&path).unwrap();

        assert_eq!(std::fs::read(&aside).unwrap(), b"database");
        for suffix in SIDECAR_SUFFIXES {
            assert!(!with_suffix(&path, suffix).exists(), "{suffix} left beside the new store");
            assert_eq!(std::fs::read(with_suffix(&aside, suffix)).unwrap(), suffix.as_bytes());
        }
    }

    #[test]
    fn a_second_corrupt_file_never_overwrites_the_first_one_set_aside() {
        let dir = TestDir::new();
        let path = dir.path().join("store.sqlite3");
        let faults = RecordedFaults::default();
        for byte in [0x11_u8, 0x22] {
            std::fs::write(&path, vec![byte; 4096]).unwrap();
            drop(open_own_store("test_store", &path, &faults, open_probed).unwrap());
        }
        let events = faults.taken();
        assert_eq!(events.len(), 2);
        assert_eq!(std::fs::read(dir.path().join("store.sqlite3.corrupt")).unwrap()[0], 0x11);
        assert_eq!(std::fs::read(dir.path().join("store.sqlite3.corrupt-1")).unwrap()[0], 0x22);
    }

    #[test]
    fn a_store_that_still_fails_is_opened_twice_at_most() {
        let dir = TestDir::new();
        let path = dir.path().join("store.sqlite3");
        std::fs::write(&path, vec![0x5a_u8; 4096]).unwrap();
        let faults = RecordedFaults::default();
        let mut calls = 0;

        let result = open_own_store("test_store", &path, &faults, |path| {
            calls += 1;
            // Recreates the garbage each time: the second open fails as well.
            std::fs::write(path, vec![0x5a_u8; 4096])?;
            open_probed(path)
        });

        assert!(result.is_err());
        assert_eq!(calls, 2);
        assert_eq!(faults.taken().len(), 1);
    }

    /// Each daemon store opener: a garbage file gives a working, empty store
    /// and one fault, and the next open of the new file reports none.
    #[test]
    fn every_daemon_store_opens_a_garbage_file_as_a_new_store_with_one_fault() {
        use crate::chief_registry::{CHIEFS_FILE, ChiefStore};
        use crate::conversation_store::{CONVERSATIONS_FILE, ConversationStore};
        let dir = TestDir::new();
        let faults = RecordedFaults::default();
        for file in [CHIEFS_FILE, CONVERSATIONS_FILE] {
            std::fs::write(dir.path().join(file), vec![0x5a_u8; 8192]).unwrap();
        }

        let chiefs = ChiefStore::open_with_faults(Some(dir.path()), &faults).unwrap();
        chiefs.list().unwrap();
        let mut conversations =
            ConversationStore::open_with_faults(Some(dir.path()), &faults).unwrap();
        assert!(conversations.list().unwrap().is_empty());

        let events = faults.taken();
        let stores: Vec<_> = events.iter().map(|event| event.store).collect();
        assert_eq!(stores, ["chief_registry", "conversation_store"]);
        for event in &events {
            assert_eq!(std::fs::read(&event.aside).unwrap(), vec![0x5a_u8; 8192]);
        }
        drop((chiefs, conversations));
        drop(ChiefStore::open_with_faults(Some(dir.path()), &faults).unwrap());
        drop(ConversationStore::open_with_faults(Some(dir.path()), &faults).unwrap());
        assert!(faults.taken().is_empty());
    }

    #[test]
    fn other_errors_leave_the_file_in_place() {
        let dir = TestDir::new();
        let path = dir.path().join("store.sqlite3");
        drop(open_probed(&path).unwrap());
        let faults = RecordedFaults::default();

        let result: anyhow::Result<()> = open_own_store("test_store", &path, &faults, |_| {
            Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
                None,
            )
            .into())
        });

        assert!(result.is_err());
        assert!(faults.taken().is_empty());
        assert!(path.exists());
        assert!(!dir.path().join("store.sqlite3.corrupt").exists());
    }
}
