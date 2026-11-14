//! The regular expression of a terminal wait: `terminal.wait` (`cmux
//! terminal <t> screen wait --pattern`), the CLI's `send --pattern` and
//! `run --pattern`, and `agents wait --regex`.
//!
//! A wait pattern is matched line by line: it compiles in multi-line mode,
//! so `^` and `$` anchor at the start and end of each line of the text, as
//! `grep` and herdr's `--regex` do. `(?-m)` at the start asks for the whole
//! text instead (`\A` and `\z` also always mean the whole text).

/// Compiles `pattern` as a wait pattern: multi-line mode, the `regex`
/// crate's default size limits.
pub fn compile(pattern: &str) -> Result<regex::Regex, regex::Error> {
    regex::RegexBuilder::new(pattern).multi_line(true).build()
}

/// One line saying why `pattern` does not compile, for the wait's error:
/// the `regex` crate's own reason ("unclosed group") without its multi-line
/// caret drawing, so an agent sees what to fix.
pub fn invalid_message(pattern: &str, error: &regex::Error) -> String {
    let text = error.to_string();
    let reason = text
        .lines()
        .rev()
        .find_map(|line| line.trim().strip_prefix("error: "))
        .map_or_else(|| text.lines().next().unwrap_or_default().trim().to_owned(), str::to_owned);
    format!("terminal wait pattern {pattern:?} is not a valid regular expression: {reason}")
}

#[cfg(test)]
mod tests;
