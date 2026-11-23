//! A Chromium `Cookies` database's fingerprint: one stable 64-bit hash per
//! `host_key`, over that host's cookies (never their access times).
//!
//! The database is read through a private copy (the file, and its
//! `-journal` or `-wal` when present) in a fresh temporary directory: the
//! browser holds the file open and commits to it while it runs, and the
//! source is never opened, locked or written. The copy opens read-write so
//! SQLite can roll back a hot journal or replay the WAL, the way the app's
//! importer (`SQLiteSnapshot`) reads it.
//!
//! Columns differ between Chrome versions; the same fallbacks as the app's
//! `ChromiumCookieReader`: `is_secure` or `secure`, `is_httponly` or
//! `httponly`, `samesite` (else -1), `has_expires` (else 1),
//! `top_frame_site_key` (else none). Partitioned cookies (a non-empty
//! `top_frame_site_key`) are skipped, as the importer skips them.
//!
//! A host's hash covers each of its cookies' name, path, value,
//! encrypted_value, expires_utc, has_expires, secure, httponly and samesite.
//! `creation_utc`, `last_access_utc` and `last_update_utc` are left out:
//! Chrome rewrites the access time on almost every request, and a commit
//! that only moved it must report nothing. Each cookie hashes alone; a
//! host's hash is over its cookies' hashes sorted, so row order never
//! matters.

use crate::hash::Fnv;
use crate::watch::sidecar;
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags};
use std::collections::{BTreeMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// `host_key` (as stored, a leading dot included) to its hash.
pub type Fingerprint = BTreeMap<String, u64>;

/// One read of a database.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scan {
    pub fingerprint: Fingerprint,
    /// Cookies hashed (partitioned ones not counted).
    pub rows: u64,
    /// Partitioned cookies skipped.
    pub partitioned: u64,
}

/// Why a database gave no fingerprint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScanError {
    /// The database file is not there (the profile is gone).
    Missing,
    /// It could not be copied or read as a Chromium cookie store. A short
    /// reason, never a path or a value.
    Unreadable(String),
}

/// The fingerprint of the Chromium `Cookies` database at `database`.
pub fn fingerprint(database: &Path) -> Result<Scan, ScanError> {
    let snapshot = Snapshot::copy(database)?;
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn =
        Connection::open_with_flags(snapshot.database(), flags).map_err(|e| sqlite("open", &e))?;
    let scan = read(&conn);
    drop(conn);
    drop(snapshot);
    scan
}

/// The fingerprint of an open Chromium cookie store.
pub fn read(conn: &Connection) -> Result<Scan, ScanError> {
    let columns = columns(conn)?;
    if !columns.contains("host_key") || !columns.contains("encrypted_value") {
        return Err(ScanError::Unreadable("not a Chromium cookies table".to_owned()));
    }
    let pick = |names: &[&'static str], fallback: &'static str| {
        names.iter().copied().find(|name| columns.contains(*name)).unwrap_or(fallback)
    };
    let secure = pick(&["is_secure", "secure"], "0");
    let http_only = pick(&["is_httponly", "httponly"], "0");
    let same_site = pick(&["samesite"], "-1");
    let has_expires = pick(&["has_expires"], "1");
    let partition = pick(&["top_frame_site_key"], "''");
    let sql = format!(
        "SELECT host_key, {partition}, name, path, value, encrypted_value, expires_utc, \
         {has_expires}, {secure}, {http_only}, {same_site} FROM cookies"
    );
    let mut statement = conn.prepare(&sql).map_err(|e| sqlite("query", &e))?;
    let mut rows = statement.query([]).map_err(|e| sqlite("query", &e))?;
    let mut hosts: BTreeMap<String, Vec<u64>> = BTreeMap::new();
    let mut scan = Scan { fingerprint: Fingerprint::new(), rows: 0, partitioned: 0 };
    while let Some(row) = rows.next().map_err(|e| sqlite("query", &e))? {
        let partitioned = match row.get_ref(1).map_err(|e| sqlite("row", &e))? {
            ValueRef::Text(text) | ValueRef::Blob(text) => !text.is_empty(),
            _ => false,
        };
        if partitioned {
            scan.partitioned = scan.partitioned.saturating_add(1);
            continue;
        }
        let host = match row.get_ref(0).map_err(|e| sqlite("row", &e))? {
            ValueRef::Text(text) => String::from_utf8_lossy(text).into_owned(),
            _ => String::new(),
        };
        let mut cookie = Fnv::new();
        for column in 2..=10 {
            hash_value(&mut cookie, row.get_ref(column).map_err(|e| sqlite("row", &e))?);
        }
        hosts.entry(host).or_default().push(cookie.finish());
        scan.rows = scan.rows.saturating_add(1);
    }
    for (host, mut cookies) in hosts {
        cookies.sort_unstable();
        let mut hash = Fnv::new();
        hash.u64(u64::try_from(cookies.len()).unwrap_or(u64::MAX));
        for cookie in cookies {
            hash.u64(cookie);
        }
        scan.fingerprint.insert(host, hash.finish());
    }
    Ok(scan)
}

/// One column's value with its type, so `NULL`, `0` and `''` differ.
fn hash_value(hash: &mut Fnv, value: ValueRef<'_>) {
    match value {
        ValueRef::Null => hash.bytes(&[0]),
        ValueRef::Integer(int) => {
            hash.bytes(&[1]);
            hash.bytes(&int.to_le_bytes());
        }
        ValueRef::Real(real) => {
            hash.bytes(&[2]);
            hash.bytes(&real.to_bits().to_le_bytes());
        }
        ValueRef::Text(text) => {
            hash.bytes(&[3]);
            hash.field(text);
        }
        ValueRef::Blob(blob) => {
            hash.bytes(&[4]);
            hash.field(blob);
        }
    }
}

fn columns(conn: &Connection) -> Result<HashSet<String>, ScanError> {
    let mut statement =
        conn.prepare("PRAGMA table_info(cookies)").map_err(|e| sqlite("schema", &e))?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| sqlite("schema", &e))?
        .collect::<Result<HashSet<_>, _>>()
        .map_err(|e| sqlite("schema", &e))?;
    Ok(names)
}

/// A short reason from SQLite's error code (its messages can carry a path).
fn sqlite(step: &str, error: &rusqlite::Error) -> ScanError {
    let code =
        error.sqlite_error_code().map_or_else(|| "error".to_owned(), |code| format!("{code:?}"));
    ScanError::Unreadable(format!("{step}: {code}"))
}

static SNAPSHOTS: AtomicU64 = AtomicU64::new(0);

/// A private copy of a database and its journal, removed on drop.
struct Snapshot {
    directory: PathBuf,
}

impl Snapshot {
    const NAME: &'static str = "Cookies";

    fn copy(database: &Path) -> Result<Self, ScanError> {
        match std::fs::metadata(database) {
            Ok(meta) if meta.is_file() => {}
            Ok(_) => return Err(ScanError::Unreadable("not a file".to_owned())),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err(ScanError::Missing);
            }
            Err(error) => return Err(io_reason("stat", &error)),
        }
        let directory = fresh_private_dir().map_err(|e| io_reason("temp", &e))?;
        let snapshot = Self { directory };
        let copy = snapshot.database();
        match std::fs::copy(database, &copy) {
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err(ScanError::Missing);
            }
            Err(error) => return Err(io_reason("copy", &error)),
        }
        for suffix in ["-journal", "-wal"] {
            let side = sidecar(database, suffix);
            match std::fs::copy(&side, sidecar(&copy, suffix)) {
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(io_reason("copy", &error)),
            }
        }
        Ok(snapshot)
    }

    fn database(&self) -> PathBuf {
        self.directory.join(Self::NAME)
    }
}

impl Drop for Snapshot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

/// A new directory of our own under the temporary directory: created, not
/// found (a path someone else made first, maybe holding a symlink, is never
/// used), mode 0700.
fn fresh_private_dir() -> io::Result<PathBuf> {
    let base = std::env::temp_dir();
    let mut last = io::Error::from(io::ErrorKind::AlreadyExists);
    for _ in 0..16 {
        let serial = SNAPSHOTS.fetch_add(1, Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.subsec_nanos());
        let directory =
            base.join(format!("cmux-cookie-sync-{}-{serial}-{nanos:08x}", std::process::id()));
        match create_new_private_dir(&directory) {
            Ok(()) => return Ok(directory),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => last = error,
            Err(error) => return Err(error),
        }
    }
    Err(last)
}

#[cfg(unix)]
fn create_new_private_dir(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().mode(0o700).create(path)
}

#[cfg(not(unix))]
fn create_new_private_dir(path: &Path) -> io::Result<()> {
    std::fs::create_dir(path)
}

fn io_reason(step: &str, error: &io::Error) -> ScanError {
    ScanError::Unreadable(format!("{step}: {}", error.kind()))
}

#[cfg(unix)]
pub(crate) fn create_private_dir(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path)
}

#[cfg(not(unix))]
pub(crate) fn create_private_dir(path: &Path) -> io::Result<()> {
    std::fs::create_dir_all(path)
}

#[cfg(test)]
mod tests {
    use super::fresh_private_dir;

    #[test]
    fn a_snapshot_directory_is_always_a_new_one() {
        let first = fresh_private_dir().unwrap();
        let second = fresh_private_dir().unwrap();
        assert_ne!(first, second);
        assert!(super::create_new_private_dir(&first).is_err(), "an existing path is refused");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&first).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o700);
        }
        std::fs::remove_dir(&first).unwrap();
        std::fs::remove_dir(&second).unwrap();
    }
}
