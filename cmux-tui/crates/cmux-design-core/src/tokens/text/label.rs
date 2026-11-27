//! `LabelText.swift` and `ChromeLabel.swift`: the label's shape rules (line break, line count,
//! alignment, container setup), the whole-point line metrics, the empty-line shortcut, the
//! measured size's rounding, trailing-space trimming, the ellipsis at a line break, the drawing
//! clip, the wrap width, the intrinsic size, the frame size, the glyph redraw choice and the
//! accessibility rules. TextKit's layout and the drawing stay in Swift.

use serde::{Deserialize, Serialize};

/// `LabelText.padding`: the line fragment padding on each side.
pub const PADDING: f64 = 2.0;

/// The measured-layouts cache empties before an insert at this size (`measured.count >= 8`).
pub const MEASURED_CACHE_LIMIT: usize = 8;

/// The cache key of an unbounded width (`width ?? -1`).
pub const UNBOUNDED_WIDTH_KEY: f64 = -1.0;

/// The characters a field's last shown line drops from its width (space, tab, LF, CR, U+2028,
/// U+2029).
pub const TRAILING_SPACES: [u16; 6] = [0x20, 0x09, 0x0A, 0x0D, 0x2028, 0x2029];

/// The line breaks an ellipsis may replace at the end of the last visible line.
pub const LINE_BREAKS: [u16; 4] = [0x0A, 0x0D, 0x2028, 0x2029];

/// `CGFloat.greatestFiniteMagnitude`: an unbounded container side.
pub const UNBOUNDED: f64 = f64::MAX;

/// `NSLineBreakMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LineBreak {
    /// `.byWordWrapping`.
    WordWrapping,
    /// `.byCharWrapping`.
    CharWrapping,
    /// `.byClipping` (the label default).
    #[default]
    Clipping,
    /// `.byTruncatingHead`.
    TruncatingHead,
    /// `.byTruncatingTail`.
    TruncatingTail,
    /// `.byTruncatingMiddle`.
    TruncatingMiddle,
}

impl LineBreak {
    /// `isWrapping`: word or character wrapping.
    pub fn is_wrapping(self) -> bool {
        matches!(self, LineBreak::WordWrapping | LineBreak::CharWrapping)
    }
}

/// `NSTextAlignment`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Alignment {
    /// `.left`.
    Left,
    /// `.right`.
    Right,
    /// `.center`.
    Center,
    /// `.justified`.
    Justified,
    /// `.natural` (the label default).
    #[default]
    Natural,
}

/// `LabelText.Shape` (its line break strategy aside: the rule is only "a run without a style
/// takes the shape's").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Shape {
    /// `maximumNumberOfLines` (0: no limit).
    pub lines: i64,
    /// Lines break at the width.
    pub wraps: bool,
    /// The line break mode.
    pub line_break: LineBreak,
    /// The alignment.
    pub alignment: Alignment,
    /// `allowsDefaultTighteningForTruncation`.
    pub tightens: bool,
    /// `truncatesLastVisibleLine`.
    pub truncates_last_visible_line: bool,
}

impl Shape {
    /// `isMultiline`: a wrapping label allowed more than one line.
    pub fn is_multiline(&self) -> bool {
        self.wraps && self.lines != 1
    }
}

/// A size (`NSSize`).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Size {
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// A rectangle (`CGRect`).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Rect {
    /// Origin x.
    pub x: f64,
    /// Origin y.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// `LabelText.Metrics`: a laid-out text's size (no padding) and baselines.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    /// The size in the alignment rect.
    pub size: Size,
    /// The first line's baseline from the top.
    pub first_baseline: f64,
    /// The last line's baseline from the bottom.
    pub last_baseline_from_bottom: f64,
}

/// One font's vertical metrics (`NSFont.ascender`, `descender` (negative), `leading`).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct FontLine {
    /// `ascender`.
    pub ascender: f64,
    /// `descender` (negative below the baseline).
    pub descender: f64,
    /// `leading`.
    pub leading: f64,
}

/// `WholePointLines.metrics(of:in:)`: the rounded ascent and the line height of the fonts on a
/// line; None without a font (or an ascent that rounds to 0).
pub fn whole_point_line(fonts: &[FontLine]) -> Option<(f64, f64)> {
    let (mut ascent, mut descent, mut leading) = (0.0_f64, 0.0_f64, 0.0_f64);
    for font in fonts {
        ascent = ascent.max(font.ascender.round());
        descent = descent.max((-font.descender).ceil());
        leading = leading.max(font.leading.ceil());
    }
    (ascent > 0.0).then_some((ascent, ascent + descent + leading))
}

/// `measure`'s shortcut for an empty text at an unbounded width: one empty line of its font,
/// no layout. None where it lays out (text, a width, or no line metrics).
pub fn empty_line_metrics(
    text_is_empty: bool,
    width: Option<f64>,
    font: &[FontLine],
    scale: f64,
) -> Option<Metrics> {
    if !text_is_empty || width.is_some() {
        return None;
    }
    let (ascent, line_height) = whole_point_line(font)?;
    let scale = scale.max(1.0);
    let height = (line_height * scale).ceil() / scale;
    Some(Metrics {
        size: Size { width: 0.0, height },
        first_baseline: ascent,
        last_baseline_from_bottom: height - ascent,
    })
}

/// `paragraphed`: the line break mode of every paragraph.
pub fn paragraph_line_break(shape: &Shape) -> LineBreak {
    if shape.wraps {
        if shape.line_break == LineBreak::CharWrapping {
            LineBreak::CharWrapping
        } else {
            LineBreak::WordWrapping
        }
    } else {
        shape.line_break
    }
}

/// `paragraphed`: a run's alignment, given its own style's (None: no style). The shape's wins
/// unless it is `.natural` and the run has a style of its own.
pub fn paragraph_alignment(own: Option<Alignment>, shape: &Shape) -> Alignment {
    match own {
        Some(own) if shape.alignment == Alignment::Natural => own,
        _ => shape.alignment,
    }
}

/// `paragraphed`: a run takes the shape's line break strategy only when it has no style.
pub fn paragraph_takes_strategy(has_own_style: bool) -> bool {
    !has_own_style
}

/// What `configure(_:shape:width:height:)` sets on the container.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Container {
    /// `lineFragmentPadding`.
    pub line_fragment_padding: f64,
    /// `maximumNumberOfLines`.
    pub maximum_number_of_lines: i64,
    /// `lineBreakMode`.
    pub line_break: LineBreak,
    /// The container width ([`UNBOUNDED`] for none).
    pub width: f64,
    /// The container height ([`UNBOUNDED`] for none).
    pub height: f64,
}

/// `configure(_:shape:width:height:)`.
pub fn configure(shape: &Shape, width: Option<f64>, height: Option<f64>) -> Container {
    let line_break = if !shape.wraps {
        LineBreak::Clipping
    } else if shape.truncates_last_visible_line && shape.line_break.is_wrapping() {
        LineBreak::TruncatingTail
    } else {
        shape.line_break
    };
    Container {
        line_fragment_padding: PADDING,
        maximum_number_of_lines: if shape.wraps { shape.lines.max(0) } else { 0 },
        line_break,
        width: width.unwrap_or(UNBOUNDED),
        height: height.unwrap_or(UNBOUNDED),
    }
}

/// `layoutHeight(_:size:)`: the frame's height for a wrapping label whose last visible line
/// truncates, else unbounded.
pub fn layout_height(shape: &Shape, height: f64) -> Option<f64> {
    (shape.wraps && shape.truncates_last_visible_line).then_some(height)
}

/// `laidOutMetrics`' measuring shape and the count of lines it measures (None: every line).
pub fn measuring_shape(shape: &Shape) -> (Shape, Option<i64>) {
    let mut measuring = *shape;
    measuring.alignment = Alignment::Left;
    measuring.truncates_last_visible_line = false;
    let shown_lines = (measuring.wraps && measuring.lines > 0).then_some(measuring.lines);
    if measuring.wraps {
        measuring.lines = 0;
    }
    (measuring, shown_lines)
}

/// `laidOutMetrics`' container width: the text's width plus the padding on both sides.
pub fn measuring_width(width: Option<f64>) -> Option<f64> {
    width.map(|w| w + PADDING * 2.0)
}

/// `laidOutMetrics`' result from the union of the used line rects (its max x and max y) and the
/// first and last baselines (from the top): widths and heights rounded up to a whole pixel, an
/// empty text no width.
pub fn laid_out_metrics(
    has_text: bool,
    used_max_x: f64,
    used_max_y: f64,
    first_baseline: Option<f64>,
    last_baseline: Option<f64>,
    scale: f64,
) -> Metrics {
    let scale = scale.max(1.0);
    let text_width = if has_text { (used_max_x - PADDING * 2.0).max(0.0) } else { 0.0 };
    let size = Size {
        width: (text_width * scale).ceil() / scale,
        height: (used_max_y * scale).ceil() / scale,
    };
    Metrics {
        size,
        first_baseline: first_baseline.unwrap_or(0.0),
        last_baseline_from_bottom: size.height - last_baseline.unwrap_or(0.0),
    }
}

/// `withoutTrailingSpaces`: the end (UTF-16 offset) of `utf16[start..end]` once its trailing
/// spaces, tabs and line breaks are dropped.
pub fn trailing_space_end(utf16: &[u16], start: usize, end: usize) -> usize {
    let mut end = end;
    while end > start && utf16.get(end - 1).is_some_and(|c| TRAILING_SPACES.contains(c)) {
        end -= 1;
    }
    end
}

/// `withoutTrailingSpaces`: whether the line's rect is trimmed at all (some but not every
/// character drops).
pub fn trims_trailing_spaces(start: usize, end: usize, kept_end: usize) -> bool {
    kept_end < end && kept_end > start
}

/// `withoutTrailingSpaces`: `used` ending at `kept_max_x` (the kept glyphs' bounding max x) plus
/// the padding, unless that does not fall inside it (right-to-left text).
pub fn without_trailing_spaces(used: Rect, kept_max_x: f64) -> Rect {
    let right = kept_max_x + PADDING;
    if right > used.x && right < used.x + used.width {
        Rect { x: used.x, y: used.y, width: right - used.x, height: used.height }
    } else {
        used
    }
}

/// `ellipsized`: the UTF-16 text up to the last visible line's end with an ellipsis in place of
/// the line break there, and the index whose attributes the ellipsis takes; None unless the
/// label truncates its last visible line, part of the text is shown, and the cut is a line break.
pub fn ellipsized(shape: &Shape, utf16: &[u16], shown_end: usize) -> Option<(Vec<u16>, usize)> {
    if !(shape.wraps && shape.truncates_last_visible_line) {
        return None;
    }
    if !(shown_end < utf16.len() && shown_end > 0) {
        return None;
    }
    if !utf16.get(shown_end - 1).is_some_and(|c| LINE_BREAKS.contains(c)) {
        return None;
    }
    let mut cut = utf16.get(..shown_end - 1)?.to_vec();
    cut.push(0x2026);
    let attributes_at = shown_end.saturating_sub(2);
    Some((cut, attributes_at))
}

/// `draw`: text of more than one line (its last line's top below 0) clips to the text's area;
/// a single line to the box (None).
pub fn draw_clip(last_line_min_y: f64, width: f64, height: f64) -> Option<Rect> {
    (last_line_min_y > 0.0).then(|| Rect {
        x: PADDING,
        y: 0.0,
        width: (width - PADDING * 2.0).max(0.0),
        height,
    })
}

/// The label settings the layout rules read (`ChromeLabel`'s properties).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LabelState {
    /// The shape.
    pub shape: Shape,
    /// `preferredMaxLayoutWidth` (0: the current width).
    pub preferred_max_layout_width: f64,
    /// `bounds.width`.
    pub bounds_width: f64,
}

/// `ChromeLabel.wrapWidth`: where a wrapping label breaks its lines; None: one line.
pub fn wrap_width(label: &LabelState) -> Option<f64> {
    if label.shape.lines == 1 {
        return None;
    }
    if label.preferred_max_layout_width > 0.0 {
        return Some(label.preferred_max_layout_width);
    }
    let current = label.bounds_width - PADDING * 2.0;
    (label.shape.is_multiline() && current > 0.0).then_some(current)
}

/// The width `intrinsicContentSize` measures at besides the unbounded line: the wrap width, or
/// the preferred width of a non-wrapping label with a line limit other than 1; None: the line.
pub fn intrinsic_measure_width(label: &LabelState) -> Option<f64> {
    if label.shape.is_multiline()
        && let Some(width) = wrap_width(label)
    {
        return Some(width);
    }
    (label.shape.lines != 1 && label.preferred_max_layout_width > 0.0)
        .then_some(label.preferred_max_layout_width)
}

/// `intrinsicContentSize` from the unbounded line's size and the size at
/// [`intrinsic_measure_width`] (unused when that is None).
pub fn intrinsic_size(label: &LabelState, line: Size, measured: Size) -> Size {
    if label.shape.is_multiline() && wrap_width(label).is_some() {
        let width =
            if label.preferred_max_layout_width > 0.0 { measured.width } else { line.width };
        return Size { width, height: measured.height };
    }
    if intrinsic_measure_width(label).is_some() { measured } else { line }
}

/// `size(forWidth:)`'s measuring width: the frame less the padding for a multiline label, else
/// unbounded.
pub fn size_for_width_measure(shape: &Shape, frame_width: f64) -> Option<f64> {
    shape.is_multiline().then(|| (frame_width - PADDING * 2.0).max(0.0))
}

/// `frameSize`: a text size plus the padding on both sides.
pub fn frame_size(text: Size) -> Size {
    Size { width: text.width + PADDING * 2.0, height: text.height }
}

/// `alignmentRectInsets`: (top, left, bottom, right).
pub fn alignment_rect_insets() -> (f64, f64, f64, f64) {
    (0.0, PADDING, 0.0, PADDING)
}

/// `setFrameSize`: a width change of a multiline label at its current width changes its
/// intrinsic size.
pub fn frame_change_invalidates_intrinsic(label: &LabelState, width_changed: bool) -> bool {
    width_changed
        && label.shape.is_multiline()
        && label.preferred_max_layout_width <= 0.0
        && label.shape.lines != 1
}

/// The cache key of a measuring width.
pub fn measured_key(width: Option<f64>) -> f64 {
    width.unwrap_or(UNBOUNDED_WIDTH_KEY)
}

/// The measured cache empties before an insert at this size.
pub fn measured_cache_evicts(count: usize) -> bool {
    count >= MEASURED_CACHE_LIMIT
}

/// `lineBreakMode`'s setter: the `wraps` a mode gives (as `NSCell`'s).
pub fn wraps_for_line_break(mode: LineBreak) -> bool {
    mode.is_wrapping()
}

/// `wraps`' setter: the line break mode after `wraps` changes (word wrapping when it turns on
/// over a non-wrapping mode, clipping when it turns off over a wrapping one).
pub fn line_break_for_wraps(wraps: bool, mode: LineBreak) -> LineBreak {
    if mode.is_wrapping() != wraps {
        if wraps { LineBreak::WordWrapping } else { LineBreak::Clipping }
    } else {
        mode
    }
}

/// What `updateLayer` does with the glyph images.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GlyphUpdate {
    /// The glyphs show something new (ink or weight changed).
    pub updates: bool,
    /// The kept images are dropped (the ink changed).
    pub clears_images: bool,
    /// A new image is drawn (no kept image for the weight).
    pub draws: bool,
    /// `glyphDraws` counts it (a new image of a non-empty text).
    pub counts_draw: bool,
}

/// `updateLayer`'s glyph choice. `drawn`: (same ink, same weight) as the last drawn, None if
/// nothing was drawn; `kept`: an image is kept for the new weight (after any clearing).
pub fn glyph_update(
    drawn: Option<(bool, bool)>,
    kept_for_weight: bool,
    text_is_empty: bool,
) -> GlyphUpdate {
    let (same_ink, same_weight) = drawn.unwrap_or((false, false));
    if drawn.is_some() && same_ink && same_weight {
        return GlyphUpdate::default();
    }
    let clears_images = !same_ink;
    let kept = kept_for_weight && !clears_images;
    GlyphUpdate { updates: true, clears_images, draws: !kept, counts_draw: !kept && !text_is_empty }
}

/// `accessibilityFrame`: the bounds 1 pt in from each side, 1 pt out at top and bottom
/// (`insetBy(dx: 1, dy: -1)`); None where that is `CGRect.null` (bounds under 2 pt wide).
pub fn accessibility_frame(bounds: Rect) -> Option<Rect> {
    let width = bounds.width - 2.0;
    let height = bounds.height + 2.0;
    (width >= 0.0 && height >= 0.0).then_some(Rect {
        x: bounds.x + 1.0,
        y: bounds.y - 1.0,
        width,
        height,
    })
}

/// `accessibilityString(for:)`'s range check.
pub fn accessibility_range_valid(location: i64, length: i64, content_length: i64) -> bool {
    location >= 0 && location + length <= content_length
}

/// `mouseDownCanMoveWindow`: a selectable label keeps the mouse.
pub fn mouse_down_can_move_window(selectable: bool) -> bool {
    !selectable
}
