//! Choice values a row renamed: `aliases` ({old value: choice value}) on a
//! row of schemas/settings/source, the one hand-edited definition (the
//! generated Swift enums read the same rows as `legacyValues`). The daemon
//! compiles in the section sources that have them ([`SOURCES`]); the test
//! `every_source_alias_is_compiled_in` fails when another section gains one.
//! An old value reads as its replacement without a diagnostic; a write of it
//! is still refused, and [`crate::migrations::migrate`] rewrites it in a
//! setup, a profile or a theme.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::Deserialize;

/// The section sources with a row that has `aliases`.
pub(crate) const SOURCES: [&str; 1] =
    [include_str!("../../../../../schemas/settings/source/updates.json")];

#[derive(Deserialize)]
struct Source {
    #[serde(default)]
    lists: Vec<List>,
}

#[derive(Deserialize)]
struct List {
    #[serde(default)]
    rows: Vec<SourceRow>,
}

#[derive(Deserialize)]
struct SourceRow {
    key: String,
    #[serde(default)]
    aliases: BTreeMap<String, String>,
}

/// Every row's aliases in the section sources `texts`, by dotted key. A text
/// that does not parse adds none.
pub(crate) fn aliases_in<'a>(
    texts: impl IntoIterator<Item = &'a str>,
) -> BTreeMap<String, BTreeMap<String, String>> {
    texts
        .into_iter()
        .filter_map(|text| serde_json::from_str::<Source>(text).ok())
        .flat_map(|source| source.lists)
        .flat_map(|list| list.rows)
        .filter(|row| !row.aliases.is_empty())
        .map(|row| (row.key, row.aliases))
        .collect()
}

/// Every row's aliases, by dotted key: {old value: choice value}.
pub fn choice_aliases() -> &'static BTreeMap<String, BTreeMap<String, String>> {
    static TABLE: OnceLock<BTreeMap<String, BTreeMap<String, String>>> = OnceLock::new();
    // Compiled in: a source that did not parse reads as no aliases, and
    // `every_choice_alias_maps_to_a_value_its_row_accepts` fails on an empty table.
    TABLE.get_or_init(|| aliases_in(SOURCES))
}

/// The choice value `old` reads as for the row `key`, when `old` is one of its aliases.
pub fn choice_alias(key: &str, old: &str) -> Option<&'static str> {
    choice_aliases().get(key)?.get(old).map(String::as_str)
}
