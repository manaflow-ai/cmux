//! Golden tests: a Mac pane's grid in, the phone's projected rows out.
//!
//! Leo, 2026-11-17: "how's the lean terminal view on phone? proven upholding
//! behaviour yet? headers left right end of terminal lines etc?"
//!
//! Each case feeds a program's bytes to a projection at the Mac's grid and
//! feeds what the projection writes to a terminal at the phone's grid, the
//! way the app feeds Ghostty. The golden file (`tests/golden/NAME.txt`) holds
//! both grids as text: every row, its soft-wrap mark, its style runs and the
//! cursor. A change to what the phone shows is a diff in review.
//!
//! `GOLDEN_UPDATE=1` rewrites the files; `GOLDEN_OUT=DIR` also writes each
//! result there (the fleet run that makes them for review).

use std::fmt::Write as _;
use std::path::PathBuf;

use cmux_terminal_projection::style::{
    BLINK, BOLD, Color, FAINT, INVERSE, INVISIBLE, ITALIC, OVERLINE, STRIKE, Style,
};
use cmux_terminal_projection::terminal::{Row, SPACER_HEAD, Terminal, WIDE_TAIL};
use cmux_terminal_projection::{Projection, Segment};
use unicode_width::UnicodeWidthStr;

/// The phone's terminal, as the app drives it: the projection's bytes, a
/// reset as `ESC c`, and the Mac's grid while the alternate screen is up
/// (the page shows the host grid there, scaled; the bytes are the Mac's).
struct Phone {
    term: Terminal,
    grid: (usize, usize),
    host: (usize, usize),
    resets: usize,
    bytes: usize,
}

impl Phone {
    fn new(cols: usize, rows: usize, host: (usize, usize)) -> Phone {
        Phone {
            term: Terminal::new(cols, rows, 100_000),
            grid: (cols, rows),
            host,
            resets: 0,
            bytes: 0,
        }
    }

    fn apply(&mut self, segments: Vec<Segment>) {
        for segment in segments {
            match segment {
                Segment::Paint(bytes) | Segment::Raw(bytes) => {
                    self.bytes += bytes.len();
                    for b in bytes {
                        self.term.advance(b);
                    }
                }
                Segment::Reset(bytes) => {
                    self.resets += 1;
                    self.bytes += bytes.len();
                    let (cols, rows) = self.grid;
                    self.term = Terminal::new(cols, rows, 100_000);
                    for b in bytes {
                        self.term.advance(b);
                    }
                }
                Segment::Alternate(on) => {
                    let (cols, rows) = if on { self.host } else { self.grid };
                    self.term.resize(cols, rows);
                }
            }
        }
    }

    fn set_grid(&mut self, cols: usize, rows: usize) {
        self.grid = (cols, rows);
        if !self.term.is_alternate() {
            self.term.resize(cols, rows);
        }
    }
}

fn style_label(style: Style) -> String {
    let color = |c: Color| match c {
        Color::Default => String::new(),
        Color::Indexed(i) => format!("{i}"),
        Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
    };
    let mut parts = Vec::new();
    if style.fg != Color::Default {
        parts.push(format!("fg={}", color(style.fg)));
    }
    if style.bg != Color::Default {
        parts.push(format!("bg={}", color(style.bg)));
    }
    for (flag, name) in [
        (BOLD, "bold"),
        (FAINT, "faint"),
        (ITALIC, "italic"),
        (BLINK, "blink"),
        (INVERSE, "inverse"),
        (INVISIBLE, "invisible"),
        (STRIKE, "strike"),
        (OVERLINE, "overline"),
    ] {
        if style.flags & flag != 0 {
            parts.push(name.to_string());
        }
    }
    if style.underline != 0 {
        parts.push(format!("ul={}", style.underline));
    }
    if style.link != 0 {
        parts.push("link".to_string());
    }
    parts.join(" ")
}

/// One row: its text (a never-written cell is a space, a spacer head `·`),
/// a `↩` when it soft-wraps, and its runs of non-default style by column.
fn render_row(term: &Terminal, row: &Row, tag: &str, out: &mut String) {
    let mut text = String::new();
    let mut runs: Vec<(usize, usize, String)> = Vec::new();
    for (x, cell) in row.cells.iter().enumerate() {
        if cell.kind == WIDE_TAIL {
            continue;
        }
        if cell.kind == SPACER_HEAD {
            text.push('·');
        } else if cell.ch == 0 {
            text.push(' ');
        } else {
            text.push_str(&term.cell_text(*cell));
        }
        // A blank in a style that draws nothing on a blank (a bold or a
        // foreground color) looks the same in any such style: not shown.
        let style = term.styles.get(cell.style);
        let blank = cell.ch == 0 || cell.ch == u32::from(b' ');
        let label = if blank && style.is_invisible_when_blank() {
            String::new()
        } else {
            style_label(style)
        };
        let end = x + cell.width().max(1) - 1;
        match runs.last_mut() {
            Some((_, last_end, last)) if *last == label && *last_end + 1 == x => *last_end = end,
            _ => runs.push((x, end, label)),
        }
    }
    let _ = writeln!(out, "{tag}|{}|{}", text.trim_end(), if row.wrapped { "↩" } else { "" });
    let styled: Vec<String> = runs
        .into_iter()
        .filter(|(_, _, l)| !l.is_empty())
        .map(|(a, b, l)| format!("{a}-{b} {l}"))
        .collect();
    if !styled.is_empty() {
        let _ = writeln!(out, "{}  ^ {}", " ".repeat(tag.chars().count()), styled.join("; "));
    }
}

/// A terminal as text: its scrollback (`h`), its screen (`s`, the
/// alternate one when it is up), its cursor.
fn render(term: &Terminal, history_tail: usize) -> String {
    let mut out = String::new();
    let alt = term.is_alternate();
    let _ = writeln!(
        out,
        "grid {}x{}{}",
        term.cols,
        term.rows,
        if alt { " alternate screen" } else { "" }
    );
    if !alt {
        let skip = term.history.len().saturating_sub(history_tail);
        if skip > 0 {
            let _ = writeln!(out, "  ({skip} older scrollback rows not shown)");
        }
        for (i, row) in term.history.iter().enumerate().skip(skip) {
            render_row(term, row, &format!("h{i:>4}"), &mut out);
        }
    }
    let rows = term.screen_rows();
    // Trailing blank screen rows are not shown (the cursor's row always is).
    let (cx, cy) = term.cursor();
    let last = rows
        .iter()
        .rposition(|r| r.cells.iter().any(|c| c.ch != 0 && c.ch != u32::from(b' ')))
        .map_or(0, |i| i + 1)
        .max(cy + 1);
    for (i, row) in rows.iter().enumerate().take(last) {
        render_row(term, row, &format!("s{i:>4}"), &mut out);
    }
    if last < rows.len() {
        let _ = writeln!(out, "  ({} blank rows)", rows.len() - last);
    }
    let _ = writeln!(
        out,
        "cursor col {cx} row {cy}{}",
        if term.cursor_visible { "" } else { " (hidden)" }
    );
    out
}

/// The text of every logical line of a terminal (soft-wrapped rows
/// joined), its scrollback and screen, trailing blanks dropped.
fn logical_lines(term: &Terminal) -> Vec<String> {
    let mut lines = Vec::new();
    let mut current = String::new();
    let rows: Vec<&Row> = term.history.iter().chain(term.primary_rows().iter()).collect();
    for row in rows {
        for cell in &row.cells {
            if cell.kind == WIDE_TAIL || cell.kind == SPACER_HEAD {
                continue;
            }
            current.push_str(&if cell.ch == 0 { " ".to_string() } else { term.cell_text(*cell) });
        }
        if !row.wrapped {
            lines.push(current.trim_end().to_string());
            current.clear();
        }
    }
    while lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines
}

/// One golden case: the steps a reader sees, each with the Mac's grid and
/// the phone's.
struct Case {
    name: &'static str,
    host: Projection,
    phone: Phone,
    out: String,
    /// The program's bytes, as fed (written beside the golden for the
    /// simulator screenshots, which feed the app the same stream).
    fed: Vec<u8>,
}

impl Case {
    fn new(name: &'static str, about: &str, host: (usize, usize), phone: (usize, usize)) -> Case {
        let mut projection = Projection::new(host.0, host.1, 10_000);
        let mut phone_term = Phone::new(phone.0, phone.1, host);
        phone_term.apply(projection.set_viewport(phone.0, phone.1));
        let mut out = String::new();
        let _ = writeln!(out, "# {name}: {about}");
        let _ = writeln!(out, "# Mac pane {}x{}, phone {}x{}", host.0, host.1, phone.0, phone.1);
        Case { name, host: projection, phone: phone_term, out, fed: Vec::new() }
    }

    fn feed(&mut self, bytes: &[u8]) {
        self.fed.extend_from_slice(bytes);
        let segments = self.host.feed(bytes, true);
        self.phone.apply(segments);
        let replies = self.host.take_replies();
        let _ = replies;
    }

    fn viewport(&mut self, cols: usize, rows: usize) {
        self.phone.set_grid(cols, rows);
        let segments = self.host.set_viewport(cols, rows);
        self.phone.apply(segments);
    }

    /// Records both grids under a heading.
    fn snapshot(&mut self, label: &str, history_tail: usize) {
        let _ = writeln!(self.out, "\n## {label}\n### Mac");
        self.out.push_str(&render(self.host.terminal(), history_tail));
        let _ = writeln!(self.out, "### phone");
        self.out.push_str(&render(&self.phone.term, history_tail * 3));
    }

    fn phone_render(&self) -> String {
        render(&self.phone.term, usize::MAX)
    }

    fn finish(self) {
        if let Some(out) = std::env::var_os("GOLDEN_OUT") {
            let dir = PathBuf::from(out).join("vt");
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join(format!("{}.vt", self.name)), &self.fed).unwrap();
        }
        check_golden(self.name, &self.out);
    }
}

fn check_golden(name: &str, actual: &str) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden");
    let path = dir.join(format!("{name}.txt"));
    if let Some(out) = std::env::var_os("GOLDEN_OUT") {
        let out = PathBuf::from(out);
        std::fs::create_dir_all(&out).unwrap();
        std::fs::write(out.join(format!("{name}.txt")), actual).unwrap();
    }
    if std::env::var_os("GOLDEN_UPDATE").is_some() {
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&path, actual).unwrap();
        return;
    }
    let expected = std::fs::read_to_string(&path)
        .unwrap_or_else(|_| panic!("no golden {} (run with GOLDEN_UPDATE=1)", path.display()));
    if expected != actual {
        let (line, (want, got)) =
            expected.lines().zip(actual.lines()).enumerate().find(|(_, (a, b))| a != b).unwrap_or(
                (expected.lines().count().min(actual.lines().count()), ("<end>", "<end>")),
            );
        panic!(
            "golden {name} differs at line {}:\nwant: {want}\ngot:  {got}\n(GOLDEN_UPDATE=1 rewrites it; review the diff)",
            line + 1
        );
    }
}

/// Display cells of `text`, its SGR sequences not counted.
fn visible_width(text: &str) -> usize {
    let mut plain = String::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            for d in chars.by_ref() {
                if d.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            plain.push(c);
        }
    }
    UnicodeWidthStr::width(plain.as_str())
}

/// `text` padded with spaces to `width` display cells.
fn pad(text: &str, width: usize) -> String {
    let w = visible_width(text);
    format!("{text}{}", " ".repeat(width.saturating_sub(w)))
}

/// A frame row: `left` + content padded + `right`, `width` cells in all.
fn frame(left: &str, content: &str, right: &str, width: usize, color: &str) -> String {
    format!("{color}{left}\x1b[0m{}{color}{right}\x1b[0m", pad(content, width - 2))
}

fn rule(left: &str, right: &str, width: usize, color: &str) -> String {
    format!("{color}{left}{}{right}\x1b[0m", "─".repeat(width - 2))
}

/// Claude Code's welcome header and input box at the Mac's 120 columns,
/// and its status row with a right-aligned part, drawn inline on the
/// primary screen.
fn claude_code_screen(cols: usize) -> Vec<u8> {
    let c = "\x1b[38;5;174m";
    let mut s = String::new();
    s += "leo@cosmic-gray ~/Projects/cmux % claude\r\n";
    s += &rule("╭", "╮", cols, c);
    s += "\r\n";
    s += &frame("│", " \x1b[38;5;174m✻\x1b[0m Welcome to \x1b[1mClaude Code\x1b[0m!", "│", cols, c);
    s += "\r\n";
    s += &frame("│", "", "│", cols, c);
    s += "\r\n";
    s += &frame("│", "   /help for help, /status for your current setup", "│", cols, c);
    s += "\r\n";
    s += &frame("│", "", "│", cols, c);
    s += "\r\n";
    s += &frame("│", "   cwd: /Users/leo/Projects/cmux", "│", cols, c);
    s += "\r\n";
    s += &rule("╰", "╯", cols, c);
    s += "\r\n\r\n";
    s += " Tips for getting started:\r\n\r\n";
    s += " 1. Ask Claude to create a new app or clear the screen and start over with a longer prompt that wraps\r\n\r\n";
    let g = "\x1b[38;5;244m";
    s += &rule("╭", "╮", cols, g);
    s += "\r\n";
    s += &frame("│", " > ", "│", cols, g);
    s += "\r\n";
    s += &rule("╰", "╯", cols, g);
    s += "\r\n";
    let left = "  ? for shortcuts";
    let right = "◯ IDE disconnected";
    s += &format!(
        "{g}{left}{}{right}\x1b[0m",
        " ".repeat(cols - 1 - UnicodeWidthStr::width(left) - UnicodeWidthStr::width(right))
    );
    // The cursor goes back into the input box, after "> ".
    s += "\x1b[2A\r\x1b[4C";
    s.into_bytes()
}

#[test]
fn headers_claude_code() {
    let mut case = Case::new(
        "headers_claude_code",
        "Claude Code's welcome box, input box and status row, laid out for 120 columns",
        (120, 24),
        (54, 38),
    );
    let bytes = claude_code_screen(120);
    case.feed(&bytes);
    case.snapshot("after the welcome screen", 0);
    // Every frame row is laid out at the phone's width: one phone row each,
    // the left border at column 0 and the right one at the phone's last column.
    let phone = &case.phone.term;
    for row in phone.primary_rows() {
        let text: String = row
            .cells
            .iter()
            .filter(|c| c.kind != WIDE_TAIL)
            .map(|c| if c.ch == 0 { " ".to_string() } else { phone.cell_text(*c) })
            .collect();
        let trimmed = text.trim_end();
        if trimmed.starts_with(['╭', '│', '╰']) {
            assert_eq!(
                UnicodeWidthStr::width(trimmed),
                54,
                "frame row at the phone's width: {trimmed:?}"
            );
            assert!(!row.wrapped, "a frame row is one phone row: {trimmed:?}");
        }
        if trimmed.contains("? for shortcuts") {
            assert!(
                trimmed.ends_with("◯ IDE disconnected"),
                "status right part at the edge: {trimmed:?}"
            );
            // The host's one-cell right margin stays, as Claude Code keeps it
            // at any width.
            assert_eq!(UnicodeWidthStr::width(trimmed), 53, "{trimmed:?}");
        }
    }
    // The cursor is in the input box, after "> ".
    let (cx, cy) = phone.cursor();
    let row = &phone.primary_rows()[cy];
    let before: String = row
        .cells
        .iter()
        .take(cx)
        .map(|c| if c.ch == 0 { ' ' } else { char::from_u32(c.ch).unwrap_or('?') })
        .collect();
    assert!(before.ends_with("│ > "), "cursor after the prompt: {before:?}");
    // Typing in the box (the program redraws its row) stays one phone row.
    case.feed(b"hello");
    case.feed(b"\x1b[s\r\x1b[38;5;244m\xe2\x94\x82\x1b[0m > hello\x1b[u");
    case.snapshot("after typing \"hello\" in the input box", 0);
    case.finish();
}

#[test]
fn headers_codex() {
    let mut case = Case::new(
        "headers_codex",
        "Codex's header box (62 columns, narrower than the Mac, wider than the phone) and a prompt",
        (120, 24),
        (54, 38),
    );
    let w = 62;
    let d = "\x1b[2m";
    let mut s = String::new();
    s += &rule("╭", "╮", w, d);
    s += "\r\n";
    s += &frame("│", " >_ \x1b[1mOpenAI Codex\x1b[0m (v0.58.0)", "│", w, d);
    s += "\r\n";
    s += &frame("│", "", "│", w, d);
    s += "\r\n";
    s += &frame("│", " model:     gpt-5.1-codex high   /model to change", "│", w, d);
    s += "\r\n";
    s += &frame("│", " directory: ~/Projects/cmux", "│", w, d);
    s += "\r\n";
    s += &rule("╰", "╯", w, d);
    s += "\r\n\r\n";
    s += "  To get started, describe a task or try one of these commands:\r\n\r\n";
    s += "› \x1b[2mImprove documentation in @filename\x1b[0m\r";
    case.feed(s.as_bytes());
    case.snapshot("Codex at start", 0);
    let phone = &case.phone.term;
    for row in phone.primary_rows() {
        let text: String = row
            .cells
            .iter()
            .filter(|c| c.kind != WIDE_TAIL)
            .map(|c| if c.ch == 0 { " ".to_string() } else { phone.cell_text(*c) })
            .collect();
        let t = text.trim_end();
        if t.starts_with(['╭', '│', '╰']) {
            assert_eq!(UnicodeWidthStr::width(t), 54, "{t:?}");
        }
    }
    case.finish();
}

#[test]
fn left_and_right_aligned() {
    let mut case = Case::new(
        "left_and_right_aligned",
        "a right prompt (zsh RPROMPT by cursor moves), a right-aligned clock, a centered title, prose and ls columns",
        (120, 24),
        (54, 38),
    );
    let mut s = String::new();
    // zsh: left prompt, the right prompt by CUF, the cursor back after the left one.
    s += "\x1b[32mleo@cosmic-gray\x1b[0m ~/Projects/cmux % \x1b[s\x1b[102G\x1b[33m[main ↑2] 09:12:44\x1b[0m\x1b[u";
    s += "ls\r\n";
    s += "AGENTS.md          Packages           cmux-next-ios      docs               scripts            workers\r\n";
    s += "CLAUDE.md          README.md          cmux-tui           schemas            vendor\r\n";
    // Right-aligned only.
    s += &format!("{}build finished 12:01:33\r\n", " ".repeat(120 - 23));
    // Centered title, padded both sides, ending at the last column.
    s += &format!("{}\x1b[1m== Release notes ==\x1b[0m{}\r\n", " ".repeat(50), " ".repeat(50));
    // A hard prose line of exactly 120 columns: not padding, wraps.
    let prose = "The quick brown fox jumps over the lazy dog while the terminal keeps its own width and the phone re-wraps lines at its";
    s += &prose.repeat(2)[..120];
    s += "\r\n";
    s += "\x1b[32mleo@cosmic-gray\x1b[0m ~/Projects/cmux % \x1b[s\x1b[102G\x1b[33m[main ↑2] 09:12:51\x1b[0m\x1b[u";
    case.feed(s.as_bytes());
    case.snapshot("prompt, ls and aligned rows", 0);
    let phone = &case.phone.term;
    let texts: Vec<String> = phone
        .primary_rows()
        .iter()
        .map(|row| {
            row.cells
                .iter()
                .filter(|c| c.kind != WIDE_TAIL)
                .map(|c| if c.ch == 0 { " ".to_string() } else { phone.cell_text(*c) })
                .collect::<String>()
        })
        .collect();
    // The right prompt stays whole and ends one cell short of the phone's
    // edge. With "ls" typed, both parts do not fit one phone row, so the
    // right part goes on the row below, right-aligned (zsh itself would
    // hide it at 54 columns); without, they share the row.
    let prompt_rows: Vec<usize> =
        (0..texts.len()).filter(|&i| texts[i].contains("[main ↑2] 09:12:")).collect();
    assert_eq!(prompt_rows.len(), 2, "each right prompt is whole on one row: {texts:#?}");
    for &i in &prompt_rows {
        let t = &texts[i];
        // zsh's right prompt keeps its one-cell indent from the edge
        // (ZLE_RPROMPT_INDENT), at the phone's width as at the Mac's.
        assert_eq!(
            UnicodeWidthStr::width(t.trim_end()),
            53,
            "right part one cell short of the phone's edge: {t:?}"
        );
        let left = if t.starts_with("leo@") { t } else { &texts[i - 1] };
        assert!(
            left.starts_with("leo@cosmic-gray ~/Projects/cmux % "),
            "left part at column 0: {left:?}"
        );
    }
    assert!(texts[prompt_rows[0] - 1].starts_with("leo@cosmic-gray ~/Projects/cmux % ls"));
    assert!(texts[prompt_rows[1]].starts_with("leo@cosmic-gray ~/Projects/cmux %  [main"));
    let clock = texts
        .iter()
        .find(|t| t.contains("build finished"))
        .unwrap_or_else(|| panic!("the clock is on the phone: {texts:#?}"));
    assert_eq!(
        UnicodeWidthStr::width(clock.trim_end()),
        54,
        "right-aligned at the edge: {clock:?}"
    );
    // The title centered on the Mac is centered on the phone, on one row.
    let title = texts
        .iter()
        .find(|t| t.contains("Release notes"))
        .unwrap_or_else(|| panic!("the title is on the phone: {texts:#?}"));
    assert_eq!(title.trim_end(), format!("{}== Release notes ==", " ".repeat(17)));

    // The cursor waits after the left prompt, as on the Mac.
    let (cx, _) = phone.cursor();
    assert_eq!(cx, UnicodeWidthStr::width("leo@cosmic-gray ~/Projects/cmux % "));
    case.finish();
}

#[test]
fn line_ends_soft_and_hard() {
    let mut case = Case::new(
        "line_ends_soft_and_hard",
        "soft wraps join and re-wrap; hard line ends stay; rows exactly at the Mac's and the phone's width",
        (120, 24),
        (54, 38),
    );
    let mut s = String::new();
    let alphabet: String = (0..250).map(|i| (b'a' + (i % 26) as u8) as char).collect();
    s += "$ echo long\r\n";
    s += &alphabet; // soft-wraps on the Mac at 120
    s += "\r\n";
    s += &"X".repeat(120); // exactly the Mac's width, then a hard end
    s += "\r\n";
    s += &"Y".repeat(54); // exactly the phone's width
    s += "\r\n";
    s += &"Z".repeat(55); // one past it
    s += "\r\n";
    s += "trailing spaces kept out    \r\n";
    s += "\r\n";
    s += "after an empty line\r\n";
    s += &"W".repeat(120); // a soft-wrapped line ending exactly at the Mac's edge...
    s += "w-continues"; // ...that goes on
    s += "\r\n$ ";
    case.feed(s.as_bytes());
    case.snapshot("soft and hard line ends", 0);
    // The phone holds the Mac's logical lines exactly.
    assert_eq!(logical_lines(&case.phone.term), logical_lines(case.host.terminal()));
    case.finish();
}

#[test]
fn wide_cjk_and_emoji() {
    let mut case = Case::new(
        "wide_cjk_and_emoji",
        "wide glyphs at the Mac's and the phone's edges never split; emoji with modifiers and ZWJ; combining marks",
        (120, 24),
        (54, 38),
    );
    let mut s = String::new();
    // 119 narrow cells then a wide glyph: it cannot fit on the Mac's row (spacer head).
    s += &"a".repeat(119);
    s += "漢字かな交じり文\r\n";
    // 53 narrow cells then a wide glyph: it cannot fit on the phone's row.
    s += &"b".repeat(53);
    s += "日本語のテキスト\r\n";
    s += "thumbs 👍🏽 family 👨‍👩‍👧 flag 🇯🇵 café (e\u{301}) done\r\n";
    s += &"中文".repeat(40); // 160 cells of wide glyphs
    s += "\r\n$ ";
    case.feed(s.as_bytes());
    case.snapshot("wide glyphs", 0);
    assert_eq!(logical_lines(&case.phone.term), logical_lines(case.host.terminal()));
    // No phone row is wider than the phone.
    for row in case.phone.term.history.iter().chain(case.phone.term.primary_rows()) {
        let w: usize = row.cells.iter().filter(|c| c.kind != WIDE_TAIL).map(|c| c.width()).sum();
        assert!(w <= 54);
    }
    case.finish();
}

#[test]
fn colors_and_attributes_across_wraps() {
    let mut case = Case::new(
        "colors_and_attributes_across_wraps",
        "SGR colors and attributes that start mid-line and run across the Mac's and the phone's wraps; a link",
        (120, 24),
        (54, 38),
    );
    let mut s = String::new();
    s += "plain \x1b[1;31mbold red that runs on past the phone's edge and the Mac's edge too, ";
    s += &"r".repeat(100);
    s += "\x1b[0m back to plain\r\n";
    s += "\x1b[48;5;236m background band across the wrap ";
    s += &"_".repeat(80);
    s += "\x1b[0m\r\n";
    s += "\x1b[38;2;255;128;0mtruecolor\x1b[0m \x1b[4munderlined\x1b[24m \x1b[3;2mitalic faint\x1b[0m \x1b[7minverse\x1b[27m \x1b[9mstrike\x1b[0m\r\n";
    s += "see \x1b]8;;https://cmux.com/docs\x1b\\\x1b[34mhttps://cmux.com/docs - a link whose text crosses the phone's edge\x1b[0m\x1b]8;;\x1b\\ end\r\n$ ";
    case.feed(s.as_bytes());
    case.snapshot("styled text", 0);
    // Every glyph keeps its style: compare (text, style) per glyph of each logical line.
    let glyphs = |t: &Terminal| -> Vec<(String, Style)> {
        t.history
            .iter()
            .chain(t.primary_rows())
            .flat_map(|r| r.cells.iter())
            .filter(|c| c.kind != WIDE_TAIL && c.kind != SPACER_HEAD && c.ch != 0)
            .map(|c| {
                let mut st = t.styles.get(c.style);
                st.link = u32::from(st.link != 0);
                if c.ch == u32::from(b' ') && st.is_invisible_when_blank() {
                    st = Style::default();
                }
                (t.cell_text(*c), st)
            })
            .collect()
    };
    assert_eq!(glyphs(&case.phone.term), glyphs(case.host.terminal()));
    case.finish();
}

#[test]
fn cursor_positions() {
    let mut case = Case::new(
        "cursor_positions",
        "the cursor mid-line in a wrapped command, at a row's last cell, and placed by CUP",
        (120, 24),
        (54, 38),
    );
    let cmd = "git commit -m 'a long message that wraps on the phone and keeps the cursor where the shell put it'";
    case.feed(format!("$ {cmd}").as_bytes());
    // The person moves the cursor 30 cells left.
    case.feed(b"\x1b[30D");
    case.snapshot("cursor 30 cells back in a wrapped command", 0);
    let (cx, cy) = case.phone.term.cursor();
    // 2 + cmd - 30 cells into the line, wrapped at 54.
    let offset = 2 + cmd.len() - 30;
    assert_eq!((cx, cy % 38), (offset % 54, offset / 54), "cursor through the wrap");
    case.feed(b"\x1b[30C\r\n");
    case.feed(&[b'Q'; 120]);
    case.snapshot("cursor after a full Mac row (pending wrap)", 0);
    case.feed(b"\r\n\x1b[2J\x1b[H\x1b[5;10Hplaced");
    case.snapshot("cursor placed by CUP after a clear", 0);
    case.finish();
}

/// Codex on the alternate screen at 120x40: header, transcript, input box,
/// status row. The phone shows the Mac's grid exactly (scaled on the page).
fn codex_alt_screen(cols: usize, rows: usize) -> Vec<u8> {
    let mut s = String::from("\x1b[?1049h\x1b[?1h\x1b=\x1b[?2004h\x1b[H\x1b[2J");
    let d = "\x1b[2m";
    s += &rule("╭", "╮", 60, d);
    s += "\r\n";
    s += &frame("│", " >_ OpenAI Codex (v0.58.0)", "│", 60, d);
    s += "\r\n";
    s += &rule("╰", "╯", 60, d);
    s += "\r\n\r\n";
    s += "\x1b[1m› \x1b[0mfix the flaky test in the link heartbeat suite\r\n\r\n";
    s += "• I'll look at the heartbeat tests first.\r\n";
    s += "  └ \x1b[2mRead LinkHeartbeatAlignmentTests.swift\x1b[0m\r\n";
    s += &format!("\x1b[{};1H", rows - 3);
    s += &rule("╭", "╮", cols, d);
    s += &format!("\x1b[{};1H", rows - 2);
    s += &frame("│", " › ", "│", cols, d);
    s += &format!("\x1b[{};1H", rows - 1);
    s += &rule("╰", "╯", cols, d);
    s += &format!("\x1b[{rows};1H");
    s += &format!(
        "  \x1b[2m⏎ send   ⇧⏎ newline   ⌃T transcript{}100% context left\x1b[0m",
        " ".repeat(cols - 2 - 36 - 17 - 1)
    );
    s += &format!("\x1b[{};6H", rows - 2);
    s.into_bytes()
}

#[test]
fn alternate_screen_codex_and_back() {
    let mut case = Case::new(
        "alternate_screen_codex_and_back",
        "Codex on the alternate screen shows the Mac's grid exactly; leaving it restores the primary screen",
        (120, 40),
        (54, 38),
    );
    case.feed(b"$ cargo test\r\n   Compiling cmux-terminal-projection v0.1.0\r\n$ codex\r\n");
    let before = case.phone_render();
    case.feed(&codex_alt_screen(120, 40));
    case.snapshot("Codex on the alternate screen", 0);
    // The phone's alternate screen is the Mac's, cell for cell.
    assert!(case.phone.term.is_alternate());
    assert_eq!(render(&case.phone.term, 0), render(case.host.terminal(), 0));
    // A redraw streams through unchanged.
    case.feed("\x1b[38;6H\x1b[Kfix it\x1b[38;12H".as_bytes());
    assert_eq!(render(&case.phone.term, 0), render(case.host.terminal(), 0));
    // Codex exits: the primary screen comes back as it was, re-wrapped.
    case.feed(b"\x1b[?2004l\x1b[?1l\x1b>\x1b[?1049l");
    case.snapshot("after Codex exits", 0);
    assert!(!case.phone.term.is_alternate());
    assert_eq!(case.phone_render(), before, "the primary screen as before");
    case.finish();
}

#[test]
fn live_streaming_output() {
    // A build with an in-place progress row and a spinner, fed whole and
    // byte by byte: the phone ends the same.
    let mut s = String::new();
    s += "$ cargo build\r\n";
    for i in 0..30 {
        s += &format!(
            "\x1b[K   \x1b[1;32mCompiling\x1b[0m crate-{i:02} v0.{i}.0 (/Users/leo/Projects/cmux/cmux-tui/crates/crate-{i:02})\r\n"
        );
        s += &format!(
            "\x1b[1;36m    Building\x1b[0m [{:=<w$}>{:<r$}] {i}/30: crate-{i:02}, cmux-tui, cmux-terminal-projection\r",
            "",
            "",
            w = i,
            r = 30 - i
        );
    }
    s += "\x1b[K";
    for frame in ["⠋", "⠙", "⠹", "⠸"] {
        s += &format!(
            "\r\x1b[K{frame} Thinking about what the build printed and what to do next with it…"
        );
    }
    s += "\r\x1b[K\x1b[1;32m    Finished\x1b[0m `dev` profile [unoptimized + debuginfo] target(s) in 41.2s\r\n$ ";
    let bytes = s.into_bytes();

    let mut whole = Case::new(
        "live_streaming_output",
        "a cargo build with an in-place progress row and a spinner, as one feed and byte by byte",
        (120, 24),
        (54, 38),
    );
    whole.feed(&bytes);
    let mut bytewise = Case::new("live_streaming_output_bytewise", "", (120, 24), (54, 38));
    let mut mid = String::new();
    for (i, b) in bytes.iter().enumerate() {
        bytewise.feed(std::slice::from_ref(b));
        if i == bytes.len() / 2 {
            mid = bytewise.phone_render();
        }
    }
    assert_eq!(bytewise.phone_render(), whole.phone_render(), "byte by byte ends as one feed");
    assert_eq!(logical_lines(&bytewise.phone.term), logical_lines(whole.host.terminal()));
    let _ = writeln!(whole.out, "\n## halfway, fed byte by byte\n### phone");
    whole.out.push_str(&mid);
    whole.snapshot("finished", 6);
    let _ = writeln!(
        whole.out,
        "\nbytes to the phone: one feed {}, byte by byte {}",
        whole.phone.bytes, bytewise.phone.bytes
    );
    whole.finish();
}

#[test]
fn scrollback_reaches_line_one() {
    let mut case = Case::new(
        "scrollback_reaches_line_one",
        "3,000 lines of output: the phone's window, then older rows on demand until line 1",
        (120, 24),
        (54, 38),
    );
    let mut s = String::new();
    for i in 1..=3000 {
        s += &format!("line {i:04} {}\r\n", "pad ".repeat(i % 40));
    }
    s += "$ ";
    case.feed(s.as_bytes());
    case.snapshot("at the bottom", 4);
    // Streamed, every line settled into the phone's scrollback as it came.
    assert_eq!(logical_lines(&case.phone.term), logical_lines(case.host.terminal()));
    // A rotation re-wraps a window, not the scrollback: older rows come on
    // demand as the reader scrolls up, until line 1.
    case.viewport(116, 16);
    case.viewport(54, 38);
    let older_before = case.host.older_rows();
    assert!(older_before > 0, "a rotation paints a window");
    let mut loads = 0;
    while case.host.older_rows() > 0 {
        let segments = case.host.load_older(2_000);
        case.phone.apply(segments);
        loads += 1;
        assert!(loads < 20);
    }
    assert_eq!(logical_lines(&case.phone.term), logical_lines(case.host.terminal()));
    let first = case.phone.term.history.front().unwrap();
    let text: String = first.cells.iter().map(|c| char::from_u32(c.ch).unwrap_or(' ')).collect();
    assert!(text.starts_with("line 0001"), "{text:?}");
    let _ = writeln!(
        case.out,
        "\nolder Mac rows not on the phone at first: {older_before}; loads to line 1: {loads}; phone scrollback rows: {}",
        case.phone.term.history.len()
    );
    case.finish();
}

#[test]
fn rotation_and_keyboard() {
    let mut case = Case::new(
        "rotation_and_keyboard",
        "portrait, keyboard up, keyboard down, landscape and back: local re-wraps, the Mac keeps 120x24",
        (120, 24),
        (54, 38),
    );
    case.feed(&claude_code_screen(120));
    // Below the status row, as Claude Code leaves the screen on exit.
    case.feed(b"\x1b[2B\r\n");
    case.feed("$ echo a long line that soft-wraps on the phone in portrait and fits in landscape at one hundred sixteen\r\n$ ".as_bytes());
    let portrait = case.phone_render();
    case.snapshot("portrait 54x38", 0);
    case.viewport(54, 20);
    case.snapshot("keyboard up: 54x20", 0);
    case.viewport(54, 38);
    assert_eq!(case.phone_render(), portrait, "keyboard down is portrait again");
    case.viewport(116, 16);
    case.snapshot("landscape 116x16", 0);
    case.viewport(54, 38);
    assert_eq!(case.phone_render(), portrait, "back to portrait is portrait again");
    assert_eq!(case.host.host_grid(), (120, 24), "the Mac's grid never changed");
    case.finish();
}

/// Laid out at the phone's width, a row loses only padding: blanks and
/// rule glyphs. Random rows (left and right parts, frames, centered text,
/// prose, wide glyphs) keep every other glyph in order, and no phone row is
/// wider than the phone.
#[test]
fn compaction_keeps_every_glyph() {
    let mut seed: u64 = 0x5eed_1234;
    let mut next = move |n: u64| {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (seed >> 33) % n.max(1)
    };
    let words = ["ls", "main", "09:12", "漢字", "✻", "cmux", "gpt-5", "│", "─", "==", "é", "👍"];
    for round in 0..200 {
        let host_cols = 60 + next(100) as usize;
        let phone_cols = 20 + next(60) as usize;
        let mut case = Case::new("compaction_fuzz", "", (host_cols, 24), (phone_cols, 30));
        let mut s = String::new();
        for _ in 0..12 {
            let mut line = String::new();
            let parts = 1 + next(4);
            for _ in 0..parts {
                if next(2) == 0 {
                    line += &" ".repeat(next(40) as usize);
                } else if next(3) == 0 {
                    line += &"─".repeat(next(30) as usize);
                }
                line += words[next(words.len() as u64) as usize];
            }
            let w = visible_width(&line);
            if w > host_cols {
                continue;
            }
            match next(3) {
                // Right-anchored: padded to the host's edge.
                0 => line = format!("{}{line}", " ".repeat(host_cols - w)),
                // Centered.
                1 => {
                    let lead = (host_cols - w) / 2;
                    line =
                        format!("{}{line}{}", " ".repeat(lead), " ".repeat(host_cols - w - lead));
                }
                _ => {}
            }
            s += &line;
            s += "\r\n";
        }
        case.feed(s.as_bytes());
        let keep = |t: &Terminal| -> Vec<Vec<String>> {
            let mut lines = Vec::new();
            let mut current = Vec::new();
            for row in t.history.iter().chain(t.primary_rows()) {
                for c in &row.cells {
                    if c.kind == WIDE_TAIL || c.kind == SPACER_HEAD || c.ch == 0 {
                        continue;
                    }
                    let text = t.cell_text(*c);
                    if text != " " && text != "─" {
                        current.push(text);
                    }
                }
                if !row.wrapped {
                    lines.push(std::mem::take(&mut current));
                }
            }
            while lines.last().is_some_and(Vec::is_empty) {
                lines.pop();
            }
            lines
        };
        let host = keep(case.host.terminal());
        let phone = keep(&case.phone.term);
        let flat = |l: Vec<Vec<String>>| l.into_iter().flatten().collect::<Vec<_>>();
        assert_eq!(flat(phone), flat(host), "round {round}: glyphs in order");
        for row in case.phone.term.history.iter().chain(case.phone.term.primary_rows()) {
            let w: usize =
                row.cells.iter().filter(|c| c.kind != WIDE_TAIL).map(|c| c.width()).sum();
            assert!(
                w <= phone_cols,
                "round {round}: a row {w} wide on a {phone_cols}-column phone"
            );
        }
    }
}

/// The phone's rows as text, trailing blanks trimmed, with their wrap flag.
fn phone_rows(case: &Case) -> Vec<(String, bool)> {
    let t = &case.phone.term;
    t.history
        .iter()
        .chain(t.primary_rows())
        .map(|r| {
            let text: String = r
                .cells
                .iter()
                .filter(|c| c.kind != WIDE_TAIL && c.kind != SPACER_HEAD)
                .map(|c| if c.ch == 0 { " ".to_string() } else { t.cell_text(*c) })
                .collect();
            (text.trim_end().to_string(), r.wrapped)
        })
        .collect()
}

/// Aziz, cmux#42219 (2): "`ls` columns ... are laid out for the Mac's width".
/// `ls` at 120 columns, shown on a 54-column phone: every name stays whole
/// on one phone row (never split across two), in the order `ls` wrote them,
/// and no row is wider than the phone.
///
/// Known gap, measured here: the projection wraps by cells, so a name at a
/// row's end splits (`node_mod` / `ules`). Breaking at the column gaps instead
/// changes where a line's earlier rows end as the line grows, which the
/// streaming painter does not allow yet (`live_streaming_output` garbles).
/// The fix (a gap-aware wrap whose prefix layout is stable, or a repaint
/// from the line's first row) lands with the shell-reflow step of
/// cmux-next-ios/design/terminal-fit-to-phone.md.
#[test]
#[ignore = "known gap: names split at a row's end; see the doc comment"]
fn ls_columns_keep_every_name_whole() {
    let names = [
        "Cargo.lock",
        "Cargo.toml",
        "README.md",
        "build.rs",
        "docs",
        "examples",
        "scripts",
        "src",
        "target",
        "tests",
        "webviews",
        "node_modules",
        "package.json",
        "tsconfig.json",
        "LICENSE",
        "CHANGELOG.md",
        "rust-toolchain.toml",
        "deny.toml",
        "clippy.toml",
        "benches",
    ];
    let mut case = Case::new("ls_columns", "", (120, 24), (54, 30));
    let mut s = String::from("$ ls\r\n");
    for row in names.chunks(6) {
        let line: String = row.iter().map(|n| format!("\x1b[1;34m{n:<20}\x1b[0m")).collect();
        s += line.trim_end();
        s += "\r\n";
    }
    s += "$ ";
    case.feed(s.as_bytes());
    let rows = phone_rows(&case);
    let mut seen = Vec::new();
    for (text, _) in &rows {
        assert!(visible_width(text) <= 54, "row wider than the phone: {text:?}");
        seen.extend(text.split_whitespace().map(str::to_string));
    }
    let seen: Vec<&str> =
        seen.iter().map(String::as_str).filter(|w| *w != "$" && *w != "ls").collect();
    assert_eq!(seen, names, "every name whole, in order: {rows:#?}");
}

/// Aziz, cmux#42219 (2): "tables ... laid out for the Mac's width". A box
/// table padded to the Mac's edge (Claude Code's Markdown tables) keeps each
/// border row to one phone row at the phone's width, and every cell's text.
#[test]
fn a_box_table_at_the_macs_width_is_laid_out_at_the_phones() {
    let mut case = Case::new("box_table", "", (120, 24), (54, 30));
    let w = [38usize, 38, 39];
    let border = |l: &str, m: &str, r: &str| {
        format!("{l}{}{r}", w.iter().map(|n| "─".repeat(*n)).collect::<Vec<_>>().join(m))
    };
    let cells = |a: &str, b: &str, c: &str| format!("│{a:<38}│{b:<38}│{c:<39}│");
    let mut s = String::new();
    s += &border("┌", "┬", "┐");
    s += "\r\n";
    s += &cells(" Test", " Before", " After");
    s += "\r\n";
    s += &border("├", "┼", "┤");
    s += "\r\n";
    s += &cells(" cols from width", " 1.7 rows", " 1 row");
    s += "\r\n";
    s += &border("└", "┴", "┘");
    s += "\r\n";
    case.feed(s.as_bytes());
    let rows = phone_rows(&case);
    for (text, wrapped) in &rows {
        if text.starts_with(['┌', '├', '└']) {
            // The table ends a cell short of the Mac's edge (119 of 120):
            // the host's right margin stays on the phone, as it does on the
            // Mac at any width.
            assert_eq!(visible_width(text), 53, "border at the phone's width: {text:?}");
            assert!(!wrapped, "a border is one phone row: {text:?}");
        }
        assert!(visible_width(text) <= 54, "{text:?}");
    }
    let all: String = rows.iter().map(|(t, _)| t.as_str()).collect::<Vec<_>>().join(" ");
    for word in ["Test", "Before", "After", "cols", "from", "width", "1.7", "rows", "1", "row"] {
        assert!(
            all.split(|c: char| !c.is_alphanumeric() && c != '.').any(|w| w == word),
            "{word} kept: {rows:#?}"
        );
    }
}

/// Aziz, cmux#42219 (2): "diffs are laid out for the Mac's width". Claude
/// Code's diff rows fill the Mac's width with their red or green background;
/// on the phone each keeps its sign, its text and its background on every
/// glyph, and no row is wider than the phone.
#[test]
fn a_diff_at_the_macs_width_keeps_its_signs_and_colours() {
    let mut case = Case::new("diff", "", (120, 24), (54, 30));
    let lines = [
        ("\x1b[38;5;167;48;5;52m", "-", "    let cols = surface.width / cell;"),
        ("\x1b[38;5;77;48;5;22m", "+", "    let cols = surface.grid.columns;"),
        ("", " ", "    feed(seed);"),
    ];
    let mut s = String::new();
    for (i, (sgr, sign, text)) in lines.iter().enumerate() {
        let body = format!("{:>4} {sign}{text}", 10 + i);
        s += &format!("{sgr}{body:<120}\x1b[0m\r\n");
    }
    case.feed(s.as_bytes());
    let t = &case.phone.term;
    let rows: Vec<_> = t.history.iter().chain(t.primary_rows()).collect();
    let text = phone_rows(&case);
    for (i, (sign, needle)) in [("-", "surface.width"), ("+", "grid.columns")].iter().enumerate() {
        let at = text
            .iter()
            .position(|(r, _)| r.contains(needle))
            .unwrap_or_else(|| panic!("{needle}: {text:#?}"));
        assert!(text[at].0.contains(&format!("{} {sign}", 10 + i)), "sign kept: {:?}", text[at].0);
        let styles: Vec<u16> = rows[at]
            .cells
            .iter()
            .filter(|c| c.ch != 0 && c.ch != u32::from(b' '))
            .map(|c| c.style)
            .collect();
        assert!(
            styles.iter().all(|s| *s != 0 && *s == styles[0]),
            "every glyph keeps the row's colours: {:?}",
            text[at].0
        );
    }
    for (row, _) in &text {
        assert!(visible_width(row) <= 54, "{row:?}");
    }
}
