//! Group colors, palettes, headers and glass: a value-for-value port of the macOS app's
//!
//! - `CmuxNextDesign/GroupColor+Palette.swift` (palette order, automatic, paletteRGB, marble,
//!   grayscale, wallpaper, pictorial)
//! - `CmuxNextDesign/GroupColor+Distinct.swift` (automatic(after:), perceptualDistance, OKLabPoint)
//! - `CmuxNextDesign/GroupBackground.swift` (with `GlyphInk.swift`'s `glyphInk(base:)` and `chip`)
//! - `CmuxNextDesign/GroupGradient+Colors.swift`
//! - `CmuxNextDesign/GroupGlass/GroupChipGlass.swift`, `GroupGlassPaint.swift` (incl. `over`),
//!   `SidebarGroupGlass.swift`
//! - `CmuxNextDesignTokens/GroupGradient.swift`, `GroupPalette.swift`,
//!   `SidebarGroupBackgroundStyle.swift`
//! - the parts of `GroupColor.swift`, `GroupColor+Theme.swift` and `GroupTint.swift` these read.
//!
//! Ops: `tokens.group_*` (see [`call`]). Colors are `{r,g,b,a}`; a tint is `"none"`,
//! `{"palette":"red"}` or `{"custom":{..}}`; a theme is [`GroupTheme`].

mod background;
mod colors;
mod glass;
mod kinds;

pub use background::{
    ChipInks, GLASS_OPACITY, GroupBackground, MINIMUM_VISIBLE_CONTRAST, Strength, chip, glass_fill,
    glyph_ink, visible,
};
pub use colors::{
    MINIMUM_MARK_CONTRAST, MINIMUM_TEXT_CONTRAST, OkLabPoint, PALETTE_ORDER, automatic,
    automatic_after, grayscale_rgb, header_rgb, hsb_rgb, hue_saturation, marble, palette_rgb,
    perceptual_distance, pictorial_rgb, swatch_rgb, theme_rgb, wallpaper_rgb,
};
pub use glass::{
    DEFAULT_VIVIDNESS, GlassPaintInput, GroupGlassPaint, NEUTRAL_OPACITY, chip_draws_glass,
    chip_glass_paint, glass_paint, glass_rgb, line_rgb, over,
};
pub use kinds::{
    ColorRole, GradientStop, GroupColor, GroupGradient, GroupPalette, GroupTheme, GroupTint,
    SidebarGroupBackgroundStyle, SidebarGroupGlass, Wallpaper,
};

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::color::{Color, Rgb};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PaletteRequest {
    palette: GroupPalette,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GradientRequest {
    #[serde(default)]
    gradient: GroupGradient,
    #[serde(default)]
    place: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlaceRequest {
    index: i64,
    count: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StyleRequest {
    style: SidebarGroupBackgroundStyle,
    #[serde(default)]
    app_looks_glassy: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GlassRequest {
    glass: SidebarGroupGlass,
    #[serde(default)]
    dark: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ColorRequest {
    color: GroupColor,
    #[serde(default = "swatch")]
    role: ColorRole,
    #[serde(default)]
    dark: bool,
}

fn swatch() -> ColorRole {
    ColorRole::Swatch
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThemeColorRequest {
    color: GroupColor,
    theme: GroupTheme,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExistingRequest {
    existing: Vec<GroupTint>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AfterRequest {
    existing: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DistanceRequest {
    color: GroupColor,
    other: GroupColor,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DarkColorRequest {
    color: GroupColor,
    #[serde(default)]
    dark: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WallpaperRequest {
    color: GroupColor,
    wallpaper: Wallpaper,
    #[serde(default)]
    dark: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PictorialRequest {
    bands: Vec<Wallpaper>,
    place: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PaletteRgbRequest {
    color: GroupColor,
    palette: GroupPalette,
    theme: GroupTheme,
    #[serde(default)]
    wallpaper: Option<Wallpaper>,
    #[serde(default)]
    gradient: GroupGradient,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MarbleRequest {
    palette: GroupPalette,
    theme: GroupTheme,
    #[serde(default)]
    wallpaper: Option<Wallpaper>,
    #[serde(default)]
    gradient: GroupGradient,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackgroundRequest {
    tint: GroupTint,
    strength: Strength,
    #[serde(default)]
    glass: bool,
    palette: GroupPalette,
    #[serde(default)]
    wallpaper: Option<Wallpaper>,
    theme: GroupTheme,
    #[serde(default)]
    steps: Vec<Color>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BackgroundReply {
    fill: Color,
    shown: Color,
    ink: Color,
    rim: Option<Color>,
    ground: Color,
    is_glass: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VisibleRequest {
    color: Color,
    ground: Color,
    #[serde(default = "glass_opacity")]
    opacity: f64,
}

fn glass_opacity() -> f64 {
    GLASS_OPACITY
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InkRequest {
    theme: GroupTheme,
    color: Color,
    #[serde(default = "theme_inks")]
    inks: ChipInks,
}

fn theme_inks() -> ChipInks {
    ChipInks::Theme
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OverRequest {
    top: Color,
    bottom: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GlassRgbRequest {
    tint: GroupTint,
    palette: GroupPalette,
    theme: GroupTheme,
    #[serde(default)]
    wallpaper: Option<Wallpaper>,
    #[serde(default)]
    gradient: GroupGradient,
    #[serde(default = "vividness")]
    vividness: f64,
}

fn vividness() -> f64 {
    DEFAULT_VIVIDNESS
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GlassPaintRequest {
    tint: GroupTint,
    palette: GroupPalette,
    glass: SidebarGroupGlass,
    theme: GroupTheme,
    #[serde(default)]
    ground: Option<Color>,
    #[serde(default)]
    steps: Vec<Color>,
    #[serde(default)]
    opaque: bool,
    veil: Color,
    #[serde(default)]
    wallpaper: Option<Wallpaper>,
    #[serde(default)]
    gradient: GroupGradient,
    /// For `group_chip_glass_paint`: the header look.
    #[serde(default)]
    background: Option<SidebarGroupBackgroundStyle>,
    /// For `group_chip_glass_paint`: the theme's chrome background.
    #[serde(default)]
    chrome: Option<Color>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GlassPaintReply {
    fill: Color,
    shown: Color,
    ink: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChipDrawsRequest {
    glass: SidebarGroupGlass,
    background: SidebarGroupBackgroundStyle,
}

fn color(c: Rgb) -> Color {
    c.into()
}

fn colors(cs: &[Rgb]) -> Vec<Color> {
    cs.iter().map(|c| color(*c)).collect()
}

fn rgbs(cs: &[Color]) -> Vec<Rgb> {
    cs.iter().map(|c| Rgb::from(*c)).collect()
}

fn paint_reply(p: GroupGlassPaint) -> GlassPaintReply {
    GlassPaintReply { fill: color(p.fill), shown: color(p.shown), ink: color(p.ink) }
}

/// Runs `tokens.group_*`:
///
/// - `group_palette_traits` `{palette}` → `{colorsNewGroups, followsWallpaper, drawn}`
/// - `group_gradient_stops` `{gradient}` → stops; `group_gradient_rgb` `{gradient, place}`;
///   `group_gradient_place` `{index, count}`
/// - `group_background_style_traits` `{style, appLooksGlassy}` → the look's flags
/// - `group_glass_tint` `{glass, dark}` → `{tint, title}`
/// - `group_color_rgb` `{color, role, dark}`; `group_theme_rgb` `{color, theme}` (null for none)
/// - `group_palette_order`; `group_automatic` `{existing: [tint]}`; `group_automatic_after`
///   `{existing: [string]}`; `group_perceptual_distance` `{color, other}`
/// - `group_grayscale_rgb` `{color, dark}`; `group_wallpaper_rgb` `{color, wallpaper, dark}`;
///   `group_pictorial_rgb` `{bands, place}`; `group_palette_rgb` `{color, palette, theme,
///   wallpaper?, gradient?}`; `group_marble` `{palette, theme, wallpaper?, gradient?}`
/// - `group_background` `{tint, strength, glass, palette, wallpaper?, theme, steps?}` →
///   `{fill, shown, ink, rim, ground, isGlass, painted?}`
/// - `group_visible` `{color, ground}`; `group_glass_fill` `{color, ground, opacity?}`
/// - `group_glyph_ink` `{theme, color}`; `group_chip` `{theme, color, inks?}` → `{fill, ink}`
/// - `group_over` `{top, bottom}`; `group_glass_rgb` `{tint, palette, theme, wallpaper?,
///   gradient?, vividness?}`
/// - `group_glass_paint` `{tint, palette, glass, theme, ground?, steps?, opaque, veil,
///   wallpaper?, gradient?}` → `{fill, shown, ink}`
/// - `group_chip_glass_draws` `{glass, background}`; `group_chip_glass_paint` (the paint request
///   plus `background` and `chrome`) → paint or null
///
/// Other names return [`OpError::Unknown`].
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "group_palette_traits" => {
            let r: PaletteRequest = parse(request)?;
            Ok(json!({
                "colorsNewGroups": r.palette.colors_new_groups(),
                "followsWallpaper": r.palette.follows_wallpaper(),
                "drawn": r.palette.drawn(),
            }))
        }
        "group_gradient_stops" => {
            let r: GradientRequest = parse(request)?;
            reply(&r.gradient.stops())
        }
        "group_gradient_rgb" => {
            let r: GradientRequest = parse(request)?;
            reply(&color(r.gradient.rgb_at(r.place)))
        }
        "group_gradient_place" => {
            let r: PlaceRequest = parse(request)?;
            reply(&GroupGradient::place(r.index, r.count))
        }
        "group_background_style_traits" => {
            let r: StyleRequest = parse(request)?;
            let s = r.style;
            Ok(json!({
                "drawsGlass": s.draws_glass(r.app_looks_glassy),
                "drawsBackground": s.draws_background(),
                "drawsMembersMark": s.draws_members_mark(),
                "indentsMembers": s.indents_members(),
                "leadsWithFolder": s.leads_with_folder(),
                "drawsCard": s.draws_card(),
                "drawsOnTabStrip": s.draws_on_tab_strip(),
            }))
        }
        "group_glass_tint" => {
            let r: GlassRequest = parse(request)?;
            Ok(json!({ "tint": r.glass.tint(r.dark), "title": r.glass.title() }))
        }
        "group_color_rgb" => {
            let r: ColorRequest = parse(request)?;
            reply(&color(r.color.rgb(r.role, r.dark)))
        }
        "group_theme_rgb" => {
            let r: ThemeColorRequest = parse(request)?;
            reply(&theme_rgb(r.color, &r.theme).map(color))
        }
        "group_palette_order" => reply(&PALETTE_ORDER),
        "group_automatic" => {
            let r: ExistingRequest = parse(request)?;
            reply(&automatic(&r.existing))
        }
        "group_automatic_after" => {
            let r: AfterRequest = parse(request)?;
            reply(&automatic_after(&r.existing))
        }
        "group_perceptual_distance" => {
            let r: DistanceRequest = parse(request)?;
            reply(&perceptual_distance(r.color, r.other))
        }
        "group_grayscale_rgb" => {
            let r: DarkColorRequest = parse(request)?;
            reply(&color(grayscale_rgb(r.color, r.dark)))
        }
        "group_wallpaper_rgb" => {
            let r: WallpaperRequest = parse(request)?;
            reply(&color(wallpaper_rgb(r.color, &r.wallpaper, r.dark)))
        }
        "group_pictorial_rgb" => {
            let r: PictorialRequest = parse(request)?;
            reply(&color(pictorial_rgb(&r.bands, r.place)))
        }
        "group_palette_rgb" => {
            let r: PaletteRgbRequest = parse(request)?;
            let rgb = palette_rgb(r.color, r.palette, &r.theme, r.wallpaper.as_ref(), r.gradient);
            reply(&color(rgb))
        }
        "group_marble" => {
            let r: MarbleRequest = parse(request)?;
            reply(&colors(&marble(r.palette, &r.theme, r.wallpaper.as_ref(), r.gradient)))
        }
        "group_background" => {
            let r: BackgroundRequest = parse(request)?;
            let bg = GroupBackground::new(
                r.tint,
                r.strength,
                r.glass,
                r.palette,
                r.wallpaper.as_ref(),
                &r.theme,
            );
            let mut out = serde_json::to_value(BackgroundReply {
                fill: color(bg.fill),
                shown: color(bg.shown),
                ink: color(bg.ink),
                rim: bg.rim.map(color),
                ground: color(bg.ground),
                is_glass: bg.is_glass(),
            })
            .map_err(|e| OpError::Invalid(e.to_string()))?;
            if !r.steps.is_empty() {
                out["painted"] = json!(color(bg.painted(&rgbs(&r.steps))));
            }
            Ok(out)
        }
        "group_visible" => {
            let r: VisibleRequest = parse(request)?;
            reply(&color(visible(r.color.into(), r.ground.into())))
        }
        "group_glass_fill" => {
            let r: VisibleRequest = parse(request)?;
            reply(&color(glass_fill(r.color.into(), r.ground.into(), r.opacity)))
        }
        "group_glyph_ink" => {
            let r: InkRequest = parse(request)?;
            reply(&color(glyph_ink(&r.theme, r.color.into())))
        }
        "group_chip" => {
            let r: InkRequest = parse(request)?;
            let (fill, ink) = chip(&r.theme, r.color.into(), r.inks);
            Ok(json!({ "fill": color(fill), "ink": color(ink) }))
        }
        "group_over" => {
            let r: OverRequest = parse(request)?;
            reply(&color(over(r.top.into(), r.bottom.into())))
        }
        "group_glass_rgb" => {
            let r: GlassRgbRequest = parse(request)?;
            let rgb = glass_rgb(
                r.tint,
                r.palette,
                &r.theme,
                r.wallpaper.as_ref(),
                r.gradient,
                r.vividness,
            );
            reply(&color(rgb))
        }
        "group_glass_paint" | "group_chip_glass_paint" => {
            let r: GlassPaintRequest = parse(request)?;
            let steps = rgbs(&r.steps);
            let input = GlassPaintInput {
                tint: r.tint,
                palette: r.palette,
                glass: r.glass,
                theme: &r.theme,
                ground: r.ground.map(Rgb::from),
                steps: &steps,
                opaque: r.opaque,
                veil: r.veil.into(),
                wallpaper: r.wallpaper.as_ref(),
                gradient: r.gradient,
            };
            if name == "group_glass_paint" {
                return reply(&paint_reply(glass_paint(&input)));
            }
            let background = r
                .background
                .ok_or_else(|| OpError::Invalid("missing field `background`".into()))?;
            let chrome =
                r.chrome.ok_or_else(|| OpError::Invalid("missing field `chrome`".into()))?;
            reply(&chip_glass_paint(background, chrome.into(), &input).map(paint_reply))
        }
        "group_chip_glass_draws" => {
            let r: ChipDrawsRequest = parse(request)?;
            reply(&chip_draws_glass(r.glass, r.background))
        }
        _ => Err(OpError::Unknown),
    }
}
