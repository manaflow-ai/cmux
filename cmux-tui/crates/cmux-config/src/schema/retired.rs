//! cmux.json keys cmux used to read and no longer does. The one list is
//! `schemas/settings/retired-keys.json` (hand-edited, cx-d5b5d), embedded
//! here; the app's Swift table is generated from the same file by
//! `scripts/cmux-next/gen-settings-sources.py`. Loading ignores a retired
//! key without a diagnostic; a write is refused as removed; a reset cleans
//! an old file.
//!
//! An entry with `replaced_by` names the row that took the key's place, and
//! `values` what the old key's values read as in it (any other reads as the
//! row's default). While the row is unset its effective value reads the old
//! key through that table, and every write or reset of the row, and Reset
//! All, removes the old key, so it never applies behind the row (Swift
//! `RenamedSettingKeys`, from the same file). An entry with `replaced_by`
//! and no `values` is a plain rename: the old key's value reads as is.
//!
//! The same table rewrites a setup, a profile or a theme file written for an
//! older cmux ([`crate::migrations`]); `since` and `until` bound the window in
//! which an old name installs without the author being told to change it.

use std::sync::OnceLock;

use serde::Deserialize;
use serde_json::Value;

const EMBEDDED: &str = include_str!("../../../../../schemas/settings/retired-keys.json");

#[derive(Deserialize)]
struct RetiredFile {
    retired: Vec<RetiredEntry>,
}

#[derive(Deserialize)]
struct RetiredEntry {
    key: String,
    #[serde(default)]
    migrated_by_app: bool,
    reason: String,
    replaced_by: Option<String>,
    values: Option<Vec<ValueMap>>,
    since: Option<String>,
    until: Option<String>,
}

#[derive(Deserialize)]
struct ValueMap {
    from: Value,
    to: Value,
}

/// A retired key a row took the place of.
#[derive(Debug)]
pub struct Replaced {
    /// The retired key's path.
    pub old: Vec<String>,
    /// The row's path.
    pub row: Vec<String>,
    /// What the old key's values read as in the row; `None` for a plain
    /// rename, where every value reads as is.
    pub values: Option<Vec<(Value, Value)>>,
}

impl Replaced {
    /// The row's value for the old key's `value`; `None` reads as the row's
    /// default.
    pub fn read<'a>(&'a self, value: &'a Value) -> Option<&'a Value> {
        match &self.values {
            None => Some(value),
            Some(values) => values.iter().find(|(from, _)| from == value).map(|(_, to)| to),
        }
    }
}

/// One entry of the table, as [`crate::migrations`] reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Retired {
    /// The old dotted key.
    pub key: String,
    /// Why it went, for a person.
    pub reason: String,
    /// The row that took its place (`None`: removed outright).
    pub replaced_by: Option<String>,
    /// The app owns a value transform on its settings file. Leave the source for it.
    pub migrated_by_app: bool,
    /// When the old name stopped being the setting (`YYYY-MM-DD` or a cmux version).
    pub since: Option<String>,
    /// The end of the deprecation window (`YYYY-MM-DD` or a cmux version).
    pub until: Option<String>,
}

/// Every entry, in the file's order.
pub fn retired_entries() -> &'static [Retired] {
    static TABLE: OnceLock<Vec<Retired>> = OnceLock::new();
    TABLE.get_or_init(|| {
        parse()
            .retired
            .into_iter()
            .map(|entry| Retired {
                key: entry.key,
                migrated_by_app: entry.migrated_by_app,
                reason: entry.reason,
                replaced_by: entry.replaced_by,
                since: entry.since,
                until: entry.until,
            })
            .collect()
    })
}

fn parse() -> RetiredFile {
    // The file is compiled in; gen-settings-sources.py --check validates it in CI.
    // crash-allow: compiled in, and the settings behavior tests parse it on every run.
    serde_json::from_str(EMBEDDED).expect("retired-keys.json parses")
}

fn path(dotted: &str) -> Vec<String> {
    dotted.split('.').map(str::to_string).collect()
}

/// Every retired key a row replaced, in the file's order.
pub fn replaced_keys() -> &'static [Replaced] {
    static TABLE: OnceLock<Vec<Replaced>> = OnceLock::new();
    TABLE.get_or_init(|| {
        parse()
            .retired
            .into_iter()
            .filter_map(|entry| {
                Some(Replaced {
                    old: path(&entry.key),
                    row: path(&entry.replaced_by?),
                    values: entry
                        .values
                        .map(|values| values.into_iter().map(|map| (map.from, map.to)).collect()),
                })
            })
            .collect()
    })
}

/// The retired key the row at `path` replaced, if any.
pub fn replaced_by_row(path: &[String]) -> Option<&'static Replaced> {
    replaced_keys().iter().find(|replaced| replaced.row == path)
}

/// Every retired dotted key and why, in the file's order.
pub fn retired_keys() -> &'static [(String, String)] {
    static TABLE: OnceLock<Vec<(String, String)>> = OnceLock::new();
    TABLE.get_or_init(|| {
        parse().retired.into_iter().map(|entry| (entry.key, entry.reason)).collect()
    })
}

/// The reason `path` was retired, or `None` when it is not retired.
pub fn retired_reason(path: &[String]) -> Option<&'static str> {
    let dotted = path.join(".");
    retired_keys().iter().find(|(key, _)| *key == dotted).map(|(_, reason)| reason.as_str())
}
