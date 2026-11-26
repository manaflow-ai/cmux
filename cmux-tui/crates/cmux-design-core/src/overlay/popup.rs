//! The native popup's pure rules: the columns layout and its arrow keys
//! (NativePopupContent+Columns.swift), the row order (NativePopupModel+Rows.swift), the
//! press-drag-release gesture (PopupPressRelease.swift), the menu tracking confinement
//! (MenuTrackingConfinement.swift) and the pointer menu's placement choice (WebContextMenu.swift).

use serde::{Deserialize, Serialize};

/// A `CGRect` in the popup content's flipped coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Rect { x, y, width, height }
    }

    fn max_x(self) -> f64 {
        self.x + self.width
    }

    fn max_y(self) -> f64 {
        self.y + self.height
    }

    /// `CGRect.isEmpty`: zero (or negative) width or height.
    pub fn is_empty(self) -> bool {
        self.width <= 0.0 || self.height <= 0.0
    }

    /// `CGRect.intersection`: the overlap, or `None` where `CGRect.null` would come back.
    pub fn intersection(self, other: Rect) -> Option<Rect> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let max_x = self.max_x().min(other.max_x());
        let max_y = self.max_y().min(other.max_y());
        if max_x < x || max_y < y {
            return None;
        }
        Some(Rect::new(x, y, max_x - x, max_y - y))
    }
}

/// `NativePopupRowKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RowKind {
    Action,
    Toggle,
    Choice,
    Section,
    Separator,
    Text,
    Slider,
    Submenu,
    TextField,
}

impl RowKind {
    /// `NativePopupRow.isNoninteractive`.
    pub fn is_noninteractive(self) -> bool {
        matches!(self, Self::Section | Self::Separator | Self::Text)
    }
}

/// `columnsSearchRow`: a 28 pt field with a 4 pt band above and below.
pub const COLUMNS_SEARCH_ROW: f64 = 36.0;
/// `columnsDefaultHeight`: the band's cap when the page names none.
pub const COLUMNS_DEFAULT_HEIGHT: f64 = 220.0;
/// The accessory's column width when there are no columns (`columns.first?.width ?? 48`).
pub const DEFAULT_LEAD: f64 = 48.0;

/// `NativePopupContent.height(of:view:)`: a slider's own height, else 9 for a separator, 32 for
/// a text field, 44 for a row with a caption, else the standard row height.
pub fn row_height(
    kind: RowKind,
    has_caption: bool,
    slider_height: Option<f64>,
    standard_row_height: f64,
) -> f64 {
    if let Some(height) = slider_height {
        return height;
    }
    match kind {
        RowKind::Separator => 9.0,
        RowKind::TextField => 32.0,
        _ if has_caption => 44.0,
        _ => standard_row_height,
    }
}

/// A row the layout places: its id and its height (from [`row_height`]).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaidRow {
    pub id: String,
    pub height: f64,
}

/// A column to lay out: its fixed width (absent: a share of what is left), whether its rows are
/// rail tabs, and its rows.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaidColumn {
    #[serde(default)]
    pub width: Option<f64>,
    #[serde(default)]
    pub rail: bool,
    #[serde(default)]
    pub rows: Vec<LaidRow>,
}

/// The inputs of `layoutColumns(title:search:)`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnsInput {
    pub width: f64,
    /// `PopupStyle.standard.padding`.
    pub inset: f64,
    /// `Metrics.lineWidth(0.5)`.
    pub hairline: f64,
    /// `PopupStyle.standard.rowHeight`: a rail tab's side.
    pub row_height: f64,
    /// `Metrics.space1`: the gap under a rail tab.
    pub space1: f64,
    #[serde(default)]
    pub has_title: bool,
    #[serde(default)]
    pub has_search: bool,
    #[serde(default)]
    pub has_accessory: bool,
    #[serde(default)]
    pub rows: Vec<LaidRow>,
    #[serde(default)]
    pub columns: Vec<LaidColumn>,
    #[serde(default)]
    pub footer: Vec<LaidRow>,
    /// `model.columnsHeight`: the band's cap.
    #[serde(default)]
    pub columns_height: Option<f64>,
    /// `columnsBandFloor`: the band's height so far (it never shrinks while open).
    #[serde(default)]
    pub band_floor: f64,
}

/// A placed row.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Placed {
    pub id: String,
    pub frame: Rect,
}

/// A placed column: its scroll view's frame, its document's frame and its cells (in the
/// document's coordinates).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlacedColumn {
    pub frame: Rect,
    pub document: Rect,
    pub cells: Vec<Placed>,
}

/// What `layoutColumns` sets.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnsLayout {
    pub title: Option<Rect>,
    pub accessory: Option<Rect>,
    pub search: Option<Rect>,
    pub rows: Vec<Placed>,
    pub columns: Vec<PlacedColumn>,
    pub footer: Vec<Placed>,
    /// One hairline per rect.
    pub lines: Vec<Rect>,
    /// The new `columnsBandFloor`.
    pub band_floor: f64,
    /// The content height.
    pub height: f64,
}

/// `layoutColumns(title:search:)`: the search row (the accessory over the first column), the
/// spanning rows, the columns side by side (as tall as the tallest, up to the cap, never shorter
/// than before), then the footer, with a hairline between each.
pub fn layout_columns(input: &ColumnsInput) -> ColumnsLayout {
    let width = input.width;
    let inset = input.inset;
    let hairline = input.hairline;
    let mut lines = Vec::new();
    let mut y = 0.0;
    let mut title = None;
    if input.has_title {
        title = Some(Rect::new(inset + 7.0, inset, (width - inset * 2.0 - 14.0).max(0.0), 24.0));
        y = inset + 24.0;
    }
    let row = COLUMNS_SEARCH_ROW;
    let lead = if input.has_accessory {
        input.columns.first().and_then(|c| c.width).unwrap_or(DEFAULT_LEAD)
    } else {
        inset
    };
    let mut accessory = None;
    if input.has_accessory {
        let side = input.row_height;
        accessory = Some(Rect::new((lead - side) / 2.0, y + (row - side) / 2.0, side, side));
        lines.push(Rect::new(lead - hairline, y, hairline, row));
    }
    let search = input.has_search.then(|| {
        Rect::new(lead + 4.0, y + (row - 28.0) / 2.0, (width - lead - inset - 8.0).max(0.0), 28.0)
    });
    y += row;
    lines.push(Rect::new(0.0, y, width, hairline));
    y += hairline;
    let mut rows = Vec::new();
    if !input.rows.is_empty() {
        for spanning in &input.rows {
            rows.push(Placed {
                id: spanning.id.clone(),
                frame: Rect::new(inset, y, (width - inset * 2.0).max(0.0), spanning.height),
            });
            y += spanning.height;
        }
        lines.push(Rect::new(0.0, y, width, hairline));
        y += hairline;
    }
    let fixed: f64 = input.columns.iter().filter_map(|c| c.width).sum();
    let flexible = input.columns.iter().filter(|c| c.width.is_none()).count();
    let rest = if flexible > 0 { ((width - fixed) / flexible as f64).max(0.0) } else { 0.0 };
    let mut heights = Vec::new();
    let mut cells_by_column = Vec::new();
    for column in &input.columns {
        let mut cursor = inset;
        let column_width = column.width.unwrap_or(rest);
        let mut cells = Vec::new();
        for item in &column.rows {
            let frame = if column.rail {
                let side = input.row_height;
                let frame = Rect::new((column_width - side) / 2.0, cursor, side, side);
                cursor += side + input.space1;
                frame
            } else {
                let frame =
                    Rect::new(inset, cursor, (column_width - inset * 2.0).max(0.0), item.height);
                cursor += item.height;
                frame
            };
            cells.push(Placed { id: item.id.clone(), frame });
        }
        heights.push(cursor + inset);
        cells_by_column.push(cells);
    }
    let cap = input.columns_height.unwrap_or(COLUMNS_DEFAULT_HEIGHT);
    let tallest =
        heights.iter().copied().fold(None, |acc: Option<f64>, h| Some(acc.map_or(h, |a| a.max(h))));
    let band = cap.min(input.band_floor.max(tallest.unwrap_or(0.0)));
    let mut columns = Vec::new();
    let mut x = 0.0;
    let count = input.columns.len();
    for (index, (column, cells)) in input.columns.iter().zip(cells_by_column).enumerate() {
        let column_width = column.width.unwrap_or(rest);
        columns.push(PlacedColumn {
            frame: Rect::new(x, y, column_width, band),
            document: Rect::new(0.0, 0.0, column_width, band.max(heights[index])),
            cells,
        });
        x += column_width;
        if index + 1 < count {
            lines.push(Rect::new(x - hairline, y, hairline, band));
        }
    }
    y += band;
    let mut footer = Vec::new();
    if !input.footer.is_empty() {
        lines.push(Rect::new(0.0, y, width, hairline));
        y += hairline;
        for item in &input.footer {
            footer.push(Placed {
                id: item.id.clone(),
                frame: Rect::new(inset, y, (width - inset * 2.0).max(0.0), item.height),
            });
            y += item.height;
        }
        y += inset;
    }
    ColumnsLayout {
        title,
        accessory,
        search,
        rows,
        columns,
        footer,
        lines,
        band_floor: band,
        height: y,
    }
}

/// A row the arrow keys may weigh.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyRow {
    pub id: String,
    pub kind: RowKind,
    #[serde(default)]
    pub disabled: bool,
    #[serde(default)]
    pub checked: bool,
}

/// A column the arrow keys move among.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyColumn {
    #[serde(default)]
    pub rail: bool,
    #[serde(default)]
    pub rows: Vec<KeyRow>,
}

/// `enabledRows` within a column: interactive, enabled and not the search accessory.
fn reachable<'a>(column: &'a KeyColumn, accessory: Option<&str>) -> Vec<&'a KeyRow> {
    column
        .rows
        .iter()
        .filter(|r| !r.kind.is_noninteractive() && !r.disabled && Some(r.id.as_str()) != accessory)
        .collect()
}

/// The left, right, down and up arrow key codes.
pub const KEY_LEFT: u16 = 123;
pub const KEY_RIGHT: u16 = 124;
pub const KEY_DOWN: u16 = 125;
pub const KEY_UP: u16 = 126;

/// `firstListColumnRowID`: the first reachable row of the first column that is not a rail.
pub fn first_list_column_row(columns: &[KeyColumn], accessory: Option<&str>) -> Option<String> {
    let start = columns.iter().position(|c| !c.rail).unwrap_or(0);
    columns.get(start).and_then(|c| reachable(c, accessory).first().map(|r| r.id.clone()))
}

/// What an arrow key does in the columns layout.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "outcome")]
pub enum ColumnKey {
    /// Not an arrow, or no columns: the key falls through (`nil`).
    Unhandled,
    /// Handled, the highlight stays.
    Stays,
    /// Handled, the highlight moves to `id` (the content emits `highlight`).
    Moves { id: String },
}

/// `handleColumnKey(_:)`: Up and Down stay in the highlighted row's column and stop at its ends;
/// Left and Right move to the nearest column that way with a reachable row, onto its checked
/// row, else its first.
pub fn column_key(
    columns: &[KeyColumn],
    accessory: Option<&str>,
    selected: Option<&str>,
    key: u16,
) -> ColumnKey {
    if columns.is_empty() || !(KEY_LEFT..=KEY_UP).contains(&key) {
        return ColumnKey::Unhandled;
    }
    let home = columns.iter().position(|c| !c.rail).unwrap_or(0);
    let current = selected
        .and_then(|id| columns.iter().position(|c| c.rows.iter().any(|r| r.id == id)))
        .unwrap_or(home);
    let next = if key == KEY_LEFT || key == KEY_RIGHT {
        let toward: Vec<usize> = if key == KEY_RIGHT {
            (current + 1..columns.len()).collect()
        } else {
            (0..current).rev().collect()
        };
        let Some(target) =
            toward.into_iter().find(|&i| !reachable(&columns[i], accessory).is_empty())
        else {
            return ColumnKey::Stays;
        };
        let rows = reachable(&columns[target], accessory);
        rows.iter().find(|r| r.checked).or(rows.first()).map(|r| r.id.clone())
    } else {
        let rows = reachable(&columns[current], accessory);
        if rows.is_empty() {
            return ColumnKey::Stays;
        }
        let down = key == KEY_DOWN;
        let index = match rows.iter().position(|r| Some(r.id.as_str()) == selected) {
            Some(at) => {
                let moved = at as i64 + if down { 1 } else { -1 };
                moved.clamp(0, rows.len() as i64 - 1) as usize
            }
            None if down => 0,
            None => rows.len() - 1,
        };
        Some(rows[index].id.clone())
    };
    match next {
        Some(id) if Some(id.as_str()) != selected => ColumnKey::Moves { id },
        _ => ColumnKey::Stays,
    }
}

/// The top-level row lists of a popup model, by id.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RowLists {
    pub rail: Option<Vec<String>>,
    pub search_accessory: Option<String>,
    pub rows: Vec<String>,
    pub columns: Option<Vec<Vec<String>>>,
    pub footer: Option<Vec<String>>,
}

impl RowLists {
    /// `allRows`: the rail, the accessory, the rows, each column's rows, then the footer.
    pub fn all_rows(&self) -> Vec<String> {
        let mut all = Vec::new();
        all.extend(self.rail.iter().flatten().cloned());
        all.extend(self.search_accessory.iter().cloned());
        all.extend(self.rows.iter().cloned());
        all.extend(self.columns.iter().flatten().flatten().cloned());
        all.extend(self.footer.iter().flatten().cloned());
        all
    }

    /// `hasColumns`: the popup lays out as columns.
    pub fn has_columns(&self) -> bool {
        self.columns.as_ref().is_some_and(|c| !c.is_empty())
    }
}

/// `PopupPressRelease.clickTime`: a release this soon after the press is a click.
pub const PRESS_CLICK_TIME: f64 = 0.15;
/// `PopupPressRelease.slop`: points the pointer moves before the press counts as a drag.
pub const PRESS_SLOP: f64 = 4.0;

/// A point.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// Whether the press has moved: once moved it stays moved, else `point` is at least the slop
/// away from `start`.
pub fn press_moved(already: bool, start: Point, point: Point) -> bool {
    already || (point.x - start.x).hypot(point.y - start.y) >= PRESS_SLOP
}

/// What a release did (`PopupPressRelease.Outcome`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PressOutcome {
    /// A row picked: try it, and if it refuses, fall to the next rule.
    Picks,
    /// The popup closes.
    Closes,
    /// Nothing: a click, the popup stays.
    None,
}

/// The release decision given whether the press moved (with the release point counted), the
/// time held and whether an enabled row under the pointer took the release.
pub fn press_released(moved: bool, held_for: f64, row_picked: bool) -> PressOutcome {
    let held = held_for >= PRESS_CLICK_TIME;
    if (moved || held) && row_picked {
        PressOutcome::Picks
    } else if moved && held {
        PressOutcome::Closes
    } else {
        PressOutcome::None
    }
}

/// Whether a release is allowed to try the row under it: after a drag or a held press.
pub fn press_may_pick(moved: bool, held_for: f64) -> bool {
    moved || held_for >= PRESS_CLICK_TIME
}

/// `MenuTrackingConfinement.confinementRect`: the bounds, or within the original delegate's
/// non-empty rect, their overlap (the original's rect when they do not overlap).
pub fn confinement_rect(bounds: Rect, previous: Option<Rect>) -> Rect {
    let Some(previous) = previous.filter(|p| !p.is_empty()) else {
        return bounds;
    };
    match previous.intersection(bounds) {
        Some(overlap) if !overlap.is_empty() => overlap,
        _ => previous,
    }
}

/// `NSMenu.popUpAtPointer`'s rules: whether tracking is confined to the viewport (the menu is
/// taller or wider than it), and the corner AppKit puts at the point (top-trailing in RTL,
/// top-leading otherwise) of the placed frame (unflipped screen coordinates).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PointerMenu {
    pub confines: bool,
    pub corner: Point,
}

/// See [`PointerMenu`].
pub fn pointer_menu(
    frame: Rect,
    menu_width: f64,
    menu_height: f64,
    viewport: Rect,
    rtl: bool,
) -> PointerMenu {
    PointerMenu {
        confines: menu_height > viewport.height || menu_width > viewport.width,
        corner: Point { x: if rtl { frame.max_x() } else { frame.x }, y: frame.max_y() },
    }
}
