//! A read-only SQLite database opened from a private copy of the file and its `-wal` and
//! `-journal` (`SQLiteSnapshot.swift`), so a browser that is running and holds the database
//! locked does not block or fail the read, and the source is never written. The copy is opened
//! read-write so SQLite can replay the WAL, and removed on drop.
//!
//! Column reads follow `sqlite3_column_*`'s conversions, as the Swift `SQLiteRow` did: a text
//! read of an integer is its digits, an integer read of NULL is 0, of text its leading number.

use crate::model::ReadError;
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags, Row};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static SNAPSHOTS: AtomicU64 = AtomicU64::new(0);

pub struct Snapshot {
    connection: Option<Connection>,
    directory: PathBuf,
}

impl Snapshot {
    /// Copies `source` (and its side files when present) and opens the copy.
    pub fn copying(source: &Path) -> Result<Snapshot, ReadError> {
        let directory = fresh_private_dir().map_err(|e| ReadError::Copy(e.to_string()))?;
        let mut snapshot = Snapshot { connection: None, directory };
        let copy = snapshot.directory.join("db.sqlite");
        std::fs::copy(source, &copy).map_err(|e| ReadError::Copy(e.to_string()))?;
        for suffix in ["-wal", "-journal"] {
            let side = sidecar(source, suffix);
            if side.exists() {
                // A side file that vanished or cannot be read leaves the copy without it.
                let _ = std::fs::copy(&side, sidecar(&copy, suffix));
            }
        }
        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let connection = Connection::open_with_flags(&copy, flags)
            .map_err(|e| ReadError::Open(e.to_string()))?;
        snapshot.connection = Some(connection);
        Ok(snapshot)
    }

    /// Runs `sql` and calls `row` for each result row; `row` returns false to stop.
    pub fn query(&self, sql: &str, mut row: impl FnMut(&Row<'_>) -> bool) -> Result<(), ReadError> {
        let failed = |e: rusqlite::Error| ReadError::Query(e.to_string());
        let connection =
            self.connection.as_ref().ok_or_else(|| ReadError::Open("closed".into()))?;
        let mut statement = connection.prepare(sql).map_err(failed)?;
        let mut rows = statement.query([]).map_err(failed)?;
        while let Some(next) = rows.next().map_err(failed)? {
            if !row(next) {
                break;
            }
        }
        Ok(())
    }

    /// Whether `table` exists.
    pub fn has_table(&self, table: &str) -> bool {
        let quoted = table.replace('\'', "''");
        let mut found = false;
        let _ = self.query(
            &format!("SELECT 1 FROM sqlite_master WHERE type='table' AND name='{quoted}'"),
            |_| {
                found = true;
                false
            },
        );
        found
    }
}

impl Drop for Snapshot {
    fn drop(&mut self) {
        drop(self.connection.take());
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

/// `sqlite3_column_text`: None for NULL, an integer's or real's text, a blob's bytes.
/// The text ends at its first NUL, as `String(cString:)` read it.
pub fn text(row: &Row<'_>, column: usize) -> Option<String> {
    let value = row.get_ref(column).ok()?;
    let text = match value {
        ValueRef::Null => return None,
        ValueRef::Integer(number) => number.to_string(),
        ValueRef::Real(number) => real_text(number),
        ValueRef::Text(bytes) | ValueRef::Blob(bytes) => {
            let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
            String::from_utf8_lossy(bytes.get(..end).unwrap_or_default()).into_owned()
        }
    };
    Some(text)
}

/// SQLite's text for a real (`%!.15g`): 1.0 is "1.0", 0.5 is "0.5".
fn real_text(number: f64) -> String {
    if number.fract() == 0.0 && number.abs() < 1e15 {
        format!("{number:.1}")
    } else {
        format!("{number}")
    }
}

/// `sqlite3_column_int64`: NULL is 0, a real truncates, text is its leading integer.
pub fn int64(row: &Row<'_>, column: usize) -> i64 {
    match row.get_ref(column) {
        Ok(ValueRef::Integer(number)) => number,
        #[allow(
            clippy::cast_possible_truncation,
            reason = "SQLite truncates (saturating) the same way"
        )]
        Ok(ValueRef::Real(number)) => number as i64,
        Ok(ValueRef::Text(bytes)) => leading_integer(bytes),
        _ => 0,
    }
}

/// `sqlite3_column_double`: NULL is 0, an integer converts, text is its leading number.
pub fn double(row: &Row<'_>, column: usize) -> f64 {
    match row.get_ref(column) {
        #[allow(clippy::cast_precision_loss, reason = "SQLite converts the same way")]
        Ok(ValueRef::Integer(number)) => number as f64,
        Ok(ValueRef::Real(number)) => number,
        Ok(ValueRef::Text(bytes)) => leading_real(bytes),
        _ => 0.0,
    }
}

/// `sqlite3_column_blob`: the bytes of a blob or text, None for NULL.
pub fn blob(row: &Row<'_>, column: usize) -> Option<Vec<u8>> {
    match row.get_ref(column).ok()? {
        ValueRef::Null => None,
        ValueRef::Blob(bytes) | ValueRef::Text(bytes) => Some(bytes.to_vec()),
        ValueRef::Integer(number) => Some(number.to_string().into_bytes()),
        ValueRef::Real(number) => Some(real_text(number).into_bytes()),
    }
}

/// The leading number of `bytes`: blanks skipped, an optional sign, then `allowed` bytes.
fn leading(bytes: &[u8], allowed: impl Fn(u8) -> bool) -> &str {
    let start = bytes.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(bytes.len());
    let rest = bytes.get(start..).unwrap_or_default();
    let sign = usize::from(matches!(rest.first(), Some(b'+' | b'-')));
    let digits = rest.get(sign..).unwrap_or_default().iter().take_while(|&&b| allowed(b)).count();
    rest.get(..sign.saturating_add(digits))
        .and_then(|t| std::str::from_utf8(t).ok())
        .unwrap_or_default()
}

fn leading_integer(bytes: &[u8]) -> i64 {
    leading(bytes, |b| b.is_ascii_digit()).parse().unwrap_or(0)
}

fn leading_real(bytes: &[u8]) -> f64 {
    let text = leading(bytes, |b| b.is_ascii_digit() || matches!(b, b'.' | b'e' | b'E'));
    // The longest prefix that parses ("1e" is 1).
    (1..=text.len()).rev().find_map(|end| text.get(..end)?.parse().ok()).unwrap_or(0.0)
}

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

/// A new directory of our own under the temporary directory: created, not found (a path
/// someone else made first is never used), mode 0700.
fn fresh_private_dir() -> io::Result<PathBuf> {
    let base = std::env::temp_dir();
    let mut last = io::Error::from(io::ErrorKind::AlreadyExists);
    for _ in 0..16 {
        let serial = SNAPSHOTS.fetch_add(1, Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.subsec_nanos());
        let directory =
            base.join(format!("cmux-import-{}-{serial}-{nanos:08x}", std::process::id()));
        match create_private_dir(&directory) {
            Ok(()) => return Ok(directory),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => last = error,
            Err(error) => return Err(error),
        }
    }
    Err(last)
}

#[cfg(unix)]
fn create_private_dir(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().mode(0o700).create(path)
}

#[cfg(not(unix))]
fn create_private_dir(path: &Path) -> io::Result<()> {
    std::fs::create_dir(path)
}
