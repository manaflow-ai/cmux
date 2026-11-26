//! Group glass (Swift `GroupGlass/GroupGlassPaint.swift` with its `over`,
//! `GroupGlass/GroupChipGlass.swift`, and `GroupTint.glassRGB`/`lineRGB`).

use super::background::{GroupBackground, MINIMUM_VISIBLE_CONTRAST, Strength, glass_fill, visible};
use super::colors::{MINIMUM_MARK_CONTRAST, MINIMUM_TEXT_CONTRAST, palette_rgb};
use super::kinds::{
    GroupGradient, GroupPalette, GroupTheme, GroupTint, SidebarGroupBackgroundStyle,
    SidebarGroupGlass, Wallpaper,
};
use crate::tokens::color::Rgb;
use cmux_theme_tokens::readable;

/// The no-color pane's opacity (Swift `GroupGlassPaint.neutralOpacity`).
pub const NEUTRAL_OPACITY: f64 = 0.3;

/// The default push away from grey for a glass tint (Swift `glassRGB(palette:vividness:)`).
pub const DEFAULT_VIVIDNESS: f64 = 1.3;

/// Source-over: `top` painted over `bottom`, both translucent (Swift `GroupGlassPaint.over`).
pub fn over(top: Rgb, bottom: Rgb) -> Rgb {
    let alpha = top.a + bottom.a * (1.0 - top.a);
    if alpha <= 0.0 {
        return top;
    }
    let mix = |t: f64, b: f64| (t * top.a + b * bottom.a * (1.0 - top.a)) / alpha;
    Rgb::new(mix(top.r, bottom.r), mix(top.g, bottom.g), mix(top.b, bottom.b), alpha)
}

/// The tint's line color: the palette color, a custom color readable as a mark, or the sidebar
/// at zero opacity (Swift `GroupTint.lineRGB(palette:)`).
pub fn line_rgb(
    tint: GroupTint,
    palette: GroupPalette,
    theme: &GroupTheme,
    wallpaper: Option<&Wallpaper>,
    gradient: GroupGradient,
) -> Rgb {
    match tint {
        GroupTint::Palette(token) => palette_rgb(token, palette, theme, wallpaper, gradient),
        GroupTint::Custom(rgb) => {
            readable(Rgb::from(rgb).with_alpha(1.0), theme.sidebar(), MINIMUM_MARK_CONTRAST)
        }
        GroupTint::None => theme.sidebar().with_alpha(0.0),
    }
}

/// The line color pushed `vividness` away from its grey, opaque; no color gives the theme text
/// (Swift `GroupTint.glassRGB(palette:vividness:)`).
pub fn glass_rgb(
    tint: GroupTint,
    palette: GroupPalette,
    theme: &GroupTheme,
    wallpaper: Option<&Wallpaper>,
    gradient: GroupGradient,
    vividness: f64,
) -> Rgb {
    if tint.is_none() {
        return theme.text().with_alpha(1.0);
    }
    let rgb = line_rgb(tint, palette, theme, wallpaper, gradient);
    let grey = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b;
    let push = |c: f64| (grey + (c - grey) * vividness).clamp(0.0, 1.0);
    Rgb::new(push(rgb.r), push(rgb.g), push(rgb.b), 1.0)
}

/// What a glass group header or chip paints (Swift `GroupGlassPaint`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GroupGlassPaint {
    /// What to paint (translucent unless `opaque`).
    pub fill: Rgb,
    /// What the person sees over the ground (opaque).
    pub shown: Rgb,
    /// The name's ink.
    pub ink: Rgb,
}

/// The inputs to [`glass_paint`] (Swift `GroupGlassPaint.init`, with what it reads from the
/// app passed in: the group role's veil and the wallpaper and gradient settings).
#[derive(Debug, Clone, PartialEq)]
pub struct GlassPaintInput<'a> {
    /// The group's color.
    pub tint: GroupTint,
    /// The sidebar palette.
    pub palette: GroupPalette,
    /// The glass strength.
    pub glass: SidebarGroupGlass,
    /// The theme.
    pub theme: &'a GroupTheme,
    /// The surface under the glass; the sidebar when `None`.
    pub ground: Option<Rgb>,
    /// State steps (hover, pressed) painted over the pane.
    pub steps: &'a [Rgb],
    /// Whether to paint the opaque `shown` instead of the glass.
    pub opaque: bool,
    /// The group role's veil (Swift `FloatingGlassStyle.group.look(isDark:).veil`: white, alpha).
    pub veil: Rgb,
    /// The desktop picture (Swift `GroupTint.wallpaper`).
    pub wallpaper: Option<&'a Wallpaper>,
    /// The gradient setting (Swift `sidebarSections.groupGradient`).
    pub gradient: GroupGradient,
}

/// The glass pane: the tint over the role's veil, steps over that, kept visible against the
/// ground (Swift `GroupGlassPaint.init(tint:palette:glass:tokens:ground:steps:opaque:)`).
pub fn glass_paint(input: &GlassPaintInput<'_>) -> GroupGlassPaint {
    let theme = input.theme;
    let ground = input.ground.unwrap_or_else(|| theme.sidebar()).with_alpha(1.0);
    let glass = if input.glass == SidebarGroupGlass::Solid {
        SidebarGroupGlass::Vivid
    } else {
        input.glass
    };
    let pane = if input.tint.is_none() {
        let neutral = GroupBackground::new(
            GroupTint::None,
            Strength::Band,
            false,
            input.palette,
            None,
            theme,
        );
        glass_fill(neutral.shown, ground, NEUTRAL_OPACITY)
    } else {
        let rgb = glass_rgb(
            input.tint,
            input.palette,
            theme,
            input.wallpaper,
            input.gradient,
            DEFAULT_VIVIDNESS,
        );
        over(rgb.with_alpha(glass.tint(theme.is_dark)), input.veil)
    };
    let mut fill = input.steps.iter().fold(pane, |acc, step| over(*step, acc));
    let mut shown = fill.composited(ground).with_alpha(1.0);
    if shown.contrast(ground) < MINIMUM_VISIBLE_CONTRAST {
        shown = visible(shown, ground);
        fill = glass_fill(shown, ground, fill.a);
    }
    let ink = readable(theme.text().with_alpha(1.0), shown, MINIMUM_TEXT_CONTRAST);
    GroupGlassPaint { fill: if input.opaque { shown } else { fill }, shown, ink }
}

/// Whether a tab strip's group chip draws as glass: a look the strip does not take falls back
/// to auto (Swift `GroupChipGlass.drawsGlass`).
pub fn chip_draws_glass(glass: SidebarGroupGlass, background: SidebarGroupBackgroundStyle) -> bool {
    let look = if background.draws_on_tab_strip() {
        background
    } else {
        SidebarGroupBackgroundStyle::Auto
    };
    look.draws_glass(glass != SidebarGroupGlass::Solid)
}

/// A chip's glass over the chrome, or `None` when it draws no glass or has no color (Swift
/// `GroupChipGlass.paint(tint:tokens:steps:opaque:)`). `chrome` is the theme's
/// `chromeBackground`; `input.ground` is ignored.
pub fn chip_glass_paint(
    background: SidebarGroupBackgroundStyle,
    chrome: Rgb,
    input: &GlassPaintInput<'_>,
) -> Option<GroupGlassPaint> {
    if !chip_draws_glass(input.glass, background) || input.tint.is_none() {
        return None;
    }
    Some(glass_paint(&GlassPaintInput { ground: Some(chrome), ..input.clone() }))
}
