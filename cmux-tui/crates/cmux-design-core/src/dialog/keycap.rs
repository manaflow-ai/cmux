//! How a keyed dialog button draws its key (`CmuxDialogKeycapStyle`) and the sizes every dialog
//! shares (`CmuxDialogMetrics`, `CmuxDialogMetrics.qrSide`).
//!
//! Sizes scale with the person's text size (`Typography.userScale`); the button corner
//! (`Metrics.buttonCornerRadius`, the density's tab corner) comes from the caller.

use super::keys::Role;
use serde::{Deserialize, Serialize};

/// The caption size at scale 1 (`TypeScale.Base.caption`).
pub const CAPTION_BASE: f64 = 11.0;

/// A keycap style (`CmuxDialogKeycapStyle`), in the playground's order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeycapStyle {
    /// The look before the pick: a plate the button's height less a 3 pt inset.
    Plate,
    /// Linear's shortcut hint, the look every dialog draws.
    LinearKbd,
    /// No plate: the glyph after the title.
    PlainGlyph,
    /// A very faint fill, no border.
    FaintFill,
    /// A hairline outline, no fill.
    Hairline,
    /// No plate, a smaller dimmer glyph.
    QuietSmall,
    /// Only the default button shows its key.
    DefaultOnly,
    /// No key in the buttons; a caption under them.
    Outside,
}

/// A glyph weight token.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GlyphWeight {
    /// `TypeScale.emphasis`.
    Emphasis,
    /// `.regular`.
    Regular,
}

/// Every number a style draws with, at one text scale.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeycapLook {
    /// The style.
    pub style: KeycapStyle,
    /// The playground's name.
    pub title: String,
    /// What the style changes.
    pub note: String,
    /// The key sits on a plate.
    pub has_plate: bool,
    /// The plate's fill: the title's ink at this alpha.
    pub fill_alpha: f64,
    /// The plate's 1 px outline alpha; 0 draws none.
    pub border_alpha: f64,
    /// The glyph's share of the key hint ink's alpha.
    pub glyph_alpha: f64,
    /// The glyph's point size.
    pub glyph_size: f64,
    /// The glyph's weight.
    pub glyph_weight: GlyphWeight,
    /// The plate's height; none fills the button less `trailing` above and below.
    pub plate_height: Option<f64>,
    /// From the key's end to the button's trailing edge.
    pub trailing: f64,
    /// From the title's end to the key.
    pub gap: f64,
    /// The plate's room each side of the glyph.
    pub plate_padding: f64,
    /// Whether the default button draws its key.
    pub default_shows_key: bool,
    /// Whether the other buttons draw their key.
    pub others_show_key: bool,
}

impl KeycapStyle {
    /// Every style, in the playground's order.
    pub const ALL: [KeycapStyle; 8] = [
        KeycapStyle::Plate,
        KeycapStyle::LinearKbd,
        KeycapStyle::PlainGlyph,
        KeycapStyle::FaintFill,
        KeycapStyle::Hairline,
        KeycapStyle::QuietSmall,
        KeycapStyle::DefaultOnly,
        KeycapStyle::Outside,
    ];

    /// The style every dialog draws.
    pub const SHIPPED: KeycapStyle = KeycapStyle::LinearKbd;

    /// The playground's name.
    pub fn title(self) -> &'static str {
        match self {
            KeycapStyle::Plate => "1. Plate (before)",
            KeycapStyle::LinearKbd => "2. Linear kbd (shipped)",
            KeycapStyle::PlainGlyph => "3. Plain glyph",
            KeycapStyle::FaintFill => "4. Faint fill",
            KeycapStyle::Hairline => "5. Hairline",
            KeycapStyle::QuietSmall => "6. Quiet, small",
            KeycapStyle::DefaultOnly => "7. Default button only",
            KeycapStyle::Outside => "8. Outside the buttons",
        }
    }

    /// What the style changes, one line.
    pub fn note(self) -> &'static str {
        match self {
            KeycapStyle::Plate => {
                "A 20 pt plate 3 pt in from the top, bottom and end; ink at 14%; corner 8 − 3 = 5 pt."
            }
            KeycapStyle::LinearKbd => {
                "A 16 pt plate, ink at 10%, 11 pt glyph, 5 pt in from the end; corner 8 − 5 = 3 pt."
            }
            KeycapStyle::PlainGlyph => {
                "No plate: the glyph 6 pt after the title, in the key hint's ink."
            }
            KeycapStyle::FaintFill => "An 18 pt plate, ink at 6%, no border; the glyph at 80%.",
            KeycapStyle::Hairline => "An 18 pt plate with a 1 px outline (ink at 22%) and no fill.",
            KeycapStyle::QuietSmall => "No plate: a 10 pt glyph at 55%, 4 pt after the title.",
            KeycapStyle::DefaultOnly => {
                "Only ↩ on the default button, as a plain glyph; Cancel shows no key."
            }
            KeycapStyle::Outside => {
                "No key in the buttons; a caption under them: “esc to cancel · ↩ to quit”."
            }
        }
    }

    /// Whether a button in `role` draws its key inside itself.
    pub fn shows_key(self, role: Role) -> bool {
        match self {
            KeycapStyle::Outside => false,
            KeycapStyle::DefaultOnly => role == Role::Default,
            _ => true,
        }
    }

    /// Whether the key sits on a plate.
    pub fn has_plate(self) -> bool {
        matches!(
            self,
            KeycapStyle::Plate
                | KeycapStyle::LinearKbd
                | KeycapStyle::FaintFill
                | KeycapStyle::Hairline
        )
    }

    /// The plate's fill alpha.
    pub fn fill_alpha(self) -> f64 {
        match self {
            KeycapStyle::Plate => 0.14,
            KeycapStyle::LinearKbd => 0.10,
            KeycapStyle::FaintFill => 0.06,
            _ => 0.0,
        }
    }

    /// The plate's outline alpha.
    pub fn border_alpha(self) -> f64 {
        if self == KeycapStyle::Hairline { 0.22 } else { 0.0 }
    }

    /// The glyph's share of the hint ink's alpha.
    pub fn glyph_alpha(self) -> f64 {
        match self {
            KeycapStyle::FaintFill => 0.8,
            KeycapStyle::QuietSmall => 0.55,
            _ => 1.0,
        }
    }

    /// The glyph's point size.
    pub fn glyph_size(self, scale: f64) -> f64 {
        match self {
            KeycapStyle::LinearKbd => 11.0 * scale,
            KeycapStyle::QuietSmall => 10.0 * scale,
            _ => CAPTION_BASE * scale,
        }
    }

    /// The glyph's weight: emphasized on a plate, regular bare.
    pub fn glyph_weight(self) -> GlyphWeight {
        if self.has_plate() { GlyphWeight::Emphasis } else { GlyphWeight::Regular }
    }

    /// The plate's height; none fills the button.
    pub fn plate_height(self, scale: f64) -> Option<f64> {
        match self {
            KeycapStyle::LinearKbd => Some(16.0 * scale),
            KeycapStyle::FaintFill | KeycapStyle::Hairline => Some(18.0 * scale),
            _ => None,
        }
    }

    /// From the key's end to the button's trailing edge.
    pub fn trailing(self, scale: f64) -> f64 {
        match self {
            KeycapStyle::Plate => KEYCAP_INSET * scale,
            KeycapStyle::LinearKbd => 5.0 * scale,
            KeycapStyle::FaintFill | KeycapStyle::Hairline => 4.0 * scale,
            _ => KEYCAP_LEADING * scale,
        }
    }

    /// From the title's end to the key.
    pub fn gap(self, scale: f64) -> f64 {
        match self {
            KeycapStyle::Plate => KEYCAP_GAP * scale,
            KeycapStyle::QuietSmall => 4.0 * scale,
            _ => 6.0 * scale,
        }
    }

    /// The plate's room each side of the glyph.
    pub fn plate_padding(self, scale: f64) -> f64 {
        if self == KeycapStyle::LinearKbd { 4.0 * scale } else { KEYCAP_PADDING * scale }
    }

    /// The plate's corner on a plate `width` × `height`: concentric with the button (its corner
    /// less the plate's inset from the end), at least the floor, at most half the plate's height.
    pub fn corner_radius(
        self,
        width: f64,
        height: f64,
        scale: f64,
        button_corner_radius: f64,
    ) -> f64 {
        let padding =
            if self == KeycapStyle::Plate { KEYCAP_INSET * scale } else { self.trailing(scale) };
        keycap_corner(width, height, button_corner_radius, padding)
    }

    /// Every number the style draws with.
    pub fn look(self, scale: f64, _button_corner_radius: f64) -> KeycapLook {
        KeycapLook {
            style: self,
            title: self.title().into(),
            note: self.note().into(),
            has_plate: self.has_plate(),
            fill_alpha: self.fill_alpha(),
            border_alpha: self.border_alpha(),
            glyph_alpha: self.glyph_alpha(),
            glyph_size: self.glyph_size(scale),
            glyph_weight: self.glyph_weight(),
            plate_height: self.plate_height(scale),
            trailing: self.trailing(scale),
            gap: self.gap(scale),
            plate_padding: self.plate_padding(scale),
            default_shows_key: self.shows_key(Role::Default),
            others_show_key: self.shows_key(Role::Cancel),
        }
    }
}

/// `ConcentricContainer(outerRadius:padding:).childRadius(fitting:)`, then the floor and half
/// the shorter side.
fn keycap_corner(width: f64, height: f64, outer: f64, padding: f64) -> f64 {
    let child = (outer.max(0.0) - padding.max(0.0)).max(0.0);
    let half = width.min(height) / 2.0;
    let fitted = child.min(half).max(0.0);
    fitted.max(KEYCAP_CORNER_FLOOR).min(half)
}

/// The chip's inset at scale 1 (`CmuxDialogMetrics.keycapInset`).
pub const KEYCAP_INSET: f64 = 3.0;
/// The smallest chip corner that still reads round (`keycapCornerFloor`).
pub const KEYCAP_CORNER_FLOOR: f64 = 2.0;
/// `keycapPadding` at scale 1.
pub const KEYCAP_PADDING: f64 = 4.0;
/// `keycapLeading` at scale 1.
pub const KEYCAP_LEADING: f64 = 12.0;
/// `keycapGap` at scale 1.
pub const KEYCAP_GAP: f64 = 8.0;

/// The dialog sizes that do not hang on the density (`CmuxDialogMetrics`), at one text scale.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    /// A button's height (26).
    pub button_height: f64,
    /// A button's least width (72).
    pub button_min_width: f64,
    /// A button's corner (the tab's).
    pub button_corner_radius: f64,
    /// The card's width (380).
    pub width: f64,
    /// The card's width with an icon (432).
    pub width_with_icon: f64,
    /// Between the buttons (12).
    pub buttons_gap: f64,
    /// A field's height (24).
    pub field_height: f64,
    /// The icon's side (40).
    pub icon_size: f64,
    /// Icon to text (12).
    pub icon_gap: f64,
    /// A floating prompt's header icon (20).
    pub header_icon_size: f64,
    /// Header icon to title (8).
    pub header_icon_gap: f64,
    /// A scrolling message's box height (240).
    pub lines_max_height: f64,
    /// Past these many lines a message scrolls.
    pub scrolling_line_count: usize,
    /// Past these many characters a message scrolls.
    pub scrolling_character_count: usize,
    /// A keyed button's height (the button's).
    pub keycap_button_height: f64,
    /// A keyed button's corner (the button's).
    pub keycap_button_corner_radius: f64,
    /// The chip's inset (3).
    pub keycap_inset: f64,
    /// The chip's least corner (2, unscaled).
    pub keycap_corner_floor: f64,
    /// The plate's room each side (4).
    pub keycap_padding: f64,
    /// The button's leading inset (12).
    pub keycap_leading: f64,
    /// Title to key (8).
    pub keycap_gap: f64,
    /// A code's side inset (10).
    pub code_inset: f64,
    /// A code's top and bottom inset (7).
    pub code_vertical_inset: f64,
    /// The code well's fill alpha.
    pub code_well_fill: f64,
    /// The code well's edge alpha.
    pub code_well_edge: f64,
    /// A pairing code's QR side (120).
    pub qr_side: f64,
}

impl Metrics {
    /// The sizes at `scale` with the density's `button_corner_radius`.
    pub fn new(scale: f64, button_corner_radius: f64) -> Self {
        Self {
            button_height: 26.0 * scale,
            button_min_width: 72.0 * scale,
            button_corner_radius,
            width: 380.0 * scale,
            width_with_icon: 432.0 * scale,
            buttons_gap: 12.0 * scale,
            field_height: 24.0 * scale,
            icon_size: 40.0 * scale,
            icon_gap: 12.0 * scale,
            header_icon_size: 20.0 * scale,
            header_icon_gap: 8.0 * scale,
            lines_max_height: 240.0 * scale,
            scrolling_line_count: super::values::SCROLLING_LINE_COUNT,
            scrolling_character_count: super::values::SCROLLING_CHARACTER_COUNT,
            keycap_button_height: 26.0 * scale,
            keycap_button_corner_radius: button_corner_radius,
            keycap_inset: KEYCAP_INSET * scale,
            keycap_corner_floor: KEYCAP_CORNER_FLOOR,
            keycap_padding: KEYCAP_PADDING * scale,
            keycap_leading: KEYCAP_LEADING * scale,
            keycap_gap: KEYCAP_GAP * scale,
            code_inset: 10.0 * scale,
            code_vertical_inset: 7.0 * scale,
            code_well_fill: 0.06,
            code_well_edge: 0.12,
            qr_side: 120.0 * scale,
        }
    }

    /// `CmuxDialogMetrics.keycapCornerRadius(fitting:)`: the plate style's chip corner.
    pub fn keycap_corner_radius(&self, width: f64, height: f64) -> f64 {
        keycap_corner(width, height, self.keycap_button_corner_radius, self.keycap_inset)
    }
}

/// `keycapLook` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StyleRequest {
    /// The style.
    pub style: KeycapStyle,
    /// `Typography.userScale`.
    #[serde(default = "one")]
    pub user_scale: f64,
    /// `Metrics.buttonCornerRadius`.
    #[serde(default)]
    pub button_corner_radius: f64,
}

/// `keycapShowsKey` request.
#[derive(Deserialize)]
pub struct ShowsKeyRequest {
    /// The style.
    pub style: KeycapStyle,
    /// The button's role.
    pub role: Role,
}

/// `keycapCornerRadius` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CornerRequest {
    /// The style.
    pub style: KeycapStyle,
    /// The plate's width.
    pub width: f64,
    /// The plate's height.
    pub height: f64,
    /// `Typography.userScale`.
    #[serde(default = "one")]
    pub user_scale: f64,
    /// `Metrics.buttonCornerRadius`.
    pub button_corner_radius: f64,
}

/// `metrics` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetricsRequest {
    /// `Typography.userScale`.
    #[serde(default = "one")]
    pub user_scale: f64,
    /// `Metrics.buttonCornerRadius`.
    pub button_corner_radius: f64,
}

fn one() -> f64 {
    1.0
}
