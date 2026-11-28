//! cmux-next.json keys that are not Settings rows but that cmux's own tools
//! read: `schemas/settings/file-keys.json` (hand-edited), embedded here. The
//! customize doctor checks this table before it calls a key unknown, so a key
//! the Chief host or a page reads (`chief.turnHooks`, `actions`) is never named
//! a typo (Leo, 2026-11-25, of a toast naming them: "will this
//! be fixed soon?").

use std::sync::OnceLock;

use serde::Deserialize;

const EMBEDDED: &str = include_str!("../../../../../schemas/settings/file-keys.json");

#[derive(Deserialize)]
struct FileKeys {
    keys: Vec<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    key: String,
    reader: String,
}

/// One key of the settings file another reader owns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileKey {
    /// The key's path; everything under it belongs to it too.
    pub path: Vec<String>,
    /// Who reads it, for a person or a removal.
    pub reader: String,
}

/// Every entry, in the file's order.
pub fn file_keys() -> &'static [FileKey] {
    static TABLE: OnceLock<Vec<FileKey>> = OnceLock::new();
    TABLE.get_or_init(|| {
        // Compiled in, and the tests below parse it on every run; a table that did not parse
        // would only make the doctor name these keys again, so it reads as empty.
        let file: FileKeys =
            serde_json::from_str(EMBEDDED).unwrap_or(FileKeys { keys: Vec::new() });
        file.keys
            .into_iter()
            .map(|entry| FileKey {
                path: entry.key.split('.').map(str::to_owned).collect(),
                reader: entry.reader,
            })
            .collect()
    })
}

/// The entry `path` is, or is under; `None` when no tool owns it.
pub fn file_key(path: &[String]) -> Option<&'static FileKey> {
    file_keys().iter().find(|entry| path.starts_with(&entry.path))
}

#[cfg(test)]
#[path = "file_keys_tests.rs"]
mod tests;
