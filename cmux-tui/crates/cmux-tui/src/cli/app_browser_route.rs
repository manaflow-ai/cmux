//! Browser effects on a browser the cmux app draws itself.
//!
//! A WebKit or CEF tab of the app has no daemon CDP session, so the daemon
//! refuses `browser.navigate`, `browser.back` and the other browser effects
//! for it with `extra.code` `browser_rendered_by_app` and the page's
//! `extra.tab_id` (`resource_router/content.rs`). The daemon cannot call the
//! app (the app is one of its clients), so the caller routes: when an app owns
//! the session, the CLI and MCP run the verb through the app's own
//! `browser.page.*` method for that tab, the path `cmux browser tab_… <verb>`
//! takes. The daemon refused before it recorded anything, so nothing runs
//! twice.
//!
//! Raw input runs as the app's page-level input: `browser.input.mouse` as
//! `browser.page.mouse`, `.wheel` as `browser.page.wheel`, `.text` as
//! `browser.page.insert_text`, and a key `down`, `up` or chord as
//! `browser.page.key` (a plain press keeps `browser.page.press`). Their
//! `x_px`/`y_px` are viewport CSS pixels of the page; `pointer_frame_seq`
//! names a daemon frame, so the app ignores it. When no app owns the
//! session, the daemon's refusal stands and the CLI's message names the
//! `cmux browser tab_…` verbs.

use std::path::Path;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::GlobalArgs;
use super::command::{RequestPlan, WireOperation};

/// The `extra.code` of the daemon's refusal.
pub(super) const CODE: &str = "browser_rendered_by_app";

/// The tab of an app-drawn browser the daemon refused to drive, if `error`
/// is that refusal.
pub(super) fn refused_tab(error: &Value) -> Option<&str> {
    let extra = &error["details"]["extra"];
    (error["code"] == "operation.failed" && extra["code"] == CODE)
        .then(|| extra["tab_id"].as_str())
        .flatten()
}

/// The app method and params that run `plan` on `tab`, or `None` when the
/// app has no method for it.
pub(super) fn app_call(plan: &RequestPlan, tab: &str) -> Option<(&'static str, Value)> {
    let WireOperation::Typed(operation) = &plan.operation else { return None };
    let params = plan.params.as_object()?;
    let mut call = Map::new();
    call.insert("tab".into(), json!(tab));
    let method = match operation {
        ResourceOperation::BrowserNavigate => {
            call.insert("url".into(), params.get("url")?.clone());
            "browser.page.navigate"
        }
        ResourceOperation::BrowserBack => "browser.page.back",
        ResourceOperation::BrowserForward => "browser.page.forward",
        ResourceOperation::BrowserReload => "browser.page.reload",
        ResourceOperation::BrowserActivate => {
            if let Some(key) = &plan.idempotency_key {
                call.insert("idempotency_key".into(), json!(key));
            }
            "browser.page.select_tab"
        }
        // A plain press keeps the app's press (keydown, keypress and keyup on
        // the focused element, with Space and Enter defaults); a down, an up
        // or a chord runs as the app's key.
        ResourceOperation::BrowserInputKey => {
            let kind = params.get("kind").and_then(Value::as_str).unwrap_or("press");
            let modifiers = params.get("modifiers").cloned().unwrap_or_else(|| json!([]));
            call.insert("key".into(), params.get("key")?.clone());
            if kind == "press" && modifiers.as_array().is_none_or(Vec::is_empty) {
                "browser.page.press"
            } else {
                call.insert("kind".into(), json!(kind));
                call.insert("modifiers".into(), modifiers);
                "browser.page.key"
            }
        }
        ResourceOperation::BrowserInputMouse => {
            call.insert("kind".into(), params.get("kind")?.clone());
            call.insert("x".into(), params.get("x_px")?.clone());
            call.insert("y".into(), params.get("y_px")?.clone());
            for key in ["button", "click_count"] {
                if let Some(value) = params.get(key) {
                    call.insert(key.into(), value.clone());
                }
            }
            "browser.page.mouse"
        }
        ResourceOperation::BrowserInputWheel => {
            call.insert("x".into(), params.get("x_px")?.clone());
            call.insert("y".into(), params.get("y_px")?.clone());
            call.insert("dx".into(), params.get("delta_x")?.clone());
            call.insert("dy".into(), params.get("delta_y")?.clone());
            "browser.page.wheel"
        }
        ResourceOperation::BrowserInputText => {
            call.insert("text".into(), params.get("text")?.clone());
            "browser.page.insert_text"
        }
        _ => return None,
    };
    Some((method, Value::Object(call)))
}

/// Runs a refused browser effect through the app that owns the session at
/// `daemon_socket`: `Some(Ok)` with a result shaped like the daemon's
/// (`{value, replayed}`), `Some(Err)` with the app's refusal as a resource
/// error, or `None` when `error` is not that refusal, the app has no method
/// for the verb, or no app owns the session (the daemon's error stands).
pub(super) fn run(
    global: &GlobalArgs,
    plan: &RequestPlan,
    error: &Value,
    daemon_socket: &Path,
) -> Option<Result<Value, Value>> {
    let tab = refused_tab(error)?;
    let (method, params) = app_call(plan, tab)?;
    let mut app = super::frontend_browser::owning_app(global, daemon_socket)?;
    let timeout = super::app::WAITING_RUN_TIMEOUT;
    Some(match super::app::request_with_retry(&mut app, method, &params, timeout) {
        Ok(Ok(value)) => Ok(json!({"value": value, "replayed": false})),
        Ok(Err(refusal)) => Err(json!({
            "code": refusal.get("code").cloned().unwrap_or_else(|| json!("operation.failed")),
            "message": refusal.get("message").cloned().unwrap_or_else(|| json!(method)),
            "details": refusal.get("data").cloned().unwrap_or_else(|| json!({})),
            "retryable": false,
        })),
        Err(transport) => Err(json!({
            "code": "app.unreachable",
            "message": transport,
            "details": {"method": method},
            "retryable": true,
        })),
    })
}

#[cfg(test)]
mod tests {
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
        assert_eq!(
            params,
            json!({"tab": "tab_x", "key": "a", "kind": "press", "modifiers": ["meta"]})
        );
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
            Some((
                "browser.page.mouse",
                json!({"tab": "tab_x", "kind": "move", "x": 1.0, "y": 2.0})
            ))
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
}
