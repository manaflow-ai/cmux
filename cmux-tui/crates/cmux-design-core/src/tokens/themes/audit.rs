//! The every-theme element audit (`Themes/ThemeElement.swift`, `ThemeElementGround.swift`,
//! `ThemeElementSample.swift`, `ThemeElementAudit.swift`) and the All Themes playground's pure
//! rules (`Playground/AllThemesPlaygroundEntry.swift`, `AllThemesPlaygroundModel.swift`,
//! `AllThemesPlaygroundStrings.swift`). The app resolves each `Palette` colour in both
//! appearances (AppKit) and hands them in; the composition, minimums, order and pass rule live here.

use crate::tokens::color::{Color, Rgb};
use cmux_theme_tokens::{MINIMUM_MARK_CONTRAST, MINIMUM_TEXT_CONTRAST};
use serde::{Deserialize, Serialize};

/// A chrome element the audit checks in every theme (Swift `ThemeElement`; serde names are the raw values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ThemeElement {
    /// Sidebar row and tab title.
    Title,
    /// Sidebar row detail, inactive tab title.
    Detail,
    /// Hint and placeholder.
    Hint,
    /// Sidebar status dot: unread.
    DotUnread,
    /// Sidebar status dot: needs attention.
    DotAttention,
    /// Sidebar status dot: error.
    DotError,
    /// Unread dot and tab badge.
    UnreadBadge,
    /// Spinner.
    Spinner,
    /// Status text: attention.
    StatusAttention,
    /// Status text: error.
    StatusError,
    /// Status text: success.
    StatusSuccess,
    /// Lit toolbar glyph.
    LitGlyph,
    /// Popover and palette text.
    PopoverText,
    /// Popover and palette detail.
    PopoverDetail,
    /// Palette and menu highlighted row.
    HighlightedRow,
    /// Accent button label.
    AccentLabel,
    /// Update button label.
    UpdateLabel,
}

impl ThemeElement {
    /// Every case, in Swift's `allCases` order.
    pub const ALL: [ThemeElement; 17] = [
        Self::Title,
        Self::Detail,
        Self::Hint,
        Self::DotUnread,
        Self::DotAttention,
        Self::DotError,
        Self::UnreadBadge,
        Self::Spinner,
        Self::StatusAttention,
        Self::StatusError,
        Self::StatusSuccess,
        Self::LitGlyph,
        Self::PopoverText,
        Self::PopoverDetail,
        Self::HighlightedRow,
        Self::AccentLabel,
        Self::UpdateLabel,
    ];

    /// The Swift raw value (`rawValue`).
    pub fn raw_value(self) -> &'static str {
        self.table().0
    }

    /// The localization key of the playground name.
    pub fn title_key(self) -> &'static str {
        self.table().1
    }

    /// The playground name (the English default).
    pub fn title(self) -> &'static str {
        self.table().2
    }

    fn table(self) -> (&'static str, &'static str, &'static str) {
        match self {
            Self::Title => ("title", "theme.audit.element.title", "Sidebar row and tab title"),
            Self::Detail => {
                ("detail", "theme.audit.element.detail", "Sidebar row detail, inactive tab title")
            }
            Self::Hint => ("hint", "theme.audit.element.hint", "Hint and placeholder"),
            Self::DotUnread => {
                ("dotUnread", "theme.audit.element.dotUnread", "Sidebar status dot: unread")
            }
            Self::DotAttention => (
                "dotAttention",
                "theme.audit.element.dotAttention",
                "Sidebar status dot: needs attention",
            ),
            Self::DotError => {
                ("dotError", "theme.audit.element.dotError", "Sidebar status dot: error")
            }
            Self::UnreadBadge => {
                ("unreadBadge", "theme.audit.element.unreadBadge", "Unread dot and tab badge")
            }
            Self::Spinner => ("spinner", "theme.audit.element.spinner", "Spinner"),
            Self::StatusAttention => {
                ("statusAttention", "theme.audit.element.statusAttention", "Status text: attention")
            }
            Self::StatusError => {
                ("statusError", "theme.audit.element.statusError", "Status text: error")
            }
            Self::StatusSuccess => {
                ("statusSuccess", "theme.audit.element.statusSuccess", "Status text: success")
            }
            Self::LitGlyph => ("litGlyph", "theme.audit.element.litGlyph", "Lit toolbar glyph"),
            Self::PopoverText => {
                ("popoverText", "theme.audit.element.popoverText", "Popover and palette text")
            }
            Self::PopoverDetail => {
                ("popoverDetail", "theme.audit.element.popoverDetail", "Popover and palette detail")
            }
            Self::HighlightedRow => (
                "highlightedRow",
                "theme.audit.element.highlightedRow",
                "Palette and menu highlighted row",
            ),
            Self::AccentLabel => {
                ("accentLabel", "theme.audit.element.accentLabel", "Accent button label")
            }
            Self::UpdateLabel => {
                ("updateLabel", "theme.audit.element.updateLabel", "Update button label")
            }
        }
    }
}

/// What an element is drawn on (Swift `ThemeElementGround`; serde names are the raw values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ThemeElementGround {
    /// The window, sidebar and tab strip background.
    Window,
    /// A row or tab under the pointer.
    HoveredRow,
    /// The selected row or tab.
    SelectedRow,
    /// A row or button while pressed.
    PressedRow,
    /// Popovers, menus and the palette: their card glass over the worst desktop.
    Popover,
    /// The highlighted row (`menuHighlight` over the popover).
    HighlightedRow,
    /// A button filled with the accent.
    AccentButton,
    /// The update button.
    UpdateButton,
}

impl ThemeElementGround {
    /// Every case, in Swift's `allCases` order.
    pub const ALL: [ThemeElementGround; 8] = [
        Self::Window,
        Self::HoveredRow,
        Self::SelectedRow,
        Self::PressedRow,
        Self::Popover,
        Self::HighlightedRow,
        Self::AccentButton,
        Self::UpdateButton,
    ];

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        self.table().0
    }

    /// The localization key of the playground name.
    pub fn title_key(self) -> &'static str {
        self.table().1
    }

    /// The playground name (the English default).
    pub fn title(self) -> &'static str {
        self.table().2
    }

    fn table(self) -> (&'static str, &'static str, &'static str) {
        match self {
            Self::Window => ("window", "theme.audit.ground.window", "window"),
            Self::HoveredRow => ("hoveredRow", "theme.audit.ground.hoveredRow", "hovered row"),
            Self::SelectedRow => ("selectedRow", "theme.audit.ground.selectedRow", "selected row"),
            Self::PressedRow => ("pressedRow", "theme.audit.ground.pressedRow", "pressed row"),
            Self::Popover => ("popover", "theme.audit.ground.popover", "popover"),
            Self::HighlightedRow => {
                ("highlightedRow", "theme.audit.ground.highlightedRow", "highlighted row")
            }
            Self::AccentButton => {
                ("accentButton", "theme.audit.ground.accentButton", "accent button")
            }
            Self::UpdateButton => {
                ("updateButton", "theme.audit.ground.updateButton", "update button")
            }
        }
    }
}

/// One element's ink on one ground in one theme (Swift `ThemeElementSample`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThemeElementSample {
    /// The element.
    pub element: ThemeElement,
    /// What it sits on.
    pub ground: ThemeElementGround,
    /// The element's colour, opaque, composited over `surface`.
    pub ink: Color,
    /// The ground, opaque.
    pub surface: Color,
    /// The WCAG 2 minimum (4.5 text, 3 marks).
    pub minimum: f64,
    /// True when the ink or the ground follows the system appearance instead of the theme.
    pub follows_system_appearance: bool,
}

impl ThemeElementSample {
    /// The WCAG 2 contrast of `ink` on `surface`.
    pub fn contrast(&self) -> f64 {
        Rgb::from(self.ink).contrast(Rgb::from(self.surface))
    }

    /// Whether it reads (contrast at least `minimum`) and is themed.
    pub fn passes(&self) -> bool {
        self.contrast() >= self.minimum && !self.follows_system_appearance
    }
}

/// A `Palette` colour as the app resolved it: in the theme's own appearance (`own`) and in the
/// other one (`other`, defaults to `own`: a colour the theme computes).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Appearances {
    /// The sRGB colour in the theme's appearance.
    pub own: Color,
    /// The sRGB colour in the other appearance.
    #[serde(default)]
    pub other: Option<Color>,
}

impl Appearances {
    /// A colour that does not change with the appearance.
    pub fn themed(color: Rgb) -> Self {
        Appearances { own: color.into(), other: None }
    }
}

/// A colour as the theme's appearance draws it, opaque, and whether it follows the system
/// (Swift's private `Resolved`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Resolved {
    /// The opaque colour.
    pub color: Rgb,
    /// Whether the other appearance draws it differently (or its base does).
    pub follows_system: bool,
}

fn same(a: Rgb, b: Rgb) -> bool {
    (a.r - b.r).abs() < 0.004
        && (a.g - b.g).abs() < 0.004
        && (a.b - b.b).abs() < 0.004
        && (a.a - b.a).abs() < 0.004
}

impl Resolved {
    /// A colour the theme computes itself (`Resolved(_ color: ThemeRGB)`).
    pub fn computed(color: Rgb) -> Self {
        Resolved { color: color.with_alpha(1.0), follows_system: false }
    }

    /// `color` over `base` (black when none), opaque (`Resolved(_:isDark:over:)`).
    pub fn over(color: Appearances, base: Option<Resolved>) -> Self {
        let own = Rgb::from(color.own);
        let other = color.other.map_or(own, Rgb::from);
        let ground = base.map_or(Rgb::BLACK, |b| b.color);
        Resolved {
            color: own.composited(ground).with_alpha(1.0),
            follows_system: !same(own, other) || base.is_some_and(|b| b.follows_system),
        }
    }
}

/// The `Palette` colours the audit reads (Swift's private `AuditColors`), each in both appearances,
/// plus the card tint the popover glass lays (`CardMaterial.tint`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub struct AuditColors {
    pub is_dark: bool,
    /// `CardMaterial(tokens, lift:, minimumOpacity:).tint`.
    pub card_tint: Color,
    pub window: Appearances,
    pub hover: Appearances,
    pub selection: Appearances,
    pub pressed: Appearances,
    pub menu_highlight: Appearances,
    pub text_primary: Appearances,
    pub text_secondary: Appearances,
    pub text_tertiary: Appearances,
    pub status_unread: Appearances,
    pub status_attention: Appearances,
    pub status_error: Appearances,
    pub notification: Appearances,
    pub spinner: Appearances,
    pub attention: Appearances,
    pub danger: Appearances,
    pub success: Appearances,
    pub lit_glyph: Appearances,
    pub accent_fill: Appearances,
    pub on_accent: Appearances,
    pub highlight: Appearances,
    pub highlight_text: Appearances,
}

/// Every sample of one theme, in playground order (Swift `ThemeElementAudit(scope:).samples`).
pub fn audit_samples(c: &AuditColors) -> Vec<ThemeElementSample> {
    use ThemeElement as E;
    use ThemeElementGround as G;
    let window = Resolved::over(c.window, None);
    let over = |fill: Appearances, base: Resolved| Resolved::over(fill, Some(base));
    let rows = [
        (G::Window, window),
        (G::HoveredRow, over(c.hover, window)),
        (G::SelectedRow, over(c.selection, window)),
        (G::PressedRow, over(c.pressed, window)),
    ];
    let selected = [rows[0], rows[2]];
    let desk = if c.is_dark { Rgb::WHITE } else { Rgb::BLACK };
    let popup = Resolved::computed(Rgb::from(c.card_tint).composited(desk));
    let (text, mark) = (MINIMUM_TEXT_CONTRAST, MINIMUM_MARK_CONTRAST);
    let mut samples = Vec::new();
    let mut add = |element: E, ink: Appearances, grounds: &[(G, Resolved)], minimum: f64| {
        for (name, ground) in grounds {
            let resolved = over(ink, *ground);
            samples.push(ThemeElementSample {
                element,
                ground: *name,
                ink: resolved.color.into(),
                surface: ground.color.into(),
                minimum,
                follows_system_appearance: resolved.follows_system || ground.follows_system,
            });
        }
    };
    add(E::Title, c.text_primary, &rows, text);
    add(E::Detail, c.text_secondary, &rows, text);
    add(E::Hint, c.text_tertiary, &rows[..1], mark);
    add(E::DotUnread, c.status_unread, &selected, mark);
    add(E::DotAttention, c.status_attention, &selected, mark);
    add(E::DotError, c.status_error, &selected, mark);
    add(E::UnreadBadge, c.notification, &selected, mark);
    add(E::Spinner, c.spinner, &selected, mark);
    add(E::StatusAttention, c.attention, &rows[..1], mark);
    add(E::StatusError, c.danger, &rows[..1], mark);
    add(E::StatusSuccess, c.success, &rows[..1], mark);
    add(E::LitGlyph, c.lit_glyph, &rows[..1], mark);
    add(E::PopoverText, c.text_primary, &[(G::Popover, popup)], text);
    add(E::PopoverDetail, c.text_secondary, &[(G::Popover, popup)], text);
    add(
        E::HighlightedRow,
        c.text_primary,
        &[(G::HighlightedRow, over(c.menu_highlight, popup))],
        text,
    );
    add(
        E::AccentLabel,
        c.on_accent,
        &[(G::AccentButton, Resolved::over(c.accent_fill, None))],
        text,
    );
    add(
        E::UpdateLabel,
        c.highlight_text,
        &[(G::UpdateButton, Resolved::over(c.highlight, None))],
        text,
    );
    samples
}

/// The samples that do not pass (`ThemeElementAudit.failures`).
pub fn audit_failures(samples: &[ThemeElementSample]) -> Vec<ThemeElementSample> {
    samples.iter().filter(|s| !s.passes()).copied().collect()
}

/// One theme in the All Themes playground (Swift `AllThemesPlaygroundEntry`, its pure part).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaygroundEntry {
    /// The theme file's name (the entry's id).
    pub name: String,
    /// Whether the theme is dark.
    #[serde(default)]
    pub is_dark: bool,
    /// Every sample, in audit order.
    #[serde(default)]
    pub samples: Vec<ThemeElementSample>,
}

impl PlaygroundEntry {
    /// Whether any sample fails (`!failures.isEmpty`).
    pub fn fails(&self) -> bool {
        self.samples.iter().any(|s| !s.passes())
    }
}

/// The playground's order: failing themes first, then by name (`load(folders:)`'s sort; Swift
/// compares `String`s, which for these names is Rust's `str` order).
pub fn playground_sorted(mut entries: Vec<PlaygroundEntry>) -> Vec<PlaygroundEntry> {
    entries.sort_by(|a, b| (!a.fails(), &a.name).cmp(&(!b.fails(), &b.name)));
    entries
}

/// Whether `name` contains `query`, case-insensitively (`localizedCaseInsensitiveContains`,
/// approximated by Unicode lowercase folding).
pub fn name_matches(name: &str, query: &str) -> bool {
    name.to_lowercase().contains(&query.to_lowercase())
}

/// The indices of the entries the filter shows (`AllThemesPlaygroundModel.shown`).
pub fn playground_shown(
    entries: &[PlaygroundEntry],
    query: &str,
    failures_only: bool,
) -> Vec<usize> {
    entries
        .iter()
        .enumerate()
        .filter(|(_, e)| {
            (!failures_only || e.fails()) && (query.is_empty() || name_matches(&e.name, query))
        })
        .map(|(i, _)| i)
        .collect()
}

/// The number of themes with a failing sample (`failingCount`).
pub fn playground_failing_count(entries: &[PlaygroundEntry]) -> usize {
    entries.iter().filter(|e| e.fails()).count()
}

/// The theme files to read from `folders` (each a list of file names), later folders winning on
/// a name and dot files skipped: `(name, folder index)` sorted by name.
pub fn playground_files(folders: &[Vec<String>]) -> Vec<(String, usize)> {
    let mut files = std::collections::BTreeMap::new();
    for (index, names) in folders.iter().enumerate() {
        for name in names.iter().filter(|n| !n.starts_with('.')) {
            files.insert(name.clone(), index);
        }
    }
    files.into_iter().collect()
}

/// The playground's fixed strings: `(key, English default)` (`AllThemesPlaygroundStrings`).
pub const PLAYGROUND_STRINGS: [(&str, &str); 5] = [
    ("theme.playground.windowTitle", "All Themes"),
    ("theme.playground.search", "Search themes"),
    ("theme.playground.failuresOnly", "Failures only"),
    ("theme.playground.light", "Light"),
    ("theme.playground.dark", "Dark"),
];

/// "3 of 622 themes fail" (`AllThemesPlaygroundStrings.summary(failing:total:)`).
pub fn playground_summary(failing: i64, total: i64) -> String {
    format!("{failing} of {total} themes fail")
}

/// "2 failing" (`AllThemesPlaygroundStrings.failing(_:)`).
pub fn playground_failing(count: i64) -> String {
    format!("{count} failing")
}

/// "Sidebar status dot: error on selected row: 2.40:1, needs 3.0:1" (`sampleHelp(_:)`).
pub fn playground_sample_help(sample: &ThemeElementSample) -> String {
    let (element, ground) = (sample.element.title(), sample.ground.title());
    if sample.follows_system_appearance {
        format!("{element} on {ground}: follows the system appearance, not the theme")
    } else {
        format!("{element} on {ground}: {:.2}:1, needs {:.1}:1", sample.contrast(), sample.minimum)
    }
}
