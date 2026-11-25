//! The JSON ops the app calls through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops `browser_rules_*`). Every op is pure. Requests and replies are
//! in the shape Swift's synthesized `Codable` gives the app's types ([`crate::links`]).
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `browser_rules_link_gesture` | `{command, shift, option, button}` | the [`Gesture`] |
//! | `browser_rules_link_action` | `{mapping, gesture}` | the [`LinkAction`](crate::links::LinkAction) |
//! | `browser_rules_webkit_link_click` | `{command, shift, option, button, mapping}` | [`WebKitLinkClick`] |
//! | `browser_rules_cef_link_placement` | `{disposition, userGesture, click, now, mapping}` | [`LinkPlacement`] |
//! | `browser_rules_window_placement` | `{request, links}` | [`LinkPlacement`] |
//! | `browser_rules_window_decide` | `{request, candidates, links}` | [`WindowDecision`] |

use crate::links::{
    self, CefDisposition, ClickMapping, ClickRecord, Gesture, LinkContext, LinkPlacement,
    Modifiers, WebKitLinkClick, WindowCandidate, WindowDecision, WindowRequest,
};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

/// Why an op failed.
#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of the table's.
    UnknownOp(String),
    /// The request is not the JSON the op takes.
    Invalid(String),
}

#[derive(Deserialize)]
struct GestureRequest {
    #[serde(flatten)]
    modifiers: Modifiers,
    #[serde(default)]
    button: i64,
}

#[derive(Deserialize)]
struct WebKitClickRequest {
    #[serde(flatten)]
    modifiers: Modifiers,
    #[serde(default)]
    button: i64,
    #[serde(default)]
    mapping: ClickMapping,
}

#[derive(Deserialize)]
struct ActionRequest {
    #[serde(default)]
    mapping: ClickMapping,
    gesture: Gesture,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CefPlacementRequest {
    disposition: CefDisposition,
    #[serde(default)]
    user_gesture: bool,
    #[serde(default)]
    click: Option<ClickRecord>,
    #[serde(default)]
    now: f64,
    #[serde(default)]
    mapping: ClickMapping,
}

#[derive(Deserialize)]
struct WindowOpRequest {
    request: WindowRequest,
    #[serde(default)]
    candidates: Vec<WindowCandidate>,
    #[serde(default)]
    links: LinkContext,
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn encode<T: serde::Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

/// True for the ops [`call`] answers.
pub fn serves(op: &str) -> bool {
    op.starts_with("browser_rules_")
}

/// Runs `op` on `request` (a JSON object; null means `{}`).
pub fn call(op: &str, request: Value) -> Result<Value, OpError> {
    let request = if request.is_null() { json!({}) } else { request };
    match op {
        "browser_rules_link_gesture" => {
            let GestureRequest { modifiers, button } = parse(request)?;
            Ok(encode(&Gesture::of(modifiers, button)))
        }
        "browser_rules_link_action" => {
            let ActionRequest { mapping, gesture } = parse(request)?;
            Ok(encode(&mapping.action(gesture)))
        }
        "browser_rules_webkit_link_click" => {
            let WebKitClickRequest { modifiers, button, mapping } = parse(request)?;
            let click: WebKitLinkClick = links::webkit_link_click(modifiers, button, &mapping);
            Ok(encode(&click))
        }
        "browser_rules_cef_link_placement" => {
            let CefPlacementRequest { disposition, user_gesture, click, now, mapping } =
                parse(request)?;
            let placement: LinkPlacement =
                links::cef_placement(disposition, user_gesture, click, now, &mapping);
            Ok(encode(&placement))
        }
        "browser_rules_window_placement" => {
            let WindowOpRequest { request, links, .. } = parse(request)?;
            Ok(encode(&links::window_placement(&request, &links)))
        }
        "browser_rules_window_decide" => {
            let WindowOpRequest { request, candidates, links } = parse(request)?;
            let decision: WindowDecision = links::decide_window(&request, &candidates, &links);
            Ok(encode(&decision))
        }
        other => Err(OpError::UnknownOp(other.to_owned())),
    }
}
