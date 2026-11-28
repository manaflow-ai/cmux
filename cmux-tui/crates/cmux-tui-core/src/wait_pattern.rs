//! The regular expression of a terminal wait: `terminal.wait` (`cmux
//! terminal <t> screen wait --pattern`) and the raw `wait-for` command.
//!
//! A wait pattern is matched line by line: it compiles in multi-line mode,
//! so `^` and `$` anchor at the start and end of each line of the text, as
//! `grep` does. `(?-m)` at the start asks for the whole text instead (`\A`
//! and `\z` also always mean the whole text).

/// Compiles `pattern` as a wait pattern: multi-line mode, the `regex`
/// crate's default size limits.
pub fn compile(pattern: &str) -> Result<regex::Regex, regex::Error> {
    regex::RegexBuilder::new(pattern).multi_line(true).build()
}

#[cfg(test)]
mod tests {
    #[test]
    fn w4j_anchors_match_at_each_line_unless_the_pattern_turns_multi_line_off() {
        let text = "step 1\nBENCH_OK\nstep 3\n$ ";
        assert!(super::compile("^BENCH_OK$").unwrap().is_match(text));
        assert!(!super::compile("(?-m)^BENCH_OK$").unwrap().is_match(text));
        assert!(!super::compile(r"\ABENCH_OK").unwrap().is_match(text));
        assert!(super::compile("(?m)^BENCH_OK$").unwrap().is_match(text));
        assert!(super::compile("BENCH").unwrap().is_match(text));
        assert!(super::compile("(").is_err());
    }
}
