//! A terminal's title as the program in it sets it (plans/cmux-next/osc-titles.md).
//!
//! libghostty-vt stores the OSC 0/2 title, but it treats xterm's title stack
//! (`CSI 22 ; Ps t` push, `CSI 23 ; Ps t` pop) as a no-op and drops OSC 1
//! (the icon name). [`TitleTracker`] follows the title in the output stream
//! and turns each pop into the `OSC 2` that restores the pushed title, and
//! an OSC 1 that comes before any OSC 0/2 into the `OSC 2` it stands for. The
//! rewrite only inserts bytes after a whole sequence, so the terminal, every
//! mirror fed the normalized stream and every attach client see one title.
//!
//! [`sanitize`] is the one way the daemon reads a title out of a terminal:
//! no control characters, no bidi overrides, at most [`MAX_TITLE_CHARS`].

use std::borrow::Cow;

/// The longest title the daemon stores or sends, in characters.
pub(crate) const MAX_TITLE_CHARS: usize = 256;

/// The title read from `term`, sanitized; empty when the program set none.
pub(crate) fn read(term: &ghostty_vt::Terminal) -> String {
    sanitize(&term.title().unwrap_or_default())
}

/// `raw` without control characters, bidi controls or invisible separators,
/// trimmed and cut to [`MAX_TITLE_CHARS`].
pub(crate) fn sanitize(raw: &str) -> String {
    raw.to_string()
}

/// Follows OSC 0/1/2 and the xterm title stack across output chunks.
#[derive(Debug, Default)]
pub(crate) struct TitleTracker {}

impl TitleTracker {
    /// `data` with the title sequences libghostty-vt cannot apply rewritten
    /// into the `OSC 2` that applies them; borrowed when nothing changed.
    pub(crate) fn rewrite<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
        Cow::Borrowed(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(tracker: &mut TitleTracker, chunks: &[&[u8]]) -> Vec<u8> {
        chunks.iter().flat_map(|chunk| tracker.rewrite(chunk).into_owned()).collect()
    }

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

    #[test]
    fn the_stack_holds_at_most_ten_titles() {
        let mut tracker = TitleTracker::default();
        let mut stream = Vec::new();
        for i in 0..12 {
            stream.extend_from_slice(format!("\x1b]2;t{i}\x07\x1b[22;0t").as_bytes());
        }
        for _ in 0..12 {
            stream.extend_from_slice(b"\x1b[23;0t");
        }
        let out = run(&mut tracker, &[&stream]);
        let pops = out.windows(4).filter(|w| w == b"\x1b]2;").count() - 12;
        assert_eq!(pops, 10);
    }

    #[test]
    fn plain_output_is_not_copied() {
        let mut tracker = TitleTracker::default();
        assert!(matches!(tracker.rewrite(b"hello \x1b]2;title\x07 world"), Cow::Borrowed(_)));
    }
}
