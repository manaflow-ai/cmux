//! Translations of the catalog's text, by string table and key, in every language the app
//! ships. The data is `strings.json` in this crate (table, then key, then language): edit
//! it there. A language a string lacks shows the English.

use crate::Text;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::OnceLock;

/// The app's languages, English first. [`lookup`] takes an index into this list.
pub const LOCALES: &[&str] = &[
    "en", "ja", "ar", "bs", "da", "de", "es", "fr", "it", "km", "ko", "nb", "pl", "pt-BR", "ru",
    "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
];

const SOURCE: &str = include_str!("../strings.json");

/// One string: its value in each of [`LOCALES`], empty where it is not translated.
type Values = Vec<String>;

fn strings_table() -> &'static HashMap<(String, String), Values> {
    static TABLE: OnceLock<HashMap<(String, String), Values>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let root: Value = serde_json::from_str(SOURCE).expect("strings.json is valid JSON");
        let mut map = HashMap::new();
        for (table, keys) in root["strings"].as_object().into_iter().flatten() {
            for (key, values) in keys.as_object().into_iter().flatten() {
                let row = LOCALES
                    .iter()
                    .map(|locale| values[*locale].as_str().unwrap_or("").to_owned())
                    .collect();
                map.insert((table.clone(), key.clone()), row);
            }
        }
        map
    })
}

/// The languages `strings.json` declares (its `locales`), for the test that keeps them
/// equal to [`LOCALES`].
pub fn declared_locales() -> Vec<String> {
    let root: Value = serde_json::from_str(SOURCE).expect("strings.json is valid JSON");
    root["locales"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect()
}

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
    let value = strings_table().get(&(table.to_owned(), key.to_owned()))?.get(index)?;
    (!value.is_empty()).then_some(value.as_str())
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
        if let Some(at) = format.find(placeholder) {
            return format!("{}{}{}", &format[..at], arg, &format[at + placeholder.len()..]);
        }
    }
    format.to_owned()
}

/// Every string, as (table, key, its value in each of [`LOCALES`]).
pub fn entries() -> impl Iterator<Item = (&'static str, &'static str, &'static [String])> {
    strings_table()
        .iter()
        .map(|((table, key), values)| (table.as_str(), key.as_str(), values.as_slice()))
}
