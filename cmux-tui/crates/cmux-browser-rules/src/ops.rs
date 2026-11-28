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
//! | `browser_rules_tab_state_new` | `{state}` (absent: a new tab) | the [`TabStateMachine`] |
//! | `browser_rules_tab_state_apply` | `{machine, event}` or `{machine, events}` | `{machine, changed}` |
//! | `browser_rules_tab_state_security` | `{url}` | the scheme-level [`SecurityState`](crate::tab_state::SecurityState) |
//! | `browser_rules_tab_state_committed_security` | `{url, hasOnlySecureContent, certificateBypassed}` | the [`SecurityState`](crate::tab_state::SecurityState) |
//! | `browser_rules_url_filter_blocks` | `{blocklist, allowlist, url}` or `{.., urls}` | a bool, or one per URL |
//! | `browser_rules_url_filter_is_empty` | `{blocklist, allowlist}` | a bool |
//! | `browser_rules_agent_url_refuses` | `{url}` or `{urls}` | a bool, or one per URL |
//! | `browser_rules_download_gesture` | `{policy}` | the [`AutomaticDownloadPolicy`] after a gesture |
//! | `browser_rules_download_count` | `{policy, site}` | `{policy, isFirst}` |
//! | `browser_rules_download_decision` | `{isFirst, setting}` | the [`DownloadDecision`](crate::download_policy::DownloadDecision) |
//! | `browser_rules_password_fills` | `{agentDriven, profileAllows}` | a bool |
//! | `browser_rules_password_fill_set_allowed` | `{state, allowed}` | `{state, changed}` |
//! | `browser_rules_password_fill_switch` | `{state, agentDriven}` | `{state, value}`, `value` 1, 0 or null |
//! | `browser_rules_automation_*` | see [`crate::automation_ops`] | |

use crate::download_policy::{AutomaticDownloadPolicy, SitePermissionSetting};
use crate::links::{
    self, CefDisposition, ClickMapping, ClickRecord, Gesture, LinkContext, LinkPlacement,
    Modifiers, WebKitLinkClick, WindowCandidate, WindowDecision, WindowRequest,
};
use crate::password_fill::{self, PasswordFillState};
use crate::tab_state::{self, NavigationEvent, TabState, TabStateMachine};
use crate::url_filter::{UrlFilter, UrlFilterLists};
use crate::{address, agent_url, calculator};
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
struct TabStateNewRequest {
    #[serde(default)]
    state: TabState,
}

#[derive(Deserialize)]
struct TabStateApplyRequest {
    #[serde(default)]
    machine: TabStateMachine,
    #[serde(default)]
    event: Option<NavigationEvent>,
    #[serde(default)]
    events: Option<Vec<NavigationEvent>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SecurityRequest {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    has_only_secure_content: bool,
    #[serde(default)]
    certificate_bypassed: bool,
}

#[derive(Deserialize)]
struct UrlFilterRequest {
    #[serde(flatten)]
    lists: UrlFilterLists,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    urls: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct UrlRequest {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    urls: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct DownloadRequest {
    #[serde(default)]
    policy: AutomaticDownloadPolicy,
    #[serde(default)]
    site: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DownloadDecisionRequest {
    is_first: bool,
    setting: SitePermissionSetting,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PasswordFillRequest {
    #[serde(default)]
    state: PasswordFillState,
    #[serde(default)]
    agent_driven: bool,
    #[serde(default = "default_true")]
    profile_allows: bool,
    #[serde(default)]
    allowed: Option<bool>,
}

fn default_true() -> bool {
    true
}

/// One answer for `url`, or one per URL of `urls`.
fn per_url(
    url: Option<String>,
    urls: Option<Vec<String>>,
    answer: impl Fn(&str) -> bool,
) -> Result<Value, OpError> {
    match (url, urls) {
        (Some(url), None) => Ok(json!(answer(&url))),
        (None, Some(urls)) => Ok(json!(urls.iter().map(|url| answer(url)).collect::<Vec<_>>())),
        _ => Err(OpError::Invalid("one of url or urls".into())),
    }
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
    if let Some(answer) = crate::automation_ops::call(op, request.clone()) {
        return answer;
    }
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
        "browser_rules_tab_state_new" => {
            let TabStateNewRequest { state } = parse(request)?;
            Ok(encode(&TabStateMachine::new(state)))
        }
        "browser_rules_tab_state_apply" => {
            let TabStateApplyRequest { mut machine, event, events } = parse(request)?;
            let events = match (event, events) {
                (Some(event), None) => vec![event],
                (None, Some(events)) => events,
                _ => return Err(OpError::Invalid("one of event or events".into())),
            };
            let mut changed = false;
            for event in events {
                changed |= machine.apply(event);
            }
            Ok(json!({"machine": encode(&machine), "changed": changed}))
        }
        "browser_rules_tab_state_security" => {
            let SecurityRequest { url, .. } = parse(request)?;
            Ok(encode(&tab_state::security(url.as_deref())))
        }
        "browser_rules_tab_state_committed_security" => {
            let SecurityRequest { url, has_only_secure_content, certificate_bypassed } =
                parse(request)?;
            Ok(encode(&tab_state::committed_security(
                url.as_deref(),
                has_only_secure_content,
                certificate_bypassed,
            )))
        }
        "browser_rules_url_filter_blocks" => {
            let UrlFilterRequest { lists, url, urls } = parse(request)?;
            let filter = UrlFilter::of(&lists);
            per_url(url, urls, |url| filter.blocks(url))
        }
        "browser_rules_url_filter_is_empty" => {
            let lists: UrlFilterLists = parse(request)?;
            Ok(json!(UrlFilter::of(&lists).is_empty()))
        }
        "browser_rules_agent_url_refuses" => {
            let UrlRequest { url, urls } = parse(request)?;
            per_url(url, urls, agent_url::refuses)
        }
        "browser_rules_download_gesture" => {
            let DownloadRequest { mut policy, .. } = parse(request)?;
            policy.user_gesture();
            Ok(encode(&policy))
        }
        "browser_rules_download_count" => {
            let DownloadRequest { mut policy, site } = parse(request)?;
            let site = site.ok_or_else(|| OpError::Invalid("missing field `site`".into()))?;
            let is_first = policy.count_download(&site);
            Ok(json!({"policy": encode(&policy), "isFirst": is_first}))
        }
        "browser_rules_download_decision" => {
            let DownloadDecisionRequest { is_first, setting } = parse(request)?;
            Ok(encode(&AutomaticDownloadPolicy::decision(is_first, setting)))
        }
        "browser_rules_password_fills" => {
            let PasswordFillRequest { agent_driven, profile_allows, .. } = parse(request)?;
            Ok(json!(password_fill::fills(agent_driven, profile_allows)))
        }
        "browser_rules_password_fill_set_allowed" => {
            let PasswordFillRequest { mut state, allowed, .. } = parse(request)?;
            let allowed =
                allowed.ok_or_else(|| OpError::Invalid("missing field `allowed`".into()))?;
            let changed = state.set_allowed_by_profile(allowed);
            Ok(json!({"state": encode(&state), "changed": changed}))
        }
        "browser_rules_password_fill_switch" => {
            let PasswordFillRequest { mut state, agent_driven, .. } = parse(request)?;
            let value = state.next_switch_value(agent_driven);
            Ok(json!({"state": encode(&state), "value": value}))
        }
        other => Err(OpError::UnknownOp(other.to_owned())),
    }
}
