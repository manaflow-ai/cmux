//! A port of `DensityTokenCatalog` (CmuxNextDesign/DensityTokenCatalog.swift): the density
//! playground's groups, fields, units, entries table and its reads and writes.

use super::tokens::{DensityPreset, DensityTokens, smax, smin};
use serde::{Deserialize, Serialize};

/// `DensityTokenCatalog.Group`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Group {
    /// `verticalTabs`.
    VerticalTabs,
    /// `horizontalTabs`.
    HorizontalTabs,
    /// `other`.
    Other,
}

impl Group {
    /// `allCases`, in order.
    pub const ALL: [Group; 3] = [Group::VerticalTabs, Group::HorizontalTabs, Group::Other];

    /// `title`.
    pub fn title(self) -> &'static str {
        match self {
            Group::VerticalTabs => "Vertical tabs",
            Group::HorizontalTabs => "Horizontal tabs",
            Group::Other => "Other",
        }
    }
}

/// `DensityTokenCatalog.Field`: which part of the density an entry edits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Field {
    /// A `tokens` key.
    Token,
    /// `spacing`.
    Spacing,
    /// `fontSize`.
    FontSize,
}

/// `DensityTokenCatalog.Unit`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Unit {
    /// `points`.
    Points,
    /// `factor`.
    Factor,
}

/// An entry's built-in fallback: none, a constant closure (`{ 0 }`, `{ 1 }`), or one that reads
/// live app metrics (the caller passes its scoped value).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum Fallback {
    /// No fallback.
    None,
    /// A constant fallback.
    Constant(f64),
    /// A fallback from live metrics (`Metrics.*`, `MetricTunables.*`).
    Derived,
}

/// `DensityTokenCatalog.Entry`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// The key (and id).
    pub key: &'static str,
    /// The group.
    pub group: Group,
    /// The section title.
    pub section: &'static str,
    /// The label.
    pub label: &'static str,
    /// The help line.
    pub help: &'static str,
    /// The range's lower bound.
    pub range_lower: f64,
    /// The range's upper bound.
    pub range_upper: f64,
    /// The snap step.
    pub step: f64,
    /// The unit.
    pub unit: Unit,
    /// The edited field.
    pub field: Field,
    /// The built-in fallback.
    pub fallback: Fallback,
}

#[allow(clippy::too_many_arguments)]
const fn e(
    key: &'static str,
    group: Group,
    section: &'static str,
    label: &'static str,
    help: &'static str,
    range_lower: f64,
    range_upper: f64,
    step: f64,
    unit: Unit,
    field: Field,
    fallback: Fallback,
) -> Entry {
    Entry {
        key,
        group,
        section,
        label,
        help,
        range_lower,
        range_upper,
        step,
        unit,
        field,
        fallback,
    }
}

/// `DensityTokenCatalog.all`: every entry, in the playground's order.
pub const ALL: &[Entry] = &[
    e(
        "sidebarRowHeight",
        Group::VerticalTabs,
        "Sidebar rows",
        "Row height",
        "A one-line workspace row; sets the room above and below the title.",
        14.0,
        56.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "sidebarRowGap",
        Group::VerticalTabs,
        "Sidebar rows",
        "Row gap",
        "The gap between two rows.",
        0.0,
        12.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarRowInset",
        Group::VerticalTabs,
        "Sidebar rows",
        "Row to sidebar edge",
        "The gap between a row's fill and the sidebar's left and right edges.",
        0.0,
        24.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarContentInset",
        Group::VerticalTabs,
        "Sidebar rows",
        "Horizontal padding",
        "Where a row's icon starts inside its fill.",
        0.0,
        24.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarCornerRadius",
        Group::VerticalTabs,
        "Sidebar rows",
        "Corner radius",
        "Every row fill's corner: hover, selection, Home and pinned rows.",
        0.0,
        20.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarIconColumn",
        Group::VerticalTabs,
        "Sidebar rows",
        "Icon column",
        "The leading icon column's width.",
        8.0,
        32.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarGlyphInk",
        Group::VerticalTabs,
        "Sidebar rows",
        "Icon size",
        "The ink of every leading glyph and favicon.",
        6.0,
        28.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "sidebarIconGap",
        Group::VerticalTabs,
        "Sidebar rows",
        "Icon to title",
        "The gap between the icon column and the title.",
        0.0,
        20.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarTitleSize",
        Group::VerticalTabs,
        "Sidebar rows",
        "Title size",
        "A row title's point size.",
        9.0,
        20.0,
        0.25,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "sidebarGroupIndent",
        Group::VerticalTabs,
        "Sidebar rows",
        "Group indent",
        "How far a nested group's rows step in per level.",
        0.0,
        32.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarHeaderHeight",
        Group::VerticalTabs,
        "Sidebar rows",
        "Section header height",
        "A computer's or section's header row.",
        12.0,
        48.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "sidebarHeadingSize",
        Group::VerticalTabs,
        "Sidebar rows",
        "Heading size",
        "Group and section heading text.",
        9.0,
        20.0,
        0.25,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarSectionGap",
        Group::VerticalTabs,
        "Sidebar rows",
        "Section gap",
        "The room between two sections of the list.",
        0.0,
        32.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarBandGap",
        Group::VerticalTabs,
        "Sidebar rows",
        "Home to pinned gap",
        "The extra room between Home and the pinned rows.",
        0.0,
        16.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarStatusDot",
        Group::VerticalTabs,
        "Sidebar rows",
        "Status dot",
        "Unread, needs-you and done dots.",
        4.0,
        14.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "sidebarWidth",
        Group::VerticalTabs,
        "Sidebar rows",
        "Sidebar width",
        "The sidebar's default width.",
        120.0,
        480.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "verticalTabRowHeight",
        Group::VerticalTabs,
        "Pane tab list",
        "Row height",
        "A tab row in a pane's vertical tab list.",
        14.0,
        56.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "verticalTabRowGap",
        Group::VerticalTabs,
        "Pane tab list",
        "Row gap",
        "The gap between two tab rows.",
        0.0,
        12.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "verticalTabPadding",
        Group::VerticalTabs,
        "Pane tab list",
        "Horizontal padding",
        "The rows' inset from the list's edges.",
        0.0,
        24.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "verticalTabIconSize",
        Group::VerticalTabs,
        "Pane tab list",
        "Icon size",
        "A tab row's favicon.",
        8.0,
        28.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "verticalTabHeaderHeight",
        Group::VerticalTabs,
        "Pane tab list",
        "Group header height",
        "A tab group's header row.",
        12.0,
        48.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "verticalTabIndent",
        Group::VerticalTabs,
        "Pane tab list",
        "Group indent",
        "How far a group's tabs sit in, room for its line.",
        0.0,
        24.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "verticalTabCornerRadius",
        Group::VerticalTabs,
        "Pane tab list",
        "Corner radius",
        "A tab row's fill corner.",
        0.0,
        20.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "verticalTabTileSize",
        Group::VerticalTabs,
        "Pane tab list",
        "Pinned tile size",
        "A pinned tab's square tile.",
        16.0,
        56.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "verticalTabWidth",
        Group::VerticalTabs,
        "Pane tab list",
        "List width",
        "The list's width while it shows titles.",
        120.0,
        480.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "browserRowHeight",
        Group::HorizontalTabs,
        "Tab strip",
        "Tab height",
        "A tab pill's height; the omnibar takes it too.",
        16.0,
        48.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "browserRowGap",
        Group::HorizontalTabs,
        "Tab strip",
        "Strip padding",
        "The gap above and below the tabs (the strip's height is the tab plus twice this).",
        0.0,
        12.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabStripEndGap",
        Group::HorizontalTabs,
        "Tab strip",
        "Strip end insets",
        "From the strip's start to the first tab, and from the last tab to +.",
        0.0,
        24.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabGap",
        Group::HorizontalTabs,
        "Tab strip",
        "Gap between tabs",
        "The gap between two tab pills.",
        0.0,
        16.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabMinActiveWidth",
        Group::HorizontalTabs,
        "Tab strip",
        "Min width (selected)",
        "Narrowest the selected tab gets when crowded; never under its icon and close button.",
        32.0,
        320.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabMinInactiveWidth",
        Group::HorizontalTabs,
        "Tab strip",
        "Min width (others)",
        "Narrowest the other tabs get before the strip scrolls.",
        16.0,
        320.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabMaxWidth",
        Group::HorizontalTabs,
        "Tab strip",
        "Max width",
        "Widest a tab gets.",
        60.0,
        480.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabPinnedWidth",
        Group::HorizontalTabs,
        "Tab strip",
        "Pinned tab width",
        "A pinned tab's width.",
        24.0,
        120.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabCornerRadius",
        Group::HorizontalTabs,
        "Tab strip",
        "Corner radius",
        "A tab pill's corner.",
        0.0,
        20.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabIconLeading",
        Group::HorizontalTabs,
        "Tab content",
        "Leading padding",
        "From the pill's leading edge to its icon.",
        0.0,
        20.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabIconSize",
        Group::HorizontalTabs,
        "Tab content",
        "Icon size",
        "A tab's favicon box.",
        8.0,
        28.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabIconTitleGap",
        Group::HorizontalTabs,
        "Tab content",
        "Icon to title",
        "The gap between a tab's icon and its title.",
        0.0,
        16.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "tabTitleSize",
        Group::HorizontalTabs,
        "Tab content",
        "Title size",
        "A tab title's point size.",
        9.0,
        20.0,
        0.25,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabTitleDrop",
        Group::HorizontalTabs,
        "Tab content",
        "Title baseline shift",
        "Moves the title down from optical center.",
        0.0,
        4.0,
        0.25,
        Unit::Points,
        Field::Token,
        Fallback::Constant(0.0),
    ),
    e(
        "tabCloseSize",
        Group::HorizontalTabs,
        "Tab content",
        "Close button",
        "The x's hover square.",
        4.0,
        28.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabCloseGlyphSize",
        Group::HorizontalTabs,
        "Tab content",
        "Close glyph",
        "The x's ink.",
        4.0,
        28.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabCloseCornerRadius",
        Group::HorizontalTabs,
        "Tab content",
        "Close corner",
        "The x's hover square corner.",
        0.0,
        14.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "tabTrailingInset",
        Group::HorizontalTabs,
        "Tab content",
        "Trailing padding",
        "From the x to the pill's trailing edge.",
        0.0,
        16.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "densityScale",
        Group::Other,
        "Scale",
        "Overall scale",
        "Scales every size the density does not set exactly, over Default's.",
        0.6,
        1.6,
        0.01,
        Unit::Factor,
        Field::Token,
        Fallback::Constant(1.0),
    ),
    e(
        "spacing",
        Group::Other,
        "Scale",
        "Spacing",
        "Multiplies every padding and inset that follows the grid.",
        0.5,
        2.0,
        0.05,
        Unit::Factor,
        Field::Spacing,
        Fallback::None,
    ),
    e(
        "fontSize",
        Group::Other,
        "Scale",
        "Body text size",
        "Chrome's body text; titles made from it scale with it.",
        9.0,
        20.0,
        0.25,
        Unit::Points,
        Field::FontSize,
        Fallback::None,
    ),
    e(
        "omnibarHeight",
        Group::Other,
        "Toolbar and omnibar",
        "Omnibar height",
        "The address bar's height.",
        16.0,
        48.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "omnibarFontSize",
        Group::Other,
        "Toolbar and omnibar",
        "Omnibar text size",
        "The URL's text size.",
        9.0,
        22.0,
        0.25,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "omnibarCornerRadius",
        Group::Other,
        "Toolbar and omnibar",
        "Omnibar corner radius",
        "The address bar's corner.",
        0.0,
        20.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "omnibarIconSize",
        Group::Other,
        "Toolbar and omnibar",
        "Omnibar icon size",
        "The page-info and search glyph.",
        8.0,
        28.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "omnibarTextGap",
        Group::Other,
        "Toolbar and omnibar",
        "Omnibar icon to text",
        "From the page-info chip to the URL.",
        0.0,
        16.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "omnibarButtonSpacing",
        Group::Other,
        "Toolbar and omnibar",
        "Toolbar button gap",
        "The gap between toolbar buttons.",
        0.0,
        12.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "toolbarGlyphSize",
        Group::Other,
        "Toolbar and omnibar",
        "Toolbar icon size",
        "Back, forward and reload glyph boxes.",
        8.0,
        32.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "paletteRowHeight",
        Group::Other,
        "Command palette",
        "Row height",
        "One palette result.",
        20.0,
        56.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "paletteSearchHeight",
        Group::Other,
        "Command palette",
        "Search field height",
        "The palette's search field.",
        28.0,
        72.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "paletteWidth",
        Group::Other,
        "Command palette",
        "Width",
        "The palette's width.",
        360.0,
        1200.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "chatTextScale",
        Group::Other,
        "Chats",
        "Agent chat text",
        "The agent chats' text, tool rows and composer, over Default's.",
        0.7,
        1.6,
        0.05,
        Unit::Factor,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "homeTextScale",
        Group::Other,
        "Chats",
        "Home chat text",
        "The Home (iMessage-style) transcript's text, over Default's.",
        0.7,
        1.6,
        0.05,
        Unit::Factor,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "composerZoom",
        Group::Other,
        "Chats",
        "New Tab composer",
        "New Tab's composer size, over Default's.",
        0.6,
        1.6,
        0.05,
        Unit::Factor,
        Field::Token,
        Fallback::Constant(1.0),
    ),
    e(
        "chatEditorMin",
        Group::Other,
        "Chats",
        "Composer min height",
        "The chat composer's resting height.",
        20.0,
        80.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::None,
    ),
    e(
        "titlebarHeight",
        Group::Other,
        "Window and panes",
        "Titlebar height",
        "The unified titlebar.",
        20.0,
        64.0,
        1.0,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "panePadding",
        Group::Other,
        "Window and panes",
        "Pane padding",
        "Around each pane's tab strip and content.",
        0.0,
        16.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "panelCornerRadius",
        Group::Other,
        "Window and panes",
        "Panel corner radius",
        "Floating panels: sidebar, palette.",
        0.0,
        24.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "itemCornerRadius",
        Group::Other,
        "Window and panes",
        "Control corner radius",
        "Buttons and small controls.",
        0.0,
        16.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "controlHeight",
        Group::Other,
        "Window and panes",
        "Control height",
        "Fields, small controls and the strip's + button.",
        16.0,
        44.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "iconSize",
        Group::Other,
        "Window and panes",
        "Icon size",
        "Toolbar and row icons that follow the grid.",
        8.0,
        28.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
    e(
        "smallIconSize",
        Group::Other,
        "Window and panes",
        "Small icon size",
        "Secondary glyphs and trailing buttons.",
        6.0,
        24.0,
        0.5,
        Unit::Points,
        Field::Token,
        Fallback::Derived,
    ),
];

/// `DensityTokenCatalog.unlistedKeys` (sorted).
pub const UNLISTED_KEYS: &[&str] = &[
    "composerMaxWidth",
    "foreground",
    "omnibarChromeColumn",
    "omnibarEdgeInset",
    "omnibarFieldTrailingGap",
    "omnibarIconLeading",
    "omnibarIconViewSize",
    "omnibarLineBoxBaseline",
    "omnibarPopupBottomPadding",
    "omnibarPopupCornerRadius",
    "omnibarPopupRowCornerRadius",
    "omnibarPopupRowGap",
    "omnibarPopupRowHeight",
    "omnibarPopupSideOutset",
    "omnibarPopupTopOutset",
    "omnibarTrailingIconSize",
    "omnibarTrailingPadding",
    "sidebarLineBoxBaseline",
    "tabStripHeight",
];

/// `entry(_:)`: the first entry with `key`.
pub fn entry(key: &str) -> Option<&'static Entry> {
    ALL.iter().find(|e| e.key == key)
}

/// `explicitValue(_:in:)`: the value the density sets for the entry.
pub fn explicit_value(entry: &Entry, density: &DensityTokens) -> Option<f64> {
    match entry.field {
        Field::Token => density.token(entry.key),
        Field::Spacing => Some(density.spacing),
        Field::FontSize => density.font_size,
    }
}

/// `value(_:in:scoped:)`: the explicit value, else the body size (font size), else the fallback
/// over `max(Metrics.scale(1), 0.01)`, else the base preset's token.
///
/// `scoped_fallback` is the caller's scoped fallback value (an `entries(fallbacks:)` override or
/// a derived fallback read live); without it a constant fallback is used, and a derived one falls
/// through to the base token. `interface_scale` is `Metrics.scale(1)`.
pub fn value(
    entry: &Entry,
    density: &DensityTokens,
    scoped_fallback: Option<f64>,
    interface_scale: f64,
) -> Option<f64> {
    if let Some(explicit) = explicit_value(entry, density) {
        return Some(explicit);
    }
    if entry.field == Field::FontSize {
        return Some(density.body_size());
    }
    let fallback = match (scoped_fallback, entry.fallback) {
        (Some(v), _) => Some(v),
        (None, Fallback::Constant(c)) => Some(c),
        _ => None,
    };
    if let Some(v) = fallback {
        return Some(v / smax(interface_scale, 0.01));
    }
    if entry.field == Field::Token { base(density).token(entry.key) } else { None }
}

/// `setting(_:to:in:)`: clamps into the range, snaps to the step and writes the field.
pub fn setting(entry: &Entry, value: f64, density: &DensityTokens) -> DensityTokens {
    if !value.is_finite() {
        return density.clone();
    }
    let clamped = smin(smax(value, entry.range_lower), entry.range_upper);
    let snapped =
        if entry.step > 0.0 { (clamped / entry.step).round() * entry.step } else { clamped };
    let mut tokens = density.tokens.clone();
    let (mut spacing, mut font_size) = (density.spacing, density.font_size);
    match entry.field {
        Field::Token => {
            tokens.insert(entry.key.to_string(), snapped);
        }
        Field::Spacing => spacing = snapped,
        Field::FontSize => font_size = Some(snapped),
    }
    rebuilt(density, density.level, spacing, font_size, tokens)
}

/// `resetting(_:in:to:)`: the entry's field back to `base`'s.
pub fn resetting(entry: &Entry, density: &DensityTokens, base: &DensityTokens) -> DensityTokens {
    let mut tokens = density.tokens.clone();
    let (mut spacing, mut font_size) = (density.spacing, density.font_size);
    match entry.field {
        Field::Token => match base.token(entry.key) {
            Some(v) => {
                tokens.insert(entry.key.to_string(), v);
            }
            None => {
                tokens.remove(entry.key);
            }
        },
        Field::Spacing => spacing = base.spacing,
        Field::FontSize => font_size = base.font_size,
    }
    rebuilt(density, density.level, spacing, font_size, tokens)
}

/// `resettingAll(_:to:)`: keeps the id, name and base; takes everything else from `base`.
pub fn resetting_all(density: &DensityTokens, base: &DensityTokens) -> DensityTokens {
    rebuilt(density, base.level, base.spacing, base.font_size, base.tokens.clone())
}

fn rebuilt(
    density: &DensityTokens,
    level: f64,
    spacing: f64,
    font_size: Option<f64>,
    tokens: std::collections::BTreeMap<String, f64>,
) -> DensityTokens {
    DensityTokens::new(
        density.id.clone(),
        density.name.clone(),
        density.based_on.clone(),
        level,
        spacing,
        font_size,
        tokens,
    )
}

/// `differs(_:_:from:)`: one sets it and the other not, or both by more than 0.0001.
pub fn differs(entry: &Entry, density: &DensityTokens, base: &DensityTokens) -> bool {
    match (explicit_value(entry, density), explicit_value(entry, base)) {
        (None, None) => false,
        (Some(a), Some(b)) => (a - b).abs() > 0.0001,
        _ => true,
    }
}

/// `base(of:)`: the preset with the density's id, else its `basedOn` preset, else Default.
pub fn base(density: &DensityTokens) -> &'static DensityTokens {
    if let Some(preset) = DensityPreset::from_raw(&density.id) {
        return preset.tokens();
    }
    if let Some(preset) = density.based_on.as_deref().and_then(DensityPreset::from_raw) {
        return preset.tokens();
    }
    DensityPreset::Cozy.tokens()
}
