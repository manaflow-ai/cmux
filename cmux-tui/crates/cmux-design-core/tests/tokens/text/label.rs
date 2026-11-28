//! `LabelText.swift` and `ChromeLabel.swift`.

use cmux_design_core::ops::call;
use cmux_design_core::tokens::text::label::*;
use serde_json::json;

fn font(ascender: f64, descender: f64, leading: f64) -> FontLine {
    FontLine { ascender, descender, leading }
}

fn wrapping(lines: i64) -> Shape {
    Shape { lines, wraps: true, line_break: LineBreak::WordWrapping, ..Shape::default() }
}

#[test]
fn constants() {
    assert_eq!(PADDING, 2.0);
    assert_eq!(MEASURED_CACHE_LIMIT, 8);
    assert_eq!(UNBOUNDED_WIDTH_KEY, -1.0);
    assert_eq!(UNBOUNDED, f64::MAX);
    assert_eq!(alignment_rect_insets(), (0.0, 2.0, 0.0, 2.0));
    assert!(!measured_cache_evicts(7));
    assert!(measured_cache_evicts(8));
    assert_eq!(measured_key(None), -1.0);
    assert_eq!(measured_key(Some(120.0)), 120.0);
    assert!(mouse_down_can_move_window(false));
    assert!(!mouse_down_can_move_window(true));
}

#[test]
fn whole_point_line_pins() {
    // 13 pt SF: ascender 12.38, descender -3.15, leading 0 -> 12 + 4 + 0.
    assert_eq!(whole_point_line(&[font(12.38, -3.15, 0.0)]), Some((12.0, 16.0)));
    // Each part takes the widest font.
    assert_eq!(
        whole_point_line(&[font(12.5, -2.1, 0.2), font(11.0, -3.5, 0.0)]),
        Some((13.0, 13.0 + 4.0 + 1.0))
    );
    assert_eq!(whole_point_line(&[]), None);
    assert_eq!(whole_point_line(&[font(0.4, -3.0, 0.0)]), None);
}

/// EmptyLabelMeasureTests: an empty label at no set width takes the font's line, no layout.
#[test]
fn empty_label_measure() {
    let fonts = [font(12.38, -3.15, 0.0)];
    let m = empty_line_metrics(true, None, &fonts, 2.0).unwrap();
    assert_eq!(m.size, Size { width: 0.0, height: 16.0 });
    assert_eq!((m.first_baseline, m.last_baseline_from_bottom), (12.0, 4.0));
    // Text, or an empty text at a set width, lays out.
    assert_eq!(empty_line_metrics(false, None, &fonts, 2.0), None);
    assert_eq!(empty_line_metrics(true, Some(80.0), &fonts, 2.0), None);
}

#[test]
fn paragraph_rules() {
    let mut shape = wrapping(0);
    assert_eq!(paragraph_line_break(&shape), LineBreak::WordWrapping);
    shape.line_break = LineBreak::CharWrapping;
    assert_eq!(paragraph_line_break(&shape), LineBreak::CharWrapping);
    shape.line_break = LineBreak::TruncatingTail;
    assert_eq!(paragraph_line_break(&shape), LineBreak::WordWrapping);
    let single = Shape { line_break: LineBreak::TruncatingMiddle, ..Shape::default() };
    assert_eq!(paragraph_line_break(&single), LineBreak::TruncatingMiddle);
    assert_eq!(paragraph_alignment(Some(Alignment::Center), &Shape::default()), Alignment::Center);
    let right = Shape { alignment: Alignment::Right, ..Shape::default() };
    assert_eq!(paragraph_alignment(Some(Alignment::Center), &right), Alignment::Right);
    assert_eq!(paragraph_alignment(None, &Shape::default()), Alignment::Natural);
    assert!(paragraph_takes_strategy(false));
    assert!(!paragraph_takes_strategy(true));
}

#[test]
fn configure_container() {
    let c = configure(&Shape { lines: 3, ..Shape::default() }, None, None);
    assert_eq!(c.line_break, LineBreak::Clipping);
    assert_eq!(c.maximum_number_of_lines, 0);
    assert_eq!((c.width, c.height, c.line_fragment_padding), (f64::MAX, f64::MAX, 2.0));
    let mut shape = wrapping(2);
    shape.truncates_last_visible_line = true;
    let c = configure(&shape, Some(100.0), Some(30.0));
    assert_eq!(c.line_break, LineBreak::TruncatingTail);
    assert_eq!((c.maximum_number_of_lines, c.width, c.height), (2, 100.0, 30.0));
    assert_eq!(configure(&wrapping(-4), None, None).maximum_number_of_lines, 0);
    assert_eq!(layout_height(&shape, 30.0), Some(30.0));
    assert_eq!(layout_height(&wrapping(2), 30.0), None);
}

#[test]
fn measuring() {
    let mut shape = wrapping(3);
    shape.alignment = Alignment::Center;
    shape.truncates_last_visible_line = true;
    let (m, shown) = measuring_shape(&shape);
    assert_eq!((m.alignment, m.truncates_last_visible_line, m.lines), (Alignment::Left, false, 0));
    assert_eq!(shown, Some(3));
    let (m, shown) = measuring_shape(&Shape { lines: 1, ..Shape::default() });
    assert_eq!((m.lines, shown), (1, None));
    assert_eq!(measuring_shape(&wrapping(0)).1, None);
    assert_eq!(measuring_width(Some(100.0)), Some(104.0));
    assert_eq!(measuring_width(None), None);
}

#[test]
fn laid_out() {
    // 50.3 - 4 = 46.3 -> 92.6 px -> 93 / 2 = 46.5; 16.2 -> 32.4 -> 33 / 2 = 16.5.
    let m = laid_out_metrics(true, 50.3, 16.2, Some(12.0), Some(12.5), 2.0);
    assert_eq!(m.size, Size { width: 46.5, height: 16.5 });
    assert_eq!((m.first_baseline, m.last_baseline_from_bottom), (12.0, 4.0));
    let empty = laid_out_metrics(false, 50.3, 16.0, None, None, 0.0);
    assert_eq!(empty.size, Size { width: 0.0, height: 16.0 });
    assert_eq!(empty.last_baseline_from_bottom, 16.0);
    assert_eq!(laid_out_metrics(true, 3.0, 0.0, None, None, 1.0).size.width, 0.0);
}

#[test]
fn trailing_spaces() {
    let text: Vec<u16> = "ab \t\u{2028}".encode_utf16().collect();
    assert_eq!(trailing_space_end(&text, 0, 5), 2);
    assert!(trims_trailing_spaces(0, 5, 2));
    let spaces: Vec<u16> = "   ".encode_utf16().collect();
    assert_eq!(trailing_space_end(&spaces, 0, 3), 0);
    assert!(!trims_trailing_spaces(0, 3, 0));
    assert!(!trims_trailing_spaces(0, 2, 2));
    let used = Rect { x: 0.0, y: 0.0, width: 40.0, height: 16.0 };
    assert_eq!(without_trailing_spaces(used, 30.0), Rect { width: 32.0, ..used });
    assert_eq!(without_trailing_spaces(used, 38.0), used);
    assert_eq!(without_trailing_spaces(used, -2.0), used);
}

#[test]
fn ellipsis_and_clip() {
    let mut shape = wrapping(2);
    shape.truncates_last_visible_line = true;
    let text: Vec<u16> = "one\ntwo".encode_utf16().collect();
    let (cut, at) = ellipsized(&shape, &text, 4).unwrap();
    assert_eq!(String::from_utf16(&cut).unwrap(), "one\u{2026}");
    assert_eq!(at, 2);
    assert_eq!(ellipsized(&shape, &text, 3), None);
    assert_eq!(ellipsized(&shape, &text, 7), None);
    assert_eq!(ellipsized(&shape, &text, 0), None);
    assert_eq!(ellipsized(&wrapping(2), &text, 4), None);
    let lone: Vec<u16> = "\nx".encode_utf16().collect();
    assert_eq!(ellipsized(&shape, &lone, 1).unwrap().1, 0);
    assert_eq!(draw_clip(0.0, 100.0, 30.0), None);
    assert_eq!(
        draw_clip(14.0, 100.0, 30.0),
        Some(Rect { x: 2.0, y: 0.0, width: 96.0, height: 30.0 })
    );
    assert_eq!(draw_clip(14.0, 3.0, 30.0).unwrap().width, 0.0);
}

#[test]
fn wrap_and_intrinsic() {
    let one = LabelState {
        shape: Shape { lines: 1, wraps: true, ..Shape::default() },
        preferred_max_layout_width: 80.0,
        bounds_width: 100.0,
    };
    assert_eq!(wrap_width(&one), None);
    assert_eq!(intrinsic_measure_width(&one), None);
    let preferred =
        LabelState { shape: wrapping(0), preferred_max_layout_width: 80.0, bounds_width: 100.0 };
    assert_eq!(wrap_width(&preferred), Some(80.0));
    let bounds = LabelState { preferred_max_layout_width: 0.0, ..preferred };
    assert_eq!(wrap_width(&bounds), Some(96.0));
    assert_eq!(wrap_width(&LabelState { bounds_width: 4.0, ..bounds }), None);
    let single_pref =
        LabelState { shape: Shape::default(), preferred_max_layout_width: 80.0, bounds_width: 0.0 };
    assert_eq!(wrap_width(&single_pref), Some(80.0));
    assert_eq!(intrinsic_measure_width(&single_pref), Some(80.0));
    let line = Size { width: 200.0, height: 16.0 };
    let measured = Size { width: 78.0, height: 48.0 };
    assert_eq!(intrinsic_size(&preferred, line, measured), measured);
    assert_eq!(intrinsic_size(&bounds, line, measured), Size { width: 200.0, height: 48.0 });
    assert_eq!(intrinsic_size(&one, line, measured), line);
    assert_eq!(intrinsic_size(&single_pref, line, measured), measured);
    assert_eq!(size_for_width_measure(&wrapping(0), 50.0), Some(46.0));
    assert_eq!(size_for_width_measure(&wrapping(0), 3.0), Some(0.0));
    assert_eq!(size_for_width_measure(&Shape::default(), 50.0), None);
    assert_eq!(frame_size(Size { width: 10.0, height: 16.0 }), Size { width: 14.0, height: 16.0 });
    assert!(frame_change_invalidates_intrinsic(&bounds, true));
    assert!(!frame_change_invalidates_intrinsic(&bounds, false));
    assert!(!frame_change_invalidates_intrinsic(&preferred, true));
    assert!(!frame_change_invalidates_intrinsic(&one, true));
}

#[test]
fn line_break_setters() {
    assert!(wraps_for_line_break(LineBreak::WordWrapping));
    assert!(wraps_for_line_break(LineBreak::CharWrapping));
    assert!(!wraps_for_line_break(LineBreak::TruncatingTail));
    assert_eq!(line_break_for_wraps(true, LineBreak::TruncatingTail), LineBreak::WordWrapping);
    assert_eq!(line_break_for_wraps(false, LineBreak::CharWrapping), LineBreak::Clipping);
    assert_eq!(line_break_for_wraps(true, LineBreak::CharWrapping), LineBreak::CharWrapping);
    assert_eq!(line_break_for_wraps(false, LineBreak::TruncatingHead), LineBreak::TruncatingHead);
}

#[test]
fn glyph_updates() {
    assert_eq!(glyph_update(Some((true, true)), false, false), GlyphUpdate::default());
    assert_eq!(
        glyph_update(None, false, false),
        GlyphUpdate { updates: true, clears_images: true, draws: true, counts_draw: true }
    );
    assert_eq!(
        glyph_update(Some((true, false)), true, false),
        GlyphUpdate { updates: true, clears_images: false, draws: false, counts_draw: false }
    );
    assert_eq!(
        glyph_update(Some((false, true)), true, true),
        GlyphUpdate { updates: true, clears_images: true, draws: true, counts_draw: false }
    );
}

#[test]
fn accessibility() {
    assert_eq!(
        accessibility_frame(Rect { x: 0.0, y: 0.0, width: 40.0, height: 16.0 }),
        Some(Rect { x: 1.0, y: -1.0, width: 38.0, height: 18.0 })
    );
    assert_eq!(accessibility_frame(Rect { x: 0.0, y: 0.0, width: 1.0, height: 16.0 }), None);
    assert!(accessibility_range_valid(0, 5, 5));
    assert!(!accessibility_range_valid(1, 5, 5));
    assert!(!accessibility_range_valid(-1, 1, 5));
}

#[test]
fn ops() {
    let fonts = json!([{"ascender": 12.38, "descender": -3.15, "leading": 0}]);
    assert_eq!(
        call("tokens.text_label_line_metrics", &json!({"fonts": fonts})).unwrap(),
        json!({"line": {"ascent": 12.0, "height": 16.0}})
    );
    assert_eq!(
        call(
            "tokens.text_label_empty_metrics",
            &json!({"fonts": fonts, "textIsEmpty": true, "scale": 2})
        )
        .unwrap(),
        json!({"metrics": {"size": {"width": 0.0, "height": 16.0}, "firstBaseline": 12.0, "lastBaselineFromBottom": 4.0}})
    );
    assert_eq!(
        call(
            "tokens.text_label_paragraph",
            &json!({"shape": {"wraps": true, "lines": 2}, "ownAlignment": "center"})
        )
        .unwrap(),
        json!({"lineBreak": "wordWrapping", "alignment": "center", "takesStrategy": true, "isMultiline": true})
    );
    assert_eq!(
        call("tokens.text_label_configure", &json!({"shape": {"lines": 2}, "width": 100})).unwrap()
            ["lineBreak"],
        json!("clipping")
    );
    assert_eq!(
        call(
            "tokens.text_label_layout_height",
            &json!({"shape": {"wraps": true, "truncatesLastVisibleLine": true}, "height": 30})
        )
        .unwrap(),
        json!({"height": 30.0})
    );
    assert_eq!(
        call(
            "tokens.text_label_measuring",
            &json!({"shape": {"wraps": true, "lines": 3}, "width": 100})
        )
        .unwrap(),
        json!({"shape": {"lines": 0, "wraps": true, "lineBreak": "clipping", "alignment": "left", "tightens": false, "truncatesLastVisibleLine": false}, "shownLines": 3, "width": 104.0})
    );
    assert_eq!(
        call(
            "tokens.text_label_laid_out_metrics",
            &json!({"hasText": true, "usedMaxX": 50.3, "usedMaxY": 16.2, "scale": 2})
        )
        .unwrap()["size"],
        json!({"width": 46.5, "height": 16.5})
    );
    assert_eq!(
        call("tokens.text_label_trailing_spaces", &json!({"text": "ab  ", "start": 0, "end": 4}))
            .unwrap(),
        json!({"keptEnd": 2, "trims": true})
    );
    assert!(
        call("tokens.text_label_trailing_spaces", &json!({"text": "ab", "start": 0, "end": 4}))
            .is_err()
    );
    assert_eq!(
        call(
            "tokens.text_label_trim_rect",
            &json!({"used": {"x": 0, "y": 0, "width": 40, "height": 16}, "keptMaxX": 30})
        )
        .unwrap(),
        json!({"x": 0.0, "y": 0.0, "width": 32.0, "height": 16.0})
    );
    assert_eq!(
        call("tokens.text_label_ellipsized", &json!({"text": "one\ntwo", "shownEnd": 4, "shape": {"wraps": true, "truncatesLastVisibleLine": true}})).unwrap(),
        json!({"cut": {"text": "one\u{2026}", "attributesAt": 2}})
    );
    assert_eq!(
        call(
            "tokens.text_label_draw_clip",
            &json!({"lastLineMinY": 14, "width": 100, "height": 30})
        )
        .unwrap(),
        json!({"clip": {"x": 2.0, "y": 0.0, "width": 96.0, "height": 30.0}})
    );
    let label = json!({"shape": {"wraps": true}, "boundsWidth": 100});
    assert_eq!(
        call("tokens.text_label_wrap_width", &json!({"label": label})).unwrap(),
        json!({"wrapWidth": 96.0})
    );
    assert_eq!(
        call("tokens.text_label_intrinsic", &json!({"label": label, "line": {"width": 200, "height": 16}, "measured": {"width": 78, "height": 48}})).unwrap(),
        json!({"measureWidth": 96.0, "size": {"width": 200.0, "height": 48.0}})
    );
    assert_eq!(
        call(
            "tokens.text_label_size_for_width",
            &json!({"shape": {"wraps": true}, "frameWidth": 50})
        )
        .unwrap(),
        json!({"measureWidth": 46.0})
    );
    assert_eq!(
        call("tokens.text_label_frame_size", &json!({"size": {"width": 10, "height": 16}}))
            .unwrap(),
        json!({"width": 14.0, "height": 16.0})
    );
    assert_eq!(
        call("tokens.text_label_frame_change", &json!({"label": label, "widthChanged": true}))
            .unwrap(),
        json!({"invalidatesIntrinsic": true})
    );
    assert_eq!(
        call("tokens.text_label_line_break", &json!({"mode": "truncatingTail", "wraps": true}))
            .unwrap(),
        json!({"wraps": false, "lineBreak": "wordWrapping"})
    );
    assert_eq!(
        call(
            "tokens.text_label_glyph_update",
            &json!({"drawn": {"sameInk": true, "sameWeight": true}})
        )
        .unwrap(),
        json!({"updates": false, "clearsImages": false, "draws": false, "countsDraw": false})
    );
    assert_eq!(
        call(
            "tokens.text_label_accessibility_frame",
            &json!({"bounds": {"x": 0, "y": 0, "width": 1, "height": 16}})
        )
        .unwrap(),
        json!({"frame": null})
    );
    assert_eq!(
        call(
            "tokens.text_label_accessibility_range",
            &json!({"location": 1, "length": 2, "contentLength": 3})
        )
        .unwrap(),
        json!({"valid": true})
    );
}
