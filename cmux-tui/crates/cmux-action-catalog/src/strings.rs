//! Translations of the catalog's text, by string table and key, in every language the app
//! ships. The data is `strings.json` in this crate (table, then key, then language): edit
//! it there. A language a string lacks shows the English.

use crate::Text;

/// The app's languages, English first. [`lookup`] takes an index into this list.
pub const LOCALES: &[&str] = &[
    "en", "ja", "ar", "bs", "da", "de", "es", "fr", "it", "km", "ko", "nb", "pl", "pt-BR", "ru",
    "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
];

// `STRINGS`: (table, key, a value per language), sorted by table and key; written by build.rs.
include!(concat!(env!("OUT_DIR"), "/strings.rs"));

/// The index of `locale` in [`LOCALES`]: an exact match (`pt-BR`, `zh-Hant`), else its
/// language (`ja-JP` -> `ja`, `zh-Hans-CN` -> `zh-Hans`), else English.
pub fn locale_index(locale: &str) -> usize {
    let normalized = locale.replace('_', "-");
    let mut parts: Vec<&str> = normalized.split('-').collect();
    while !parts.is_empty() {
        let prefix = parts.join("-");
        if let Some(index) = LOCALES.iter().position(|known| known.eq_ignore_ascii_case(&prefix)) {
            return index;
        }
        parts.pop();
    }
    0
}

/// The translation of `table`/`key` in the language at `index`, if the table has one.
pub fn lookup(table: &str, key: &str, index: usize) -> Option<&'static str> {
    let found = STRINGS.binary_search_by(|(t, k, _)| (*t, *k).cmp(&(table, key))).ok()?;
    let value = *STRINGS.get(found)?.2.get(index)?;
    (!value.is_empty()).then_some(value)
}

/// `text` in the language at `index`, falling back to English, with its argument filled in.
pub fn resolve(text: &Text, index: usize) -> String {
    let format = if text.key.is_empty() || index == 0 {
        text.en
    } else {
        lookup(text.table, text.key, index).unwrap_or(text.en)
    };
    let value = match text.arg {
        Some(arg) => fill(format, arg),
        None => format.to_owned(),
    };
    match text.strip {
        Some((table, key, en)) => {
            let prefix = if index == 0 { en } else { lookup(table, key, index).unwrap_or(en) };
            value.replace(prefix, "")
        }
        None => value,
    }
}

/// Puts `arg` where `format` has its one `%@`, `%lld`, `%d` or positional `%1$@`.
fn fill(format: &str, arg: &str) -> String {
    for placeholder in ["%1$@", "%1$lld", "%@", "%lld", "%d"] {
        if let Some((before, after)) = format.split_once(placeholder) {
            return format!("{before}{arg}{after}");
        }
    }
    format.to_owned()
}

/// Every string, as (table, key, its value in each of [`LOCALES`]).
pub fn entries() -> impl Iterator<Item = (&'static str, &'static str, &'static [&'static str])> {
    STRINGS.iter().map(|(table, key, values)| (*table, *key, values.as_slice()))
}
