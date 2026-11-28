//! `MenuTextSize` (CmuxNextDesign/MenuTextSize.swift): a menu cmux shows draws at the system menu
//! size times the person's text scale; the menu bar keeps the system's, and at the default scale a
//! menu is touched only to put back one this sized.

use serde::Serialize;

/// `MenuTextSize.size(base:scale:)`: the menu font's point size, in half points.
pub fn size(base: f64, scale: f64) -> f64 {
    (base * scale * 2.0).round() / 2.0
}

/// What `MenuTextSize` does to a menu as it begins tracking.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "action")]
pub enum TextSizeAction {
    /// Leave the menu's font as it is.
    Keep,
    /// Set the menu font at `pointSize` and remember the menu as sized.
    Set {
        #[serde(rename = "pointSize")]
        point_size: f64,
    },
    /// Put the system size (`pointSize`, the base) back and forget the menu.
    Restore {
        #[serde(rename = "pointSize")]
        point_size: f64,
    },
}

/// `MenuTextSize.size(_:)`'s decision for a menu: `in_menu_bar` (its root is the main menu),
/// `was_sized` (this sized it before) and its font's `current` point size, if any.
pub fn action(
    base: f64,
    scale: f64,
    current: Option<f64>,
    in_menu_bar: bool,
    was_sized: bool,
) -> TextSizeAction {
    if in_menu_bar {
        return TextSizeAction::Keep;
    }
    if (scale - 1.0).abs() < 0.001 {
        return if was_sized {
            TextSizeAction::Restore { point_size: base }
        } else {
            TextSizeAction::Keep
        };
    }
    let points = size(base, scale);
    if current == Some(points) {
        return TextSizeAction::Keep;
    }
    TextSizeAction::Set { point_size: points }
}
