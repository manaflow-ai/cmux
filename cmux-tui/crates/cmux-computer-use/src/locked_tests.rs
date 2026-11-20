use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::desktop::fake::{Event, FakeDesktop};
use crate::engine::{CallContext, Engine, EngineParts, Origin, ToolOutput};
use crate::policy::PolicyConfig;

/// Every tool the engine serves, with arguments that pick each of its kinds.
fn table() -> Vec<(&'static str, Value, Kind)> {
    vec![
        ("status", json!({}), Kind::Engine),
        ("list_machines", json!({}), Kind::Engine),
        ("list_apps", json!({}), Kind::Inventory),
        ("list_windows", json!({}), Kind::Inventory),
        ("screenshot", json!({"window_id": "1"}), Kind::WindowLook),
        ("screenshot", json!({}), Kind::Display),
        ("screenshot", json!({"display": "1"}), Kind::Display),
        ("wait", json!({"window_id": "1"}), Kind::WindowLook),
        ("wait", json!({}), Kind::Display),
        ("get_ui_tree", json!({"window_id": "1"}), Kind::WindowLook),
        ("click", json!({"window_id": "1"}), Kind::WindowInput),
        ("click", json!({"window_id": "1", "delivery": "background"}), Kind::WindowInput),
        ("click", json!({"window_id": "1", "delivery": "foreground"}), Kind::Hid),
        ("type_text", json!({"window_id": "1"}), Kind::WindowInput),
        ("type_text", json!({"window_id": "1", "delivery": "foreground"}), Kind::Hid),
        ("press_key", json!({"window_id": "1"}), Kind::WindowInput),
        ("press_key", json!({"window_id": "1", "delivery": "foreground"}), Kind::Hid),
        ("drag", json!({"window_id": "1"}), Kind::WindowInput),
        ("drag", json!({"window_id": "1", "delivery": "foreground"}), Kind::Hid),
        // An unknown delivery is not taken for background.
        ("click", json!({"window_id": "1", "delivery": "sideways"}), Kind::Hid),
        ("scroll", json!({"window_id": "1"}), Kind::WindowInput),
        ("set_value", json!({"window_id": "1"}), Kind::WindowInput),
        ("perform_action", json!({"window_id": "1"}), Kind::WindowInput),
        ("batch", json!({"window_id": "1"}), Kind::WindowInput),
        ("launch_app", json!({"app_id": "com.apple.TextEdit"}), Kind::Activates),
        ("request_permission", json!({"permission": "accessibility"}), Kind::Activates),
        ("some_new_tool", json!({}), Kind::Activates),
    ]
}

#[test]
fn every_tool_has_a_kind() {
    let named: Vec<&str> = table().iter().map(|(t, _, _)| *t).collect();
    for tool in crate::tools::TOOLS {
        assert!(named.contains(&tool.name), "{} is not in the locked table", tool.name);
    }
    for (tool, args, kind) in table() {
        assert_eq!(kind_of(tool, &args), kind, "{tool} {args}");
    }
}

#[test]
fn gating_table_locked_by_setting() {
    // (kind, admitted with whileLocked off, admitted with it on)
    let expected = [
        (Kind::Engine, true, true),
        (Kind::Inventory, false, true),
        (Kind::WindowLook, false, true),
        (Kind::WindowInput, false, true),
        (Kind::Hid, false, false),
        (Kind::Display, false, false),
        (Kind::Activates, false, false),
    ];
    for (kind, off, on) in expected {
        assert_eq!(admits(kind, false), off, "{kind:?} off");
        assert_eq!(admits(kind, true), on, "{kind:?} on");
    }
}

fn ctx() -> CallContext {
    CallContext {
        session: "s1".into(),
        label: "Claude".into(),
        call_id: None,
        origin: Origin::Local,
        tag: None,
    }
}

fn engine(locked: bool, while_locked: bool) -> (Arc<FakeDesktop>, Engine) {
    let d = Arc::new(FakeDesktop::standard());
    *d.locked.lock().unwrap() = locked;
    let mut parts = EngineParts::new(d.clone());
    parts.config = PolicyConfig { while_locked, allow_foreground: true, ..PolicyConfig::default() };
    parts.sleep = Arc::new(|_| {});
    (d, Engine::new(parts))
}

fn is_locked(out: &ToolOutput) -> bool {
    out.is_error && out.code.as_deref() == Some(CODE)
}

/// Calls that reach the desktop, one of each kind.
fn calls() -> Vec<(&'static str, Value, Kind)> {
    vec![
        ("status", json!({}), Kind::Engine),
        ("list_apps", json!({}), Kind::Inventory),
        ("list_windows", json!({}), Kind::Inventory),
        ("screenshot", json!({"window_id": "1"}), Kind::WindowLook),
        ("get_ui_tree", json!({"window_id": "1"}), Kind::WindowLook),
        ("screenshot", json!({}), Kind::Display),
        ("wait", json!({"ms": 0}), Kind::Display),
        ("type_text", json!({"window_id": "1", "text": "hunter2"}), Kind::WindowInput),
        ("press_key", json!({"window_id": "1", "keys": "return"}), Kind::WindowInput),
        (
            "type_text",
            json!({"window_id": "1", "text": "hunter2", "delivery": "foreground"}),
            Kind::Hid,
        ),
        (
            "click",
            json!({"window_id": "1", "x": 10.0, "y": 300.0, "delivery": "foreground"}),
            Kind::Hid,
        ),
        (
            "press_key",
            json!({"window_id": "1", "keys": "return", "delivery": "foreground"}),
            Kind::Hid,
        ),
        ("launch_app", json!({"app_id": "com.apple.TextEdit"}), Kind::Activates),
        (
            "batch",
            json!({"window_id": "1", "actions": [{"action": "type_text", "text": "a"}]}),
            Kind::WindowInput,
        ),
    ]
}

#[test]
fn engine_gate_locked_unlocked_by_setting() {
    for locked in [false, true] {
        for while_locked in [false, true] {
            for (tool, args, kind) in calls() {
                let (d, e) = engine(locked, while_locked);
                let out = e.call(&ctx(), tool, &args);
                let refused = is_locked(&out);
                let want = locked && !admits(kind, while_locked);
                assert_eq!(
                    refused, want,
                    "locked={locked} whileLocked={while_locked} {tool} {args}: {:?}",
                    out.body
                );
                if refused {
                    // Refused before anything reached the desktop.
                    assert!(d.events().is_empty(), "{tool}: {:?}", d.events());
                    assert_eq!(*d.captures.lock().unwrap(), 0, "{tool} captured");
                    let detail = &out.body["whileLocked"];
                    assert_eq!(detail["setting"], SETTING);
                    assert_eq!(detail["value"], if while_locked { "on" } else { "off" });
                    assert_eq!(detail["kind"], kind.as_str());
                }
            }
        }
    }
}

#[test]
fn opt_in_background_typing_reaches_the_window_while_locked() {
    let (d, e) = engine(true, true);
    let out = e.call(&ctx(), "type_text", &json!({"window_id": "1", "text": "hi"}));
    assert!(!out.is_error, "{:?}", out.body);
    assert!(
        d.events().iter().any(|ev| matches!(ev, Event::Type { text, .. } if text == "hi")),
        "{:?}",
        d.events()
    );
}

#[test]
fn a_batch_step_is_checked_on_its_own() {
    let (d, e) = engine(true, true);
    let out = e.call(
        &ctx(),
        "batch",
        &json!({"window_id": "1", "actions": [
            {"action": "type_text", "text": "a"},
            {"action": "press_key", "keys": "return", "delivery": "foreground"},
        ]}),
    );
    // The foreground step is refused; nothing of it was posted.
    let text = out.body.to_string();
    assert!(text.contains(CODE), "{text}");
    assert!(!d.events().iter().any(|ev| matches!(ev, Event::Keys { .. })), "{:?}", d.events());
}

#[test]
fn status_reports_the_lock() {
    let (_, e) = engine(true, false);
    let out = e.call(&ctx(), "status", &json!({}));
    assert!(!out.is_error);
    assert_eq!(out.body["screen_locked"], true);
    assert_eq!(out.body["while_locked"], false);
}

#[test]
fn the_setting_is_off_by_default_and_reads_camel_case() {
    assert!(!PolicyConfig::default().while_locked);
    assert!(!PolicyConfig::cloud_vm().while_locked);
    let c: PolicyConfig = serde_json::from_value(json!({"whileLocked": true})).unwrap();
    assert!(c.while_locked);
}
