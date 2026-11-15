//! Observation through the engine and the fake desktop: stable ids across
//! looks and actions, diffs, stale ids, guards and the menu bar listing.

use std::sync::atomic::{AtomicU64, Ordering};

use super::*;
use crate::desktop::fake::{Event, FakeDesktop};

fn ctx() -> CallContext {
    CallContext {
        session: "s1".into(),
        label: "Claude".into(),
        call_id: None,
        origin: OriginKind::Local,
        tag: None,
    }
}

fn el(id: &str, role: &str, name: &str) -> Element {
    Element { id: id.into(), role: role.into(), name: name.into(), ..Element::default() }
}

fn framed(mut e: Element, x: f64, y: f64, w: f64, h: f64) -> Element {
    e.frame = Some(Rect { x, y, width: w, height: h });
    e
}

/// Safari's window 1 (800x600 at 100,100): a Name field, a Save button, a
/// menu bar with File > Save As…. `generation` changes every platform id,
/// as a new walk does on macOS.
fn form(generation: u32, save_disabled: bool, focus_save: bool, name: &str) -> Element {
    let p = |i: u32| format!("{generation}.{i}");
    let mut field = framed(el(&p(1), "text_field", "Name"), 120.0, 160.0, 200.0, 22.0);
    field.value = name.into();
    field.actions = vec!["confirm".into()];
    let mut save = framed(el(&p(2), "button", "Save"), 120.0, 200.0, 80.0, 22.0);
    save.actions = vec!["press".into()];
    save.disabled = save_disabled;
    save.focused = focus_save;
    let mut item = el(&p(12), "menu_item", "Save As…");
    item.shortcut = "cmd+shift+s".into();
    item.actions = vec!["press".into()];
    let mut file = el(&p(10), "menu_bar_item", "File");
    file.actions = vec!["press".into()];
    file.children = vec![Element { children: vec![item], ..el(&p(11), "menu", "") }];
    let bar = Element { children: vec![file], ..el(&p(9), "menu_bar", "") };
    Element {
        children: vec![field, save, bar],
        ..framed(el(&p(0), "window", "Form"), 100.0, 100.0, 800.0, 600.0)
    }
}

fn rig() -> (Arc<FakeDesktop>, Engine) {
    let d = Arc::new(FakeDesktop::standard());
    *d.tree.lock().unwrap() = Some(form(1, false, false, ""));
    let mut parts = EngineParts::new(d.clone());
    let now = Arc::new(AtomicU64::new(0));
    let (a, b) = (now.clone(), now);
    parts.sleep = Arc::new(move |t| {
        a.fetch_add(t.as_millis() as u64, Ordering::SeqCst);
    });
    parts.clock = Arc::new(move || Duration::from_millis(b.load(Ordering::SeqCst)));
    (d, Engine::new(parts))
}

fn tree_text(out: &ToolOutput) -> String {
    out.body["tree"]
        .as_str()
        .or_else(|| out.body["state"]["tree"].as_str())
        .unwrap_or_else(|| panic!("no tree: {}", out.body))
        .to_string()
}

fn set_tree(d: &FakeDesktop, root: Element) {
    *d.tree.lock().unwrap() = Some(root);
}

#[test]
fn the_first_look_is_whole_then_only_changes_and_ids_stay() {
    let (d, e) = rig();
    let first = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert_eq!(
        tree_text(&first),
        "[1] window \"Form\"\n  [2] text field \"Name\" actions: confirm\n  [3] button \"Save\"\n  [4] menu bar (click a menu's id to list its items)\n    [5] menu bar item \"File\"\nFocus: no element of this window has keyboard focus"
    );
    // Nothing changed: said so, in one line.
    set_tree(&d, form(2, false, false, ""));
    let again = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert!(
        tree_text(&again).starts_with("No change in window 1's elements"),
        "{}",
        tree_text(&again)
    );
    // A value changed: only that line, with what it was; same id.
    set_tree(&d, form(3, true, false, "Ada"));
    let changed = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert_eq!(
        tree_text(&changed),
        "Changes in window 1 since your last look (+0 ~2 -0):\n~ [2] text field \"Name\" = \"Ada\" actions: confirm (was: empty)\n~ [3] button \"Save\" disabled (was: enabled)"
    );
    let full = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "full": true}));
    assert!(
        tree_text(&full).starts_with("[1] window \"Form\"\n  [2] text field \"Name\" = \"Ada\"")
    );
    // Another agent's first look is whole.
    let other = CallContext { session: "s2".into(), ..ctx() };
    assert!(
        tree_text(&e.call(&other, "get_ui_tree", &json!({"window_id": "1"})))
            .starts_with("[1] window")
    );
}

#[test]
fn an_action_maps_the_small_id_to_the_desktops_and_returns_the_change() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    // The window changes after the look (a new walk, new platform ids).
    set_tree(&d, form(2, false, false, ""));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3"}));
    assert!(!out.is_error, "{}", out.body);
    let Event::Click { element: Some(id), .. } = &d.events()[0] else { panic!("{:?}", d.events()) };
    // The registry's latest walk (by the guard or the look) has it as 2.2 or 1.2;
    // either way it is the desktop's id for Save, never the agent's "3".
    assert!(id.ends_with(".2"), "{id}");
    assert!(tree_text(&out).starts_with("No change in window 1's elements"), "{}", tree_text(&out));
    // The MCP result: the JSON, then the outline as its own text block.
    let mcp = out.to_mcp();
    assert!(!mcp["content"][0]["text"].as_str().unwrap().contains("No change"));
    assert!(mcp["content"][1]["text"].as_str().unwrap().starts_with("No change"));
}

#[test]
fn an_unknown_or_gone_id_is_refused_and_says_to_look_again() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "99"}));
    assert_eq!(out.code.as_deref(), Some("stale_element"));
    assert!(out.body["error"].as_str().unwrap().contains("is not in window 1"));
    // Save goes away; its id is refused by name.
    let mut gone = form(2, false, false, "");
    gone.children.remove(1);
    set_tree(&d, gone);
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "[3]"}));
    assert_eq!(out.code.as_deref(), Some("stale_element"));
    let msg = out.body["error"].as_str().unwrap();
    assert!(msg.contains("[3] (button \"Save\") is no longer in window 1"), "{msg}");
    assert!(d.events().is_empty());
    // Old desktop ids still pass through as they are.
    set_tree(&d, form(3, false, false, ""));
    let out =
        e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3.2", "observe": false}));
    assert!(!out.is_error, "{}", out.body);
}

#[test]
fn a_disabled_element_is_refused_on_a_fresh_read_and_force_skips_it() {
    let (d, e) = rig();
    set_tree(&d, form(1, true, false, ""));
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3"}));
    assert_eq!(out.code.as_deref(), Some("element_disabled"), "{}", out.body);
    assert!(d.events().is_empty());
    // Enabled since the look: the fresh read lets it through.
    set_tree(&d, form(2, false, false, ""));
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    set_tree(&d, form(3, true, false, ""));
    let forced = e.call(
        &ctx(),
        "click",
        &json!({"window_id": "1", "element_id": "3", "force": true, "observe": false}),
    );
    assert!(!forced.is_error, "{}", forced.body);
}

#[test]
fn a_pixel_click_on_the_title_bar_is_refused_in_the_background_only() {
    let (d, e) = rig();
    // Geometry: no screenshot yet, so pixels are points from the window's corner.
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "x": 400.0, "y": 10.0}));
    assert_eq!(out.code.as_deref(), Some("title_bar"), "{}", out.body);
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "x": 900.0, "y": 300.0}));
    assert_eq!(out.code.as_deref(), Some("point_outside_window"), "{}", out.body);
    assert!(d.events().is_empty());
    let inside =
        e.call(&ctx(), "click", &json!({"window_id": "1", "x": 60.0, "y": 70.0, "observe": false}));
    assert!(!inside.is_error, "{}", inside.body);
}

#[test]
fn typing_with_focus_on_a_button_is_refused_and_into_the_field_goes_through() {
    let (d, e) = rig();
    set_tree(&d, form(1, false, true, ""));
    let out = e.call(&ctx(), "type_text", &json!({"window_id": "1", "text": "Ada"}));
    assert_eq!(out.code.as_deref(), Some("focus_not_on_text"), "{}", out.body);
    let msg = out.body["error"].as_str().unwrap();
    assert!(
        msg.contains("[3] button \"Save\"") && msg.contains("[2] text field \"Name\""),
        "{msg}"
    );
    assert!(d.events().is_empty());
    let into = e.call(
        &ctx(),
        "type_text",
        &json!({"window_id": "1", "text": "Ada", "element_id": "2", "observe": false}),
    );
    assert!(!into.is_error, "{}", into.body);
    let out =
        e.call(&ctx(), "type_text", &json!({"window_id": "1", "text": "x", "element_id": "3"}));
    assert_eq!(out.code.as_deref(), Some("not_a_text_field"));
}

#[test]
fn a_menu_bar_menus_id_lists_its_items_without_opening_it() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    // An action's state walks without the menus; the menu's id still works.
    e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3"}));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "5"}));
    assert!(!out.is_error, "{}", out.body);
    assert_eq!(out.body["menu"]["state"], "menu_bar");
    assert!(out.body.get("state").is_none(), "nothing acted, nothing to settle");
    let text = tree_text(&out);
    assert!(text.starts_with("Menu \"File\" (not opened; its items):\n["), "{text}");
    assert!(text.ends_with("menu item \"Save As…\" cmd+shift+s"), "{text}");
    let item: String =
        text.lines().nth(1).unwrap()[1..].chars().take_while(char::is_ascii_digit).collect();
    // Only the Save click reached the desktop.
    assert_eq!(d.events().len(), 1);
    // Clicking the listed item runs it by the desktop's id.
    let run =
        e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": item, "observe": false}));
    assert!(!run.is_error, "{}", run.body);
    let Event::Click { element: Some(id), .. } = &d.events()[1] else { panic!() };
    assert!(id.ends_with(".12"), "{id}");
}

#[test]
fn json_format_keeps_the_tree_whole_for_scripts() {
    let (_d, e) = rig();
    let out = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "format": "json"}));
    assert_eq!(out.body["root"]["children"][1]["id"], "3");
    assert_eq!(out.body["root"]["children"][1]["name"], "Save");
    assert!(out.body.get("tree").is_none());
}

#[test]
fn a_retried_call_forgets_the_look_so_the_next_is_whole() {
    let (_d, e) = rig();
    let c = CallContext { call_id: Some("same".into()), ..ctx() };
    e.call(&c, "click", &json!({"window_id": "1", "element_id": "e1"}));
    e.call(&c, "click", &json!({"window_id": "1", "element_id": "e1"}));
    let look = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert!(tree_text(&look).starts_with("[1] window"), "{}", tree_text(&look));
}

#[test]
fn a_scripts_json_look_is_not_the_models_last_look() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "format": "json"}));
    set_tree(&d, form(2, false, false, "Ada"));
    // The model never read the tree: its first own look is whole.
    let look = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert!(tree_text(&look).starts_with("[1] window"), "{}", tree_text(&look));
}

#[test]
fn an_id_from_another_window_names_its_window() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    // Window 2 is 1Password, denied by default: use a config without a deny list.
    let _ = d;
    e.set_config(PolicyConfig { denied_apps: vec![], ..PolicyConfig::default() });
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "2"}));
    let out = e.call(&ctx(), "click", &json!({"window_id": "2", "element_id": "3"}));
    assert_eq!(out.code.as_deref(), Some("stale_element"), "{}", out.body);
    let msg = out.body["error"].as_str().unwrap();
    assert!(msg.contains("belongs to window 1, not window 2"), "{msg}");
}

#[test]
fn a_title_bar_click_after_a_look_cut_short_is_still_refused() {
    let (d, e) = rig();
    // A look cut at max_nodes 2 is truncated; the guard reads the window again.
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "max_nodes": 2}));
    let walks = *d.walks.lock().unwrap();
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "x": 400.0, "y": 10.0}));
    assert_eq!(out.code.as_deref(), Some("title_bar"), "{}", out.body);
    assert!(*d.walks.lock().unwrap() > walks, "a fresh walk decided it");
}
