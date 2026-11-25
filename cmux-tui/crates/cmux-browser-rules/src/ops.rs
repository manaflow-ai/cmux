//! The JSON ops the app calls through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops `browser_rules_*`). Every op is pure. Requests and replies are
//! in the shape Swift's synthesized `Codable` gives the app's types ([`crate::links`]).
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `browser_rules_is_top_level_domain` | `{label}` or `{labels}` | a bool, or one per label |
//! | `browser_rules_host_typo_fix` | `{text}` | [`TypoFix`](crate::address::TypoFix) `{text, typedHost}`, or null |
//! | `browser_rules_https_upgrade_falls_back` | `{domain, code}` | a bool |
//! | `browser_rules_calculator_answer` | `{text}` | the answer text, or null when `text` is not arithmetic |
//! | `browser_rules_link_gesture` | `{command, shift, option, button}` | the [`Gesture`] |
//! | `browser_rules_link_action` | `{mapping, gesture}` | the [`LinkAction`](crate::links::LinkAction) |
//! | `browser_rules_webkit_link_click` | `{command, shift, option, button, mapping}` | [`WebKitLinkClick`] |
//! | `browser_rules_cef_link_placement` | `{disposition, userGesture, click, now, mapping}` | [`LinkPlacement`] |
//! | `browser_rules_window_placement` | `{request, links}` | [`LinkPlacement`] |
//! | `browser_rules_window_decide` | `{request, candidates, links}` | [`WindowDecision`] |
//! | `browser_rules_omnibar_display_text` | `{url?, home}` | the compact address text |
//! | `browser_rules_omnibar_resting_text` | `{url?, home}` | the host-only resting text |
//! | `browser_rules_omnibar_editing_text` | `{url?}` | the full address to edit |
//! | `browser_rules_omnibar_host_range` | `{text, url?}` | a [`Range`] (`NSRange`), or null |
//! | `browser_rules_omnibar_tilde_path` | `{path, home}` | the path with the home folder as `~` |
//! | `browser_rules_omnibar_fill_text` | `{row}` | the text an arrowed row puts in the field |
//! | `browser_rules_omnibar_inline_completion` | `{row, typed, home}` | the completing suffix, or null |
//! | `browser_rules_omnibar_desired_tld_url` | `{typed, home, allowsChromiumSchemes}` | the Control-Enter URL, or null |
//! | `browser_rules_omnibar_is_https_upgrade` | `{text, url, home, allowsChromiumSchemes}` | a bool |
//! | `browser_rules_omnibar_single_line` | `{text}` | the text on one line |
//! | `browser_rules_omnibar_dropped_text` | `{text}` | the dropped text, cleaned |
//! | `browser_rules_omnibar_clamped` | `{selection, length}` | the selection [`Range`] within `length` UTF-16 units |
//! | `browser_rules_omnibar_utf16_length` | `{text}` | the length in UTF-16 units |

use crate::links::{
    self, CefDisposition, ClickMapping, ClickRecord, Gesture, LinkContext, LinkPlacement,
    Modifiers, WebKitLinkClick, WindowCandidate, WindowDecision, WindowRequest,
};
use crate::omnibar::{self, Range, Suggestion};
use crate::{address, calculator};
use cmux_url_input::TypedInput;
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
struct TldRequest {
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    labels: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct TextRequest {
    text: String,
}

#[derive(Deserialize)]
struct LoadErrorRequest {
    domain: String,
    code: i64,
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

#[derive(Deserialize)]
struct UrlRequest {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    home: String,
}

#[derive(Deserialize)]
struct HostRangeRequest {
    text: String,
    #[serde(default)]
    url: Option<String>,
}

#[derive(Deserialize)]
struct TildeRequest {
    path: String,
    #[serde(default)]
    home: String,
}

#[derive(Deserialize)]
struct FillRequest {
    row: Suggestion,
}

#[derive(Deserialize)]
struct CompletionRequest {
    row: Suggestion,
    typed: String,
    #[serde(default)]
    home: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TldUrlRequest {
    typed: String,
    #[serde(default)]
    home: String,
    #[serde(default)]
    allows_chromium_schemes: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HttpsUpgradeRequest {
    text: String,
    url: String,
    #[serde(default)]
    home: String,
    #[serde(default)]
    allows_chromium_schemes: bool,
}

#[derive(Deserialize)]
struct ClampRequest {
    selection: Range,
    length: i64,
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
        "browser_rules_is_top_level_domain" => {
            let TldRequest { label, labels } = parse(request)?;
            match (label, labels) {
                (Some(label), None) => Ok(json!(address::is_top_level_domain(&label))),
                (None, Some(labels)) => Ok(json!(
                    labels
                        .iter()
                        .map(|label| address::is_top_level_domain(label))
                        .collect::<Vec<_>>()
                )),
                _ => Err(OpError::Invalid("one of label or labels".into())),
            }
        }
        "browser_rules_host_typo_fix" => {
            let TextRequest { text } = parse(request)?;
            Ok(encode(&address::fix_host_typo(&text)))
        }
        "browser_rules_https_upgrade_falls_back" => {
            let LoadErrorRequest { domain, code } = parse(request)?;
            Ok(json!(address::https_upgrade_falls_back(&domain, code)))
        }
        "browser_rules_calculator_answer" => {
            let TextRequest { text } = parse(request)?;
            Ok(json!(calculator::answer(&text)))
        }
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
        "browser_rules_omnibar_display_text" => {
            let UrlRequest { url, home } = parse(request)?;
            Ok(json!(omnibar::display_text(url.as_deref(), &home)))
        }
        "browser_rules_omnibar_resting_text" => {
            let UrlRequest { url, home } = parse(request)?;
            Ok(json!(omnibar::resting_text(url.as_deref(), &home)))
        }
        "browser_rules_omnibar_editing_text" => {
            let UrlRequest { url, .. } = parse(request)?;
            Ok(json!(omnibar::editing_text(url.as_deref())))
        }
        "browser_rules_omnibar_host_range" => {
            let HostRangeRequest { text, url } = parse(request)?;
            Ok(encode(&omnibar::host_range(&text, url.as_deref())))
        }
        "browser_rules_omnibar_tilde_path" => {
            let TildeRequest { path, home } = parse(request)?;
            Ok(json!(omnibar::tilde_path(&path, &home)))
        }
        "browser_rules_omnibar_fill_text" => {
            let FillRequest { row } = parse(request)?;
            Ok(json!(omnibar::fill_text(&row)))
        }
        "browser_rules_omnibar_inline_completion" => {
            let CompletionRequest { row, typed, home } = parse(request)?;
            Ok(json!(omnibar::inline_completion(&row, &typed, &home)))
        }
        "browser_rules_omnibar_desired_tld_url" => {
            let TldUrlRequest { typed, home, allows_chromium_schemes } = parse(request)?;
            let resolver = TypedInput { home: &home, allows_chromium_schemes };
            Ok(json!(omnibar::desired_tld_url(&typed, &resolver)))
        }
        "browser_rules_omnibar_is_https_upgrade" => {
            let HttpsUpgradeRequest { text, url, home, allows_chromium_schemes } = parse(request)?;
            let resolver = TypedInput { home: &home, allows_chromium_schemes };
            Ok(json!(omnibar::is_https_upgrade(&text, &url, &resolver)))
        }
        "browser_rules_omnibar_single_line" => {
            let TextRequest { text } = parse(request)?;
            Ok(json!(omnibar::single_line(&text)))
        }
        "browser_rules_omnibar_dropped_text" => {
            let TextRequest { text } = parse(request)?;
            Ok(json!(omnibar::dropped_text(&text)))
        }
        "browser_rules_omnibar_clamped" => {
            let ClampRequest { selection, length } = parse(request)?;
            Ok(encode(&omnibar::clamped(selection, length)))
        }
        "browser_rules_omnibar_utf16_length" => {
            let TextRequest { text } = parse(request)?;
            Ok(json!(omnibar::utf16_length(&text)))
        }
        other => Err(OpError::UnknownOp(other.to_owned())),
    }
}
