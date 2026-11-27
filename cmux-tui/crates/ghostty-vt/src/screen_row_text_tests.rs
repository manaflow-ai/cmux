//! `screen_row_text` (Cmd-F's `terminal-find` and copy mode read every retained row with it)
//! looks each row up once, not each cell: a screen lookup walks the page list from the top of
//! the history, so a lookup per cell made a find over a long history cost rows x columns walks.
//!
//! The per-cell read it replaced (`screen_row_text_per_cell`) is the oracle: on random screens
//! (wide graphemes, combining marks, soft wraps, a resize that reflows) both read every row the
//! same, and past the last row both read `None`.

use std::time::Instant;

use super::*;

/// xorshift64*: a reproducible stream with no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

const PIECES: &[&str] =
    &["a", "Z", "0", " ", "  ", "橋", "界", "😀", "e\u{301}", "\t", "-", "\x1b[1m", "\x1b[0m"];

fn random_screen(rng: &mut Rng, cols: u16, rows: u16) -> Terminal {
    let mut term = Terminal::new(cols, rows, 8 << 20, Callbacks::default()).unwrap();
    let lines = 20 + rng.below(200);
    for _ in 0..lines {
        // Some lines run past the width (soft wraps), some are short, some empty.
        let len = rng.below(u64::from(cols) * 3);
        let mut line = String::new();
        for _ in 0..len {
            line.push_str(PIECES[rng.below(PIECES.len() as u64) as usize]);
        }
        line.push_str("\r\n");
        term.vt_write(line.as_bytes());
    }
    term
}

fn total_rows(term: &Terminal) -> u64 {
    term.scrollback_rows() as u64 + u64::from(term.rows())
}

fn assert_same_as_oracle(term: &Terminal, case: &str) {
    let total = total_rows(term);
    for row in 0..total + 2 {
        assert_eq!(
            term.screen_row_text(row),
            term.screen_row_text_per_cell(row),
            "{case}: row {row} of {total}"
        );
    }
}

#[test]
fn a_row_reads_the_same_as_the_per_cell_read_on_random_screens() {
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    for case in 0..60 {
        let cols = 1 + rng.below(90) as u16;
        let rows = 1 + rng.below(30) as u16;
        let mut term = random_screen(&mut rng, cols, rows);
        assert_same_as_oracle(&term, &format!("case {case} at {cols}x{rows}"));
        // A resize reflows the history: rows on pages of another width, rewrapped lines.
        let (new_cols, new_rows) = (1 + rng.below(120) as u16, 1 + rng.below(30) as u16);
        term.resize(new_cols, new_rows, 8, 16).unwrap();
        assert_same_as_oracle(&term, &format!("case {case} resized to {new_cols}x{new_rows}"));
    }
}

#[test]
fn a_row_is_looked_up_once_not_once_per_cell() {
    const COLS: u16 = 160;
    let mut term = Terminal::new(COLS, 40, 64 << 20, Callbacks::default()).unwrap();
    for index in 0..5_000 {
        term.vt_write(
            format!("line {index:06} the quick brown fox jumps over the lazy dog\r\n").as_bytes(),
        );
    }
    let total = total_rows(&term);
    assert!(total > 4_000, "retained {total} rows");
    GRID_LOOKUPS.with(|lookups| lookups.set(0));
    for row in 0..total {
        assert!(term.screen_row_text(row).is_some());
    }
    let lookups = GRID_LOOKUPS.with(std::cell::Cell::get);
    assert!(lookups <= 2 * total, "{lookups} grid lookups for {total} rows of {COLS} columns");
}

/// Before -> after in one harness: the rows of a Cmd-F page (the newest 8 192, the daemon's
/// `DEFAULT_PAGE_ROWS`) and of the whole history, read per cell and per row, at 10k and 100k
/// retained rows of a 200-column terminal (measured at 100k: page 5 798 ms -> 403 ms, whole
/// history 31.2 s -> 4.4 s; per-row cost 0.93x from 10k to 100k). Run:
/// `cargo test -p ghostty-vt --release --lib screen_row_text_bench -- --ignored --nocapture`
#[test]
#[ignore = "bench: run with --ignored --nocapture"]
fn screen_row_text_bench() {
    const COLS: u16 = 200;
    const PAGE: u64 = 8_192;
    let mut per_row_full = Vec::new();
    for history in [10_000u64, 100_000] {
        let mut term = Terminal::new(COLS, 50, 1 << 30, Callbacks::default()).unwrap();
        let mut chunk = String::new();
        for index in 0..history {
            chunk.push_str(&format!(
                "{index:07} cargo build: compiling crate-{} v0.{}.0 (/src/crates/x) warning: unused\r\n",
                index % 977,
                index % 31
            ));
            if chunk.len() > 1 << 20 {
                term.vt_write(chunk.as_bytes());
                chunk.clear();
            }
        }
        term.vt_write(chunk.as_bytes());
        let total = total_rows(&term);
        let time = |read: &dyn Fn(u64) -> Option<ScreenRowText>, rows: std::ops::Range<u64>| {
            let started = Instant::now();
            let mut cells = 0usize;
            for row in rows {
                cells += read(row).map_or(0, |row| row.cells.len());
            }
            assert!(cells > 0);
            started.elapsed().as_secs_f64() * 1_000.0
        };
        let old = |row| term.screen_row_text_per_cell(row);
        let new = |row| term.screen_row_text(row);
        let page = total.saturating_sub(PAGE)..total;
        let old_page = time(&old, page.clone());
        let new_page = time(&new, page);
        let old_full = time(&old, 0..total);
        let new_full = time(&new, 0..total);
        println!(
            "screen_row_text {total} rows x {COLS} cols: find page (newest {PAGE}) \
             {old_page:.1} ms -> {new_page:.1} ms; whole history {old_full:.1} ms -> {new_full:.1} ms"
        );
        per_row_full.push(new_full / total as f64);
        // Budget: a find page reads in under a second even at 100k rows (measured 403 ms; the
        // per-cell read took 5.8 s).
        assert!(new_page < 1_000.0, "find page took {new_page:.1} ms at {total} rows");
    }
    let ratio = per_row_full[1] / per_row_full[0];
    println!("per-row cost of a whole-history read, 100k vs 10k rows: {ratio:.2}x");
    // Flat at 10x: a row costs about the same however long the history is (measured 0.93x).
    assert!(ratio < 2.0, "per-row cost grew {ratio:.2}x from 10k to 100k rows");
}
