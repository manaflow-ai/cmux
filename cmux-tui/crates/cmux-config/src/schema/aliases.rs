//! Choice values a row renamed: `aliases` ({old value: choice value}) in
//! schemas/settings/source, which gen-settings-sources.py writes for the daemon
//! as schemas/settings/choice-aliases.generated.json (the generated Swift enums
//! read the same table as `legacyValues`). An old value reads as its
//! replacement without a diagnostic; a write of it is still refused, and
//! [`crate::migrations::migrate`] rewrites it in a setup, a profile or a theme.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::Deserialize;

const EMBEDDED: &str =
    include_str!("../../../../../schemas/settings/choice-aliases.generated.json");

#[derive(Deserialize)]
struct AliasesFile {
    aliases: BTreeMap<String, BTreeMap<String, String>>,
}

/// Every row's aliases, by dotted key: {old value: choice value}.
pub fn choice_aliases() -> &'static BTreeMap<String, BTreeMap<String, String>> {
    static TABLE: OnceLock<BTreeMap<String, BTreeMap<String, String>>> = OnceLock::new();
    TABLE.get_or_init(|| {
        // Generated and compiled in: a file that did not parse reads as no aliases, and
        // `every_choice_alias_maps_to_a_value_its_row_accepts` fails on an empty table.
        serde_json::from_str::<AliasesFile>(EMBEDDED).map(|file| file.aliases).unwrap_or_default()
    })
}

/// The choice value `old` reads as for the row `key`, when `old` is one of its aliases.
pub fn choice_alias(key: &str, old: &str) -> Option<&'static str> {
    choice_aliases().get(key)?.get(old).map(String::as_str)
}
