//! The JSON shape of a terminal's colors (`fg`, `bg`, cursor, selection,
//! palette, and the opted-in `overrides`), shared by attach, render and
//! snapshot replies.

use crate::panic_free::JsonFields;
use serde_json::{Value, json};

use crate::{Rgb, TerminalColors};

fn color_hex(color: Option<Rgb>) -> Option<String> {
    color.map(|color| format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b))
}

pub(crate) fn terminal_colors_json(colors: TerminalColors, include_overrides: bool) -> Value {
    let cursor_style = colors.cursor_style.map(|style| match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    });
    let palette = colors
        .palette
        .into_iter()
        .enumerate()
        .filter_map(|(index, color)| {
            color_hex(color).map(|color| (index.to_string(), Value::String(color)))
        })
        .collect::<serde_json::Map<String, Value>>();
    let mut value = json!({
        "fg": color_hex(colors.fg),
        "bg": color_hex(colors.bg),
        "cursor": color_hex(colors.cursor),
        "selection_bg": color_hex(colors.selection_bg),
        "selection_fg": color_hex(colors.selection_fg),
        "palette": palette,
        "cursor_style": cursor_style,
        "cursor_blink": colors.cursor_blink,
    });
    // Older generated SDKs reject unknown fields. Only viewers that opted in
    // before attaching receive the additional provenance object.
    if include_overrides {
        value.insert(
            "overrides",
            json!({
                "fg": color_hex(colors.fg_override),
                "bg": color_hex(colors.bg_override),
                "cursor": color_hex(colors.cursor_override),
            }),
        );
    }
    value
}
