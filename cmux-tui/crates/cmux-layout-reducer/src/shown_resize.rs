//! The keyboard resize rules of a screen as it shows: which split ratios, column widths and dock widths show as
//! different layouts, the width trade of a key press between two strip columns, and the row heights of a key press
//! on a row edge (RESIZE KEYS, cmux-ad 2026-11-02: every press moves exactly what a person sees, or nothing).
//!
//! The app gathers the values these rules read from its placed geometry (`ShownResizeRange` in CmuxNextLayout) and
//! calls them through cmux-layout-reducer-ffi (`cmux_shown_resize_*`). They are the app's former Swift rules, ported
//! one operation at a time: Swift's `min` and `max` (which keep the first value on a tie and on NaN) are
//! [`swift_min`] and [`swift_max`], `rounded()` is [`f64::round`] (half away from zero), and a column width goes
//! through `f32` as the daemon keeps it. `tests/shown_resize_corpus.rs` checks every rule against the answers the
//! Swift rules gave for a seeded corpus (`tests/data/shown_resize_corpus.txt`).

/// The column width shares the daemon accepts (`ColumnWidthPreset.widthRange` in the app).
pub const WIDTH_RANGE: (f64, f64) = (0.1, 1.0);
/// The share a new column takes (`ColumnWidthPreset.defaultWidth`): what a width maps to on a strip with no room.
pub const DEFAULT_WIDTH: f64 = 0.5;
/// The stored row heights the daemon accepts, in permille (`LayoutRow.heightRange`).
pub const ROW_RANGE: (i64, i64) = (100, 1000);
/// The share of the window one side dock may take (`DockStripGeometry.maxShare`).
pub const DOCK_MAX_SHARE: f64 = 0.75;
/// The share of the window each of two side docks may take (`DockStripGeometry.maxShareBoth`).
pub const DOCK_MAX_SHARE_BOTH: f64 = 0.4;
/// The strip width docked docks leave beside them (`DockStripGeometry.minimumStripWidth`), at most half the window.
pub const MINIMUM_STRIP_WIDTH: f64 = 400.0;
/// Float slack of a pixel when the room of a trade is cut to whole pixels (`ColumnStripGeometry.edgeTolerance`).
pub const EDGE_TOLERANCE: f64 = 0.01;

/// Swift's `min(x, y)`: `y < x ? y : x`.
#[must_use]
pub fn swift_min(x: f64, y: f64) -> f64 {
    if y < x { y } else { x }
}

/// Swift's `max(x, y)`: `y >= x ? y : x`.
#[must_use]
pub fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}

/// A closed range of shares.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Bounds {
    pub lower: f64,
    pub upper: f64,
}

/// The pixel width of a strip column of share `fraction` (`ColumnStripGeometry.pixelWidth`).
#[must_use]
pub fn pixel_width(fraction: f64, viewport_width: f64, gap: f64) -> f64 {
    swift_max(1.0, (viewport_width - gap) * fraction - gap)
}

/// The share whose column is `width` points wide, kept in [`WIDTH_RANGE`] (`ColumnStripGeometry.fraction`).
#[must_use]
pub fn fraction(width: f64, viewport_width: f64, gap: f64) -> f64 {
    let denominator = viewport_width - gap;
    if denominator <= 0.0 {
        return DEFAULT_WIDTH;
    }
    let value = (width + gap) / denominator;
    swift_min(swift_max(value, WIDTH_RANGE.0), WIDTH_RANGE.1)
}

/// `value` rounded to the pixel grid (`SplitGeometry.roundToPixel`).
#[must_use]
pub fn round_to_pixel(value: f64, scale: f64) -> f64 {
    if scale > 0.0 { (value * scale).round() / scale } else { value }
}

/// `value` rounded up to the pixel grid, with a thousandth of a pixel of slack (`SplitGeometry.ceilToPixel`).
#[must_use]
pub fn ceil_to_pixel(value: f64, scale: f64) -> f64 {
    if scale > 0.0 { (value * scale - 0.001).ceil() / scale } else { value }
}

/// The pixel height of a row of `permille` (`RowStackGeometry.pixelHeight`).
#[must_use]
pub fn row_pixel_height(permille: f64, column_height: f64, gap: f64) -> f64 {
    swift_max(1.0, (column_height + gap) * permille / 1000.0 - gap)
}

/// The split ratios of a divider that place it somewhere new: each side keeps its minimum extent. `container` and
/// `divider` are the split's and the divider's extents along its axis. None when there is no room for both minimums.
#[must_use]
pub fn ratio(container: f64, divider: f64, minimum_a: f64, minimum_b: f64) -> Option<Bounds> {
    let available = container - divider;
    let fits = available > 0.0 && minimum_a + minimum_b <= available;
    if !fits {
        return None;
    }
    let lower = minimum_a / available;
    let upper = (available - minimum_b) / available;
    (lower <= upper).then_some(Bounds { lower, upper })
}

/// The width shares of a scrolling strip column the strip shows as different widths: from the share whose frame is
/// the column's minimum width up. None for a docked column or a screen with no strip.
#[must_use]
pub fn column_width(
    is_columns: bool,
    is_docked: bool,
    strip_width: f64,
    minimum_width: f64,
    gap: f64,
) -> Option<Bounds> {
    let has_strip = strip_width > 0.0;
    if !is_columns || is_docked || !has_strip {
        return None;
    }
    let lower = fraction(minimum_width, strip_width, gap);
    Some(Bounds { lower, upper: swift_max(lower, WIDTH_RANGE.1) })
}

/// One placed dock of the screen, as [`dock_width`] reads it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DockSide {
    /// The dock the press resizes.
    pub is_target: bool,
    /// A top or bottom band, not a side dock.
    pub is_band: bool,
    pub is_docked: bool,
    pub width: f64,
}

/// The width shares of a side dock the screen shows as different widths (`DockStripGeometry.place`): from its panes'
/// minimum to its share of the window, and for a docked dock to the room the strip leaves at its minimum width beside
/// the other docked dock as it shows. None when the target is not a placed side dock.
#[must_use]
pub fn dock_width<I>(docks: I, viewport_width: f64, gap: f64, minimum_width: f64) -> Option<Bounds>
where
    I: IntoIterator<Item = DockSide>,
    I::IntoIter: Clone,
{
    let sides = docks.into_iter().filter(|side| !side.is_band);
    let side_count = sides.clone().count();
    let entry = sides.clone().find(|side| side.is_target)?;
    let share = if side_count == 2 { DOCK_MAX_SHARE_BOTH } else { DOCK_MAX_SHARE };
    let mut widest = swift_max(1.0, viewport_width * share);
    if entry.is_docked {
        let others = sides.filter(|side| !side.is_target && side.is_docked);
        let (count, widths) = others
            .fold((0_u32, 0.0), |(count, sum), side| (count.saturating_add(1), sum + side.width));
        let room = viewport_width
            - swift_min(MINIMUM_STRIP_WIDTH, viewport_width / 2.0)
            - gap * f64::from(count.saturating_add(1));
        widest = swift_min(widest, room - widths);
    }
    let lower = fraction(minimum_width, viewport_width, gap);
    let upper = fraction(widest, viewport_width, gap);
    Some(Bounds { lower, upper: swift_max(lower, upper) })
}

/// What a keyboard trade between two neighbor strip columns reads: the strip, the two columns' shown frames, their
/// minimum widths and stored shares, and where the strip's camera rests.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TradeInput {
    pub is_columns: bool,
    pub strip_width: f64,
    pub gap: f64,
    /// Device pixels per point.
    pub scale: f64,
    /// The press, a share of the strip; right is positive.
    pub delta: f64,
    pub left_min_x: f64,
    pub left_max_x: f64,
    pub left_width: f64,
    pub right_min_x: f64,
    pub right_max_x: f64,
    pub right_width: f64,
    pub left_minimum_width: f64,
    pub right_minimum_width: f64,
    pub left_fraction: f64,
    pub right_fraction: f64,
    /// Where the strip's camera rests (content x of its viewport's leading edge); None when unknown.
    pub strip_offset: Option<f64>,
    pub uncovered_min_x: f64,
    pub uncovered_max_x: f64,
    pub strip_min_x: f64,
}

/// The divider move of a trade, in points, and the two width pairs that may show it, in the order to try them: the
/// pair's ideal sum kept with both widths the same way from their pixels, then the shown widths themselves. Each
/// width is what the daemon keeps (`f32`). The caller places each pair and takes the first that moves only the
/// divider by `move_points`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TradeCandidates {
    pub move_points: f64,
    pub first: (f64, f64),
    pub second: (f64, f64),
}

/// The width trade of a key press between two neighbor strip columns: whole device pixels from the widths the columns
/// show, stopped where a column reaches its minimum (rounded up to a pixel) or the widest share, and where the divider
/// would leave the part of the strip the window shows. None when the press would move nothing.
#[must_use]
pub fn trade(input: &TradeInput) -> Option<TradeCandidates> {
    let (strip, gap, scale, delta) = (input.strip_width, input.gap, input.scale, input.delta);
    let unit = strip - gap;
    // `delta != 0` is true for NaN, as in Swift.
    let moves = delta.is_nan() || delta < 0.0 || delta > 0.0;
    let has_unit = unit > 0.0;
    if !(input.is_columns && has_unit && moves) {
        return None;
    }
    let pixel = if scale > 0.0 { scale } else { 1.0 };
    let widest = swift_max(1.0, strip - gap * 2.0);
    let ideal = |share: f64| pixel_width(share, strip, gap);
    let floor = |minimum: f64| {
        swift_max(
            ceil_to_pixel(swift_min(minimum, widest), scale),
            ceil_to_pixel(ideal(WIDTH_RANGE.0), scale),
        )
    };
    let mut most =
        swift_min(widest - input.left_width, input.right_width - floor(input.right_minimum_width));
    let mut least =
        -swift_min(input.left_width - floor(input.left_minimum_width), widest - input.right_width);
    if let Some(offset) = input.strip_offset {
        let leading = swift_max(0.0, input.uncovered_min_x - input.strip_min_x);
        let trailing = swift_max(0.0, input.strip_min_x + strip - input.uncovered_max_x);
        most = swift_min(most, offset + strip - trailing - input.right_min_x);
        least = swift_max(least, offset + leading - input.left_max_x);
    }
    let room = swift_max(0.0, if delta > 0.0 { most } else { -least });
    let pixels =
        swift_min((delta.abs() * unit * pixel).round(), (room * pixel + EDGE_TOLERANCE).floor());
    let moves_a_pixel = pixels > 0.0;
    if !moves_a_pixel {
        return None;
    }
    let move_points = (if delta > 0.0 { pixels } else { -pixels }) / pixel;
    let (left_shown, right_shown) =
        (input.left_width + move_points, input.right_width - move_points);
    let (left_ideal, right_ideal) = (ideal(input.left_fraction), ideal(input.right_fraction));
    let shift = (left_shown - left_ideal + right_ideal - right_shown) / 2.0;
    let kept = |width: f64| f64::from(fraction(width, strip, gap) as f32);
    Some(TradeCandidates {
        move_points,
        first: (kept(left_ideal + shift), kept(right_ideal - shift)),
        second: (kept(left_shown), kept(right_shown)),
    })
}

/// What a key press on a column's row edge reads.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RowInput<'a> {
    /// Every row's stored permille, top to bottom.
    pub heights: &'a [i64],
    /// Every row's minimum height in points, top to bottom (as many as `heights`).
    pub minimum_heights: &'a [f64],
    /// The row that holds the pane the press is on.
    pub pane_row: usize,
    pub rows_enabled: bool,
    pub column_height: f64,
    pub gap: f64,
    /// Device pixels per point.
    pub scale: f64,
    /// The press, a share of the column's height; down is positive.
    pub delta: f64,
}

/// Every row height of a column after a key press moves the row edge next to the pane's row (the edge below it, or
/// above it for the last row). A filled stack trades whole permille between the two rows; a scrolling stack sizes the
/// upper row alone. Each row keeps 100 permille and the height its tree needs. Writes the heights into `out` (as many
/// as the rows) and returns true; false when the press would move nothing or the input does not fit.
pub fn row_heights(input: &RowInput<'_>, out: &mut [i64]) -> bool {
    let rows = input.heights;
    let count = rows.len();
    let index = input.pane_row;
    if index >= count || input.minimum_heights.len() != count || out.len() != count {
        return false;
    }
    let Some(upper) = (if index + 1 < count { Some(index) } else { index.checked_sub(1) }) else {
        return false;
    };
    let height = |row: usize| rows.get(row).copied().unwrap_or(0);
    let sum = rows.iter().fold(0_i64, |sum, height| sum.saturating_add((*height).max(1)));
    let fills = !input.rows_enabled || sum <= 1000;
    // Permille as placed: a filled stack scales every row by 1000 / sum.
    let stack_scale = if fills && sum > 0 { sum as f64 / 1000.0 } else { 1.0 };
    let (pixel_scale, column_height, gap) = (input.scale, input.column_height, input.gap);
    // The largest stored permille at which the row still shows at its minimum height on the pixel grid.
    let floor = |row: usize| -> i64 {
        let minimum =
            ceil_to_pixel(input.minimum_heights.get(row).copied().unwrap_or(0.0), pixel_scale);
        let shown = |stored: i64| {
            round_to_pixel(
                row_pixel_height(stored as f64 / stack_scale, column_height, gap),
                pixel_scale,
            )
        };
        let exact = (minimum + gap) / (column_height + gap) * 1000.0 * stack_scale;
        let mut stored = (exact.floor() as i64).max(ROW_RANGE.0).min(ROW_RANGE.1);
        while stored > ROW_RANGE.0 && shown(stored) > minimum {
            stored -= 1;
        }
        while stored < ROW_RANGE.1 && shown(stored + 1) <= minimum {
            stored += 1;
        }
        stored
    };
    let step = (input.delta * 1000.0 * stack_scale).round() as i64;
    if step == 0 {
        return false;
    }
    let shown_upper = height(upper).max(floor(upper));
    // From where the row shows, one step toward the press, inside low...high; None when nothing would move. Each
    // direction checks only its own bound.
    let stepped = |low: i64, high: i64| -> Option<i64> {
        if step > 0 {
            let next = shown_upper.saturating_add(step).min(high);
            (next > shown_upper).then_some(next)
        } else {
            let next = shown_upper.saturating_add(step).max(low);
            (next < shown_upper).then_some(next)
        }
    };
    out.copy_from_slice(rows);
    if fills {
        let pair = height(upper).saturating_add(height(upper + 1));
        let low = floor(upper).max(pair.saturating_sub(ROW_RANGE.1));
        let high = pair.saturating_sub(floor(upper + 1)).min(ROW_RANGE.1);
        let Some(next) = stepped(low, high) else { return false };
        let Some([first, second]) = out.get_mut(upper..upper + 2) else { return false };
        *first = next;
        *second = pair.saturating_sub(next);
    } else {
        let rest = sum.saturating_sub(height(upper));
        let Some(next) = stepped(floor(upper).max(1000_i64.saturating_sub(rest)), ROW_RANGE.1)
        else {
            return false;
        };
        let Some(slot) = out.get_mut(upper) else { return false };
        *slot = next;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn trade_input(delta: f64) -> TradeInput {
        // Two half-strip columns on a 1000 pt strip with 8 pt gaps, at 2x, the camera at rest at 0.
        TradeInput {
            is_columns: true,
            strip_width: 1000.0,
            gap: 8.0,
            scale: 2.0,
            delta,
            left_min_x: 8.0,
            left_max_x: 500.0,
            left_width: 492.0,
            right_min_x: 508.0,
            right_max_x: 1000.0,
            right_width: 492.0,
            left_minimum_width: 200.0,
            right_minimum_width: 200.0,
            left_fraction: 0.5,
            right_fraction: 0.5,
            strip_offset: None,
            uncovered_min_x: 0.0,
            uncovered_max_x: 1000.0,
            strip_min_x: 0.0,
        }
    }

    #[test]
    fn swift_min_and_max_keep_the_first_value_on_a_tie_and_on_nan() {
        assert!(swift_min(f64::NAN, 1.0).is_nan());
        assert_eq!(swift_min(1.0, f64::NAN), 1.0);
        assert!(swift_max(f64::NAN, 1.0).is_nan());
        assert_eq!(swift_max(1.0, f64::NAN), 1.0);
        assert!(swift_max(-0.0, 0.0).is_sign_positive());
        assert!(swift_min(-0.0, 0.0).is_sign_negative());
    }

    #[test]
    fn a_ratio_needs_room_for_both_minimums() {
        assert_eq!(ratio(1001.0, 1.0, 200.0, 300.0), Some(Bounds { lower: 0.2, upper: 0.7 }));
        assert_eq!(ratio(1001.0, 1.0, 500.0, 500.0), Some(Bounds { lower: 0.5, upper: 0.5 }));
        assert_eq!(ratio(1001.0, 1.0, 500.0, 501.0), None);
        assert_eq!(ratio(1.0, 1.0, 0.0, 0.0), None);
        assert_eq!(ratio(f64::NAN, 1.0, 0.0, 0.0), None);
    }

    #[test]
    fn a_column_width_starts_at_its_minimum_and_a_docked_column_has_none() {
        let bounds = column_width(true, false, 1008.0, 192.0, 8.0).expect("strip column");
        assert_eq!(bounds, Bounds { lower: 0.2, upper: 1.0 });
        assert_eq!(column_width(true, true, 1008.0, 192.0, 8.0), None);
        assert_eq!(column_width(false, false, 1008.0, 192.0, 8.0), None);
        assert_eq!(column_width(true, false, 0.0, 192.0, 8.0), None);
        // A minimum wider than the strip keeps the widest share.
        assert_eq!(
            column_width(true, false, 1008.0, 5000.0, 8.0),
            Some(Bounds { lower: 1.0, upper: 1.0 })
        );
    }

    #[test]
    fn a_docked_dock_stops_at_the_room_the_strip_leaves() {
        let side =
            |is_target, is_docked, width| DockSide { is_target, is_band: false, is_docked, width };
        let alone = dock_width([side(true, true, 300.0)], 2000.0, 0.0, 200.0).expect("dock");
        assert_eq!(alone, Bounds { lower: 0.1, upper: 0.75 });
        // Two docked docks: each at most 40 %, and no wider than the window less 400 pt and the other dock.
        let both =
            dock_width([side(true, true, 300.0), side(false, true, 900.0)], 2000.0, 0.0, 200.0)
                .expect("dock");
        assert_eq!(both, Bounds { lower: 0.1, upper: 0.35 });
        let band = DockSide { is_target: true, is_band: true, is_docked: true, width: 300.0 };
        assert_eq!(dock_width([band], 2000.0, 0.0, 200.0), None);
        assert_eq!(dock_width([side(false, true, 300.0)], 2000.0, 0.0, 200.0), None);
    }

    #[test]
    fn a_trade_moves_whole_pixels_and_stops_at_a_minimum() {
        let right = trade(&trade_input(0.1)).expect("a press right");
        assert_eq!(right.move_points, 99.0);
        let left = trade(&trade_input(-0.1)).expect("a press left");
        assert_eq!(left.move_points, -99.0);
        // The right column can give at most 492 - 200 points.
        let far = trade(&trade_input(0.9)).expect("a press right to the minimum");
        assert_eq!(far.move_points, 292.0);
        let mut at_minimum = trade_input(0.1);
        at_minimum.right_width = 200.0;
        assert_eq!(trade(&at_minimum), None);
        assert_eq!(trade(&trade_input(0.0)), None);
        assert_eq!(trade(&trade_input(0.0001)), None);
    }

    #[test]
    fn a_trade_stays_in_the_part_of_the_strip_the_window_shows() {
        let mut input = trade_input(0.1);
        input.strip_offset = Some(0.0);
        input.uncovered_max_x = 950.0;
        // 50 points of cover at the window's trailing edge: the divider may go 442 points right, the minimum stops it first.
        let answer = trade(&input).expect("a press right");
        assert_eq!(answer.move_points, 99.0);
        input.delta = 0.9;
        assert_eq!(trade(&input).expect("the press that reaches the edge").move_points, 292.0);
        // 400 points of cover: the right column's leading edge (508) may go to 600, no further.
        input.uncovered_max_x = 600.0;
        assert_eq!(trade(&input).expect("the press that reaches the cover").move_points, 92.0);
    }

    #[test]
    fn a_trade_widths_are_what_the_daemon_keeps() {
        let answer = trade(&trade_input(0.1)).expect("a press right");
        for width in [answer.first.0, answer.first.1, answer.second.0, answer.second.1] {
            assert_eq!(f64::from(width as f32), width);
        }
    }

    fn rows(
        heights: &[i64],
        minimums: &[f64],
        pane_row: usize,
        rows_enabled: bool,
        delta: f64,
    ) -> Option<Vec<i64>> {
        let input = RowInput {
            heights,
            minimum_heights: minimums,
            pane_row,
            rows_enabled,
            column_height: 992.0,
            gap: 8.0,
            scale: 2.0,
            delta,
        };
        let mut out = vec![0; heights.len()];
        row_heights(&input, &mut out).then_some(out)
    }

    #[test]
    fn a_row_press_trades_permille_with_the_row_below_or_above_the_last() {
        assert_eq!(rows(&[500, 500], &[64.0, 64.0], 0, true, 0.1), Some(vec![600, 400]));
        assert_eq!(rows(&[500, 500], &[64.0, 64.0], 1, true, -0.1), Some(vec![400, 600]));
        // One row has no edge to move; a press of no whole permille moves nothing.
        assert_eq!(rows(&[1000], &[64.0], 0, true, 0.1), None);
        assert_eq!(rows(&[500, 500], &[64.0, 64.0], 0, true, 0.0004), None);
    }

    #[test]
    fn a_row_press_keeps_the_minimum_of_both_rows() {
        // The lower row needs 400 points: about 408 permille, so the upper row stops near 592.
        let grown = rows(&[500, 500], &[64.0, 400.0], 0, true, 0.5).expect("a press down");
        assert_eq!(grown[0] + grown[1], 1000);
        assert!(grown[1] >= 400, "{grown:?}");
        assert_eq!(rows(&grown, &[64.0, 400.0], 0, true, 0.1), None);
        // Up stops at the upper row's own minimum.
        let shrunk = rows(&[500, 500], &[300.0, 64.0], 0, true, -0.5).expect("a press up");
        assert!(shrunk[0] >= 300, "{shrunk:?}");
    }

    #[test]
    fn a_scrolling_stack_sizes_the_upper_row_alone() {
        // 700 + 700 is a scrolling stack (rows enabled, over 1000): the press sizes the upper row only.
        assert_eq!(rows(&[700, 700], &[64.0, 64.0], 0, true, 0.1), Some(vec![800, 700]));
        // Never below the sum that fills the column: 1000 - 700.
        assert_eq!(rows(&[700, 700], &[64.0, 64.0], 0, true, -0.5), Some(vec![300, 700]));
        // With rows off the stack fills: the pair trades, in permille scaled by 1400 / 1000.
        assert_eq!(rows(&[700, 700], &[64.0, 64.0], 0, false, 0.1), Some(vec![840, 560]));
    }

    #[test]
    fn a_row_input_that_does_not_fit_moves_nothing() {
        let input = RowInput {
            heights: &[500, 500],
            minimum_heights: &[64.0],
            pane_row: 0,
            rows_enabled: true,
            column_height: 992.0,
            gap: 8.0,
            scale: 2.0,
            delta: 0.1,
        };
        assert!(!row_heights(&input, &mut [0, 0]));
        let input = RowInput { minimum_heights: &[64.0, 64.0], pane_row: 2, ..input };
        assert!(!row_heights(&input, &mut [0, 0]));
        let input = RowInput { pane_row: 0, ..input };
        assert!(!row_heights(&input, &mut [0]));
    }
}
