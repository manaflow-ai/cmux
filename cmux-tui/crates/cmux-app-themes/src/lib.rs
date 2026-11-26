//! The cmux NEXT app's theme and layout template rules, without I/O: the app
//! reads and writes the files, stats paths and owns the async plumbing; these
//! decide what it writes, what it keeps and what it refuses. The app reaches
//! them over the app FFI (`cmux-layout-reducer-ffi` `app_themes_*` ops).

pub mod catalog;
pub mod kv_store;
pub mod layout_templates;
pub mod theme_files;
pub mod theme_spec;

/// Foundation's `CharacterSet.whitespaces`: tab and the space separators (Unicode Zs).
pub(crate) fn is_horizontal_space(c: char) -> bool {
    c == '\t' || (c.is_whitespace() && !c.is_control() && !matches!(c, '\u{2028}' | '\u{2029}'))
}

/// `trimmingCharacters(in: .whitespaces)`.
pub(crate) fn trim_spaces(text: &str) -> &str {
    text.trim_matches(is_horizontal_space)
}
