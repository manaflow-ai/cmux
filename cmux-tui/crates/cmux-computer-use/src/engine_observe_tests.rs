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
    // The window's own close button in its title bar: a real title bar.
    let mut close = framed(el(&p(20), "close_button", ""), 108.0, 104.0, 14.0, 14.0);
    close.actions = vec!["press".into()];
    let mut root = Element {
        children: vec![field, save, bar, close],
        ..framed(el(&p(0), "window", "Form"), 100.0, 100.0, 800.0, 600.0)
    };
    // As on macOS: every element has its identity, the same across walks.
    identify(&mut root, 1);
    root
}

/// Gives every element an identity from its place in the tree.
fn identify(e: &mut Element, seed: u64) {
    e.identity = Some(seed);
    for (i, c) in e.children.iter_mut().enumerate() {
        identify(c, seed * 31 + i as u64 + 1);
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
        "[1] window \"Form\"\n  [2] text field \"Name\" actions: confirm\n  [3] button \"Save\"\n  [4] menu bar (click a menu's id to list its items)\n    [5] menu bar item \"File\"\n  [8] close button\nFocus: no element of this window has keyboard focus"
    );
    // Nothing changed: said so, in one sentence.
    set_tree(&d, form(2, false, false, ""));
    let again = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert_eq!(tree_text(&again), "No change since your last look.");
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
    e.call(&ctx(), "screenshot", &json!({"window_id": "1"}));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "x": 400.0, "y": 10.0}));
    assert_eq!(out.code.as_deref(), Some("title_bar"), "{}", out.body);
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "x": 1600.0, "y": 300.0}));
    assert_eq!(out.code.as_deref(), Some("point_outside_window"), "{}", out.body);
    assert!(d.events().is_empty());
    let inside =
        e.call(&ctx(), "click", &json!({"window_id": "1", "x": 60.0, "y": 70.0, "observe": false}));
    assert!(!inside.is_error, "{}", inside.body);
}

#[test]
fn typing_with_focus_on_a_button_goes_through_and_into_a_button_is_refused() {
    let (d, e) = rig();
    set_tree(&d, form(1, false, true, ""));
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    // A web app keeps focus on a button while its own key handler takes the
    // text: untargeted typing is let through, the state tells what landed.
    let out =
        e.call(&ctx(), "type_text", &json!({"window_id": "1", "text": "Ada", "observe": false}));
    assert!(!out.is_error, "{}", out.body);
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
    e.call(&ctx(), "screenshot", &json!({"window_id": "1"}));
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "max_nodes": 2}));
    let walks = *d.walks.lock().unwrap();
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "x": 400.0, "y": 10.0}));
    assert_eq!(out.code.as_deref(), Some("title_bar"), "{}", out.body);
    assert!(*d.walks.lock().unwrap() > walks, "a fresh walk decided it");
}

#[test]
fn with_no_earlier_screenshot_the_pixels_are_unknown_never_changed() {
    let (_d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    // No screenshot of the window before the click: the settle capture has
    // nothing to compare with.
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3"}));
    let text = tree_text(&out);
    assert!(text.contains("whether its pixels changed is unknown"), "{text}");
    assert!(!text.contains("pixels changed (see"), "{text}");
}

#[test]
fn a_look_cut_short_never_says_no_change_for_what_it_did_not_read() {
    let (_d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "max_nodes": 3}));
    let again = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "max_nodes": 3}));
    let text = tree_text(&again);
    assert_eq!(text, "No change in what this look read (it stopped at the element limit).");
}

#[test]
fn a_window_another_process_opens_over_the_target_is_reported() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    *d.opens_on_input.lock().unwrap() = Some(Window {
        id: "9".into(),
        app_id: "com.apple.appkit.xpc.openAndSavePanelService".into(),
        pid: 99,
        title: "Save".into(),
        frame: Rect { x: 200.0, y: 150.0, width: 400.0, height: 300.0 },
        on_screen: true,
        focused: false,
        minimized: false,
    });
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3"}));
    let text = tree_text(&out);
    assert!(
        text.starts_with("+ window 9") && text.contains("opened over it (window_id 9)"),
        "{text}"
    );
}

#[test]
fn walks_of_two_windows_do_not_wait_for_each_other() {
    let (_d, e) = rig();
    let e = Arc::new(e);
    // Hold window 1's walk lock; a walk of window 2 still runs.
    let held = lock(&e.observe.walking).entry("1".into()).or_default().clone();
    let _guard = lock(&held);
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(e.walk_tree("2", TreeOptions::default()).is_ok());
    });
    assert_eq!(rx.recv_timeout(Duration::from_secs(5)), Ok(true));
}

#[test]
fn a_menu_heal_walk_does_not_deepen_the_windows_later_walks() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    // The action's state walk leaves the menus out: their ids are carried.
    e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3", "observe": false}));
    e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3"}));
    // Clicking a menu item heals by walking with the menus...
    e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "7", "observe": false}));
    // ...at the default depth, and later default walks stay there.
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert_eq!(*d.last_max_nodes.lock().unwrap(), TreeOptions::default().max_nodes);
}

#[test]
fn a_menu_bar_listing_shows_the_menu_as_it_is_now() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    // The app adds an item after the look (Open Recent gains a file).
    let mut now = form(2, false, false, "");
    let menu = &mut now.children[2].children[0].children[0];
    menu.children.push(el("2.13", "menu_item", "Recent.txt"));
    set_tree(&d, now);
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "5"}));
    assert!(tree_text(&out).contains("menu item \"Recent.txt\""), "{}", tree_text(&out));
}

#[test]
fn a_look_keeps_the_json_tree_and_truncated_for_direct_callers() {
    let (_d, e) = rig();
    let out = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert_eq!(out.body["truncated"], false);
    assert_eq!(out.body["root"]["children"][1]["name"], "Save");
    // The model reads the outline, not both.
    let mcp = out.to_mcp();
    let head: Value = serde_json::from_str(mcp["content"][0]["text"].as_str().unwrap()).unwrap();
    assert!(head.get("root").is_none() && head["truncated"] == false, "{head}");
    assert!(mcp["content"][1]["text"].as_str().unwrap().starts_with("[1] window"));
}

#[test]
fn every_guard_refusal_says_force_skips_it() {
    let (d, e) = rig();
    set_tree(&d, form(1, true, false, ""));
    e.call(&ctx(), "screenshot", &json!({"window_id": "1"}));
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    for args in [
        json!({"window_id": "1", "element_id": "3"}),
        json!({"window_id": "1", "x": 400.0, "y": 10.0}),
    ] {
        let out = e.call(&ctx(), "click", &args);
        assert!(out.is_error, "{}", out.body);
        assert!(out.body["error"].as_str().unwrap().contains("force: true"), "{}", out.body);
    }
}

#[test]
fn the_last_looks_kept_per_session_are_bounded() {
    let (_d, e) = rig();
    for w in 0..40 {
        e.record_seen("s9", &format!("w{w}"), crate::observe::outline::Outline::default());
    }
    let kept = lock(&e.observe.seen).keys().filter(|(s, _)| s == "s9").count();
    assert!(kept <= 24, "{kept}");
    assert!(lock(&e.observe.seen).contains_key(&("s9".into(), "w39".into())));
}

#[test]
fn an_actions_state_carries_its_evidence_in_a_fixed_shape() {
    let (d, e) = rig();
    e.call(&ctx(), "screenshot", &json!({"window_id": "1"}));
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    set_tree(&d, form(2, false, false, "Ada"));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3"}));
    let c = &out.body["state"]["changes"];
    assert_eq!(c["changed"], 1, "{c}");
    assert_eq!((c["added"].clone(), c["removed"].clone()), (json!(0), json!(0)));
    assert_eq!(c["elements_read"], "all");
    assert!(["changed", "same"].contains(&c["pixels"].as_str().unwrap()), "{c}");
}

#[test]
fn an_id_whose_element_is_not_the_one_shown_is_refused_at_use_time() {
    // The progress bar "Upload" keeps its id (same name, same place), but its
    // value turned from text into a number: not what the agent was shown
    // under the id, so the use-time check refuses it instead of acting.
    let (d, e) = rig();
    let with_bar = |g: u32, value: &str| {
        let mut f = form(g, false, false, "");
        let mut b = framed(el(&format!("{g}.30"), "progress", "Upload"), 400.0, 200.0, 80.0, 22.0);
        b.value = value.into();
        b.actions = vec!["press".into()];
        f.children.push(b);
        identify(&mut f, 1);
        f
    };
    set_tree(&d, with_bar(1, "Waiting"));
    let look = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    let id = tree_text(&look)
        .lines()
        .find(|l| l.contains("progress \"Upload\""))
        .and_then(|l| l.trim().strip_prefix('['))
        .and_then(|l| l.split(']').next())
        .unwrap()
        .to_string();
    set_tree(&d, with_bar(2, "42"));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": id}));
    assert_eq!(out.code.as_deref(), Some("stale_element"), "{}", out.body);
    assert!(
        out.body["error"].as_str().unwrap().contains("not the element you were shown"),
        "{}",
        out.body
    );
    assert!(d.events().is_empty());
}

#[test]
fn an_id_never_shown_by_this_worker_is_refused() {
    let (_d, e) = rig();
    // The window was walked (a guard, a state the agent never saw) but no look
    // showed its ids to this session.
    e.walk_tree("1", TreeOptions::default()).unwrap();
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3"}));
    assert_eq!(out.code.as_deref(), Some("stale_element"), "{}", out.body);
    assert!(out.body["error"].as_str().unwrap().contains("was not shown to you"), "{}", out.body);
}

#[test]
fn a_focus_move_counts_in_the_evidence() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    set_tree(&d, form(2, false, true, ""));
    let look = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert_eq!(look.body["changes"]["changed"], 1, "{}", look.body["changes"]);
    assert_eq!(look.body["changes"]["focus_moved"], true);
}

#[test]
fn a_same_looking_element_swapped_in_under_a_kept_id_is_refused_at_use_time() {
    // The window shows another list whose row has the same name: the row
    // keeps its id by place and name, and its fingerprint reads the same but
    // for the platform's identity, which differs. The click is refused.
    let (d, e) = rig();
    let with_list = |g: u32, list_seed: u64| {
        let mut f = form(g, false, false, "");
        let mut row =
            framed(el(&format!("{g}.41"), "row", "Report.pdf"), 400.0, 300.0, 200.0, 22.0);
        row.actions = vec!["press".into()];
        let mut list = el(&format!("{g}.40"), "list", "Files");
        list.children = vec![row];
        identify(&mut list, list_seed);
        f.children.push(list);
        f
    };
    set_tree(&d, with_list(1, 500));
    let look = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    let id = tree_text(&look)
        .lines()
        .find(|l| l.contains("row \"Report.pdf\""))
        .and_then(|l| l.trim().strip_prefix('['))
        .and_then(|l| l.split(']').next())
        .unwrap()
        .to_string();
    set_tree(&d, with_list(2, 900));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": id}));
    assert_eq!(out.code.as_deref(), Some("stale_element"), "{}", out.body);
    assert!(
        out.body["error"].as_str().unwrap().contains("another element that looks the same"),
        "{}",
        out.body
    );
    assert!(d.events().is_empty());
}

/// The id of the first element of a JSON tree with `role` and `name`.
fn json_id(root: &Value, role: &str, name: &str) -> Option<String> {
    if root["role"] == role && root["name"] == name {
        return root["id"].as_str().map(str::to_string);
    }
    root["children"].as_array()?.iter().find_map(|c| json_id(c, role, name))
}

#[test]
fn a_menu_item_id_read_from_a_look_runs_without_opening_the_menu() {
    // The eval's flow: get_ui_tree (max_nodes 5000), a menu item's id read out
    // of the returned tree, then a click on that id in the same window.
    let (d, e) = rig();
    let look = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "max_nodes": 5000}));
    let id = json_id(&look.body["root"], "menu_item", "Save As…").expect("menu item in the tree");
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": id}));
    assert!(!out.is_error, "{}", out.body);
    let Event::Click { element: Some(platform), .. } = &d.events()[0] else {
        panic!("{:?}", d.events())
    };
    assert!(platform.ends_with(".12"), "{platform}");
}

#[test]
fn a_menu_items_id_from_the_menu_bar_listing_runs() {
    // The docs' flow: get_ui_tree lists the menu bar; click the menu's id
    // (its items, the menu stays closed); click an item's id.
    let (d, e) = rig();
    let look = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    let file = tree_text(&look)
        .lines()
        .find(|l| l.contains("menu bar item \"File\""))
        .and_then(|l| l.trim().strip_prefix('['))
        .and_then(|l| l.split(']').next())
        .unwrap()
        .to_string();
    let listing = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": file}));
    let item = tree_text(&listing)
        .lines()
        .find(|l| l.contains("Save As"))
        .and_then(|l| l.trim().strip_prefix('['))
        .and_then(|l| l.split(']').next())
        .unwrap()
        .to_string();
    // A later walk of the window (an action's state) leaves the menus out.
    set_tree(&d, form(2, false, false, ""));
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": item}));
    assert!(!out.is_error, "{}", out.body);
}

#[test]
fn a_file_name_field_in_a_recycled_row_keeps_its_id_across_walks() {
    // Finder's list: rows of cells holding the file name in a text field (a
    // value, no label), the same views across walks with new desktop ids.
    let (d, e) = rig();
    let finder = |g: u32| {
        let mut f = form(g, false, false, "");
        let rows = ["a.txt", "b.txt"]
            .iter()
            .enumerate()
            .map(|(i, name)| {
                let mut field = framed(
                    el(&format!("{g}.6{i}"), "text_field", ""),
                    420.0,
                    300.0 + 22.0 * i as f64,
                    150.0,
                    20.0,
                );
                field.value = (*name).into();
                let cell =
                    Element { children: vec![field], ..el(&format!("{g}.5{i}"), "cell", "") };
                Element { children: vec![cell], ..el(&format!("{g}.4{i}"), "row", "") }
            })
            .collect();
        f.children.push(Element { children: rows, ..el(&format!("{g}.39"), "outline", "") });
        identify(&mut f, 1);
        f
    };
    set_tree(&d, finder(1));
    let look = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1", "max_nodes": 5000}));
    let mut field = None;
    fn find_field(v: &Value, out: &mut Option<String>) {
        if v["role"] == "text_field" && v["value"] == "a.txt" {
            *out = v["id"].as_str().map(str::to_string);
        }
        v["children"].as_array().into_iter().flatten().for_each(|c| find_field(c, out));
    }
    find_field(&look.body["root"], &mut field);
    set_tree(&d, finder(2));
    let out = e.call(
        &ctx(),
        "click",
        &json!({"window_id": "1", "element_id": field.unwrap(), "observe": false}),
    );
    assert!(!out.is_error, "{}", out.body);
}

#[test]
fn a_pixel_click_with_no_screenshot_of_the_window_is_refused() {
    // After a retry, a restart or a session's end there is no screenshot
    // geometry: a guessed 1 pt/px is twice off on a Retina display.
    let (d, e) = rig();
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "x": 400.0, "y": 300.0}));
    assert_eq!(out.code.as_deref(), Some("no_screenshot"), "{}", out.body);
    let drag = e.call(
        &ctx(),
        "drag",
        &json!({"window_id": "1", "from_x": 10.0, "from_y": 100.0, "to_x": 50.0, "to_y": 100.0}),
    );
    assert_eq!(drag.code.as_deref(), Some("no_screenshot"), "{}", drag.body);
    assert!(d.events().is_empty());
}

#[test]
fn pixels_map_against_where_the_window_is_now_and_a_resize_is_refused() {
    let (d, e) = rig();
    // Window 1: 800x600 pt at (100, 100), 2x: a 1456x1092 screenshot.
    let shot = e.call(&ctx(), "screenshot", &json!({"window_id": "1"}));
    let k = 800.0 / shot.body["width"].as_f64().unwrap();
    // The window moves 50 pt right: the agent's pixel still means the same
    // spot of the window.
    *d.reframed.lock().unwrap() =
        vec![("1".into(), Rect { x: 150.0, y: 100.0, width: 800.0, height: 600.0 })];
    let out = e.call(
        &ctx(),
        "click",
        &json!({"window_id": "1", "x": 200.0, "y": 400.0, "observe": false}),
    );
    assert!(!out.is_error, "{}", out.body);
    let Event::Click { point: Some(p), .. } = &d.events()[0] else { panic!("{:?}", d.events()) };
    assert!(
        (p.x - (150.0 + 200.0 * k)).abs() < 1e-6 && (p.y - (100.0 + 400.0 * k)).abs() < 1e-6,
        "{p:?}"
    );
    // Resized: the pixels no longer say where.
    *d.reframed.lock().unwrap() =
        vec![("1".into(), Rect { x: 150.0, y: 100.0, width: 640.0, height: 600.0 })];
    let out = e.call(&ctx(), "click", &json!({"window_id": "1", "x": 200.0, "y": 400.0}));
    assert_eq!(out.code.as_deref(), Some("window_resized"), "{}", out.body);
}

#[test]
fn the_shown_map_keeps_only_live_ids_and_ends_with_the_session() {
    let (d, e) = rig();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    // Save goes away for good: its fingerprint is dropped at the next look.
    let mut gone = form(2, false, false, "");
    gone.children.remove(1);
    set_tree(&d, gone);
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    let kept: Vec<u32> = lock(&e.observe.shown)
        .get(&("s1".to_string(), "1".to_string()))
        .map(|(_, m)| m.keys().copied().collect())
        .unwrap();
    assert!(!kept.contains(&3), "{kept:?}");
    e.end_session("s1");
    assert!(lock(&e.observe.shown).keys().all(|(s, _)| s != "s1"));
}

#[test]
fn a_look_with_nothing_to_compare_or_nothing_changed_costs_one_sentence() {
    let (d, e) = rig();
    // The first look: the outline, and no evidence (there is no action to judge).
    let first = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert!(first.body.get("changes").is_none(), "{}", first.body);
    // Nothing changed: the MCP result is the window id, truncated and one sentence.
    set_tree(&d, form(2, false, false, ""));
    let again = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"})).to_mcp();
    let texts: Vec<&str> =
        again["content"].as_array().unwrap().iter().map(|c| c["text"].as_str().unwrap()).collect();
    assert_eq!(
        texts,
        ["{\"truncated\":false,\"window_id\":\"1\"}", "No change since your last look."]
    );
    // An action still carries the evidence its outcome is decided from.
    let click = e.call(&ctx(), "click", &json!({"window_id": "1", "element_id": "3"}));
    let c = &click.body["state"]["changes"];
    assert_eq!(c["elements_read"], "all", "{}", click.body);
    assert_eq!(c["added"], 0);
    assert!(click.body["outcome"].is_string(), "{}", click.body);
}

#[test]
fn a_web_view_that_fills_on_its_first_read_is_in_the_first_look() {
    // The first read of the window finds the page empty (WebKit builds its
    // accessibility when asked); the next has it.
    let (d, e) = rig();
    let mut empty = form(1, false, false, "");
    empty.children.retain(|c| c.role != "button" && c.role != "text_field");
    *d.first_walk.lock().unwrap() = Some(empty);
    let first = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    let text = tree_text(&first);
    assert!(text.contains("button \"Save\"") && text.contains("text field \"Name\""), "{text}");
    // So the next look has nothing new to report.
    let again = e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert_eq!(tree_text(&again), "No change since your last look.");
    // A window walked before is walked once per look.
    let walks = *d.walks.lock().unwrap();
    e.call(&ctx(), "get_ui_tree", &json!({"window_id": "1"}));
    assert_eq!(*d.walks.lock().unwrap(), walks + 1);
}
