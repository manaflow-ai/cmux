//! The shim's menu and dialog callbacks (plain C values and JSON) as rb
//! messages (remote-tab-protocol.md 5.2, 5.3). Pure; serve.rs calls it.

use cmux_remote_browser::proto::{Dialog, DialogKind, Menu, MenuItem, MenuKind, Rect};

/// A page context menu at (`x`, `y`) (CSS px) with the shim's item JSON.
pub fn context_menu(x: i32, y: i32, items_json: &str) -> Result<Menu, String> {
    let _ = (x, y, items_json);
    Err("not implemented".into())
}

/// A `<select>` popup anchored at the element's box (CSS px), with the
/// fork's popup item JSON; `selected` < 0 is no selection.
pub fn select_menu(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    items_json: &str,
    selected: i32,
    multiple: bool,
) -> Result<Menu, String> {
    let _ = (x, y, width, height, items_json, selected, multiple);
    Err("not implemented".into())
}

/// A JS dialog; `None` for a kind the protocol does not know.
pub fn dialog(
    kind: &str,
    origin: &str,
    message: &str,
    default_text: Option<&str>,
    is_reload: bool,
) -> Option<Dialog> {
    let _ = (kind, origin, message, default_text, is_reload);
    let _: Option<(DialogKind, MenuItem, MenuKind, Rect)> = None;
    None
}
