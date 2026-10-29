//! A terminal's title as the program in it sets it (plans/cmux-next/osc-titles.md).
//!
//! The title stack and OSC 1 rewrite every parser of a terminal's output
//! runs is `cmux_vt_stream::TitleTracker`, applied through
//! [`crate::prompt_mode_reset::write_output`].
//!
//! [`sanitize`] is the one way the daemon reads a title out of a terminal:
//! no control characters, no bidi overrides, at most [`MAX_TITLE_CHARS`].

/// The longest title the daemon stores or sends, in characters.
pub(crate) const MAX_TITLE_CHARS: usize = 256;

/// The title read from `term`, sanitized; empty when the program set none.
pub(crate) fn read(term: &ghostty_vt::Terminal) -> String {
    sanitize(&term.title().unwrap_or_default())
}

/// `raw` without control characters, bidi controls or invisible separators,
/// trimmed and cut to [`MAX_TITLE_CHARS`]. A tab, newline or carriage return
/// reads as a space; a zero width joiner stays, it holds emoji together.
pub(crate) fn sanitize(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len().min(MAX_TITLE_CHARS * 4));
    let mut count = 0;
    for ch in raw.trim().chars() {
        let ch = match ch {
            '\t' | '\n' | '\r' => ' ',
            c if c.is_control() || is_hidden_format(c) => continue,
            c => c,
        };
        if count == MAX_TITLE_CHARS {
            break;
        }
        out.push(ch);
        count += 1;
    }
    out.truncate(out.trim_end().len());
    out
}

/// Bidi embeddings, overrides, isolates and marks (a title could otherwise
/// show `exe.gpj` as `jpg.exe`), and invisible separators.
fn is_hidden_format(c: char) -> bool {
    matches!(
        c,
        '\u{061C}'
            | '\u{200B}'
            | '\u{200E}'
            | '\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{2069}'
            | '\u{FEFF}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal() -> ghostty_vt::Terminal {
        ghostty_vt::Terminal::new(40, 4, 100, ghostty_vt::Callbacks::default()).unwrap()
    }

    /// Feeds `chunks` through the daemon's output path and returns the title after each.
    fn titles_after(chunks: &[&[u8]]) -> Vec<String> {
        let mut term = terminal();
        let mut marks = crate::prompt_mode_reset::ShellMarks::default();
        chunks
            .iter()
            .map(|chunk| {
                let _ = crate::prompt_mode_reset::write_output(&mut term, chunk, &mut marks);
                read(&term)
            })
            .collect()
    }

    #[test]
    fn sanitize_drops_controls_and_bidi_and_caps_the_length() {
        assert_eq!(sanitize("  build\u{7}\u{1b}[31m ok\t "), "build[31m ok");
        assert_eq!(sanitize("evil\u{202e}gpj.exe"), "evilgpj.exe");
        assert_eq!(sanitize("a\u{2066}b\u{2069}c\u{200f}d\u{061c}e\u{feff}"), "abcde");
        assert_eq!(sanitize("line one\nline two"), "line one line two");
        assert_eq!(sanitize("\u{85}c1"), "c1");
        // A zero width joiner holds an emoji sequence together: it stays.
        assert_eq!(sanitize("👩\u{200d}💻 dev"), "👩\u{200d}💻 dev");
        let long = "é".repeat(MAX_TITLE_CHARS + 40);
        assert_eq!(sanitize(&long).chars().count(), MAX_TITLE_CHARS);
    }

    #[test]
    fn a_pop_restores_the_pushed_title() {
        let titles = titles_after(&[
            b"\x1b]2;zsh ~/src\x07",
            b"\x1b[22;0t\x1b]2;vim notes.md\x07",
            b"\x1b[23;0t",
        ]);
        assert_eq!(titles, ["zsh ~/src", "vim notes.md", "zsh ~/src"]);
    }

    #[test]
    fn push_and_pop_with_title_only_and_default_params() {
        let titles = titles_after(&[
            b"\x1b]0;one\x1b\\",
            b"\x1b[22t\x1b]2;two\x07\x1b[22;2t\x1b]2;three\x07",
            b"\x1b[23;2t",
            b"\x1b[23t",
        ]);
        assert_eq!(titles, ["one", "three", "two", "one"]);
    }

    #[test]
    fn an_icon_only_push_and_an_empty_stack_leave_the_title() {
        let titles = titles_after(&[
            b"\x1b]2;kept\x07",
            b"\x1b[22;1t\x1b]2;next\x07\x1b[23;1t",
            b"\x1b[23;0t",
        ]);
        assert_eq!(titles, ["kept", "next", "next"]);
    }

    #[test]
    fn a_pop_split_across_chunks_still_restores() {
        let titles =
            titles_after(&[b"\x1b]2;shell\x07\x1b[2", b"2;0t\x1b]2;tool\x07\x1b[23", b";0t"]);
        assert_eq!(titles, ["shell", "tool", "shell"]);
    }

    #[test]
    fn osc_1_names_the_terminal_only_until_an_osc_2() {
        assert_eq!(titles_after(&[b"\x1b]1;icon name\x07"]), ["icon name"]);
        assert_eq!(titles_after(&[b"\x1b]2;real\x07\x1b]1;icon\x07"]), ["real"]);
    }
}
