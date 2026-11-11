//! Menus through the fake desktop: the setting decides, items match by
//! title, a missing item cancels with the list, the focus guard reports the
//! menu's owner, and the deny list holds inside menus.

use std::sync::atomic::{AtomicU64, Ordering};

use super::*;
use crate::desktop::FocusSnapshot;
use crate::desktop::fake::{Event, FakeDesktop, FakePopup};
use crate::menus::MenuMode;

/// A detector that watches and never sees the person.
struct Quiet;
impl PersonActivity for Quiet {
    fn wait_idle(&self, _limit: Duration) -> bool {
        true
    }
    fn input_count(&self) -> Option<u64> {
        Some(0)
    }
}

fn person() -> FocusSnapshot {
    FocusSnapshot {
        pid: 30,
        app_id: "com.apple.TextEdit".into(),
        window_id: Some("30".into()),
        top_pid: Some(30),
        pointer: None,
    }
}

fn ctx(call: &str) -> CallContext {
    CallContext {
        session: "s1".into(),
        label: "Claude".into(),
        call_id: Some(call.into()),
        origin: OriginKind::Local,
    }
}

/// Safari's window 1 holds pop-up "p1" (Show previews), set to "When Unlocked".
fn rig(menus: MenuMode) -> (Arc<FakeDesktop>, Engine) {
    let d = FakeDesktop::standard();
    *d.popups.lock().unwrap() = vec![FakePopup {
        window: "1".into(),
        element: "p1".into(),
        items: ["Always", "When Unlocked", "Never", "Open in Terminal"].map(String::from).to_vec(),
        value: "When Unlocked".into(),
        open: false,
    }];
    *d.focus.lock().unwrap() = Some(person());
    let d = Arc::new(d);
    let mut parts = EngineParts::new(d.clone());
    let now = Arc::new(AtomicU64::new(0));
    let (a, b) = (now.clone(), now);
    parts.sleep = Arc::new(move |t| {
        a.fetch_add(t.as_millis() as u64, Ordering::SeqCst);
    });
    parts.clock = Arc::new(move || Duration::from_millis(b.load(Ordering::SeqCst)));
    parts.takeover = Arc::new(Quiet);
    parts.config = PolicyConfig { menus, ..PolicyConfig::default() };
    (d, Engine::new(parts))
}

fn set_value(e: &Engine, call: &str, value: &str) -> ToolOutput {
    e.call(&ctx(call), "set_value", &json!({"window_id": "1", "element_id": "p1", "value": value}))
}

#[test]
fn open_picks_the_item_and_closes_the_menu_in_one_call() {
    let (d, e) = rig(MenuMode::Open);
    let out = set_value(&e, "v1", "always");
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["evidence"], "confirmed");
    assert_eq!(out.body["menu"]["state"], "picked");
    assert_eq!(out.body["menu"]["picked"], "Always");
    assert!(out.body["menu"]["open_ms"].is_u64());
    let p = &d.popups()[0];
    assert_eq!((p.value.as_str(), p.open), ("Always", false));
    assert_eq!(out.body["focus"], json!({"kept": true}));
}

#[test]
fn a_unique_prefix_picks_and_an_ambiguous_one_lists_the_matches() {
    let (d, e) = rig(MenuMode::Open);
    assert_eq!(set_value(&e, "v1", "Nev").body["menu"]["picked"], "Never");
    assert_eq!(d.popups()[0].value, "Never");
    d.popups.lock().unwrap()[0].items.push("Never Again".into());
    let out = set_value(&e, "v2", "Nev");
    assert!(out.is_error);
    let msg = out.body["error"].as_str().unwrap();
    assert!(msg.contains("Never, Never Again"), "{msg}");
}

#[test]
fn a_missing_item_cancels_the_menu_and_names_the_items() {
    let (d, e) = rig(MenuMode::Open);
    let out = set_value(&e, "v1", "Sometimes");
    assert!(out.is_error);
    assert_eq!(out.code.as_deref(), Some("unsupported"));
    let msg = out.body["error"].as_str().unwrap();
    assert!(msg.contains("Always, When Unlocked, Never"), "{msg}");
    // The denied item is not listed.
    assert!(!msg.contains("Terminal"), "{msg}");
    let p = &d.popups()[0];
    assert_eq!((p.value.as_str(), p.open), ("When Unlocked", false));
    assert!(d.events().is_empty());
}

#[test]
fn refuse_keeps_every_menu_closed() {
    let (d, e) = rig(MenuMode::Refuse);
    let out = set_value(&e, "v1", "Always");
    assert!(out.is_error);
    assert!(out.body["error"].as_str().unwrap().contains("computerUse.menus"));
    let out = e.call(&ctx("c1"), "click", &json!({"window_id": "1", "element_id": "p1"}));
    assert!(out.is_error);
    let out = e.call(
        &ctx("a1"),
        "perform_action",
        &json!({"window_id": "1", "element_id": "p1", "action": "press"}),
    );
    assert!(out.is_error);
    let out = e.call(
        &ctx("r1"),
        "click",
        &json!({"window_id": "1", "element_id": "e1", "button": "right"}),
    );
    assert!(out.is_error, "{:?}", out.body);
    assert!(d.events().is_empty());
    assert_eq!(d.popups()[0].value, "When Unlocked");
    assert_eq!(e.call(&ctx("s"), "status", &json!({})).body["menus"], "refuse");
}

#[test]
fn a_click_opens_the_menu_and_lists_its_items_for_the_next_call() {
    let (d, e) = rig(MenuMode::Open);
    let out = e.call(&ctx("c1"), "click", &json!({"window_id": "1", "element_id": "p1"}));
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["menu"]["state"], "open");
    let titles: Vec<&str> = out.body["menu"]["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["title"].as_str().unwrap())
        .collect();
    assert_eq!(titles, ["Always", "When Unlocked", "Never"]);
    assert_eq!(out.body["menu"]["hidden"], 1);
    assert!(d.popups()[0].open);
    // The state's tree shows the open menu, without the denied item.
    let tree = out.body["state"]["root"].to_string();
    assert!(tree.contains("When Unlocked") && !tree.contains("Open in Terminal"), "{tree}");
    let tree = e.call(&ctx("t1"), "get_ui_tree", &json!({"window_id": "1"}));
    assert!(!tree.body["root"].to_string().contains("Terminal"));
}

#[test]
fn an_item_leading_to_a_denied_app_is_refused() {
    let (d, e) = rig(MenuMode::Open);
    let out = set_value(&e, "v1", "Open in Terminal");
    assert!(out.is_error);
    let msg = out.body["error"].as_str().unwrap();
    assert!(msg.contains("Terminal") && msg.contains("deny list"), "{msg}");
    assert_eq!(d.popups()[0].value, "When Unlocked");
    // With Terminal off the deny list, the same item is fine.
    let mut config = e.config();
    config.denied_apps.retain(|a| a != "com.apple.Terminal");
    e.set_config(config);
    assert!(!set_value(&e, "v2", "Open in Terminal").is_error);
}

#[test]
fn the_focus_guard_puts_the_persons_app_back_after_the_pick() {
    let (d, e) = rig(MenuMode::Open);
    // Picking the item activates the target app (as a menu's owner can).
    *d.steal_on_input.lock().unwrap() = Some(FocusSnapshot {
        pid: 10,
        app_id: "com.apple.Safari".into(),
        window_id: Some("1".into()),
        top_pid: Some(10),
        pointer: None,
    });
    let out = set_value(&e, "v1", "Never");
    assert!(!out.is_error, "{:?}", out.body);
    assert_eq!(out.body["focus"], json!({"kept": true, "restored_from": "com.apple.Safari"}));
    assert_eq!(d.restores(), vec![person()]);
}

#[test]
fn the_desktop_gets_the_policy_before_each_acting_call() {
    let (d, e) = rig(MenuMode::Open);
    assert!(d.menu_policy.lock().unwrap().is_none());
    e.call(&ctx("c1"), "click", &json!({"window_id": "1", "element_id": "e1"}));
    let policy = d.menu_policy.lock().unwrap().clone().unwrap();
    assert_eq!(policy.mode, MenuMode::Open);
    assert!(policy.denied_names.iter().any(|n| n == "Terminal"));
    // 1Password is running and denied: its name is in the list too.
    assert!(policy.denied_names.iter().any(|n| n == "1Password"));
    e.set_config(PolicyConfig { menus: MenuMode::Refuse, ..PolicyConfig::default() });
    e.call(&ctx("c2"), "click", &json!({"window_id": "1", "element_id": "e1"}));
    assert_eq!(d.menu_policy.lock().unwrap().clone().unwrap().mode, MenuMode::Refuse);
    assert!(matches!(d.events()[0], Event::Click { .. }));
}
