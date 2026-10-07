//! The shim's menu and dialog callbacks (plain C values and JSON) as rb
//! messages (remote-tab-protocol.md 5.2, 5.3). Pure; serve.rs calls it.

use cmux_remote_browser::proto::{Dialog, DialogKind, Menu, MenuItem, MenuKind, Rect};
use serde::Deserialize;

/// A page context menu at (`x`, `y`) (CSS px) with the shim's item JSON
/// (the CEF menu model: id, type, label, enabled, checked, items).
pub fn context_menu(x: i32, y: i32, items_json: &str) -> Result<Menu, String> {
    let items: Vec<MenuItem> = serde_json::from_str(items_json).map_err(|e| e.to_string())?;
    Ok(Menu {
        kind: MenuKind::Context,
        anchor: Rect { x: f64::from(x), y: f64::from(y), width: 0.0, height: 0.0 },
        surface: 0,
        items,
        selected: None,
        multiple: false,
        right_aligned: false,
    })
}

/// One `<select>` popup item as the fork sends it (cef_cmux.h RP6).
#[derive(Deserialize)]
struct PopupItem {
    #[serde(default)]
    label: String,
    #[serde(rename = "type")]
    item_type: String,
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    checked: bool,
}

/// A `<select>` popup anchored at the element's box (CSS px), with the
/// fork's popup item JSON; `selected` < 0 is no selection. Items are
/// numbered by their index (the `indices` choice refers to them).
pub fn select_menu(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    items_json: &str,
    selected: i32,
    multiple: bool,
) -> Result<Menu, String> {
    let popup: Vec<PopupItem> = serde_json::from_str(items_json).map_err(|e| e.to_string())?;
    let items = popup
        .into_iter()
        .enumerate()
        .map(|(i, p)| MenuItem {
            id: i64::try_from(i).unwrap_or(i64::MAX),
            item_type: match p.item_type.as_str() {
                // A checkable option is an option of a multiple select.
                "option" | "checkable" => "option".to_string(),
                other => other.to_string(),
            },
            label: p.label,
            enabled: p.enabled,
            checked: p.checked,
            items: Vec::new(),
        })
        .collect();
    Ok(Menu {
        kind: MenuKind::Select,
        anchor: Rect {
            x: f64::from(x),
            y: f64::from(y),
            width: f64::from(width),
            height: f64::from(height),
        },
        surface: 0,
        items,
        selected: u32::try_from(selected).ok(),
        multiple,
        right_aligned: false,
    })
}

/// A JS dialog; `None` for a kind the protocol does not know.
pub fn dialog(
    kind: &str,
    origin: &str,
    message: &str,
    default_text: Option<&str>,
    is_reload: bool,
) -> Option<Dialog> {
    let kind = match kind {
        "alert" => DialogKind::Alert,
        "confirm" => DialogKind::Confirm,
        "prompt" => DialogKind::Prompt,
        "beforeunload" => DialogKind::Beforeunload,
        _ => return None,
    };
    Some(Dialog {
        kind,
        origin: origin.to_string(),
        message: message.to_string(),
        default_text: default_text.map(str::to_string),
        is_reload,
    })
}
