//! A tab strip's geometry: how the strip's tabs share its width (pinned tabs, content-sized
//! chips, collapsed members, Full Width Tab mode, closing mode), the same layout at a new width,
//! where a dropped tab lands, how the strip scrolls with its pinned band, which parts of a tab
//! show at a width (its icon, title and x, and along a width path), and the vertical tab list's
//! rows and drop slots. The macOS strip (`TabLayoutEngine`, `TabReorderMath`, `TabScrollMath`,
//! `TabScrollMapping`, `TabChromeVisibility`, `VerticalTabListLayout`) asks these over the JSON
//! channel (ops `tab_layout_*`) and sends its metrics as numbers; it keeps the drawing.

use serde::{Deserialize, Serialize};

// MARK: Metrics

/// Where a titled tab's trailing status mark sits (`TabStatusMarkPlacement`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StatusMarkPlacement {
    /// Centered in the x's slot.
    CloseSlot,
    /// Mirrors the icon; the hovered x keeps its own place.
    #[default]
    MirrorIcon,
    /// The mark and the hovered x both mirror the icon.
    MirrorAll,
}

/// The strip sizes the rules read (`TabStripMetrics`), as the strip resolved them.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    pub max_tab_width: f64,
    pub min_inactive_tab_width: f64,
    pub min_active_tab_width: f64,
    pub pinned_tab_width: f64,
    pub compact_tab_width: f64,
    pub pinned_group_gap: f64,
    /// Chrome's own inactive minimum (`metrics.chrome.minInactiveWidth`).
    pub chrome_min_inactive_width: f64,
    pub close_min_contents_width: f64,
    pub title_min_visible_width: f64,
    pub content_leading_inset: f64,
    pub content_trailing_inset: f64,
    pub icon_size: f64,
    pub close_button_size: f64,
    pub icon_title_spacing: f64,
    pub title_close_spacing: f64,
    #[serde(default)]
    pub status_mark_placement: StatusMarkPlacement,
}

impl Metrics {
    /// The status slot's center in a pill `pill_width` wide: the x's own center, or the icon's
    /// center mirrored at the trailing end, never nearer the end than the x's.
    pub fn status_slot_mid_x(&self, pill_width: f64, placement: StatusMarkPlacement) -> f64 {
        let close_mid_x = pill_width - self.content_trailing_inset - self.close_button_size / 2.0;
        if placement == StatusMarkPlacement::CloseSlot {
            return close_mid_x;
        }
        close_mid_x.min(pill_width - self.content_leading_inset - self.icon_size / 2.0)
    }
}

/// `TabStripStyle`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Style {
    #[default]
    Chrome,
    Compact,
}

// MARK: Horizontal layout

/// One tab (or chip, or drop gap) as layout sees it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub selected: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    /// Content-sized items (group chips, a group-sized drop gap) keep this width.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fixed_width: Option<f64>,
    /// Member of a collapsed group: zero width, behind its chip.
    #[serde(default)]
    pub collapsed: bool,
    #[serde(default)]
    pub group_chip: bool,
}

/// A laid out item, in content coordinates (0 is the leading edge of the first tab).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Slot {
    pub id: String,
    pub x: f64,
    pub width: f64,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    #[serde(default)]
    pub group_chip: bool,
    #[serde(default)]
    pub collapsed: bool,
    /// It shares the row's width with the other flexible tabs.
    #[serde(default)]
    pub flexible: bool,
}

impl Slot {
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
}

/// How the flexible tabs of a row share its width (`TabRowShare`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Share {
    /// No flexible tab.
    #[default]
    None,
    /// Every flexible tab this wide.
    Each { width: f64 },
    /// One flexible tab, narrower than its widest.
    Alone { width: f64 },
    /// Each tab `base` wide, the first `extra` one point wider.
    Split { base: f64, extra: usize },
    /// Full Width Tab mode: the tab spans this width.
    FullWidth { width: f64 },
}

impl Share {
    /// The width of the flexible tab at `index` (leading first).
    pub fn width(&self, index: usize) -> f64 {
        match *self {
            Share::None => 0.0,
            Share::Each { width } | Share::Alone { width } | Share::FullWidth { width } => width,
            Share::Split { base, extra } => {
                if index < extra {
                    base + 1.0
                } else {
                    base
                }
            }
        }
    }

    /// The width of an inactive flexible tab (the last one's): 0 with none.
    pub fn standard_width(&self, count: usize) -> f64 {
        match *self {
            Share::None => 0.0,
            // The last index is -1 with no flexible tab: below every `extra`, as the app's index.
            Share::Split { base, .. } if count == 0 => base + 1.0,
            _ => self.width(count.saturating_sub(1)),
        }
    }
}

/// The strip's layout (`TabLayoutResult`).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LayoutResult {
    pub slots: Vec<Slot>,
    /// Total width of all tabs, including the pinned group gap.
    pub content_width: f64,
    /// Width given to an inactive unpinned tab (0 when there are none).
    pub standard_width: f64,
    /// The width tabs were allowed to fill.
    pub available_width: f64,
    #[serde(default)]
    pub share: Share,
    #[serde(default)]
    pub flexible_count: usize,
    /// The row's width the flexible tabs did not share.
    #[serde(default)]
    pub reserved_width: f64,
}

impl LayoutResult {
    pub fn is_overflowing(&self) -> bool {
        self.content_width > self.available_width + 0.5
    }

    pub fn slot(&self, id: &str) -> Option<&Slot> {
        self.slots.iter().find(|slot| slot.id == id)
    }
}

/// The width the strip may fill: `available_width`, no wider than closing mode's pretend width.
fn allowed(available_width: f64, closing_mode_width: Option<f64>) -> f64 {
    let available =
        closing_mode_width.map_or(available_width, |closing| available_width.min(closing));
    available.max(0.0)
}

/// Lays out `items` in order (`TabLayoutEngine.layout`). `closing_mode_width` is the deferred
/// relayout while the user closes tabs with the mouse; `full_width_tab` fills the whole strip
/// and collapses every other item.
pub fn layout(
    items: &[Item],
    available_width: f64,
    style: Style,
    metrics: &Metrics,
    closing_mode_width: Option<f64>,
    full_width_tab: Option<&str>,
) -> LayoutResult {
    let available = allowed(available_width, closing_mode_width);
    if let Some(tab) = full_width_tab
        && items.iter().any(|item| item.id == tab && !item.group_chip)
    {
        return full_width_layout(items, tab, available);
    }
    let pinned_count = items.iter().filter(|item| item.pinned).count();
    let unpinned: Vec<&Item> = items.iter().filter(|item| !item.pinned).collect();
    let flexible_count =
        unpinned.iter().filter(|item| item.fixed_width.is_none() && !item.collapsed).count();
    let fixed_total = unpinned.iter().fold(0.0, |total, item| {
        total + if item.collapsed { 0.0 } else { item.fixed_width.unwrap_or(0.0) }
    });
    let gap = if pinned_count > 0 && !unpinned.is_empty() { metrics.pinned_group_gap } else { 0.0 };
    let reserved = pinned_count as f64 * metrics.pinned_tab_width + gap + fixed_total;
    let share = row_share(flexible_count, (available - reserved).max(0.0), style, metrics);

    let mut slots = Vec::with_capacity(items.len());
    let mut x = 0.0;
    let mut flexible_index = 0;
    let mut previous_was_pinned = false;
    for item in items {
        if !item.pinned && previous_was_pinned {
            x += metrics.pinned_group_gap;
        }
        let width = if item.pinned {
            metrics.pinned_tab_width
        } else if item.collapsed {
            0.0
        } else if let Some(fixed) = item.fixed_width {
            fixed
        } else {
            let width = share.width(flexible_index);
            flexible_index += 1;
            width
        };
        slots.push(Slot {
            id: item.id.clone(),
            x,
            width,
            pinned: item.pinned,
            group: item.group.clone(),
            group_chip: item.group_chip,
            collapsed: item.collapsed,
            flexible: !item.pinned && !item.collapsed && item.fixed_width.is_none(),
        });
        x += width;
        previous_was_pinned = item.pinned;
    }
    LayoutResult {
        slots,
        content_width: x,
        standard_width: share.standard_width(flexible_count),
        available_width: available,
        share,
        flexible_count,
        reserved_width: reserved,
    }
}

/// `result` laid out again at `available_width`, every other input as it was
/// (`TabLayoutEngine.resized`): equal to [`layout`] with `result`'s items at that width.
pub fn resized(
    result: &LayoutResult,
    available_width: f64,
    style: Style,
    metrics: &Metrics,
    closing_mode_width: Option<f64>,
) -> LayoutResult {
    let available = allowed(available_width, closing_mode_width);
    if let Share::FullWidth { .. } = result.share {
        let mut passed = false;
        let mut resized = result.clone();
        for slot in &mut resized.slots {
            if slot.collapsed {
                slot.x = if passed { available } else { 0.0 };
            } else {
                passed = true;
                slot.width = available;
            }
        }
        resized.content_width = available;
        resized.standard_width = available;
        resized.available_width = available;
        resized.share = Share::FullWidth { width: available };
        return resized;
    }
    let share = row_share(
        result.flexible_count,
        (available - result.reserved_width).max(0.0),
        style,
        metrics,
    );
    let mut resized = result.clone();
    resized.available_width = available;
    if share == result.share {
        return resized;
    }
    resized.share = share;
    resized.standard_width = share.standard_width(result.flexible_count);
    let mut x = 0.0;
    let mut flexible_index = 0;
    let mut previous_was_pinned = false;
    for slot in &mut resized.slots {
        if !slot.pinned && previous_was_pinned {
            x += metrics.pinned_group_gap;
        }
        slot.x = x;
        if slot.flexible {
            slot.width = share.width(flexible_index);
            flexible_index += 1;
        }
        x += slot.width;
        previous_was_pinned = slot.pinned;
    }
    resized.content_width = x;
    resized
}

/// `tab` across the whole strip; the rest collapse at its leading or trailing edge.
fn full_width_layout(items: &[Item], tab: &str, available: f64) -> LayoutResult {
    let mut passed = false;
    let slots = items
        .iter()
        .map(|item| {
            if item.id != tab {
                return Slot {
                    id: item.id.clone(),
                    x: if passed { available } else { 0.0 },
                    width: 0.0,
                    pinned: false,
                    group: item.group.clone(),
                    group_chip: item.group_chip,
                    collapsed: true,
                    flexible: false,
                };
            }
            passed = true;
            // Not pinned in the slot: a pinned tab here is no fixed band, it is the whole strip.
            Slot {
                id: item.id.clone(),
                x: 0.0,
                width: available,
                group: item.group.clone(),
                ..Slot::default()
            }
        })
        .collect();
    LayoutResult {
        slots,
        content_width: available,
        standard_width: available,
        available_width: available,
        share: Share::FullWidth { width: available },
        flexible_count: 0,
        reserved_width: 0.0,
    }
}

/// How `count` flexible tabs share `available` (the row less the pinned tabs and the
/// content-sized items).
pub fn row_share(count: usize, available: f64, style: Style, metrics: &Metrics) -> Share {
    if count == 0 {
        return Share::None;
    }
    if style == Style::Compact {
        return Share::Each { width: metrics.compact_tab_width };
    }
    let ideal = available / count as f64;
    if ideal >= metrics.max_tab_width {
        return Share::Each { width: metrics.max_tab_width };
    }
    // Crowded: every tab shrinks evenly down to the inactive minimum, then the strip scrolls; the
    // selected tab gets no larger share, so a selection never moves or resizes a tab.
    if count == 1 {
        return Share::Alone { width: ideal.floor().max(metrics.min_active_tab_width) };
    }
    if ideal >= metrics.min_inactive_tab_width {
        let (base, extra) = split(available, count);
        return Share::Split { base, extra };
    }
    Share::Each { width: metrics.min_inactive_tab_width }
}

/// `total` in `count` whole points: each part `base`, the first `extra` one point wider.
pub fn split(total: f64, count: usize) -> (f64, usize) {
    if count == 0 || !total.is_finite() || total <= 0.0 {
        return (0.0, 0);
    }
    let base = (total / count as f64).floor();
    let extra = (total - base * count as f64).floor();
    (base, (extra.max(0.0) as usize).min(count))
}

/// `total` in `count` whole-point widths, the leftover points on the leading ones.
pub fn distribute(total: f64, count: usize) -> Vec<f64> {
    let (base, extra) = split(total, count);
    (0..count).map(|index| if index < extra { base + 1.0 } else { base }).collect()
}

/// The closing-mode width after the user closes `closing` with the mouse: closing any tab but
/// the last shrinks the pretend strip by the closed tab (and the pinned gap when the last pinned
/// tab goes), so the right neighbor slides under the pointer; the last keeps `current`.
pub fn closing_mode_width(
    closing: &str,
    result: &LayoutResult,
    current: Option<f64>,
) -> Option<f64> {
    let count = result.slots.len();
    let Some(index) = result.slots.iter().position(|slot| slot.id == closing) else {
        return current;
    };
    if count <= 1 || index >= count - 1 {
        return current;
    }
    let last = &result.slots[count - 1];
    let closed = &result.slots[index];
    let mut width = last.max_x() - closed.width;
    let pinned_count = result.slots.iter().filter(|slot| slot.pinned).count();
    let has_unpinned = result.slots.iter().any(|slot| !slot.pinned);
    if closed.pinned && pinned_count == 1 && has_unpinned {
        // The pinned group disappears, and its gap with it.
        width -= result.slots[index + 1].x - closed.max_x();
    }
    Some(current.map_or(width, |current| current.min(width)))
}

/// `items` with a drop gap before the `tab_index`-th tab (chips do not count): before that tab's
/// chip unless the gap joins that tab's group.
pub fn insert_placeholder(items: &mut Vec<Item>, placeholder: Item, tab_index: usize) {
    let mut seen = 0;
    let mut position = items.len();
    for (offset, item) in items.iter().enumerate() {
        if item.group_chip {
            continue;
        }
        if seen == tab_index {
            position = offset;
            break;
        }
        seen += 1;
    }
    if position > 0
        && items[position - 1].group_chip
        && items[position - 1].group != placeholder.group
    {
        position -= 1;
    }
    items.insert(position, placeholder);
}

// MARK: Reorder

/// Where a dragged tab lands among `other_widths` (its group's tabs in order, without it): the
/// slot whose leading edge is nearest the dragged tab's leading edge, the first on a tie.
pub fn insertion_index(dragged_min_x: f64, group_start: f64, other_widths: &[f64]) -> usize {
    let mut best = 0;
    let mut best_distance = f64::INFINITY;
    let mut edge = group_start;
    for index in 0..=other_widths.len() {
        let distance = (edge - dragged_min_x).abs();
        if distance < best_distance {
            best_distance = distance;
            best = index;
        }
        if let Some(width) = other_widths.get(index) {
            edge += width;
        }
    }
    best
}

// MARK: Scroll

pub fn max_offset(content_width: f64, viewport_width: f64) -> f64 {
    (content_width - viewport_width).max(0.0)
}

pub fn clamp_offset(offset: f64, content_width: f64, viewport_width: f64) -> f64 {
    offset.max(0.0).min(max_offset(content_width, viewport_width))
}

/// The smallest scroll change that shows `slot` whole, `margin` (the fade) from a scrolled edge.
/// `fixed_leading` is the pinned band: a pinned tab in it is always in view, and an unpinned tab
/// shows from the band's trailing edge on.
pub fn offset_revealing(
    slot: &Slot,
    current: f64,
    content_width: f64,
    viewport_width: f64,
    margin: f64,
    fixed_leading: f64,
) -> f64 {
    if slot.pinned && fixed_leading > 0.0 {
        return clamp_offset(current, content_width, viewport_width);
    }
    let mut offset = current;
    let leading = slot.x - if slot.x > fixed_leading { margin } else { 0.0 };
    let trailing = slot.max_x() + if slot.max_x() < content_width { margin } else { 0.0 };
    if trailing - offset > viewport_width {
        offset = trailing - viewport_width;
    }
    if leading - fixed_leading < offset {
        offset = leading - fixed_leading;
    }
    clamp_offset(offset, content_width, viewport_width)
}

/// Which edges fade: an edge with more than half a point of tabs hidden beyond it, the offset
/// clamped first so a rubber band never flashes a fade.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FadedEdges {
    pub leading: bool,
    pub trailing: bool,
}

pub fn faded_edges(offset: f64, content_width: f64, viewport_width: f64) -> FadedEdges {
    let maximum = max_offset(content_width, viewport_width);
    let clamped = clamp_offset(offset, content_width, viewport_width);
    FadedEdges { leading: clamped > 0.5, trailing: clamped < maximum - 0.5 }
}

/// Where the strip shows its tabs for a scroll offset (`TabScrollMapping`): the pinned tabs and
/// their gap are a band fixed at the leading edge; only the unpinned tabs scroll.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ScrollMapping {
    /// Width of the fixed band, pinned tabs plus gap; 0 when nothing is fixed.
    pub band: f64,
    /// The strip's scroll offset, which the unpinned tabs take.
    pub offset: f64,
}

impl ScrollMapping {
    /// The band for `result`: the first unpinned slot's x after leading pinned tabs, unless that
    /// leaves the unpinned tabs less than `minimum_scrollable` of `viewport_width` (or there is
    /// no unpinned tab): then the whole strip scrolls.
    pub fn new(
        result: &LayoutResult,
        viewport_width: f64,
        minimum_scrollable: f64,
        offset: f64,
    ) -> Self {
        let mut fixed = 0.0;
        if result.slots.first().is_some_and(|slot| slot.pinned)
            && let Some(first) = result.slots.iter().find(|slot| !slot.pinned)
        {
            fixed = first.x;
        }
        let band =
            if fixed > 0.0 && fixed + minimum_scrollable <= viewport_width { fixed } else { 0.0 };
        Self { band, offset }
    }

    /// The offset a tab in that region takes: 0 for a fixed pinned tab.
    pub fn offset_for(&self, pinned: bool) -> f64 {
        if pinned && self.band > 0.0 { 0.0 } else { self.offset }
    }

    pub fn view_x(&self, content_x: f64, pinned: bool) -> f64 {
        content_x - self.offset_for(pinned)
    }

    pub fn content_x(&self, view_x: f64, pinned: bool) -> f64 {
        view_x + self.offset_for(pinned)
    }

    /// Whether an unpinned tab can show (or be hit) at clip x `view_x`: not under the band.
    pub fn shows_unpinned(&self, view_x: f64) -> bool {
        view_x >= self.band
    }
}

// MARK: Chrome visibility

/// Which parts of a tab show at a width and state (`TabChromeVisibility`, Chromium's
/// `Tab::UpdateIconVisibility` with cmux's pinned, hover and status rules).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Visibility {
    pub shows_icon: bool,
    pub shows_title: bool,
    pub shows_close: bool,
    /// Icon (or the x when it replaces the icon) is centered.
    pub centers_content: bool,
    /// The x stands in for the tab's status in the status's slot (hover only).
    #[serde(default)]
    pub close_replaces_status: bool,
}

/// A tab's state as the visibility rules read it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabState {
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub selected: bool,
    #[serde(default)]
    pub hovered: bool,
    #[serde(default = "yes")]
    pub closable: bool,
    #[serde(default)]
    pub has_status: bool,
}

fn yes() -> bool {
    true
}

impl Default for TabState {
    fn default() -> Self {
        Self { pinned: false, selected: false, hovered: false, closable: true, has_status: false }
    }
}

impl Visibility {
    pub const HIDDEN: Visibility = Visibility {
        shows_icon: false,
        shows_title: false,
        shows_close: false,
        centers_content: true,
        close_replaces_status: false,
    };

    fn new(shows_icon: bool, shows_title: bool, shows_close: bool, centers_content: bool) -> Self {
        Self { shows_icon, shows_title, shows_close, centers_content, close_replaces_status: false }
    }

    /// Nothing shows (a tab narrower than an icon-only tab).
    pub fn is_hidden(&self) -> bool {
        !self.shows_icon && !self.shows_title && !self.shows_close
    }

    /// The form of a tab `width` wide.
    pub fn resolve(width: f64, tab: TabState, style: Style, m: &Metrics) -> Self {
        if tab.pinned {
            // The pinned icon owns the one centered slot, hovered or not: no x.
            return Self::new(true, false, false, true);
        }
        // Narrower than an icon-only tab: nothing shows.
        if width + 0.5 < m.min_inactive_tab_width.min(m.chrome_min_inactive_width) {
            return Self::HIDDEN;
        }
        let contents = width - m.content_leading_inset - m.content_trailing_inset;
        let roomy = contents >= m.close_min_contents_width;
        let wants_close = match style {
            Style::Chrome => {
                if tab.selected {
                    tab.hovered || !roomy
                } else {
                    tab.hovered
                }
            }
            Style::Compact => tab.hovered,
        };
        let shows_close = wants_close && tab.closable;
        let mut available = contents;
        if shows_close {
            available -= m.close_button_size + m.title_close_spacing;
        }
        let icon_fits = available >= m.icon_size;
        let shows_icon = icon_fits || !shows_close;
        let title_width = available - m.icon_size - m.icon_title_spacing;
        let shows_title = icon_fits && title_width >= m.title_min_visible_width;
        // An x shown at rest (a narrow selected tab) already sits beside the status.
        let close_at_rest = style == Style::Chrome && tab.selected && !roomy && tab.closable;
        Self::new(shows_icon, shows_title, shows_close, !shows_title)
            .yielding_status(tab.hovered && tab.has_status && !close_at_rest)
    }

    /// This form with the x standing in for a status when `replaces` and the x shows: an untitled
    /// tab draws its status on its icon, so the x takes the icon's centered slot instead.
    pub fn yielding_status(self, replaces: bool) -> Self {
        if !replaces || !self.shows_close {
            return self;
        }
        let mut form = self;
        form.close_replaces_status = true;
        if !self.shows_title {
            form.shows_icon = false;
            form.centers_content = true;
        }
        form
    }

    /// The x's origin in a pill `pill_width` wide, one for paint, rapid close and accessibility;
    /// none while the x hides.
    pub fn close_button_origin_x(&self, pill_width: f64, m: &Metrics) -> Option<f64> {
        if !self.shows_close {
            return None;
        }
        if !self.shows_icon && self.centers_content {
            return Some((pill_width - m.close_button_size) / 2.0);
        }
        if !self.shows_title || m.status_mark_placement != StatusMarkPlacement::MirrorAll {
            return Some(pill_width - m.content_trailing_inset - m.close_button_size);
        }
        Some(
            m.status_slot_mid_x(pill_width, StatusMarkPlacement::MirrorAll)
                - m.close_button_size / 2.0,
        )
    }

    /// The form at each width of a width path, from `start` (the form on screen) to the rest form
    /// at the last width: each of the icon, the x and the title changes at most once.
    pub fn path(
        widths: &[f64],
        start: Self,
        tab: TabState,
        style: Style,
        m: &Metrics,
    ) -> Vec<Self> {
        let rest: Vec<Self> =
            widths.iter().map(|&width| Self::resolve(width, tab, style, m)).collect();
        let Some(end) = rest.last().copied() else { return rest };
        if tab.pinned {
            return rest;
        }
        let contents: Vec<f64> = widths
            .iter()
            .map(|width| width - m.content_leading_inset - m.content_trailing_inset)
            .collect();
        let available = |index: usize, close: bool| {
            contents[index] - if close { m.close_button_size + m.title_close_spacing } else { 0.0 }
        };
        let keeps_icon = start.shows_icon && end.shows_icon;
        // A width that springs past an end can leave a kept icon no room for the x: the x waits.
        let fits: Vec<bool> = (0..rest.len())
            .map(|index| !keeps_icon || available(index, true) >= m.icon_size)
            .collect();
        let wanted_close: Vec<bool> =
            (0..rest.len()).map(|index| rest[index].shows_close && fits[index]).collect();
        let close: Vec<bool> = once(&wanted_close, start.shows_close)
            .iter()
            .zip(&fits)
            .map(|(a, b)| *a && *b)
            .collect();
        let wanted_icon: Vec<bool> = (0..rest.len())
            .map(|index| {
                !rest[index].is_hidden()
                    && (available(index, close[index]) >= m.icon_size || !close[index])
            })
            .collect();
        let icon = once(&wanted_icon, start.shows_icon);
        let wanted_title: Vec<bool> = (0..rest.len())
            .map(|index| {
                !rest[index].is_hidden()
                    && icon[index]
                    && available(index, close[index]) - m.icon_size - m.icon_title_spacing
                        >= m.title_min_visible_width
            })
            .collect();
        let title = once(&wanted_title, start.shows_title);
        (0..rest.len())
            .map(|index| {
                Self::new(icon[index], title[index], close[index], !title[index])
                    .yielding_status(rest[index].close_replaces_status)
            })
            .collect()
    }
}

/// `wanted` changed at most once from `start`: the end value from the first sample after the
/// last one that wants otherwise.
fn once(wanted: &[bool], start: bool) -> Vec<bool> {
    let Some(&end) = wanted.last() else { return Vec::new() };
    if start == end {
        return vec![end; wanted.len()];
    }
    let first = wanted.iter().rposition(|&value| value != end).map_or(0, |index| index + 1);
    (0..wanted.len()).map(|index| if index >= first { end } else { start }).collect()
}

#[path = "tabs_layout_vertical.rs"]
pub mod vertical;
#[path = "tabs_layout_wire.rs"]
pub mod wire;

#[cfg(test)]
#[path = "tabs_layout_tests.rs"]
mod tests;
