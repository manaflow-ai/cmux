//! Read-only access to a harness's SQLite store: `mode=ro`, `query_only`,
//! fixed queries only (no ATTACH), a busy timeout, and a deadline for every query on the handle.

use std::collections::HashSet;
use std::path::Path;
use std::time::{Duration, Instant};

use rusqlite::{Connection, OpenFlags};

const DEADLINE: Duration = Duration::from_secs(2);

pub(crate) fn open_read_only(path: &Path) -> rusqlite::Result<Connection> {
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = Connection::open_with_flags(path, flags)?;
    conn.busy_timeout(DEADLINE)?;
    conn.pragma_update(None, "query_only", true)?;
    let deadline = Instant::now() + DEADLINE;
    conn.progress_handler(10_000, Some(move || Instant::now() > deadline))?;
    Ok(conn)
}

pub(crate) fn columns(conn: &Connection, table: &str) -> rusqlite::Result<HashSet<String>> {
    let mut stmt = conn.prepare("SELECT name FROM pragma_table_info(?1)")?;
    let names = stmt.query_map([table], |row| row.get::<_, String>(0))?;
    names.collect()
}
