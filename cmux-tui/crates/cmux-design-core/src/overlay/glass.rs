//! The floating glass: `FloatingGlassStyle` and its presets, `TransientMaterial`, `GlassLevel`,
//! `SurfaceRole`'s glass rules, `OverlayGlassVariant` and `HoverSurfaceLook`
//! (CmuxNextDesign/FloatingGlass, CmuxTheme/TransientMaterial.swift).

use crate::menu::color::ThemeRgb;
use serde::{Deserialize, Serialize};

/// CmuxTheme `TransientMaterial.standard`: the regular translucent material of non-chat
/// transient surfaces (schemas/design-scale/design-scale.json).
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransientMaterial {
    pub dark_veil_alpha: f64,
    pub light_veil_alpha: f64,
    pub dark_rim_top: f64,
    pub dark_rim_bottom: f64,
    pub light_rim_top: f64,
    pub light_rim_bottom: f64,
    pub host_veil: f64,
    pub native_tint_strength: f64,
    pub web_tint: f64,
    pub web_tint_dark: f64,
    pub web_blur: f64,
    pub web_saturation: f64,
    pub neutral_dark: f64,
    pub neutral_light: f64,
}

/// The shipped material.
pub const TRANSIENT: TransientMaterial = TransientMaterial {
    dark_veil_alpha: 0.42,
    light_veil_alpha: 0.55,
    dark_rim_top: 0.3,
    dark_rim_bottom: 0.06,
    light_rim_top: 0.85,
    light_rim_bottom: 0.1,
    host_veil: 0.4,
    native_tint_strength: 1.25,
    web_tint: 80.0,
    web_tint_dark: 72.0,
    web_blur: 32.0,
    web_saturation: 1.6,
    neutral_dark: 0.11,
    neutral_light: 0.99,
};

/// A rim's top and bottom opacity.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rim {
    pub top: f64,
    pub bottom: f64,
}

/// `FloatingGlassStyle`: the veil, rim, corner level and shadow of a neutral glass surface.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingGlassStyle {
    pub corner_depth: i64,
    pub dark_veil_alpha: f64,
    pub light_veil_alpha: f64,
    pub dark_rim: Rim,
    pub light_rim: Rim,
    pub casts_shadow: bool,
    #[serde(default)]
    pub veil_takes_theme_tint: bool,
}

/// A grey with an opacity (`FloatingGlassLook.Gray`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Gray {
    pub white: f64,
    pub alpha: f64,
}

/// `FloatingGlassLook`: the colours of one appearance.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FloatingGlassLook {
    pub veil: Gray,
    pub rim_top: Gray,
    pub rim_bottom: Gray,
}

const fn style(
    dark_veil_alpha: f64,
    light_veil_alpha: f64,
    dark_rim: (f64, f64),
    light_rim: (f64, f64),
    casts_shadow: bool,
    veil_takes_theme_tint: bool,
) -> FloatingGlassStyle {
    FloatingGlassStyle {
        corner_depth: 0,
        dark_veil_alpha,
        light_veil_alpha,
        dark_rim: Rim { top: dark_rim.0, bottom: dark_rim.1 },
        light_rim: Rim { top: light_rim.0, bottom: light_rim.1 },
        casts_shadow,
        veil_takes_theme_tint,
    }
}

impl FloatingGlassStyle {
    /// `FloatingGlassStyle.transient` (Glass+Transient.swift), also `.toast`.
    pub const TRANSIENT: FloatingGlassStyle = style(
        TRANSIENT.dark_veil_alpha,
        TRANSIENT.light_veil_alpha,
        (TRANSIENT.dark_rim_top, TRANSIENT.dark_rim_bottom),
        (TRANSIENT.light_rim_top, TRANSIENT.light_rim_bottom),
        true,
        true,
    );
    /// `.toast`: the transient material.
    pub const TOAST: FloatingGlassStyle = Self::TRANSIENT;
    /// `.card`: the sidebar's cards.
    pub const CARD: FloatingGlassStyle = style(0.42, 0.45, (0.22, 0.04), (0.8, 0.08), false, false);
    /// `.group`: the sidebar's group headers.
    pub const GROUP: FloatingGlassStyle =
        style(0.06, 0.2, (0.24, 0.04), (0.75, 0.08), false, false);
    /// `.dialog`: dialogs, confirms, prompt bars and sheets.
    pub const DIALOG: FloatingGlassStyle =
        style(0.48, 0.62, (0.28, 0.05), (0.85, 0.1), true, false);
    /// `.prompt`: prompts that float over every app.
    pub const PROMPT: FloatingGlassStyle = style(0.74, 0.8, (0.3, 0.06), (0.85, 0.1), true, true);
    /// `.agentTag`: the toast's veil and rim with a shadow, never the theme tint.
    pub const AGENT_TAG: FloatingGlassStyle = style(
        TRANSIENT.dark_veil_alpha,
        TRANSIENT.light_veil_alpha,
        (TRANSIENT.dark_rim_top, TRANSIENT.dark_rim_bottom),
        (TRANSIENT.light_rim_top, TRANSIENT.light_rim_bottom),
        true,
        false,
    );

    /// `.findPill` (FindPillView.swift): the transient material, its dark veil at least 70 %.
    pub fn find_pill() -> FloatingGlassStyle {
        let mut style = Self::TRANSIENT;
        style.dark_veil_alpha = style.dark_veil_alpha.max(0.7);
        style
    }

    /// A preset by its Swift name.
    pub fn named(name: &str) -> Option<FloatingGlassStyle> {
        Some(match name {
            "transient" => Self::TRANSIENT,
            "toast" => Self::TOAST,
            "card" => Self::CARD,
            "group" => Self::GROUP,
            "dialog" => Self::DIALOG,
            "prompt" => Self::PROMPT,
            "agentTag" => Self::AGENT_TAG,
            "findPill" => Self::find_pill(),
            _ => return None,
        })
    }

    /// `look(isDark:)`.
    pub fn look(&self, is_dark: bool) -> FloatingGlassLook {
        if is_dark {
            FloatingGlassLook {
                veil: Gray { white: 0.11, alpha: self.dark_veil_alpha },
                rim_top: Gray { white: 1.0, alpha: self.dark_rim.top },
                rim_bottom: Gray { white: 1.0, alpha: self.dark_rim.bottom },
            }
        } else {
            FloatingGlassLook {
                veil: Gray { white: 0.99, alpha: self.light_veil_alpha },
                rim_top: Gray { white: 1.0, alpha: self.light_rim.top },
                rim_bottom: Gray { white: 0.0, alpha: self.light_rim.bottom },
            }
        }
    }

    /// `Palette.veilRGB(of:tokens:)`: the grey veil, or the theme's glass tint at its opacity.
    pub fn veil_rgb(&self, is_dark: bool, glass_tint: ThemeRgb) -> ThemeRgb {
        let veil = self.look(is_dark).veil;
        if self.veil_takes_theme_tint {
            glass_tint.with_alpha(veil.alpha)
        } else {
            ThemeRgb::new(veil.white, veil.white, veil.white, veil.alpha)
        }
    }
}

/// `ConcentricCorners.radius(depth:)`: `outer - depth * padding`, at least 0.
pub fn corner_radius(outer: f64, padding: f64, depth: i64) -> f64 {
    (outer - depth as f64 * padding).max(0.0)
}

/// `GlassLevel`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GlassLevel {
    Chrome,
    Popover,
    Menu,
    Chip,
}

impl GlassLevel {
    /// Every level, in Swift's `allCases` order.
    pub const ALL: [GlassLevel; 4] = [Self::Chrome, Self::Popover, Self::Menu, Self::Chip];

    /// `tintStrength`: the multiplier on the theme glass tint's alpha.
    pub fn tint_strength(self) -> f64 {
        match self {
            Self::Chrome => 1.0,
            Self::Popover | Self::Menu => TRANSIENT.native_tint_strength,
            Self::Chip => 1.5,
        }
    }
}

/// `GlassLevel.scaled(_:by:)` on the alpha: unchanged at 1, else scaled and clamped to 0...1.
pub fn scaled_alpha(alpha: f64, strength: f64) -> f64 {
    if strength == 1.0 { alpha } else { (alpha * strength).clamp(0.0, 1.0) }
}

/// `SurfaceRole`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SurfaceRole {
    Popover,
    Menu,
    Card,
    Group,
    Toast,
    Sheet,
    Prompt,
    Tooltip,
}

/// `SurfaceRole.nearOpaque`: every role's veil stays under this.
pub const NEAR_OPAQUE: f64 = 0.9;

impl SurfaceRole {
    /// Every role, in Swift's `allCases` order.
    pub const ALL: [SurfaceRole; 8] = [
        Self::Popover,
        Self::Menu,
        Self::Card,
        Self::Group,
        Self::Toast,
        Self::Sheet,
        Self::Prompt,
        Self::Tooltip,
    ];

    /// `glassLevel` (SurfaceRole+GlassLevel.swift).
    pub fn glass_level(self) -> GlassLevel {
        match self {
            Self::Popover | Self::Toast | Self::Sheet | Self::Prompt => GlassLevel::Popover,
            Self::Menu => GlassLevel::Menu,
            Self::Tooltip => GlassLevel::Chip,
            Self::Card | Self::Group => GlassLevel::Chrome,
        }
    }

    /// `cornerDepth`.
    pub fn corner_depth(self) -> i64 {
        match self {
            Self::Tooltip => 2,
            _ => 0,
        }
    }

    /// `castsShadow`.
    pub fn casts_shadow(self) -> bool {
        !matches!(self, Self::Card | Self::Group)
    }

    /// `neutralStyle`: the neutral glass the role draws, nil for the theme tone.
    pub fn neutral_style(self) -> Option<FloatingGlassStyle> {
        match self {
            Self::Card => Some(FloatingGlassStyle::CARD),
            Self::Group => Some(FloatingGlassStyle::GROUP),
            Self::Toast => Some(FloatingGlassStyle::TOAST),
            Self::Sheet => Some(FloatingGlassStyle::DIALOG),
            Self::Prompt => Some(FloatingGlassStyle::PROMPT),
            _ => None,
        }
    }
}

/// `OverlayGlassVariant`, by its gallery number.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OverlayGlassVariant {
    /// 1: Apple's Liquid Glass as it ships.
    AppKitRegular,
    /// 3: Liquid Glass with the role's veil and the neutral rim.
    VeilTinted,
    /// 11: the frosted blur with the veil and rim.
    Frost,
}

impl OverlayGlassVariant {
    /// `picked`: the floating surfaces' variant.
    pub const PICKED: OverlayGlassVariant = Self::AppKitRegular;

    /// The gallery number (`rawValue`).
    pub fn number(self) -> i64 {
        match self {
            Self::AppKitRegular => 1,
            Self::VeilTinted => 3,
            Self::Frost => 11,
        }
    }

    /// `tintsGlass(_:)`: variant 1 drops only the neutral grey veil, never a theme-tinted one.
    pub fn tints_glass(self, veil_takes_theme_tint: bool) -> bool {
        self != Self::AppKitRegular || veil_takes_theme_tint
    }

    /// `drawsRim`.
    pub fn draws_rim(self) -> bool {
        self != Self::AppKitRegular
    }

    /// `prefersFrost`.
    pub fn prefers_frost(self) -> bool {
        self == Self::Frost
    }
}

/// `HoverSurfaceLook`: what tooltips, hover cards and hint toasts draw on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HoverSurfaceLook {
    Hairline,
    Shadowed,
    Framed,
    Glass,
}

/// `PopupStyle.elevation2`: offset, blur and alpha.
pub const ELEVATION_2: Elevation = Elevation { offset: 2.0, blur: 6.0, alpha: 0.11 };

/// A shadow elevation (`Elevation`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Elevation {
    pub offset: f64,
    pub blur: f64,
    pub alpha: f64,
}

impl HoverSurfaceLook {
    /// Every look, in Swift's `allCases` order.
    pub const ALL: [HoverSurfaceLook; 4] =
        [Self::Hairline, Self::Shadowed, Self::Framed, Self::Glass];
    /// `solidLooks`: the gallery's side-by-side looks.
    pub const SOLID: [HoverSurfaceLook; 3] = [Self::Hairline, Self::Shadowed, Self::Framed];
    /// The setting's default (Release keeps it).
    pub const DEFAULT: HoverSurfaceLook = Self::Hairline;

    /// `tunableTitle`.
    pub fn title(self) -> &'static str {
        match self {
            Self::Hairline => "1: Solid, hairline edge",
            Self::Shadowed => "2: Solid, shadow only",
            Self::Framed => "3: Solid, one-point rim",
            Self::Glass => "Glass (before)",
        }
    }

    /// `isSolid`.
    pub fn is_solid(self) -> bool {
        self != Self::Glass
    }

    /// `material`: `"opaque"` for the solid looks, nil (this Mac's glass) for glass.
    pub fn material(self) -> Option<&'static str> {
        self.is_solid().then_some("opaque")
    }

    /// `edgeWidth`: points, or nil for the device-pixel hairline.
    pub fn edge_width(self) -> Option<f64> {
        match self {
            Self::Hairline | Self::Glass => None,
            Self::Shadowed => Some(0.0),
            Self::Framed => Some(1.0),
        }
    }

    /// `shadow(default:)`.
    pub fn shadow(self, base: Elevation) -> Elevation {
        match self {
            Self::Hairline | Self::Glass => base,
            Self::Shadowed | Self::Framed => ELEVATION_2,
        }
    }
}
