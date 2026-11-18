use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Style;

use super::{
    ReusableRowBuffer, copy_buffer_row_cropped, middle_truncate, sanitize_render_buffer, truncate,
};

#[test]
fn middle_truncates_for_narrow_columns() {
    assert_eq!(middle_truncate("abcdefghi", 7), "ab...hi");
    assert_eq!(middle_truncate("abcdefghi", 3), "...");
    assert_eq!(middle_truncate("abc", 3), "abc");
    assert_eq!(middle_truncate("abc", 0), "");
}

#[test]
fn middle_truncation_zero_width_input_respects_zero_budget() {
    assert_eq!(middle_truncate("\u{200b}", 0), "");
}

#[test]
fn middle_truncation_respects_graphemes_and_terminal_cells() {
    assert_eq!(middle_truncate("界界界界", 7), "界...界");
    assert_eq!(middle_truncate("e\u{301}clair", 5), "e\u{301}...r");
}

#[test]
#[allow(clippy::unicode_not_nfc)]
fn truncation_uses_terminal_cell_width_for_halfwidth_dakuten() {
    assert_eq!(middle_truncate("界ﾞ界ﾞ", 5), "...");
    assert_eq!(truncate("界ﾞ界ﾞ", 5), "界ﾞ…");
}

#[test]
fn truncation_uses_terminal_cell_width_and_preserves_graphemes() {
    assert_eq!(truncate("復元失敗", 5), "復元…");
    assert_eq!(truncate("e\u{301}clair", 2), "e\u{301}…");
    assert_eq!(truncate("復元", 1), "…");
    assert_eq!(truncate("復元", 0), "");
}

#[test]
fn truncation_bounds_pathological_zero_width_input() {
    let oversized_grapheme = format!("x{}", "\u{301}".repeat(10_000));
    assert_eq!(truncate(&oversized_grapheme, 20), "…");

    let invisible = "\u{200b}".repeat(10_000);
    assert_eq!(truncate(&invisible, 0), "");
    assert!(truncate(&invisible, 4).len() <= 4_096);
}

#[test]
fn render_buffer_rejects_control_bytes_from_every_ui_source() {
    let mut buffer = Buffer::empty(Rect::new(0, 0, 3, 1));
    buffer[(0, 0)].set_symbol("\u{1b}");
    buffer[(1, 0)].set_symbol("bad\ncell");
    buffer[(2, 0)].set_symbol("ok");

    sanitize_render_buffer(&mut buffer);

    assert_eq!(buffer[(0, 0)].symbol(), " ");
    assert_eq!(buffer[(1, 0)].symbol(), " ");
    assert_eq!(buffer[(2, 0)].symbol(), "ok");
}

#[test]
fn cropped_buffer_rows_blank_partial_wide_glyphs_at_both_edges() {
    let mut source = Buffer::empty(Rect::new(0, 0, 5, 1));
    source.set_string(0, 0, "a界b", Style::default());
    assert_eq!(source[(1, 0)].symbol(), "界");

    let draw_crop = |source_x| {
        let mut target = Buffer::empty(Rect::new(0, 0, 2, 1));
        copy_buffer_row_cropped(
            &source,
            0,
            source_x,
            &mut target,
            cmux_tui_core::Rect { x: 0, y: 0, width: 2, height: 1 },
        );
        target
    };

    let clipped_lead = draw_crop(0);
    assert_eq!(clipped_lead[(0, 0)].symbol(), "a");
    assert_eq!(clipped_lead[(1, 0)].symbol(), " ");

    let complete = draw_crop(1);
    assert_eq!(complete[(0, 0)].symbol(), "界");
    assert_eq!(complete[(1, 0)].symbol(), " ");

    let clipped_tail = draw_crop(2);
    assert_eq!(clipped_tail[(0, 0)].symbol(), " ");
    assert_eq!(clipped_tail[(1, 0)].symbol(), "b");
}

#[test]
fn reusable_row_buffer_keeps_its_allocation_for_smaller_rows() {
    let mut scratch = ReusableRowBuffer::default();
    let first = scratch.take(512);
    let pointer = first.content.as_ptr();
    let capacity = first.content.capacity();
    scratch.put(first);

    let second = scratch.take(256);
    assert_eq!(second.area.width, 256);
    assert_eq!(second.content.as_ptr(), pointer);
    assert_eq!(second.content.capacity(), capacity);
}
