//! Port of classic cmux's `PredictionOverlayLayoutTests.swift`.

use cmux_terminal_prediction::{PredictedGlyph, PredictionOverlayLayout, Standing};

fn glyphs(offsets: &[i32], standing: Standing) -> Vec<PredictedGlyph> {
    offsets.iter().map(|&offset| PredictedGlyph { character: b'x', offset, standing }).collect()
}

fn speculative(offsets: &[i32]) -> Vec<PredictedGlyph> {
    glyphs(offsets, Standing::Speculative)
}

fn offsets(layout: &PredictionOverlayLayout) -> Vec<i32> {
    layout.glyphs.iter().map(|glyph| glyph.offset).collect()
}

#[test]
fn a_run_from_the_cursor_ends_with_a_caret() {
    let layout = PredictionOverlayLayout::new(&speculative(&[0, 1, 2]), 5, 80).expect("a layout");

    assert_eq!(offsets(&layout), [0, 1, 2]);
    assert_eq!(layout.leading_offset, 0);
    assert_eq!(layout.caret_offset, Some(3));
    assert_eq!(layout.cell_count, 4);
}

#[test]
fn a_held_confirmation_extends_the_overlay_left_of_the_cursor() {
    let run = [
        PredictedGlyph { character: b'a', offset: -1, standing: Standing::Confirmed },
        PredictedGlyph { character: b'b', offset: 0, standing: Standing::Speculative },
    ];
    let layout = PredictionOverlayLayout::new(&run, 5, 80).expect("a layout");

    assert_eq!(layout.leading_offset, -1);
    assert_eq!(layout.caret_offset, Some(1));
    assert_eq!(layout.cell_count, 3);
}

#[test]
fn glyphs_after_an_undrawn_keystroke_keep_their_offset() {
    // A keystroke typed before the run armed holds offset 0 undrawn; the
    // next glyph belongs one cell further on, not on the cursor.
    let layout = PredictionOverlayLayout::new(&speculative(&[1]), 5, 80).expect("a layout");

    assert_eq!(offsets(&layout), [1]);
    assert_eq!(layout.leading_offset, 1);
    assert_eq!(layout.caret_offset, Some(2));
    assert_eq!(layout.cell_count, 2);
}

#[test]
fn nothing_is_drawn_past_the_right_margin() {
    // Columns 7, 8, 9 of a 10-column row fit; offset 3 would be column 10.
    let layout =
        PredictionOverlayLayout::new(&speculative(&[0, 1, 2, 3]), 7, 10).expect("a layout");

    assert_eq!(offsets(&layout), [0, 1, 2]);
    assert_eq!(layout.caret_offset, None);
    assert_eq!(layout.cell_count, 3);
}

#[test]
fn the_caret_is_dropped_when_it_would_land_past_the_margin() {
    let layout = PredictionOverlayLayout::new(&speculative(&[0]), 8, 10).expect("a layout");

    assert_eq!(offsets(&layout), [0]);
    assert_eq!(layout.caret_offset, Some(1));

    let full = PredictionOverlayLayout::new(&speculative(&[0, 1]), 8, 10).expect("a layout");
    assert_eq!(full.caret_offset, None);
    assert_eq!(full.cell_count, 2);
}

#[test]
fn no_caret_left_of_the_cursor_while_a_retracted_echo_awaits_its_erase() {
    // The remote has printed a retracted character and not yet erased
    // it, so the held glyph sits two cells left of the cursor. Typing
    // continues where the erase will leave the cursor, not one cell left
    // of the live one; with nothing speculative, draw no caret there.
    let held = glyphs(&[-2], Standing::Confirmed);
    let layout = PredictionOverlayLayout::new(&held, 5, 80).expect("a layout");

    assert_eq!(offsets(&layout), [-2]);
    assert_eq!(layout.caret_offset, None);
    assert_eq!(layout.cell_count, 1);

    // An ordinary held confirmation keeps its caret on the cursor.
    let ordinary =
        PredictionOverlayLayout::new(&glyphs(&[-1], Standing::Confirmed), 5, 80).expect("a layout");
    assert_eq!(ordinary.caret_offset, Some(0));
}

#[test]
fn a_cursor_on_the_last_column_draws_nothing() {
    // It may be waiting to wrap, which moves every offset by a cell.
    assert_eq!(PredictionOverlayLayout::new(&speculative(&[0]), 9, 10), None);
    assert_eq!(PredictionOverlayLayout::new(&glyphs(&[-1], Standing::Confirmed), 9, 10), None);
}

#[test]
fn confirmations_that_wrapped_off_the_row_are_not_drawn() {
    // The echo wrapped, so the cursor is on a new row and the oldest held
    // glyph belongs to the row above.
    let mut run = glyphs(&[-2, -1], Standing::Confirmed);
    run.extend(speculative(&[0]));
    let layout = PredictionOverlayLayout::new(&run, 1, 80).expect("a layout");

    assert_eq!(offsets(&layout), [-1, 0]);
    assert_eq!(layout.leading_offset, -1);
}

#[test]
fn nothing_to_draw_is_no_layout() {
    assert_eq!(PredictionOverlayLayout::new(&[], 0, 80), None);
    assert_eq!(PredictionOverlayLayout::new(&speculative(&[0]), 0, 0), None);
    assert_eq!(PredictionOverlayLayout::new(&speculative(&[0]), -1, 80), None);
}
