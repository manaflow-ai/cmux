//! `ThemeTokens::derive`: every chrome color from the terminal theme. A
//! line-by-line port of cmux-next `ThemeTokens.swift` (CmuxTheme package on
//! `feat-cmux-next`); keep the numbers in sync with it.

use crate::Rgb;

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
    };
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
/// `#[repr(C)]` (a C caller reads it field by field). Field docs follow the
/// Swift ones.
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
    /// Swift's pane strip tint (a shade darker than the window). Kept for
    /// parity; cmux2 draws strips flat on `window_background`.
    pub strip_background: Rgb,

    // Text
    /// Titles and body text: the foreground, pushed to 4.5:1 when needed.
    pub text_primary: Rgb,
    /// Captions, inactive titles. At least 4.5:1 on every fill.
    pub text_secondary: Rgb,
    /// Hints and placeholders. At least 3:1 on every fill.
    pub text_tertiary: Rgb,

    // Fills (translucent foreground over the surface)
    pub hover_fill: Rgb,
    pub selection_fill: Rgb,
    pub secondary_selection_fill: Rgb,
    pub pressed_fill: Rgb,
    pub badge_fill: Rgb,
    /// Hairlines between sections.
    pub separator: Rgb,
    /// The subtle hairline around each pane's content.
    pub pane_border: Rgb,
    /// The keyboard focus outline.
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
    /// The one action color (ANSI blue, at least 3:1). Not used by chrome
    /// fills: there is no accent.
    pub highlight: Rgb,
    pub highlight_text: Rgb,
    /// ANSI 0...15.
    pub ansi: [Rgb; 16],

    pub background_opacity: f64,
    pub background_blur: i32,
}

/// Minimum contrast for primary and secondary chrome text.
pub const MINIMUM_TEXT_CONTRAST: f64 = 4.5;
/// Minimum contrast for tertiary text and status marks.
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
        let pick = |dark: f64, light: f64| if is_dark { dark } else { light };

        let hover = fg.with_alpha(pick(0.06, 0.05));
        let selection = fg.with_alpha(pick(0.10, 0.08));
        let pressed = fg.with_alpha(pick(0.14, 0.11));
        // Text must hold its contrast on the strongest fill it can sit on.
        let worst_surface = pressed.composited(bg);
        let primary = readable(fg, worst_surface, MINIMUM_TEXT_CONTRAST);
        let secondary = muted(primary, bg, 0.38, worst_surface, MINIMUM_TEXT_CONTRAST);
        let tertiary = muted(primary, bg, 0.55, worst_surface, MINIMUM_MARK_CONTRAST);

        let palette = input.palette;
        let status = |i: usize| readable(palette[i], bg, MINIMUM_MARK_CONTRAST);

        let opacity = input.background_opacity.clamp(0.0, 1.0);
        let surface = bg.with_alpha(opacity);
        let highlight = status(4);
        let best = |candidates: [Rgb; 2]| {
            if candidates[1].contrast(highlight) > candidates[0].contrast(highlight) {
                candidates[1]
            } else {
                candidates[0]
            }
        };
        let themed = best([bg.with_alpha(1.0), primary.with_alpha(1.0)]);
        let highlight_text = if themed.contrast(highlight) >= MINIMUM_TEXT_CONTRAST {
            themed
        } else {
            best([Rgb::hex(0x000000), Rgb::hex(0xFFFFFF)])
        };
        ThemeTokens {
            is_dark,
            window_background: surface,
            sidebar_background: surface,
            content_background: surface,
            chrome_background: bg.mixed(fg, pick(0.05, 0.035)),
            elevated_background: bg.mixed(fg, pick(0.07, 0.02)),
            strip_background: bg.mixed(Rgb::BLACK, pick(0.22, 0.05)).with_alpha(opacity),
            text_primary: primary,
            text_secondary: secondary,
            text_tertiary: tertiary,
            hover_fill: hover,
            selection_fill: selection,
            secondary_selection_fill: fg.with_alpha(pick(0.07, 0.055)),
            pressed_fill: pressed,
            badge_fill: fg.with_alpha(pick(0.14, 0.10)),
            separator: fg.with_alpha(pick(0.08, 0.07)),
            pane_border: fg.with_alpha(pick(0.07, 0.09)),
            focus_ring: fg.with_alpha(0.40),
            glass_tint: bg.with_alpha(pick(0.40, 0.30)),
            shadow: bg.mixed(Rgb::BLACK, 0.85),
            text_selection: input.selection_background.unwrap_or_else(|| bg.mixed(fg, 0.22)),
            attention: status(3),
            danger: status(1),
            success: status(2),
            highlight,
            highlight_text,
            ansi: palette,
            background_opacity: opacity,
            background_blur: input.background_blur,
        }
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
