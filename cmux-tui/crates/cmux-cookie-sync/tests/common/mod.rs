//! Chromium cookie stores for the tests, in Chrome's own schema.
#![allow(dead_code)]

use rusqlite::{Connection, params};
use std::path::Path;

/// Chrome's `cookies` table as of meta version 24 (2025).
pub const MODERN: &str = "
CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
INSERT INTO meta VALUES('version', '24');
CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
  name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
  expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
  last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
  priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
  source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
  has_cross_site_ancestor INTEGER NOT NULL);
";

/// An old Chrome's table: `secure`/`httponly`, no `samesite`,
/// `top_frame_site_key` or `last_update_utc`.
pub const OLD: &str = "
CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
INSERT INTO meta VALUES('version', '9');
CREATE TABLE cookies(creation_utc INTEGER NOT NULL UNIQUE PRIMARY KEY, host_key TEXT NOT NULL,
  name TEXT NOT NULL, value TEXT NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL,
  secure INTEGER NOT NULL, httponly INTEGER NOT NULL, last_access_utc INTEGER NOT NULL,
  has_expires INTEGER NOT NULL DEFAULT 1, persistent INTEGER NOT NULL DEFAULT 1,
  priority INTEGER NOT NULL DEFAULT 1, encrypted_value BLOB DEFAULT '');
";

pub fn create(path: &Path, schema: &str) -> Connection {
    let conn = Connection::open(path).expect("open the fixture");
    conn.execute_batch(schema).expect("schema");
    conn
}

/// One cookie in the modern schema; `partition` non-empty makes it partitioned.
pub fn insert(conn: &Connection, host: &str, name: &str, encrypted: &[u8], partition: &str) {
    insert_at(conn, host, name, encrypted, partition, 13_300_000_000_000_000);
}

pub fn insert_at(
    conn: &Connection,
    host: &str,
    name: &str,
    encrypted: &[u8],
    partition: &str,
    created: i64,
) {
    conn.execute(
        "INSERT INTO cookies VALUES(?1, ?2, ?3, ?4, '', ?5, '/', 13400000000000000, 1, 1, ?1, 1, 1, 1, 1, 2, 443, ?1, 0, 0)",
        params![created, host, partition, name, encrypted],
    )
    .expect("insert");
}
