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

use crate::panic_free::split_once_byte;

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

/// How many pushed titles the stack keeps, as xterm does.
const MAX_STACK: usize = 10;
/// The most title bytes kept: libghostty-vt cuts a title to 1024 bytes too.
const MAX_TITLE_BYTES: usize = 1024;
/// The most CSI parameter bytes followed; a longer CSI is no title op.
const MAX_CSI_BYTES: usize = 16;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum ScanState {
    #[default]
    Ground,
    Escape,
    Csi,
    /// A CSI too long or too odd to be a title op: skipped to its final byte.
    CsiIgnore,
    Osc,
    /// An ESC inside an OSC: `\` ends it (ST), anything else aborts it.
    OscEscape,
}

/// Follows OSC 0/1/2 and the xterm title stack across output chunks.
#[derive(Debug, Default)]
pub(crate) struct TitleTracker {
    state: ScanState,
    csi: Vec<u8>,
    osc: Vec<u8>,
    /// The title as the stream set it: what a push saves.
    title: Vec<u8>,
    /// An OSC 0 or 2 set the title; from then on OSC 1 names only the icon.
    titled: bool,
    stack: Vec<Vec<u8>>,
}

impl TitleTracker {
    /// `data` with the title sequences libghostty-vt cannot apply rewritten
    /// into the `OSC 2` that applies them; borrowed when nothing changed.
    #[allow(clippy::indexing_slicing, reason = "INVARIANT: copied <= index + 1 <= data.len()")]
    pub(crate) fn rewrite<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
        let mut out: Option<Vec<u8>> = None;
        let mut copied = 0;
        for (index, &byte) in data.iter().enumerate() {
            let Some(title) = self.step(byte) else { continue };
            let out = out.get_or_insert_with(|| Vec::with_capacity(data.len() + title.len() + 6));
            out.extend_from_slice(&data[copied..=index]);
            copied = index + 1;
            out.extend_from_slice(b"\x1b]2;");
            out.extend_from_slice(&title);
            out.push(0x07);
        }
        match out {
            None => Cow::Borrowed(data),
            Some(mut out) => {
                out.extend_from_slice(&data[copied..]);
                Cow::Owned(out)
            }
        }
    }

    /// Advances over one byte; `Some(title)` when the sequence it ends needs
    /// an `OSC 2 ; title` right after it.
    fn step(&mut self, byte: u8) -> Option<Vec<u8>> {
        match self.state {
            ScanState::Ground => {
                if byte == 0x1b {
                    self.state = ScanState::Escape;
                }
                None
            }
            ScanState::Escape => {
                self.state = match byte {
                    b'[' => {
                        self.csi.clear();
                        ScanState::Csi
                    }
                    b']' => {
                        self.osc.clear();
                        ScanState::Osc
                    }
                    0x1b => ScanState::Escape,
                    _ => ScanState::Ground,
                };
                None
            }
            ScanState::Csi | ScanState::CsiIgnore => match byte {
                0x40..=0x7e => {
                    let ignored = self.state == ScanState::CsiIgnore;
                    self.state = ScanState::Ground;
                    (!ignored && byte == b't').then(|| self.window_op()).flatten()
                }
                0x1b => {
                    self.state = ScanState::Escape;
                    None
                }
                0x18 | 0x1a => {
                    self.state = ScanState::Ground;
                    None
                }
                b'0'..=b'9' | b';'
                    if self.state == ScanState::Csi && self.csi.len() < MAX_CSI_BYTES =>
                {
                    self.csi.push(byte);
                    None
                }
                // C0 controls run inside a CSI without ending it.
                0x00..=0x1f => None,
                _ => {
                    self.state = ScanState::CsiIgnore;
                    None
                }
            },
            ScanState::Osc => match byte {
                0x07 => {
                    self.state = ScanState::Ground;
                    self.osc_end()
                }
                0x1b => {
                    self.state = ScanState::OscEscape;
                    None
                }
                0x18 | 0x1a => {
                    self.state = ScanState::Ground;
                    None
                }
                _ => {
                    if self.osc.len() < MAX_TITLE_BYTES + 8 {
                        self.osc.push(byte);
                    }
                    None
                }
            },
            ScanState::OscEscape => {
                if byte == b'\\' {
                    self.state = ScanState::Ground;
                    return self.osc_end();
                }
                // Another sequence aborted the OSC: the terminal applied it,
                // but nothing can go between this ESC and its sequence.
                let _ = self.osc_end();
                self.state = ScanState::Escape;
                self.step(byte)
            }
        }
    }

    /// `CSI Ps ; Ps t`: 22 pushes and 23 pops the title (second parameter 0,
    /// 2 or none; 1 is the icon name only).
    fn window_op(&mut self) -> Option<Vec<u8>> {
        let mut params = self.csi.split(|&b| b == b';');
        let op = params.next().filter(|p| !p.is_empty());
        let which = params.next().filter(|p| !p.is_empty());
        let which_title = matches!(which, None | Some(b"0") | Some(b"2"));
        match op {
            Some(b"22") if which_title => {
                if self.stack.len() == MAX_STACK {
                    self.stack.remove(0);
                }
                self.stack.push(self.title.clone());
                None
            }
            Some(b"23") if which_title => {
                let title = self.stack.pop()?;
                self.title = title.clone();
                Some(title)
            }
            _ => None,
        }
    }

    fn osc_end(&mut self) -> Option<Vec<u8>> {
        let (command, payload) = split_once_byte(&self.osc, b';')?;
        let payload = clip_utf8(payload, MAX_TITLE_BYTES);
        match command {
            b"0" | b"2" => {
                self.title = payload.to_vec();
                self.titled = true;
                None
            }
            b"1" if !self.titled => {
                self.title = payload.to_vec();
                Some(self.title.clone())
            }
            _ => None,
        }
    }
}

/// At most `max` bytes of `bytes`, never ending inside a UTF-8 sequence.
#[allow(clippy::indexing_slicing, reason = "INVARIANT: end <= max < bytes.len()")]
fn clip_utf8(bytes: &[u8], max: usize) -> &[u8] {
    if bytes.len() <= max {
        return bytes;
    }
    let mut end = max;
    while end > 0 && (bytes[end] & 0xC0) == 0x80 {
        end -= 1;
    }
    &bytes[..end]
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
        let pops = out.windows(4).filter(|w| *w == b"\x1b]2;").count() - 12;
        assert_eq!(pops, 10);
    }

    #[test]
    fn plain_output_is_not_copied() {
        let mut tracker = TitleTracker::default();
        assert!(matches!(tracker.rewrite(b"hello \x1b]2;title\x07 world"), Cow::Borrowed(_)));
    }
}
