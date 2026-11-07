//! Translations of the catalog's text, by string-table key, in every language the app ships.

mod data;

pub use data::LOCALES;
use data::STRINGS;

use crate::Text;

/// The index of `locale` in [`LOCALES`]: an exact match (`pt-BR`, `zh-Hant`), else its
/// language (`ja-JP` -> `ja`, `zh-Hans-CN` -> `zh-Hans`), else English.
pub fn locale_index(locale: &str) -> usize {
    let normalized = locale.replace('_', "-");
    if let Some(index) = LOCALES.iter().position(|known| known.eq_ignore_ascii_case(&normalized)) {
        return index;
    }
    let mut parts: Vec<&str> = normalized.split('-').collect();
    while parts.len() > 1 {
        parts.pop();
        let prefix = parts.join("-");
        if let Some(index) = LOCALES.iter().position(|known| known.eq_ignore_ascii_case(&prefix)) {
            return index;
        }
    }
    0
}

/// The translation of `table`/`key` in the language at `index`, if the table has one.
pub fn lookup(table: &str, key: &str, index: usize) -> Option<&'static str> {
    let found = STRINGS.binary_search_by(|(t, k, _)| (*t, *k).cmp(&(table, key))).ok()?;
    let value = STRINGS[found].2.get(index).copied()?;
    (!value.is_empty()).then_some(value)
}

/// `text` in the language at `index`, falling back to English, with its argument filled in.
pub fn resolve(text: &Text, index: usize) -> String {
    let format = if text.key.is_empty() || index == 0 {
        text.en
    } else {
        lookup(text.table, text.key, index).unwrap_or(text.en)
    };
    match text.arg {
        Some(arg) => fill(format, arg),
        None => format.to_owned(),
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

/// Every key the catalog files translations under, with its English (the parity test checks
/// each against the app's string catalogs).
pub fn entries() -> impl Iterator<Item = (&'static str, &'static str, &'static [&'static str])> {
    STRINGS.iter().map(|(table, key, values)| (*table, *key, values.as_slice()))
}
