//! A group header's band or wash (Swift `GroupBackground.swift`), with the two ink rules it
//! calls (Swift `ThemeTokens.glyphInk(base:)` and `ThemeTokens.chip(_:inks:)`, `GlyphInk.swift`).

use super::colors::{
    MINIMUM_MARK_CONTRAST, MINIMUM_TEXT_CONTRAST, header_rgb, palette_rgb, swatch_rgb,
};
use super::kinds::{GroupGradient, GroupPalette, GroupTheme, GroupTint, Wallpaper};
use crate::tokens::color::Rgb;
use cmux_theme_tokens::readable;
use serde::{Deserialize, Serialize};

/// The contrast a header keeps against the sidebar (Swift `GroupBackground.minimumVisibleContrast`).
pub const MINIMUM_VISIBLE_CONTRAST: f64 = 1.2;

/// A glass header's opacity (Swift `GroupBackground.glassOpacity`).
pub const GLASS_OPACITY: f64 = 0.6;

/// The dark ink the chip and glyph rules try (`0x1F1F1F`).
const DARK_INK: u32 = 0x1F1F1F;

/// How strongly the header draws (Swift `GroupBackground.Strength`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Strength {
    /// A bar carrying the name.
    Band,
    /// A faint wash behind the group.
    Wash,
}

/// Which inks a chip tries (Swift `ChipInks`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChipInks {
    /// The theme's text first.
    Theme,
    /// Dark or white, whichever reads better on the color.
    OnColor,
}

/// A group header's paint (Swift `GroupBackground`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GroupBackground {
    /// What to paint (translucent for glass).
    pub fill: Rgb,
    /// What the person sees over the sidebar (opaque).
    pub shown: Rgb,
    /// The name's ink.
    pub ink: Rgb,
    /// A glass header's rim; `None` for solid.
    pub rim: Option<Rgb>,
    /// The opaque sidebar under it.
    pub ground: Rgb,
}

/// The first color with the largest score (Swift `max(by:)` keeps the first of equals).
fn first_max(candidates: &[Rgb], score: impl Fn(Rgb) -> f64) -> Option<Rgb> {
    let mut best: Option<Rgb> = None;
    for &c in candidates {
        if best.is_none_or(|b| score(b) < score(c)) {
            best = Some(c);
        }
    }
    best
}

/// The glyph ink that reads at 4.5:1 on `base` at rest, hovered and pressed (Swift
/// `ThemeTokens.glyphInk(over: nil, base:)`).
pub fn glyph_ink(theme: &GroupTheme, base: Rgb) -> Rgb {
    let surface = base.with_alpha(1.0);
    let states = [surface, theme.hover().composited(surface), theme.pressed().composited(surface)];
    let worst = |ink: Rgb| states.iter().map(|s| ink.contrast(*s)).reduce(f64::min).unwrap_or(1.0);
    let candidates = [theme.text().composited(surface), Rgb::hex(DARK_INK), Rgb::WHITE, Rgb::BLACK];
    if let Some(fit) = candidates.iter().copied().find(|c| worst(*c) >= MINIMUM_TEXT_CONTRAST) {
        return fit;
    }
    let best = first_max(&candidates, worst).unwrap_or(Rgb::WHITE);
    let mut hardest = states[0];
    for s in states {
        if best.contrast(s) < best.contrast(hardest) {
            hardest = s;
        }
    }
    readable(best, hardest, MINIMUM_TEXT_CONTRAST)
}

/// A chip's bar and ink: the ink that reads at rest, hovered and dropped, the bar pushed away
/// from it when none does (Swift `ThemeTokens.chip(_:inks:)`). Returns `(fill, ink)`.
pub fn chip(theme: &GroupTheme, color: Rgb, inks: ChipInks) -> (Rgb, Rgb) {
    let bar = color.with_alpha(1.0);
    let mut poles = [Rgb::hex(DARK_INK), Rgb::WHITE];
    if poles[1].contrast(bar) > poles[0].contrast(bar) {
        poles.swap(0, 1);
    }
    let candidates: Vec<Rgb> = match inks {
        ChipInks::Theme => vec![theme.text().composited(bar), Rgb::hex(DARK_INK), Rgb::WHITE],
        ChipInks::OnColor => poles.to_vec(),
    };
    let (hover, pressed) = (theme.hover(), theme.pressed());
    let states = |bar: Rgb| -> Vec<Rgb> {
        let hovered = hover.composited(bar);
        let dropped = pressed.composited(bar);
        let mut out = vec![bar, hovered, dropped];
        for x in [bar, hovered, dropped] {
            out.push(hover.composited(x));
            out.push(pressed.composited(x));
        }
        out
    };
    let worst = |ink: Rgb, bar: Rgb| {
        states(bar).iter().map(|s| ink.contrast(*s)).reduce(f64::min).unwrap_or(1.0)
    };
    let ink = candidates
        .iter()
        .copied()
        .find(|c| worst(*c, bar) >= MINIMUM_TEXT_CONTRAST)
        .or_else(|| first_max(&candidates, |c| worst(c, bar)))
        .unwrap_or(Rgb::WHITE);
    let pole = if ink.relative_luminance() > 0.5 { Rgb::BLACK } else { Rgb::WHITE };
    let mut fill = bar;
    let mut step = 0.0;
    while worst(ink, fill) < MINIMUM_TEXT_CONTRAST && step < 1.0 {
        step += 0.02;
        fill = bar.mixed(pole, step);
    }
    (fill, ink)
}

/// `color`, opaque, pushed away from `ground` until it stands 1.2:1 apart (Swift
/// `GroupBackground.visible(_:over:)`).
pub fn visible(color: Rgb, ground: Rgb) -> Rgb {
    let opaque = color.with_alpha(1.0);
    if opaque.contrast(ground) >= MINIMUM_VISIBLE_CONTRAST {
        return opaque;
    }
    let (lum, ground_lum) = (opaque.relative_luminance(), ground.relative_luminance());
    // Away from the ground's side; equal luminance goes toward the far pole.
    let first = if lum < ground_lum || (lum == ground_lum && ground_lum >= 0.18) {
        Rgb::BLACK
    } else {
        Rgb::WHITE
    };
    let second = if first == Rgb::BLACK { Rgb::WHITE } else { Rgb::BLACK };
    for pole in [first, second] {
        let mut step = 0.0;
        let mut candidate = opaque;
        while step < 1.0 && candidate.contrast(ground) < MINIMUM_VISIBLE_CONTRAST {
            step += 0.02;
            candidate = opaque.mixed(pole, step);
        }
        if candidate.contrast(ground) >= MINIMUM_VISIBLE_CONTRAST {
            return candidate;
        }
    }
    if opaque.contrast(Rgb::WHITE) > opaque.contrast(Rgb::BLACK) { Rgb::WHITE } else { Rgb::BLACK }
}

/// The translucent fill that composites over `ground` to `shown`, at least `opacity` opaque
/// (Swift `GroupBackground.glassFill(showing:over:opacity:)`).
pub fn glass_fill(shown: Rgb, ground: Rgb, opacity: f64) -> Rgb {
    let pairs = [(shown.r, ground.r), (shown.g, ground.g), (shown.b, ground.b)];
    let needed = pairs
        .iter()
        .map(|&(s, g)| {
            if s > g {
                if g < 1.0 { (s - g) / (1.0 - g) } else { 1.0 }
            } else if s < g {
                if g > 0.0 { (g - s) / g } else { 1.0 }
            } else {
                0.0
            }
        })
        .reduce(f64::max)
        .unwrap_or(0.0);
    let alpha = opacity.max(needed).min(1.0);
    let channel = |s: f64, g: f64| (g + (s - g) / alpha).clamp(0.0, 1.0);
    Rgb::new(
        channel(shown.r, ground.r),
        channel(shown.g, ground.g),
        channel(shown.b, ground.b),
        alpha,
    )
}

impl GroupBackground {
    /// The header for `tint` at `strength`, glass or solid, under `palette` (Swift
    /// `GroupBackground.init(tint:strength:glass:palette:wallpaper:tokens:)`). A gradient-palette
    /// token takes the default gradient (sunset), as in Swift.
    pub fn new(
        tint: GroupTint,
        strength: Strength,
        glass: bool,
        palette: GroupPalette,
        wallpaper: Option<&Wallpaper>,
        theme: &GroupTheme,
    ) -> Self {
        let fixed = palette.drawn() == GroupPalette::Vibrant;
        let ground = theme.sidebar().with_alpha(1.0);
        let text = theme.text().with_alpha(1.0);
        let dark = theme.is_dark;
        let color = match tint {
            GroupTint::Palette(token) => {
                if fixed {
                    None
                } else {
                    Some(palette_rgb(token, palette, theme, wallpaper, GroupGradient::Sunset))
                }
            }
            GroupTint::Custom(rgb) => {
                Some(readable(Rgb::from(rgb).with_alpha(1.0), ground, MINIMUM_MARK_CONTRAST))
            }
            GroupTint::None => None,
        };
        let pick = |d: f64, l: f64| if dark { d } else { l };
        let mut inks = ChipInks::Theme;
        let base = match (strength, tint) {
            (Strength::Band, GroupTint::None) => ground.mixed(text, pick(0.12, 0.07)),
            (Strength::Band, GroupTint::Palette(token)) if fixed => {
                inks = ChipInks::OnColor;
                header_rgb(token, theme)
            }
            (Strength::Band, GroupTint::Palette(_)) => {
                ground.mixed(color.unwrap_or(text), pick(0.34, 0.26))
            }
            (Strength::Band, GroupTint::Custom(_)) => {
                inks = ChipInks::OnColor;
                color.unwrap_or(text)
            }
            (Strength::Wash, GroupTint::None) => ground.mixed(text, pick(0.08, 0.05)),
            (Strength::Wash, GroupTint::Palette(token)) => {
                ground.mixed(color.unwrap_or_else(|| swatch_rgb(token, theme)), pick(0.14, 0.10))
            }
            (Strength::Wash, GroupTint::Custom(_)) => {
                ground.mixed(color.unwrap_or(text), pick(0.14, 0.10))
            }
        };
        let target = visible(base, ground);
        let (shown, ink) = match strength {
            Strength::Band => {
                let (mut shown, mut ink) = chip(theme, target, inks);
                if shown.contrast(ground) < MINIMUM_VISIBLE_CONTRAST {
                    shown = visible(shown, ground);
                    ink = glyph_ink(theme, shown);
                }
                (shown, ink)
            }
            Strength::Wash => (target, glyph_ink(theme, target)),
        };
        let shown = shown.with_alpha(1.0);
        let (fill, rim) = if glass {
            (glass_fill(shown, ground, GLASS_OPACITY), Some(text.with_alpha(pick(0.16, 0.12))))
        } else {
            (shown, None)
        };
        GroupBackground { fill, shown, ink, rim, ground }
    }

    /// Whether the header draws as glass (Swift `isGlass`).
    pub fn is_glass(&self) -> bool {
        self.rim.is_some()
    }

    /// The fill with state steps (hover, pressed) painted over the shown color, kept visible
    /// (Swift `GroupBackground.painted(over:)`).
    pub fn painted(&self, steps: &[Rgb]) -> Rgb {
        if steps.is_empty() {
            return self.fill;
        }
        let stepped =
            visible(steps.iter().fold(self.shown, |acc, step| step.composited(acc)), self.ground);
        if self.is_glass() { glass_fill(stepped, self.ground, GLASS_OPACITY) } else { stepped }
    }
}
