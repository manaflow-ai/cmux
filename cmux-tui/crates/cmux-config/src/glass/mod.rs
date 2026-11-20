//! The glass look: `appearance.glass.<role>.{material,tint,tintStrength,veil}`
//! for the seven surface roles (`schemas/surface-roles/surface-roles.json`)
//! plus the agent pane's `composer` and `chrome`, resolved and clamped (cmuxterm-hq
//! `docs/design/customization-api-state.md` section 4).
//!
//! The rows live in one hand-edited source, `schemas/settings/source/glass.json`,
//! embedded here so the daemon, the CLI and the phone read the same paths,
//! choices, ranges and defaults as the app (whose Swift constants
//! `scripts/cmux-next/gen-settings-sources.py` writes from the same file).
//!
//! Every default is today's look: an unset role resolves to `material: None`
//! (the built-in pick), `tint: None` (the theme's glass tint), the role's
//! level `tint_strength` (chrome 1, popover and menu 1.25, chip 1.5) and
//! `veil: None` (the role's own light and dark veils). A value of the wrong
//! type is ignored (the default applies, as `effective_value` does); a number
//! outside the row's range is clamped into it, as `AppearanceTuning` clamps
//! `glassTransparency`.

use std::sync::OnceLock;

use serde::Serialize;
use serde_json::{Map, Value};

use crate::schema::is_hex_color;
use crate::value::value_at;

static SOURCE: &str = include_str!("../../../../../schemas/settings/source/glass.json");

/// The glass roles, in `glass.json` order: the seven surface roles, the agent
/// pane's composer (a web surface), then the window's chrome.
pub const ROLES: [&str; 9] =
    ["popover", "menu", "card", "group", "toast", "sheet", "tooltip", "composer", "chrome"];

/// The materials a role may pick: a closed vocabulary, never a raw AppKit
/// material name. `plain`, `lens` and `spectrum` are the app's web glass modes
/// (`GlassLensMode`); a native surface draws plain glass for `lens` and
/// `spectrum`.
pub const MATERIALS: [&str; 6] =
    ["plain", "glass-clear", "frosted", "translucent", "lens", "spectrum"];

/// `appearance.glass`.
pub const ROOT_PATH: [&str; 2] = ["appearance", "glass"];

/// One role's resolved glass. `None` keeps the built-in value.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RoleGlass {
    pub material: Option<String>,
    /// `#RRGGBB` or `#RRGGBBAA`.
    pub tint: Option<String>,
    pub tint_strength: f64,
    pub veil: Option<f64>,
}

/// Every role's resolved glass, in [`ROLES`] order.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GlassLook {
    pub roles: Vec<(String, RoleGlass)>,
}

impl GlassLook {
    /// The look the effective settings document describes.
    pub fn resolve(root: &Value) -> GlassLook {
        let rows = rows();
        let roles = ROLES
            .iter()
            .map(|role| {
                let field = |name: &str| {
                    let path = [ROOT_PATH[0], ROOT_PATH[1], role, name];
                    value_at(root, &path)
                };
                let spec = |name: &str| rows.field(role, name);
                let material = field("material")
                    .and_then(Value::as_str)
                    .filter(|value| MATERIALS.contains(value))
                    .map(str::to_owned);
                let tint = field("tint")
                    .and_then(Value::as_str)
                    .filter(|value| is_hex_color(value))
                    .map(str::to_owned);
                let strength = spec("tintStrength");
                let tint_strength = field("tintStrength")
                    .and_then(Value::as_f64)
                    .filter(|value| value.is_finite())
                    .map_or(strength.default.unwrap_or(1.0), |value| strength.clamp(value));
                let veil_spec = spec("veil");
                let veil = field("veil")
                    .and_then(Value::as_f64)
                    .filter(|value| value.is_finite())
                    .map(|value| veil_spec.clamp(value));
                ((*role).to_owned(), RoleGlass { material, tint, tint_strength, veil })
            })
            .collect();
        GlassLook { roles }
    }

    /// The resolved glass of `role` (one of [`ROLES`]).
    pub fn role(&self, role: &str) -> Option<&RoleGlass> {
        self.roles.iter().find(|(name, _)| name == role).map(|(_, glass)| glass)
    }

    /// Whether every role is at its default (today's look).
    pub fn is_default(&self) -> bool {
        *self == GlassLook::resolve(&Value::Object(Map::new()))
    }

    /// `{<role>: {material, tint, tintStrength, veil}}`, for clients that draw
    /// the glass (the app's resolver, `WebTheme`'s `--ds-glass-*` push).
    pub fn to_json(&self) -> Value {
        Value::Object(
            self.roles
                .iter()
                .map(|(role, glass)| {
                    (role.clone(), serde_json::to_value(glass).unwrap_or(Value::Null))
                })
                .collect(),
        )
    }
}

/// A number row's range and default from `glass.json`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NumberSpec {
    pub min: f64,
    pub max: f64,
    pub default: Option<f64>,
}

impl NumberSpec {
    pub fn clamp(&self, value: f64) -> f64 {
        value.clamp(self.min, self.max)
    }
}

/// The parsed `glass.json` rows.
#[derive(Debug)]
pub struct GlassRows {
    rows: Vec<(String, NumberSpec)>,
    /// Every row key, in source order.
    pub keys: Vec<String>,
}

impl GlassRows {
    fn field(&self, role: &str, name: &str) -> NumberSpec {
        let key = format!("appearance.glass.{role}.{name}");
        self.rows
            .iter()
            .find(|(row, _)| *row == key)
            .map_or(NumberSpec { min: f64::MIN, max: f64::MAX, default: None }, |(_, spec)| *spec)
    }
}

/// The embedded rows, parsed once.
pub fn rows() -> &'static GlassRows {
    static ROWS: OnceLock<GlassRows> = OnceLock::new();
    ROWS.get_or_init(|| {
        // glass.json is compiled in and its tests read it; a broken copy resolves every role to
        // its built-in look rather than ending the daemon.
        let source: Value = serde_json::from_str(SOURCE).unwrap_or(Value::Null);
        let mut rows = Vec::new();
        let mut keys = Vec::new();
        for list in source["lists"].as_array().into_iter().flatten() {
            for row in list["rows"].as_array().into_iter().flatten() {
                let Some(key) = row["key"].as_str() else { continue };
                keys.push(key.to_owned());
                if let Some(range) = row.get("range") {
                    rows.push((
                        key.to_owned(),
                        NumberSpec {
                            min: range["min"].as_f64().unwrap_or(f64::MIN),
                            max: range["max"].as_f64().unwrap_or(f64::MAX),
                            default: row["default"].as_f64(),
                        },
                    ));
                }
            }
        }
        GlassRows { rows, keys }
    })
}

#[cfg(test)]
mod tests;
