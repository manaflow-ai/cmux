//! Synthesized Claude Code transcript rows: what a long session leaves in a terminal's
//! scrollback. Each row is valid UTF-8 ending in `\r\n`: prompts on a grey band, `● ` replies and
//! tool calls in 256-color and truecolor SGR, `  ⎿  ` tool results, diff lines on red and green
//! backgrounds, bold headers, some wide (CJK) text, visible widths up to about 100 columns. The
//! words come from the recorded session's printable text plus a fixed vocabulary; every choice is
//! a draw from the seeded generator, so a seed gives the same bytes.

use cmux_fault::Rng;

/// Words every generator has, beside the recording's.
const VOCABULARY: &[&str] = &[
    "the",
    "function",
    "returns",
    "error",
    "cargo",
    "test",
    "build",
    "passes",
    "fails",
    "file",
    "src/main.rs",
    "Cargo.toml",
    "let",
    "fn",
    "struct",
    "impl",
    "match",
    "Some(x)",
    "None",
    "Ok(())",
    "update",
    "render",
    "terminal",
    "scrollback",
    "frame",
    "commit",
    "branch",
    "review",
    "diff",
    "async",
    "await",
    "self",
    "pub",
    "use",
    "crate::",
    "→",
    "✓",
    "…",
    "—",
    "Read",
    "Edit",
    "Bash",
];
/// Wide text: two columns a character.
const WIDE: &[&str] =
    &["日本語のテキスト", "中文字符测试", "한국어 텍스트", "全角文字", "終端の再描画"];
const TOOLS: &[&str] = &["Bash", "Read", "Edit", "Write", "Grep", "Glob", "Task", "WebFetch"];

/// Writes rows; one per [`Rows::push_row`].
pub struct Rows {
    rng: Rng,
    words: Vec<String>,
    /// The line number a diff block is at.
    diff_line: u64,
    /// Rows left in the current block, and its kind.
    block: (u32, Kind),
}

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Prompt,
    Reply,
    Tool,
    Result,
    Diff,
    Header,
    Blank,
}

impl Rows {
    /// `recorded` is the recording's vocabulary ([`crate::inputs::printable_words`]).
    pub fn new(rng: Rng, recorded: &[String]) -> Self {
        let mut words: Vec<String> = VOCABULARY.iter().map(|w| (*w).to_owned()).collect();
        words.extend(recorded.iter().cloned());
        Self { rng, words, diff_line: 1, block: (0, Kind::Blank) }
    }

    /// Appends one row to `out`.
    pub fn push_row(&mut self, out: &mut Vec<u8>) {
        if self.block.0 == 0 {
            self.block = self.next_block();
        }
        self.block.0 -= 1;
        let kind = self.block.1;
        let mut row = String::with_capacity(160);
        match kind {
            Kind::Prompt => {
                row.push_str("\x1b[48;5;237m\x1b[38;5;246m❯ \x1b[38;5;231m");
                self.text(&mut row, 20, 96);
                row.push_str("\x1b[39m\x1b[49m");
            }
            Kind::Reply => {
                if self.block.0 % 4 == 3 || self.rng.chance(30) {
                    row.push_str("\x1b[38;5;231m● \x1b[39m");
                } else {
                    row.push_str("  ");
                }
                self.text(&mut row, 0, 98);
            }
            Kind::Tool => {
                let tool = *self.rng.pick(TOOLS);
                row.push_str("\x1b[38;2;78;186;101m● \x1b[39m\x1b[1m");
                row.push_str(tool);
                row.push_str("\x1b[22m(");
                self.text(&mut row, 8, 70);
                row.push(')');
            }
            Kind::Result => {
                row.push_str("\x1b[38;5;246m  ⎿  \x1b[39m");
                self.text(&mut row, 4, 90);
            }
            Kind::Diff => {
                let sign = self.rng.range(0, 2);
                let (background, foreground, mark) = match sign {
                    0 => ("\x1b[48;2;61;1;0m", "\x1b[38;2;255;220;220m", '-'),
                    1 => ("\x1b[48;2;2;40;0m", "\x1b[38;2;220;255;220m", '+'),
                    _ => ("", "\x1b[38;5;246m", ' '),
                };
                row.push_str(&format!("      {:>4} ", self.diff_line));
                self.diff_line += 1;
                row.push_str(background);
                row.push_str(foreground);
                row.push(mark);
                row.push_str("  ");
                self.text(&mut row, 0, 84);
                row.push_str("\x1b[0m");
            }
            Kind::Header => {
                row.push_str("\x1b[1m\x1b[38;5;174m## ");
                self.text(&mut row, 8, 40);
                row.push_str("\x1b[22m\x1b[39m");
            }
            Kind::Blank => {}
        }
        out.extend_from_slice(row.as_bytes());
        out.extend_from_slice(b"\r\n");
    }

    fn next_block(&mut self) -> (u32, Kind) {
        let kind = match self.rng.range(0, 99) {
            0..=4 => Kind::Prompt,
            5..=39 => Kind::Reply,
            40..=54 => Kind::Tool,
            55..=74 => Kind::Result,
            75..=89 => Kind::Diff,
            90..=94 => Kind::Header,
            _ => Kind::Blank,
        };
        let rows = match kind {
            Kind::Prompt | Kind::Header | Kind::Tool => 1,
            Kind::Blank => self.rng.range(1, 2),
            Kind::Reply => self.rng.range(1, 8),
            Kind::Result => self.rng.range(1, 6),
            Kind::Diff => {
                self.diff_line = self.rng.range(1, 900);
                self.rng.range(3, 14)
            }
        };
        (rows as u32, kind)
    }

    /// Words until the row's visible text reaches a drawn width in `min..=max` columns.
    fn text(&mut self, row: &mut String, min: u64, max: u64) {
        let target = self.rng.range(min, max);
        let mut width = 0;
        while width < target {
            let word: &str = if self.rng.chance(4) {
                self.rng.pick::<&str>(WIDE)
            } else {
                self.rng.pick(&self.words).as_str()
            };
            let word_width = columns(word);
            if width > 0 && width + 1 + word_width > max {
                break;
            }
            if width > 0 {
                row.push(' ');
                width += 1;
            }
            row.push_str(word);
            width += word_width;
        }
    }
}

/// Columns a word takes: two for the East Asian wide ranges the vocabulary uses.
fn columns(word: &str) -> u64 {
    word.chars()
        .map(|c| match c as u32 {
            0x1100..=0x115F
            | 0x2E80..=0xA4CF
            | 0xAC00..=0xD7A3
            | 0xF900..=0xFAFF
            | 0xFF00..=0xFF60 => 2,
            _ => 1,
        })
        .sum()
}

/// The scrollback file: the recorded session's banner (its first write of 512 bytes or more,
/// ending in `\r\n`), then `rows` synthesized rows. Returns the bytes and the banner's length.
/// No rows is an empty file.
pub fn history(rows: u64, banner: &[u8], generator: &mut Rows) -> (Vec<u8>, usize) {
    if rows == 0 {
        return (Vec::new(), 0);
    }
    let mut out = Vec::with_capacity(banner.len() + rows as usize * 120);
    out.extend_from_slice(banner);
    if !out.ends_with(b"\r\n") {
        out.extend_from_slice(b"\r\n");
    }
    let prefix = out.len();
    for _ in 0..rows {
        generator.push_row(&mut out);
    }
    (out, prefix)
}
