//! App ids, SQL identifiers and literals (server.md 8.3).
//!
//! App ids are validated before they become identifiers, and every
//! identifier is quoted anyway, so a bug in one layer is not an injection.

use std::fmt;

use sha2::{Digest, Sha256};

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
    /// Not a manifest app id `<publisher>/<name>` (cmux-app.schema.json).
    ManifestGrammar,
}

/// The manifest id grammar of `cmux-app-host/schema/cmux-app.schema.json`:
/// `^(local|[a-z0-9](?:[a-z0-9-]{0,38}))/[a-z0-9][a-z0-9-]{0,63}$`.
pub fn valid_manifest_id(id: &str) -> bool {
    let Some((publisher, name)) = id.split_once('/') else { return false };
    let part = |s: &str, max: usize| {
        let b = s.as_bytes();
        !b.is_empty()
            && b.len() <= max
            && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
            && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
    };
    part(publisher, 39) && part(name, 64)
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

    /// Maps a manifest app id to its Postgres and OS name (server.md 8.3):
    /// lowercase; `/`, `-` and `.` become `_`; a leading digit gets the
    /// prefix `a_`; a result longer than 40 bytes keeps its first 31 bytes,
    /// then `_` and the first 8 hex characters of SHA-256 of the full id.
    /// `cmux/tasks` becomes `cmux_tasks` (role `app_cmux_tasks`).
    ///
    /// The mapping is not injective (`a-b/c` and `a/b-c` both give
    /// `a_b_c`): the caller keeps the installed ids and refuses an install
    /// whose mapped id is already taken by another manifest id.
    pub fn from_manifest_id(id: &str) -> Result<AppId, AppIdError> {
        if !valid_manifest_id(id) {
            return Err(AppIdError::ManifestGrammar);
        }
        let mut mapped: String = id
            .to_ascii_lowercase()
            .chars()
            .map(|c| if matches!(c, '/' | '-' | '.') { '_' } else { c })
            .collect();
        if mapped.starts_with(|c: char| c.is_ascii_digit()) {
            mapped.insert_str(0, "a_");
        }
        if mapped.len() > 40 {
            let digest = Sha256::digest(id.as_bytes());
            let hex: String = digest[..4].iter().map(|b| format!("{b:02x}")).collect();
            mapped.truncate(31);
            mapped.push('_');
            mapped.push_str(&hex);
        }
        AppId::parse(&mapped)
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
