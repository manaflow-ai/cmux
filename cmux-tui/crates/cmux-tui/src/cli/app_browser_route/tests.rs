use super::*;
use crate::cli::command::ResponseView;

fn plan(operation: ResourceOperation, params: Value) -> RequestPlan {
    RequestPlan {
        operation: WireOperation::Typed(operation),
        params,
        idempotency_key: Some("k".into()),
        stream: false,
        resolve: Vec::new(),
        view: ResponseView::Full,
        filter: Default::default(),
    }
}

#[test]
fn a_plain_key_press_maps_to_the_apps_press_and_other_keys_to_its_key() {
    let press = plan(ResourceOperation::BrowserInputKey, json!({"key": "Enter"}));
    assert_eq!(app_call(&press, "tab_x").map(|call| call.0), Some("browser.page.press"));
    let down = plan(ResourceOperation::BrowserInputKey, json!({"key": "a", "kind": "down"}));
    let (method, params) = app_call(&down, "tab_x").expect("a key down runs on the app");
    assert_eq!(method, "browser.page.key");
    assert_eq!(params, json!({"tab": "tab_x", "key": "a", "kind": "down", "modifiers": []}));
    let chord =
        plan(ResourceOperation::BrowserInputKey, json!({"key": "a", "modifiers": ["meta"]}));
    let (method, params) = app_call(&chord, "tab_x").expect("a chord runs on the app");
    assert_eq!(method, "browser.page.key");
    assert_eq!(params, json!({"tab": "tab_x", "key": "a", "kind": "press", "modifiers": ["meta"]}));
}

#[test]
fn mouse_wheel_and_text_map_to_the_apps_raw_input() {
    let mouse = plan(
        ResourceOperation::BrowserInputMouse,
        json!({"kind": "down", "x_px": 10.5, "y_px": 20.0, "pointer_frame_seq": "4",
                "button": "right", "click_count": 2}),
    );
    assert_eq!(
        app_call(&mouse, "tab_x"),
        Some((
            "browser.page.mouse",
            json!({"tab": "tab_x", "kind": "down", "x": 10.5,
                "y": 20.0, "button": "right", "click_count": 2})
        ))
    );
    let moved = plan(
        ResourceOperation::BrowserInputMouse,
        json!({"kind": "move", "x_px": 1.0, "y_px": 2.0, "pointer_frame_seq": "4"}),
    );
    assert_eq!(
        app_call(&moved, "tab_x"),
        Some(("browser.page.mouse", json!({"tab": "tab_x", "kind": "move", "x": 1.0, "y": 2.0})))
    );
    let wheel = plan(
        ResourceOperation::BrowserInputWheel,
        json!({"delta_x": 0.0, "delta_y": 120.0, "x_px": 5.0, "y_px": 6.0, "pointer_frame_seq": "4"}),
    );
    assert_eq!(
        app_call(&wheel, "tab_x"),
        Some((
            "browser.page.wheel",
            json!({"tab": "tab_x", "x": 5.0, "y": 6.0, "dx": 0.0,
                "dy": 120.0})
        ))
    );
    let text = plan(ResourceOperation::BrowserInputText, json!({"text": "hi"}));
    assert_eq!(
        app_call(&text, "tab_x"),
        Some(("browser.page.insert_text", json!({"tab": "tab_x", "text": "hi"})))
    );
}

#[test]
fn only_the_daemons_app_drawn_refusal_names_a_tab() {
    let refusal = json!({"code": "operation.failed", "details": {"extra": {
            "code": CODE, "tab_id": "tab_x"}}});
    assert_eq!(refused_tab(&refusal), Some("tab_x"));
    let starting =
        json!({"code": "operation.failed", "details": {"extra": {"status": "starting"}}});
    assert_eq!(refused_tab(&starting), None);
}
