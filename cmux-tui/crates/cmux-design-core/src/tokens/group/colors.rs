//! Group colors per palette (Swift `GroupColor+Palette.swift`, `GroupColor+Distinct.swift`,
//! `GroupColor+Theme.themeRGB`): the next automatic color, perceptual distance, and the theme,
//! grayscale, wallpaper, pictorial and gradient palettes.

use super::kinds::{
    ColorRole, GroupColor, GroupGradient, GroupPalette, GroupTheme, GroupTint, Wallpaper,
};
use crate::tokens::color::Rgb;
use cmux_theme_tokens::{Oklch, from_oklch, oklch, readable};

/// The contrast a mark (dot, line, swatch) keeps over the sidebar (Swift
/// `ThemeTokens.minimumMarkContrast`).
pub const MINIMUM_MARK_CONTRAST: f64 = 3.0;

/// The contrast text keeps over its surface (Swift `ThemeTokens.minimumTextContrast`).
pub const MINIMUM_TEXT_CONTRAST: f64 = 4.5;

/// The order new groups take colors in (Swift `GroupColor.paletteOrder`): no grey, no blue.
pub const PALETTE_ORDER: [GroupColor; 7] = [
    GroupColor::Purple,
    GroupColor::Orange,
    GroupColor::Cyan,
    GroupColor::Red,
    GroupColor::Green,
    GroupColor::Pink,
    GroupColor::Yellow,
];

/// The swatch in the theme's variant (Swift `GroupColor.swatchRGB(_:)`).
pub fn swatch_rgb(color: GroupColor, theme: &GroupTheme) -> Rgb {
    color.rgb(ColorRole::Swatch, theme.is_dark)
}

/// The header fill in the theme's variant (Swift `GroupColor.fillRGB(_:)` and `headerRGB(_:)`).
pub fn header_rgb(color: GroupColor, theme: &GroupTheme) -> Rgb {
    color.rgb(ColorRole::Fill, theme.is_dark)
}

/// The fewest-used palette color, the earlier on a tie (Swift `GroupColor.automatic(existing:)`).
pub fn automatic(existing: &[GroupTint]) -> GroupColor {
    let count = |c: GroupColor| existing.iter().filter(|t| **t == GroupTint::Palette(c)).count();
    let mut best = PALETTE_ORDER.first().copied().unwrap_or(GroupColor::Purple);
    for c in PALETTE_ORDER {
        if count(c) < count(best) {
            best = c;
        }
    }
    best
}

/// The next new profile's color: of the least-used colors, the one farthest from the colors
/// already used more (or from the last one) (Swift `GroupColor.automatic(after:)`).
pub fn automatic_after(existing: &[String]) -> GroupColor {
    let tokens: Vec<GroupColor> = existing.iter().filter_map(|s| GroupColor::from_raw(s)).collect();
    let count = |c: GroupColor| tokens.iter().filter(|t| **t == c).count();
    let round = PALETTE_ORDER.iter().map(|c| count(*c)).min().unwrap_or(0);
    let open: Vec<GroupColor> = PALETTE_ORDER.into_iter().filter(|c| count(*c) == round).collect();
    let mut near: Vec<GroupColor> =
        PALETTE_ORDER.into_iter().filter(|c| count(*c) > round).collect();
    near.extend(tokens.iter().copied().filter(|t| !PALETTE_ORDER.contains(t)));
    let reference: Vec<GroupColor> =
        if near.is_empty() { tokens.last().copied().into_iter().collect() } else { near };
    if reference.is_empty() {
        return open.first().copied().unwrap_or(GroupColor::Purple);
    }
    let mut best = open.first().copied().unwrap_or(GroupColor::Purple);
    let mut best_distance = -1.0;
    for color in open {
        let distance = reference
            .iter()
            .map(|r| perceptual_distance(color, *r))
            .reduce(f64::min)
            .unwrap_or(0.0);
        if distance > best_distance + 1e-9 {
            best = color;
            best_distance = distance;
        }
    }
    best
}

/// A point in OKLab (Swift `OKLabPoint`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OkLabPoint {
    /// Lightness.
    pub lightness: f64,
    /// Green-red axis.
    pub a: f64,
    /// Blue-yellow axis.
    pub b: f64,
}

impl OkLabPoint {
    /// The OKLab point of `color`, from its OKLCH (Swift `GroupColor.oklab(_:)`).
    pub fn of(color: Rgb) -> Self {
        let lch = oklch(color);
        let radians = lch.h * std::f64::consts::PI / 180.0;
        OkLabPoint { lightness: lch.l, a: lch.c * radians.cos(), b: lch.c * radians.sin() }
    }

    /// Euclidean distance (Swift `OKLabPoint.distance(to:)`).
    pub fn distance(self, other: OkLabPoint) -> f64 {
        let (dl, da, db) = (self.lightness - other.lightness, self.a - other.a, self.b - other.b);
        (dl * dl + da * da + db * db).sqrt()
    }
}

/// The smaller OKLab distance between two colors' swatches, dark or light (Swift
/// `GroupColor.perceptualDistance(to:)`).
pub fn perceptual_distance(color: GroupColor, other: GroupColor) -> f64 {
    let d = |dark: bool| {
        OkLabPoint::of(color.rgb(ColorRole::Swatch, dark))
            .distance(OkLabPoint::of(other.rgb(ColorRole::Swatch, dark)))
    };
    d(true).min(d(false))
}

/// The color from the theme's ANSI palette, readable as a mark over the sidebar; `None` for grey
/// or a palette under 8 colors (Swift `GroupColor.themeRGB(_:)`).
pub fn theme_rgb(color: GroupColor, theme: &GroupTheme) -> Option<Rgb> {
    let p: Vec<Rgb> = theme.ansi.iter().map(|c| Rgb::from(*c)).collect();
    if p.len() < 8 {
        return None;
    }
    let ansi = |index: usize| p.get(index).copied().unwrap_or(Rgb::WHITE);
    let rgb = match color {
        GroupColor::Grey => return None,
        GroupColor::Red => ansi(1),
        GroupColor::Green => ansi(2),
        GroupColor::Yellow => ansi(3),
        GroupColor::Blue => ansi(4),
        GroupColor::Purple => ansi(5),
        GroupColor::Cyan => ansi(6),
        GroupColor::Pink => {
            if p.len() > 13 {
                ansi(13)
            } else {
                ansi(5).mixed(ansi(1), 0.35)
            }
        }
        GroupColor::Orange => ansi(1).mixed(ansi(3), 0.5),
    };
    Some(readable(rgb.with_alpha(1.0), theme.sidebar(), MINIMUM_MARK_CONTRAST))
}

/// The grey a color takes under the grayscale palette (Swift `GroupColor.grayscaleRGB(dark:)`).
pub fn grayscale_rgb(color: GroupColor, dark: bool) -> Rgb {
    let (d, l) = match color {
        GroupColor::Purple => (0xE6E4E0, 0xA6A4A0),
        GroupColor::Orange => (0x827874, 0x615754),
        GroupColor::Cyan => (0xBCBDC4, 0x88898F),
        GroupColor::Red => (0x8A7A76, 0x665856),
        GroupColor::Green => (0xC9CFCB, 0x939A95),
        GroupColor::Pink => (0x857A82, 0x63585F),
        GroupColor::Yellow => (0xD7CFC9, 0x9D9590),
        GroupColor::Blue => (0x8B9C9D, 0x627273),
        GroupColor::Grey => (0xA1A1AA, 0x8E8E93),
    };
    Rgb::hex(if dark { d } else { l })
}

/// HSB hue (0..<1) and saturation of an sRGB color, as `NSColor.hueComponent` and
/// `saturationComponent` read them.
pub fn hue_saturation(r: f64, g: f64, b: f64) -> (f64, f64) {
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let delta = max - min;
    let saturation = if max > 0.0 { delta / max } else { 0.0 };
    if delta <= 0.0 {
        return (0.0, saturation);
    }
    let mut hue = if max == r {
        (g - b) / delta
    } else if max == g {
        2.0 + (b - r) / delta
    } else {
        4.0 + (r - g) / delta
    } / 6.0;
    if hue < 0.0 {
        hue += 1.0;
    }
    (hue, saturation)
}

/// sRGB from HSB, hue 0...1 (`NSColor(hue:saturation:brightness:alpha:)` read in sRGB).
pub fn hsb_rgb(hue: f64, saturation: f64, brightness: f64) -> Rgb {
    // NSColor clamps each component to 0...1 and treats hue 1 as hue 0 (red).
    let (hue, saturation, brightness) =
        (hue.clamp(0.0, 1.0), saturation.clamp(0.0, 1.0), brightness.clamp(0.0, 1.0));
    if saturation <= 0.0 {
        return Rgb::new(brightness, brightness, brightness, 1.0);
    }
    let h = if hue >= 1.0 { 0.0 } else { hue * 6.0 };
    // A hue a hair under 1 can round to 6: that is sector 0 again.
    let sector = if h.floor() >= 6.0 { 0.0 } else { h.floor() };
    let f = h - h.floor();
    let p = brightness * (1.0 - saturation);
    let q = brightness * (1.0 - saturation * f);
    let t = brightness * (1.0 - saturation * (1.0 - f));
    let (r, g, b) = match sector as i64 {
        0 => (brightness, t, p),
        1 => (q, brightness, p),
        2 => (p, brightness, t),
        3 => (p, q, brightness),
        4 => (t, p, brightness),
        _ => (brightness, p, q),
    };
    Rgb::new(r, g, b, 1.0)
}

/// The color a hue offset from the desktop picture's; a grey picture gives the grayscale palette
/// (Swift `GroupColor.wallpaperRGB(_:dark:)`).
pub fn wallpaper_rgb(color: GroupColor, wallpaper: &Wallpaper, dark: bool) -> Rgb {
    let w = wallpaper.clamped();
    let (picture_hue, picture_saturation) = hue_saturation(w.red, w.green, w.blue);
    if picture_saturation < 0.08 {
        return grayscale_rgb(color, dark);
    }
    let offset = match color {
        GroupColor::Red => -30.0,
        GroupColor::Orange => -10.0,
        GroupColor::Yellow => 15.0,
        GroupColor::Green => 40.0,
        GroupColor::Cyan => 160.0,
        GroupColor::Blue => 190.0,
        GroupColor::Purple => 215.0,
        GroupColor::Pink => -55.0,
        GroupColor::Grey => 0.0,
    };
    let hue = (picture_hue * 360.0 + offset + 360.0) % 360.0 / 360.0;
    let saturation = if color == GroupColor::Grey {
        0.08
    } else if dark {
        0.5
    } else {
        0.62
    };
    hsb_rgb(hue, saturation, if dark { 0.95 } else { 0.78 })
}

/// The color at `place` down the sidebar from the picture's bands: the band's hue at lightness
/// 0.72, its chroma lifted into 0.08...0.18 unless it is grey (Swift `GroupColor.pictorialRGB`).
pub fn pictorial_rgb(bands: &[Wallpaper], place: f64) -> Rgb {
    if bands.is_empty() {
        return Rgb::WHITE;
    }
    let index =
        ((place.clamp(0.0, 1.0) * bands.len() as f64).floor() as usize).min(bands.len() - 1);
    let band = bands.get(index).cloned().unwrap_or_default().clamped();
    let lch = oklch(Rgb::new(band.red, band.green, band.blue, 1.0));
    let chroma = if lch.c < 0.02 { lch.c } else { (lch.c * 1.4).clamp(0.08, 0.18) };
    from_oklch(Oklch { l: 0.72, c: chroma, h: lch.h })
}

/// The color a token draws in under `palette`, held to a mark's contrast over the sidebar
/// (vibrant and glass return the swatch as is) (Swift `GroupColor.paletteRGB`).
pub fn palette_rgb(
    color: GroupColor,
    palette: GroupPalette,
    theme: &GroupTheme,
    wallpaper: Option<&Wallpaper>,
    gradient: GroupGradient,
) -> Rgb {
    let rgb = match palette.drawn() {
        GroupPalette::Glass | GroupPalette::Vibrant => return swatch_rgb(color, theme),
        GroupPalette::Theme => theme_rgb(color, theme).unwrap_or_else(|| swatch_rgb(color, theme)),
        GroupPalette::Grayscale => grayscale_rgb(color, theme.is_dark),
        GroupPalette::Wallpaper | GroupPalette::Pictorial => match wallpaper {
            Some(w) => wallpaper_rgb(color, w, theme.is_dark),
            None => swatch_rgb(color, theme),
        },
        GroupPalette::Gradient => {
            let mut order = PALETTE_ORDER.to_vec();
            order.extend([GroupColor::Blue, GroupColor::Grey]);
            let index = order.iter().position(|c| *c == color).unwrap_or(0);
            gradient.rgb_at(GroupGradient::place(index as i64, order.len() as i64))
        }
    };
    readable(rgb.with_alpha(1.0), theme.sidebar(), MINIMUM_MARK_CONTRAST)
}

/// The eight colors the palette picker shows for `palette` (Swift `GroupColor.marble`).
pub fn marble(
    palette: GroupPalette,
    theme: &GroupTheme,
    wallpaper: Option<&Wallpaper>,
    gradient: GroupGradient,
) -> Vec<Rgb> {
    let sidebar = theme.sidebar();
    if palette == GroupPalette::Pictorial
        && let Some(bands) = wallpaper.map(|w| &w.bands).filter(|b| !b.is_empty())
    {
        return (0..8)
            .map(|step| {
                readable(
                    pictorial_rgb(bands, GroupGradient::place(step, 8)),
                    sidebar,
                    MINIMUM_MARK_CONTRAST,
                )
            })
            .collect();
    }
    if palette == GroupPalette::Gradient {
        return (0..8)
            .map(|step| {
                readable(
                    gradient.rgb_at(GroupGradient::place(step, 8)),
                    sidebar,
                    MINIMUM_MARK_CONTRAST,
                )
            })
            .collect();
    }
    PALETTE_ORDER
        .into_iter()
        .chain([GroupColor::Blue])
        .map(|c| palette_rgb(c, palette, theme, wallpaper, GroupGradient::Sunset))
        .collect()
}
