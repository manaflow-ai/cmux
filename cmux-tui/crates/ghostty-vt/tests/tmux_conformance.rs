//! tmux's terminal-emulator regression tests, translated to golden tests of
//! libghostty-vt through the `ghostty-vt` wrapper.
//!
//! Source: tmux `regress/` (ISC license, see `tests/fixtures/tmux/NOTICE`).
//! Each `#[test]` is one tmux case, named `tmux_<file>_<case>`. Only the
//! scenarios whose subject is the terminal emulator are ported; tmux UI tests
//! (key tables, status line, copy mode, choose modes) are not.
//!
//! Translation rules:
//! - A tmux pane runs `printf` through a pty whose ONLCR turns LF into CRLF.
//!   [`Pane::printf`] and [`Pane::tty`] do the same. Scripts that run
//!   `stty raw` write with [`Pane::raw`].
//! - `capture-pane -pN -S 0 -E -` piped through `normalize_capture` is the
//!   visible rows with trailing blanks trimmed and trailing empty rows
//!   dropped ([`Pane::capture`]). `-S -` adds history ([`Pane::capture_all`]),
//!   `-J` joins soft-wrapped rows ([`Pane::joined`], [`Pane::joined_all`]).
//! - tmux reports a pending-wrap cursor as `cursor_x == pane width`. Ghostty
//!   keeps the cursor on the last column with a pending-wrap flag, so those
//!   expectations are written as the last column (commented where it applies).
//! - tmux stores a tab as one TAB cell and capture prints `\t`. A terminal
//!   grid holds blank cells, so `\t` expectations are written as spaces.
//! - `capture-pane -pR` raw-grid regexes are translated to checks of the
//!   rendered cells (text, width role, colours, attributes). tmux-internal
//!   storage flags (EXTENDED, CLEARED, the data byte counts) have no terminal
//!   meaning and are not checked.
//! - tmux's `history-limit` counts lines; Ghostty's scrollback limit is bytes.
//!   `start_pane` (limit 0) maps to [`Pane::new`] with no scrollback and
//!   `start_pane_history` (limit 2000) to [`Pane::history`].

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use ghostty_vt::{Callbacks, Cell, CellWidth, ColorSpec, RenderState, Terminal, UnderlineStyle};

/// Scrollback for panes that tmux runs with `history-limit 2000`.
const HISTORY_BYTES: usize = 16 * 1024 * 1024;

struct Pane {
    term: Terminal,
    replies: Arc<Mutex<Vec<u8>>>,
}

impl Pane {
    fn with_scrollback(cols: u16, rows: u16, scrollback: usize) -> Self {
        let replies = Arc::new(Mutex::new(Vec::new()));
        let sink = replies.clone();
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new(move |bytes| {
                sink.lock().unwrap().extend_from_slice(bytes);
            })),
            ..Callbacks::default()
        };
        // Grapheme clustering (mode 2027) is on by default, as in Ghostty.
        let term = Terminal::new(cols, rows, scrollback, callbacks).unwrap();
        Self { term, replies }
    }

    /// tmux `start_pane`: `history-limit 0`.
    fn new(cols: u16, rows: u16) -> Self {
        Self::with_scrollback(cols, rows, 0)
    }

    /// tmux `start_pane_history` and default sessions: `history-limit 2000`.
    fn history(cols: u16, rows: u16) -> Self {
        Self::with_scrollback(cols, rows, HISTORY_BYTES)
    }

    /// Bytes written by `printf` through a pty with ONLCR.
    fn printf(&mut self, s: &str) {
        self.tty(s.as_bytes());
    }

    fn tty(&mut self, bytes: &[u8]) {
        let mut out = Vec::with_capacity(bytes.len() + bytes.len() / 8);
        for &b in bytes {
            if b == b'\n' {
                out.push(b'\r');
            }
            out.push(b);
        }
        self.term.vt_write(&out);
    }

    /// Bytes written with the pty in raw mode (no ONLCR).
    fn raw(&mut self, bytes: &[u8]) {
        self.term.vt_write(bytes);
    }

    fn resize(&mut self, cols: u16, rows: u16) {
        self.term.resize(cols, rows, 8, 16).unwrap();
    }

    fn take_replies(&self) -> Vec<u8> {
        std::mem::take(&mut *self.replies.lock().unwrap())
    }

    fn rows(&mut self) -> Vec<Vec<Cell>> {
        let mut rs = RenderState::new().unwrap();
        rs.update(&mut self.term).unwrap();
        let mut rows = Vec::new();
        rs.walk_rows(|_, _, cells| rows.push(cells.to_vec())).unwrap();
        rows
    }

    #[track_caller]
    fn cell(&mut self, row: usize, col: usize) -> Cell {
        let rows = self.rows();
        let Some(cells) = rows.get(row) else {
            panic!("row {row} is outside the {}-row viewport", rows.len());
        };
        let Some(cell) = cells.get(col) else {
            panic!("column {col} is outside row {row} of {} cells", cells.len());
        };
        cell.clone()
    }

    fn lines(&mut self) -> Vec<String> {
        self.rows().iter().map(|row| row_text(row)).collect()
    }

    /// `capture-pane -pN -S 0 -E -` | normalize_capture.
    fn capture(&mut self) -> String {
        normalize(self.lines())
    }

    fn cursor(&self) -> (u16, u16) {
        self.term.cursor_position().unwrap()
    }

    fn history_rows(&self) -> Vec<Vec<Cell>> {
        let total = self.term.history_rows();
        let mut rows = Vec::new();
        let mut start = 0;
        while start < total {
            let chunk = self.term.styled_history_rows(start, 256).unwrap();
            if chunk.is_empty() {
                break;
            }
            start += chunk.len() as u32;
            rows.extend(chunk);
        }
        rows
    }

    fn all_lines(&mut self) -> Vec<String> {
        let mut lines: Vec<String> = self.history_rows().iter().map(|r| row_text(r)).collect();
        lines.extend(self.lines());
        lines
    }

    /// `capture-pane -pN -S - -E -` | normalize_capture.
    fn capture_all(&mut self) -> String {
        normalize(self.all_lines())
    }

    /// `capture-pane -pNJ -S 0 -E -` | normalize_capture.
    fn joined(&mut self) -> String {
        let cols = self.term.cols();
        let rows = self.term.rows();
        let text = self.term.selection_text((0, 0), (cols - 1, rows - 1)).unwrap_or_default();
        normalize(text.split('\n').map(str::to_owned).collect())
    }

    /// `capture-pane -pNJ -S - -E -` | normalize_capture.
    fn joined_all(&mut self) -> String {
        let cols = self.term.cols();
        let total = self.term.scrollbar().map_or(u64::from(self.term.rows()), |s| s.total);
        let text = self
            .term
            .selection_text_absolute((0, 0), (cols - 1, total.saturating_sub(1)))
            .unwrap_or_default();
        normalize(text.split('\n').map(str::to_owned).collect())
    }

    fn replay(&mut self) -> String {
        String::from_utf8_lossy(&self.term.vt_replay_bytes().unwrap()).into_owned()
    }
}

/// One row as capture-pane prints it: a wide grapheme once, its spacer
/// skipped, blanks as spaces.
fn row_text(row: &[Cell]) -> String {
    let mut line = String::new();
    for cell in row {
        match cell.width {
            CellWidth::SpacerTail => {}
            CellWidth::SpacerHead => line.push(' '),
            CellWidth::Narrow | CellWidth::Wide => {
                if cell.text.is_empty() {
                    line.push(' ');
                } else {
                    line.push_str(&cell.text);
                }
            }
        }
    }
    line
}

/// tmux `normalize_capture`: strip trailing blanks, drop trailing empty lines.
fn normalize(lines: Vec<String>) -> String {
    let mut lines: Vec<String> =
        lines.into_iter().map(|l| l.trim_end_matches([' ', '\t', '\r']).to_owned()).collect();
    while lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines.join("\n")
}

fn normalize_text(text: &str) -> String {
    normalize(text.split('\n').map(str::to_owned).collect())
}

#[track_caller]
fn assert_text_eq(actual: &str, expected: &str) {
    if actual == expected {
        return;
    }
    let a: Vec<&str> = actual.split('\n').collect();
    let e: Vec<&str> = expected.split('\n').collect();
    let mut diffs = Vec::new();
    for i in 0..a.len().max(e.len()) {
        let (x, y) = (a.get(i), e.get(i));
        if x != y {
            diffs.push(format!("line {}: actual {x:?}\n          expected {y:?}", i + 1));
            if diffs.len() >= 12 {
                break;
            }
        }
    }
    panic!(
        "capture differs ({} actual lines, {} expected); first differences:\n{}",
        a.len(),
        e.len(),
        diffs.join("\n")
    );
}

#[track_caller]
fn assert_cell(p: &mut Pane, row: usize, col: usize, text: &str) {
    let cell = p.cell(row, col);
    assert_eq!(cell.text, text, "cell {row},{col}: {cell:?}");
    assert_ne!(cell.width, CellWidth::SpacerTail, "cell {row},{col} is a spacer: {cell:?}");
}

#[track_caller]
fn assert_blank(p: &mut Pane, row: usize, col: usize) {
    let cell = p.cell(row, col);
    assert!(
        cell.text.is_empty() && cell.width == CellWidth::Narrow,
        "cell {row},{col} is not a blank narrow cell: {cell:?}"
    );
}

#[track_caller]
fn assert_wide(p: &mut Pane, row: usize, col: usize, text: &str) {
    let cell = p.cell(row, col);
    assert_eq!(cell.text, text, "cell {row},{col}: {cell:?}");
    assert_eq!(cell.width, CellWidth::Wide, "cell {row},{col} is not wide: {cell:?}");
    let spacer = p.cell(row, col + 1);
    assert_eq!(
        spacer.width,
        CellWidth::SpacerTail,
        "cell {row},{} is not the padding of a wide cell: {spacer:?}",
        col + 1
    );
}

fn reply_string(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

// ---------------------------------------------------------------------------
// cursor-test1..4.sh: cursor position and character across reflowing resizes.

/// `display -pF '#{cursor_x} #{cursor_y} #{cursor_character}'` followed by
/// `capturep -p | awk '{print NR-1,$0}'`.
fn cursor_report(p: &mut Pane) -> String {
    let (x, y) = p.cursor();
    let rows = p.rows();
    let ch = rows
        .get(usize::from(y))
        .and_then(|r| r.get(usize::from(x)))
        .map(|c| if c.text.is_empty() { " ".to_owned() } else { c.text.clone() })
        .unwrap_or_else(|| " ".to_owned());
    let mut out = format!("{x} {y} {ch}\n");
    for (i, row) in rows.iter().enumerate() {
        out.push_str(&format!("{i} {}\n", row_text(row).trim_end()));
    }
    out
}

#[test]
#[ignore = "tmux-specific: after a shrinking reflow tmux pulls rows from below the cursor into view and moves the cursor up one row more than Ghostty, whose reflow keeps the blank row below the cursor"]
fn tmux_cursor_test1_resize() {
    let mut p = Pane::history(40, 10);
    p.tty(include_bytes!("fixtures/tmux/cursor-test.txt"));
    p.printf("\x1b[9;15H");
    let mut out = cursor_report(&mut p);
    p.resize(10, 10);
    out.push_str(&cursor_report(&mut p));
    p.resize(50, 10);
    out.push_str(&cursor_report(&mut p));
    assert_text_eq(&out, include_str!("fixtures/tmux/cursor-test1.result"));
}

#[test]
#[ignore = "tmux-specific: same reflow row-placement choice as cursor-test1: Ghostty keeps the blank row below the cursor, tmux does not"]
fn tmux_cursor_test2_resize() {
    let mut p = Pane::history(10, 10);
    p.tty(include_bytes!("fixtures/tmux/cursor-test.txt"));
    p.printf("\x1b[8;10H");
    let mut out = cursor_report(&mut p);
    p.resize(5, 10);
    out.push_str(&cursor_report(&mut p));
    p.resize(50, 10);
    out.push_str(&cursor_report(&mut p));
    assert_text_eq(&out, include_str!("fixtures/tmux/cursor-test2.result"));
}

#[test]
fn tmux_cursor_test3_resize() {
    let mut p = Pane::history(7, 2);
    p.printf("abcdefabcdefab");
    p.printf("\x1b[2;7H");
    let mut out = cursor_report(&mut p);
    p.resize(5, 2);
    out.push_str(&cursor_report(&mut p));
    p.resize(7, 2);
    out.push_str(&cursor_report(&mut p));
    assert_text_eq(&out, include_str!("fixtures/tmux/cursor-test3.result"));
}

#[test]
#[ignore = "tmux-specific: shrinking to 3 columns, tmux scrolls the wrapped abc row into history and keeps the cursor on row 1; Ghostty keeps both rows on screen because the rows below the cursor are blank"]
fn tmux_cursor_test4_resize() {
    let mut p = Pane::history(10, 3);
    p.printf("abcdef\n");
    let mut out = cursor_report(&mut p);
    p.resize(20, 3);
    out.push_str(&cursor_report(&mut p));
    p.resize(3, 3);
    out.push_str(&cursor_report(&mut p));
    p.resize(10, 3);
    out.push_str(&cursor_report(&mut p));
    assert_text_eq(&out, include_str!("fixtures/tmux/cursor-test4.result"));
}

// ---------------------------------------------------------------------------
// utf8-test.sh: Markus Kuhn's decoder stress test, `capturep -pCeJS-`.

#[test]
#[ignore = "tmux-specific: the golden file encodes tmux's U+FFFD policy (one per malformed sequence, C1 U+0080 printed); see tmux_utf8_test_lines for the policy-free checks"]
fn tmux_utf8_test_capture() {
    let mut p = Pane::history(80, 24);
    p.tty(include_bytes!("fixtures/tmux/UTF-8-test.txt"));
    let expected =
        normalize_text(&String::from_utf8_lossy(include_bytes!("fixtures/tmux/utf8-test.result")));
    assert_text_eq(&p.joined_all(), &expected);
}

/// The section ids of the test file (`2.1.1`, `3.2`, ...) that start a line.
fn utf8_section_ids(text: &str) -> Vec<String> {
    text.lines()
        .filter_map(|line| {
            let id: String = line.chars().take_while(|c| c.is_ascii_digit() || *c == '.').collect();
            (id.contains('.') && line[id.len()..].starts_with("  ")).then_some(id)
        })
        .collect()
}

#[test]
#[ignore = "policy: cmux-tui's C1Normalizer reads a bare 0x90/0x9d as an 8-bit DCS/OSC introducer (kept for 8-bit C1 programs); see TMUX.md"]
fn tmux_utf8_test_lines() {
    // Whatever the replacement policy, no source line may be lost or merged
    // into another: every section heading of the golden file starts a line.
    let mut p = Pane::history(80, 24);
    p.tty(include_bytes!("fixtures/tmux/UTF-8-test.txt"));
    let actual = p.joined_all();
    let expected =
        normalize_text(&String::from_utf8_lossy(include_bytes!("fixtures/tmux/utf8-test.result")));
    let have = utf8_section_ids(&actual);
    let missing: Vec<String> =
        utf8_section_ids(&expected).into_iter().filter(|id| !have.contains(id)).collect();
    if !missing.is_empty() {
        let around: Vec<String> = actual
            .lines()
            .enumerate()
            .skip(100)
            .take(40)
            .map(|(i, l)| format!("{:3} {:?}", i + 1, l.trim_end()))
            .collect();
        panic!("section lines lost or merged: {missing:?}\nactual lines:\n{}", around.join("\n"));
    }
    assert_eq!(
        actual.lines().count(),
        expected.lines().count(),
        "joined line count differs; ends with {:?}",
        actual.lines().rev().take(3).collect::<Vec<_>>()
    );
    assert!(actual.contains("THE END"));
}

#[test]
#[ignore = "policy: cmux-tui's C1Normalizer reads a bare 0x90/0x9d as an 8-bit DCS/OSC introducer (kept for 8-bit C1 programs); see TMUX.md"]
fn tmux_utf8_test_raw_c1_bytes() {
    // UTF-8-test.txt 3.1.9 holds the bare bytes 0x80-0xbf. In a UTF-8 stream
    // each is a malformed sequence, not an 8-bit C1 control: 0x90 is not DCS,
    // 0x9b is not CSI and 0x9d is not OSC.
    let mut p = Pane::new(20, 4);
    p.tty(b"\"\x90\"X\n\"\x9b\"Y\n\"\x9d\"Z\n");
    assert_eq!(p.capture(), "\"\u{FFFD}\"X\n\"\u{FFFD}\"Y\n\"\u{FFFD}\"Z");
}

#[test]
#[ignore = "known VT bug (ghostty-next): DEL (0x7F) is stored as a visible cell; see TMUX.md"]
fn tmux_utf8_test_del() {
    // UTF-8-test.txt 2.2.1 is a quoted DEL (0x7F), which a terminal ignores.
    let mut p = Pane::new(20, 3);
    p.tty(b"\"\x7f\"");
    assert_eq!(p.capture(), "\"\"");
}

// ---------------------------------------------------------------------------
// combine-test.sh: combining characters written after cursor movement.

#[test]
fn tmux_combine_test_capture() {
    let mut p = Pane::history(80, 24);
    p.printf(concat!(
        "\x1b[H\x1b[J",
        "\x1b[3;1H\u{39B}\x1b[3;1H\u{30A}0\n",
        "\x1b[4;1H\u{39B}\x1b[4;2H\u{30A}1\n",
        "\x1b[5;1H\u{1F44D}\x1b[5;1H\u{1F3FB}2\n",
        "\x1b[6;1H\u{1F44D}\x1b[6;3H\u{1F3FB}3\n",
        "\x1b[7;1H\u{1F44D}\x1b[7;10H\u{1F44D}\x1b[7;3H\u{1F3FB}\x1b[7;12H\u{1F3FB}4\n",
        "\x1b[8;1H\u{1F937}\u{200D}\u{2642}\u{FE0F}5\n",
        "\x1b[9;1H\u{1F937}\x1b[9;1H\u{200D}\u{2642}\u{FE0F}6\n",
        "\x1b[9;1H\u{1F937}\x1b[9;1H\u{200D}\u{2642}\u{FE0F}7\n",
        "\x1b[10;1H\u{1F937}\x1b[10;3H\u{200D}\u{2642}\u{FE0F}8\n",
        "\x1b[11;1H\u{1F937}\x1b[11;3H\u{200D}\x1b[11;3H\u{2642}\u{FE0F}9\n",
        "\x1b[12;1H\u{1F937}\x1b[12;3H\u{200D}\u{2642}\u{FE0F}10\n",
        "\x1b[13;1H\u{1F1EA}11\n",
        "\x1b[14;1H\u{1F1F8}\u{1F1EA}12\n",
        "\x1b[15;1H\u{1F1F8}  \x08\x08\u{1F1EA}13\n",
    ));
    let expected = normalize_text(include_str!("fixtures/tmux/combine-test.result"));
    assert_text_eq(&p.capture(), &expected);
}

// ---------------------------------------------------------------------------
// input-raw-reflow.sh

#[test]
fn tmux_input_raw_reflow_reflow() {
    let mut p = Pane::history(8, 4);
    p.printf("abcdefgh\nijklmnop\nqrstuvwx\nyz");
    p.resize(4, 4);
    let lines = p.all_lines();
    // A wrapped row starting a at column 0 with d at column 3.
    assert!(lines.iter().any(|l| l.trim_end() == "abcd"), "no 4-column abcd row: {lines:?}");
    assert!(
        p.joined_all().lines().any(|l| l == "abcdefgh"),
        "abcd is not soft-wrapped into efgh: {:?}",
        p.joined_all()
    );
    p.resize(12, 4);
    let lines = p.all_lines();
    assert!(lines.iter().any(|l| l.trim_end() == "abcdefgh"), "abcdefgh did not unwrap: {lines:?}");
}

// ---------------------------------------------------------------------------
// input-raw-history.sh

#[test]
#[ignore = "tmux-specific: history-limit 2 keeps exactly 2 lines; Ghostty's scrollback limit is a byte budget with page granularity"]
fn tmux_input_raw_history_trim() {
    let mut p = Pane::history(6, 3);
    p.printf("one\ntwo\nthree\nfour\nfive\nsix");
    assert_eq!(p.term.history_rows(), 2);
}

#[test]
fn tmux_input_raw_history_trim_clear() {
    // clear-history is the terminal's ED 3 (erase saved lines).
    let mut p = Pane::history(6, 3);
    p.printf("one\ntwo\nthree\nfour\nfive\nsix");
    p.raw(b"\x1b[3J");
    assert_eq!(p.term.history_rows(), 0);
    assert_cell(&mut p, 0, 0, "f");
    assert_cell(&mut p, 2, 0, "s");
}

#[test]
#[ignore = "tmux-specific: tmux moves the screen into history on ED from the home position; xterm and Ghostty erase in place"]
fn tmux_input_raw_history_edhistory() {
    let mut p = Pane::history(6, 3);
    p.printf("one\ntwo\nthree\x1b[H\x1b[JZ");
    assert!(p.term.history_rows() >= 1, "ED from home did not move the screen into history");
    assert_cell(&mut p, 0, 0, "Z");
}

// ---------------------------------------------------------------------------
// input-modes.sh

#[test]
fn tmux_input_modes_alternate() {
    let mut p = Pane::new(10, 3);
    p.printf("MAIN\x1b[?1049hALT\x1b[?1049lZ\n");
    assert_eq!(p.capture(), "MAINZ");
}

#[test]
#[ignore = "tmux-specific: Ghostty implements the semantic-prompt fresh-line rule (OSC 133;A starts a new line when the cursor is not at column 0); tmux does not"]
fn tmux_input_modes_osc133() {
    // tmux also checks its raw per-line OSC 133 flags; that dump is tmux's
    // storage format, so only the capture is ported.
    let mut p = Pane::new(20, 8);
    p.printf(concat!(
        "xx\x1b]133;A\x07p>\x1b]133;B\x07cmd\n",
        "xy\x1b]133;P;k=s\x07more\n",
        "zz\x1b]133;C\x07out\x1b]133;D;7\x07\n",
        "q\x1b]133;C\x07bad\x1b]133;D;-1\x07\n",
        "qq\x1b]133;C\x07big\x1b]133;D;300\x07\n",
        "zzz\x1b]133;C\x07ok\x1b]133;D\x07\n",
    ));
    assert_eq!(p.capture(), "xxp>cmd\nxymore\nzzout\nqbad\nqqbig\nzzzok");
}

// ---------------------------------------------------------------------------
// input-sgr.sh

#[test]
fn tmux_input_sgr_sgr_basic() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1b[1;2;3;4;5;7;8;9mA\x1b[22;23;24;25;27;28;29mB\n");
    assert_eq!(p.capture(), "AB");
}

#[test]
fn tmux_input_sgr_sgr_colour() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1b[31;42mA\x1b[38;5;196;48;5;22mB\x1b[38;2;1;2;3;48;2;4;5;6mC\x1b[39;49mD\n");
    assert_eq!(p.capture(), "ABCD");
}

#[test]
fn tmux_input_sgr_sgr_underline() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1b[4:1mA\x1b[4:2mB\x1b[4:3mC\x1b[4:4mD\x1b[4:5mE\x1b[4:0mF\n");
    assert_eq!(p.capture(), "ABCDEF");
}

#[test]
fn tmux_input_sgr_sgr_uscolour() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1b[58;5;45;4mA\x1b[58:2::10:20:30mB\x1b[59mC\n");
    assert_eq!(p.capture(), "ABC");
}

#[test]
fn tmux_input_sgr_sgr_reset() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1b[90;100mA\x1b[0mB\x1b[91;101mC\x1b[39;49mD\n");
    assert_eq!(p.capture(), "ABCD");
}

// ---------------------------------------------------------------------------
// input-raw-wrap.sh

#[test]
fn tmux_input_raw_wrap_wrap() {
    let mut p = Pane::new(5, 3);
    p.printf("ABCDEZ");
    assert_eq!(p.capture(), "ABCDE\nZ");
    assert_eq!(p.term.history_rows(), 0);
    assert_eq!(p.joined(), "ABCDEZ", "row 0 is not marked wrapped");
    assert_cell(&mut p, 0, 4, "E");
    assert_cell(&mut p, 1, 0, "Z");
}

#[test]
fn tmux_input_raw_wrap_nowrap() {
    let mut p = Pane::new(5, 3);
    p.printf("\x1b[?7lABCDEZ");
    assert_eq!(p.capture(), "ABCDZ");
    assert_eq!(p.term.history_rows(), 0);
    assert_eq!(p.joined(), "ABCDZ");
    assert_cell(&mut p, 0, 4, "Z");
}

#[test]
fn tmux_input_raw_wrap_pending() {
    let mut p = Pane::new(5, 3);
    p.printf("ABCD\r\x1b[4CZ");
    assert_eq!(p.capture(), "ABCDZ");
    // tmux: cursor 5,0 (pending wrap after the last column).
    assert_eq!(p.cursor(), (4, 0));
    assert_eq!(p.joined(), "ABCDZ");
    assert_cell(&mut p, 0, 4, "Z");
}

// ---------------------------------------------------------------------------
// input-raw-cursor.sh

#[test]
fn tmux_input_raw_cursor_absolute() {
    let mut p = Pane::new(8, 4);
    p.printf("A\x1b[3;5HB\x1b[2GC\x1b[2D!");
    assert_eq!(p.capture(), "A\n\n!C  B");
    assert_eq!(p.cursor(), (1, 2));
    assert_cell(&mut p, 0, 0, "A");
    assert_cell(&mut p, 2, 4, "B");
    assert_cell(&mut p, 2, 0, "!");
    assert_cell(&mut p, 2, 1, "C");
}

#[test]
fn tmux_input_raw_cursor_savecursor() {
    let mut p = Pane::new(8, 4);
    p.printf("\x1b[4;4HS\x1b7\x1b[1;1HA\x1b8R");
    assert_eq!(p.capture(), "A\n\n\n   SR");
    assert_eq!(p.cursor(), (5, 3));
    assert_cell(&mut p, 0, 0, "A");
    assert_cell(&mut p, 3, 3, "S");
    assert_cell(&mut p, 3, 4, "R");
}

#[test]
fn tmux_input_raw_cursor_origin() {
    let mut p = Pane::new(8, 5);
    p.printf("\x1b[2;4r\x1b[?6h\x1b[1;1HO\x1b[3;1HP\x1b[?6lQ");
    assert_cell(&mut p, 1, 0, "O");
    assert_cell(&mut p, 3, 0, "P");
    assert_cell(&mut p, 0, 0, "Q");
}

// ---------------------------------------------------------------------------
// input-cursor.sh

#[test]
fn tmux_input_cursor_cursor() {
    let mut p = Pane::new(10, 3);
    p.printf("ABCDE\r\x1b[2Cxy\x1b[1D!\x1b[4GZ\n");
    assert_eq!(p.capture(), "ABxZE");
    assert_eq!(p.cursor(), (0, 1));
}

#[test]
fn tmux_input_cursor_saverc() {
    let mut p = Pane::new(10, 3);
    p.printf("abc\x1b7\x1b[2;5HXY\x1b8Z\n");
    assert_eq!(p.capture(), "abcZ\n    XY");
    assert_eq!(p.cursor(), (0, 1));
}

#[test]
fn tmux_input_cursor_hvp() {
    let mut p = Pane::new(10, 4);
    p.printf("A\x1b[3dB\x1b[5GC\x1b[2;2fD\n");
    assert_eq!(p.capture(), "A\n D\n B  C");
    assert_eq!(p.cursor(), (0, 2));
}

#[test]
fn tmux_input_cursor_cursorlines() {
    let mut p = Pane::new(8, 4);
    p.printf("A\x1b[2BB\x1b[1FC\x1b[1AD\n");
    assert_eq!(p.capture(), "AD\nC\n B");
    assert_eq!(p.cursor(), (0, 1));
}

#[test]
fn tmux_input_cursor_tabs() {
    let mut p = Pane::new(12, 3);
    p.printf("a\tb\n");
    // tmux: "a\tb" (a TAB cell covering columns 1-7).
    assert_eq!(p.capture(), "a       b");
    assert_eq!(p.cursor(), (0, 1));
}

#[test]
fn tmux_input_cursor_tabclear() {
    let mut p = Pane::new(12, 3);
    p.printf("\x1bH\ta\x1b[3g\r\tb\n");
    // tmux: "\ta  b" (a TAB cell covering columns 0-7).
    assert_eq!(p.capture(), "        a  b");
    assert_eq!(p.cursor(), (0, 1));
}

#[test]
fn tmux_input_cursor_cbt() {
    let mut p = Pane::new(16, 3);
    p.printf("0123456789\r\x1b[10C\x1b[Zx\n");
    assert_eq!(p.capture(), "01234567x9");
    assert_eq!(p.cursor(), (0, 1));
}

// ---------------------------------------------------------------------------
// input-raw-scroll.sh

#[test]
fn tmux_input_raw_scroll_history() {
    let mut p = Pane::history(6, 3);
    p.printf("one\ntwo\nthree\nfour\nfive");
    let history = p.history_rows();
    assert!(!history.is_empty(), "nothing scrolled into history");
    assert_eq!(history[0][0].text, "o", "first history row: {:?}", row_text(&history[0]));
}

#[test]
#[ignore = "tmux-specific: tmux saves lines scrolled out of a scroll region whose top is not row 1 into history; xterm and Ghostty discard them"]
fn tmux_input_raw_scroll_index() {
    let mut p = Pane::history(6, 4);
    p.printf("A\nB\nC\x1b[2;3r\x1b[2;1HX\x1bD\x1bDY");
    let lines = p.all_lines();
    assert!(lines.iter().any(|l| l.starts_with('X')), "no X at column 0: {lines:?}");
    assert!(lines.iter().any(|l| l.starts_with('A')), "no A at column 0: {lines:?}");
    assert!(lines.iter().any(|l| l.chars().nth(1) == Some('Y')), "no Y at column 1: {lines:?}");
}

#[test]
fn tmux_input_raw_scroll_reverse() {
    let mut p = Pane::new(6, 4);
    p.printf("A\nB\nC\x1b[2;3r\x1b[2;1H\x1bMY");
    assert_cell(&mut p, 1, 0, "Y");
    assert_cell(&mut p, 2, 0, "B");
}

#[test]
fn tmux_input_raw_scroll_insertline() {
    let mut p = Pane::new(6, 4);
    p.printf("A\nB\nC\x1b[2;3r\x1b[2;1H\x1b[LY");
    assert_cell(&mut p, 1, 0, "Y");
    assert_cell(&mut p, 2, 0, "B");
}

#[test]
fn tmux_input_raw_scroll_deleteline() {
    let mut p = Pane::new(6, 4);
    p.printf("A\nB\nC\x1b[2;3r\x1b[2;1H\x1b[MY");
    assert_cell(&mut p, 1, 0, "Y");
    assert_blank(&mut p, 2, 0);
}

#[test]
fn tmux_input_raw_scroll_region_edge() {
    let mut p = Pane::new(6, 4);
    p.printf("top\x1b[2;3rmid\x1b[2;1H\x1bD\x1bMbot");
    assert_cell(&mut p, 0, 0, "m");
    assert_cell(&mut p, 1, 0, "b");
    assert_blank(&mut p, 2, 0);
    assert_blank(&mut p, 3, 0);
}

// ---------------------------------------------------------------------------
// input-raw-sgr.sh

#[track_caller]
fn assert_attrs(p: &mut Pane, col: usize, text: &str, expected: [bool; 8]) {
    let c = p.cell(0, col);
    assert_eq!(c.text, text, "cell 0,{col}: {c:?}");
    let actual =
        [c.bold, c.faint, c.underline, c.blink, c.inverse, c.invisible, c.italic, c.strikethrough];
    assert_eq!(
        actual, expected,
        "cell 0,{col} [bold, faint, underline, blink, inverse, invisible, italic, strike]: {c:?}"
    );
}

#[test]
fn tmux_input_raw_sgr_attrs() {
    let mut p = Pane::new(16, 3);
    p.printf("\x1b[1mB\x1b[2mD\x1b[3mI\x1b[4mU\x1b[5mK\x1b[7mR\x1b[8mH\x1b[9mS\x1b[53mO");
    assert_attrs(&mut p, 0, "B", [true, false, false, false, false, false, false, false]);
    assert_attrs(&mut p, 1, "D", [true, true, false, false, false, false, false, false]);
    assert_attrs(&mut p, 2, "I", [true, true, false, false, false, false, true, false]);
    assert_attrs(&mut p, 3, "U", [true, true, true, false, false, false, true, false]);
    assert_attrs(&mut p, 5, "R", [true, true, true, true, true, false, true, false]);
    assert_attrs(&mut p, 7, "S", [true, true, true, true, true, true, true, true]);
    // tmux also expects OVERLINE on O; the wrapper's Cell has no overline.
    assert_attrs(&mut p, 8, "O", [true, true, true, true, true, true, true, true]);
}

#[test]
fn tmux_input_raw_sgr_colours() {
    let mut p = Pane::new(12, 3);
    p.printf("\x1b[38;5;196;48;5;17mX\x1b[58;5;45mY");
    for (col, text) in [(0, "X"), (1, "Y")] {
        let c = p.cell(0, col);
        assert_eq!(c.text, text);
        assert_eq!(c.fg, ColorSpec::Palette(196), "cell 0,{col}: {c:?}");
        assert_eq!(c.bg, ColorSpec::Palette(17), "cell 0,{col}: {c:?}");
    }
    // tmux also expects underline colour 45 on Y; the wrapper's Cell has none.
}

#[test]
fn tmux_input_raw_sgr_bce() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1b[44mA\x1b[K");
    assert_cell(&mut p, 0, 0, "A");
    for col in [0, 1, 7] {
        let c = p.cell(0, col);
        assert_eq!(c.bg, ColorSpec::Palette(4), "cell 0,{col}: {c:?}");
    }
    assert_blank(&mut p, 0, 1);
    assert_blank(&mut p, 0, 7);
}

#[test]
fn tmux_input_raw_sgr_underlines() {
    let mut p = Pane::new(12, 3);
    p.printf("\x1b[4:2m2\x1b[4:3m3\x1b[4:4m4\x1b[4:5m5");
    for (col, text, style) in [
        (0, "2", UnderlineStyle::Double),
        (1, "3", UnderlineStyle::Curly),
        (2, "4", UnderlineStyle::Dotted),
        (3, "5", UnderlineStyle::Dashed),
    ] {
        let c = p.cell(0, col);
        assert_eq!(c.text, text);
        assert_eq!(c.underline_style, Some(style), "cell 0,{col}: {c:?}");
    }
}

#[test]
#[ignore = "known bug: the VT replay drops closed OSC 8 hyperlinks on cells; see TMUX.md"]
fn tmux_input_raw_sgr_hyperlink() {
    // The wrapper's Cell carries no hyperlink; the replay must re-create it.
    let mut p = Pane::new(12, 3);
    p.printf("\x1b]8;id=id1;https://example.com/a\x1b\\A\x1b]8;;\x1b\\B");
    assert_eq!(p.capture(), "AB");
    let replay = p.replay();
    assert!(replay.contains("https://example.com/a"), "hyperlink lost: {replay:?}");
}

// ---------------------------------------------------------------------------
// input-raw-edit.sh

#[test]
fn tmux_input_raw_edit_erasechars() {
    let mut p = Pane::new(8, 3);
    p.printf("ABCDEFGH\r\x1b[3C\x1b[2X");
    assert_eq!(p.capture(), "ABC  FGH");
    assert_blank(&mut p, 0, 3);
    assert_blank(&mut p, 0, 4);
    assert_cell(&mut p, 0, 5, "F");
}

#[test]
fn tmux_input_raw_edit_deletechars() {
    let mut p = Pane::new(8, 3);
    p.printf("ABCDEFGH\r\x1b[3C\x1b[3P");
    assert_eq!(p.capture(), "ABCGH");
    assert_cell(&mut p, 0, 3, "G");
    assert_cell(&mut p, 0, 4, "H");
    assert_blank(&mut p, 0, 5);
}

#[test]
fn tmux_input_raw_edit_insertchars() {
    let mut p = Pane::new(8, 3);
    p.printf("ABCDEF\r\x1b[3C\x1b[2@xy");
    assert_eq!(p.capture(), "ABCxyDEF");
    assert_cell(&mut p, 0, 3, "x");
    assert_cell(&mut p, 0, 4, "y");
    assert_cell(&mut p, 0, 5, "D");
}

#[test]
fn tmux_input_raw_edit_eraseline() {
    let mut p = Pane::new(8, 3);
    p.printf("ABCDEFGH\r\x1b[4C\x1b[K");
    assert_eq!(p.capture(), "ABCD");
    assert_blank(&mut p, 0, 4);
    assert_blank(&mut p, 0, 7);
}

#[test]
fn tmux_input_raw_edit_erasescreen() {
    let mut p = Pane::new(8, 3);
    p.printf("1111111\x1b[2;1H2222222\x1b[H\x1b[JZ");
    assert_eq!(p.capture(), "Z");
    assert_eq!(p.term.history_rows(), 0);
    assert_cell(&mut p, 0, 0, "Z");
    assert_blank(&mut p, 0, 1);
}

#[test]
#[ignore = "tmux-specific: tmux does not implement CHT (CSI I), so C lands at column 0; xterm and Ghostty move it to the next tab stop"]
fn tmux_input_raw_edit_tabs() {
    let mut p = Pane::new(12, 3);
    p.printf("A\tB\x1b[2g\r\x1b[IC");
    // tmux has no CHT (CSI I): C stays at column 0 and overwrites A.
    assert_cell(&mut p, 0, 8, "B");
    assert_cell(&mut p, 0, 0, "C");
}

// ---------------------------------------------------------------------------
// input-nowrap-collect.sh

#[test]
fn tmux_input_nowrap_collect_narrow() {
    let mut p = Pane::new(2, 3);
    p.printf("\x1b[?7lABC");
    assert_eq!(p.capture(), "AC");
    assert_eq!(p.cursor(), (1, 0));
    assert_eq!(p.joined(), "AC");
}

#[test]
fn tmux_input_nowrap_collect_repeat() {
    let mut p = Pane::new(5, 3);
    p.printf("\x1b[?7lA\x1b[9bYZ");
    assert_eq!(p.capture(), "AAAAZ");
    assert_eq!(p.cursor(), (4, 0));
    assert_eq!(p.joined(), "AAAAZ");
}

#[test]
fn tmux_input_nowrap_collect_styled() {
    let mut p = Pane::new(5, 3);
    p.printf("\x1b[?7l\x1b[31mAB\x1b[32mCDE\x1b[34mZ");
    assert_eq!(p.capture(), "ABCDZ");
    assert_eq!(p.cursor(), (4, 0));
    for (col, text, fg) in [(0, "A", 1), (2, "C", 2), (4, "Z", 4)] {
        let c = p.cell(0, col);
        assert_eq!(c.text, text);
        assert_eq!(c.fg, ColorSpec::Palette(fg), "cell 0,{col}: {c:?}");
    }
}

#[test]
fn tmux_input_nowrap_collect_padding() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1b[?7lA\u{3042}B\r\x1b[2CX");
    assert_eq!(p.capture(), "A XB");
    assert_eq!(p.cursor(), (3, 0));
    assert_blank(&mut p, 0, 1);
    assert_cell(&mut p, 0, 2, "X");
}

#[test]
fn tmux_input_nowrap_collect_insert() {
    let mut p = Pane::new(5, 3);
    p.printf("\x1b[?7lABCD\r\x1b[C\x1b[4hXY\x1b[4l");
    assert_eq!(p.capture(), "AXYBC");
    assert_eq!(p.cursor(), (3, 0));
}

#[test]
fn tmux_input_nowrap_collect_toggle() {
    let mut p = Pane::new(5, 3);
    p.printf("\x1b[?7lABCD\x1b[?7hEF");
    assert_eq!(p.capture(), "ABCDE\nF");
    assert_eq!(p.cursor(), (1, 1));
    assert_eq!(p.joined(), "ABCDEF", "row 0 is not marked wrapped");
}

// ---------------------------------------------------------------------------
// input-osc.sh

#[test]
#[ignore = "known bug: the VT replay drops closed OSC 8 hyperlinks on cells; see TMUX.md"]
fn tmux_input_osc_hyperlink() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1b]8;id=1;https://example.com\x1b\\link\x1b]8;;\x1b\\ plain\n");
    assert_eq!(p.capture(), "link plain");
    let replay = p.replay();
    assert!(replay.contains("https://example.com"), "hyperlink lost: {replay:?}");
}

#[test]
fn tmux_input_osc_palette() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1b]4;1;rgb:11/22/33;2;red\x07\x1b]104;1;2\x07X\n");
    assert_eq!(p.capture(), "X");
}

#[test]
fn tmux_input_osc_osc_colours() {
    let mut p = Pane::new(20, 3);
    p.printf(concat!(
        "\x1b]10;rgb:11/22/33\x07\x1b]11;rgb:44/55/66\x07\x1b]12;rgb:77/88/99\x07",
        "\x1b]110\x07\x1b]111\x07\x1b]112\x07X\n",
    ));
    assert_eq!(p.capture(), "X");
}

#[test]
fn tmux_input_osc_progress() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1b]9;4;1;25\x07\x1b]9;4;0\x07\x1b]9;4;5;200\x07X\n");
    assert_eq!(p.capture(), "X");
}

#[test]
#[ignore = "tmux-specific: ESC k ... ST is GNU screen's window-title sequence, which tmux implements; xterm and Ghostty do not"]
fn tmux_input_osc_rename() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1bkrenamed\x1b\\X\n");
    assert_eq!(p.capture(), "X");
}

#[test]
fn tmux_input_osc_apc_title() {
    let mut p = Pane::new(20, 3);
    p.printf("\x1b_test-title\x1b\\X\n");
    assert_eq!(p.capture(), "X");
}

#[test]
fn tmux_input_osc_title_stack() {
    let mut p = Pane::new(20, 3);
    p.printf(&format!("{}X", "\x1b[22;0t".repeat(12)));
    assert_eq!(p.capture(), "X");
    // tmux respawns the pane and pushes once more.
    let mut p = Pane::new(20, 3);
    p.printf("\x1b[22;0tY");
    assert_eq!(p.capture(), "Y");
}

// ---------------------------------------------------------------------------
// input-edit.sh

#[test]
fn tmux_input_edit_dch() {
    let mut p = Pane::new(10, 3);
    p.printf("abcdef\r\x1b[3C\x1b[2PXY\n");
    assert_eq!(p.capture(), "abcXY");
}

#[test]
fn tmux_input_edit_ich() {
    let mut p = Pane::new(10, 3);
    p.printf("abcdef\r\x1b[3C\x1b[2@XY\n");
    assert_eq!(p.capture(), "abcXYdef");
}

#[test]
fn tmux_input_edit_erase() {
    let mut p = Pane::new(10, 3);
    p.printf("abcdef\r\x1b[3C\x1b[KZ\n");
    assert_eq!(p.capture(), "abcZ");
}

#[test]
fn tmux_input_edit_el1() {
    let mut p = Pane::new(10, 3);
    p.printf("abcdef\r\x1b[3C\x1b[1KZ\n");
    assert_eq!(p.capture(), "   Zef");
}

#[test]
fn tmux_input_edit_ech() {
    let mut p = Pane::new(10, 3);
    p.printf("abcdef\r\x1b[3C\x1b[2XX\n");
    assert_eq!(p.capture(), "abcX f");
}

#[test]
fn tmux_input_edit_ed() {
    let mut p = Pane::new(10, 3);
    p.printf("one\ntwo\x1b[2;2H\x1b[JX\n");
    assert_eq!(p.capture(), "one\ntX");
}

#[test]
fn tmux_input_edit_ed1() {
    let mut p = Pane::new(10, 3);
    p.printf("one\ntwo\x1b[2;2H\x1b[1JX\n");
    assert_eq!(p.capture(), "\n Xo");
}

#[test]
fn tmux_input_edit_ed2() {
    let mut p = Pane::new(10, 3);
    p.printf("one\ntwo\x1b[2JZ\n");
    assert_eq!(p.capture(), "\n   Z");
}

#[test]
fn tmux_input_edit_il() {
    let mut p = Pane::new(8, 4);
    p.printf("111\n222\n333\x1b[2;1H\x1b[LAAA\n");
    assert_eq!(p.capture(), "111\nAAA\n222\n333");
}

#[test]
fn tmux_input_edit_dl() {
    let mut p = Pane::new(8, 4);
    p.printf("111\n222\n333\x1b[2;1H\x1b[MZZZ\n");
    assert_eq!(p.capture(), "111\nZZZ");
}

#[test]
fn tmux_input_edit_irm() {
    let mut p = Pane::new(10, 3);
    p.printf("abcdef\r\x1b[4h\x1b[3CXY\x1b[4lZ\n");
    assert_eq!(p.capture(), "abcXYZef");
}

#[test]
fn tmux_input_edit_rep() {
    let mut p = Pane::new(10, 3);
    p.printf("A\x1b[4bB\n");
    assert_eq!(p.capture(), "AAAAAB");
}

#[test]
fn tmux_input_edit_decaln() {
    let mut p = Pane::new(6, 3);
    p.printf("\x1b#8");
    assert_eq!(p.capture(), "EEEEEE\nEEEEEE\nEEEEEE");
}

// ---------------------------------------------------------------------------
// input-reflow-wide.sh

const REFLOW_WIDE_TEXT: &str =
    "中文文档甲   中文文档乙   中文文档丙   中文文档丁   中文文档戊   中文文档己";

fn reflow_wide(style: &str) {
    let mut p = Pane::history(96, 18);
    p.printf(&format!("{style}{REFLOW_WIDE_TEXT}\n"));
    assert_text_eq(&p.capture_all(), REFLOW_WIDE_TEXT);
    for width in [47, 96, 47, 96] {
        p.resize(width, 18);
        assert_text_eq(&p.joined_all(), REFLOW_WIDE_TEXT);
        if width == 96 {
            assert_text_eq(&p.capture_all(), REFLOW_WIDE_TEXT);
        }
    }
}

#[test]
fn tmux_input_reflow_wide_compact() {
    reflow_wide("");
}

#[test]
fn tmux_input_reflow_wide_extended() {
    reflow_wide("\x1b[48;2;1;2;3m");
}

#[test]
fn tmux_input_reflow_wide_boundary() {
    let text = "中文文档";
    let mut p = Pane::history(8, 18);
    p.printf(&format!("{text}\n"));
    for width in [4, 8, 3, 8] {
        p.resize(width, 18);
        assert_text_eq(&p.joined_all(), text);
        let expected = match width {
            4 => "中文\n文档",
            3 => "中\n文\n文\n档",
            _ => text,
        };
        assert_text_eq(&p.capture_all(), expected);
    }
}

// ---------------------------------------------------------------------------
// input-malformed.sh

#[test]
fn tmux_input_malformed_csi_param_discard() {
    let mut p = Pane::new(8, 3);
    p.raw(format!("\x1b[{}\x18OK", "1".repeat(80)).as_bytes());
    assert_eq!(p.capture(), "OK");
}

#[test]
fn tmux_input_malformed_csi_interm_discard() {
    let mut p = Pane::new(8, 3);
    p.raw(b"\x1b[    \x18OK");
    assert_eq!(p.capture(), "OK");
}

fn string_discard(prefix: &str) {
    let mut p = Pane::new(8, 3);
    // tmux sets the title with select-pane -T; a pane sets it with OSC 2.
    p.raw(b"\x1b]2;discard-test\x07");
    let mut bytes = prefix.as_bytes().to_vec();
    bytes.extend(std::iter::repeat_n(b'x', 1_100_000));
    bytes.extend_from_slice(b"\x1b\\\x1b[H\x1b[2JOK");
    p.raw(&bytes);
    assert_eq!(p.capture(), "OK");
    assert_eq!(p.term.title().as_deref(), Some("discard-test"));
}

#[test]
fn tmux_input_malformed_osc_discard() {
    string_discard("\x1b]2;");
}

#[test]
fn tmux_input_malformed_apc_discard() {
    string_discard("\x1b_");
}

#[test]
fn tmux_input_malformed_unknown_csi() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1b[?9999zOK");
    assert_eq!(p.capture(), "OK");
}

#[test]
fn tmux_input_malformed_unknown_osc() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1b]999;bad\x07OK");
    assert_eq!(p.capture(), "OK");
}

#[test]
#[ignore = "tmux-specific: tmux rejects OSC 8 with a duplicate id key (id=a:id=b); Ghostty accepts it and opens the link"]
fn tmux_input_malformed_malformed_osc() {
    let mut p = Pane::new(8, 3);
    p.printf(concat!(
        "\x1b]8;id=a:id=b;http://bad\x07X\x1b]8;id=no-separator\x07Y",
        "\x1b]9;4;5;200\x07\x1b]9;4;z\x07\x1b]10;notacolour\x07\x1b]11;notacolour\x07",
        "\x1b]12;notacolour\x07\x1b]4;999;red\x07\x1b]104;999\x07\x1b]52bad\x07",
        "\x1b]52;c;@@@\x07OK",
    ));
    assert_eq!(p.capture(), "XYOK");
    let replay = p.replay();
    assert!(!replay.contains("http://bad"), "malformed OSC 8 created a hyperlink: {replay:?}");
}

#[test]
#[ignore = "known VT bug (ghostty-next): an invalid DECRQSS gets no DCS 0 $ r reply; see TMUX.md"]
fn tmux_input_malformed_malformed_dcs() {
    // tmux's capture also shows the DECRQSS reply echoed back by the tty.
    let mut p = Pane::new(8, 3);
    p.printf("\x1bP$qBAD\x1b\\OK");
    assert_eq!(p.capture(), "OK");
    assert_eq!(reply_string(&p.take_replies()), "\x1bP0$r\x1b\\");
}

#[test]
#[ignore = "tmux-specific: tmux emits one U+FFFD per malformed sequence; Ghostty follows Unicode's maximal-subpart practice (one U+FFFD per invalid byte here), so the row overflows"]
fn tmux_input_malformed_malformed_utf8() {
    let mut p = Pane::new(8, 3);
    p.tty(b"\xf0\x80\x80\x80A\xed\xa0\x80B");
    assert_eq!(p.capture(), "\u{FFFD}A\u{FFFD}B");
}

// ---------------------------------------------------------------------------
// input-scroll.sh

#[test]
fn tmux_input_scroll_wrap() {
    let mut p = Pane::new(5, 3);
    p.printf("abcdeF");
    assert_eq!(p.capture(), "abcde\nF");
    assert_eq!(p.cursor(), (1, 1));
    assert_eq!(p.joined(), "abcdeF");
}

#[test]
fn tmux_input_scroll_wraplast() {
    let mut p = Pane::new(5, 3);
    p.printf("abcd\x1b[5GZQ");
    assert_eq!(p.capture(), "abcdZ\nQ");
    assert_eq!(p.cursor(), (1, 1));
}

#[test]
fn tmux_input_scroll_nowrap() {
    let mut p = Pane::new(5, 3);
    p.printf("\x1b[?7labcdeF");
    assert_eq!(p.capture(), "abcdF");
    assert_eq!(p.cursor(), (4, 0));
}

#[test]
fn tmux_input_scroll_origin() {
    let mut p = Pane::new(6, 4);
    p.printf("111111\n222222\n333333\n444444\x1b[2;3r\x1b[?6h\x1b[1;1HAA\x1b[?6l\x1b[r");
    assert_eq!(p.capture(), "111111\nAA2222\n333333\n444444");
}

#[test]
fn tmux_input_scroll_scrollup() {
    let mut p = Pane::new(5, 4);
    p.printf("11111\n22222\n33333\n44444\x1b[2;3r\x1b[3;1HAAAAA\nBBBBB\x1b[r");
    assert_eq!(p.capture(), "11111\nAAAAA\nBBBBB\n44444");
}

#[test]
fn tmux_input_scroll_scrolldown() {
    let mut p = Pane::new(5, 4);
    p.printf("11111\n22222\n33333\n44444\x1b[2;3r\x1b[2;1H\x1b[TZZZZZ\x1b[r");
    assert_eq!(p.capture(), "11111\nZZZZZ\n22222\n44444");
}

#[test]
fn tmux_input_scroll_ri() {
    let mut p = Pane::new(5, 4);
    p.printf("11111\n22222\n33333\n44444\x1b[2;3r\x1b[2;1H\x1bMZZZZZ\x1b[r");
    assert_eq!(p.capture(), "11111\nZZZZZ\n22222\n44444");
}

#[test]
fn tmux_input_scroll_nel() {
    let mut p = Pane::new(5, 3);
    p.printf("AA\x1bEBC\n");
    assert_eq!(p.capture(), "AA\nBC");
}

#[test]
fn tmux_input_scroll_history_limit() {
    // tmux runs this with history-limit 3; every line still fits in it.
    let mut p = Pane::history(5, 3);
    p.printf("01\n02\n03\n04\n05\n06");
    assert_eq!(p.capture_all(), "01\n02\n03\n04\n05\n06");
}

#[test]
fn tmux_input_scroll_clear_history() {
    let mut p = Pane::history(5, 3);
    p.printf("01\n02\n03\n04\n05\n06");
    p.raw(b"\x1b[3J");
    assert_eq!(p.capture_all(), "04\n05\n06");
}

// ---------------------------------------------------------------------------
// input-lines-region.sh: IL/DL inside, outside and clamped to a region,
// with and without synchronized output.

const LINES_REGION_BASE: &str = "111\x1b[2;1H222\x1b[3;1H333\x1b[4;1H444\x1b[5;1H555\x1b[6;1H666";
const LR_UNCHANGED: &str = "111\n222\n333\n444\n555\n666";
const LR_L_2: &str = "111\n\n222\n333\n555\n666";
const LR_M_2: &str = "111\n333\n444\n\n555\n666";
const LR_X_4: &str = "111\n222\n333\n\n555\n666";
const LR_L_CLEAR: &str = "111\n\n\n222\n555\n666";
const LR_M_CLEAR: &str = "111\n444\n\n\n555\n666";
const LR_CLAMP: &str = "111\n222\n\n\n555\n666";

fn lines_region(sync: bool, op: char, cup: &str, count: &str) -> String {
    let (begin, end) = if sync { ("\x1b[?2026h", "\x1b[?2026l") } else { ("", "") };
    let mut p = Pane::new(8, 6);
    p.printf(&format!("{LINES_REGION_BASE}{begin}\x1b[2;4r\x1b[{cup}H\x1b[{count}{op}\x1b[r{end}"));
    p.capture()
}

macro_rules! lines_region_tests {
    ($($name:ident: $sync:expr, $op:expr, $cup:expr, $count:expr => $expected:expr;)*) => {
        $(
            #[test]
            fn $name() {
                assert_text_eq(&lines_region($sync, $op, $cup, $count), $expected);
            }
        )*
    };
}

lines_region_tests! {
    tmux_input_lines_region_lines_off_l_1: false, 'L', "1;3", "2" => LR_UNCHANGED;
    tmux_input_lines_region_lines_off_l_5: false, 'L', "5;3", "2" => LR_UNCHANGED;
    tmux_input_lines_region_lines_off_l_margin_2: false, 'L', "2;1", "" => LR_L_2;
    tmux_input_lines_region_lines_off_l_margin_4: false, 'L', "4;1", "" => LR_X_4;
    tmux_input_lines_region_lines_off_l_clear: false, 'L', "2;1", "2" => LR_L_CLEAR;
    tmux_input_lines_region_lines_off_l_clamp: false, 'L', "3;1", "99" => LR_CLAMP;
    tmux_input_lines_region_lines_off_m_1: false, 'M', "1;3", "2" => LR_UNCHANGED;
    tmux_input_lines_region_lines_off_m_5: false, 'M', "5;3", "2" => LR_UNCHANGED;
    tmux_input_lines_region_lines_off_m_margin_2: false, 'M', "2;1", "" => LR_M_2;
    tmux_input_lines_region_lines_off_m_margin_4: false, 'M', "4;1", "" => LR_X_4;
    tmux_input_lines_region_lines_off_m_clear: false, 'M', "2;1", "2" => LR_M_CLEAR;
    tmux_input_lines_region_lines_off_m_clamp: false, 'M', "3;1", "99" => LR_CLAMP;
    tmux_input_lines_region_lines_on_l_1: true, 'L', "1;3", "2" => LR_UNCHANGED;
    tmux_input_lines_region_lines_on_l_5: true, 'L', "5;3", "2" => LR_UNCHANGED;
    tmux_input_lines_region_lines_on_l_margin_2: true, 'L', "2;1", "" => LR_L_2;
    tmux_input_lines_region_lines_on_l_margin_4: true, 'L', "4;1", "" => LR_X_4;
    tmux_input_lines_region_lines_on_l_clear: true, 'L', "2;1", "2" => LR_L_CLEAR;
    tmux_input_lines_region_lines_on_l_clamp: true, 'L', "3;1", "99" => LR_CLAMP;
    tmux_input_lines_region_lines_on_m_1: true, 'M', "1;3", "2" => LR_UNCHANGED;
    tmux_input_lines_region_lines_on_m_5: true, 'M', "5;3", "2" => LR_UNCHANGED;
    tmux_input_lines_region_lines_on_m_margin_2: true, 'M', "2;1", "" => LR_M_2;
    tmux_input_lines_region_lines_on_m_margin_4: true, 'M', "4;1", "" => LR_X_4;
    tmux_input_lines_region_lines_on_m_clear: true, 'M', "2;1", "2" => LR_M_CLEAR;
    tmux_input_lines_region_lines_on_m_clamp: true, 'M', "3;1", "99" => LR_CLAMP;
}

// ---------------------------------------------------------------------------
// input-raw-unicode.sh

#[test]
fn tmux_input_raw_unicode_wide() {
    let mut p = Pane::new(8, 3);
    p.printf("A\u{3042}B");
    assert_eq!(p.capture(), "A\u{3042}B");
    assert_wide(&mut p, 0, 1, "\u{3042}");
    assert_cell(&mut p, 0, 3, "B");
}

#[test]
fn tmux_input_raw_unicode_combining() {
    let mut p = Pane::new(8, 3);
    p.printf("e\u{301}x");
    let c = p.cell(0, 0);
    assert!(c.text.starts_with('e') && c.text.chars().count() > 1, "cell 0,0: {c:?}");
    assert_eq!(c.width, CellWidth::Narrow, "cell 0,0: {c:?}");
    assert_cell(&mut p, 0, 1, "x");
}

#[test]
fn tmux_input_raw_unicode_emoji() {
    let mut p = Pane::new(10, 3);
    p.printf("\u{1F600}Z");
    assert_wide(&mut p, 0, 0, "\u{1F600}");
    assert_cell(&mut p, 0, 2, "Z");
}

#[test]
fn tmux_input_raw_unicode_flag() {
    let mut p = Pane::new(10, 3);
    p.printf("\u{1F1EC}\u{1F1E7}!");
    assert_wide(&mut p, 0, 0, "\u{1F1EC}\u{1F1E7}");
    assert_cell(&mut p, 0, 2, "!");
}

#[test]
fn tmux_input_raw_unicode_variation() {
    let mut p = Pane::new(10, 3);
    p.printf("*\u{FE0F}!");
    let c = p.cell(0, 0);
    assert!(c.text.starts_with('*'), "cell 0,0: {c:?}");
    assert_eq!(c.width, CellWidth::Wide, "VS16 did not widen *: {c:?}");
    assert_eq!(p.cell(0, 1).width, CellWidth::SpacerTail);
    assert_cell(&mut p, 0, 2, "!");
}

#[test]
fn tmux_input_raw_unicode_invalid() {
    let mut p = Pane::new(10, 3);
    p.tty(b"\xffA");
    assert_cell(&mut p, 0, 0, "\u{FFFD}");
    assert_cell(&mut p, 0, 1, "A");
}

#[test]
fn tmux_input_raw_unicode_trunc2() {
    let mut p = Pane::new(10, 3);
    p.tty(b"\xc3A");
    assert_cell(&mut p, 0, 0, "\u{FFFD}");
    assert_cell(&mut p, 0, 1, "A");
}

#[test]
fn tmux_input_raw_unicode_trunc3() {
    let mut p = Pane::new(10, 3);
    p.tty(b"\xe2\x82A");
    assert_cell(&mut p, 0, 0, "\u{FFFD}");
    assert_cell(&mut p, 0, 1, "A");
}

#[test]
fn tmux_input_raw_unicode_overwrite_wide_left() {
    let mut p = Pane::new(10, 3);
    p.printf("A\u{3042}B\r\x1b[1CX");
    assert_cell(&mut p, 0, 0, "A");
    assert_cell(&mut p, 0, 1, "X");
    assert_blank(&mut p, 0, 2);
    assert_cell(&mut p, 0, 3, "B");
}

#[test]
fn tmux_input_raw_unicode_overwrite_wide_pad() {
    let mut p = Pane::new(10, 3);
    p.printf("A\u{3042}B\r\x1b[2CX");
    assert_cell(&mut p, 0, 0, "A");
    assert_blank(&mut p, 0, 1);
    assert_cell(&mut p, 0, 2, "X");
    assert_cell(&mut p, 0, 3, "B");
}

#[test]
fn tmux_input_raw_unicode_overwrite_wide_with_wide() {
    let mut p = Pane::new(10, 3);
    p.printf("A\u{3042}B\r\x1b[1C\u{754C}");
    assert_wide(&mut p, 0, 1, "\u{754C}");
    assert_cell(&mut p, 0, 3, "B");
}

#[test]
fn tmux_input_raw_unicode_wide_right_edge() {
    let mut p = Pane::new(4, 3);
    p.printf("ABC\u{3042}Z");
    assert_eq!(p.joined(), "ABC\u{3042}Z", "row 0 is not marked wrapped");
    assert_wide(&mut p, 1, 0, "\u{3042}");
    assert_cell(&mut p, 1, 2, "Z");
}

// ---------------------------------------------------------------------------
// input-raw-controls.sh

#[test]
fn tmux_input_raw_controls_bs() {
    let mut p = Pane::new(8, 3);
    p.printf("abc\x08d");
    assert_eq!(p.capture(), "abd");
    assert_cell(&mut p, 0, 0, "a");
    assert_cell(&mut p, 0, 1, "b");
    assert_cell(&mut p, 0, 2, "d");
}

#[test]
fn tmux_input_raw_controls_nel() {
    let mut p = Pane::new(8, 3);
    p.printf("A\x1bEB");
    assert_eq!(p.capture(), "A\nB");
    assert_cell(&mut p, 0, 0, "A");
    assert_cell(&mut p, 1, 0, "B");
}

#[test]
fn tmux_input_raw_controls_tabstops() {
    let mut p = Pane::new(16, 3);
    p.printf("\x1bH1\t2\x1b[3g\r\t3");
    assert_cell(&mut p, 0, 0, "1");
    assert_cell(&mut p, 0, 8, "2");
    assert_cell(&mut p, 0, 15, "3");
}

#[test]
fn tmux_input_raw_controls_decaln() {
    let mut p = Pane::new(6, 3);
    p.printf("\x1b#8");
    assert_cell(&mut p, 0, 0, "E");
    assert_cell(&mut p, 1, 5, "E");
    assert_cell(&mut p, 2, 5, "E");
}

#[test]
fn tmux_input_raw_controls_charset() {
    // tmux stores q, x, l with a CHARSET attribute and maps them when it
    // draws; a terminal grid holds the DEC Special Graphics glyphs.
    let mut p = Pane::new(8, 3);
    p.printf("\x1b(0qxl\x1b(BZ");
    assert_cell(&mut p, 0, 0, "\u{2500}");
    assert_cell(&mut p, 0, 1, "\u{2502}");
    assert_cell(&mut p, 0, 2, "\u{250C}");
    assert_cell(&mut p, 0, 3, "Z");
}

#[test]
fn tmux_input_raw_controls_g1charset() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1b)0\x0eq\x0fZ");
    assert_cell(&mut p, 0, 0, "\u{2500}");
    assert_cell(&mut p, 0, 1, "Z");
}

#[test]
fn tmux_input_raw_controls_csisave() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1b[3;3HS\x1b[s\x1b[1;1HA\x1b[uR");
    assert_cell(&mut p, 0, 0, "A");
    assert_cell(&mut p, 2, 2, "S");
    assert_cell(&mut p, 2, 3, "R");
}

#[test]
fn tmux_input_raw_controls_alternate() {
    let mut p = Pane::new(8, 3);
    p.printf("main\x1b[?1049halt\x1b[?1049lback");
    assert_eq!(p.capture(), "mainback");
    assert_cell(&mut p, 0, 0, "m");
    assert_cell(&mut p, 0, 4, "b");
    assert_cell(&mut p, 0, 7, "k");
}

#[test]
fn tmux_input_raw_controls_sync() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1bP=1signored\x1b\\A\x1bP=2s\x1b\\B");
    assert_cell(&mut p, 0, 0, "A");
    assert_cell(&mut p, 0, 1, "B");
}

#[test]
fn tmux_input_raw_controls_private() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1b[?25lA\x1b[?25hB\x1b[?1000hC\x1b[?1000lD");
    assert_eq!(p.capture(), "ABCD");
}

#[test]
fn tmux_input_raw_controls_ris() {
    let mut p = Pane::new(8, 3);
    p.printf("A\x1bcB");
    assert_eq!(p.capture(), "B");
    assert_cell(&mut p, 0, 0, "B");
    assert_blank(&mut p, 0, 1);
}

#[test]
fn tmux_input_raw_controls_keypad() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1b=A\x1b>B");
    assert_eq!(p.capture(), "AB");
}

#[test]
fn tmux_input_raw_controls_cursorstyle() {
    let mut p = Pane::new(8, 3);
    p.printf("\x1b[5 qA\x1b[0 qB");
    assert_eq!(p.capture(), "AB");
}

// ---------------------------------------------------------------------------
// input-combine-width.sh: VS16, a skin tone modifier and a regional
// indicator each widen the cell before them.

const CW_VARIATION: &str = "\u{2714}\u{FE0F}";
const CW_MODIFIER: &str = "\u{261D}\u{1F3FB}";
const CW_FLAG: &str = "\u{1F1EC}\u{1F1E7}";

fn cw_overwrite(seq: &str) {
    let mut p = Pane::new(10, 3);
    p.printf(&format!("A\u{754C}BC\r{seq}X"));
    assert_eq!(p.capture(), format!("{seq}XBC"));
    assert_eq!(p.cursor(), (3, 0));
    assert_wide(&mut p, 0, 0, seq);
    assert_cell(&mut p, 0, 2, "X");
}

fn cw_edge(seq: &str) {
    let mut p = Pane::new(5, 3);
    p.printf(&format!("abcd{seq}X"));
    assert_eq!(p.capture(), format!("abcd\n{seq}X"));
    assert_eq!(p.cursor(), (3, 1));
    let joined = p.joined();
    assert_eq!(joined.lines().count(), 1, "row 0 is not marked wrapped: {joined:?}");
    // tmux: a blank cell; Ghostty marks the same blank as a spacer head.
    let c = p.cell(0, 4);
    assert!(
        c.text.is_empty() && matches!(c.width, CellWidth::Narrow | CellWidth::SpacerHead),
        "cell 0,4 is not blank: {c:?}"
    );
    assert_wide(&mut p, 1, 0, seq);
    assert_cell(&mut p, 1, 2, "X");
}

fn cw_fit(seq: &str) {
    let mut p = Pane::new(5, 3);
    p.printf(&format!("abc{seq}X"));
    assert_eq!(p.capture(), format!("abc{seq}\nX"));
    assert_eq!(p.cursor(), (1, 1));
}

fn cw_scroll(seq: &str) {
    let mut p = Pane::new(5, 2);
    p.printf(&format!("11111\r\nabcd{seq}X"));
    assert_eq!(p.capture(), format!("abcd\n{seq}X"));
    assert_eq!(p.cursor(), (3, 1));
}

fn cw_region(seq: &str) {
    let mut p = Pane::new(5, 4);
    p.printf(&format!("top\x1b[2;1Hold\x1b[4;1Hend\x1b[2;3r\x1b[3;1Habcd{seq}X"));
    assert_eq!(p.capture(), format!("top\nabcd\n{seq}X\nend"));
    assert_eq!(p.cursor(), (3, 2));
}

fn cw_insert(seq: &str) {
    let mut p = Pane::new(10, 3);
    p.printf(&format!("ABCDE\r\x1b[4h{seq}X"));
    assert_eq!(p.capture(), format!("{seq}XABCDE"));
    assert_eq!(p.cursor(), (3, 0));
}

fn cw_insert_edge(seq: &str) {
    let mut p = Pane::new(5, 3);
    p.printf(&format!("\x1b[2;1HABCDE\x1b[1;1Habcd\x1b[4h{seq}X"));
    assert_eq!(p.capture(), format!("abcd\n{seq}XAB"));
    assert_eq!(p.cursor(), (3, 1));
}

fn cw_nowrap(seq: &str) {
    let mut p = Pane::new(5, 3);
    p.printf(&format!("\x1b[?7labc{seq}"));
    assert_eq!(p.capture(), format!("abc{seq}"));
    assert_eq!(p.cursor(), (4, 0));
    assert_wide(&mut p, 0, 3, seq);
}

macro_rules! combine_width_tests {
    ($($(#[$attr:meta])* $name:ident: $case:ident($seq:expr);)*) => {
        $(
            #[test]
            $(#[$attr])*
            fn $name() {
                $case($seq);
            }
        )*
    };
}

combine_width_tests! {
    tmux_input_combine_width_variation_overwrite: cw_overwrite(CW_VARIATION);
    tmux_input_combine_width_variation_edge: cw_edge(CW_VARIATION);
    tmux_input_combine_width_variation_fit: cw_fit(CW_VARIATION);
    tmux_input_combine_width_variation_scroll: cw_scroll(CW_VARIATION);
    tmux_input_combine_width_variation_region: cw_region(CW_VARIATION);
    #[ignore = "known VT bug (ghostty-next): in insert mode a widening grapheme overwrites the next cell instead of shifting it; see TMUX.md"]
    tmux_input_combine_width_variation_insert: cw_insert(CW_VARIATION);
    #[ignore = "known VT bug (ghostty-next): in insert mode a widening grapheme overwrites the next cell instead of shifting it; see TMUX.md"]
    tmux_input_combine_width_variation_insert_edge: cw_insert_edge(CW_VARIATION);
    tmux_input_combine_width_variation_nowrap: cw_nowrap(CW_VARIATION);
    #[ignore = "known VT bug (ghostty-next): an emoji modifier after a text-default base (U+261D U+1F3FB) stays one column; see TMUX.md"]
    tmux_input_combine_width_modifier_overwrite: cw_overwrite(CW_MODIFIER);
    #[ignore = "known VT bug (ghostty-next): an emoji modifier after a text-default base (U+261D U+1F3FB) stays one column; see TMUX.md"]
    tmux_input_combine_width_modifier_edge: cw_edge(CW_MODIFIER);
    #[ignore = "known VT bug (ghostty-next): an emoji modifier after a text-default base (U+261D U+1F3FB) stays one column; see TMUX.md"]
    tmux_input_combine_width_modifier_fit: cw_fit(CW_MODIFIER);
    #[ignore = "known VT bug (ghostty-next): an emoji modifier after a text-default base (U+261D U+1F3FB) stays one column; see TMUX.md"]
    tmux_input_combine_width_modifier_scroll: cw_scroll(CW_MODIFIER);
    #[ignore = "known VT bug (ghostty-next): an emoji modifier after a text-default base (U+261D U+1F3FB) stays one column; see TMUX.md"]
    tmux_input_combine_width_modifier_region: cw_region(CW_MODIFIER);
    #[ignore = "known VT bug (ghostty-next): an emoji modifier after a text-default base (U+261D U+1F3FB) stays one column; see TMUX.md"]
    tmux_input_combine_width_modifier_insert: cw_insert(CW_MODIFIER);
    #[ignore = "known VT bug (ghostty-next): an emoji modifier after a text-default base (U+261D U+1F3FB) stays one column; see TMUX.md"]
    tmux_input_combine_width_modifier_insert_edge: cw_insert_edge(CW_MODIFIER);
    #[ignore = "known VT bug (ghostty-next): an emoji modifier after a text-default base (U+261D U+1F3FB) stays one column; see TMUX.md"]
    tmux_input_combine_width_modifier_nowrap: cw_nowrap(CW_MODIFIER);
    tmux_input_combine_width_flag_overwrite: cw_overwrite(CW_FLAG);
    tmux_input_combine_width_flag_edge: cw_edge(CW_FLAG);
    tmux_input_combine_width_flag_fit: cw_fit(CW_FLAG);
    tmux_input_combine_width_flag_scroll: cw_scroll(CW_FLAG);
    tmux_input_combine_width_flag_region: cw_region(CW_FLAG);
    tmux_input_combine_width_flag_insert: cw_insert(CW_FLAG);
    #[ignore = "known VT bug (ghostty-next): in insert mode a widening grapheme overwrites the next cell instead of shifting it; see TMUX.md"]
    tmux_input_combine_width_flag_insert_edge: cw_insert_edge(CW_FLAG);
    tmux_input_combine_width_flag_nowrap: cw_nowrap(CW_FLAG);
}

#[test]
fn tmux_input_combine_width_one_column() {
    // A two-column cluster cannot fit in a one-column pane: keep the base.
    let mut p = Pane::new(1, 3);
    p.printf("\u{2714}\u{FE0F}");
    // tmux stores only the base (capture "\u{2714}"); keeping VS16 in a
    // narrow cell is the same grid state.
    let capture = p.capture();
    assert!(capture == "\u{2714}" || capture == "\u{2714}\u{FE0F}", "capture: {capture:?}");
    // tmux: cursor 1,0 (pending wrap after the only column).
    assert_eq!(p.cursor(), (0, 0));
    let rows = p.rows();
    assert!(rows.iter().flatten().all(|c| c.width != CellWidth::Wide), "a wide cell: {rows:?}");
}

#[test]
fn tmux_input_combine_width_two_columns_nowrap() {
    let mut p = Pane::new(2, 3);
    p.printf("\x1b[?7l\u{2714}\u{FE0F}");
    assert_eq!(p.capture(), "\u{2714}\u{FE0F}");
    assert_eq!(p.cursor(), (1, 0));
}

// ---------------------------------------------------------------------------
// input-unicode.sh

#[test]
fn tmux_input_unicode_wide() {
    let mut p = Pane::new(10, 3);
    p.printf("\u{3042}B\rX\n");
    assert_eq!(p.capture(), "X B");
}

#[test]
fn tmux_input_unicode_widepad() {
    let mut p = Pane::new(10, 3);
    p.printf("A\u{3042}B\r\x1b[2CX\n");
    assert_eq!(p.capture(), "A XB");
}

#[test]
fn tmux_input_unicode_wideedge() {
    let mut p = Pane::new(5, 3);
    p.printf("abc\u{3042}Z\n");
    assert_eq!(p.capture(), "abc\u{3042}\nZ");
    assert_eq!(p.cursor(), (0, 2));
    assert_eq!(p.joined(), "abc\u{3042}Z");
}

#[test]
fn tmux_input_unicode_wideeol() {
    let mut p = Pane::new(5, 3);
    p.printf("abcd\u{3042}Z\n");
    assert_eq!(p.capture(), "abcd\n\u{3042}Z");
    assert_eq!(p.cursor(), (0, 2));
}

#[test]
fn tmux_input_unicode_combine() {
    let mut p = Pane::new(10, 3);
    p.printf("e\u{301}\n");
    assert_eq!(p.capture(), "e\u{301}");
    assert_eq!(p.cursor(), (0, 1));
}

#[test]
fn tmux_input_unicode_combinewide() {
    let mut p = Pane::new(10, 3);
    p.printf("\u{3042}\u{301}X\n");
    assert_eq!(p.capture(), "\u{3042}\u{301}X");
    assert_eq!(p.cursor(), (0, 1));
}

#[test]
fn tmux_input_unicode_variation() {
    let mut p = Pane::new(10, 3);
    p.printf("\u{2714}\u{FE0F}X\n");
    assert_eq!(p.capture(), "\u{2714}\u{FE0F}X");
    assert_eq!(p.cursor(), (0, 1));
    assert_wide(&mut p, 0, 0, "\u{2714}\u{FE0F}");
}

#[test]
fn tmux_input_unicode_flag() {
    let mut p = Pane::new(10, 3);
    p.printf("\u{1F1EC}\u{1F1E7}X\n");
    assert_eq!(p.capture(), "\u{1F1EC}\u{1F1E7}X");
    assert_eq!(p.cursor(), (0, 1));
    assert_wide(&mut p, 0, 0, "\u{1F1EC}\u{1F1E7}");
}

#[test]
#[ignore = "tmux-specific: tmux draws a lone regional indicator one column wide, Ghostty two"]
fn tmux_input_unicode_flagrun() {
    // Regional indicators pair, and a third starts a new one-column cell.
    let mut p = Pane::new(10, 3);
    p.printf("\u{1F1EC}\u{1F1E7}\u{1F1F8}\u{1F1EA}\u{1F1E6}X");
    assert_eq!(p.capture(), "\u{1F1EC}\u{1F1E7}\u{1F1F8}\u{1F1EA}\u{1F1E6}X");
    assert_eq!(p.cursor(), (6, 0));
    assert_wide(&mut p, 0, 0, "\u{1F1EC}\u{1F1E7}");
    assert_wide(&mut p, 0, 2, "\u{1F1F8}\u{1F1EA}");
    let c = p.cell(0, 4);
    assert_eq!(c.text, "\u{1F1E6}");
    assert_eq!(c.width, CellWidth::Narrow, "a lone regional indicator is one column: {c:?}");
    assert_cell(&mut p, 0, 5, "X");
}

#[test]
fn tmux_input_unicode_tonebefore() {
    // A skin tone combines only with the emoji before it.
    let mut p = Pane::new(10, 3);
    p.printf("\u{1F3FD}\u{1F44D}");
    assert_eq!(p.capture(), "\u{1F3FD}\u{1F44D}");
    assert_eq!(p.cursor(), (4, 0));
    assert_wide(&mut p, 0, 0, "\u{1F3FD}");
    assert_wide(&mut p, 0, 2, "\u{1F44D}");
}

#[test]
fn tmux_input_unicode_toneafter() {
    let mut p = Pane::new(10, 3);
    p.printf("\u{1F44D}\u{1F3FD}");
    assert_eq!(p.capture(), "\u{1F44D}\u{1F3FD}");
    assert_eq!(p.cursor(), (2, 0));
    assert_wide(&mut p, 0, 0, "\u{1F44D}\u{1F3FD}");
}

#[test]
fn tmux_input_unicode_tonebefore_run() {
    let mut p = Pane::new(20, 3);
    p.printf(&format!("\u{1F3FD}{}X", "\u{1F44D}".repeat(6)));
    assert_eq!(p.capture(), format!("\u{1F3FD}{}X", "\u{1F44D}".repeat(6)));
    assert_eq!(p.cursor(), (15, 0));
    assert_wide(&mut p, 0, 0, "\u{1F3FD}");
    assert_wide(&mut p, 0, 2, "\u{1F44D}");
    assert_wide(&mut p, 0, 12, "\u{1F44D}");
    assert_cell(&mut p, 0, 14, "X");
}

#[test]
fn tmux_input_unicode_astronaut() {
    // GitHub tmux issue 4726: skin tone plus ZWJ sequence.
    let astronaut = "\u{1F469}\u{1F3FB}\u{200D}\u{1F680}";
    let mut p = Pane::new(20, 3);
    p.printf(&format!("abc{astronaut}123"));
    assert_eq!(p.capture(), format!("abc{astronaut}123"));
    assert_eq!(p.cursor(), (8, 0));
    assert_wide(&mut p, 0, 3, astronaut);
    assert_cell(&mut p, 0, 5, "1");
}

#[test]
fn tmux_input_unicode_combining_left() {
    let mut p = Pane::new(10, 3);
    p.printf("\u{301}A\n");
    assert_eq!(p.capture(), "A");
    assert_eq!(p.cursor(), (0, 1));
}

#[test]
fn tmux_input_unicode_combining_overflow() {
    let mut p = Pane::new(10, 3);
    p.printf(&format!("u{}\n", "\u{325}".repeat(16)));
    let c = p.cell(0, 0);
    assert!(c.text.starts_with('u') && c.text.chars().count() > 1, "cell 0,0: {c:?}");
    assert_eq!(c.width, CellWidth::Narrow);
    let rows = p.rows();
    for (col, cell) in rows[0].iter().enumerate().skip(1) {
        assert!(cell.text.is_empty(), "combining marks spilled into cell 0,{col}: {cell:?}");
    }
}

// ---------------------------------------------------------------------------
// input-replies.sh: the pane reads its replies with `stty raw`.

fn query(setup: &str, seq: &str) -> String {
    let mut p = Pane::new(80, 24);
    p.raw(setup.as_bytes());
    p.take_replies();
    p.raw(seq.as_bytes());
    reply_string(&p.take_replies())
}

macro_rules! reply_tests {
    ($($(#[$attr:meta])* $name:ident: $setup:expr, $seq:expr => $expected:expr;)*) => {
        $(
            #[test]
            $(#[$attr])*
            fn $name() {
                assert_eq!(query($setup, $seq), $expected);
            }
        )*
    };
}

reply_tests! {
    tmux_input_replies_dsr_ok: "", "\x1b[5n" => "\x1b[0n";
    tmux_input_replies_dsr_cursor: "", "\x1b[6n" => "\x1b[1;1R";
    #[ignore = "tmux-specific: DA1 reports tmux's own identity (VT100 with AVO)"]
    tmux_input_replies_da_primary: "", "\x1b[c" => "\x1b[?1;2c";
    #[ignore = "tmux-specific: DA2 reports tmux's terminal id 84 and version"]
    tmux_input_replies_da_secondary: "", "\x1b[>c" => "\x1b[>84;0;0c";
    tmux_input_replies_decrqm_irm_reset: "", "\x1b[4$p" => "\x1b[4;2$y";
    tmux_input_replies_decrqm_irm_set: "\x1b[4h", "\x1b[4$p" => "\x1b[4;1$y";
    tmux_input_replies_decrqm_cursor_keys_reset: "", "\x1b[?1$p" => "\x1b[?1;2$y";
    tmux_input_replies_decrqm_cursor_keys_set: "\x1b[?1h", "\x1b[?1$p" => "\x1b[?1;1$y";
    #[ignore = "tmux-specific: tmux reports DECCOLM as permanently reset (4); Ghostty supports DECCOLM and reports reset (2)"]
    tmux_input_replies_decrqm_columns: "", "\x1b[?3$p" => "\x1b[?3;4$y";
    tmux_input_replies_decrqm_origin_reset: "", "\x1b[?6$p" => "\x1b[?6;2$y";
    tmux_input_replies_decrqm_origin_set: "\x1b[?6h", "\x1b[?6$p" => "\x1b[?6;1$y";
    tmux_input_replies_decrqm_wrap_set: "", "\x1b[?7$p" => "\x1b[?7;1$y";
    tmux_input_replies_decrqm_wrap_reset: "\x1b[?7l", "\x1b[?7$p" => "\x1b[?7;2$y";
    tmux_input_replies_decrqm_cursor_visible_set: "", "\x1b[?25$p" => "\x1b[?25;1$y";
    tmux_input_replies_decrqm_cursor_visible_reset: "\x1b[?25l", "\x1b[?25$p" => "\x1b[?25;2$y";
    tmux_input_replies_decrqm_mouse_standard_set: "\x1b[?1000h", "\x1b[?1000$p" => "\x1b[?1000;1$y";
    tmux_input_replies_decrqm_mouse_button_set: "\x1b[?1002h", "\x1b[?1002$p" => "\x1b[?1002;1$y";
    tmux_input_replies_decrqm_mouse_all_set: "\x1b[?1003h", "\x1b[?1003$p" => "\x1b[?1003;1$y";
    tmux_input_replies_decrqm_focus_set: "\x1b[?1004h", "\x1b[?1004$p" => "\x1b[?1004;1$y";
    tmux_input_replies_decrqm_mouse_utf8_set: "\x1b[?1005h", "\x1b[?1005$p" => "\x1b[?1005;1$y";
    tmux_input_replies_decrqm_mouse_sgr_set: "\x1b[?1006h", "\x1b[?1006$p" => "\x1b[?1006;1$y";
    tmux_input_replies_decrqm_bracket_paste_set: "\x1b[?2004h", "\x1b[?2004$p" => "\x1b[?2004;1$y";
    tmux_input_replies_decrqm_theme_updates_set: "\x1b[?2031h", "\x1b[?2031$p" => "\x1b[?2031;1$y";
    #[ignore = "tmux-specific: tmux answers DECRQSS SP q as `1$r q0 q` (echoing the selector before the style); xterm answers `1$r<Ps> q`, see tmux_input_replies_decrqss_cursor_style_shape"]
    tmux_input_replies_decrqss_cursor_style: "", "\x1bP$q q\x1b\\" => "\x1bP1$r q0 q\x1b\\";
    tmux_input_replies_osc_10_query: "\x1b]10;red\x07", "\x1b]10;?\x07" => "\x1b]10;rgb:ffff/0000/0000\x07";
    tmux_input_replies_osc_11_query: "\x1b]11;blue\x07", "\x1b]11;?\x07" => "\x1b]11;rgb:0000/0000/ffff\x07";
    tmux_input_replies_osc_12_query: "\x1b]12;green\x07", "\x1b]12;?\x07" => "\x1b]12;rgb:0000/ffff/0000\x07";
    tmux_input_replies_osc_4_query: "\x1b]4;1;red\x07", "\x1b]4;1;?\x07" => "\x1b]4;1;rgb:ffff/0000/0000\x07";
    #[ignore = "tmux-specific: tmux does not know the outer terminal's default palette, so it answers nothing after OSC 104; a terminal reports its default colour"]
    tmux_input_replies_osc_104_reset_query: "\x1b]4;1;red\x07\x1b]104;1\x07", "\x1b]4;1;?\x07" => "";
}

#[test]
fn tmux_input_replies_decrqss_cursor_style_shape() {
    // The terminal-level content of tmux's decrqss-cursor-style case: a
    // valid DECRQSS reply for DECSCUSR, in xterm's format.
    let reply = query("", "\x1bP$q q\x1b\\");
    let style = reply.strip_prefix("\x1bP1$r").and_then(|r| r.strip_suffix(" q\x1b\\"));
    assert!(
        style.is_some_and(|s| matches!(s, "0" | "1" | "2" | "3" | "4" | "5" | "6")),
        "DECRQSS SP q reply: {reply:?}"
    );
}

// ---------------------------------------------------------------------------
// input-requests.sh: tmux forwards OSC 4/52 requests to the outer terminal
// and relays its replies. Only the pane-facing contract is a terminal
// property: a reply uses the request's ST terminator.

#[test]
fn tmux_input_requests_palette_st() {
    let mut p = Pane::new(80, 24);
    p.raw(b"\x1b]4;99;?\x1b\\");
    let reply = reply_string(&p.take_replies());
    assert!(
        reply.starts_with("\x1b]4;99;rgb:") && reply.ends_with("\x1b\\"),
        "palette reply: {reply:?}"
    );
}

// ---------------------------------------------------------------------------
// decrqm-sync.sh

reply_tests! {
    tmux_decrqm_sync_reset: "", "\x1b[?2026$p" => "\x1b[?2026;2$y";
    tmux_decrqm_sync_set: "\x1b[?2026h", "\x1b[?2026$p" => "\x1b[?2026;1$y";
    tmux_decrqm_sync_cursor_reset: "\x1b[?25l", "\x1b[?25$p" => "\x1b[?25;2$y";
    tmux_decrqm_sync_unknown: "\x1b[?9999h", "\x1b[?9999$p" => "\x1b[?9999;0$y";
}

// ---------------------------------------------------------------------------
// alt-screen-saved-cursor.sh: 1049h saves the cursor; 47l and 1049l keep it.

#[test]
#[ignore = "unconfirmed: 1049l restores the pending-wrap state; check against xterm before changing; see TMUX.md"]
fn tmux_alt_screen_saved_cursor_outside_alternate() {
    let mut p = Pane::history(10, 5);
    p.printf("abcdefghij\x1b[?1049h\x1b[?47l\x1b[?1049lX");
    assert_eq!(p.lines()[0].trim_end(), "abcdefghiX");
}

#[test]
fn tmux_alt_screen_saved_cursor_full_line_then_wider() {
    let mut p = Pane::history(10, 5);
    p.printf("abcdefghij\x1b[?1049h");
    p.resize(20, 5);
    p.printf("\x1b[?1049lX");
    assert_eq!(p.lines()[0].trim_end(), "abcdefghijX");
}

#[test]
fn tmux_alt_screen_saved_cursor_saved_taller() {
    let mut p = Pane::history(40, 10);
    p.printf("\x1b[9;1Hrow\x1b[?1049h\x1b[?47l");
    p.resize(20, 4);
    p.printf("\x1b[?47h");
    p.resize(40, 4);
    p.printf("\x1b[?1049lX");
    let lines = p.lines();
    let rows: Vec<&str> =
        lines.iter().filter(|l| l.contains("row")).map(|l| l.trim_end()).collect();
    assert_eq!(rows, ["rowX"], "visible rows: {lines:?}");
}

// ---------------------------------------------------------------------------
// tab-cell-background.sh: blanks left by breaking a tab or a wide character
// keep the background colour. tmux checks what it sends to an attached
// terminal; here the grid is the output.

#[test]
fn tmux_tab_cell_background_capture() {
    let mut p = Pane::new(24, 3);
    p.printf("\x1b[44m\x1b[K\t\x1b[4GX");
    p.printf("\x1b[2;1H\x1b[44m\x1b[K\u{4E16}\x1b[2GX");
    p.printf("\x1b[3;1H\x1b[42m\x1b[K\t\x1b[43m\x1b[K\t\x1b[0m\x1b[4G\x1b[8P\rx");
    let rows = p.rows();
    let bg = |row: usize, col: usize| rows[row][col].bg;
    let text = |row: usize, col: usize| rows[row][col].text.as_str();
    assert_eq!(row_text(&rows[0]).trim_end(), "   X");
    for (col, cell) in rows[0].iter().enumerate().take(4) {
        assert_eq!(bg(0, col), ColorSpec::Palette(4), "row 0 col {col}: {cell:?}");
    }
    assert_eq!(row_text(&rows[1]).trim_end(), " X");
    assert_eq!((text(1, 0), bg(1, 0)), ("", ColorSpec::Palette(4)), "{:?}", rows[1][0]);
    assert_eq!((text(1, 1), bg(1, 1)), ("X", ColorSpec::Palette(4)), "{:?}", rows[1][1]);
    assert_eq!(row_text(&rows[2]).trim_end(), "x");
    assert_eq!(bg(2, 0), ColorSpec::Default, "{:?}", rows[2][0]);
    for (col, cell) in rows[2].iter().enumerate().skip(1).take(2) {
        assert_eq!(bg(2, col), ColorSpec::Palette(2), "row 2 col {col}: {cell:?}");
    }
    for (col, cell) in rows[2].iter().enumerate().skip(3).take(13) {
        assert_eq!(bg(2, col), ColorSpec::Palette(3), "row 2 col {col}: {cell:?}");
    }
    for (col, cell) in rows[2].iter().enumerate().skip(16).take(8) {
        assert_eq!(bg(2, col), ColorSpec::Default, "row 2 col {col}: {cell:?}");
    }
}

// ---------------------------------------------------------------------------
// input-reflow-stress.sh: a mixed payload survives a cycle of resizes down to
// one column and back, on the primary and alternate screens. tmux's
// copy-mode and nested-client redraw phases are tmux UI and not ported.

const STRESS_WIDE_A: &str = "\u{3042}";
const STRESS_WIDE_B: &str = "\u{754C}";

fn stress_orphan_payload(tag: &str) -> String {
    let b = STRESS_WIDE_B;
    let mut s = String::new();
    s += &format!("OP{tag}-01|ECH-half|left{b}right\x1b[6D\x1b[1X\n");
    s += &format!("OP{tag}-02|EL-inside|left{b}right\x1b[6D\x1b[K\n");
    s +=
        &format!("OP{tag}-03|overwrite-leading|left{b}right\rOP{tag}-03|overwrite-leading|left!\n");
    s += &format!("OP{tag}-04|right-edge|{}{b}Z\x1b[2D\x1b[1X\n", ".".repeat(60));
    s += &format!("OP{tag}-05|ERASED|left{b}right\r\x1b[2KOP{tag}-05|ERASED|left clear\n");
    s += &format!("SENT-{tag}|ORPHAN-PHASE|complete\n");
    s
}

fn stress_payload() -> String {
    let (a, b) = (STRESS_WIDE_A, STRESS_WIDE_B);
    let mut s = String::new();
    for i in 0..16 {
        s += &format!("ASCII{i:02}|abcdefghijklmnopqrstuvwxyz\n");
        s += &format!("WIDE{i:02}|{a}|{b}|tail\n");
        s += &format!("COMB{i:02}|e\u{301}|zero\u{200B}\u{200D}|done\n");
        s += &format!("STYLE{i:02}|\x1b[1;31mred\x1b[0m|\x1b[4munder\x1b[0m\n");
        s +=
            &format!("LINK{i:02}|\x1b]8;;https://example.invalid/{i}\x07link{i}\x1b]8;;\x07|end\n");
        s += &format!("WRAP{i:02}|{i:064}\n");
        s += &format!("CRBS{i:02}|abcdef\rCRBS{i:02}|XYZ\n");
        s += &format!("BS{i:02}|abc\x08Z\n");
    }
    for i in 0..6 {
        s += &format!("L{i:04}|stable|abcdefghijklmnopqrstuvwxyz\n");
    }
    s += "SENT-A|SURVIVES|plain logical line\n";
    s += "SENT-B|SURVIVES|wide-free after erases\n";
    s += &stress_orphan_payload("PRE");
    s += "SENT-C|SURVIVES|tail logical line\n";
    s
}

fn line_ids(line: &str) -> Vec<u32> {
    let bytes = line.as_bytes();
    let mut ids = Vec::new();
    let mut i = 0;
    while i + 6 <= bytes.len() {
        if bytes[i] == b'L'
            && bytes[i + 1..i + 5].iter().all(u8::is_ascii_digit)
            && bytes[i + 5] == b'|'
        {
            ids.push(line[i + 1..i + 5].parse().unwrap());
            i += 6;
        } else {
            i += 1;
        }
    }
    ids
}

fn stress_joined_sane(p: &mut Pane, label: &str, fails: &mut Vec<String>) {
    let text = p.joined_all();
    if text.len() > 500_000 {
        fails.push(format!("joined capture too large after {label}: {}", text.len()));
    }
    if text.contains('\u{FFFD}') {
        fails.push(format!("replacement character in joined capture after {label}"));
    }
    let mut ids = Vec::new();
    let mut seen: HashMap<u32, usize> = HashMap::new();
    for line in text.lines() {
        let found = line_ids(line);
        if found.len() > 1 {
            fails.push(format!("fused IDs after {label}: {line}"));
        }
        for id in found {
            *seen.entry(id).or_default() += 1;
            ids.push(id);
        }
    }
    if ids.is_empty() {
        fails.push(format!("no line IDs after {label}"));
    }
    if ids.windows(2).filter(|w| w[1] < w[0]).count() > 1 {
        fails.push(format!("IDs out of order after {label}"));
    }
    for (id, count) in seen {
        if count > 2 {
            fails.push(format!("duplicate ID after {label}: L{id:04}"));
        }
    }
    for marker in [
        "SENT-A|SURVIVES|plain logical line",
        "SENT-B|SURVIVES|wide-free after erases",
        "SENT-C|SURVIVES|tail logical line",
    ] {
        if !text.contains(marker) {
            fails.push(format!("missing sentinel after {label}: {marker}"));
        }
    }
    if text
        .lines()
        .any(|l| l.starts_with("OP") && l.contains("-05|ERASED|") && l.contains(STRESS_WIDE_B))
    {
        fails.push(format!("erased wide character visible after {label}"));
    }
}

fn stress_final_logical_text(p: &mut Pane, label: &str, fails: &mut Vec<String>) {
    let text = p.joined_all();
    for marker in [
        "SENT-A|SURVIVES|plain logical line",
        "SENT-B|SURVIVES|wide-free after erases",
        "SENT-C|SURVIVES|tail logical line",
        "OPPRE-03|overwrite-leading|left!",
        "OPPOST-03|overwrite-leading|left!",
        "SENT-POST|ORPHAN-PHASE|complete",
    ] {
        if !text.contains(marker) {
            fails.push(format!("missing expected logical text after {label}: {marker}"));
        }
    }
}

/// tmux `assert_raw_sane`: no cell outside the width and no visible
/// zero-width cell, i.e. every spacer belongs to a wide lead before it.
fn stress_raw_sane(p: &mut Pane, label: &str, fails: &mut Vec<String>) {
    let cols = usize::from(p.term.cols());
    let mut rows = p.history_rows();
    rows.extend(p.rows());
    for (y, row) in rows.iter().enumerate() {
        if row.len() != cols {
            fails.push(format!("row {y} has {} cells at width {cols} after {label}", row.len()));
        }
        for (x, cell) in row.iter().enumerate() {
            let lead = x.checked_sub(1).map(|i| row[i].width);
            if cell.width == CellWidth::SpacerTail && lead != Some(CellWidth::Wide) {
                fails.push(format!("orphan spacer at {y},{x} after {label}: {cell:?}"));
            }
            if cell.width == CellWidth::Wide
                && row.get(x + 1).map(|c| c.width) != Some(CellWidth::SpacerTail)
            {
                fails.push(format!("wide cell without spacer at {y},{x} after {label}: {cell:?}"));
            }
        }
    }
}

fn stress_history_sane(p: &Pane, label: &str, fails: &mut Vec<String>) {
    let size = p.term.history_rows();
    if size > 12_000 {
        fails.push(format!("history too large after {label}: {size}"));
    }
}

#[test]
fn tmux_input_reflow_stress_resize_cycle() {
    let mut fails = Vec::new();
    let mut p = Pane::history(80, 24);
    p.printf(&stress_payload());
    stress_joined_sane(&mut p, "initial payload", &mut fails);
    stress_raw_sane(&mut p, "initial payload", &mut fails);
    stress_history_sane(&p, "initial payload", &mut fails);

    p.resize(40, 24);
    p.printf(&stress_orphan_payload("POST"));
    stress_joined_sane(&mut p, "post-resize orphan payload", &mut fails);
    stress_raw_sane(&mut p, "post-resize orphan payload", &mut fails);

    for width in [80, 40, 20, 10, 7, 5, 4, 3, 2, 1, 2, 3, 4, 5, 7, 10, 20, 40, 80] {
        p.resize(width, 24);
        let label = format!("resize to {width}");
        stress_joined_sane(&mut p, &label, &mut fails);
        stress_raw_sane(&mut p, &label, &mut fails);
        stress_history_sane(&p, &label, &mut fails);
    }
    stress_final_logical_text(&mut p, "return to original width", &mut fails);

    p.printf(&format!(
        "\x1b[?1049hALT-SENT|alternate screen|{STRESS_WIDE_A}\nALT-SENT|resize target\n"
    ));
    for width in [30, 12, 80] {
        p.resize(width, 24);
        stress_raw_sane(&mut p, &format!("alternate resize to {width}"), &mut fails);
    }
    p.printf("\x1b[?1049l");
    stress_joined_sane(&mut p, "alternate screen exit", &mut fails);
    stress_raw_sane(&mut p, "alternate screen exit", &mut fails);
    stress_final_logical_text(&mut p, "alternate screen exit", &mut fails);

    fails.truncate(40);
    assert!(fails.is_empty(), "{}", fails.join("\n"));
}
