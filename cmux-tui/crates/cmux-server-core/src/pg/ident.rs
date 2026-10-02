//! App ids, SQL identifiers and literals (server.md 8.3).
//!
//! App ids are validated before they become identifiers, and every
//! identifier is quoted anyway, so a bug in one layer is not an injection.

use std::fmt;

pub const APP_ID_MAX: usize = 41;

/// A validated app id: `[a-z][a-z0-9_]{0,40}`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct AppId(String);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppIdError {
    Empty,
    TooLong(usize),
    /// The first character is not `a`..`z`.
    BadStart,
    /// A character outside `a-z`, `0-9`, `_` at this byte offset.
    BadChar(usize),
}

impl AppId {
    pub fn parse(id: &str) -> Result<AppId, AppIdError> {
        let bytes = id.as_bytes();
        let Some(first) = bytes.first() else { return Err(AppIdError::Empty) };
        if bytes.len() > APP_ID_MAX {
            return Err(AppIdError::TooLong(bytes.len()));
        }
        if !first.is_ascii_lowercase() {
            return Err(AppIdError::BadStart);
        }
        if let Some(pos) =
            bytes.iter().position(|b| !(b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_'))
        {
            return Err(AppIdError::BadChar(pos));
        }
        Ok(AppId(id.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Postgres role and (in database mode) database name: `app_<id>`.
    pub fn role(&self) -> String {
        format!("app_{}", self.0)
    }

    /// OS user in Linux system mode: `app-<id>` (server.md 7.2, 8.3).
    pub fn os_user(&self) -> String {
        format!("app-{}", self.0)
    }
}

impl fmt::Display for AppId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Quotes an SQL identifier: `"` + name with `"` doubled + `"`. Refuses NUL,
/// which Postgres cannot store.
pub fn quote_ident(name: &str) -> Option<String> {
    if name.is_empty() || name.contains('\0') {
        return None;
    }
    Some(format!("\"{}\"", name.replace('"', "\"\"")))
}

/// Quotes an SQL string literal: `'` + value with `'` doubled + `'`. The
/// result is only valid with `standard_conforming_strings = on` (the default
/// since 9.1, and this crate's `postgresql.conf` keeps it). Refuses NUL.
pub fn quote_literal(value: &str) -> Option<String> {
    if value.contains('\0') {
        return None;
    }
    Some(format!("'{}'", value.replace('\'', "''")))
}

/// An OS user name accepted in pg_ident, unit files and fix argv:
/// `[A-Za-z_][A-Za-z0-9_.-]{0,31}` (Linux and macOS short names).
pub fn valid_os_user(name: &str) -> bool {
    let bytes = name.as_bytes();
    match bytes.first() {
        Some(b) if b.is_ascii_alphabetic() || *b == b'_' => {}
        _ => return false,
    }
    bytes.len() <= 32
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || matches!(*b, b'_' | b'-' | b'.'))
}
