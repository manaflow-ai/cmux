//! The shim's menu and dialog callbacks (C values and JSON) as rb messages.

use cmux_remote_browser::proto::{DialogKind, MenuKind, Rect};
use cmux_remote_browser_host::shim_ui::{context_menu, dialog, select_menu};

#[test]
fn a_context_menu_keeps_command_ids_types_and_submenus() {
    let json = r#"[{"id":100,"label":"Back","enabled":true,"checked":false,"type":"command","items":[]},
        {"id":-1,"label":"","enabled":true,"checked":false,"type":"separator","items":[]},
        {"id":50200,"label":"Speech","enabled":true,"checked":false,"type":"submenu","items":[
            {"id":50201,"label":"Start Speaking","enabled":false,"checked":false,"type":"command","items":[]}]}]"#;
    let menu = context_menu(12, 30, json).expect("menu");
    assert_eq!(menu.kind, MenuKind::Context);
    assert_eq!(menu.anchor, Rect { x: 12.0, y: 30.0, width: 0.0, height: 0.0 });
    assert_eq!(menu.items.len(), 3);
    assert_eq!(menu.items[2].items[0].id, 50201);
    assert!(!menu.items[2].items[0].enabled);
    assert_eq!(menu.selected, None);
    assert!(context_menu(0, 0, "not json").is_err());
}

#[test]
fn a_select_popup_numbers_its_items_by_index_and_keeps_the_selection() {
    let json = r#"[{"label":"Colors","tool_tip":"","type":"group","action":0,"enabled":false,"checked":false},
        {"label":"Red","tool_tip":"","type":"option","action":1,"enabled":true,"checked":false},
        {"label":"","tool_tip":"","type":"separator","action":2,"enabled":true,"checked":false},
        {"label":"Green","tool_tip":"tip","type":"checkable","action":3,"enabled":true,"checked":true}]"#;
    let menu = select_menu(5, 6, 120, 24, json, 3, true).expect("menu");
    assert_eq!(menu.kind, MenuKind::Select);
    assert_eq!(menu.anchor, Rect { x: 5.0, y: 6.0, width: 120.0, height: 24.0 });
    let ids: Vec<i64> = menu.items.iter().map(|i| i.id).collect();
    assert_eq!(ids, vec![0, 1, 2, 3]);
    let types: Vec<&str> = menu.items.iter().map(|i| i.item_type.as_str()).collect();
    assert_eq!(types, vec!["group", "option", "separator", "option"]);
    assert!(menu.items[3].checked);
    assert_eq!(menu.selected, Some(3));
    assert!(menu.multiple);
    assert_eq!(select_menu(0, 0, 1, 1, "[]", -1, false).expect("empty").selected, None);
    assert!(select_menu(0, 0, 1, 1, "{}", 0, false).is_err());
}

#[test]
fn dialogs_map_their_kind_and_keep_the_prompt_text() {
    let d = dialog("prompt", "https://a.test", "Name?", Some("Ann"), false).expect("dialog");
    assert_eq!(d.kind, DialogKind::Prompt);
    assert_eq!(d.default_text.as_deref(), Some("Ann"));
    let d = dialog("beforeunload", "https://a.test", "", None, true).expect("dialog");
    assert_eq!(d.kind, DialogKind::Beforeunload);
    assert!(d.is_reload);
    assert!(dialog("alert", "o", "m", None, false).is_some_and(|d| d.kind == DialogKind::Alert));
    assert!(dialog("confirm", "o", "m", None, false).is_some());
    assert!(dialog("bogus", "o", "m", None, false).is_none());
}
