//! Held rows on the alternate screen: a pan within what the app already
//! drew is painted by the phone (nothing sent); past it, or for an app that
//! asked for the mouse, it goes to the Mac as before.

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
fn new_output_returns_the_surface_to_the_live_screen_first() {
    let mut p = alt_app();
    lines(&mut p, 0, 60);
    let _ = p.alt_pan(4.0);
    let segments = p.feed(b"new", true);
    let Some(Segment::Raw(first)) = segments.first() else { panic!("{segments:?}") };
    assert!(text(first).contains("line 59"), "the live screen, before the app's bytes");
    assert!(matches!(segments.get(1), Some(Segment::Raw(b)) if b == b"new"));
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
fn an_app_that_asked_for_the_mouse_gets_the_wheel_as_before() {
    let mut p = alt_app();
    lines(&mut p, 0, 60);
    let _ = p.feed(b"\x1b[?1000h\x1b[?1006h", true);
    let step = p.alt_pan(5.0);
    assert!(step.paint.is_empty());
    assert_eq!(step.forward_rows, 5.0);
    assert_eq!(p.alt_rows_back(), 0);
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
