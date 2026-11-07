//! Constructors the catalog data uses for its text.

use crate::model::Text;

/// A translated string: its table, key and English.
pub const fn t(table: &'static str, key: &'static str, en: &'static str) -> Text {
    Text { table, key, en, arg: None, strip: None }
}

/// A translated format string (`%@`, `%lld`) with its one argument.
pub const fn tf(
    table: &'static str,
    key: &'static str,
    en: &'static str,
    arg: &'static str,
) -> Text {
    Text { table, key, en, arg: Some(arg), strip: None }
}
