//! Cell parity for `terminal-full-screen-frames-v1`: a full-screen program reaches the phone as
//! lean frames, and the phone must end on the same screen as a phone fed the program's raw
//! PTY bytes, cell by cell.
//!
//! Two viewers watch one shell from its first byte: `bytes` declares nothing (the PTY stream,
//! drawn by a Ghostty terminal fed `vt-state` then every `output`), `frames` declares the shell
//! lines and full-screen frames (drawn as the iPhone draws them, `LinesPhone`). The duress is
//! the mobile bandwidth bench's (#51253): a pager over 20,000 lines streaming 20 lines/s with a
//! full redraw each, then 10 pans of 1 s with 22 wheel steps each (a full redraw per step),
//! the stream going on beneath; the lines carry wide characters, emoji, symbols, 256 and true
//! colours, backgrounds and every attribute; the pager hides the cursor while it paints and
//! parks it on its prompt. It then leaves the alternate screen back to the shell's lines and
//! scrollback, and the shell prints more.
//!
//! A third viewer, `control`, declares the shell lines alone (today's lean stream).
//!
//! At each quiet point (the streams idle for 300 ms) every row both the bytes and frames phones
//! retain of the active screen (scrollback included, aligned at the bottom) is compared cell by
//! cell: the grapheme, wide or narrow, foreground, background, attributes and underline style
//! (a blank's foreground and text attributes do not show and are not compared, as in
//! `cmux-terminal-projection/tests/parity.rs`), then the cursor cell, its visibility and which
//! screen is active. The target is 0 mismatches. The shell lines carry what scrolls past
//! between two frames as one screen's shift, so a burst of more than a screen of lines leaves
//! the lean phones less scrollback than the bytes phone; those rows are counted apart, and the
//! frames phone must equal the control phone on every row, scrollback included: the full-screen
//! frames lose nothing the shell lines keep.

use std::fmt::Write as _;
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_agent_cli_render::lean::LeanDecoder;
use ghostty_vt::{Callbacks, Cell, CellWidth, ColorSpec, Terminal as Vt, UnderlineStyle};
use serde_json::{Value, json};

use super::super::disconnect_client;
use super::{LinesPhone, SHELL_LINES, Viewer, declaring, shell_terminal};

const FILE_LINES: usize = 20_000;
const STREAM_EVERY: Duration = Duration::from_millis(50);
const PANS: usize = 10;
const WHEEL_SENDS: usize = 22;
const WHEEL_LINES: usize = 3;
const QUIET: Duration = Duration::from_millis(300);

fn decode(event: &Value, field: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(event[field].as_str().unwrap()).unwrap()
}

/// The phone fed the raw PTY stream.
struct BytesPhone {
    term: Option<Vt>,
}

impl BytesPhone {
    fn apply(&mut self, event: &Value) {
        match event["event"].as_str() {
            Some("vt-state") => {
                let cols = u16::try_from(event["cols"].as_u64().unwrap()).unwrap();
                let rows = u16::try_from(event["rows"].as_u64().unwrap()).unwrap();
                let mut term = Vt::new(cols, rows, 1 << 20, Callbacks::default()).unwrap();
                term.vt_write(&decode(event, "data"));
                self.term = Some(term);
            }
            Some("output") => {
                self.term.as_mut().expect("vt-state first").vt_write(&decode(event, "data"))
            }
            _ => {}
        }
    }
}

/// Every message each viewer has now, applied; whether there was any.
fn pump(viewers: &Viewers, phones: &mut Phones) -> bool {
    let mut any = false;
    while let Some(message) = viewers.bytes.outbound.try_pop() {
        any = true;
        phones.bytes.apply(&serde_json::from_str(&message).expect("outbound JSON"));
    }
    for (viewer, phone) in
        [(&viewers.frames, &mut phones.frames), (&viewers.control, &mut phones.control)]
    {
        while let Some(message) = viewer.outbound.try_pop() {
            any = true;
            let event: Value = serde_json::from_str(&message).expect("outbound JSON");
            if matches!(event["event"].as_str(), Some("agent-cli-lean" | "output")) {
                phone.apply(&event);
            }
        }
    }
    any
}

/// The three viewers of the one shell.
struct Viewers {
    bytes: Viewer,
    frames: Viewer,
    control: Viewer,
}

/// What each viewer's phone draws.
struct Phones {
    bytes: BytesPhone,
    frames: LinesPhone,
    control: LinesPhone,
}

/// Pumps until both streams have been quiet for `QUIET`.
fn settle(viewers: &Viewers, phones: &mut Phones) {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut quiet = Instant::now();
    while quiet.elapsed() < QUIET {
        assert!(Instant::now() < deadline, "the streams never went quiet");
        if pump(viewers, phones) {
            quiet = Instant::now();
        } else {
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct Key {
    text: String,
    wide: bool,
    fg: ColorSpec,
    bg: ColorSpec,
    attrs: u16,
    underline: Option<UnderlineStyle>,
}

impl Key {
    fn of(cell: &Cell) -> Key {
        let text = if cell.text.is_empty() { " ".to_owned() } else { cell.text.clone() };
        let blank = text == " ";
        let mut key = Key {
            text,
            wide: cell.width == CellWidth::Wide,
            fg: cell.fg,
            bg: cell.bg,
            attrs: cell.attrs(),
            underline: cell
                .underline
                .then(|| cell.underline_style.unwrap_or(UnderlineStyle::Single)),
        };
        if blank {
            if key.attrs & ghostty_vt::ATTR_INVERSE == 0 {
                key.fg = ColorSpec::Default;
            }
            key.attrs &= ghostty_vt::ATTR_INVERSE | ghostty_vt::ATTR_STRIKETHROUGH;
            key.underline = None;
        }
        key
    }
}

struct Snapshot {
    rows: Vec<Vec<Cell>>,
    cursor: (usize, usize),
    cursor_visible: bool,
    alternate: bool,
}

fn snapshot(term: &Vt) -> Snapshot {
    let total = (term.scrollback_rows() + usize::from(term.rows())) as u64;
    let rows: Vec<Vec<Cell>> =
        (0..total).map_while(|y| term.styled_screen_row(y).map(|(cells, _, _)| cells)).collect();
    let (x, y) = term.cursor_position().unwrap_or((0, 0));
    let top = rows.len().saturating_sub(usize::from(term.rows()));
    Snapshot {
        rows,
        cursor: (top + usize::from(y), usize::from(x)),
        cursor_visible: term.mode(25, false),
        alternate: matches!(term.active_screen(), ghostty_vt::Screen::Alternate),
    }
}

#[derive(Default)]
struct Score {
    cells: usize,
    /// Cells that differ on rows both phones hold, and the cursor, its visibility and screen.
    mismatched: usize,
    notes: Vec<String>,
    /// Cells of rows only one phone holds (its scrollback reaches further back).
    one_sided: usize,
    one_sided_notes: Vec<String>,
}

impl Score {
    fn miss(&mut self, note: String) {
        self.mismatched += 1;
        if self.notes.len() < 24 {
            self.notes.push(note);
        }
    }

    fn compare(&mut self, at: &str, bytes: &Vt, frames: &Vt) {
        let (want, got) = (snapshot(bytes), snapshot(frames));
        // Rows aligned at the bottom: the active area is the last rows of each.
        let n = want.rows.len().max(got.rows.len());
        fn row(s: &Snapshot, i: usize, n: usize) -> Option<&[Cell]> {
            (i + s.rows.len()).checked_sub(n).and_then(|i| s.rows.get(i)).map(Vec::as_slice)
        }
        for i in 0..n {
            let (a, b) = match (row(&want, i, n), row(&got, i, n)) {
                (Some(a), Some(b)) => (a, b),
                (a, b) => {
                    self.one_sided += a.or(b).map_or(0, <[Cell]>::len);
                    if self.one_sided_notes.len() < 4 {
                        self.one_sided_notes.push(format!(
                            "{at}: row {} only in {}",
                            i as isize - n as isize,
                            if a.is_some() { "the first" } else { "the second" }
                        ));
                    }
                    continue;
                }
            };
            for c in 0..a.len().max(b.len()) {
                self.cells += 1;
                let (ka, kb) = (a.get(c).map(Key::of), b.get(c).map(Key::of));
                if ka != kb {
                    self.miss(format!(
                        "{at}: row {} col {c}: bytes {ka:?} / frames {kb:?}",
                        i as isize - n as isize
                    ));
                }
            }
        }
        let bottom = |s: &Snapshot| (s.rows.len() - s.cursor.0, s.cursor.1);
        if bottom(&want) != bottom(&got) {
            self.miss(format!(
                "{at}: cursor bytes {:?} / frames {:?}",
                bottom(&want),
                bottom(&got)
            ));
        }
        if want.cursor_visible != got.cursor_visible {
            self.miss(format!(
                "{at}: cursor visible bytes {} / frames {}",
                want.cursor_visible, got.cursor_visible
            ));
        }
        if want.alternate != got.alternate {
            self.miss(format!(
                "{at}: alternate bytes {} / frames {}",
                want.alternate, got.alternate
            ));
        }
    }
}

/// Line `i` of the pager's file: wide characters, emoji, symbols, colours and attributes.
fn file_line(i: usize) -> String {
    const WORDS: [&str; 8] = ["漢字", "かな", "🚀", "✅", "👍🏽", "→ ✓ ★", "─│┌┐", "⚠ λ ∑"];
    const SGR: [&str; 12] = [
        "1",
        "2",
        "3",
        "4",
        "4:3",
        "5",
        "7",
        "9",
        "38;5;174",
        "38;2;255;128;0",
        "48;5;22",
        "1;3;48;2;20;40;60",
    ];
    let mut line = format!("\x1b[38;5;{}m{i:05}\x1b[0m ", 16 + i % 216);
    for k in 0..4 {
        let word = WORDS[(i + k * 3) % WORDS.len()];
        let sgr = SGR[(i * 7 + k) % SGR.len()];
        let _ =
            write!(line, "\x1b[{sgr}m{word}\x1b[0m {} ", ["pager", "line", "bytes", "phone"][k]);
    }
    line
}

/// One full redraw of the pager: `top` is the first line shown of `len`.
fn redraw(top: usize, len: usize, rows: usize) -> Vec<u8> {
    let mut out = String::from("\x1b[?25l\x1b[H");
    for i in top..top + rows - 1 {
        if i < len {
            out.push_str(&file_line(i));
        }
        out.push_str("\x1b[K\r\n");
    }
    let status = format!(":{top}/{len}");
    let _ = write!(out, "\x1b[7m{status}\x1b[0m\x1b[K\x1b[{rows};{}H\x1b[?25h", status.len() + 1);
    out.into_bytes()
}

#[test]
fn full_screen_frames_end_on_the_raw_bytes_screen_cell_by_cell() {
    let (mux, surface) = shell_terminal("full-screen-frames-parity");
    let viewers = Viewers {
        bytes: declaring(&mux, &[]),
        frames: declaring(&mux, &[SHELL_LINES, &["terminal-full-screen-frames-v1"][..]].concat()),
        control: declaring(&mux, SHELL_LINES),
    };
    for viewer in [&viewers.bytes, &viewers.frames, &viewers.control] {
        viewer.attach(&mux, &surface, json!({}));
    }
    let lines = || LinesPhone { decoder: LeanDecoder::new(), phone: None };
    let mut phones = Phones { bytes: BytesPhone { term: None }, frames: lines(), control: lines() };
    // `score`: the frames phone against the raw bytes phone. `control`: against the phone of
    // the shell lines alone (no full-screen frames), every row: what the cut must not change.
    let mut score = Score::default();
    let mut control = Score::default();
    let mut checkpoints = 0;
    let mut depths = String::new();
    let mut check = |at: &str, phones: &mut Phones, score: &mut Score, control: &mut Score| {
        settle(&viewers, phones);
        let want = phones.bytes.term.as_ref().expect("the bytes phone drew");
        let got = &phones.frames.phone.as_ref().expect("the frames phone drew").term;
        let lines = &phones.control.phone.as_ref().expect("the shell lines phone drew").term;
        score.compare(at, want, got);
        control.compare(at, lines, got);
        let depth = |t: &Vt| t.scrollback_rows() + usize::from(t.rows());
        let _ = write!(depths, " {at}={}/{}/{}", depth(want), depth(got), depth(lines));
        checkpoints += 1;
    };

    // The shell's lines, past a screen of them, so scrollback holds some.
    let mut prologue = Vec::new();
    for i in 0..60 {
        prologue.extend_from_slice(format!("$ make {i}\r\n{}\r\n", file_line(i)).as_bytes());
    }
    prologue.extend_from_slice(b"$ less +F build.log\r\n");
    surface.inject_output_for_test(&prologue);
    check("shell", &mut phones, &mut score, &mut control);
    let rows = usize::from(phones.bytes.term.as_ref().unwrap().rows());

    // The pager: the alternate screen, the mouse, the file's tail, streaming 20 lines/s.
    let mut len = FILE_LINES;
    let follow = |len: usize| len.saturating_sub(rows - 1);
    let mut start = b"\x1b[?1049h\x1b[?1000h\x1b[?1006h".to_vec();
    start.extend_from_slice(&redraw(follow(len), len, rows));
    surface.inject_output_for_test(&start);
    let begun = Instant::now();
    while begun.elapsed() < Duration::from_secs(1) {
        std::thread::sleep(STREAM_EVERY);
        len += 1;
        surface.inject_output_for_test(&redraw(follow(len), len, rows));
        pump(&viewers, &mut phones);
    }
    check("stream", &mut phones, &mut score, &mut control);

    // Ten pans of 1 s, 22 wheel steps each (up, then down), the stream going on beneath.
    let mut top = follow(len);
    for pan in 0..PANS {
        let begun = Instant::now();
        let (mut wheels, mut streams) = (0, 0);
        while begun.elapsed() < Duration::from_secs(1) {
            let at = begun.elapsed();
            if wheels < WHEEL_SENDS
                && at >= Duration::from_secs(1) * wheels as u32 / WHEEL_SENDS as u32
            {
                wheels += 1;
                top = if pan % 2 == 0 {
                    top.saturating_sub(WHEEL_LINES)
                } else {
                    (top + WHEEL_LINES).min(follow(len))
                };
                surface.inject_output_for_test(&redraw(top, len, rows));
            }
            if at >= STREAM_EVERY * (streams + 1) {
                streams += 1;
                len += 1;
                surface.inject_output_for_test(&redraw(top, len, rows));
            }
            pump(&viewers, &mut phones);
            std::thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(wheels, WHEEL_SENDS, "pan {pan}");
        check(&format!("pan {pan}"), &mut phones, &mut score, &mut control);
    }

    // It ends: back to the shell's screen and scrollback, and the shell goes on.
    surface.inject_output_for_test(b"\x1b[?1006l\x1b[?1000l\x1b[?1049l$ ");
    check("exit", &mut phones, &mut score, &mut control);
    let mut after = b"echo \xe6\xbc\xa2\xf0\x9f\x9a\x80 done\r\n".to_vec();
    for i in 0..30 {
        after.extend_from_slice(format!("{}\r\n", file_line(FILE_LINES + i)).as_bytes());
    }
    after.extend_from_slice(b"$ ");
    surface.inject_output_for_test(&after);
    check("after", &mut phones, &mut score, &mut control);

    println!(
        "FULL-SCREEN-FRAMES-PARITY mismatched={} cells={} checkpoints={checkpoints} \
         scrollback_only_in_one={} vs_shell_lines_mismatched={} vs_shell_lines_one_sided={}",
        score.mismatched, score.cells, score.one_sided, control.mismatched, control.one_sided
    );
    println!("FULL-SCREEN-FRAMES-PARITY rows bytes/frames/shell-lines:{depths}");
    for note in score.notes.iter().chain(&score.one_sided_notes) {
        println!("FULL-SCREEN-FRAMES-PARITY note {note}");
    }
    for note in control.notes.iter().chain(&control.one_sided_notes) {
        println!("FULL-SCREEN-FRAMES-PARITY vs-shell-lines {note}");
    }
    // Every cell both phones hold, the cursor, its visibility and the screen: the raw bytes'.
    assert_eq!(score.mismatched, 0, "cells that differ: {:#?}", score.notes);
    // And the full-screen frames change nothing the shell lines alone draw, scrollback included.
    assert_eq!(control.mismatched + control.one_sided, 0, "{:#?}", control.notes);
    for viewer in [&viewers.bytes, &viewers.frames, &viewers.control] {
        disconnect_client(&mux, viewer.client, false);
    }
}
