//! Field-by-field readers of the layout-ish cmux.json objects, driven by the settings schema
//! (ranges and defaults come from `schemas/settings/settings-schema.json`, not copies). Swift
//! `ConfigFieldReader`, `PaneRingConfigParser`, `StatusIndicatorConfigParser`, `ColumnLayoutSettings`
//! and `ContextMenusSetting`.
//!
//! - `fields.focus_ring`, `fields.attention`, `fields.status_indicator`, `fields.status_behavior`
//!   `{root}` answer `{values, defaults, diagnostics}`. `values` holds the keys the file set to a good
//!   value (a color is `null` for the theme, else `{red, green, blue, alpha}`; `focusRing.cornerRadius`
//!   `null` is "follow the pane"), `defaults` every key's default; the caller takes `values[k] ?? defaults[k]`.
//! - `fields.column_layout` `{root}` answers `{values, diagnostics}`: every key resolved (`newColumnWidth`
//!   is `{mode, fixed}`, `fixed` a number when the file named a share).
//! - `fields.context_menus` `{root, contexts}` answers `{showCustomizeItem, layouts, diagnostics}`:
//!   `contexts` are the menu names the app has; each layout is `{items, hidden}`, an item a key string,
//!   `"-"` or `{key, title?, items}`.
//!
//! Part 3, schema-driven the same way (every list, range and default is read from the schema):
//! - `fields.sidebar_sections` `{root}` answers `{values, rowDiagnosticsAt, diagnostics}`: `values` is every
//!   `sidebar.*` section key (and `presence.live`, `workspaceColors.indicatorStyle`) by dotted key, resolved.
//! - `fields.workspace_row` `{root}` answers `{values: {shown, secondLineOrder, overrides, statusPlacement}}`.
//! - `fields.sidebar_border` `{root, defaultShows?}` answers `{values: {shows, width}}`;
//!   `fields.sidebar_surface` `{root}` answers `{value}`; `fields.sidebar_look` `{root}` answers `{look}`.
//! - `fields.pane_toolbar_buttons` and `fields.browser_toolbar_buttons` `{root}` answer `{pinned}`.
//!
//! A diagnostic is `{kind: "invalid_value", path, message}`.

mod column;
mod context_menus;
mod reader;
mod sidebar;
#[cfg(test)]
mod tests;
mod toolbar;

use serde_json::{Value, json};

use super::OpError;
use reader::Reader;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "fields.focus_ring" => with_root(request, focus_ring),
        "fields.attention" => with_root(request, attention),
        "fields.status_indicator" => with_root(request, status_indicator),
        "fields.status_behavior" => with_root(request, status_behavior),
        "fields.column_layout" => with_root(request, column::column_layout),
        "fields.context_menus" => context_menus::op(request),
        "fields.sidebar_sections" => with_root(request, sidebar::sidebar_sections),
        "fields.workspace_row" => with_root(request, sidebar::workspace_row),
        "fields.sidebar_border" => sidebar::sidebar_border(request),
        "fields.sidebar_surface" => with_root(request, sidebar::sidebar_surface),
        "fields.sidebar_look" => with_root(request, sidebar::sidebar_look),
        "fields.pane_toolbar_buttons" => with_root(request, toolbar::pane),
        "fields.browser_toolbar_buttons" => with_root(request, toolbar::browser),
        _ => return None,
    })
}

#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
pub(crate) fn with_root(
    request: &Value,
    read: fn(&Value) -> (Value, Vec<Value>),
) -> Result<Value, OpError> {
    let root = request.get("root").ok_or_else(|| OpError::Invalid("expected `root`".into()))?;
    let (mut out, diags) = read(root);
    out["diagnostics"] = Value::Array(diags);
    Ok(out)
}

fn finish(
    reader: Option<Reader>,
    direct: Vec<Value>,
    keys: &[&str],
    prefix: &str,
) -> (Value, Vec<Value>) {
    let defaults = reader::defaults(prefix, keys);
    let Some(reader) = reader else { return (json!({"values": {}, "defaults": defaults}), direct) };
    let mut diags = direct;
    diags.extend(reader.diagnostics);
    (json!({"values": reader.values, "defaults": defaults}), diags)
}

const FOCUS_STYLE: &[&str] = &["ring", "glow", "none"];

#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn focus_ring(root: &Value) -> (Value, Vec<Value>) {
    let mut direct = Vec::new();
    let mut reader = Reader::open(root, "focusRing", &mut direct);
    if let Some(r) = reader.as_mut() {
        r.bool("enabled");
        r.choice("style", FOCUS_STYLE);
        r.choice("contrast", &["subtle", "standard", "strong"]);
        r.color("color");
        r.number("width");
        match r.members.get("cornerRadius") {
            Some(Value::String(text)) if text == "pane" => {
                r.values.insert("cornerRadius".into(), Value::Null);
            }
            Some(Value::Null) => {
                r.values.insert("cornerRadius".into(), Value::Null);
            }
            _ => r.points("cornerRadius", 0.0, 24.0),
        }
        r.bool("showWhenSinglePane");
    }
    let (mut out, diags) = finish(
        reader,
        direct,
        &["enabled", "style", "contrast", "color", "width", "showWhenSinglePane"],
        "focusRing",
    );
    out["defaults"]["cornerRadius"] = Value::Null;
    (out, diags)
}

fn attention(root: &Value) -> (Value, Vec<Value>) {
    let mut direct = Vec::new();
    let mut reader = Reader::open(root, "notifications.attention", &mut direct);
    if let Some(r) = reader.as_mut() {
        r.choice("style", &["none", "steady", "pulse", "blink"]);
        r.color("color");
        r.choice("terminals", FOCUS_STYLE);
        r.choice("agentChats", FOCUS_STYLE);
        r.number("width");
        r.rounded("blinkCount");
        r.rounded("agentChatBlinkCount");
        r.number("duration");
        for key in ["persist", "flash", "flashOnTyping", "showOnTab", "showOnSidebar"] {
            r.bool(key);
        }
        r.choice("mark", &["badge", "glow"]);
        r.bool("moveToTop");
        r.bool("moveToTopOnAgentFinish");
    }
    finish(
        reader,
        direct,
        &[
            "style",
            "color",
            "terminals",
            "agentChats",
            "width",
            "blinkCount",
            "agentChatBlinkCount",
            "duration",
            "persist",
            "flash",
            "flashOnTyping",
            "showOnTab",
            "showOnSidebar",
            "mark",
            "moveToTop",
            "moveToTopOnAgentFinish",
        ],
        "notifications.attention",
    )
}

/// The sources `appearance.statusIndicator.honorStatusStyle` lists (Swift `StatusReport.Source`, in case order).
pub(crate) const SOURCES: [&str; 7] =
    ["explicit", "run", "agent", "program", "terminalProgress", "browser", "command"];

/// Every source for `true`, none for `false`, else the listed names; `None` for anything else.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn honored_sources(value: &Value) -> Option<Value> {
    match value {
        Value::Bool(true) => Some(json!(SOURCES)),
        Value::Bool(false) => Some(json!([])),
        Value::Array(items) => {
            let mut keep = [false; 7];
            for item in items {
                let at = SOURCES.iter().position(|s| Some(*s) == item.as_str())?;
                keep[at] = true;
            }
            Some(json!(
                SOURCES.iter().zip(keep).filter(|(_, k)| *k).map(|(s, _)| *s).collect::<Vec<_>>()
            ))
        }
        _ => None,
    }
}

const STATUS_KEYS: [&str; 9] = [
    "style",
    "animation",
    "iconSet",
    "size",
    "thickness",
    "color",
    "showAgentWorkingOnTabs",
    "showPageLoading",
    "honorStatusStyle",
];

#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn status_indicator(root: &Value) -> (Value, Vec<Value>) {
    let mut direct = Vec::new();
    let mut reader = Reader::open(root, "appearance.statusIndicator", &mut direct);
    if let Some(r) = reader.as_mut() {
        r.choice("style", &["arc", "native", "dot", "braille", "none"]);
        r.choice("animation", &["animated", "static"]);
        // The Debug-only sets are the Debug switch's, not the setting's.
        let sets = [
            "current",
            "shapes",
            "rings",
            "badges",
            "bars",
            "pips",
            "signs",
            "letters",
            "symbols",
            "symbolsOutline",
            "still",
            "codex",
            "stillDots",
            "stillPictograms",
        ];
        if r.choice("iconSet", &sets) {
            let set =
                r.values.get("iconSet").and_then(Value::as_str).unwrap_or_default().to_string();
            if set == "stillDots" || set == "stillPictograms" {
                r.values.remove("iconSet");
                direct.push(reader::invalid(
                    "appearance.statusIndicator.iconSet",
                    format!("\"{set}\" is a Debug Settings set"),
                ));
            }
        }
        r.number("size");
        r.number("thickness");
        r.color("color");
        r.bool("showAgentWorkingOnTabs");
        r.bool("showPageLoading");
        if let Some(value) = r.members.get("honorStatusStyle") {
            match honored_sources(value) {
                Some(list) => {
                    r.values.insert("honorStatusStyle".into(), list);
                }
                None => direct.push(reader::invalid(
                    "appearance.statusIndicator.honorStatusStyle",
                    "expected true, false or a list of sources",
                )),
            }
        }
    }
    let (mut out, diags) = finish(reader, direct, &STATUS_KEYS[..8], "appearance.statusIndicator");
    if let Some(all) =
        honored_sources(&reader::default_of("appearance.statusIndicator.honorStatusStyle"))
    {
        out["defaults"]["honorStatusStyle"] = all;
    }
    (out, diags)
}

fn status_behavior(root: &Value) -> (Value, Vec<Value>) {
    let mut direct = Vec::new();
    let mut reader = Reader::open(root, "status", &mut direct);
    if let Some(r) = reader.as_mut() {
        r.bool("inferCommandBusy");
        r.number("inferCommandBusyAfter");
        r.number("runNotifyMinimumSeconds");
        r.bool("runNotifyWhenVisible");
    }
    finish(
        reader,
        direct,
        &[
            "inferCommandBusy",
            "inferCommandBusyAfter",
            "runNotifyMinimumSeconds",
            "runNotifyWhenVisible",
        ],
        "status",
    )
}
