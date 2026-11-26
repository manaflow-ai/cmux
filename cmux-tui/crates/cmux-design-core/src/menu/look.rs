//! `MenuLook` (CmuxNextDesign/MenuLook.swift) and the look's use on a `GlassMenu`
//! (GlassMenu/GlassMenu+Look.swift): the theme file's `appearance.menu.*` / `appearance.popover.*`
//! keys, the page tokens they send, the shadow steps and the flush submenu anchor.

use super::color::{ThemeRgb, css};
use super::{HIGHLIGHT_INSET, Rect};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// `Elevation`: a drop's offset, blur and alpha.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Elevation {
    pub offset: f64,
    pub blur: f64,
    pub alpha: f64,
}

/// `PopupStyle.elevation1`.
pub const ELEVATION_1: Elevation = Elevation { offset: 1.0, blur: 2.0, alpha: 0.07 };
/// `PopupStyle.elevation2` (the standard popup drop).
pub const ELEVATION_2: Elevation = Elevation { offset: 2.0, blur: 6.0, alpha: 0.11 };
/// The `strong` step: the standard drop's geometry, darker.
pub const ELEVATION_STRONG: Elevation = Elevation { offset: 2.0, blur: 6.0, alpha: 0.28 };

/// `PopupStyle.standard.shadowMargin`: the standard drop's blur plus offset.
pub fn shadow_margin() -> f64 {
    ELEVATION_2.blur + ELEVATION_2.offset
}

/// `MenuLook.Shadow`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Shadow {
    #[default]
    Standard,
    None,
    Subtle,
    Strong,
}

impl Shadow {
    pub const ALL: [Shadow; 4] = [Shadow::Standard, Shadow::None, Shadow::Subtle, Shadow::Strong];

    /// The drop; `None` draws none.
    pub fn elevation(self) -> Option<Elevation> {
        match self {
            Shadow::Standard => Some(ELEVATION_2),
            Shadow::None => None,
            Shadow::Subtle => Some(ELEVATION_1),
            Shadow::Strong => Some(ELEVATION_STRONG),
        }
    }
}

/// `MenuLook.Ink`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Ink {
    #[default]
    Standard,
    Muted,
}

/// `MenuLook.Separator`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Separator {
    #[default]
    Standard,
    Subtle,
    None,
}

impl Separator {
    /// The share of the separator's ink a line draws in.
    pub fn ink_share(self) -> f64 {
        match self {
            Separator::Standard => 1.0,
            Separator::Subtle => 0.5,
            Separator::None => 0.0,
        }
    }
}

/// `MenuLook.DestructiveInk`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DestructiveInk {
    #[default]
    Standard,
    Plain,
}

/// `MenuLook.Submenu`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Submenu {
    #[default]
    Standard,
    Flush,
}

/// `MenuLook.PopoverHeader`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PopoverHeader {
    #[default]
    Standard,
    Strong,
}

/// `MenuLook.ProgressFill`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProgressFill {
    #[default]
    Standard,
    Muted,
    Strong,
}

/// `MenuLook`: every unset key is today's look.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MenuLook {
    pub corner_radius: Option<f64>,
    pub border_opacity: Option<f64>,
    pub shadow: Shadow,
    pub fill: Option<ThemeRgb>,
    pub padding: Option<f64>,
    pub highlight_radius: Option<f64>,
    pub row_height: Option<f64>,
    pub shortcuts: Ink,
    pub section_label: Ink,
    pub separator: Separator,
    pub destructive_ink: DestructiveInk,
    pub submenu: Submenu,
    pub subtitle: Ink,
    pub popover_padding: Option<f64>,
    pub popover_header: PopoverHeader,
    pub progress_height: Option<f64>,
    pub progress_fill: ProgressFill,
}

/// `MenuLook.mutedShare`: the text share a muted secondary ink draws in on a page.
pub const MUTED_SHARE: f64 = 0.45;

/// `MenuLook.number`: a CSS number, no trailing `.0`, at most three decimals.
pub fn number(value: f64) -> String {
    let rounded = (value * 1000.0).round() / 1000.0;
    if rounded == rounded.round() { format!("{}", rounded as i64) } else { format!("{rounded}") }
}

impl MenuLook {
    /// `resolvedPadding`: the panel's inner padding and the hover fill's inset.
    pub fn resolved_padding(&self) -> f64 {
        self.padding.unwrap_or(HIGHLIGHT_INSET)
    }

    /// `webVariables`: the page tokens for the keys that are set.
    pub fn web_variables(&self) -> BTreeMap<String, String> {
        let mut tokens = BTreeMap::new();
        let mut set = |name: &str, value: String| {
            tokens.insert(name.to_string(), value);
        };
        let share = |value: f64| {
            format!("color-mix(in srgb, currentColor {}%, transparent)", number(value * 100.0))
        };
        let px = |value: f64| format!("{}px", number(value));
        let muted = share(MUTED_SHARE);
        if let Some(v) = self.corner_radius {
            set("--menu-radius", px(v));
        }
        if let Some(v) = self.border_opacity {
            set("--menu-border", share(v));
        }
        if self.shadow != Shadow::Standard {
            let value = self.shadow.elevation().map_or_else(
                || "none".to_string(),
                |e| {
                    format!(
                        "0 {}px {}px rgba(0, 0, 0, {})",
                        number(e.offset),
                        number(e.blur),
                        number(e.alpha)
                    )
                },
            );
            set("--menu-shadow", value);
        }
        if let Some(fill) = self.fill {
            set("--menu-fill", css(fill));
        }
        if let Some(v) = self.padding {
            set("--menu-padding", px(v));
        }
        if let Some(v) = self.highlight_radius {
            set("--menu-hover-radius", px(v));
        }
        if let Some(v) = self.row_height {
            set("--menu-row-height", px(v));
        }
        if self.shortcuts == Ink::Muted {
            set("--menu-shortcut-color", muted.clone());
        }
        if self.section_label == Ink::Muted {
            set("--menu-label-color", muted.clone());
            set("--menu-label-weight", "var(--weight-regular, 400)".to_string());
        }
        match self.separator {
            Separator::Standard => {}
            Separator::Subtle => set("--menu-separator", share(0.06)),
            Separator::None => set("--menu-separator", "transparent".to_string()),
        }
        if self.destructive_ink == DestructiveInk::Plain {
            set("--menu-destructive", "currentColor".to_string());
        }
        if self.submenu == Submenu::Flush {
            let padding = self.resolved_padding();
            set("--menu-submenu-offset", format!("{}px", number(padding)));
            set("--menu-submenu-align-offset", format!("{}px", number(-padding)));
        }
        if self.subtitle == Ink::Muted {
            set("--menu-subtitle-color", muted);
        }
        if let Some(v) = self.popover_padding {
            set("--popover-padding", px(v));
        }
        if self.popover_header == PopoverHeader::Strong {
            set("--popover-header-color", "currentColor".to_string());
            set("--popover-header-size", "var(--text-body, 13px)".to_string());
            set("--popover-header-weight", "var(--weight-emphasis, 600)".to_string());
        }
        if let Some(v) = self.progress_height {
            set("--popover-progress-height", px(v));
        }
        match self.progress_fill {
            ProgressFill::Standard => {}
            ProgressFill::Muted => set("--popover-progress-fill", share(0.55)),
            ProgressFill::Strong => set("--popover-progress-fill", "currentColor".to_string()),
        }
        tokens
    }
}

/// What `GlassMenu.applyLook` sets on the panel for `look`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppliedLook {
    /// The panel's corner: the look's, else the surface radius in effect.
    pub corner_radius: f64,
    /// The panel's drop; `None` draws none.
    pub elevation: Option<Elevation>,
    /// Whether the fill-and-edge view (`GlassMenuLookView`) is shown.
    pub draws_look_view: bool,
    /// The rows' inner padding.
    pub padding: f64,
    /// The share of the separator ink a line draws in.
    pub separator_ink_share: f64,
}

/// `GlassMenu.applyLook(_:)`'s decisions; `surface_radius` is `GlassMenuMaterial.cornerRadius` now.
pub fn apply_look(look: &MenuLook, surface_radius: f64) -> AppliedLook {
    AppliedLook {
        corner_radius: look.corner_radius.unwrap_or(surface_radius),
        elevation: look.shadow.elevation(),
        draws_look_view: look.fill.is_some() || look.border_opacity.is_some(),
        padding: look.resolved_padding(),
        separator_ink_share: look.separator.ink_share(),
    }
}

/// `PopupPlacement.sideGap`.
pub const SIDE_GAP: f64 = 4.0;

/// `GlassMenu.flushAnchor(row:card:padding:gap:)`.
pub fn flush_anchor(row: Rect, card: Rect, padding: f64, gap: f64) -> Rect {
    let min_x = card.x + gap;
    let max_x = min_x.max(card.x + card.width - gap);
    Rect { x: min_x, y: row.y, width: max_x - min_x, height: row.height + padding }
}

/// `GlassMenu.submenuAnchor(row:)`: the row itself unless the look's submenu is flush.
pub fn submenu_anchor(look: &MenuLook, row: Rect, card: Rect) -> Rect {
    if look.submenu != Submenu::Flush {
        return row;
    }
    flush_anchor(row, card, look.resolved_padding(), SIDE_GAP)
}
