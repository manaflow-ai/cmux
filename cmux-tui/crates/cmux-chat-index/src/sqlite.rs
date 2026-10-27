//! Read-only access to a harness's SQLite store, without writing, creating
//! or locking anything in the harness's folder:
//!
//! - A live WAL store (`-wal` and `-shm` beside it) opens read-only; WAL
//!   readers never block the writer.
//! - A `-wal` without its `-shm` is refused: opening it would make SQLite
//!   create the `-shm` file.
//! - Otherwise the file opens `immutable=1`: no locks, no journal or shared
//!   memory files. A rollback-journal writer that commits during the read
//!   can make the query fail; the caller keeps its last scan.
//!
//! Every handle is `query_only`, runs fixed queries (no ATTACH), and stops
//! any query after a deadline.
//!
//! The SQLite error policy for a store another program owns: wait out a
//! lock for the deadline (busy timeout); a corrupt file (`SQLITE_CORRUPT`,
//! `SQLITE_NOTADB`) is never moved or repaired, it fails that one scan with
//! the error and the index keeps its last result until the file changes.

use std::collections::HashSet;
use std::path::Path;
use std::time::{Duration, Instant};

use rusqlite::{Connection, OpenFlags};

const DEADLINE: Duration = Duration::from_secs(2);

pub(crate) fn open_read_only(path: &Path) -> rusqlite::Result<Connection> {
    let sidecar = |suffix: &str| {
        let mut name = path.as_os_str().to_owned();
        name.push(suffix);
        std::path::PathBuf::from(name).exists()
    };
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = match (sidecar("-wal"), sidecar("-shm")) {
        (true, true) => Connection::open_with_flags(path, flags)?,
        (true, false) => {
            return Err(rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
                Some("a WAL without its shared-memory file; opening would create it".to_owned()),
            ));
        }
        (false, _) => {
            Connection::open_with_flags(immutable_uri(path), flags | OpenFlags::SQLITE_OPEN_URI)?
        }
    };
    conn.busy_timeout(DEADLINE)?;
    conn.pragma_update(None, "query_only", true)?;
    let deadline = Instant::now() + DEADLINE;
    conn.progress_handler(10_000, Some(move || Instant::now() > deadline))?;
    Ok(conn)
}

/// `file:<percent-encoded path>?immutable=1` (`file:///C:/x` on Windows).
fn immutable_uri(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    let mut uri = String::from("file:");
    if !text.starts_with('/') {
        // A Windows drive path: `file:///C:/...`.
        uri.push_str("///");
    }
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'-' | b'_' | b'~' | b':') {
            uri.push(char::from(byte));
        } else {
            uri.push_str(&format!("%{byte:02X}"));
        }
    }
    uri.push_str("?immutable=1");
    uri
}

pub(crate) fn columns(conn: &Connection, table: &str) -> rusqlite::Result<HashSet<String>> {
    let mut stmt = conn.prepare("SELECT name FROM pragma_table_info(?1)")?;
    let names = stmt.query_map([table], |row| row.get::<_, String>(0))?;
    names.collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A garbage harness store fails its read with SQLite's error, and the
    /// file stays byte for byte as the harness left it, with no sidecar.
    #[test]
    fn a_garbage_store_fails_the_read_and_is_left_untouched() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.sqlite");
        let garbage = vec![0x5a_u8; 8192];
        std::fs::write(&path, &garbage).unwrap();

        let error = open_read_only(&path).and_then(|conn| columns(&conn, "threads")).unwrap_err();

        assert_eq!(error.sqlite_error_code(), Some(rusqlite::ErrorCode::NotADatabase), "{error}");
        assert_eq!(std::fs::read(&path).unwrap(), garbage);
        let names: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names, ["state.sqlite"]);
    }
}
