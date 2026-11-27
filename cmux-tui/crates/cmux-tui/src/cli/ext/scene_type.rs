//! The scene DSL's type, one table for every renderer (RFD 0009, goal 3): each name a scene
//! node's `font` may take, a cmux type role or an Apple text style, at one size and weight.
//!
//! The table is `schemas/type-scale/scene-type.json`. The web scene renderer
//! (`webviews/src/apps/scene/sceneStyle.ts`) reads the same file, and
//! `scripts/cmux-next/gen-type-scale.py` writes AppKit's copy (`SceneType` in
//! `TypeScale.generated.swift`; its `--check` fails when that copy is stale). The design check
//! reads it here, so what it says a name draws is what both renderers draw.

use std::sync::OnceLock;

use serde::Deserialize;

const TABLE: &str = include_str!("../../../../../../schemas/type-scale/scene-type.json");

/// One name in the table.
#[derive(Debug, Deserialize)]
pub(super) struct Style {
    pub name: String,
    /// The SDK helper that draws a role (`widget.ts`); none for an Apple style name.
    #[serde(default)]
    pub helper: Option<String>,
    pub size: f64,
    pub weight: String,
    /// For an Apple style name, the role at its size.
    #[serde(default)]
    pub role: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Table {
    roles: Vec<Style>,
    styles: Vec<Style>,
}

fn table() -> &'static Table {
    static PARSED: OnceLock<Table> = OnceLock::new();
    // The file is built in and read by the tests below, so a table that does not read is caught
    // there; at run time it leaves the check with no roles rather than ending the CLI.
    PARSED.get_or_init(|| {
        serde_json::from_str(TABLE).unwrap_or(Table { roles: Vec::new(), styles: Vec::new() })
    })
}

/// cmux's type roles, large to small.
pub(super) fn roles() -> &'static [Style] {
    &table().roles
}

/// The Apple text style names a scene may still write.
pub(super) fn apple_styles() -> &'static [Style] {
    &table().styles
}

/// What a `font` name draws: a role, else an Apple style name; `None` for a name the renderers
/// do not know (they draw it as `body`).
pub(super) fn named(name: &str) -> Option<&'static Style> {
    roles().iter().chain(apple_styles()).find(|style| style.name == name)
}

/// The role `style` is drawn as, when it is one exactly (a role, or an Apple name at a role's size
/// and weight, like `headline` for `label`).
pub(super) fn exact_role(style: &Style) -> Option<&'static Style> {
    roles().iter().find(|role| role.size == style.size && role.weight == style.weight)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_table_has_cmux_roles_and_every_apple_style_name() {
        let names: Vec<&str> = roles().iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["numeral", "heading", "title", "label", "body", "caption", "footnote"]);
        for apple in [
            "largeTitle",
            "title",
            "title2",
            "title3",
            "headline",
            "body",
            "callout",
            "subheadline",
            "footnote",
            "caption",
            "caption2",
        ] {
            assert!(named(apple).is_some(), "{apple} has a row");
        }
        for style in apple_styles() {
            let role = style.role.as_deref().and_then(named).expect("a style names a role");
            assert_eq!(role.size, style.size, "{} names the role at its size", style.name);
        }
    }

    /// The SDK's `TYPE_ROLES` (tokens.ts) is a copy an extension bundles, so it cannot import the
    /// table; it must say the same sizes and weights.
    #[test]
    fn the_sdk_type_roles_match_the_table() {
        let tokens = include_str!("../../../../cmux-extension-sdk/typescript/src/tokens.ts");
        for role in roles() {
            let row =
                format!("{}: {{ size: {}, weight: \"{}\" }}", role.name, role.size, role.weight);
            assert!(tokens.contains(&row), "tokens.ts TYPE_ROLES has `{row}`");
        }
    }
}
