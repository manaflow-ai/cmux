//! The group token types: the nine colors, the palettes, gradients, header looks and glass
//! strengths (Swift `GroupColor`, `GroupPalette`, `GroupGradient`, `SidebarGroupBackgroundStyle`,
//! `SidebarGroupGlass`, `GroupTint`, `WallpaperTint`), and the theme values the rules read.

use crate::tokens::color::{Color, Rgb};
use cmux_theme_tokens::{Oklch, ThemeTokens, from_oklch};
use serde::{Deserialize, Serialize};

/// The nine group colors (Swift `GroupColor`); the raw value is the stored token.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GroupColor {
    /// Grey.
    Grey,
    /// Blue.
    Blue,
    /// Red.
    Red,
    /// Yellow.
    Yellow,
    /// Green.
    Green,
    /// Pink.
    Pink,
    /// Purple.
    Purple,
    /// Cyan.
    Cyan,
    /// Orange.
    Orange,
}

/// Where a group color draws (Swift `GroupColor.Role`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ColorRole {
    /// The color itself.
    Swatch,
    /// A background that carries text.
    Fill,
}

impl GroupColor {
    /// Every color in Swift's `allCases` order.
    pub const ALL: [GroupColor; 9] = [
        GroupColor::Grey,
        GroupColor::Blue,
        GroupColor::Red,
        GroupColor::Yellow,
        GroupColor::Green,
        GroupColor::Pink,
        GroupColor::Purple,
        GroupColor::Cyan,
        GroupColor::Orange,
    ];

    /// The stored token (Swift `rawValue`).
    pub fn raw(self) -> &'static str {
        match self {
            GroupColor::Grey => "grey",
            GroupColor::Blue => "blue",
            GroupColor::Red => "red",
            GroupColor::Yellow => "yellow",
            GroupColor::Green => "green",
            GroupColor::Pink => "pink",
            GroupColor::Purple => "purple",
            GroupColor::Cyan => "cyan",
            GroupColor::Orange => "orange",
        }
    }

    /// The color for a stored token, exactly (Swift `GroupColor(rawValue:)`).
    pub fn from_raw(raw: &str) -> Option<GroupColor> {
        GroupColor::ALL.into_iter().find(|c| c.raw() == raw)
    }

    /// The vibrant palette on dark glass (Swift `vibrantDark`).
    pub fn vibrant_dark(self) -> u32 {
        match self {
            GroupColor::Grey => 0xA1A1AA,
            GroupColor::Red => 0xFD7273,
            GroupColor::Orange => 0xFE843D,
            GroupColor::Yellow => 0xF5BA14,
            GroupColor::Green => 0x20C45F,
            GroupColor::Cyan => 0x14BBC2,
            GroupColor::Blue => 0x62A7FD,
            GroupColor::Purple => 0xB28BFD,
            GroupColor::Pink => 0xF46CBF,
        }
    }

    /// The vibrant palette on light glass (Swift `vibrantLight`).
    pub fn vibrant_light(self) -> u32 {
        match self {
            GroupColor::Grey => 0x8E8E93,
            GroupColor::Red => 0xE36364,
            GroupColor::Orange => 0xE57431,
            GroupColor::Yellow => 0xD6A20A,
            GroupColor::Green => 0x33AC5A,
            GroupColor::Cyan => 0x10A6AD,
            GroupColor::Blue => 0x4693F1,
            GroupColor::Purple => 0x9F79E6,
            GroupColor::Pink => 0xD465A8,
        }
    }

    /// The color in its light or dark variant (Swift `GroupColor.rgb(_:dark:)`).
    pub fn rgb(self, role: ColorRole, dark: bool) -> Rgb {
        let swatch = Rgb::hex(if dark { self.vibrant_dark() } else { self.vibrant_light() });
        match role {
            ColorRole::Swatch => swatch,
            ColorRole::Fill => {
                if dark {
                    swatch.mixed(Rgb::hex(0x1C1C1E), 0.55)
                } else {
                    swatch.mixed(Rgb::WHITE, 0.7)
                }
            }
        }
    }
}

/// Where sidebar group colors come from (Swift `GroupPalette`, `sidebar.groupPalette`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GroupPalette {
    /// Pure glass: a new group gets no color; a colored one draws vibrant.
    Glass,
    /// The theme's ANSI colors.
    Theme,
    /// Hues around the desktop picture's.
    Wallpaper,
    /// Eight greys.
    Grayscale,
    /// cmux's own colors.
    Vibrant,
    /// A gradient stepped down the sidebar.
    Gradient,
    /// The desktop picture's bands.
    Pictorial,
}

impl GroupPalette {
    /// Every palette in Swift's `allCases` order.
    pub const ALL: [GroupPalette; 7] = [
        GroupPalette::Glass,
        GroupPalette::Theme,
        GroupPalette::Wallpaper,
        GroupPalette::Grayscale,
        GroupPalette::Vibrant,
        GroupPalette::Gradient,
        GroupPalette::Pictorial,
    ];

    /// Whether a new group takes this palette's next color (Swift `colorsNewGroups`).
    pub fn colors_new_groups(self) -> bool {
        self != GroupPalette::Glass
    }

    /// Whether the palette follows the desktop picture (Swift `followsWallpaper`).
    pub fn follows_wallpaper(self) -> bool {
        self == GroupPalette::Wallpaper || self == GroupPalette::Pictorial
    }

    /// The palette a stored color draws from: glass draws vibrant (Swift `drawn`).
    pub fn drawn(self) -> GroupPalette {
        if self == GroupPalette::Glass { GroupPalette::Vibrant } else { self }
    }
}

/// One gradient stop: OKLCH lightness, chroma and hue in degrees.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GradientStop {
    /// OKLCH lightness 0...1.
    pub lightness: f64,
    /// OKLCH chroma.
    pub chroma: f64,
    /// Hue in degrees.
    pub hue: f64,
}

const fn stop(lightness: f64, chroma: f64, hue: f64) -> GradientStop {
    GradientStop { lightness, chroma, hue }
}

/// The gradient the gradient palette steps through (Swift `GroupGradient`, `sidebar.groupGradient`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GroupGradient {
    /// Pink, orange, then yellow. The default.
    #[default]
    Sunset,
    /// Purple, cyan, then green.
    Aurora,
    /// Blue, teal, then sea green.
    Lagoon,
    /// Purple into orange.
    TwoTone,
}

impl GroupGradient {
    /// Every gradient in Swift's `allCases` order.
    pub const ALL: [GroupGradient; 4] = [
        GroupGradient::Sunset,
        GroupGradient::Aurora,
        GroupGradient::Lagoon,
        GroupGradient::TwoTone,
    ];

    /// The stops, top of the sidebar first (Swift `stops`).
    pub fn stops(self) -> &'static [GradientStop] {
        const SUNSET: [GradientStop; 3] =
            [stop(0.70, 0.19, 350.0), stop(0.72, 0.18, 40.0), stop(0.84, 0.16, 85.0)];
        const AURORA: [GradientStop; 3] =
            [stop(0.72, 0.17, 300.0), stop(0.74, 0.14, 200.0), stop(0.78, 0.17, 150.0)];
        const LAGOON: [GradientStop; 3] =
            [stop(0.70, 0.16, 265.0), stop(0.76, 0.13, 205.0), stop(0.80, 0.15, 165.0)];
        const TWO_TONE: [GradientStop; 2] = [stop(0.70, 0.18, 300.0), stop(0.76, 0.17, 50.0)];
        match self {
            GroupGradient::Sunset => &SUNSET,
            GroupGradient::Aurora => &AURORA,
            GroupGradient::Lagoon => &LAGOON,
            GroupGradient::TwoTone => &TWO_TONE,
        }
    }

    /// The color at `place` (0 the first stop, 1 the last), blended in OKLCH, the hue the short
    /// way round (Swift `GroupGradient.rgb(at:)`).
    pub fn rgb_at(self, place: f64) -> Rgb {
        let stops = self.stops();
        let Some(first) = stops.first() else { return Rgb::WHITE };
        if stops.len() <= 1 {
            return from_oklch(Oklch { l: first.lightness, c: first.chroma, h: first.hue });
        }
        let scaled = place.clamp(0.0, 1.0) * (stops.len() - 1) as f64;
        let index = (scaled as usize).min(stops.len() - 2);
        let t = scaled - index as f64;
        let Some((&a, &b)) = stops.get(index).zip(stops.get(index + 1)) else {
            return Rgb::WHITE;
        };
        let turn = (b.hue - a.hue + 540.0) % 360.0 - 180.0;
        from_oklch(Oklch {
            l: a.lightness + (b.lightness - a.lightness) * t,
            c: a.chroma + (b.chroma - a.chroma) * t,
            h: (a.hue + turn * t + 360.0) % 360.0,
        })
    }

    /// Where the `index`th of `count` colored groups sits on the gradient (Swift
    /// `GroupGradient.place(_:of:)`).
    pub fn place(index: i64, count: i64) -> f64 {
        if count > 1 { index as f64 / (count - 1) as f64 } else { 0.0 }
    }
}

/// How a sidebar group header's background draws (Swift `SidebarGroupBackgroundStyle`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SidebarGroupBackgroundStyle {
    /// A plain folder.
    Folder,
    /// cmux's own group look. The default.
    Auto,
    /// A translucent fill with a rim.
    Glass,
    /// An opaque fill.
    Solid,
    /// Plain section headings.
    Sections,
    /// Chromium's tab-group chip and rail.
    Chip,
    /// The folder drawn as a tree.
    Tree,
    /// One tinted card around the group.
    Card,
}

impl SidebarGroupBackgroundStyle {
    /// Every look in Swift's `allCases` order.
    pub const ALL: [SidebarGroupBackgroundStyle; 8] = [
        SidebarGroupBackgroundStyle::Folder,
        SidebarGroupBackgroundStyle::Auto,
        SidebarGroupBackgroundStyle::Glass,
        SidebarGroupBackgroundStyle::Solid,
        SidebarGroupBackgroundStyle::Sections,
        SidebarGroupBackgroundStyle::Chip,
        SidebarGroupBackgroundStyle::Tree,
        SidebarGroupBackgroundStyle::Card,
    ];

    /// Whether the background draws as glass (Swift `drawsGlass(appLooksGlassy:)`).
    pub fn draws_glass(self, app_looks_glassy: bool) -> bool {
        match self {
            SidebarGroupBackgroundStyle::Auto => app_looks_glassy,
            SidebarGroupBackgroundStyle::Glass => true,
            _ => false,
        }
    }

    /// Whether the header draws a band of its own (Swift `drawsBackground`).
    pub fn draws_background(self) -> bool {
        matches!(
            self,
            SidebarGroupBackgroundStyle::Auto
                | SidebarGroupBackgroundStyle::Glass
                | SidebarGroupBackgroundStyle::Solid
        )
    }

    /// Whether the group draws a mark by its members (Swift `drawsMembersMark`).
    pub fn draws_members_mark(self) -> bool {
        self != SidebarGroupBackgroundStyle::Sections && self != SidebarGroupBackgroundStyle::Folder
    }

    /// Whether members sit one indent step in (Swift `indentsMembers`).
    pub fn indents_members(self) -> bool {
        self == SidebarGroupBackgroundStyle::Folder || self == SidebarGroupBackgroundStyle::Tree
    }

    /// Whether an icon-less header leads with the folder glyph (Swift `leadsWithFolder`).
    pub fn leads_with_folder(self) -> bool {
        self == SidebarGroupBackgroundStyle::Folder || self == SidebarGroupBackgroundStyle::Tree
    }

    /// Whether every group draws as one card (Swift `drawsCard`).
    pub fn draws_card(self) -> bool {
        self == SidebarGroupBackgroundStyle::Card
    }

    /// Whether a tab strip's chips take the look (Swift `drawsOnTabStrip`).
    pub fn draws_on_tab_strip(self) -> bool {
        !matches!(
            self,
            SidebarGroupBackgroundStyle::Folder
                | SidebarGroupBackgroundStyle::Chip
                | SidebarGroupBackgroundStyle::Tree
                | SidebarGroupBackgroundStyle::Card
        )
    }
}

/// How much of its color a group header's glass takes (Swift `SidebarGroupGlass`, `sidebar.groupGlass`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SidebarGroupGlass {
    /// A clear tint.
    Glass,
    /// More of the color. The default.
    Vivid,
    /// A light tint.
    Frost,
    /// The opaque bar.
    Solid,
}

impl SidebarGroupGlass {
    /// Every choice in Swift's `allCases` order.
    pub const ALL: [SidebarGroupGlass; 4] = [
        SidebarGroupGlass::Glass,
        SidebarGroupGlass::Vivid,
        SidebarGroupGlass::Frost,
        SidebarGroupGlass::Solid,
    ];

    /// The tunable's default (`sidebar.groupGlass`).
    pub const DEFAULT: SidebarGroupGlass = SidebarGroupGlass::Vivid;

    /// The share of the color over the role's veil (Swift `tint(dark:)`).
    pub fn tint(self, dark: bool) -> f64 {
        match self {
            SidebarGroupGlass::Glass => {
                if dark {
                    0.30
                } else {
                    0.22
                }
            }
            SidebarGroupGlass::Vivid => {
                if dark {
                    0.44
                } else {
                    0.34
                }
            }
            SidebarGroupGlass::Frost => {
                if dark {
                    0.16
                } else {
                    0.12
                }
            }
            SidebarGroupGlass::Solid => 1.0,
        }
    }

    /// The choice's title in Debug settings (Swift `tunableTitle`).
    pub fn title(self) -> &'static str {
        match self {
            SidebarGroupGlass::Glass => "Tinted glass",
            SidebarGroupGlass::Vivid => "Vivid glass",
            SidebarGroupGlass::Frost => "Frosted glass",
            SidebarGroupGlass::Solid => "Solid bar",
        }
    }
}

/// A group's color: a palette token, a custom color, or none (Swift `GroupTint`). On the wire:
/// `"none"`, `{"palette":"red"}` or `{"custom":{"r":..,"g":..,"b":..}}`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GroupTint {
    /// A palette token.
    Palette(GroupColor),
    /// A color a person picked.
    Custom(Color),
    /// No color.
    None,
}

impl GroupTint {
    /// Whether this is no color (Swift `isNone`).
    pub fn is_none(self) -> bool {
        matches!(self, GroupTint::None)
    }
}

/// The desktop picture's color, and its bands top first (Swift `WallpaperTint`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Wallpaper {
    /// sRGB red 0...1.
    pub red: f64,
    /// sRGB green 0...1.
    pub green: f64,
    /// sRGB blue 0...1.
    pub blue: f64,
    /// The picture's bands, top first; empty when only the mean was taken.
    #[serde(default)]
    pub bands: Vec<Wallpaper>,
}

impl Wallpaper {
    /// A picture color, clamped to 0...1 as Swift's `init(red:green:blue:)` does.
    pub fn new(red: f64, green: f64, blue: f64) -> Self {
        Wallpaper {
            red: red.clamp(0.0, 1.0),
            green: green.clamp(0.0, 1.0),
            blue: blue.clamp(0.0, 1.0),
            bands: Vec::new(),
        }
    }

    /// The same color and bands with every component clamped (for values read off the wire).
    pub fn clamped(&self) -> Self {
        let mut out = Wallpaper::new(self.red, self.green, self.blue);
        out.bands = self.bands.iter().map(Wallpaper::clamped).collect();
        out
    }
}

/// The theme values the group rules read (a slice of Swift `ThemeTokens`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupTheme {
    /// Whether the theme is dark.
    pub is_dark: bool,
    /// The sidebar's background.
    pub sidebar_background: Color,
    /// The primary text color.
    pub text_primary: Color,
    /// The translucent hover fill.
    pub hover_fill: Color,
    /// The translucent pressed fill.
    pub pressed_fill: Color,
    /// The terminal ANSI palette (8 or 16 colors); the theme palette needs at least 8.
    #[serde(default)]
    pub ansi: Vec<Color>,
}

impl From<&ThemeTokens> for GroupTheme {
    fn from(t: &ThemeTokens) -> Self {
        GroupTheme {
            is_dark: t.is_dark,
            sidebar_background: t.sidebar_background.into(),
            text_primary: t.text_primary.into(),
            hover_fill: t.hover_fill.into(),
            pressed_fill: t.pressed_fill.into(),
            ansi: t.ansi.iter().map(|c| Color::from(*c)).collect(),
        }
    }
}

impl GroupTheme {
    /// The sidebar background as an `Rgb`.
    pub fn sidebar(&self) -> Rgb {
        self.sidebar_background.into()
    }
    /// The primary text as an `Rgb`.
    pub fn text(&self) -> Rgb {
        self.text_primary.into()
    }
    /// The hover fill as an `Rgb`.
    pub fn hover(&self) -> Rgb {
        self.hover_fill.into()
    }
    /// The pressed fill as an `Rgb`.
    pub fn pressed(&self) -> Rgb {
        self.pressed_fill.into()
    }
}
