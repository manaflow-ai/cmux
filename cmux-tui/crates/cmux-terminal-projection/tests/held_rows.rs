//! Held rows on the alternate screen: a pan within what the app already
//! drew is painted by the phone (nothing sent), also for an app that asked
//! for the mouse; past it, it goes to the Mac as before.

use cmux_terminal_projection::held::HELD_ROW_CAP;
use cmux_terminal_projection::{DEFAULT_HISTORY_LIMIT, Projection, Segment};

const COLS: usize = 80;
const ROWS: usize = 24;

fn alt_app() -> Projection {
    let mut p = Projection::new(COLS, ROWS, DEFAULT_HISTORY_LIMIT);
    let _ = p.set_viewport(54, 38);
    let _ = p.feed(b"\x1b[?1049h\x1b[H\x1b[2J", true);
    p
}

/// `n` lines printed at the bottom of the screen, each scrolling it up.
fn lines(p: &mut Projection, from: usize, n: usize) {
    let mut bytes = Vec::new();
    for i in from..from + n {
        bytes.extend_from_slice(format!("line {i}\r\n").as_bytes());
    }
    let _ = p.feed(&bytes, true);
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// The painted characters, escape sequences dropped, a row per line.
fn visible(bytes: &[u8]) -> String {
    let s = text(bytes);
    let mut out = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\x1b' => match chars.next() {
                Some('[') => {
                    for c in chars.by_ref() {
                        if c.is_ascii_alphabetic() || c == '@' || c == '~' {
                            if c == 'H' {
                                out.push('\n');
                            }
                            break;
                        }
                    }
                }
                Some(']') => {
                    while let Some(c) = chars.next() {
                        if c == '\x07' || (c == '\x1b' && chars.next_if_eq(&'\\').is_some()) {
                            break;
                        }
                    }
                }
                _ => {}
            },
            '\r' | '\n' => out.push('\n'),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

#[test]
fn rows_that_scroll_off_the_alternate_screen_are_held_once() {
    let mut p = alt_app();
    lines(&mut p, 0, 100);
    // 100 lines and the cursor's row on 24: 77 scrolled off.
    assert_eq!(p.held().0, 77);
    // The app scrolls back down 3 (RI at the top): those rows are on its
    // screen again, not held twice.
    let _ = p.feed(b"\x1b[H\x1bM\x1bM\x1bM", true);
    assert_eq!(p.held().0, 74);
}

#[test]
fn a_pan_within_the_held_rows_is_painted_on_the_phone_and_sends_nothing() {
    let mut p = alt_app();
    lines(&mut p, 0, 100);
    let step = p.alt_pan(5.0);
    assert_eq!(step.forward_rows, 0.0, "nothing goes to the Mac");
    assert_eq!(p.alt_rows_back(), 5);
    let painted = text(&step.paint);
    // Live, the top row is line 77; five rows back it is line 72.
    assert!(painted.contains("line 72") && !painted.contains("line 99"), "{painted}");
    assert!(painted.ends_with("\x1b[?25l\x1b[?2026l"), "the cursor is hidden while back");
    // A fraction carries; a row's worth moves.
    assert_eq!(p.alt_pan(0.5), Default::default());
    assert_eq!(p.alt_pan(0.5).forward_rows, 0.0);
    assert_eq!(p.alt_rows_back(), 6);
    // Back down to live: the live screen, with its cursor.
    let live = p.alt_pan(-6.0);
    assert_eq!(live.forward_rows, 0.0);
    assert_eq!(p.alt_rows_back(), 0);
    let live = text(&live.paint);
    assert!(live.contains("line 99") && live.contains("\x1b[?25h"), "{live}");
}

#[test]
fn a_pan_past_the_held_rows_goes_to_the_app_from_where_the_reader_is() {
    let mut p = alt_app();
    lines(&mut p, 0, 30);
    let held = p.held().0;
    assert_eq!(held, 7);
    let step = p.alt_pan(10.0);
    assert_eq!(p.alt_rows_back(), held);
    // The 7 rows back and the 3 past them: the app scrolls to the reader.
    assert_eq!(step.forward_rows, 10.0);
    // Further while the app has not answered: only the new rows.
    assert_eq!(p.alt_pan(2.0).forward_rows, 2.0);
    // A pan past the live screen goes to the app as before.
    let _ = p.alt_return_live();
    assert_eq!(p.alt_pan(-3.0).forward_rows, -3.0);
}

#[test]
fn new_output_while_back_keeps_the_reader_on_the_same_rows() {
    let mut p = alt_app();
    lines(&mut p, 0, 60);
    let _ = p.alt_pan(4.0);
    let before = p.alt_pan(1.0).paint;
    assert_eq!(p.alt_rows_back(), 5);
    // Output that scrolls 3 more rows off: the reader is 3 more rows back,
    // on the same rows, and the app's bytes still reach the surface.
    let segments = p.feed(b"\r\nline 60\r\nline 61\r\nline 62", true);
    assert_eq!(p.alt_rows_back(), 8);
    let [Segment::Raw(live), Segment::Raw(app), Segment::Raw(shown)] = segments.as_slice() else {
        panic!("{segments:?}")
    };
    assert!(text(live).starts_with("\x1b[?2026h") && !text(live).contains("\x1b[?2026l"));
    assert!(text(live).contains("line 59"), "the live screen, before the app's bytes");
    assert_eq!(app, b"\r\nline 60\r\nline 61\r\nline 62");
    assert_eq!(shown, &before, "the same rows, one synchronized update");
    // A pan down to the bottom rejoins live, and the next bytes go as they come.
    let rejoin = p.alt_pan(-8.0);
    assert_eq!(rejoin.forward_rows, 0.0);
    assert!(text(&rejoin.paint).contains("line 62"));
    assert_eq!(p.alt_rows_back(), 0);
    assert_eq!(p.feed(b"x", true), vec![Segment::Raw(b"x".to_vec())]);
}

#[test]
fn the_apps_answer_to_a_pan_past_the_held_rows_shows_live() {
    let mut p = alt_app();
    lines(&mut p, 0, 30);
    let held = p.held().0;
    assert!(p.alt_pan((held + 3) as f64).forward_rows > 0.0);
    let segments = p.feed(b"older", true);
    assert!(matches!(segments.first(), Some(Segment::Raw(b)) if text(b).contains("line 29")));
    assert_eq!(p.alt_rows_back(), 0);
}

#[test]
fn a_key_or_tap_returns_to_the_live_screen() {
    let mut p = alt_app();
    lines(&mut p, 0, 60);
    assert!(p.alt_return_live().is_empty(), "already live: nothing to paint");
    let _ = p.alt_pan(4.0);
    let live = p.alt_return_live();
    assert!(text(&live).contains("line 59"));
    assert_eq!(p.alt_rows_back(), 0);
}

#[test]
fn an_app_that_asked_for_the_mouse_pans_held_rows_locally_and_gets_the_wheel_past_them() {
    let mut p = alt_app();
    let _ = p.feed(b"\x1b[?1000h\x1b[?1006h", true);
    lines(&mut p, 0, 60);
    let held = p.held().0;
    let step = p.alt_pan(5.0);
    assert!(!step.paint.is_empty());
    assert_eq!(step.forward_rows, 0.0);
    assert_eq!(p.alt_rows_back(), 5);
    let past = p.alt_pan((held + 3) as f64);
    assert!(past.forward_rows > 0.0);
    assert_eq!(p.alt_rows_back(), held);
}

#[test]
fn the_primary_screen_and_an_app_with_nothing_held_are_unchanged() {
    let mut p = Projection::new(COLS, ROWS, DEFAULT_HISTORY_LIMIT);
    let _ = p.set_viewport(54, 38);
    let _ = p.feed(b"$ ls\r\n", true);
    assert_eq!(p.alt_pan(2.5).forward_rows, 2.5);
    let mut p = alt_app();
    let _ = p.feed(b"\x1b[5;1Hno scrolling", true);
    let step = p.alt_pan(2.5);
    assert!(step.paint.is_empty());
    assert_eq!(step.forward_rows, 2.5);
}

#[test]
fn a_header_and_status_line_outside_the_scroll_region_stay_put() {
    let mut p = alt_app();
    let _ = p.feed(b"\x1b[1;1HHEADER\x1b[24;1HSTATUS\x1b[2;23r\x1b[23;1H", true);
    lines(&mut p, 0, 50);
    // Every line feed at the bottom margin scrolls: the region's 21 blank
    // rows above the cursor, then lines 0..=28, leave its top.
    assert_eq!(p.held().0, 50);
    let painted = text(&p.alt_pan(10.0).paint);
    assert!(painted.contains("HEADER") && painted.contains("STATUS"), "{painted}");
    // The region's 22 rows, 10 back from live (live top: line 29).
    assert!(painted.contains("line 19") && !painted.contains("line 18"), "{painted}");
}

#[test]
fn an_app_that_repaints_pages_without_scrolling_holds_whole_screens() {
    let mut p = alt_app();
    for page in 0..3 {
        let mut bytes = b"\x1b[H\x1b[2J".to_vec();
        for row in 0..ROWS {
            bytes.extend_from_slice(format!("\x1b[{};1Hpage {page} row {row}", row + 1).as_bytes());
        }
        let _ = p.feed(&bytes, true);
    }
    // Pages 0 and 1 were cleared away: two screens held.
    assert_eq!(p.held().0, 2 * ROWS);
    let painted = text(&p.alt_pan(ROWS as f64).paint);
    assert!(painted.contains("page 1 row 0") && !painted.contains("page 2"), "{painted}");
    // A spinner redrawing one row of the page with a clear holds no more.
    let mut p = alt_app();
    for tick in 0..20 {
        let _ = p.feed(format!("\x1b[H\x1b[2Jtitle\r\nbody\r\nspinner {tick}").as_bytes(), true);
    }
    assert_eq!(p.held().0, ROWS);
}

#[test]
fn a_10k_row_session_holds_at_most_the_cap() {
    let mut p = Projection::new(200, 50, DEFAULT_HISTORY_LIMIT);
    let _ = p.set_viewport(54, 38);
    let _ = p.feed(b"\x1b[?1049h", true);
    let mut bytes = Vec::new();
    for i in 0..10_000 {
        // Full 200-column rows: the worst case for the store's bytes.
        bytes.extend_from_slice(format!("{i:0>200}\r\n").as_bytes());
    }
    let _ = p.feed(&bytes, true);
    let (rows, held_bytes) = p.held();
    assert_eq!(rows, HELD_ROW_CAP);
    // 3,000 rows of 200 eight-byte cells, and the deque.
    eprintln!("held: {rows} rows, {held_bytes} bytes for a 10k-row session at 200 columns");
    assert!(held_bytes <= HELD_ROW_CAP * (200 * 8 + 64) + 4096 * 32, "{held_bytes}");
    // The oldest held row is row 10_000 - 49 - 3_000.
    let painted = text(&p.alt_pan(HELD_ROW_CAP as f64).paint);
    assert!(
        painted.contains(&format!("{:0>200}", 10_000 - 49 - HELD_ROW_CAP)),
        "oldest held row first"
    );
    assert_eq!(p.alt_pan(1.0).forward_rows, (HELD_ROW_CAP + 1) as f64);
}

#[test]
fn leaving_the_alternate_screen_drops_what_it_held() {
    let mut p = alt_app();
    lines(&mut p, 0, 60);
    let _ = p.alt_pan(3.0);
    let _ = p.feed(b"\x1b[?1049l", true);
    assert_eq!(p.held().0, 0);
    assert_eq!(p.alt_rows_back(), 0);
}

/// The phone's cost of a pan step within held rows (the decision and the
/// paint bytes), p50/p95 over 2,000 steps on a 200x50 screen.
#[test]
fn a_pan_step_paints_in_well_under_a_frame() {
    let mut p = Projection::new(200, 50, DEFAULT_HISTORY_LIMIT);
    let _ = p.set_viewport(54, 38);
    let _ = p.feed(b"\x1b[?1049h", true);
    let mut bytes = Vec::new();
    for i in 0..5_000 {
        bytes.extend_from_slice(
            format!("\x1b[3{}m{i:0>120} wide 漢字\x1b[0m\r\n", i % 8).as_bytes(),
        );
    }
    let _ = p.feed(&bytes, true);
    let mut times = Vec::new();
    for i in 0..2_000 {
        let dir = if (i / 500) % 2 == 0 { 1.0 } else { -1.0 };
        let start = std::time::Instant::now();
        let step = p.alt_pan(dir);
        times.push(start.elapsed());
        assert_eq!(step.forward_rows, 0.0);
    }
    times.sort();
    let p50 = times[times.len() / 2];
    let p95 = times[times.len() * 95 / 100];
    eprintln!("pan step (decision + paint bytes): p50 {p50:?} p95 {p95:?}");
    assert!(p95 < std::time::Duration::from_millis(8), "{p95:?}");
}

/// Draws a screen the way a full-screen app that never scrolls does: a
/// header on row 1, transcript lines `from..` in rows 2..=21, an input box
/// and a status line on rows 23 and 24, each row by a cursor move.
fn repaint(p: &mut Projection, from: usize) {
    let mut bytes = b"\x1b[1;1H header\x1b[K".to_vec();
    for row in 0..20 {
        bytes
            .extend_from_slice(format!("\x1b[{};1Hentry {}\x1b[K", row + 2, from + row).as_bytes());
    }
    bytes.extend_from_slice(b"\x1b[23;1H> input\x1b[K\x1b[24;1Hstatus\x1b[K");
    let _ = p.feed(&bytes, true);
}

#[test]
fn a_repaint_split_across_two_batches_holds_the_rows_that_left_once() {
    let mut p = alt_app();
    repaint(&mut p, 0);
    // The first batch draws the header and the top half 5 rows higher.
    let mut first = b"\x1b[1;1H header\x1b[K".to_vec();
    for row in 0..10 {
        first.extend_from_slice(format!("\x1b[{};1Hentry {}\x1b[K", row + 2, 5 + row).as_bytes());
    }
    let _ = p.feed(&first, true);
    assert_eq!(p.held().0, 5);
    repaint(&mut p, 5);
    assert_eq!(p.held().0, 5);
}

#[test]
fn an_app_that_repaints_its_transcript_higher_holds_the_rows_that_left() {
    let mut p = alt_app();
    repaint(&mut p, 0);
    assert_eq!(p.held().0, 0);
    repaint(&mut p, 3);
    assert_eq!(p.held().0, 3);
    repaint(&mut p, 4);
    assert_eq!(p.held().0, 4);
    // The same screen again (a spinner tick elsewhere) holds nothing new.
    repaint(&mut p, 4);
    assert_eq!(p.held().0, 4);
    let step = p.alt_pan(2.0);
    assert_eq!(step.forward_rows, 0.0);
    let shown = text(&step.paint);
    assert!(shown.contains("entry 2") && shown.contains("entry 3"));
    assert!(!shown.contains("entry 22"));
}

/// Claude Code 2.1.330's full-screen mode, as recorded (120x40): it never
/// scrolls, it repaints its transcript higher, each frame between the cursor
/// hidden and shown again. Compared frame to frame, the rows that left its
/// transcript are held, in order, whatever the batches the bytes came in.
#[test]
fn claude_code_full_screen_repaints_are_held() {
    let bytes = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/parity/real/claude_code_session.vt"
    ))
    .expect("fixture");
    // Up to the app's exit (leaving the alternate screen drops what it held).
    let end = bytes.windows(8).rposition(|w| w == b"\x1b[?1049l").expect("exit");
    let mut held = Vec::new();
    for size in [256usize, 1024, 4096, end] {
        let mut p = Projection::new(120, 40, DEFAULT_HISTORY_LIMIT);
        let _ = p.set_viewport(54, 38);
        for chunk in bytes[..end].chunks(size) {
            let _ = p.feed(chunk, true);
        }
        held.push(p.held());
        if size == 1024 {
            let rows = p.held().0;
            let step = p.alt_pan(rows as f64);
            assert_eq!(step.forward_rows, 0.0);
            let shown = text(&step.paint);
            assert!(shown.contains("v2.1.330"), "{shown}");
            assert!(shown.contains("read main.py and explain the bug"));
            // The input box and status line stay where they are.
            assert!(shown.contains("auto mode on"));
            let mid = p.alt_pan(-((rows / 2) as f64));
            let mid = visible(&mid.paint);
            // The primes table: every entry between two rules, none lost or
            // doubled (an even move once put the rules out of step).
            let table: Vec<char> = mid
                .lines()
                .filter_map(|row| row.trim().chars().next())
                .filter(|c| matches!(c, '│' | '├'))
                .collect();
            assert!(table.len() > 10, "{mid}");
            assert!(table.windows(2).all(|w| w[0] != w[1]), "a rule lost or doubled: {mid}");
        }
    }
    eprintln!(
        "claude_code_session.vt held (rows, bytes) for 256, 1024, 4096 B and whole: {held:?}"
    );
    assert!(held[0].0 >= 60, "{held:?}");
    assert!(held.iter().all(|h| *h == held[0]), "{held:?}");
}

/// Leo reads back while Claude Code works, its spinner repainting several
/// times a second: the rows they read stay byte for byte where they are,
/// and a pan down to the bottom rejoins the live screen.
#[test]
fn claude_code_spinner_frames_leave_the_reader_where_they_are() {
    let bytes = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/parity/real/claude_code_session.vt"
    ))
    .expect("fixture");
    let end = bytes.windows(8).rposition(|w| w == b"\x1b[?1049l").expect("exit");
    let mut p = Projection::new(120, 40, DEFAULT_HISTORY_LIMIT);
    let _ = p.set_viewport(54, 38);
    let _ = p.feed(&bytes[..end], true);
    let held = p.held().0;
    let shown = p.alt_pan(held as f64).paint;
    let live = p.alt_live_paint();
    // The recording's own spinner frame, glyph and seconds counting.
    for n in 0..100 {
        let glyph = ["✶", "✻", "✽", "✢", "·", "✳"][n % 6];
        let frame = format!(
            "\x1b[?25l\x1b[H\r\x1b[34B\x1b[38;2;215;119;87m{glyph}\x1b[3GDeciphering…\x1b[37G\x1b[38;2;153;153;153m{}\x1b[39m\x1b[40;1H\x1b[38;3H\x1b[?25h",
            n + 3
        );
        let segments = p.feed(frame.as_bytes(), true);
        let Some(Segment::Raw(last)) = segments.last() else { panic!("{segments:?}") };
        assert_eq!(last, &shown, "frame {n}: the rows read moved");
        assert_eq!(p.alt_rows_back(), held);
    }
    assert_ne!(p.alt_live_paint(), live, "the live screen kept updating underneath");
    let rejoin = p.alt_pan(-(held as f64));
    assert_eq!(rejoin.forward_rows, 0.0);
    assert_eq!(rejoin.paint, p.alt_live_paint(), "live, with no jump");
}

/// A repaint matches only on rows with text: a line alone on a blank screen
/// moving up, or a screen of one repeated line with a row changed, holds
/// nothing.
#[test]
fn a_mostly_blank_or_repeated_line_screen_makes_no_false_shift() {
    let mut p = alt_app();
    let _ = p.feed(b"\x1b[10;1Hlonely line\x1b[K", true);
    let _ = p.feed(b"\x1b[10;1H\x1b[K\x1b[9;1Hlonely line\x1b[K", true);
    assert_eq!(p.held().0, 0);

    let mut p = alt_app();
    let mut rule = Vec::new();
    for row in 2..=21 {
        rule.extend_from_slice(format!("\x1b[{row};1H----------\x1b[K").as_bytes());
    }
    let _ = p.feed(&rule, true);
    let _ = p.feed(b"\x1b[12;1Hchanged\x1b[K", true);
    let _ = p.feed(b"\x1b[12;1H----------\x1b[K\x1b[2;1Hchanged\x1b[K", true);
    let _ = p.feed(&rule, true);
    assert_eq!(p.held().0, 0);
}

/// An app that asked for the mouse, with nothing held, gets every wheel
/// event whole, as before held rows.
#[test]
fn a_mouse_mode_app_with_nothing_held_gets_every_wheel_event() {
    let mut p = alt_app();
    let _ = p.feed(b"\x1b[?1000h\x1b[?1006h\x1b[5;1Hno scrolling", true);
    assert_eq!(p.held().0, 0);
    for rows in [0.4, 1.0, 2.5, -3.0, -0.25, 7.0] {
        let step = p.alt_pan(rows);
        assert!(step.paint.is_empty());
        assert_eq!(step.forward_rows, rows);
    }
    assert_eq!(p.alt_rows_back(), 0);
}
