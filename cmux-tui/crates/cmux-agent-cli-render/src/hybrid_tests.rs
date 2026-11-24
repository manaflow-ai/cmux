use super::*;
use crate::{BOLD, Line};

fn grid(rows: &[&[(&str, Style)]]) -> Grid {
    let mut grid = Grid::blank(20, 4);
    for (slot, parts) in grid.cells.iter_mut().zip(rows) {
        let mut line = Line::new();
        for (text, style) in *parts {
            line.push(text, *style);
        }
        *slot = line.into_row(20);
    }
    grid
}

#[test]
fn a_delta_turns_the_drawn_screen_into_the_real_one() {
    let drawn = grid(&[&[("> hi", Style::PLAIN)], &[("hello", Style::fg(174))]]);
    let real = grid(&[
        &[("> hi", Style::PLAIN)],
        &[("hello", Style::fg(174))],
        &[("Do you want", Style::PLAIN.with(BOLD))],
        &[("✻ Misting…", Style::fg(174))],
    ]);
    let mut overlay = Overlay::new(20, 4);
    let spans = overlay.diff(&drawn, &real);
    // Only the two rows the records lack. The space after the spinner draws the same pixels
    // as the drawn blank, so it splits that row's span in two.
    let at: Vec<(u16, u16)> = spans
        .iter()
        .map(|s| match s {
            Span::Set { row, col, .. } | Span::Clear { row, col, .. } => (*row, *col),
        })
        .collect();
    assert_eq!(at, [(2, 0), (3, 0), (3, 2)]);
    overlay.apply(&spans);
    assert_eq!(real.parity(&overlay.compose(&drawn)), (80, 80));
    assert!(overlay.diff(&drawn, &real).is_empty());
}

#[test]
fn an_override_goes_when_the_screen_moves_on_to_what_the_records_draw() {
    let drawn = grid(&[&[("> hi", Style::PLAIN)]]);
    let dialog = grid(&[&[("Allow? y/n", Style::PLAIN)]]);
    let mut overlay = Overlay::new(20, 4);
    overlay.apply(&overlay.diff(&drawn, &dialog));
    assert!(overlay.overrides() > 0);
    // The dialog closes and the screen is what the records draw again.
    let spans = overlay.diff(&drawn, &drawn);
    assert!(spans.iter().all(|s| matches!(s, Span::Clear { row: 0, .. })), "{spans:?}");
    overlay.apply(&spans);
    assert_eq!(drawn.parity(&overlay.compose(&drawn)), (80, 80));
}

#[test]
fn a_scrolled_screen_moves_the_overlay_instead_of_resending_it() {
    let drawn = Grid::blank(20, 4);
    let line = |text| (text, Style::fg(246));
    let before = grid(&[&[line("one")], &[line("two")], &[line("three")], &[line("four")]]);
    let after = grid(&[&[line("three")], &[line("four")], &[line("five")], &[line("six")]]);
    let mut overlay = Overlay::new(20, 4);
    overlay.apply_delta(&overlay.delta(&drawn, &before, 1, 0), &drawn);
    let delta = overlay.delta(&drawn, &after, 1, 10);
    // Two lines printed: a scroll of two and the two new rows, nothing else.
    assert_eq!(delta.shift, 2);
    assert!(delta.spans.iter().all(|s| matches!(s, Span::Set { row: 2 | 3, .. })), "{delta:?}");
    overlay.apply_delta(&delta, &drawn);
    assert_eq!(after.parity(&overlay.compose(&drawn)), (80, 80));
}

#[test]
fn a_delta_round_trips_through_its_bytes() {
    let delta = Delta {
        seq: 300,
        at_ms: 25_000,
        shift: -3,
        spans: vec![
            Span::Set {
                row: 3,
                col: 7,
                cells: ["✻", "a", "", "字", " "]
                    .into_iter()
                    .map(|text| Cell {
                        text: text.into(),
                        style: Style {
                            fg: Color::Rgb(1, 2, 3),
                            bg: Color::Palette(237),
                            attrs: BOLD,
                        },
                    })
                    .collect(),
            },
            Span::Clear { row: 31, col: 99, len: 1 },
        ],
    };
    let bytes = delta.encode();
    assert_eq!(Delta::decode(&bytes), Some(delta));
    assert_eq!(Delta::decode(&bytes[..bytes.len() - 1]), None);
}

/// A varint past 64 bits is not a delta: its high bits are not dropped to read a smaller
/// value (#44052 F2).
#[test]
fn a_varint_past_64_bits_is_not_a_delta() {
    // seq, then at_ms 0, shift 0 and no spans.
    let with_seq = |seq: &[u8]| [seq, &[0, 0, 0]].concat();
    let max = [[0xff; 9].as_slice(), &[0x01]].concat();
    assert_eq!(Delta::decode(&with_seq(&max)).map(|delta| delta.seq), Some(u64::MAX));
    // Bit 64 set: the shift used to drop it and read seq 0.
    let bit_64 = [[0x80; 9].as_slice(), &[0x02]].concat();
    assert_eq!(Delta::decode(&with_seq(&bit_64)), None);
    // An eleventh byte.
    let eleven = [[0x80; 10].as_slice(), &[0x00]].concat();
    assert_eq!(Delta::decode(&with_seq(&eleven)), None);
}
