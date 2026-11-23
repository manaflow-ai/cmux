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
//! At each quiet point (both streams idle for 300 ms) every retained row of the active screen
//! (scrollback included) is compared cell by cell: the grapheme, wide or narrow, foreground,
//! background, attributes and underline style (a blank's foreground and text attributes do not
//! show and are not compared, as in `cmux-terminal-projection/tests/parity.rs`), then the
//! cursor cell, its visibility and which screen is active. The target is 0 mismatches.

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
fn pump(
    bytes: &Viewer,
    bytes_phone: &mut BytesPhone,
    frames: &Viewer,
    phone: &mut LinesPhone,
) -> bool {
    let mut any = false;
    while let Some(message) = bytes.outbound.try_pop() {
        any = true;
        bytes_phone.apply(&serde_json::from_str(&message).expect("outbound JSON"));
    }
    while let Some(message) = frames.outbound.try_pop() {
        any = true;
        let event: Value = serde_json::from_str(&message).expect("outbound JSON");
        if matches!(event["event"].as_str(), Some("agent-cli-lean" | "output")) {
            phone.apply(&event);
        }
    }
    any
}

/// Pumps until both streams have been quiet for `QUIET`.
fn settle(bytes: &Viewer, bytes_phone: &mut BytesPhone, frames: &Viewer, phone: &mut LinesPhone) {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut quiet = Instant::now();
    while quiet.elapsed() < QUIET {
        assert!(Instant::now() < deadline, "the streams never went quiet");
        if pump(bytes, bytes_phone, frames, phone) {
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
    mismatched: usize,
    notes: Vec<String>,
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
        let row = |s: &Snapshot, i: usize| {
            (i + s.rows.len()).checked_sub(n).and_then(|i| s.rows.get(i)).map(Vec::as_slice)
        };
        for i in 0..n {
            let (a, b) = (row(&want, i).unwrap_or(&[]), row(&got, i).unwrap_or(&[]));
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
    let bytes = declaring(&mux, &[]);
    let frames = declaring(&mux, &[SHELL_LINES, &["terminal-full-screen-frames-v1"][..]].concat());
    bytes.attach(&mux, &surface, json!({}));
    frames.attach(&mux, &surface, json!({}));
    let mut bytes_phone = BytesPhone { term: None };
    let mut phone = LinesPhone { decoder: LeanDecoder::new(), phone: None };
    let mut score = Score::default();
    let mut checkpoints = 0;
    let mut check =
        |at: &str, bytes_phone: &mut BytesPhone, phone: &mut LinesPhone, score: &mut Score| {
            settle(&bytes, bytes_phone, &frames, phone);
            let want = bytes_phone.term.as_ref().expect("the bytes phone drew");
            let got = &phone.phone.as_ref().expect("the frames phone drew").term;
            score.compare(at, want, got);
            checkpoints += 1;
        };

    // The shell's lines, past a screen of them, so scrollback holds some.
    let mut prologue = Vec::new();
    for i in 0..60 {
        prologue.extend_from_slice(format!("$ make {i}\r\n{}\r\n", file_line(i)).as_bytes());
    }
    prologue.extend_from_slice(b"$ less +F build.log\r\n");
    surface.inject_output_for_test(&prologue);
    check("shell", &mut bytes_phone, &mut phone, &mut score);
    let rows = usize::from(bytes_phone.term.as_ref().unwrap().rows());

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
        pump(&bytes, &mut bytes_phone, &frames, &mut phone);
    }
    check("stream", &mut bytes_phone, &mut phone, &mut score);

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
            pump(&bytes, &mut bytes_phone, &frames, &mut phone);
            std::thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(wheels, WHEEL_SENDS, "pan {pan}");
        check(&format!("pan {pan}"), &mut bytes_phone, &mut phone, &mut score);
    }

    // It ends: back to the shell's screen and scrollback, and the shell goes on.
    surface.inject_output_for_test(b"\x1b[?1006l\x1b[?1000l\x1b[?1049l$ ");
    check("exit", &mut bytes_phone, &mut phone, &mut score);
    let mut after = b"echo \xe6\xbc\xa2\xf0\x9f\x9a\x80 done\r\n".to_vec();
    for i in 0..30 {
        after.extend_from_slice(format!("{}\r\n", file_line(FILE_LINES + i)).as_bytes());
    }
    after.extend_from_slice(b"$ ");
    surface.inject_output_for_test(&after);
    check("after", &mut bytes_phone, &mut phone, &mut score);

    println!(
        "FULL-SCREEN-FRAMES-PARITY mismatched={} cells={} checkpoints={checkpoints}",
        score.mismatched, score.cells
    );
    for note in &score.notes {
        println!("FULL-SCREEN-FRAMES-PARITY note {note}");
    }
    assert_eq!(score.mismatched, 0, "cells that differ: {:#?}", score.notes);
    disconnect_client(&mux, bytes.client, false);
    disconnect_client(&mux, frames.client, false);
}
