//! A page of styled history (`styled_history_rows`, the daemon's
//! `read-scrollback`) finds each of its rows in the history once, not each
//! cell: a history lookup walks the page list from the top of the history,
//! so a lookup per cell made a page of a long history cost rows x columns
//! walks.

use super::*;
use crate::ColorSpec;

const COLS: u16 = 120;
const ROWS: u16 = 40;

fn line(index: usize) -> String {
    format!("line {index:06} the quick brown fox jumps over the lazy dog")
}

fn long_history(lines: usize) -> Terminal {
    let mut term = Terminal::new(COLS, ROWS, 64 << 20, Callbacks::default()).unwrap();
    for index in 0..lines {
        term.vt_write(format!("\x1b[1;3{}m{}\x1b[0m\r\n", index % 8, line(index)).as_bytes());
    }
    term
}

fn text(row: &[Cell]) -> String {
    row.iter().map(|cell| cell.text.as_str()).collect::<String>().trim_end().to_string()
}

#[test]
fn a_history_page_looks_up_each_row_not_each_cell() {
    let term = long_history(10_000);
    let total = term.history_rows();
    assert!(total >= 9_000, "retained {total} rows");
    let start = total - 3 * u32::from(ROWS);
    HISTORY_GRID_LOOKUPS.with(|lookups| lookups.set(0));
    let page = term.styled_history_rows(start, ROWS).unwrap();
    let lookups = HISTORY_GRID_LOOKUPS.with(std::cell::Cell::get);
    assert_eq!(page.len(), usize::from(ROWS));
    assert!(
        lookups <= 2 * u64::from(ROWS),
        "{lookups} history lookups for a page of {ROWS} rows of {COLS} columns"
    );
    // Every cell is the one at its column: the text, its style and its color.
    let first = text(&term.styled_history_rows(0, 1).unwrap()[0]);
    let first_index: usize = first["line ".len().."line ".len() + 6].parse().unwrap();
    for (offset, row) in page.iter().enumerate() {
        let index = first_index + start as usize + offset;
        assert_eq!(row.len(), usize::from(COLS));
        assert_eq!(text(row), line(index));
        assert!(row[0].bold && row[10].bold);
        assert_eq!(row[0].fg, ColorSpec::Palette((index % 8) as u8));
        assert!(!row[usize::from(COLS) - 1].bold, "the row's end is past the styled text");
    }
}

#[test]
fn a_page_past_the_end_and_an_empty_page_stay_empty() {
    let term = long_history(200);
    let total = term.history_rows();
    assert!(term.styled_history_rows(total, 10).unwrap().is_empty());
    assert!(term.styled_history_rows(0, 0).unwrap().is_empty());
    let tail = term.styled_history_rows(total - 3, 10).unwrap();
    assert_eq!(tail.len(), 3);
}

/// A small deterministic generator, so a failing oracle seed replays.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 =
            self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }

    fn pick<'a>(&mut self, items: &'a [&'a str]) -> &'a str {
        items[(self.next() as usize) % items.len()]
    }
}

/// Random styled output: SGR flags, palette and RGB colors, erase-to-end
/// with a background (cells with only a color), wide CJK and emoji,
/// combining-mark and ZWJ grapheme clusters, lines longer than the
/// terminal (soft wraps) and bare carriage returns.
fn random_styled(term: &mut Terminal, seed: u64, lines: usize) {
    const SGR: &[&str] = &[
        "\x1b[0m",
        "\x1b[1m",
        "\x1b[2m",
        "\x1b[3m",
        "\x1b[4m",
        "\x1b[4:3m",
        "\x1b[21m",
        "\x1b[5m",
        "\x1b[7m",
        "\x1b[8m",
        "\x1b[9m",
        "\x1b[31m",
        "\x1b[92m",
        "\x1b[38;5;201m",
        "\x1b[38;2;10;200;30m",
        "\x1b[44m",
        "\x1b[48;5;17m",
        "\x1b[48;2;250;1;99m",
        "\x1b[39;49m",
    ];
    const TEXT: &[&str] = &[
        "plain ",
        "cargo build ",
        "日本語",
        "中文字符",
        "😀",
        "👩‍💻",
        "e\u{301}",
        "a\u{308}\u{332}",
        "🇯🇵",
        "x",
        "  ",
        "tab\there",
        "│box│",
        "\u{200d}",
    ];
    let mut rng = Lcg(seed);
    let mut out = String::new();
    for _ in 0..lines {
        let pieces = 1 + rng.next() % 40;
        for _ in 0..pieces {
            match rng.next() % 10 {
                0..=3 => out.push_str(rng.pick(SGR)),
                4 => out.push_str("\x1b[K"),
                5 => out.push_str("a long run that wraps past the terminal's right edge "),
                _ => out.push_str(rng.pick(TEXT)),
            }
        }
        out.push_str(if rng.next() % 7 == 0 { "\r" } else { "\r\n" });
    }
    term.vt_write(out.as_bytes());
}

#[test]
fn the_batched_reader_matches_the_per_cell_read_on_random_styled_content() {
    for seed in 1..=6u64 {
        let mut term = Terminal::new(37, 11, 8 << 20, Callbacks::default()).unwrap();
        random_styled(&mut term, seed, 1_500);
        // A resize reflows the history: rows wrap anew and pages split.
        if seed % 2 == 0 {
            term.resize(23, 9, 0, 0).unwrap();
            random_styled(&mut term, seed.wrapping_mul(31), 300);
        }
        let total = term.history_rows();
        assert!(total > 200, "seed {seed}: retained {total} rows");
        let batched = term.styled_history_rows(0, u16::MAX).unwrap();
        let per_cell = term.styled_history_rows_per_cell(0, u16::MAX).unwrap();
        assert_eq!(batched.len(), per_cell.len(), "seed {seed}");
        for (y, (got, want)) in batched.iter().zip(&per_cell).enumerate() {
            assert_eq!(got, want, "seed {seed}: history row {y} differs");
        }
        let cells: Vec<&Cell> = batched.iter().flatten().collect();
        assert!(
            cells.iter().any(|cell| cell.width == CellWidth::Wide),
            "seed {seed}: no wide cell"
        );
        assert!(cells.iter().any(|cell| cell.text.chars().count() > 1), "seed {seed}: no grapheme");
        assert!(cells.iter().any(|cell| cell.bold), "seed {seed}: no styled cell");
        assert!(
            cells.iter().any(|cell| cell.text.is_empty() && cell.resolved_bg.is_some()),
            "seed {seed}: no background-only cell"
        );
    }
}

#[test]
fn a_history_page_fetches_each_page_style_once_not_each_cell() {
    let term = long_history(5_000);
    let total = term.history_rows();
    crate::render::GRID_STYLE_FETCHES.with(|fetches| fetches.set(0));
    let page = term.styled_history_rows(total - u32::from(ROWS), ROWS).unwrap();
    let fetches = crate::render::GRID_STYLE_FETCHES.with(std::cell::Cell::get);
    assert_eq!(page.len(), usize::from(ROWS));
    // Eight styles plus the default, on at most a few pages; a fetch per cell
    // would be ROWS x COLS (4800).
    assert!(fetches <= 3 * 9, "{fetches} style fetches for {ROWS} rows of {COLS} columns");
}

#[test]
fn history_row_runs_match_a_lookup_per_row() {
    for seed in 1..=4u64 {
        let mut term = Terminal::new(41, 7, 32 << 20, Callbacks::default()).unwrap();
        random_styled(&mut term, seed, 6_000);
        if seed % 2 == 0 {
            term.resize(29, 9, 0, 0).unwrap();
            random_styled(&mut term, seed.wrapping_add(99), 500);
        }
        let total = term.history_rows();
        let mut rng = Lcg(seed);
        let mut ranges = vec![(0, total), (total.saturating_sub(1), total), (0, 1)];
        for _ in 0..20 {
            let start = (rng.next() % u64::from(total)) as u32;
            let len = 1 + (rng.next() % 5_000) as u32;
            ranges.push((start, start.saturating_add(len).min(total)));
        }
        for (start, end) in ranges {
            let runs = term.history_row_runs(start, end).unwrap();
            let mut y = start;
            for run in &runs {
                assert_eq!(
                    run.start, y,
                    "seed {seed}: runs of {start}..{end} skip or repeat a row"
                );
                for offset in 0..run.len {
                    let want = term.history_grid_ref(0, y).unwrap();
                    assert_eq!(
                        (want.node, want.x, want.y),
                        (run.first.node, 0, run.first.y + offset),
                        "seed {seed}: row {y} of {start}..{end}"
                    );
                    y += 1;
                }
            }
            assert_eq!(y, end, "seed {seed}: runs of {start}..{end} stop at {y}");
        }
    }
}

#[test]
fn a_long_history_page_looks_up_each_page_not_each_row() {
    let term = long_history(30_000);
    let total = term.history_rows();
    let page = 8_192u16;
    HISTORY_GRID_LOOKUPS.with(|lookups| lookups.set(0));
    let rows = term.styled_history_rows(total - u32::from(page), page).unwrap();
    let lookups = HISTORY_GRID_LOOKUPS.with(std::cell::Cell::get);
    assert_eq!(rows.len(), usize::from(page));
    // Bisection finds each page boundary in about log2(8192) = 13 lookups
    // (measured 232 for this page); two lookups a row would be 16,384.
    assert!(lookups <= 1_024, "{lookups} history lookups for a page of {page} rows");
}

/// Before/after for one 8192-row page of styled history at 10k, 100k and 1M
/// retained rows of a 200-column terminal, in one harness. Before: two
/// history lookups (page-list walks from the top) a row, then the per-cell
/// read (five FFI calls and a style fetch a cell). After: the page's rows
/// found by bisection over page nodes, then the batched reader.
#[test]
#[ignore = "bench: run with --ignored --nocapture"]
fn styled_history_page_bench() {
    const COLS: u16 = 200;
    const PAGE: u16 = 8_192;
    for history in [10_000usize, 100_000, 1_000_000] {
        let mut term = Terminal::new(COLS, 50, 1 << 31, Callbacks::default()).unwrap();
        let mut chunk = String::new();
        for index in 0..history {
            chunk.push_str(&format!(
                "\x1b[1;3{}m{index:07}\x1b[0m cargo build: compiling crate-{} v0.{}.0 \
                 \x1b[33mwarning\x1b[0m: unused\r\n",
                index % 8,
                index % 977,
                index % 31
            ));
            if chunk.len() > 1 << 20 {
                term.vt_write(chunk.as_bytes());
                chunk.clear();
            }
        }
        term.vt_write(chunk.as_bytes());
        let total = term.history_rows();
        let start = total.saturating_sub(u32::from(PAGE));
        let ms = |started: std::time::Instant| started.elapsed().as_secs_f64() * 1e3;
        // The two row-end lookups alone: the page-list walk both paths share.
        let mut walk_ms = f64::MAX;
        let (mut old_ms, mut new_ms) = (f64::MAX, f64::MAX);
        for _ in 0..9 {
            let started = std::time::Instant::now();
            for y in start..total {
                assert!(term.history_grid_ref(0, y).is_ok());
                assert!(term.history_grid_ref(COLS - 1, y).is_ok());
            }
            walk_ms = walk_ms.min(ms(started));
            let started = std::time::Instant::now();
            let old = term.styled_history_rows_per_cell(start, PAGE).unwrap();
            old_ms = old_ms.min(ms(started));
            let started = std::time::Instant::now();
            let new = term.styled_history_rows(start, PAGE).unwrap();
            new_ms = new_ms.min(ms(started));
            assert_eq!(old, new, "the batched page differs at {total} rows");
        }
        println!(
            "styled_history_rows {total} rows x {COLS} cols, page of {PAGE} (min of 9): \
             {old_ms:.1} ms -> {new_ms:.1} ms ({:.2}x); row lookups alone {walk_ms:.1} ms",
            old_ms / new_ms
        );
    }
}
