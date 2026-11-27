//! `ThemeTokens::derive`: every chrome color from the terminal theme, as
//! cmux-next `ThemeTokens.swift` (CmuxTheme package on `feat-cmux-next`)
//! derives them. The plain color formulas and the contrast minimums come
//! from the spec's `design-tokens.json` (`crate::spec`); the contrast
//! searches (`readable`, `muted`), the status, highlight and selection rules,
//! the caret and the hued accent (`appearance.accent`, from `AppTheme`) are
//! here, as the json writes them in prose.

use crate::spec::{Inputs, spec};
use crate::{AppTheme, AppToken, Rgb, ThemeAccent};

/// The colors of the terminal theme (port of `ThemeInput`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ThemeInput {
    /// The terminal background, opaque (its opacity is `background_opacity`).
    pub background: Rgb,
    /// The terminal foreground, opaque.
    pub foreground: Rgb,
    /// ANSI palette entries 0...15.
    pub palette: [Rgb; 16],
    /// Set only when the config names an explicit color.
    pub selection_background: Option<Rgb>,
    /// Set only when the config names an explicit color.
    pub selection_foreground: Option<Rgb>,
    /// `background-opacity`, 0...1.
    pub background_opacity: f64,
    /// `background-blur` as Ghostty encodes it (0 off, >0 radius, <0 macOS glass).
    pub background_blur: i32,
    /// `cursor-color`; set only when the config names an explicit color.
    pub cursor: Option<Rgb>,
    /// Where the chrome's accent comes from (`appearance.accent` in
    /// cmux.json, not the Ghostty config; `load` leaves it neutral).
    pub accent: ThemeAccent,
    /// The theme's own accent: its `<theme>/accent` edit in
    /// `appearance.themeEdits` (set by the app), else the theme file's
    /// `# cmux-accent = #rrggbb` line (set by `load`). Wins over `accent`.
    pub accent_color: Option<Rgb>,
}

/// Ghostty's default ANSI 0...15.
pub const GHOSTTY_DEFAULT_PALETTE: [Rgb; 16] = [
    Rgb::hex(0x1D1F21),
    Rgb::hex(0xCC6666),
    Rgb::hex(0xB5BD68),
    Rgb::hex(0xF0C674),
    Rgb::hex(0x81A2BE),
    Rgb::hex(0xB294BB),
    Rgb::hex(0x8ABEB7),
    Rgb::hex(0xC5C8C6),
    Rgb::hex(0x666666),
    Rgb::hex(0xD54E53),
    Rgb::hex(0xB9CA4A),
    Rgb::hex(0xE7C547),
    Rgb::hex(0x7AA6DA),
    Rgb::hex(0xC397D8),
    Rgb::hex(0x70C0B1),
    Rgb::hex(0xEAEAEA),
];

impl ThemeInput {
    /// Ghostty's built-in default theme (no config, no theme).
    pub const GHOSTTY_DEFAULT: ThemeInput = ThemeInput {
        background: Rgb::hex(0x282C34),
        foreground: Rgb::hex(0xFFFFFF),
        palette: GHOSTTY_DEFAULT_PALETTE,
        selection_background: None,
        selection_foreground: None,
        background_opacity: 1.0,
        background_blur: 0,
        cursor: None,
        accent: ThemeAccent::Neutral,
        accent_color: None,
    };

    /// This theme with the chrome accent `accent` (`appearance.accent`).
    pub fn with_accent(mut self, accent: ThemeAccent) -> Self {
        self.accent = accent;
        self
    }
}

impl Default for ThemeInput {
    fn default() -> Self {
        Self::GHOSTTY_DEFAULT
    }
}

/// `appearance.borders`: `Default` draws every border, hairline and
/// separator; `None` makes them clear (their space stays).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum BorderMode {
    #[default]
    Default,
    None,
}

impl BorderMode {
    /// `default` | `none` (as cmux.json writes it).
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "default" => Some(Self::Default),
            "none" => Some(Self::None),
            _ => None,
        }
    }

    /// Whether lines draw at all.
    pub fn draws_lines(self) -> bool {
        self == Self::Default
    }

    /// The width a border of `width` points draws with: 0 under `None`.
    pub fn width(self, width: f32) -> f32 {
        if self.draws_lines() { width } else { 0.0 }
    }
}

/// Every chrome color, derived from the terminal theme. Plain `Copy` and
/// `#[repr(C)]` (a C caller reads it field by field; new fields go at the
/// end). Field docs follow the Swift ones.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ThemeTokens {
    /// Dark when the background is darker than the foreground.
    pub is_dark: bool,

    // Surfaces
    /// Window background: the terminal background (with its opacity).
    pub window_background: Rgb,
    /// Sidebar: the same surface as the window, no panel.
    pub sidebar_background: Rgb,
    /// Behind terminal and browser content.
    pub content_background: Rgb,
    /// Fields and toolbars that need a faint lift (omnibar, find bar).
    pub chrome_background: Rgb,
    /// Floating cards (palette, hover card) under or instead of glass.
    pub elevated_background: Rgb,
    /// Every pane's tab strip: the same ground as the window.
    pub strip_background: Rgb,
    /// The sidebar's tonal step: a translucent layer over the window's
    /// backdrop (the foreground at 4%).
    pub sidebar_step: Rgb,
    /// Reserved for the sidebar rules (space marks soften toward it); tab
    /// strips do not add a tonal step.
    pub strip_step: Rgb,

    // Text
    /// Titles and body text: the foreground, pushed to 4.5:1 when needed.
    pub text_primary: Rgb,
    /// Captions, inactive titles. At least 4.5:1 on every fill.
    pub text_secondary: Rgb,
    /// Hints and placeholders. At least 3:1 on every fill.
    pub text_tertiary: Rgb,

    // Fills (translucent foreground over the surface)
    pub hover_fill: Rgb,
    /// The foreground at low alpha; with `appearance.accent`, the app
    /// accent at 0.26 (dark) or 0.16 (light).
    pub selection_fill: Rgb,
    pub secondary_selection_fill: Rgb,
    pub pressed_fill: Rgb,
    pub badge_fill: Rgb,
    /// Hairlines between sections.
    pub separator: Rgb,
    /// The subtle hairline around each pane's content.
    pub pane_border: Rgb,
    /// The keyboard focus outline: the foreground at 0.40; with
    /// `appearance.accent`, the opaque app accent.
    pub focus_ring: Rgb,
    /// Tint laid over glass so it takes the theme's cast.
    pub glass_tint: Rgb,
    pub shadow: Rgb,
    /// Selected text in chrome text fields.
    pub text_selection: Rgb,

    // Status, from the ANSI palette
    pub attention: Rgb,
    pub danger: Rgb,
    pub success: Rgb,
    /// The one action color (ANSI blue, at least 3:1); with
    /// `appearance.accent`, the app accent.
    pub highlight: Rgb,
    pub highlight_text: Rgb,
    /// Selected and active marks (unread dots, the user's messages, Send in
    /// the agent pane): the primary text (no hue) with the neutral accent,
    /// else the app accent (`AppTheme`, the theme's own hue).
    pub accent: Rgb,
    /// Glyphs and labels on `accent`: the opaque background with the
    /// neutral accent, else the app theme's `onAccent` (at least 4.5:1).
    pub on_accent: Rgb,
    /// ANSI 0...15.
    pub ansi: [Rgb; 16],

    pub background_opacity: f64,
    pub background_blur: i32,

    /// Text carets: `cursor-color` when the config names one (pushed to 3:1
    /// on the background), else the primary text.
    pub caret: Rgb,
}

/// Minimum contrast for primary and secondary chrome text (the spec's
/// `theme.constants.minimumTextContrast`; derive reads the json).
pub const MINIMUM_TEXT_CONTRAST: f64 = 4.5;
/// Minimum contrast for tertiary text and status marks (the spec's
/// `theme.constants.minimumMarkContrast`; derive reads the json).
pub const MINIMUM_MARK_CONTRAST: f64 = 3.0;

impl ThemeTokens {
    /// Ghostty's default theme's tokens.
    pub fn fallback() -> Self {
        Self::derive(&ThemeInput::GHOSTTY_DEFAULT)
    }

    /// Every chrome color for a terminal theme.
    pub fn derive(input: &ThemeInput) -> Self {
        let bg = input.background.with_alpha(1.0);
        let fg = input.foreground.with_alpha(1.0);
        let is_dark = bg.relative_luminance() < fg.relative_luminance();
        let opacity = input.background_opacity.clamp(0.0, 1.0);
        let spec = spec();
        let inputs = Inputs { bg, fg, opacity, is_dark };
        let color = |token: &str| spec.color(token, &inputs);
        let (text_minimum, mark_minimum) = (spec.minimum_text_contrast, spec.minimum_mark_contrast);

        // The app accent when the setting or the theme names one; None
        // keeps the neutral fills (the spec's formulas).
        let app = (input.accent != ThemeAccent::Neutral || input.accent_color.is_some())
            .then(|| AppTheme::derive(bg, fg, &input.palette, input.accent, input.accent_color));
        let accent = app.map(|app| app.get(AppToken::Accent));

        let hover = color("hoverFill");
        // An accent selection is the app theme's (the accent over the background).
        let selection = match accent {
            Some(accent) => accent.with_alpha(if is_dark { 0.26 } else { 0.16 }),
            None => color("selectionFill"),
        };
        // The other rows of a multi-selection: the selection's color at 0.7 of its weight.
        let secondary_selection = match accent {
            Some(accent) => accent.with_alpha(if is_dark { 0.18 } else { 0.11 }),
            None => color("secondarySelectionFill"),
        };
        let pressed = color("pressedFill");
        // Text must hold its contrast on the strongest fill it can sit on.
        let worst_surface = [pressed.composited(bg), selection.composited(bg)]
            .into_iter()
            .min_by(|a, b| fg.contrast(*a).total_cmp(&fg.contrast(*b)))
            .unwrap_or(bg);
        // In a see-through window the quieter inks also hold over the tint
        // on the worst desktop for the theme; the tint stays the opacity.
        let see_through =
            see_through_surfaces(bg, input.background_opacity, is_dark, &[pressed, selection]);
        let (primary, secondary, tertiary) =
            inks(fg, [worst_surface, bg], &see_through, bg, text_minimum, mark_minimum);
        // The config's selection fill, when text reads on it (an
        // inverse-video selection keeps the derived one).
        let config_selection = input
            .selection_background
            .filter(|s| primary.contrast(s.composited(bg)) >= mark_minimum);

        let palette = input.palette;
        let status = |i: usize| readable(palette[i], bg, mark_minimum);

        let highlight = accent.unwrap_or_else(|| status(4));
        let best = |candidates: [Rgb; 2]| {
            if candidates[1].contrast(highlight) > candidates[0].contrast(highlight) {
                candidates[1]
            } else {
                candidates[0]
            }
        };
        let themed = best([bg.with_alpha(1.0), primary.with_alpha(1.0)]);
        let highlight_text = if themed.contrast(highlight) >= text_minimum {
            themed
        } else {
            best([Rgb::hex(0x000000), Rgb::hex(0xFFFFFF)])
        };
        ThemeTokens {
            is_dark,
            window_background: color("windowBackground"),
            sidebar_background: color("sidebarBackground"),
            content_background: color("contentBackground"),
            chrome_background: color("chromeBackground"),
            elevated_background: color("elevatedBackground"),
            strip_background: color("stripBackground"),
            sidebar_step: color("sidebarStep"),
            strip_step: color("stripStep"),
            text_primary: primary,
            text_secondary: secondary,
            text_tertiary: tertiary,
            hover_fill: hover,
            selection_fill: selection,
            secondary_selection_fill: secondary_selection,
            pressed_fill: pressed,
            badge_fill: color("badgeFill"),
            separator: color("separator"),
            pane_border: color("paneBorder"),
            focus_ring: accent.unwrap_or_else(|| color("focusRing")),
            glass_tint: color("glassTint"),
            shadow: color("shadow"),
            text_selection: config_selection.unwrap_or_else(|| bg.mixed(fg, 0.22)),
            attention: status(3),
            danger: status(1),
            success: status(2),
            highlight,
            highlight_text,
            accent: accent.unwrap_or(primary),
            on_accent: app.map_or(bg.with_alpha(1.0), |app| app.get(AppToken::OnAccent)),
            ansi: palette,
            background_opacity: opacity,
            background_blur: input.background_blur,
            caret: input.cursor.map_or(primary, |c| readable(c.with_alpha(1.0), bg, mark_minimum)),
        }
    }

    /// The popup surface (Swift `ThemeTokens.opaqueOverlayFill`,
    /// OverlayMaterial.swift): the opaque window background lifted by up to
    /// `lift` toward white, or on a dark theme whose text is lighter than its
    /// page toward the text (a lighter card), stopping where secondary text
    /// would drop below 4.5:1 on a hovered row. A dark theme with dark text
    /// (Hot Dog Stand's red) lifts toward white: lifting toward the text
    /// would darken the card under it.
    pub fn opaque_overlay_fill(&self, lift: f64) -> Rgb {
        let page = self.window_background.with_alpha(1.0);
        let text = self.text_primary.with_alpha(1.0);
        if !self.is_dark || text.relative_luminance() < page.relative_luminance() {
            return page.mixed(Rgb::WHITE, lift);
        }
        let secondary = self.text_secondary.with_alpha(1.0);
        let mut step = (lift * 100.0).round() / 100.0;
        while step > 0.0 {
            let fill = page.mixed(text, step);
            if secondary.contrast(self.hover_fill.composited(fill)) >= MINIMUM_TEXT_CONTRAST {
                return fill;
            }
            step -= 0.01;
        }
        page
    }

    /// These tokens under `appearance.borders`: `None` makes every border,
    /// separator and the focus ring clear (Swift `Borders.color`).
    pub fn with_borders(mut self, mode: BorderMode) -> Self {
        if !mode.draws_lines() {
            self.separator = self.separator.with_alpha(0.0);
            self.pane_border = self.pane_border.with_alpha(0.0);
            self.focus_ring = self.focus_ring.with_alpha(0.0);
        }
        self
    }
}

/// `color`, pushed away from `surface` (toward white or black) until it
/// reaches `minimum` contrast.
pub fn readable(color: Rgb, surface: Rgb, minimum: f64) -> Rgb {
    if color.contrast(surface) >= minimum {
        return color;
    }
    let pole = if surface.relative_luminance() < 0.18 { Rgb::WHITE } else { Rgb::BLACK };
    let mut step = 0.0;
    let mut candidate = color;
    while step < 1.0 && candidate.contrast(surface) < minimum {
        step += 0.02;
        candidate = color.mixed(pole, step);
    }
    candidate
}

/// The primary, secondary and tertiary text for `foreground`, read on both
/// `rows` (the strongest row fill and the bare background; port of Swift
/// `ThemeTokens.inks`). A foreground that already reads keeps its color.
/// Otherwise it is walked toward white and toward black (the pole that reads
/// better on the row fill first), and the candidate whose primary and
/// secondary keep the higher least contrast over `rows` wins, capped at
/// `text_minimum` (a tie keeps the first). Hot Dog Stand's white on red
/// reaches only 4.20:1, so it takes the dark ink; Grass's dark ink drops to
/// 3.73:1 on its background, so it takes white.
pub fn inks(
    foreground: Rgb,
    rows: [Rgb; 2],
    see_through: &[Rgb],
    bg: Rgb,
    text_minimum: f64,
    mark_minimum: f64,
) -> (Rgb, Rgb, Rgb) {
    let least = |ink: Rgb| rows.iter().map(|row| ink.contrast(*row)).fold(f64::INFINITY, f64::min);
    let poles = if Rgb::BLACK.contrast(rows[0]) > Rgb::WHITE.contrast(rows[0]) {
        [Rgb::BLACK, Rgb::WHITE]
    } else {
        [Rgb::WHITE, Rgb::BLACK]
    };
    let mut chosen: Option<(f64, (Rgb, Rgb, Rgb))> = None;
    for pole in poles {
        let primary = readable_over(foreground, &rows, pole, text_minimum);
        let ink_surface = rows
            .iter()
            .chain(see_through)
            .copied()
            .min_by(|a, b| primary.contrast(*a).total_cmp(&primary.contrast(*b)))
            .unwrap_or(bg);
        let secondary = muted(primary, bg, 0.38, ink_surface, text_minimum);
        let tertiary = muted(primary, bg, 0.55, ink_surface, mark_minimum);
        let score = least(primary).min(least(secondary)).min(text_minimum);
        if chosen.is_none_or(|(best, _)| score > best) {
            chosen = Some((score, (primary, secondary, tertiary)));
        }
    }
    chosen.map_or((foreground, foreground, foreground), |(_, inks)| inks)
}

/// `color` walked toward `pole` until it reaches `minimum` contrast over
/// every surface (or `pole`); port of Swift `ThemeTokens.readable(_:over:toward:minimum:)`.
pub fn readable_over(color: Rgb, surfaces: &[Rgb], pole: Rgb, minimum: f64) -> Rgb {
    let reads = |ink: Rgb| surfaces.iter().all(|surface| ink.contrast(*surface) >= minimum);
    let mut step = 0.0;
    let mut candidate = color;
    while step < 1.0 && !reads(candidate) {
        step += 0.02;
        candidate = color.mixed(pole, step);
    }
    candidate
}

/// What text sits on in a window of `opacity` below 1 (port of
/// `ThemeTokens.seeThroughSurfaces`): the background at that opacity over the
/// worst desktop for the theme (black behind a light theme, white behind a
/// dark one), alone and under each of `fills`. Empty for an opaque window.
pub fn see_through_surfaces(bg: Rgb, opacity: f64, is_dark: bool, fills: &[Rgb]) -> Vec<Rgb> {
    if opacity >= 1.0 {
        return Vec::new();
    }
    let tint = bg.with_alpha(opacity).composited(if is_dark { Rgb::WHITE } else { Rgb::BLACK });
    std::iter::once(tint).chain(fills.iter().map(|fill| fill.composited(tint))).collect()
}

/// `color` mixed toward `target` as far as `limit` allows while keeping
/// `minimum` contrast over `surface`.
pub fn muted(color: Rgb, target: Rgb, limit: f64, surface: Rgb, minimum: f64) -> Rgb {
    let mut fraction = limit;
    while fraction > 0.0 {
        let candidate = color.mixed(target, fraction);
        if candidate.contrast(surface) >= minimum {
            return candidate;
        }
        fraction -= 0.01;
    }
    color
}
