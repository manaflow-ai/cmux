//! Panic-free string helpers shared by both policies: production code in
//! this crate never indexes or slices (plans/cmux-next/rust-panic-free.md).

use std::fmt::Write as _;

/// `text` split before the first character `is_delimiter` accepts; the whole
/// text and `""` when none does.
pub(crate) fn split_before(text: &str, is_delimiter: impl FnMut(char) -> bool) -> (&str, &str) {
    text.find(is_delimiter).and_then(|at| text.split_at_checked(at)).unwrap_or((text, ""))
}

/// Appends `%HH` (upper-case hex) for `byte`.
pub(crate) fn push_percent_byte(out: &mut String, byte: u8) {
    // Writing to a `String` cannot fail.
    let _ = write!(out, "%{byte:02X}");
}
