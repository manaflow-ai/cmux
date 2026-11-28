//! Rules for link routing that were the Swift app's: which URLs only a Chromium tab can show, the
//! New Tab page, which sign-in tab to close after the sign-in, and a popup window's requested size
//! (`ChromiumInternalURL.needsChromium`, `BrowserNewTabPage.isNewTabPage`, `SignInPageTab`,
//! `BrowserPopupRequest`). Ops in [`call`], over the app FFI's JSON channel.
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `browser_rules_linkroute_needs_chromium` | `{scheme}` (null: none) | a bool |
//! | `browser_rules_linkroute_is_new_tab_page` | `{text}` | a bool |
//! | `browser_rules_linkroute_sign_in_on_host` | `{shown, host, hosts}` | a bool |
//! | `browser_rules_linkroute_sign_in_to_close` | `{tabs: [{shown}], host, hosts}` | the index of the tab, or null |
//! | `browser_rules_linkroute_popup_request` | `{features}` (`{x, y, width, height}` or null) | `{width, height, x?, y?}` |
//!
//! `shown` is a tab's addresses, each `{scheme, host}` or null (the address was not a URL); the app
//! parses addresses, Rust decides.

use crate::ops::OpError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// Schemes whose pages only a Chromium tab shows.
const CHROMIUM_SCHEMES: [&str; 2] = ["chrome", "chrome-extension"];

/// Whether a URL with this scheme is a page only a Chromium tab can show.
pub fn needs_chromium(scheme: Option<&str>) -> bool {
    scheme.is_some_and(|scheme| CHROMIUM_SCHEMES.contains(&scheme.to_lowercase().as_str()))
}

/// True for the New Tab page and the blank page: the omnibar shows nothing, the title falls back
/// to "New Tab", history skips it.
pub fn is_new_tab_page(text: &str) -> bool {
    matches!(text.to_lowercase().as_str(), "about:blank" | "chrome://newtab/" | "chrome://newtab")
}

/// A shown address's scheme and host, as the app parsed them.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Address {
    pub scheme: Option<String>,
    pub host: Option<String>,
}

/// Whether a tab still shows the sign-in's provider: its first web address (a load error's own
/// page is none) is on `host` or one of `hosts`.
pub fn on_host(shown: &[Option<Address>], host: Option<&str>, hosts: &[String]) -> bool {
    let Some(host) = host.map(str::to_lowercase) else { return false };
    let Some(page) = shown.iter().flatten().find(|address| {
        address
            .scheme
            .as_deref()
            .is_some_and(|scheme| matches!(scheme.to_lowercase().as_str(), "http" | "https"))
    }) else {
        return false;
    };
    let Some(shown_host) = page.host.as_deref().map(str::to_lowercase) else { return false };
    shown_host == host || hosts.iter().any(|candidate| candidate.to_lowercase() == shown_host)
}

/// Of the tabs made since the sign-in opened its page, the index of the one to close: the only one
/// still on the provider's host. With none, or two or more, none closes.
pub fn to_close(
    tabs: &[Vec<Option<Address>>],
    host: Option<&str>,
    hosts: &[String],
) -> Option<usize> {
    let mut on = tabs.iter().enumerate().filter(|(_, shown)| on_host(shown, host, hosts));
    match (on.next(), on.next()) {
        (Some((index, _)), None) => Some(index),
        _ => None,
    }
}

/// Window features a page gave (zero = not given).
#[derive(Debug, Clone, Copy, Deserialize)]
pub struct Features {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// A popup's content size and, when the page gave a position, its top-left.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct PopupRequest {
    pub width: f64,
    pub height: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
}

/// The popup a page's window features ask for: a negative size reads as none (0), an origin of
/// (0, 0) as no position; no features, no size and no position.
pub fn popup_request(features: Option<Features>) -> PopupRequest {
    let Some(f) = features else {
        return PopupRequest { width: 0.0, height: 0.0, x: None, y: None };
    };
    let placed = f.x != 0.0 || f.y != 0.0;
    PopupRequest {
        width: f.width.max(0.0),
        height: f.height.max(0.0),
        x: placed.then_some(f.x),
        y: placed.then_some(f.y),
    }
}

#[derive(Deserialize)]
struct SchemeRequest {
    #[serde(default)]
    scheme: Option<String>,
}

#[derive(Deserialize)]
struct TextRequest {
    text: String,
}

#[derive(Deserialize)]
struct OnHostRequest {
    #[serde(default)]
    shown: Vec<Option<Address>>,
    #[serde(default)]
    host: Option<String>,
    #[serde(default)]
    hosts: Vec<String>,
}

#[derive(Deserialize)]
struct Tab {
    #[serde(default)]
    shown: Vec<Option<Address>>,
}

#[derive(Deserialize)]
struct ToCloseRequest {
    #[serde(default)]
    tabs: Vec<Tab>,
    #[serde(default)]
    host: Option<String>,
    #[serde(default)]
    hosts: Vec<String>,
}

#[derive(Deserialize)]
struct PopupRequestInput {
    #[serde(default)]
    features: Option<Features>,
}

fn parse<T: serde::de::DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

/// Runs the link op `op`, or None when it is not one of them.
pub fn call(op: &str, request: Value) -> Option<Result<Value, OpError>> {
    let name = op.strip_prefix("browser_rules_linkroute_")?;
    Some(run(name, request))
}

fn run(name: &str, request: Value) -> Result<Value, OpError> {
    match name {
        "needs_chromium" => {
            let SchemeRequest { scheme } = parse(request)?;
            Ok(json!(needs_chromium(scheme.as_deref())))
        }
        "is_new_tab_page" => {
            let TextRequest { text } = parse(request)?;
            Ok(json!(is_new_tab_page(&text)))
        }
        "sign_in_on_host" => {
            let OnHostRequest { shown, host, hosts } = parse(request)?;
            Ok(json!(on_host(&shown, host.as_deref(), &hosts)))
        }
        "sign_in_to_close" => {
            let ToCloseRequest { tabs, host, hosts } = parse(request)?;
            let tabs: Vec<_> = tabs.into_iter().map(|tab| tab.shown).collect();
            Ok(json!(to_close(&tabs, host.as_deref(), &hosts)))
        }
        "popup_request" => {
            let PopupRequestInput { features } = parse(request)?;
            Ok(serde_json::to_value(popup_request(features)).unwrap_or(Value::Null))
        }
        other => Err(OpError::UnknownOp(format!("browser_rules_linkroute_{other}"))),
    }
}
