//! Pop-up buttons and system rows: `ThemedPopUpButtonCell`'s chevron (ThemedPopUpButtonCell.swift)
//! and whether AppKit may add its own rows to a menu (NSMenu+SystemItems.swift).

use super::Rect;
use serde::Serialize;

/// `NSFont.systemFontSize`: a cell with no font of its own.
pub const SYSTEM_FONT_SIZE: f64 = 13.0;

/// The chevron `ThemedPopUpButtonCell.drawBezel` draws in the title's ink.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Chevron {
    /// The SF Symbol: one down for a pull-down, up and down for a pop-up.
    pub symbol: &'static str,
    /// The symbol's point size: the font's at 70%.
    pub point_size: f64,
    /// Whether the themed bezel draws at all (a fill, an ink and a border); else AppKit's own.
    pub themed: bool,
}

/// The chevron for a cell (`pulls_down`, its font's `font_size`, else the system size).
pub fn chevron(
    pulls_down: bool,
    font_size: Option<f64>,
    has_fill: bool,
    has_ink: bool,
    bordered: bool,
) -> Chevron {
    Chevron {
        symbol: if pulls_down { "chevron.down" } else { "chevron.up.chevron.down" },
        point_size: font_size.unwrap_or(SYSTEM_FONT_SIZE) * 0.7,
        themed: has_fill && has_ink && bordered,
    }
}

/// Where the chevron image of `width` x `height` sits in the bezel path's `bounds`: `space3` in
/// from the right edge, centred vertically.
pub fn chevron_frame(bounds: Rect, width: f64, height: f64, space3: f64) -> Rect {
    Rect {
        x: bounds.x + bounds.width - space3 - width,
        y: bounds.y + bounds.height / 2.0 - height / 2.0,
        width,
        height,
    }
}

/// `NSMenu.allowsSystemItems`: plugins on, or (macOS 15.2+) Writing Tools inserted.
pub fn allows_system_items(context_menu_plug_ins: bool, writing_tools: Option<bool>) -> bool {
    context_menu_plug_ins || writing_tools.unwrap_or(false)
}
